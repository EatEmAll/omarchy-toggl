"""Command line interface used by the QML service, keybindings, the menu and humans.

Every command prints exactly one JSON line (``--text`` prints a human line
instead) so the QML Backend can parse results uniformly:

    {"ok": true, "queued": false, "result": ..., "state": {...}}
    {"ok": false, "error": {"kind": ..., "message": ...}}
"""

from __future__ import annotations

import argparse
import getpass
import json
import sys
import time
from typing import Any

from . import __version__
from .api import Api, ApiError
from .parse import ParseError, parse
from .stats import hms
from .store import Store
from .sync import Engine, UsageError
from .timeutil import parse_when, parse_iso, now_utc, to_api
from .token import TokenError, clear_token, get_token, set_token, token_file

EXIT = {"usage": 2, "auth": 3, "quota": 4, "net": 5, "rate": 4}


def _emit(payload: dict[str, Any], text: str | None, as_text: bool) -> None:
    if as_text:
        print(text if text is not None else json.dumps(payload))
    else:
        sys.stdout.write(json.dumps(payload, separators=(",", ":"), ensure_ascii=False) + "\n")
    sys.stdout.flush()


def _fail(kind: str, message: str, as_text: bool, **extra: Any) -> int:
    _emit({"ok": False, "error": {"kind": kind, "message": message, **extra}}, f"error: {message}", as_text)
    return EXIT.get(kind, 1)


def _summary(state: dict[str, Any]) -> str:
    running = state.get("running")
    stats = state.get("stats") or {}
    today = (stats.get("today") or {}).get("total", 0)
    week = (stats.get("week") or {}).get("total", 0)
    live = 0
    parts = []
    if running:
        start = parse_iso(running.get("start"))
        live = int((now_utc() - start).total_seconds()) if start else 0
        label = running.get("description") or "(no description)"
        if running.get("projectName"):
            label += f" · {running['projectName']}"
        parts.append(f"● {label} {hms(live)}")
    else:
        parts.append("No timer running")
    parts.append(f"Today {hms(today + live)} · Week {hms(week + live)}")
    return "\n".join(parts)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="omarchy-toggl", description="Toggl Track for the Omarchy bar")
    p.add_argument("--text", action="store_true", help="print a human readable line instead of JSON")
    p.add_argument("--version", action="version", version=f"omarchy-toggl {__version__}")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("sync", help="fetch recent entries (quota aware)")
    s.add_argument("--force", action="store_true")
    s.add_argument("--meta", action="store_true", help="also refresh projects, tags and user info")
    s.add_argument("--history-days", type=int)
    s.add_argument("--workspace")

    s = sub.add_parser("range", help="fetch entries for a date range beyond the cache")
    s.add_argument("--from", dest="first", required=True)
    s.add_argument("--to", dest="last", required=True)
    s.add_argument("--force", action="store_true")

    sub.add_parser("status", help="print cached state (never touches the API)")

    s = sub.add_parser("start", help="start a timer; words accept @project #tag $")
    s.add_argument("words", nargs="*")
    s.add_argument("--project", help="project id or 'none'")
    s.add_argument("--tag", action="append", default=[])
    s.add_argument("--billable", action="store_true")
    s.add_argument("--at", help="start time (14:02, -15m, ISO)")

    s = sub.add_parser("add", help="add a finished entry")
    s.add_argument("words", nargs="*")
    s.add_argument("--start", required=True)
    s.add_argument("--stop", required=True)
    s.add_argument("--project", help="project id or 'none'")
    s.add_argument("--tag", action="append", default=[])
    s.add_argument("--billable", action="store_true")

    s = sub.add_parser("stop")
    s.add_argument("--at")

    s = sub.add_parser("continue")
    s.add_argument("entry_id", nargs="?")

    sub.add_parser("toggle", help="stop if running, else continue the last entry")

    s = sub.add_parser("duplicate")
    s.add_argument("entry_id")

    s = sub.add_parser("update")
    s.add_argument("entry_id")
    s.add_argument("--description")
    s.add_argument("--project", help="project id or 'none'")
    s.add_argument("--tags", help="comma separated tag names ('' clears)")
    b = s.add_mutually_exclusive_group()
    b.add_argument("--billable", dest="billable", action="store_true", default=None)
    b.add_argument("--no-billable", dest="billable", action="store_false")
    s.add_argument("--start")
    s.add_argument("--stop")

    s = sub.add_parser("delete")
    s.add_argument("entry_ids", nargs="+")

    s = sub.add_parser("idle-resolve")
    s.add_argument("--since", required=True)
    s.add_argument("--mode", choices=["keep", "discard", "discard-continue"], required=True)

    s = sub.add_parser("ui-set", help="store a UI bookkeeping value in ui.json")
    s.add_argument("key")
    s.add_argument("value", help="JSON value (null deletes)")

    s = sub.add_parser("auth")
    s.add_argument("action", choices=["login", "status", "logout"])
    s.add_argument("--stdin", action="store_true", help="read the token from stdin")

    sub.add_parser("doctor")
    return p


