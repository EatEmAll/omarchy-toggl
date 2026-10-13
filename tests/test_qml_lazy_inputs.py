"""Text inputs read the system clipboard whenever it changes (Qt keeps a
TextInput's canPaste up to date), so none may exist while the panel is
closed: the always-loaded bar widget must not host editable fields. The panel
content, the settings view, the entry editor and the picker lists are created
only while shown. These checks pin that structure."""

import re
import unittest
from pathlib import Path

UI = Path(__file__).resolve().parents[1] / "src" / "ui"
FIELD = re.compile(r"Ui\.TextField\s*\{|TextField\s*\{|TextInput\s*\{")


def src(rel):
    return (UI / rel).read_text()


class LazyInputs(unittest.TestCase):
    def test_panel_has_no_field_of_its_own(self):
        self.assertIsNone(FIELD.search(src("Panel.qml")))

    def test_panel_content_exists_only_while_the_popup_is_visible(self):
        panel = src("Panel.qml")
        m = re.search(r"Loader\s*\{\s*id: contentLoader\b(.*?)sourceComponent", panel, re.S)
        self.assertIsNotNone(m, "panel content must be behind contentLoader")
        self.assertRegex(m.group(1), r"active:\s*panel\.visible")
        # the whole layout lives inside that loader, after its sourceComponent
        self.assertGreater(panel.index("id: layout"), panel.index("id: contentLoader"))

    def test_settings_and_editor_are_created_on_demand(self):
        panel = src("Panel.qml")
        self.assertRegex(panel, r"id: settingsLoader[\s\S]*?active:\s*root\.showSettings[\s\S]*?sourceComponent:\s*SettingsView")
        self.assertRegex(panel, r"id: editorLoader[\s\S]*?active:\s*false[\s\S]*?sourceComponent:\s*EntryEditor")
        # never declared directly (that would create their fields up front)
        self.assertIsNone(re.search(r"^\s*(SettingsView|EntryEditor)\s*\{", panel, re.M))

    def test_picker_list_is_created_only_while_showing(self):
        picker = src("components/PickerPopup.qml")
        self.assertRegex(picker, r"contentItem:\s*Loader\s*\{[\s\S]*?active:\s*root\.visible")
        head = picker.split("contentItem:")[0]
        self.assertIsNone(FIELD.search(head))


if __name__ == "__main__":
    unittest.main()
