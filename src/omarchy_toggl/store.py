"""The shared state file every writer (panel, keybindings, menu, terminal) updates.

The QML side watches ``state.json`` with a FileView, so writes must be atomic
(tmp + fsync + rename) and serialised across processes with ``flock``.
"""

from __future__ import annotations

import contextlib
import fcntl
import json
import os
from pathlib import Path
from typing import Any, Iterator

SCHEMA = 1
MAX_RANGES = 4


def cache_dir() -> Path:
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    return Path(base) / "omarchy-toggl"


def empty_state() -> dict[str, Any]:
    return {
        "schema": SCHEMA,
        "updatedAt": None,
        "lastSyncAt": None,
        "lastMetaSyncAt": None,
        "error": None,
        "config": {"historyDays": 7, "workspaceId": None},
        "auth": {"ok": False, "source": None, "user": None, "workspaceId": None, "workspaces": []},
        "running": None,
        "entries": [],
        "ranges": {},
        "projects": [],
        "tags": [],
        "stats": {},
        "quota": {},
        "pending": [],
    }


class Store:
    def __init__(self, directory: Path | None = None):
        self.dir = Path(directory) if directory else cache_dir()
        self.path = self.dir / "state.json"
        self.ui_path = self.dir / "ui.json"
        self.lock_path = self.dir / "state.lock"

    @contextlib.contextmanager
    def locked(self) -> Iterator[None]:
        _private_dir(self.dir)
        with open(self.lock_path, "a+") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(handle, fcntl.LOCK_UN)

    def load(self) -> dict[str, Any]:
        state = empty_state()
        try:
            data = json.loads(self.path.read_text())
        except (OSError, ValueError):
            return state
        if not isinstance(data, dict) or data.get("schema") != SCHEMA:
            return state
        state.update(data)
        return state

    def save(self, state: dict[str, Any]) -> None:
        _atomic_write(self.path, state)

    def load_ui(self) -> dict[str, Any]:
        try:
            data = json.loads(self.ui_path.read_text())
            return data if isinstance(data, dict) else {}
        except (OSError, ValueError):
            return {}

    def save_ui(self, data: dict[str, Any]) -> None:
        _atomic_write(self.ui_path, data)


def _private_dir(path: Path) -> None:
    """Create the cache folder readable only by the user (it holds time entries)."""
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        os.chmod(path, 0o700)
    except OSError:
        pass


def _atomic_write(path: Path, data: Any) -> None:
    _private_dir(path.parent)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as handle:
        json.dump(data, handle, separators=(",", ":"), ensure_ascii=False)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, path)


def remember_range(state: dict[str, Any], key: str, value: dict[str, Any]) -> None:
    ranges = dict(state.get("ranges") or {})
    ranges.pop(key, None)
    ranges[key] = value
    while len(ranges) > MAX_RANGES:
        oldest = min(ranges, key=lambda k: ranges[k].get("fetchedAt") or 0)
        ranges.pop(oldest)
    state["ranges"] = ranges
