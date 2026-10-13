"""Qt text inputs keep their paste state in sync with the system clipboard and
read foreign text without a size or time limit. The plugin therefore uses no
Qt text input at all: components/PlainField.qml draws its own text and pastes
through one bounded wl-paste. The panel content, the settings view, the entry
editor and the picker lists are additionally created only while shown. These
checks pin that structure."""

import re
import unittest
from pathlib import Path

UI = Path(__file__).resolve().parents[1] / "src" / "ui"
FIELD = re.compile(r"(?<![A-Za-z])(Ui\.)?(TextField|TextInput|TextEdit|TextArea|SpinBox|NumberField)\s*\{|QQC\.\w*(TextField|SpinBox)")


def src(rel):
    return (UI / rel).read_text()


class LazyInputs(unittest.TestCase):
    def test_no_qt_text_input_anywhere(self):
        found = []
        for qml in sorted(UI.parent.rglob("*.qml")):
            if FIELD.search(qml.read_text()):
                found.append(str(qml.relative_to(UI.parent)))
        self.assertEqual(found, [], "use components/PlainField.qml, never a Qt text input")

    def test_no_editable_combo_or_input_hint_properties(self):
        for qml in UI.parent.rglob("*.qml"):
            text = qml.read_text()
            self.assertNotRegex(text, r"editable:\s*true", str(qml))
            self.assertNotRegex(text, r"\bTextInput\.", str(qml))

    def test_paste_is_bounded(self):
        field = src("components/PlainField.qml")
        self.assertIn("timeout 2 wl-paste", field)
        self.assertIn("head -c", field)
        self.assertNotRegex(field, r"Clipboard|clipboard\.")

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
