import QtQuick
import qs.Commons
import "../Model.js" as Model

// "TODAY 3:23:38    WEEK TOTAL 60:49:24" (live, includes the running entry).
Row {
  id: root
  property var ctx: null
  readonly property var svc: ctx ? ctx.svc : null
  spacing: Style.spacing.xxxl * 2
  height: Style.space(22)

  Repeater {
    model: [
      { label: "TODAY", value: root.svc ? Model.hms(root.svc.todayStats.total) : "0:00:00", view: "list" },
      { label: "WEEK TOTAL", value: root.svc ? Model.hms(root.svc.weekStats.total) : "0:00:00", view: "timesheet" }
    ]
    delegate: Row {
      required property var modelData
      spacing: Style.spacing.lg
      anchors.verticalCenter: parent.verticalCenter
      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        text: modelData.label
        color: Color.muted
        font.family: ctx.fontFamily
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1
      }
      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        text: modelData.value
        color: ctx.foreground
        font.family: ctx.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        font.features: { "tnum": 1 }
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            if (modelData.view === "timesheet") ctx.jumpTo("timesheet", "week", ctx.todayKey)
            else ctx.jumpTo("list", "day", ctx.todayKey)
          }
        }
      }
    }
  }
}
