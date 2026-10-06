"""The panel's explicit Sync actions must refresh project/tag metadata, not just
time entries. Projects, tags and user info are cached for META_TTL (12 h) and
were only refetched on that timer, so ``sync --force`` left a project created in
Toggl invisible in the ``@`` suggestions for hours."""

import re
import unittest
from pathlib import Path

PANEL = Path(__file__).resolve().parents[1] / "src" / "ui" / "Panel.qml"


class PanelRefreshMeta(unittest.TestCase):
    def test_no_explicit_sync_without_metadata(self):
        src = PANEL.read_text()
        bare = re.findall(r"\.refresh\(true\)", src)
        self.assertEqual(bare, [], "every explicit panel sync must pass meta=true")

    def test_explicit_sync_actions_request_metadata(self):
        src = PANEL.read_text()
        self.assertGreaterEqual(len(re.findall(r"\.refresh\(true,\s*true\)", src)), 3,
                                "the r key, sync button and retry banner must refresh metadata")


if __name__ == "__main__":
    unittest.main()
