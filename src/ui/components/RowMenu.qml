import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// Small popup action menu (the web app's ⋮ menu). items: [{id, label, icon, destructive, hint}]
Popup {
  id: root

  property var items: []
  property color foreground: Color.popups.text
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property int current: 0
  readonly property var popupBorderSpec: Border.localOrSurfaceSpec("popups", "border", Color.popups.border, Color.popups.border, Style.normalBorderWidth)

  signal chosen(string id)

  width: Style.space(190)
  height: items.length * Style.space(28) + padding * 2
  padding: Style.spacing.xs
  focus: true
  closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent

  background: BorderSurface {
    color: Color.popups.background
    borderSpec: root.popupBorderSpec
    radius: Style.cornerRadius
  }

  onOpened: { current = 0; menuKeys.forceActiveFocus() }

  contentItem: Item {
    id: menuKeys
    focus: true
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Down || event.text === "j") { root.current = Math.min(root.items.length - 1, root.current + 1); event.accepted = true }
      else if (event.key === Qt.Key_Up || event.text === "k") { root.current = Math.max(0, root.current - 1); event.accepted = true }
      else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
        var it = root.items[root.current]; root.close(); if (it) root.chosen(it.id); event.accepted = true
      }
      else if (event.key === Qt.Key_Escape) { root.close(); event.accepted = true }
    }

    Column {
      anchors.fill: parent
      Repeater {
        model: root.items
        delegate: Rectangle {
          id: menuRow
          required property var modelData
          required property int index
          width: parent.width
          height: Style.space(28)
          radius: Math.max(Style.cornerRadius, Style.space(5))
          readonly property color tone: modelData.destructive ? Color.urgent : root.foreground
          color: index === root.current || rowMouse.containsMouse
            ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.14) : "transparent"

          Row {
            anchors.fill: parent
            anchors.leftMargin: Style.spacing.lg
            anchors.rightMargin: Style.spacing.lg
            spacing: Style.spacing.lg
            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(14)
              text: modelData.icon || ""
              color: menuRow.tone
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - Style.space(14) - hint.width - parent.spacing * 2
              text: modelData.label
              color: menuRow.tone
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }
            Text {
              id: hint
              anchors.verticalCenter: parent.verticalCenter
              text: modelData.hint || ""
              color: Color.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
          MouseArea {
            id: rowMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { root.close(); root.chosen(modelData.id) }
          }
        }
      }
    }
  }
}
