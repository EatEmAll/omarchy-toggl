import QtQuick
import QtQuick.Controls
import qs.Commons
import "../components"
import "../Model.js" as Model

// Day timeline (the web app's Calendar): hour grid, entry blocks in project
// colours, a live "now" line; click a block to edit, empty space to add.
Flickable {
  id: root
  property var ctx: null
  readonly property real hourHeight: Style.space(48)
  readonly property real gutter: Style.space(40)
  readonly property string dayKey: ctx ? ctx.range.from : ""
  readonly property var blocks: ctx ? Model.dayBlocks(ctx.poolEntries, dayKey, ctx.svc ? ctx.svc.now : Date.now()) : []
  readonly property bool isToday: ctx && dayKey === ctx.todayKey

  clip: true
  contentHeight: hourHeight * 24 + Style.spacing.xl
  boundsBehavior: Flickable.StopAtBounds
  ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

  function scrollToStart() {
    var first = blocks.length ? blocks[0].startMin : 8 * 60
    if (isToday) first = Math.min(first, (new Date().getHours() - 1) * 60)
    contentY = Math.max(0, Math.min(contentHeight - height, (Math.max(0, first - 30) / 60) * hourHeight))
  }
  onDayKeyChanged: Qt.callLater(scrollToStart)
  Component.onCompleted: Qt.callLater(scrollToStart)

  Item {
    width: root.width
    height: root.hourHeight * 24

    Repeater {
      model: 24
      delegate: Item {
        required property int index
        y: index * root.hourHeight
        width: parent.width
        height: root.hourHeight
        Text {
          y: -height / 2
          width: root.gutter - Style.spacing.md
          horizontalAlignment: Text.AlignRight
          visible: index > 0
          text: (index < 10 ? "0" : "") + index + ":00"
          color: Color.muted
          font.family: ctx.fontFamily
          font.pixelSize: Style.font.caption
        }
        Rectangle {
          x: root.gutter
          width: parent.width - root.gutter
          height: Style.spacing.hairline
          color: Qt.rgba(ctx.foreground.r, ctx.foreground.g, ctx.foreground.b, 0.07)
        }
      }
    }

    MouseArea {
      x: root.gutter
      width: parent.width - root.gutter
      height: parent.height
      cursorShape: Qt.PointingHandCursor
      onClicked: function(mouse) {
        var minutes = Math.floor(mouse.y / root.hourHeight * 2) * 30
        var start = Model.keyMs(root.dayKey) + minutes * 60000
        if (start > Date.now()) return
        ctx.openCreator(start, Math.min(Date.now(), start + 30 * 60000))
      }
    }

    Repeater {
      model: root.blocks
      delegate: Rectangle {
        id: block
        required property var modelData
        readonly property color tone: Model.projectColor(modelData.entry, Color.muted)
        readonly property real laneWidth: (parent.width - root.gutter - Style.spacing.md) / modelData.lanes
        x: root.gutter + Style.spacing.xs + laneWidth * modelData.lane
        y: modelData.startMin / 60 * root.hourHeight
        width: laneWidth - Style.spacing.xs
        height: Math.max(Style.space(6), (modelData.endMin - modelData.startMin) / 60 * root.hourHeight - 1)
        radius: Math.max(Style.cornerRadius, Style.space(5))
        color: Qt.rgba(tone.r, tone.g, tone.b, blockMouse.containsMouse ? 0.4 : 0.28)
        clip: true

        Rectangle {
          width: Style.space(3)
          height: parent.height
          color: block.tone
          radius: parent.radius
        }
        Column {
          x: Style.spacing.lg
          y: Style.spacing.xs
          width: parent.width - Style.spacing.lg * 2
          visible: block.height > Style.space(16)
          Text {
            width: parent.width
            text: (modelData.entry.description || "(no description)")
            color: ctx.foreground
            font.family: ctx.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            elide: Text.ElideRight
          }
          Text {
            width: parent.width
            visible: block.height > Style.space(32)
            text: (modelData.entry.projectName || "No project") + " · " + Model.hm(modelData.seconds)
            color: Qt.lighter(block.tone, 1.3)
            font.family: ctx.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
        MouseArea {
          id: blockMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: if (!modelData.running) ctx.openEditor(modelData.entry)
        }
      }
    }

    Rectangle {
      visible: root.isToday
      x: root.gutter - Style.space(4)
      width: parent.width - root.gutter + Style.space(4)
      y: { var d = new Date(ctx.svc ? ctx.svc.now : Date.now()); return (d.getHours() * 60 + d.getMinutes()) / 60 * root.hourHeight }
      height: Math.max(1, Style.space(2))
      color: Color.urgent
      Rectangle {
        width: Style.space(8)
        height: width
        radius: width / 2
        color: Color.urgent
        anchors.verticalCenter: parent.verticalCenter
      }
    }
  }
}
