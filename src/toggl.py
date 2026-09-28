#!/usr/bin/env python3
"""Entry point: ``python3 src/toggl.py <command>`` (see omarchy_toggl.cli)."""

import sys

# Never write __pycache__ into the installed plugin folder.
sys.dont_write_bytecode = True

from omarchy_toggl.cli import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main())
