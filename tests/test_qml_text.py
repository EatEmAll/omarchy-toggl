"""Text from the API or the user must never be interpreted as rich text: Qt's
default AutoText renders HTML and even fetches remote <img> URLs. Every QML
Text element in the plugin therefore sets textFormat: Text.PlainText."""

import re
import unittest
from pathlib import Path

SRC = Path(__file__).resolve().parents[1] / "src"
TEXT_OPEN = re.compile(r"(?<![A-Za-z.])Text \{\s*$")


class PlainTextOnly(unittest.TestCase):
    def test_every_text_element_is_plain_text(self):
        missing = []
        for qml in sorted(SRC.rglob("*.qml")):
            lines = qml.read_text().splitlines()
            for i, line in enumerate(lines):
                if TEXT_OPEN.search(line):
                    block = "\n".join(lines[i + 1:i + 4])
                    if "textFormat: Text.PlainText" not in block:
                        missing.append(f"{qml.relative_to(SRC)}:{i + 1}")
        self.assertEqual(missing, [], "Text without textFormat: Text.PlainText")

    def test_no_rich_text_anywhere(self):
        for qml in SRC.rglob("*.qml"):
            src = qml.read_text()
            self.assertNotRegex(src, r"Text\.(RichText|StyledText|AutoText|MarkdownText)", str(qml))


if __name__ == "__main__":
    unittest.main()
