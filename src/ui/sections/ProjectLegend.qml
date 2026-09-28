import QtQuick
import qs.Commons
import qs.Ui as Ui
import "../Model.js" as Model

// Coloured per-project share bar with labels above ("SNOWBALL  GENERIC  STONKS  FITNE…").
Item {
  id: root
  property var ctx: null
  property var segments: []
  readonly property real gap: Style.spacing.sm
  readonly property real usable: Math.max(0, width - gap * Math.max(0, segments.length - 1))

  implicitHeight: segments.length ? Style.space(26) : 0
  visible: segments.length > 0

  Row {
    anchors.fill: parent
    spacing: root.gap
    Repeater {
      model: root.segments
      delegate: Item {
        id: seg
        required property var modelData
        readonly property color tone: modelData.color ? modelData.color : Color.muted
        readonly property bool filtered: ctx.projectFilter !== "" && ctx.projectFilter !== modelData.key
        width: Math.max(Style.space(3), root.usable * modelData.share)
        height: parent.height
        opacity: filtered ? 0.35 : 1

        Text {
          textFormat: Text.PlainText
          width: parent.width
          anchors.top: parent.top
          visible: modelData.showLabel
          text: String(modelData.name).toUpperCase()
          color: seg.tone
          font.family: ctx.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          elide: Text.ElideRight
        }
        Rectangle {
          anchors.bottom: parent.bottom
          anchors.bottomMargin: Style.space(3)
          width: parent.width
          height: Style.space(4)
          radius: height / 2
          color: seg.tone
        }
        MouseArea {
          id: segMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: ctx.projectFilter = ctx.projectFilter === modelData.key ? "" : modelData.key
        }
        Ui.PanelToolTip {
          visible: segMouse.containsMouse
          text: modelData.name + " · " + Model.hm(modelData.seconds) + " (" + Math.round(modelData.share * 100) + "%)"
        }
      }
    }
  }
}
