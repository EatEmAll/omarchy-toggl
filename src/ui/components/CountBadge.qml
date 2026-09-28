import QtQuick
import qs.Commons

// Rounded square with a hairline border and a count ("[4]" in the web app).
Rectangle {
  id: root
  property int count: 0
  property bool expanded: false
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  signal clicked()

  width: Style.space(24)
  height: Style.space(24)
  radius: Math.max(Style.cornerRadius, Style.space(5))
  color: expanded ? Qt.rgba(accent.r, accent.g, accent.b, 0.14)
    : (mouse.containsMouse ? Qt.rgba(foreground.r, foreground.g, foreground.b, 0.08) : "transparent")
  border.width: Style.spacing.hairline
  border.color: expanded ? Qt.rgba(accent.r, accent.g, accent.b, 0.4) : Qt.rgba(foreground.r, foreground.g, foreground.b, 0.28)

  Text {
    textFormat: Text.PlainText
    anchors.centerIn: parent
    text: String(root.count)
    color: root.expanded ? root.accent : root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    font.bold: true
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}
