import QtQuick
import qs.Commons

Rectangle {
  id: root
  property bool checked: false
  property bool partial: false
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  signal toggled()

  width: Style.space(15)
  height: width
  radius: Math.max(2, Math.min(Style.cornerRadius, Style.space(4)))
  color: checked || partial ? accent : "transparent"
  border.width: Math.max(1, Style.spacing.hairline)
  border.color: checked || partial ? accent : Qt.rgba(foreground.r, foreground.g, foreground.b, mouse.containsMouse ? 0.6 : 0.35)

  Text {
    textFormat: Text.PlainText
    anchors.centerIn: parent
    visible: root.checked || root.partial
    text: root.checked ? "✓" : "–"
    color: Color.background
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    anchors.margins: -Style.space(4)
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.toggled()
  }
}
