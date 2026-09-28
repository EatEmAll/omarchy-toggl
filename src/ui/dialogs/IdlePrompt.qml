import QtQuick
import qs.Commons
import "../components"
import "../Model.js" as Model

// "You were away 14 min (13:48 – 14:02) while tracking ● Research · stonks"
Rectangle {
  id: root
  property var ctx: null
  readonly property var prompt: ctx && ctx.svc ? ctx.svc.idlePrompt : null
  visible: !!prompt
  implicitHeight: col.implicitHeight + Style.spacing.xl * 2
  radius: Math.max(Style.cornerRadius, Style.space(10))
  color: Color.popups.background
  border.width: Style.normalBorderWidth
  border.color: Qt.rgba(ctx.accent.r, ctx.accent.g, ctx.accent.b, 0.5)

  function resolve(mode) { if (ctx && ctx.svc) ctx.svc.resolveIdle(mode) }

  MouseArea { anchors.fill: parent }

  Column {
    id: col
    anchors.fill: parent
    anchors.margins: Style.spacing.xl
    spacing: Style.spacing.lg

    Row {
      spacing: Style.spacing.lg
      width: parent.width
      Text {
        textFormat: Text.PlainText
        text: "󰒲"
        color: ctx.accent
        font.family: ctx.fontFamily
        font.pixelSize: Style.font.display
        anchors.verticalCenter: parent.verticalCenter
      }
      Column {
        width: parent.width - Style.space(40)
        anchors.verticalCenter: parent.verticalCenter
        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: root.prompt
            ? (root.prompt.reason === "suspend" ? "Suspended " : "You were away ") + Math.round((root.prompt.until - root.prompt.since) / 60000)
              + " min (" + Model.clock(Model.toIso(root.prompt.since)) + " – " + Model.clock(Model.toIso(root.prompt.until)) + ")"
            : ""
          color: ctx.foreground
          font.family: ctx.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          wrapMode: Text.WordWrap
        }
        Row {
          spacing: Style.spacing.sm
          Text {
            textFormat: Text.PlainText
            text: "while tracking"
            color: Color.muted
            font.family: ctx.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          ProjectDot {
            anchors.verticalCenter: parent.verticalCenter
            dotColor: root.prompt && root.prompt.projectColor ? root.prompt.projectColor : Color.muted
          }
          Text {
            textFormat: Text.PlainText
            text: root.prompt ? root.prompt.description + (root.prompt.projectName ? " · " + root.prompt.projectName : "") : ""
            color: ctx.foreground
            font.family: ctx.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }
      }
    }
    Flow {
      width: parent.width
      spacing: Style.spacing.md
      ActionChip {
        text: "Esc  Keep time"
        foreground: ctx.foreground
        accent: ctx.accent
        fontFamily: ctx.fontFamily
        onClicked: root.resolve("keep")
      }
      ActionChip {
        text: "D  Discard idle time"
        selected: true
        foreground: ctx.foreground
        accent: ctx.accent
        fontFamily: ctx.fontFamily
        onClicked: root.resolve("discard-continue")
      }
      ActionChip {
        text: "S  Discard & stop"
        destructive: true
        foreground: ctx.foreground
        accent: ctx.accent
        fontFamily: ctx.fontFamily
        onClicked: root.resolve("discard")
      }
    }
  }
}
