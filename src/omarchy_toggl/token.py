"""API token storage: libsecret keyring first, then a 0600 file, then env.

The token never passes through argv or the shell's QML scene: the panel pipes
it to ``auth login --stdin`` and only this module ever reads it back.
"""

from __future__ import annotations

import os
import shutil
import stat
import subprocess
from pathlib import Path

from . import safefs

SERVICE_ATTRS = ["service", "omarchy-toggl", "account", "api-token"]
LABEL = "Toggl Track API token"


class TokenError(Exception):
    pass


def token_file() -> Path:
    return safefs.xdg_dir("XDG_CONFIG_HOME", ".config") / "omarchy-toggl" / "token"


def _secret_tool() -> str | None:
    return shutil.which("secret-tool")


def _keyring_lookup() -> str | None:
    tool = _secret_tool()
    if not tool:
        return None
    try:
        proc = subprocess.run([tool, "lookup", *SERVICE_ATTRS], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return None
    value = proc.stdout.strip()
    return value if proc.returncode == 0 and value else None


def _keyring_store(token: str) -> bool:
    tool = _secret_tool()
    if not tool:
        return False
    try:
        proc = subprocess.run([tool, "store", f"--label={LABEL}", *SERVICE_ATTRS],
                              input=token, capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return proc.returncode == 0


def _keyring_clear() -> None:
    tool = _secret_tool()
    if tool:
        try:
            subprocess.run([tool, "clear", *SERVICE_ATTRS], capture_output=True, timeout=5)
        except (OSError, subprocess.TimeoutExpired):
            pass


def _file_lookup() -> str | None:
    path = token_file()
    try:
        with safefs.private_dir(path.parent, create=False) as dirfd:
            if dirfd is None:
                return None
            found = safefs.read_regular(dirfd, path.name, str(path), max_bytes=4096)
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
    if not token or any(ch.isspace() for ch in token):
        raise TokenError("token looks invalid")
    if _keyring_store(token) and _keyring_lookup() == token:
        _file_remove()
        return "keyring"
    _file_store(token)
    return "file"


def clear_token() -> None:
    _keyring_clear()
    _file_remove()
