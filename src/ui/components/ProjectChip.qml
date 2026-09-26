import QtQuick
import qs.Commons
import "../Model.js" as Model

// Rounded project pill tinted with the project colour ("[● Ge…]").
Rectangle {
  id: root
  property string name: ""
  property string projectColor: ""
  property int maxChars: 12
  property bool placeholder: name === ""
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  signal clicked()

  readonly property color tone: projectColor ? projectColor : Color.muted

  implicitHeight: Style.space(26)
  implicitWidth: row.implicitWidth + Style.spacing.xl * 2
  radius: height / 2
  color: Qt.rgba(tone.r, tone.g, tone.b, mouse.containsMouse ? 0.24 : 0.16)
  border.width: placeholder ? Style.spacing.hairline : 0
  border.color: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.2)

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.spacing.sm
    ProjectDot {
      anchors.verticalCenter: parent.verticalCenter
      dotColor: root.tone
      visible: !root.placeholder
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: root.placeholder ? "󰉋" : Model.elide(root.name, root.maxChars)
      color: root.placeholder ? Color.muted : Qt.lighter(root.tone, 1.25)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: !root.placeholder
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}
