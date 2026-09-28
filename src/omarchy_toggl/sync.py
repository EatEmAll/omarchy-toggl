"""Quota-aware sync and mutations against the shared state file.

Budget rules (Free plan: 30 ``/me`` requests per hour):
* a background sync is exactly one ``GET /me/time_entries`` call and is
  throttled (120 s, or 60 s when forced);
* metadata (``/me?with_related_data``) is refreshed at most every 12 h;
* mutations use ``/workspaces`` endpoints (separate quota) and merge the
  returned entry into the state; they never trigger a follow-up GET;
* when fewer than ``QUOTA_FLOOR`` calls remain, reads are skipped until reset.
"""

from __future__ import annotations

import time
from datetime import datetime, timedelta, timezone
from typing import Any, Callable

from . import stats as stats_mod
from .api import Api, ApiError, AuthError, Conflict, NetError, NotFound, QuotaError
from .store import Store, remember_range
from .timeutil import local_tz, now_utc, parse_iso, to_api
from .token import TokenError, get_token

UNFORCED_INTERVAL = 120
FORCED_INTERVAL = 60
META_TTL = 12 * 3600
QUOTA_FLOOR = 3
MAX_PENDING = 500          # offline changes kept for replay
MAX_DESCRIPTION = 3000     # Toggl's own description limit
MAX_TAGS = 50
MAX_TAG_LENGTH = 128


class UsageError(Exception):
    kind = "usage"

    def __init__(self, message: str, candidates: list[str] | None = None):
        super().__init__(message)
        self.candidates = candidates or []


# ------------------------------------------------------------------ helpers

def check_text(description: Any = None, tags: Any = None) -> None:
    """Bound user-supplied text (CLI, IPC, panel) before it reaches argv or the API."""
    if description is not None and len(str(description)) > MAX_DESCRIPTION:
        raise UsageError(f"description is longer than {MAX_DESCRIPTION} characters")
    if tags is not None:
        tags = list(tags)
        if len(tags) > MAX_TAGS or any(len(str(t)) > MAX_TAG_LENGTH for t in tags):
            raise UsageError(f"at most {MAX_TAGS} tags of up to {MAX_TAG_LENGTH} characters")


def normalize(raw: dict[str, Any]) -> dict[str, Any]:
    duration = raw.get("duration")
    stop = raw.get("stop")
    running = stop is None or (isinstance(duration, (int, float)) and duration < 0)
    seconds = None
    if not running:
        start_dt, stop_dt = parse_iso(raw.get("start")), parse_iso(stop)
        if isinstance(duration, (int, float)) and duration >= 0:
            seconds = int(duration)
        elif start_dt and stop_dt:
            seconds = int((stop_dt - start_dt).total_seconds())
    return {
        "id": raw.get("id"),
        "wid": raw.get("workspace_id") or raw.get("wid"),
        "description": raw.get("description") or "",
        "projectId": raw.get("project_id") or raw.get("pid"),
        "projectName": raw.get("project_name"),
        "projectColor": raw.get("project_color"),
        "clientName": raw.get("client_name"),
        "tags": list(raw.get("tags") or []),
        "tagIds": list(raw.get("tag_ids") or []),
        "billable": bool(raw.get("billable")),
        "start": _to_z(raw.get("start")),
        "stop": None if running else _to_z(stop),
        "seconds": seconds,
    }


def _to_z(value: Any) -> str | None:
    dt = parse_iso(value) if value else None
    return to_api(dt) if dt else None


def _enrich(entry: dict[str, Any], state: dict[str, Any]) -> dict[str, Any]:
    """Fill project name/colour from cached metadata when meta fields are absent."""
    pid = entry.get("projectId")
    if pid and (not entry.get("projectName") or not entry.get("projectColor")):
        for project in state.get("projects") or []:
            if project.get("id") == pid:
                entry["projectName"] = entry.get("projectName") or project.get("name")
                entry["projectColor"] = entry.get("projectColor") or project.get("color")
                entry["clientName"] = entry.get("clientName") or project.get("clientName")
                break
    if not pid:
        entry["projectName"] = None
        entry["projectColor"] = None
    return entry


