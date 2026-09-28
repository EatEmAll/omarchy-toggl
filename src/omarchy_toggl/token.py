"""API token storage: libsecret keyring first, then a 0600 file, then env.

The token never passes through argv or the shell's QML scene: the panel pipes
it to ``auth login --stdin`` and only this module ever reads it back.
"""

from __future__ import annotations

import os
import shutil
import signal
import stat
import subprocess
import threading
from pathlib import Path

from . import safefs

SERVICE_ATTRS = ["service", "omarchy-toggl", "account", "api-token"]
LABEL = "Toggl Track API token"
MAX_TOKEN = 4096            # Toggl tokens are 32 hex chars; anything near this is garbage


class TokenError(Exception):
    pass


def token_file() -> Path:
    return safefs.xdg_dir("XDG_CONFIG_HOME", ".config") / "omarchy-toggl" / "token"


def _secret_tool() -> str | None:
    return shutil.which("secret-tool")


def _capped_output(cmd: list[str], limit: int, timeout: float) -> bytes | None:
    """stdout of ``cmd``, reading at most ``limit`` bytes and killing its whole
    process group after ``timeout`` seconds; None on error, timeout or oversized output."""
    try:
        proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        return None

    def kill() -> None:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass

    timer = threading.Timer(timeout, kill)
    timer.start()
    try:
        data = proc.stdout.read(limit + 1) if proc.stdout else b""
    finally:
        timer.cancel()
        if proc.stdout:
            proc.stdout.close()
        if proc.poll() is None:
            kill()
        proc.wait()
    if proc.returncode != 0 or len(data) > limit:
        return None
    return data


def _keyring_lookup() -> str | None:
    tool = _secret_tool()
    if not tool:
        return None
    data = _capped_output([tool, "lookup", *SERVICE_ATTRS], MAX_TOKEN, timeout=5)
    value = data.decode("utf-8", errors="replace").strip() if data else ""
    return value or None


def _keyring_store(token: str) -> bool:
    tool = _secret_tool()
    if not tool:
        return False
    try:
        proc = subprocess.run([tool, "store", f"--label={LABEL}", *SERVICE_ATTRS], input=token, text=True,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return proc.returncode == 0


def _keyring_clear() -> None:
    tool = _secret_tool()
    if tool:
        try:
            subprocess.run([tool, "clear", *SERVICE_ATTRS], stdin=subprocess.DEVNULL,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
        except (OSError, subprocess.TimeoutExpired):
            pass


def _file_lookup() -> str | None:
    path = token_file()
    try:
        with safefs.private_dir(path.parent, create=False) as dirfd:
            if dirfd is None:
                return None
            found = safefs.read_regular(dirfd, path.name, str(path), max_bytes=MAX_TOKEN)
    except safefs.UnsafePath as exc:
        raise TokenError(f"{exc}; remove it and sign in again") from None
    if found is None:
        return None
    data, st = found
    if st.st_uid != os.getuid():
        raise TokenError(f"token file {path} is owned by another user")
    mode = stat.S_IMODE(st.st_mode)
    if mode & 0o077:
        raise TokenError(f"insecure token file {path} (mode {oct(mode)}); run: chmod 600 {path}")
    value = data.decode("utf-8", errors="replace").strip()
    return value or None


def _file_store(token: str) -> None:
    path = token_file()
    with safefs.private_dir(path.parent) as dirfd:
        safefs.write_atomic(dirfd, path.name, (token + "\n").encode("utf-8"))


def _file_remove() -> None:
    path = token_file()
    try:
        with safefs.private_dir(path.parent, create=False) as dirfd:
            if dirfd is not None:
                safefs.unlink(dirfd, path.name)
    except safefs.UnsafePath as exc:
        raise TokenError(str(exc)) from None


def get_token() -> tuple[str, str]:
    """Return ``(token, source)`` or raise TokenError when none is configured."""
    value = _keyring_lookup()
    if value:
        return value, "keyring"
    value = _file_lookup()
    if value:
        return value, "file"
    value = os.environ.get("TOGGL_API_TOKEN", "").strip()
    if value:
        return value, "env"
    raise TokenError("not signed in")


def set_token(token: str) -> str:
    token = token.strip()
    if not token or len(token) > MAX_TOKEN or any(ch.isspace() for ch in token):
        raise TokenError("token looks invalid")
    if _keyring_store(token) and _keyring_lookup() == token:
        _file_remove()
        return "keyring"
    _file_store(token)
    return "file"


def clear_token() -> None:
    _keyring_clear()
    _file_remove()
