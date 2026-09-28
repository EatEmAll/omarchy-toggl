"""The shared state file every writer (panel, keybindings, menu, terminal) updates.

The QML side watches ``state.json`` with a FileView, so writes must be atomic
(temp + fsync + rename) and serialised across processes with ``flock``. All
file access goes through :mod:`safefs`, which never follows symlinks, and the
lock is taken on the private folder's fd itself (no lock file).
"""

from __future__ import annotations

import contextlib
import fcntl
import json
import time
from pathlib import Path
from typing import Any, Iterator

from . import safefs

SCHEMA = 1
MAX_RANGES = 4
LOCK_WAIT = 60      # seconds to wait for another process holding the state lock


def cache_dir() -> Path:
    return safefs.xdg_dir("XDG_CACHE_HOME", ".cache") / "omarchy-toggl"


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

    @contextlib.contextmanager
    def locked(self) -> Iterator[None]:
        with safefs.private_dir(self.dir) as dirfd:
            waited_until = time.monotonic() + LOCK_WAIT
            while True:
                try:
                    fcntl.flock(dirfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() > waited_until:
                        raise TimeoutError("another omarchy-toggl process is still busy; try again") from None
                    time.sleep(0.05)
            try:
                yield
            finally:
                fcntl.flock(dirfd, fcntl.LOCK_UN)

    def _read(self, name: str) -> Any:
        """Parsed JSON, or None. A planted symlink/FIFO at the file is treated as
        missing (never followed) and replaced by the next atomic write; an unsafe
        folder raises."""
        with safefs.private_dir(self.dir, create=False) as dirfd:
            if dirfd is None:
                return None
            try:
                found = safefs.read_regular(dirfd, name, str(self.dir / name))
            except safefs.TooLarge as exc:
                # Never treat an oversized file as missing: the next write would
                # replace it (and any queued offline changes) with an empty state.
                raise OSError(f"{exc}; move it aside or delete it to start fresh") from None
            except OSError:
                return None
        if found is None:
            return None
        try:
            return json.loads(found[0].decode("utf-8"))
        except ValueError:
            return None

    def _write(self, name: str, data: Any) -> None:
        payload = json.dumps(data, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        with safefs.private_dir(self.dir) as dirfd:
            safefs.write_atomic(dirfd, name, payload)

    def load(self) -> dict[str, Any]:
        state = empty_state()
        data = self._read("state.json")
        if not isinstance(data, dict) or data.get("schema") != SCHEMA:
            return state
        state.update(data)
        return state

    def save(self, state: dict[str, Any]) -> None:
        self._write("state.json", state)

    def load_ui(self) -> dict[str, Any]:
        data = self._read("ui.json")
        return data if isinstance(data, dict) else {}

    def save_ui(self, data: dict[str, Any]) -> None:
        self._write("ui.json", data)


def remember_range(state: dict[str, Any], key: str, value: dict[str, Any]) -> None:
    ranges = dict(state.get("ranges") or {})
    ranges.pop(key, None)
    ranges[key] = value
    while len(ranges) > MAX_RANGES:
        oldest = min(ranges, key=lambda k: ranges[k].get("fetchedAt") or 0)
        ranges.pop(oldest)
    state["ranges"] = ranges
