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

SERVICE_ATTRS = ["service", "omarchy-toggl", "account", "api-token"]
LABEL = "Toggl Track API token"


class TokenError(Exception):
    pass


def token_file() -> Path:
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return Path(base) / "omarchy-toggl" / "token"


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
    if not path.exists():
        return None
    mode = stat.S_IMODE(path.stat().st_mode)
    if mode & 0o077:
        raise TokenError(f"insecure token file {path} (mode {oct(mode)}); run: chmod 600 {path}")
    value = path.read_text().strip()
    return value or None


def _file_store(token: str) -> None:
    path = token_file()
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as handle:
        handle.write(token + "\n")
    os.chmod(path, 0o600)


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
        path = token_file()
        if path.exists():
            path.unlink()
        return "keyring"
    _file_store(token)
    return "file"


def clear_token() -> None:
    _keyring_clear()
    path = token_file()
    if path.exists():
        path.unlink()
