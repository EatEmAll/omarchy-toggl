import QtQuick
import qs.Commons
import "../components"

// "[Calendar | List view | Timesheet]  [⚙] [◧]"
Item {
  id: root
  property var ctx: null
  readonly property var views: [
    { id: "calendar", label: "Calendar" },
    { id: "list", label: "List view" },
    { id: "timesheet", label: "Timesheet" }
  ]
  implicitHeight: Style.spacing.controlHeight + Style.space(4)

  Rectangle {
    id: group
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    width: parent.width - gear.width - compact.width - Style.spacing.md * 3
    height: parent.height
    radius: Math.max(Style.cornerRadius, Style.space(7))
    color: "transparent"
    border.width: Style.spacing.hairline
    border.color: Qt.rgba(ctx.foreground.r, ctx.foreground.g, ctx.foreground.b, 0.28)

    Row {
      anchors.fill: parent
      anchors.margins: Style.spacing.hairline
      Repeater {
        model: root.views
        delegate: Rectangle {
          required property var modelData
          required property int index
          readonly property bool selected: ctx.view === modelData.id && !ctx.showSettings
          width: parent.width / 3
          height: parent.height
          radius: Math.max(0, group.radius - 1)
          color: selected ? Qt.rgba(ctx.accent.r, ctx.accent.g, ctx.accent.b, 0.14)
            : (segMouse.containsMouse ? Qt.rgba(ctx.foreground.r, ctx.foreground.g, ctx.foreground.b, 0.05) : "transparent")
          border.width: selected ? Style.spacing.hairline : 0
          border.color: ctx.accent

          Rectangle {
            visible: index > 0 && !parent.selected && ctx.view !== root.views[index - 1].id
            width: Style.spacing.hairline
            height: parent.height - Style.spacing.md * 2
            anchors.verticalCenter: parent.verticalCenter
            color: Qt.rgba(ctx.foreground.r, ctx.foreground.g, ctx.foreground.b, 0.2)
          }
          Text {
            anchors.centerIn: parent
            text: modelData.label
            color: parent.selected ? ctx.foreground : Qt.rgba(ctx.foreground.r, ctx.foreground.g, ctx.foreground.b, 0.8)
            font.family: ctx.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
          MouseArea {
            id: segMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: ctx.setView(modelData.id)
          }
        }
      }
    }
  }

  IconToggle {
    id: gear
    anchors.right: compact.left
    anchors.rightMargin: Style.spacing.md
    anchors.verticalCenter: parent.verticalCenter
    icon: "󰒓"
    glyphSize: Style.font.title
    active: ctx.showSettings
    tooltip: "Settings  ,"
    foreground: ctx.foreground
    accent: ctx.accent
    fontFamily: ctx.fontFamily
    onClicked: ctx.toggleSettings()
  }

  IconToggle {
    id: compact
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    icon: ctx.compact ? "󰞕" : "󰞖"
    glyphSize: Style.font.title
    active: ctx.compact
    tooltip: ctx.compact ? "Show summary  c" : "Compact  c"
    foreground: ctx.foreground
    accent: ctx.accent
    fontFamily: ctx.fontFamily
    onClicked: ctx.compact = !ctx.compact
  }
}