def _sort(entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return sorted(entries, key=lambda e: e.get("start") or "", reverse=True)


def remove_entry(state: dict[str, Any], entry_id: Any) -> None:
    if state.get("running") and state["running"].get("id") == entry_id:
        state["running"] = None
    state["entries"] = [e for e in state.get("entries") or [] if e.get("id") != entry_id]
    for rng in (state.get("ranges") or {}).values():
        rng["entries"] = [e for e in rng.get("entries") or [] if e.get("id") != entry_id]


def apply_entry(state: dict[str, Any], entry: dict[str, Any]) -> dict[str, Any]:
    entry = _enrich(entry, state)
    remove_entry(state, entry.get("id"))
    if entry.get("stop") is None:
        state["running"] = entry
    else:
        state["entries"] = _sort((state.get("entries") or []) + [entry])
        for rng in (state.get("ranges") or {}).values():
            day = (entry.get("start") or "")[:10]
            if rng.get("from", "") <= day <= rng.get("to", ""):
                rng["entries"] = _sort((rng.get("entries") or []) + [entry])
    return entry


def find_entry(state: dict[str, Any], entry_id: Any) -> dict[str, Any] | None:
    if state.get("running") and str(state["running"].get("id")) == str(entry_id):
        return state["running"]
    pools = [state.get("entries") or []] + [r.get("entries") or [] for r in (state.get("ranges") or {}).values()]
    for pool in pools:
        for entry in pool:
            if str(entry.get("id")) == str(entry_id):
                return entry
    return None


def recompute(state: dict[str, Any]) -> None:
    user = (state.get("auth") or {}).get("user") or {}
    finished = [e for e in state.get("entries") or [] if e.get("stop")]
    state["stats"] = stats_mod.compute(finished, int(user.get("beginningOfWeek", 1) or 1))


def _merge_quota(state: dict[str, Any], api: Api) -> None:
    quota = dict(state.get("quota") or {})
    for bucket, values in api.quota.items():
        quota[bucket] = {**quota.get(bucket, {}), **values}
    state["quota"] = quota


def _error(exc: Exception, at: str) -> dict[str, Any]:
    out: dict[str, Any] = {"kind": getattr(exc, "kind", "error"), "message": str(exc), "at": at}
    resets = getattr(exc, "resets_in", None)
    if resets is not None:
        out["resetsAt"] = int(time.time()) + int(resets)
    candidates = getattr(exc, "candidates", None)
    if candidates:
        out["candidates"] = candidates
    return out


# ------------------------------------------------------------------- engine

class Engine:
    def __init__(self, store: Store | None = None, api_factory: Callable[[], tuple[Api, str]] | None = None,
                 clock: Callable[[], datetime] = now_utc):
        self.store = store or Store()
        self._api_factory = api_factory or _default_api
        self._api: Api | None = None
        self._source: str | None = None
        self.clock = clock

    # -- plumbing
    def api(self) -> Api:
        if self._api is None:
            self._api, self._source = self._api_factory()
        return self._api

    def _stamp(self) -> str:
        return to_api(self.clock())

    def _wid(self, state: dict[str, Any]) -> int:
        cfg = state.get("config") or {}
        wid = cfg.get("workspaceId") or (state.get("auth") or {}).get("workspaceId")
        if not wid:
            self._fetch_meta(state)
            wid = (state.get("auth") or {}).get("workspaceId")
        if not wid:
            raise UsageError("no Toggl workspace found")
        return int(wid)

    def _finish(self, state: dict[str, Any]) -> dict[str, Any]:
        if self._api is not None:
            _merge_quota(state, self._api)
        recompute(state)
        state["updatedAt"] = self._stamp()
        self.store.save(state)
        return state

    def transaction(self, fn: Callable[[dict[str, Any]], Any]) -> tuple[dict[str, Any], Any]:
        """Run ``fn(state)`` under the file lock and persist the state afterwards.

        ``fn`` may raise; the state (with any quota info gathered) is saved
        either way and the exception propagates to the CLI.
        """
        with self.store.locked():
            state = self.store.load()
            try:
                result = fn(state)
            except AuthError as exc:
                state["auth"] = {**(state.get("auth") or {}), "ok": False}
                state["error"] = _error(exc, self._stamp())
                self._finish(state)
                raise
            except TokenError as exc:
                state["auth"] = {**(state.get("auth") or {}), "ok": False, "source": None}
                state["error"] = {"kind": "auth", "message": str(exc), "at": self._stamp()}
                self._finish(state)
                raise
            except ApiError as exc:
                state["error"] = _error(exc, self._stamp())
                self._finish(state)
                raise
            except Exception:
                self._finish(state)
                raise
            self._finish(state)
            return state, result

    # -- metadata
    def _fetch_meta(self, state: dict[str, Any]) -> None:
        me = self.api().me(related=True) or {}
        cfg_wid = (state.get("config") or {}).get("workspaceId")
        workspaces = [{"id": w.get("id"), "name": w.get("name")} for w in me.get("workspaces") or []]
        clients = {c.get("id"): c.get("name") for c in me.get("clients") or []}
        state["auth"] = {
            "ok": True,
            "source": self._source,
            "user": {
                "fullname": me.get("fullname"),
                "email": me.get("email"),
                "timezone": me.get("timezone"),
                "beginningOfWeek": me.get("beginning_of_week", 1),
            },
            "workspaceId": int(cfg_wid) if cfg_wid else me.get("default_workspace_id"),
            "workspaces": workspaces,
        }
        wid = state["auth"]["workspaceId"]
        state["projects"] = sorted([
            {"id": p.get("id"), "name": p.get("name"), "color": p.get("color"),
             "active": p.get("active", True), "clientName": clients.get(p.get("client_id") or p.get("cid")),
             "wid": p.get("workspace_id") or p.get("wid")}
            for p in me.get("projects") or [] if not wid or (p.get("workspace_id") or p.get("wid")) == wid
        ], key=lambda p: str(p.get("name") or "").lower())
        state["tags"] = sorted([
            {"id": t.get("id"), "name": t.get("name")}
            for t in me.get("tags") or [] if not wid or (t.get("workspace_id") or t.get("wid")) == wid
        ], key=lambda t: str(t.get("name") or "").lower())
        state["lastMetaSyncAt"] = int(time.time())

    def _quota_low(self, state: dict[str, Any]) -> dict[str, Any] | None:
        user = (state.get("quota") or {}).get("user") or {}
        remaining, resets_at = user.get("remaining"), user.get("resetsAt")
        if remaining is not None and remaining <= QUOTA_FLOOR and resets_at and resets_at > time.time():
            return {"kind": "quota", "message": "Toggl API hourly limit nearly used; showing cached data",
                    "at": self._stamp(), "resetsAt": resets_at}
        return None

    # -- sync
    def sync(self, force: bool = False, meta: bool = False, history_days: int | None = None,
             workspace: str | None = None) -> dict[str, Any]:
        def run(state: dict[str, Any]) -> dict[str, Any]:
            cfg = dict(state.get("config") or {})
            if history_days:
                cfg["historyDays"] = max(1, min(90, int(history_days)))
            if workspace is not None:
                cfg["workspaceId"] = int(workspace) if str(workspace).strip() else None
            if cfg != state.get("config"):
                meta_needed = cfg.get("workspaceId") != (state.get("config") or {}).get("workspaceId")
                state["config"] = cfg
            else:
                meta_needed = False
            now = time.time()
            last = state.get("lastSyncAt") or 0
            interval = FORCED_INTERVAL if force else UNFORCED_INTERVAL
            if now - last < interval and not meta and not meta_needed and not state.get("pending") \
                    and (state.get("auth") or {}).get("ok"):
                return {"skipped": "throttled"}
            low = self._quota_low(state)
            if low:
                state["error"] = low
                return {"skipped": "quota"}
            self.api()
            self._replay(state)
            stale_meta = now - (state.get("lastMetaSyncAt") or 0) > META_TTL
            if meta or meta_needed or stale_meta or not (state.get("auth") or {}).get("ok"):
                self._fetch_meta(state)
            state["auth"]["source"] = self._source
            self._fetch_window(state)
            known = {p.get("id") for p in state.get("projects") or []}
            unknown = [e for e in state["entries"] if e.get("projectId") and e["projectId"] not in known]
            if unknown and not meta and not stale_meta:
                self._fetch_meta(state)
                for entry in state["entries"]:
                    _enrich(entry, state)
            state["lastSyncAt"] = int(now)
            state["error"] = None
            return {"synced": True}

        return self._guarded(run)

    def _fetch_window(self, state: dict[str, Any]) -> None:
        tz = local_tz()
        today = self.clock().astimezone(tz).date()
        days = int((state.get("config") or {}).get("historyDays") or 7)
        first = today - timedelta(days=days - 1)
        raw = self.api().entries(first.isoformat(), (today + timedelta(days=2)).isoformat())
        previous = state.get("running")
        running = None
        entries = []
        for item in raw if isinstance(raw, list) else []:
            if item.get("server_deleted_at") or item.get("deleted_at"):
                continue
            entry = _enrich(normalize(item), state)
            if entry["stop"] is None:
                running = entry
            else:
                entries.append(entry)
        if running is None and previous and previous.get("id") and previous["id"] > 0:
            started = parse_iso(previous.get("start"))
            if started and started.astimezone(tz).date() < first:
                current = self.api().current()
                if current:
                    running = _enrich(normalize(current), state)
        state["running"] = running
        state["entries"] = _sort(entries)

    def fetch_range(self, first: str, last: str, force: bool = False) -> dict[str, Any]:
        def run(state: dict[str, Any]) -> dict[str, Any]:
            key = f"{first}_{last}"
            cached = (state.get("ranges") or {}).get(key)
            if cached and not force and time.time() - (cached.get("fetchedAt") or 0) < 600:
                return {"skipped": "cached"}
            low = self._quota_low(state)
            if low:
                raise QuotaError(low["message"], 402, int(low["resetsAt"] - time.time()))
            end = (datetime.fromisoformat(last) + timedelta(days=1)).date().isoformat()
            raw = self.api().entries(first, end)
            entries = [_enrich(normalize(e), state) for e in raw or []
                       if e.get("stop") and not e.get("server_deleted_at")]
            remember_range(state, key, {"from": first, "to": last, "entries": _sort(entries),
                                        "fetchedAt": int(time.time())})
            return {"fetched": len(entries)}

        return self._guarded(run)

    # -- mutations
    def start(self, description: str = "", project_id: int | None = None, tags: list[str] | None = None,
              billable: bool = False, at: datetime | None = None) -> dict[str, Any]:
        check_text(description, tags)

        def run(state: dict[str, Any]) -> dict[str, Any]:
            when = at or self.clock()
            if state.get("running"):
                self._stop(state, at)
            body = {"description": description or "", "project_id": project_id, "tags": tags or [],
                    "billable": bool(billable), "start": to_api(when), "duration": -1}
            return self._create(state, body)

        return self._guarded(run)

    def continue_entry(self, entry_id: Any = None) -> dict[str, Any]:
        def run(state: dict[str, Any]) -> dict[str, Any]:
            source = find_entry(state, entry_id) if entry_id is not None else \
                next(iter(state.get("entries") or []), None)
            if not source:
                raise UsageError("nothing to continue")
            if state.get("running"):
                self._stop(state, None)
            body = {"description": source.get("description") or "", "project_id": source.get("projectId"),
                    "tags": source.get("tags") or [], "billable": bool(source.get("billable")),
                    "start": to_api(self.clock()), "duration": -1}
            return self._create(state, body)

        return self._guarded(run)

    def stop(self, at: datetime | None = None) -> dict[str, Any]:
        def run(state: dict[str, Any]) -> dict[str, Any]:
            if not state.get("running"):
                raise UsageError("no timer is running")
            return self._stop(state, at)

        return self._guarded(run)

    def toggle(self) -> dict[str, Any]:
        with self.store.locked():
            running = self.store.load().get("running")
        return self.stop() if running else self.continue_entry()

    def add(self, description: str, project_id: int | None, tags: list[str] | None, billable: bool,
            start: datetime, stop: datetime) -> dict[str, Any]:
        check_text(description, tags)

        def run(state: dict[str, Any]) -> dict[str, Any]:
            if stop <= start:
                raise UsageError("stop must be after start")
            if stop > self.clock() + timedelta(minutes=1):
                raise UsageError("stop time is in the future")
            body = {"description": description or "", "project_id": project_id, "tags": tags or [],
                    "billable": bool(billable), "start": to_api(start), "stop": to_api(stop),
                    "duration": int((stop - start).total_seconds())}
            return self._create(state, body)

        return self._guarded(run)

    def duplicate(self, entry_id: Any) -> dict[str, Any]:
        def run(state: dict[str, Any]) -> dict[str, Any]:
            source = find_entry(state, entry_id)
            if not source or not source.get("stop"):
                raise UsageError("only finished entries can be duplicated")
            start, stop = parse_iso(source["start"]), parse_iso(source["stop"])
            body = {"description": source.get("description") or "", "project_id": source.get("projectId"),
                    "tags": source.get("tags") or [], "billable": bool(source.get("billable")),
                    "start": to_api(start), "stop": to_api(stop),
                    "duration": int((stop - start).total_seconds())}
            return self._create(state, body)

        return self._guarded(run)

    def update(self, entry_id: Any, fields: dict[str, Any]) -> dict[str, Any]:
        check_text(fields.get("description"), fields.get("tags"))

        def run(state: dict[str, Any]) -> dict[str, Any]:
            entry = find_entry(state, entry_id)
            if not entry:
                raise UsageError(f"entry {entry_id} not found in cache")
            body = self._update_body(entry, fields)
            return self._update(state, entry, body)

        return self._guarded(run)

    def delete(self, entry_ids: list[Any]) -> dict[str, Any]:
        def run(state: dict[str, Any]) -> dict[str, Any]:
            done = []
            for entry_id in entry_ids:
                entry = find_entry(state, entry_id)
                wid = int((entry or {}).get("wid") or self._wid(state))
                eid = int(entry_id)
                if eid < 0:
                    state["pending"] = [p for p in state.get("pending") or [] if p.get("tempId") != eid]
                    remove_entry(state, eid)
                    done.append(eid)
                    continue
                try:
                    self.api().delete(wid, eid)
                except NotFound:
                    pass
                except NetError:
                    self._queue(state, {"op": "delete", "wid": wid, "id": eid})
                remove_entry(state, eid)
                done.append(eid)
            return {"deleted": done}

        return self._guarded(run)

    def idle_resolve(self, since: datetime, mode: str) -> dict[str, Any]:
        def run(state: dict[str, Any]) -> dict[str, Any]:
            running = state.get("running")
            if mode == "keep" or not running:
                return {"kept": True}
            start = parse_iso(running.get("start"))
            cut = max(since, start) if start else since
            copy = dict(running)
            self._stop(state, cut)
            if mode == "discard-continue":
                body = {"description": copy.get("description") or "", "project_id": copy.get("projectId"),
                        "tags": copy.get("tags") or [], "billable": bool(copy.get("billable")),
                        "start": to_api(self.clock()), "duration": -1}
                return self._create(state, body)
            return {"stoppedAt": to_api(cut)}

        return self._guarded(run)

    # -- mutation internals
    def _guarded(self, fn: Callable[[dict[str, Any]], Any]) -> dict[str, Any]:
        state, result = self.transaction(fn)
        return {"state": state, "result": result}

    def _queue(self, state: dict[str, Any], op: dict[str, Any]) -> None:
        if len(state.get("pending") or []) >= MAX_PENDING:
            raise NetError(f"offline queue is full ({MAX_PENDING} changes); reconnect to sync first")
        state["pending"] = (state.get("pending") or []) + [{**op, "queuedAt": self._stamp()}]
        state["error"] = {"kind": "net", "message": "Offline; changes are queued", "at": self._stamp()}

    def _create(self, state: dict[str, Any], body: dict[str, Any]) -> dict[str, Any]:
        wid = self._wid(state)
        try:
            raw = self.api().create(wid, body)
        except NetError:
            temp_id = -int(time.time() * 1000)
            self._queue(state, {"op": "create", "wid": wid, "body": body, "tempId": temp_id})
            fake = {**body, "id": temp_id, "workspace_id": wid, "stop": body.get("stop")}
            return apply_entry(state, normalize(fake))
        return apply_entry(state, normalize(raw))

    def _stop(self, state: dict[str, Any], at: datetime | None) -> dict[str, Any]:
        running = state["running"]
        wid = int(running.get("wid") or self._wid(state))
        if at is None:
            at = self.clock()
            use_patch = True
        else:
            use_patch = False
        start = parse_iso(running.get("start"))
        if start and at < start:
            raise UsageError("stop time is before the entry started")
        body = {"stop": to_api(at), "duration": int((at - start).total_seconds()) if start else None}
        if running["id"] < 0:
            self._queue(state, {"op": "update", "wid": wid, "id": running["id"], "body": body})
            return apply_entry(state, {**running, "stop": body["stop"], "seconds": body["duration"]})
        try:
            raw = self.api().stop(wid, running["id"]) if use_patch else self.api().update(wid, running["id"], body)
        except NetError:
            self._queue(state, {"op": "update", "wid": wid, "id": running["id"], "body": body})
            return apply_entry(state, {**running, "stop": body["stop"], "seconds": body["duration"]})
        if raw is None:  # 409: already stopped elsewhere
            remove_entry(state, running["id"])
            return {"alreadyStopped": True}
        return apply_entry(state, normalize(raw))

    def _update_body(self, entry: dict[str, Any], fields: dict[str, Any]) -> dict[str, Any]:
        body: dict[str, Any] = {}
        if "description" in fields:
            body["description"] = fields["description"] or ""
        if "projectId" in fields:
            body["project_id"] = fields["projectId"]
        if "tags" in fields:
            body["tags"] = list(fields["tags"] or [])
            body["tag_action"] = None
        if "billable" in fields:
            body["billable"] = bool(fields["billable"])
        start = parse_iso(fields["start"]) if fields.get("start") else parse_iso(entry.get("start"))
        stop = parse_iso(fields["stop"]) if fields.get("stop") else parse_iso(entry.get("stop"))
        if "start" in fields or "stop" in fields:
            now = self.clock()
            if start and start > now:
                raise UsageError("start time is in the future")
            if stop and stop > now + timedelta(minutes=1):
                raise UsageError("stop time is in the future")
            body["start"] = to_api(start)
            if entry.get("stop") is None and not fields.get("stop"):
                body["duration"] = -1
            else:
                if not stop or stop <= start:
                    raise UsageError("stop must be after start")
                body["stop"] = to_api(stop)
                body["duration"] = int((stop - start).total_seconds())
        body.pop("tag_action", None)
        return body

    def _update(self, state: dict[str, Any], entry: dict[str, Any], body: dict[str, Any]) -> dict[str, Any]:
        wid = int(entry.get("wid") or self._wid(state))
        optimistic = {**entry}
        if "description" in body:
            optimistic["description"] = body["description"]
        if "project_id" in body:
            optimistic["projectId"] = body["project_id"]
            optimistic["projectName"] = optimistic["projectColor"] = None
        if "tags" in body:
            optimistic["tags"] = body["tags"]
        if "billable" in body:
            optimistic["billable"] = body["billable"]
        if "start" in body:
            optimistic["start"] = body["start"]
        if "stop" in body:
            optimistic["stop"] = body["stop"]
            optimistic["seconds"] = body.get("duration")
        if int(entry["id"]) < 0:
            self._queue(state, {"op": "update", "wid": wid, "id": entry["id"], "body": body})
            return apply_entry(state, optimistic)
        try:
            raw = self.api().update(wid, int(entry["id"]), body)
        except NetError:
            self._queue(state, {"op": "update", "wid": wid, "id": entry["id"], "body": body})
            return apply_entry(state, optimistic)
        return apply_entry(state, normalize(raw))

    def _replay(self, state: dict[str, Any]) -> None:
        pending = list(state.get("pending") or [])
        if not pending:
            return
        mapping: dict[int, int] = {}
        remaining: list[dict[str, Any]] = []
        for index, op in enumerate(pending):
            eid = op.get("id")
            if isinstance(eid, int) and eid in mapping:
                eid = mapping[eid]
            try:
                if op["op"] == "create":
                    raw = self.api().create(op["wid"], op["body"])
                    mapping[op["tempId"]] = raw["id"]
                    remove_entry(state, op["tempId"])
                    apply_entry(state, normalize(raw))
                elif isinstance(eid, int) and eid < 0:
                    continue  # its create was dropped; nothing to apply
                elif op["op"] == "update":
                    raw = self.api().update(op["wid"], eid, op["body"])
                    apply_entry(state, normalize(raw))
                elif op["op"] == "delete":
                    self.api().delete(op["wid"], eid)
            except (NotFound, Conflict):
                continue
            except NetError:
                remaining = pending[index:]
                break
        state["pending"] = remaining
        if remaining:
            raise NetError("still offline; changes remain queued")


def _default_api() -> tuple[Api, str]:
    token, source = get_token()
    return Api(token), source


__all__ = ["Engine", "UsageError", "normalize", "apply_entry", "find_entry", "recompute", "ApiError",
           "timezone"]
