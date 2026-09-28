"""File helpers that never write, chmod, lock or read *through* a path.

Every file the backend owns (``state.json``, ``ui.json``, ``token``) lives in a
private folder that is opened once with ``O_DIRECTORY|O_NOFOLLOW`` and
owner-checked; all further operations are relative to that directory fd:

* writes go to a fresh random ``O_CREAT|O_EXCL|O_NOFOLLOW`` 0600 temp file that
  is fsynced and ``rename``d over the target, so an existing symlink or hard
  link at the target (or at a temp name) is replaced, never written through;
* reads use ``O_NOFOLLOW|O_NONBLOCK`` and accept only regular files, so a
  planted symlink, FIFO or device can neither redirect nor hang a read;
* folder permissions are fixed with ``fchmod`` on the directory fd, never
  ``chmod`` by path.
"""

from __future__ import annotations

import contextlib
import errno
import os
import secrets
import stat
from pathlib import Path
from typing import Iterator

MAX_READ = 8 * 1024 * 1024


class UnsafePath(OSError):
    """A path we own is a symlink, owned by someone else, or not a regular file/folder."""


class TooLarge(OSError):
    """A file we own is larger than we are willing to read."""


def xdg_dir(var: str, fallback: str) -> Path:
    """$XDG_* value if absolute (relative values must be ignored per the spec)."""
    value = os.environ.get(var, "")
    if value and os.path.isabs(value):
        return Path(value)
    return Path(os.path.expanduser("~")) / fallback


def _check_dir(fd: int, path: Path) -> None:
    st = os.fstat(fd)
    if not stat.S_ISDIR(st.st_mode):
        raise UnsafePath(f"{path} is not a folder")
    if st.st_uid != os.getuid():
        raise UnsafePath(f"{path} is owned by another user")
    if stat.S_IMODE(st.st_mode) & 0o077:
        os.fchmod(fd, 0o700)


def _open_dir(path: Path) -> int:
    try:
        return os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError as exc:
        if exc.errno in (errno.ELOOP, errno.ENOTDIR):
            raise UnsafePath(f"{path} is a symlink or not a folder; refusing to use it") from None
        raise


@contextlib.contextmanager
def private_dir(path: Path, create: bool = True) -> Iterator[int | None]:
    """Yield an fd for our private folder (created 0700), or None if missing and not creating."""
    path = Path(path)
    if create:
        path.parent.mkdir(parents=True, exist_ok=True)
        try:
            os.mkdir(path, 0o700)
        except FileExistsError:
            pass
    try:
        fd = _open_dir(path)
    except FileNotFoundError:
        if create:
            raise
        yield None
        return
    try:
        _check_dir(fd, path)
        yield fd
    finally:
        os.close(fd)


def read_regular(dirfd: int, name: str, label: str = "", max_bytes: int = MAX_READ) -> tuple[bytes, os.stat_result] | None:
    """Read ``name`` in ``dirfd`` if it is a regular file; None if it does not exist."""
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=dirfd)
    except FileNotFoundError:
        return None
    except OSError as exc:
        if exc.errno == errno.ELOOP:
            raise UnsafePath(f"{label or name} is a symlink; refusing to read it") from None
        raise
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise UnsafePath(f"{label or name} is not a regular file")
        if st.st_size > max_bytes:
            raise TooLarge(f"{label or name} is unexpectedly large ({st.st_size} bytes)")
        chunks = []
        total = 0
        while True:                      # bounded even if the file grows after fstat
            chunk = os.read(fd, min(65536, max_bytes + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > max_bytes:
                raise TooLarge(f"{label or name} is unexpectedly large")
        return b"".join(chunks), st
    finally:
        os.close(fd)


def write_atomic(dirfd: int, name: str, data: bytes) -> None:
    """Replace ``name`` with ``data`` via a fresh random temp file + rename (never writes through)."""
    tmp = f".{name}.{secrets.token_hex(8)}.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=dirfd)
    try:
        try:
            view = memoryview(data)
            while view:
                view = view[os.write(fd, view):]
            os.fsync(fd)
        finally:
            os.close(fd)
        os.replace(tmp, name, src_dir_fd=dirfd, dst_dir_fd=dirfd)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp, dir_fd=dirfd)
        raise


def unlink(dirfd: int, name: str) -> None:
    """Remove ``name`` (a symlink is removed itself, never its target); missing is fine."""
    try:
        os.unlink(name, dir_fd=dirfd)
    except FileNotFoundError:
        pass
    except IsADirectoryError:
        raise UnsafePath(f"{name} is a folder; refusing to remove it") from None
