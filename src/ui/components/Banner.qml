import QtQuick
import qs.Commons

// Tinted notice strip (quota, offline, backend errors).
Rectangle {
  id: root
  property string icon: "󰋼"
  property string text: ""
  property string actionText: ""
  property bool urgent: false
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  signal action()
  signal dismissed()

  readonly property color tone: urgent ? Color.urgent : accent

  implicitHeight: Math.max(Style.space(30), row.implicitHeight + Style.spacing.md * 2)
  radius: Math.max(Style.cornerRadius, Style.space(7))
  color: Qt.rgba(tone.r, tone.g, tone.b, 0.10)
  border.width: Style.spacing.hairline
  border.color: Qt.rgba(tone.r, tone.g, tone.b, 0.28)

  Row {
    id: row
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.spacing.xl
    anchors.rightMargin: Style.spacing.md
    spacing: Style.spacing.lg

    Text {
      id: glyph
      text: root.icon
      color: root.tone
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      anchors.verticalCenter: parent.verticalCenter
    }
    Text {
      width: parent.width - glyph.width - chip.width - parent.spacing * 2
      text: root.text
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
      maximumLineCount: 3
      elide: Text.ElideRight
      anchors.verticalCenter: parent.verticalCenter
    }
    ActionChip {
      id: chip
      visible: root.actionText !== ""
      width: visible ? implicitWidth : 0
      text: root.actionText
      foreground: root.foreground
      accent: root.accent
      fontFamily: root.fontFamily
      anchors.verticalCenter: parent.verticalCenter
      onClicked: root.action()
    }
  }
}
