"""Minimal Toggl Track API v9 client (stdlib only).

Every response's quota headers are recorded so sync can stay inside the
30 requests/hour budget that applies to all ``/me`` endpoints.
"""

from __future__ import annotations

import base64
import json
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Callable

from . import __version__

BASE = "https://api.track.toggl.com/api/v9"
REPORTS = "https://api.track.toggl.com/reports/api/v3"
CREATED_WITH = "omarchy-toggl"


class ApiError(Exception):
    kind = "api"

    def __init__(self, message: str, status: int | None = None, resets_in: int | None = None):
        super().__init__(message)
        self.status = status
        self.resets_in = resets_in


class AuthError(ApiError):
    kind = "auth"


class QuotaError(ApiError):
    kind = "quota"


class PlanError(ApiError):
    kind = "plan"


class RateError(ApiError):
    kind = "rate"


class NetError(ApiError):
    kind = "net"


class NotFound(ApiError):
    kind = "notfound"


class Conflict(ApiError):
    kind = "conflict"


def _int(value: Any) -> int | None:
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return None


class Api:
    def __init__(self, token: str, opener: Callable[..., Any] | None = None,
                 sleep: Callable[[float], None] = time.sleep, clock: Callable[[], float] = time.time):
        self._auth = "Basic " + base64.b64encode(f"{token}:api_token".encode()).decode()
        self._open = opener or urllib.request.urlopen
        self._sleep = sleep
        self._clock = clock
        self.quota: dict[str, dict[str, int]] = {}
        self.calls: list[str] = []

    # ------------------------------------------------------------------ core
    def request(self, method: str, path: str, body: Any = None, query: dict[str, Any] | None = None,
                base: str = BASE, retry: bool = True) -> Any:
        url = base + path
        if query:
            url += "?" + urllib.parse.urlencode({k: v for k, v in query.items() if v is not None},
                                                quote_via=urllib.parse.quote)
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method, headers={
            "Authorization": self._auth,
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": f"omarchy-toggl/{__version__}",
        })
        bucket = "user" if path.startswith("/me") else "workspace"
        self.calls.append(f"{method} {path}")
        try:
            with self._open(req, timeout=10) as resp:
                self._record(bucket, resp.headers)
                raw = resp.read()
        except urllib.error.HTTPError as err:
            self._record(bucket, err.headers)
            detail = _error_text(err)
            status = err.code
            if status in (401, 403):
                raise AuthError("Toggl rejected the API token", status) from None
            if status == 402:
                resets = _int(err.headers.get("X-Toggl-Quota-Resets-In")) if err.headers else None
                if resets is not None or (err.headers and err.headers.get("X-Toggl-Quota-Remaining") is not None):
                    raise QuotaError("Toggl API hourly limit reached", status, resets) from None
                raise PlanError(detail or "This feature needs a paid Toggl plan", status) from None
            if status == 429:
                if retry:
                    wait = _int(err.headers.get("Retry-After")) if err.headers else None
                    self._sleep(min(max(wait or 2, 1), 5))
                    return self.request(method, path, body, query, base, retry=False)
                raise RateError("Toggl is rate limiting requests", status) from None
            if status == 404:
                raise NotFound(detail or "not found", status) from None
            if status == 409:
                raise Conflict(detail or "conflict", status) from None
            if status >= 500:
                raise NetError(f"Toggl server error {status}", status) from None
            raise ApiError(detail or f"HTTP {status}", status) from None
        except (urllib.error.URLError, TimeoutError, OSError) as err:
            raise NetError(f"network error: {getattr(err, 'reason', err)}") from None
        if not raw:
            return None
        try:
            return json.loads(raw)
        except ValueError:
            return raw.decode(errors="replace")

    def _record(self, bucket: str, headers: Any) -> None:
        if not headers:
            return
        remaining = _int(headers.get("X-Toggl-Quota-Remaining"))
        resets_in = _int(headers.get("X-Toggl-Quota-Resets-In"))
        if remaining is None and resets_in is None:
            return
        entry = self.quota.setdefault(bucket, {})
        if remaining is not None:
            entry["remaining"] = remaining
        if resets_in is not None:
            entry["resetsAt"] = int(self._clock()) + resets_in

    # ------------------------------------------------------------- endpoints
    def me(self, related: bool = False) -> dict:
        return self.request("GET", "/me", query={"with_related_data": "true"} if related else None)

    def entries(self, start_date: str, end_date: str) -> list:
        return self.request("GET", "/me/time_entries",
                            query={"start_date": start_date, "end_date": end_date, "meta": "true"}) or []

    def current(self) -> dict | None:
        try:
            value = self.request("GET", "/me/time_entries/current", query={"meta": "true"})
        except NotFound:
            return None
        return value if isinstance(value, dict) else None

    def projects(self, wid: int) -> list:
        out: list = []
        page = 1
        while True:
            chunk = self.request("GET", f"/workspaces/{wid}/projects",
                                 query={"active": "both", "per_page": 200, "page": page}) or []
            out.extend(chunk)
            if len(chunk) < 200:
                return out
            page += 1

    def tags(self, wid: int) -> list:
        return self.request("GET", f"/workspaces/{wid}/tags") or []

    def create(self, wid: int, body: dict) -> dict:
        payload = {"created_with": CREATED_WITH, "workspace_id": wid, **body}
        return self.request("POST", f"/workspaces/{wid}/time_entries", payload, query={"meta": "true"})

    def update(self, wid: int, entry_id: int, body: dict) -> dict:
        return self.request("PUT", f"/workspaces/{wid}/time_entries/{entry_id}", body, query={"meta": "true"})

    def stop(self, wid: int, entry_id: int) -> dict | None:
        try:
            return self.request("PATCH", f"/workspaces/{wid}/time_entries/{entry_id}/stop")
        except Conflict:
            return None

    def delete(self, wid: int, entry_id: int) -> None:
        self.request("DELETE", f"/workspaces/{wid}/time_entries/{entry_id}")


def _error_text(err: urllib.error.HTTPError) -> str:
    try:
        text = err.read().decode(errors="replace").strip()
    except Exception:  # noqa: BLE001 - best effort diagnostics only
        return ""
    if text.startswith('"') and text.endswith('"'):
        text = text[1:-1]
    return text[:300]