def _project_arg(value: str | None) -> tuple[bool, int | None]:
    if value is None:
        return False, None
    if value.strip().lower() in ("none", "", "0"):
        return True, None
    return True, int(value)


def main(argv: list[str] | None = None, engine: Engine | None = None) -> int:
    args = build_parser().parse_args(argv)
    as_text = args.text
    engine = engine or Engine()
    try:
        return _dispatch(args, engine, as_text)
    except UsageError as exc:
        return _fail("usage", str(exc), as_text, candidates=exc.candidates)
    except ParseError as exc:
        return _fail("usage", str(exc), as_text, candidates=exc.candidates)
    except TokenError as exc:
        return _fail("auth", str(exc), as_text)
    except ApiError as exc:
        extra = {}
        if getattr(exc, "resets_in", None) is not None:
            extra["resetsAt"] = int(time.time()) + int(exc.resets_in)
        return _fail(exc.kind, str(exc), as_text, **extra)
    except ValueError as exc:
        return _fail("usage", str(exc), as_text)


def _ok(out: dict[str, Any], as_text: bool, text: str | None = None) -> int:
    state = out.get("state") or {}
    payload = {"ok": True, "queued": bool(state.get("pending")), "result": out.get("result"), "state": state}
    _emit(payload, text if text is not None else _summary(state), as_text)
    return 0


def _dispatch(args: argparse.Namespace, engine: Engine, as_text: bool) -> int:
    cmd = args.cmd
    if cmd == "status":
        with engine.store.locked():
            state = engine.store.load()
        return _ok({"state": state}, as_text)
    if cmd == "sync":
        return _ok(engine.sync(force=args.force, meta=args.meta, history_days=args.history_days,
                               workspace=args.workspace), as_text)
    if cmd == "range":
        return _ok(engine.fetch_range(args.first, args.last, force=args.force), as_text)
    if cmd == "start":
        with engine.store.locked():
            projects = engine.store.load().get("projects") or []
        quick = parse(" ".join(args.words), projects)
        project_set, project_id = _project_arg(args.project)
        tags = quick.tags + [t for t in args.tag if t not in quick.tags]
        at = parse_when(args.at) if args.at else None
        return _ok(engine.start(quick.description, project_id if project_set else quick.project_id,
                                tags, bool(args.billable or quick.billable), at), as_text)
    if cmd == "add":
        with engine.store.locked():
            projects = engine.store.load().get("projects") or []
        quick = parse(" ".join(args.words), projects)
        project_set, project_id = _project_arg(args.project)
        tags = quick.tags + [t for t in args.tag if t not in quick.tags]
        return _ok(engine.add(quick.description, project_id if project_set else quick.project_id, tags,
                              bool(args.billable or quick.billable), parse_when(args.start), parse_when(args.stop)),
                   as_text)
    if cmd == "stop":
        return _ok(engine.stop(parse_when(args.at) if args.at else None), as_text)
    if cmd == "continue":
        return _ok(engine.continue_entry(args.entry_id), as_text)
    if cmd == "toggle":
        return _ok(engine.toggle(), as_text)
    if cmd == "duplicate":
        return _ok(engine.duplicate(args.entry_id), as_text)
    if cmd == "update":
        fields: dict[str, Any] = {}
        if args.description is not None:
            fields["description"] = args.description
        project_set, project_id = _project_arg(args.project)
        if project_set:
            fields["projectId"] = project_id
        if args.tags is not None:
            fields["tags"] = [t.strip() for t in args.tags.split(",") if t.strip()]
        if args.billable is not None:
            fields["billable"] = args.billable
        if args.start:
            fields["start"] = to_api(parse_when(args.start))
        if args.stop:
            fields["stop"] = to_api(parse_when(args.stop))
        if not fields:
            raise UsageError("nothing to update")
        return _ok(engine.update(args.entry_id, fields), as_text)
    if cmd == "delete":
        return _ok(engine.delete(args.entry_ids), as_text)
    if cmd == "idle-resolve":
        return _ok(engine.idle_resolve(parse_when(args.since), args.mode), as_text)
    if cmd == "ui-set":
        value = json.loads(args.value)
        with engine.store.locked():
            ui = engine.store.load_ui()
            if value is None:
                ui.pop(args.key, None)
            else:
                ui[args.key] = value
            engine.store.save_ui(ui)
        _emit({"ok": True, "ui": ui}, "ok", as_text)
        return 0
    if cmd == "auth":
        return _auth(args, engine, as_text)
    if cmd == "doctor":
        return _doctor(engine, as_text)
    raise UsageError(f"unknown command {cmd}")


