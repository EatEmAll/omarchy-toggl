import QtQuick
import qs.Commons

// Inline destructive confirmation (pattern from omarchy-stats ProcessesTab).
Rectangle {
  id: root
  property string message: ""
  property string confirmText: "Delete"
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  signal confirmed()
  signal canceled()

  implicitHeight: col.implicitHeight + Style.spacing.lg * 2
  radius: Math.max(Style.cornerRadius, Style.space(8))
  color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.10)
  border.width: Style.spacing.hairline
  border.color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.28)

  Column {
    id: col
    anchors.fill: parent
    anchors.margins: Style.spacing.lg
    spacing: Style.spacing.md

    Text {
      width: parent.width
      text: root.message
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }
    Row {
      spacing: Style.spacing.md
      ActionChip {
        text: root.confirmText + "  ↵"
        icon: "󰆴"
        destructive: true
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        onClicked: root.confirmed()
      }
      ActionChip {
        text: "Cancel  Esc"
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        onClicked: root.canceled()
      }
    }
  }
}
