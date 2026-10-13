#!/usr/bin/env python3
"""Entry point: ``python3 src/toggl.py <command>`` (see omarchy_toggl.cli)."""

import sys

# Never write __pycache__ into the installed plugin folder.
sys.dont_write_bytecode = True


class _CappedStream:
    """stderr that stops after a fixed number of characters: the shell reads
    it whole, so even a pathological traceback stays small."""

    def __init__(self, stream, limit=64 * 1024):
        self._stream, self._left = stream, limit

    def write(self, text):
        if self._left > 0:
            part = text[: self._left]
            self._left -= len(part)
            self._stream.write(part)
        return len(text)

    def flush(self):
        self._stream.flush()

    def __getattr__(self, name):
        return getattr(self._stream, name)


sys.stderr = _CappedStream(sys.stderr)

from omarchy_toggl.cli import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main())
