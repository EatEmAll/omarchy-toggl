#!/usr/bin/env python3
"""Entry point: ``python3 src/toggl.py <command>`` (see omarchy_toggl.cli)."""

import sys

from omarchy_toggl.cli import main

if __name__ == "__main__":
    sys.exit(main())
