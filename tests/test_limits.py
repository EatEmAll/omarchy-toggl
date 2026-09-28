"""Untrusted input is bounded: network bodies, redirects, time, pagination,
response shapes, stdin, subprocess output, user text and the offline queue."""

import http.server
import io
import itertools
import os
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.error
from email.message import Message
from pathlib import Path
from unittest import mock

from src.omarchy_toggl import api as api_mod
from src.omarchy_toggl import token as token_mod
from src.omarchy_toggl.api import Api, ApiError, NetError
from src.omarchy_toggl.sync import MAX_PENDING, UsageError
from tests.fakes import ME, FakeOpener, make_engine

ROOT = Path(__file__).resolve().parents[1]


class Endless:
    """A response body that never ends; counts how much was read."""

    def __init__(self, headers=None, url="https://api.track.toggl.com/api/v9/me"):
        self.headers = headers or Message()
        self.read_total = 0
        self._url = url

    def read(self, n=-1):
        if n is None or n < 0:
            raise AssertionError("unbounded read() of a network body")
        self.read_total += n
        return b"x" * n

    def geturl(self):
        return self._url

    def close(self):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def api_with(opener):
    return Api("tok", opener=opener, sleep=lambda s: None)


class NetworkLimits(unittest.TestCase):
    def test_response_body_is_capped_during_the_read(self):
        body = Endless()
        with mock.patch.object(api_mod, "MAX_BODY", 256 * 1024), self.assertRaises(ApiError):
            api_with(lambda req, timeout=None: body).me()
        self.assertLessEqual(body.read_total, 256 * 1024 + api_mod.CHUNK)

    def test_declared_oversize_is_refused_before_reading(self):
        hdrs = Message()
        hdrs["Content-Length"] = str(api_mod.MAX_BODY + 1)
        body = Endless(hdrs)
        with self.assertRaises(ApiError):
            api_with(lambda req, timeout=None: body).me()
        self.assertEqual(body.read_total, 0)

    def test_error_body_is_capped(self):
        body = Endless()

        def opener(req, timeout=None):
            raise urllib.error.HTTPError(req.full_url, 500, "boom", Message(), body)
        with self.assertRaises(NetError):
            api_with(opener).me()
        self.assertLessEqual(body.read_total, api_mod.MAX_ERROR_BODY)

    def test_whole_request_deadline(self):
        body = Endless()
        ticks = itertools.count(step=5)
        client = api_with(lambda req, timeout=None: body)
        client._monotonic = lambda: next(ticks)          # 5 "seconds" per chunk
        with self.assertRaises(NetError):
            client.me()
        self.assertLess(body.read_total, api_mod.MAX_BODY)

    def test_endless_pagination_stops(self):
        opener = FakeOpener().on("GET", "/workspaces/7/projects", lambda p, b: [{"id": 1}] * 200)
        with self.assertRaises(ApiError):
            api_with(opener).projects(7)
        self.assertEqual(len(opener.requests), api_mod.MAX_PAGES)

    def test_unexpected_shapes_are_errors(self):
        opener = FakeOpener()   # later routes win; register the shorter prefix first
        opener.on("GET", "/me", lambda p, b: ["not", "a", "dict"])
        opener.on("GET", "/me/time_entries", lambda p, b: {"not": "a list"})
        client = api_with(opener)
        with self.assertRaises(ApiError):
            client.me()
        with self.assertRaises(ApiError):
            client.entries("2026-09-01", "2026-09-02")

    def test_non_json_and_deeply_nested_json(self):
        for raw in (b"<html>oops</html>", b"[" * 200000 + b"]" * 200000):
            class R(Endless):
                def read(self, n=-1, _buf=io.BytesIO(raw)):
                    return _buf.read(n)
            with self.subTest(raw=raw[:10]), self.assertRaises(ApiError):
                api_with(lambda req, timeout=None: R()).me()

    def test_token_only_sent_to_toggl_over_https(self):
        opener = FakeOpener().on("GET", "/me", lambda p, b: ME)
        client = api_with(opener)
        for base in ("http://api.track.toggl.com/api/v9", "https://evil.example/api/v9"):
            with self.subTest(base=base), self.assertRaises(ApiError):
                client.request("GET", "/me", base=base)
        self.assertEqual(opener.requests, [])

    def test_response_from_elsewhere_is_refused(self):
        body = Endless(url="https://evil.example/")
        with self.assertRaises(ApiError):
            api_with(lambda req, timeout=None: body).me()
        self.assertEqual(body.read_total, 0)

    def test_redirect_status_is_an_error(self):
        def opener(req, timeout=None):
            hdrs = Message()
            hdrs["Location"] = "https://evil.example/steal"
            raise urllib.error.HTTPError(req.full_url, 302, "Found", hdrs, io.BytesIO(b""))
        with self.assertRaises(ApiError):
            api_with(opener).me()

    def test_identity_encoding_is_requested(self):
        opener = FakeOpener().on("GET", "/me", lambda p, b: ME)
        seen = {}
        real = opener.__call__

        def spy(req, timeout=None):
            seen.update({k.lower(): v for k, v in req.header_items()})
            return real(req, timeout)
        api_with(spy).me()
        self.assertEqual(seen.get("accept-encoding"), "identity")


