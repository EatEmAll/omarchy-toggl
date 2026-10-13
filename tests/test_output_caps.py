"""The shell reads the CLI's stdout and stderr whole, so the CLI caps both."""

import io
import json
import runpy
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

from src.omarchy_toggl import cli

ROOT = Path(__file__).resolve().parents[1]


class OutputCaps(unittest.TestCase):
    def test_oversized_result_becomes_an_error(self):
        buf = io.StringIO()
        with mock.patch.object(cli, "MAX_OUTPUT", 100), redirect_stdout(buf):
            cli._emit({"ok": True, "state": {"x": "y" * 500}}, None, False)
        out = json.loads(buf.getvalue())
        self.assertFalse(out["ok"])
        self.assertEqual(out["error"]["message"], "result too large")

    def test_normal_result_is_unchanged(self):
        buf = io.StringIO()
        with redirect_stdout(buf):
            cli._emit({"ok": True, "n": 1}, None, False)
        self.assertEqual(json.loads(buf.getvalue()), {"ok": True, "n": 1})

    def test_stderr_is_capped(self):
        sys.path.insert(0, str(ROOT / "src"))
        try:
            ns = runpy.run_path(str(ROOT / "src" / "toggl.py"), run_name="not_main")
            sink = io.StringIO()
            capped = ns["_CappedStream"](sink, limit=10)
            capped.write("abcdef")
            capped.write("ghijklmnop")
            capped.write("more")
            self.assertEqual(sink.getvalue(), "abcdefghij")
        finally:
            sys.stderr = sys.__stderr__
            sys.path.remove(str(ROOT / "src"))


if __name__ == "__main__":
    unittest.main()
