import io
import json
import os
import subprocess
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path

from src.omarchy_toggl.cli import main
from tests.fakes import ME, FakeOpener, entry, make_engine

ROOT = Path(__file__).resolve().parents[1]


def run(argv, engine):
    buf = io.StringIO()
    with redirect_stdout(buf):
        code = main(argv, engine)
    lines = buf.getvalue().strip().splitlines()
    return code, (json.loads(lines[-1]) if lines and lines[-1].startswith("{") else buf.getvalue())


class CliTests(unittest.TestCase):
    def setUp(self):
        self.opener = FakeOpener()
        self.opener.on("GET", "/me", lambda p, b: ME)
        self.opener.on("GET", "/me/time_entries", lambda p, b: [entry(1, "2026-09-26T09:00:00Z", "2026-09-26T10:00:00Z")])
        self.opener.on("POST", "/workspaces/7/time_entries",
                       lambda p, b: entry(5, b["start"], None, desc=b["description"], pid=b["project_id"], tags=b["tags"]))
        self.engine, _ = make_engine(self.opener)

    def test_sync_status_contract(self):
        code, out = run(["sync", "--force"], self.engine)
        self.assertEqual(code, 0)
        self.assertTrue(out["ok"])
        self.assertEqual(out["state"]["schema"], 1)
        n = len(self.opener.requests)
        code, out = run(["status"], self.engine)
        self.assertEqual(len(self.opener.requests), n)

    def test_start_with_grammar(self):
        run(["sync", "--force"], self.engine)
        code, out = run(["start", "Research", "@stonks", "#deep"], self.engine)
        self.assertEqual(code, 0)
        self.assertEqual(out["state"]["running"]["projectId"], 3)
        self.assertEqual(out["state"]["running"]["tags"], ["deep"])

    def test_usage_error_exit_code(self):
        run(["sync", "--force"], self.engine)
        code, out = run(["start", "x", "@nope"], self.engine)
        self.assertEqual(code, 2)
        self.assertEqual(out["error"]["kind"], "usage")
        code, out = run(["stop"], self.engine)
        self.assertEqual(code, 2)

    def test_auth_error_exit_code(self):
        self.opener.on("GET", "/me", lambda p, b: (403, "no"))
        code, out = run(["sync", "--force"], self.engine)
        self.assertEqual(code, 3)
        self.assertEqual(out["error"]["kind"], "auth")

    def test_text_mode(self):
        run(["sync", "--force"], self.engine)
        code, out = run(["--text", "status"], self.engine)
        self.assertIn("Today", out)

    def test_subprocess_help_and_bad_args(self):
        script = ROOT / "src" / "toggl.py"
        ok = subprocess.run([sys.executable, str(script), "--help"], capture_output=True, text=True)
        self.assertEqual(ok.returncode, 0)
        bad = subprocess.run([sys.executable, str(script), "nope"], capture_output=True, text=True)
        self.assertEqual(bad.returncode, 2)

    def test_status_without_token_never_fails(self):
        env = {**os.environ, "XDG_CACHE_HOME": "/tmp/omarchy-toggl-nonexistent-cache"}
        out = subprocess.run([sys.executable, str(ROOT / "src" / "toggl.py"), "status"],
                             capture_output=True, text=True, env=env)
        self.assertEqual(out.returncode, 0)
        self.assertTrue(json.loads(out.stdout)["ok"])


if __name__ == "__main__":
    unittest.main()
