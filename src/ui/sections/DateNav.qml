import QtQuick
import qs.Commons
import "../components"

// "[‹] [󰃭 All dates] [›]" range navigator.
Rectangle {
  id: root
  property var ctx: null
  readonly property bool canStep: ctx && ctx.rangeMode !== "all"

  implicitWidth: Style.space(250)
  implicitHeight: Style.spacing.controlHeight + Style.space(4)
  radius: Math.max(Style.cornerRadius, Style.space(7))
  color: "transparent"
  border.width: Style.spacing.hairline
  border.color: Qt.rgba(ctx.foreground.r, ctx.foreground.g, ctx.foreground.b, 0.16)

  Row {
    anchors.fill: parent

    Rectangle {
      width: Style.space(32)
      height: parent.height
      color: prevMouse.containsMouse && root.canStep ? Qt.rgba(ctx.foreground.r, ctx.foreground.g, ctx.foreground.b, 0.06) : "transparent"
      radius: root.radius
      Text {
        anchors.centerIn: parent
        text: "‹"
        color: root.canStep ? ctx.foreground : Color.muted
        opacity: root.canStep ? 1 : 0.4
        font.family: ctx.fontFamily
        font.pixelSize: Style.font.heading
      }
      MouseArea { id: prevMouse; anchors.fill: parent; hoverEnabled: true; enabled: root.canStep; cursorShape: Qt.PointingHandCursor; onClicked: ctx.stepRange(-1) }
    }

    Rectangle { width: Style.spacing.hairline; height: parent.height; color: Qt.rgba(ctx.foreground.r, ctx.foreground.g, ctx.foreground.b, 0.16) }

    Rectangle {
      width: parent.width - Style.space(64) - Style.spacing.hairline * 2
      height: parent.height
      color: midMouse.containsMouse ? Qt.rgba(ctx.foreground.r, ctx.foreground.g, ctx.foreground.b, 0.06) : "transparent"
      Row {
        anchors.centerIn: parent
        spacing: Style.spacing.md
        Text {
          text: ctx.rangeLoading ? "󰑓" : "󰃭"
          color: ctx.foreground
          font.family: ctx.fontFamily
          font.pixelSize: Style.font.body
          anchors.verticalCenter: parent.verticalCenter
          RotationAnimator on rotation { running: ctx.rangeLoading; from: 0; to: 360; duration: 900; loops: Animation.Infinite
            onRunningChanged: if (!running) parent.rotation = 0 }
        }
        Text {
          text: ctx.range.label
          color: ctx.foreground
          font.family: ctx.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          anchors.verticalCenter: parent.verticalCenter
        }
      }
      MouseArea { id: midMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: modeMenu.open() }

      RowMenu {
        id: modeMenu
        y: parent.height + Style.spacing.xs
        x: (parent.width - width) / 2
        foreground: ctx.foreground
        accent: ctx.accent
        fontFamily: ctx.fontFamily
        items: [
          { id: "all", label: "All dates", icon: "󰃭", hint: ctx.historyDays + "d" },
          { id: "today", label: "Today", icon: "󰃶", hint: "t" },
          { id: "yesterday", label: "Yesterday", icon: "󰃮" },
          { id: "week", label: "This week", icon: "󰸗" },
          { id: "lastweek", label: "Last week", icon: "󰸗" }
        ]
        onChosen: function(id) { ctx.pickRange(id) }
        onClosed: ctx.focusCatcher()
      }
    }

    Rectangle { width: Style.spacing.hairline; height: parent.height; color: Qt.rgba(ctx.foreground.r, ctx.foreground.g, ctx.foreground.b, 0.16) }

    Rectangle {
      width: Style.space(32)
      height: parent.height
      radius: root.radius
      color: nextMouse.containsMouse && root.canStep ? Qt.rgba(ctx.foreground.r, ctx.foreground.g, ctx.foreground.b, 0.06) : "transparent"
      Text {
        anchors.centerIn: parent
        text: "›"
        color: root.canStep ? ctx.foreground : Color.muted
        opacity: root.canStep ? 1 : 0.4
        font.family: ctx.fontFamily
        font.pixelSize: Style.font.heading
      }
      MouseArea { id: nextMouse; anchors.fill: parent; hoverEnabled: true; enabled: root.canStep; cursorShape: Qt.PointingHandCursor; onClicked: ctx.stepRange(1) }
    }
  }
}
