"""Minimal Toggl Track API v9 client (stdlib only).

Every response's quota headers are recorded so sync can stay inside the
30 requests/hour budget that applies to all ``/me`` endpoints.

Untrusted-input rules (all in :meth:`Api.request`):

* redirects are never followed, so the ``Authorization`` header is only ever
  sent to ``https://api.track.toggl.com`` (urllib would otherwise forward it
  to any redirect target, including another host or plain http);
* bodies are read in chunks with hard byte limits enforced during the read
  (``MAX_BODY`` for responses, ``MAX_ERROR_BODY`` for error bodies) and an
  overall per-request deadline on top of the socket timeout;
* ``Accept-Encoding: identity`` (no decompression);
* responses must be JSON of the type each endpoint expects, otherwise
  :class:`ApiError`; pagination stops after ``MAX_PAGES``.
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
ALLOWED_ORIGIN = ("https", "api.track.toggl.com")

MAX_BODY = 8 * 1024 * 1024        # largest response body we will read
MAX_ERROR_BODY = 16 * 1024        # error bodies are only used for a short message
SOCKET_TIMEOUT = 10               # per socket operation
DEADLINE = 30                     # whole request, including a slow-drip body
MAX_PAGES = 50                    # 50 x 200 projects
CHUNK = 64 * 1024


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


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Refuse every redirect: urllib would re-send Authorization to the new URL."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D401
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)


def _read_capped(stream: Any, limit: int, deadline: float, monotonic: Callable[[], float]) -> bytes:
    """Read at most ``limit`` bytes before the deadline; raise if there is more."""
    length = _int(stream.headers.get("Content-Length")) if getattr(stream, "headers", None) else None
    if length is not None and length > limit:
        raise ApiError(f"Toggl response too large ({length} bytes)")
    chunks: list[bytes] = []
    total = 0
    while True:
        if monotonic() > deadline:
            raise NetError("Toggl response took too long")
        chunk = stream.read(min(CHUNK, limit + 1 - total))
        if not chunk:
            return b"".join(chunks)
        chunks.append(chunk)
        total += len(chunk)
        if total > limit:
            raise ApiError(f"Toggl response too large (over {limit} bytes)")


def _int(value: Any) -> int | None:
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return None


class Api:
    def __init__(self, token: str, opener: Callable[..., Any] | None = None,
                 sleep: Callable[[float], None] = time.sleep, clock: Callable[[], float] = time.time):
        self._auth = "Basic " + base64.b64encode(f"{token}:api_token".encode()).decode()
        self._open = opener or _OPENER.open
        self._sleep = sleep
        self._clock = clock
        self._monotonic = time.monotonic
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
            "Accept-Encoding": "identity",
            "User-Agent": f"omarchy-toggl/{__version__}",
        })
        parts = urllib.parse.urlsplit(url)
        if (parts.scheme, parts.hostname) != ALLOWED_ORIGIN:
            raise ApiError(f"refusing to send the API token to {parts.scheme}://{parts.hostname}")
        bucket = "user" if path.startswith("/me") else "workspace"
        self.calls.append(f"{method} {path}")
        deadline = self._monotonic() + DEADLINE
        try:
            with self._open(req, timeout=SOCKET_TIMEOUT) as resp:
                final = urllib.parse.urlsplit(resp.geturl()) if hasattr(resp, "geturl") else parts
                if (final.scheme, final.hostname) != ALLOWED_ORIGIN:
                    raise ApiError("Toggl API response came from an unexpected location")
                self._record(bucket, resp.headers)
                raw = _read_capped(resp, MAX_BODY, deadline, self._monotonic)
        except urllib.error.HTTPError as err:
            self._record(bucket, err.headers)
            detail = _error_text(err, deadline, self._monotonic)
            status = err.code
            if 300 <= status < 400:
                raise ApiError(f"Toggl API answered with a redirect ({status}); not following it", status) from None
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
        except (ValueError, RecursionError):
            raise ApiError("unexpected (non-JSON) response from Toggl") from None

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
        return _expect(self.request("GET", "/me", query={"with_related_data": "true"} if related else None),
                       dict, "/me")

    def entries(self, start_date: str, end_date: str) -> list:
        value = self.request("GET", "/me/time_entries",
                             query={"start_date": start_date, "end_date": end_date, "meta": "true"})
        return _expect(value, list, "time entries", allow_none=True) or []

    def current(self) -> dict | None:
        try:
            value = self.request("GET", "/me/time_entries/current", query={"meta": "true"})
        except NotFound:
            return None
        return _expect(value, dict, "current entry", allow_none=True)

    def projects(self, wid: int) -> list:
        out: list = []
        for page in range(1, MAX_PAGES + 1):
            chunk = _expect(self.request("GET", f"/workspaces/{wid}/projects",
                                         query={"active": "both", "per_page": 200, "page": page}),
                            list, "projects", allow_none=True) or []
            out.extend(chunk)
            if len(chunk) < 200:
                return out
        raise ApiError(f"more than {MAX_PAGES} pages of projects; stopping")

    def tags(self, wid: int) -> list:
        return _expect(self.request("GET", f"/workspaces/{wid}/tags"), list, "tags", allow_none=True) or []

    def create(self, wid: int, body: dict) -> dict:
        payload = {"created_with": CREATED_WITH, "workspace_id": wid, **body}
        return _expect(self.request("POST", f"/workspaces/{wid}/time_entries", payload, query={"meta": "true"}),
                       dict, "created entry")

    def update(self, wid: int, entry_id: int, body: dict) -> dict:
        return _expect(self.request("PUT", f"/workspaces/{wid}/time_entries/{entry_id}", body,
                                    query={"meta": "true"}), dict, "updated entry")

    def stop(self, wid: int, entry_id: int) -> dict | None:
        try:
            return _expect(self.request("PATCH", f"/workspaces/{wid}/time_entries/{entry_id}/stop"),
                           dict, "stopped entry", allow_none=True)
        except Conflict:
            return None

    def delete(self, wid: int, entry_id: int) -> None:
        self.request("DELETE", f"/workspaces/{wid}/time_entries/{entry_id}")


def _expect(value: Any, kind: type, what: str, allow_none: bool = False) -> Any:
    if value is None and allow_none:
        return None
    if not isinstance(value, kind):
        raise ApiError(f"unexpected response from Toggl for {what}")
    return value


def _error_text(err: urllib.error.HTTPError, deadline: float, monotonic: Callable[[], float]) -> str:
    """A short message from the error body: at most MAX_ERROR_BODY bytes are read
    (and never past the deadline), then trimmed to 300 characters."""
    chunks: list[bytes] = []
    total = 0
    try:
        while total < MAX_ERROR_BODY and monotonic() <= deadline:
            chunk = err.read(min(CHUNK, MAX_ERROR_BODY - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
    except Exception:  # noqa: BLE001 - best effort diagnostics only
        pass
    text = b"".join(chunks).decode(errors="replace").strip()
    if text.startswith('"') and text.endswith('"'):
        text = text[1:-1]
    return text[:300]
