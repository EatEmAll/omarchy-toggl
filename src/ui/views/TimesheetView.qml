import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui as Ui
import "../components"
import "../Model.js" as Model

// Project x weekday grid (the web app's Timesheet), plus per-day bars and totals.
Flickable {
  id: root
  property var ctx: null
  readonly property var sheet: Model.timesheet(ctx ? ctx.stats : null)
  readonly property real innerWidth: width - Style.spacing.md * 2 - Style.spacing.hairline * 2
  readonly property real totalWidth: Style.space(52)
  readonly property real dayWidth: Math.floor(Math.min(Style.space(40), (innerWidth - totalWidth - Style.space(84)) / Math.max(1, sheet.days.length)))
  readonly property real nameWidth: innerWidth - dayWidth * sheet.days.length - totalWidth

  clip: true
  contentHeight: body.implicitHeight + Style.spacing.xl
  boundsBehavior: Flickable.StopAtBounds
  ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

  function cellAlpha(v) { return sheet.max > 0 && v > 0 ? 0.08 + 0.32 * v / sheet.max : 0 }

  Column {
    id: body
    width: root.width
    spacing: Style.spacing.xl

    Item {
      width: parent.width
      height: Style.space(24)
      Text {
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: ctx.range.from ? Model.shortDate(ctx.range.from) + " – " + Model.shortDate(ctx.range.to) : ""
        color: ctx.foreground
        font.family: ctx.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }
      Text {
        textFormat: Text.PlainText
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: "Total  " + Model.hms(root.sheet.total)
        color: ctx.foreground
        font.family: ctx.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        font.features: { "tnum": 1 }
      }
    }

    // grid ----------------------------------------------------------------
    Rectangle {
      width: parent.width
      height: grid.implicitHeight + Style.spacing.md * 2
      radius: Math.max(Style.cornerRadius, Style.space(8))
      color: Qt.rgba(ctx.foreground.r, ctx.foreground.g, ctx.foreground.b, 0.028)
      border.width: Style.spacing.hairline
      border.color: Qt.rgba(ctx.foreground.r, ctx.foreground.g, ctx.foreground.b, 0.07)
      visible: root.sheet.days.length > 0

      Column {
        id: grid
        anchors.fill: parent
        anchors.margins: Style.spacing.md

        // header
        Rectangle {
          width: parent.width
          height: Style.space(28)
          radius: Math.max(Style.cornerRadius, Style.space(6))
          color: Qt.rgba(ctx.foreground.r, ctx.foreground.g, ctx.foreground.b, 0.045)
          Row {
            anchors.fill: parent
            Text {
              textFormat: Text.PlainText
              width: root.nameWidth
              leftPadding: Style.spacing.lg
              anchors.verticalCenter: parent.verticalCenter
              text: "PROJECT"
              color: Color.muted
              font.family: ctx.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            Repeater {
              model: root.sheet.days
              delegate: Rectangle {
                required property var modelData
                width: root.dayWidth
                height: parent.height
                color: modelData.date === ctx.todayKey ? Qt.rgba(ctx.accent.r, ctx.accent.g, ctx.accent.b, 0.12) : "transparent"
                radius: Style.space(4)
                Text {
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  text: Model.weekdayShort(modelData.date)
                  color: modelData.date === ctx.todayKey ? ctx.accent : Color.muted
                  font.family: ctx.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }
            }
            Text {
              textFormat: Text.PlainText
              width: root.totalWidth
              anchors.verticalCenter: parent.verticalCenter
              horizontalAlignment: Text.AlignRight
              rightPadding: Style.spacing.md
              text: "TOTAL"
              color: Color.muted
              font.family: ctx.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }
        }

        Repeater {
          model: root.sheet.rows
          delegate: Item {
            id: projRow
            required property var modelData
            readonly property color tone: modelData.color ? modelData.color : Color.muted
            width: grid.width
            height: Style.space(32)
            Row {
              anchors.fill: parent
              Row {
                width: root.nameWidth
                anchors.verticalCenter: parent.verticalCenter
                leftPadding: Style.spacing.lg
                spacing: Style.spacing.md
                ProjectDot { anchors.verticalCenter: parent.verticalCenter; dotColor: projRow.tone }
                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  width: root.nameWidth - Style.space(28)
                  text: modelData.name
                  color: Qt.lighter(projRow.tone, 1.2)
                  font.family: ctx.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  elide: Text.ElideRight
                }
              }
              Repeater {
                model: modelData.cells
                delegate: Rectangle {
                  required property var modelData
                  required property int index
                  width: root.dayWidth - Style.space(2)
                  height: Style.space(26)
                  anchors.verticalCenter: parent.verticalCenter
                  radius: Style.space(4)
                  readonly property color tone: projRow.tone
                  color: Qt.rgba(tone.r, tone.g, tone.b, root.cellAlpha(modelData))
                  Text {
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    text: Model.compactDuration(modelData)
                    color: modelData > 0 ? ctx.foreground : Color.muted
                    opacity: modelData > 0 ? 1 : 0.5
                    font.family: ctx.fontFamily
                    font.pixelSize: Style.font.caption
                    font.features: { "tnum": 1 }
                  }
                  MouseArea {
                    anchors.fill: parent
                    enabled: modelData > 0
                    cursorShape: Qt.PointingHandCursor
                    onClicked: ctx.drillDown(root.sheet.days[index].date, projRow.modelData.key)
                  }
                }
              }
              Text {
                textFormat: Text.PlainText
                width: root.totalWidth
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                rightPadding: Style.spacing.md
                text: Model.hm(modelData.total)
                color: ctx.foreground
                font.family: ctx.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                font.features: { "tnum": 1 }
              }
            }
          }
        }

        // totals row
        Rectangle { width: parent.width; height: Style.spacing.hairline; color: Qt.rgba(ctx.foreground.r, ctx.foreground.g, ctx.foreground.b, 0.1) }
        Row {
          height: Style.space(30)
          Text {
            textFormat: Text.PlainText
            width: root.nameWidth
            leftPadding: Style.spacing.lg
            anchors.verticalCenter: parent.verticalCenter
            text: "Total"
            color: ctx.foreground
            font.family: ctx.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
          Repeater {
            model: root.sheet.days
            delegate: Text {
              textFormat: Text.PlainText
              required property var modelData
              width: root.dayWidth
              anchors.verticalCenter: parent.verticalCenter
              horizontalAlignment: Text.AlignHCenter
              text: Model.compactDuration(modelData.seconds)
              color: modelData.seconds > 0 ? ctx.foreground : Color.muted
              font.family: ctx.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.features: { "tnum": 1 }
            }
          }
          Text {
            textFormat: Text.PlainText
            width: root.totalWidth
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignRight
            rightPadding: Style.spacing.md
            text: Model.hm(root.sheet.total)
            color: ctx.accent
            font.family: ctx.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
        }
      }
    }

    // by day bars -----------------------------------------------------------
    Column {
      width: parent.width
      spacing: Style.spacing.md
      visible: root.sheet.days.length > 1
      Text {
        textFormat: Text.PlainText
        text: "BY DAY"
        color: Color.muted
        font.family: ctx.fontFamily
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1
      }
      Row {
        id: bars
        width: parent.width
        height: Style.space(70)
        spacing: Style.spacing.md
        readonly property real maxDay: {
          var m = 0
          for (var i = 0; i < root.sheet.days.length; i++) m = Math.max(m, root.sheet.days[i].seconds)
          return m
        }
        Repeater {
          model: root.sheet.days
          delegate: Column {
            required property var modelData
            width: (bars.width - bars.spacing * (root.sheet.days.length - 1)) / Math.max(1, root.sheet.days.length)
            spacing: Style.spacing.xxs
            Item {
              width: parent.width
              height: Style.space(54)
              Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: bars.maxDay > 0 ? Math.max(modelData.seconds > 0 ? 2 : 0, parent.height * modelData.seconds / bars.maxDay) : 0
                radius: Math.min(Style.space(4), width / 2)
                color: modelData.date === ctx.todayKey ? ctx.accent : Qt.rgba(ctx.foreground.r, ctx.foreground.g, ctx.foreground.b, 0.3)
                Behavior on height { NumberAnimation { duration: 200 } }
              }
            }
            Text {
              textFormat: Text.PlainText
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: Model.weekdayShort(modelData.date)
              color: Color.muted
              font.family: ctx.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }

    // totals ---------------------------------------------------------------
    SurfaceCard {
      width: parent.width
      foreground: ctx.foreground
      accent: ctx.accent
      fontFamily: ctx.fontFamily
      padding: Style.spacing.xl
      contentSpacing: Style.spacing.md
      StatPair { width: parent.width; label: "Total"; value: Model.hms(ctx.stats.total); emphasize: true; foreground: ctx.foreground; fontFamily: ctx.fontFamily }
      StatPair { width: parent.width; label: "Billable"; value: Model.hms(ctx.stats.billable); foreground: ctx.foreground; fontFamily: ctx.fontFamily }
      StatPair { width: parent.width; label: "Entries"; value: String(ctx.stats.count); foreground: ctx.foreground; fontFamily: ctx.fontFamily }
      StatPair { width: parent.width; label: "Average per active day"; value: Model.hm(ctx.stats.avgPerDay); foreground: ctx.foreground; fontFamily: ctx.fontFamily }
    }
  }

  EmptyState {
    visible: root.sheet.rows.length === 0 && ctx.bodyReady
    y: Style.space(120)
    width: parent.width
    icon: "󰄧"
    title: "No time tracked"
    detail: "Nothing recorded in " + ctx.range.label.toLowerCase()
    foreground: ctx.foreground
    accent: ctx.accent
    fontFamily: ctx.fontFamily
  }
}