def _auth(args: argparse.Namespace, engine: Engine, as_text: bool) -> int:
    if args.action == "logout":
        clear_token()
        with engine.store.locked():
            state = engine.store.load()
            state["auth"] = {"ok": False, "source": None, "user": None, "workspaceId": None, "workspaces": []}
            state.update({"running": None, "entries": [], "ranges": {}, "projects": [], "tags": [],
                          "stats": {}, "pending": [], "lastSyncAt": None, "lastMetaSyncAt": None,
                          "error": None})
            engine.store.save(state)
        return _ok({"state": state}, as_text, "signed out")
    if args.action == "status":
        token, source = get_token()
        api = Api(token)
        me = api.me()
        text = f"signed in as {me.get('fullname')} <{me.get('email')}> (token in {source})"
        _emit({"ok": True, "source": source, "user": {"fullname": me.get("fullname"), "email": me.get("email")}},
              text, as_text)
        return 0
    if args.stdin or not sys.stdin.isatty():
        token = sys.stdin.readline().strip()
    else:
        token = getpass.getpass("Toggl API token (track.toggl.com/profile): ").strip()
    Api(token).me()  # validate before storing; raises AuthError on a bad token
    source = set_token(token)
    engine._api = None
    out = engine.sync(force=True, meta=True)
    return _ok(out, as_text, f"signed in (token stored in {source})")


def _doctor(engine: Engine, as_text: bool) -> int:
    info: dict[str, Any] = {"version": __version__, "python": sys.version.split()[0],
                            "stateFile": str(engine.store.path), "tokenFile": str(token_file())}
    try:
        _, info["tokenSource"] = get_token()
    except TokenError as exc:
        info["tokenSource"] = None
        info["tokenError"] = str(exc)
    with engine.store.locked():
        state = engine.store.load()
    info["lastSyncAgeSeconds"] = int(time.time() - state["lastSyncAt"]) if state.get("lastSyncAt") else None
    info["quota"] = state.get("quota")
    info["pending"] = len(state.get("pending") or [])
    info["error"] = state.get("error")
    info["auth"] = {k: v for k, v in (state.get("auth") or {}).items() if k != "workspaces"}
    lines = [f"{k}: {json.dumps(v)}" for k, v in info.items()]
    _emit({"ok": True, "doctor": info}, "\n".join(lines), as_text)
    return 0


__all__ = ["main", "parse_iso", "time"]