class RealOpenerRedirect(unittest.TestCase):
    """The production opener must not follow a redirect (it would re-send Authorization)."""

    def test_no_redirect_followed(self):
        hits = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                hits.append((self.path, self.headers.get("Authorization")))
                if self.path == "/start":
                    self.send_response(302)
                    self.send_header("Location", f"http://127.0.0.1:{self.server.server_port}/leak")
                    self.end_headers()
                else:
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(b"{}")

            def log_message(self, *args):
                pass

        server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            req = urllib.request.Request(f"http://127.0.0.1:{server.server_port}/start",
                                         headers={"Authorization": "Basic secret"})
            with self.assertRaises(urllib.error.HTTPError) as ctx:
                api_mod._OPENER.open(req, timeout=5)
            self.assertEqual(ctx.exception.code, 302)
        finally:
            server.shutdown()
        self.assertEqual([h[0] for h in hits], ["/start"])


class LocalInputLimits(unittest.TestCase):
    def test_stdin_token_is_bounded(self):
        env = {**os.environ, "XDG_CONFIG_HOME": tempfile.mkdtemp(), "XDG_CACHE_HOME": tempfile.mkdtemp()}
        out = subprocess.run([sys.executable, str(ROOT / "src/toggl.py"), "auth", "login", "--stdin"],
                             input="a" * (1024 * 1024) + "\n", capture_output=True, text=True, env=env, timeout=30)
        self.assertEqual(out.returncode, 3, out.stdout + out.stderr)
        self.assertIn("invalid", out.stdout)

    def test_secret_tool_output_is_bounded_and_timed(self):
        with tempfile.TemporaryDirectory() as d:
            endless = Path(d) / "secret-tool"
            endless.write_text("#!/bin/sh\nexec yes aaaaaaaaaaaaaaaa\n")
            endless.chmod(0o755)
            with mock.patch.object(token_mod, "_secret_tool", return_value=str(endless)):
                self.assertIsNone(token_mod._keyring_lookup())
            slow = Path(d) / "slow"
            slow.write_text("#!/bin/sh\nsleep 30\n")
            slow.chmod(0o755)
            self.assertIsNone(token_mod._capped_output([str(slow)], 100, timeout=0.5))

    def test_user_text_is_bounded(self):
        engine, _ = make_engine(FakeOpener())
        with self.assertRaises(UsageError):
            engine.start("x" * 3001)
        with self.assertRaises(UsageError):
            engine.start("ok", tags=[f"t{i}" for i in range(51)])
        with self.assertRaises(UsageError):
            engine.update(1, {"description": "y" * 3001})

    def test_offline_queue_is_bounded(self):
        opener = FakeOpener().on("GET", "/me", lambda p, b: ME).on("GET", "/me/time_entries", lambda p, b: [])
        engine, store = make_engine(opener)
        engine.sync(force=True)
        with store.locked():
            state = store.load()
            state["pending"] = [{"op": "delete", "wid": 7, "id": i} for i in range(MAX_PENDING)]
            store.save(state)
        opener.offline = True
        with self.assertRaises(NetError):
            engine.start("one more")
        with store.locked():
            self.assertEqual(len(store.load()["pending"]), MAX_PENDING)


if __name__ == "__main__":
    unittest.main()


class SlowDrip(unittest.TestCase):
    """A server that keeps each recv alive under the socket timeout must still
    hit the overall deadline (checked at the syscall, not between chunks)."""

    CLIENT = r'''
import sys, time
sys.path.insert(0, %(root)r)
from src.omarchy_toggl import api as api_mod
api_mod.ALLOWED_ORIGIN = ("http", "127.0.0.1")
api_mod.DEADLINE = 1.5
api_mod.SOCKET_TIMEOUT = 1.0
t = time.monotonic()
try:
    api_mod.Api("tok").request("GET", "/x", base="http://127.0.0.1:%(port)d")
    print("NO-ERROR")
except api_mod.NetError as exc:
    print("NetError %%.1f" %% (time.monotonic() - t))
'''

    def serve(self, mode):
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                try:
                    if mode == "headers":
                        for ch in b"HTTP/1.1 200 OK\r\nX-Slow: " + b"a" * 1000:
                            self.wfile.write(bytes([ch])); self.wfile.flush(); time.sleep(0.3)
                        return
                    self.send_response(500 if mode == "error" else 200)
                    self.send_header("Content-Length", "100000")
                    self.end_headers()
                    for _ in range(1000):
                        self.wfile.write(b"x"); self.wfile.flush(); time.sleep(0.3)
                except OSError:
                    pass

            def log_message(self, *args):
                pass

        import time
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.daemon_threads = True
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.shutdown)
        return server.server_port

    def run_client(self, mode):
        port = self.serve(mode)
        code = self.CLIENT % {"root": str(ROOT), "port": port}
        out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, timeout=15)
        return out.stdout.strip() + out.stderr.strip()[-300:]

    def assertDeadline(self, result):
        self.assertTrue(result.startswith("NetError"), result)
        self.assertLess(float(result.split()[1]), 3.0, result)

    def test_slow_drip_body(self):
        self.assertDeadline(self.run_client("body"))

    def test_slow_drip_headers(self):
        self.assertDeadline(self.run_client("headers"))

    def test_slow_drip_error_body(self):
        self.assertDeadline(self.run_client("error"))


class LockWait(unittest.TestCase):
    def test_lock_wait_is_bounded(self):
        import fcntl
        from src.omarchy_toggl import store as store_mod
        d = Path(tempfile.mkdtemp()) / "c"
        holder = store_mod.Store(d)
        with holder.locked():
            other = store_mod.Store(d)
            with mock.patch.object(store_mod, "LOCK_WAIT", 0.3), self.assertRaises(TimeoutError):
                # a second open file description contends for the same flock
                fd = os.open(d, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    with other.locked():
                        pass
                finally:
                    os.close(fd)
