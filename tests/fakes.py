"""Test doubles: a scripted urlopen and an Engine wired to a temp store."""

import io
import json
import tempfile
import urllib.error
import urllib.parse
from datetime import datetime, timezone
from email.message import Message
from pathlib import Path

from src.omarchy_toggl.api import Api
from src.omarchy_toggl.store import Store
from src.omarchy_toggl.sync import Engine


def headers(remaining=25, resets=1800):
    msg = Message()
    if remaining is not None:
        msg["X-Toggl-Quota-Remaining"] = str(remaining)
    if resets is not None:
        msg["X-Toggl-Quota-Resets-In"] = str(resets)
    return msg


class Resp:
    def __init__(self, body, hdrs):
        self._body = body
        self.headers = hdrs

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FakeOpener:
    """Routes (METHOD, path) to handlers; records every request."""

    def __init__(self):
        self.routes = []
        self.requests = []
        self.offline = False
        self.remaining = 25

    def on(self, method, path_prefix, handler):
        self.routes.insert(0, (method, path_prefix, handler))
        return self

    def __call__(self, req, timeout=None):
        url = urllib.parse.urlparse(req.full_url)
        path = url.path.replace("/api/v9", "", 1)
        body = json.loads(req.data) if req.data else None
        self.requests.append((req.get_method(), path, urllib.parse.parse_qs(url.query), body, req.full_url))
        if self.offline:
            raise urllib.error.URLError("offline")
        for method, prefix, handler in self.routes:
            if method == req.get_method() and path.startswith(prefix):
                result = handler(path, body)
                status = 200
                if isinstance(result, tuple):
                    status, result = result
                self.remaining -= 1 if path.startswith("/me") else 0
                hdrs = headers(self.remaining, 1800)
                raw = json.dumps(result).encode() if result is not None else b""
                if status >= 400:
                    raise urllib.error.HTTPError(req.full_url, status, "err", hdrs, io.BytesIO(raw))
                return Resp(raw, hdrs)
        raise urllib.error.HTTPError(req.full_url, 404, "no route", headers(None, None), io.BytesIO(b""))


NOW = datetime(2026, 9, 26, 12, 0, 0, tzinfo=timezone.utc)


def make_engine(opener, clock=lambda: NOW):
    tmp = tempfile.mkdtemp(prefix="omarchy-toggl-test-")
    store = Store(Path(tmp))
    engine = Engine(store, api_factory=lambda: (Api("tok", opener=opener, sleep=lambda s: None), "file"),
                    clock=clock)
    return engine, store


ME = {
    "fullname": "Test User", "email": "user@example.com", "timezone": "Europe/Berlin", "beginning_of_week": 1,
    "default_workspace_id": 7,
    "workspaces": [{"id": 7, "name": "Personal"}],
    "projects": [
        {"id": 1, "name": "Snowball", "color": "#c7741c", "active": True, "workspace_id": 7},
        {"id": 2, "name": "Generic", "color": "#465bb3", "active": True, "workspace_id": 7},
        {"id": 3, "name": "stonks", "color": "#2da608", "active": True, "workspace_id": 7},
    ],
    "tags": [{"id": 9, "name": "deep", "workspace_id": 7}],
    "clients": [],
}


def entry(eid, start, stop=None, desc="Research", pid=2, **extra):
    base = {"id": eid, "workspace_id": 7, "description": desc, "project_id": pid, "start": start,
            "stop": stop, "duration": -1 if stop is None else None, "billable": False, "tags": [],
            "tag_ids": []}
    if pid:
        base["project_name"] = {1: "Snowball", 2: "Generic", 3: "stonks"}.get(pid)
        base["project_color"] = {1: "#c7741c", 2: "#465bb3", 3: "#2da608"}.get(pid)
    if stop is not None:
        a = datetime.fromisoformat(start.replace("Z", "+00:00"))
        b = datetime.fromisoformat(stop.replace("Z", "+00:00"))
        base["duration"] = int((b - a).total_seconds())
    base.update(extra)
    return base
