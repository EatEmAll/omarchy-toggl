import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui as Ui

// Searchable list popup used for the project picker (single) and the tag
// picker (multi). Items: [{value, label, color, detail}].
Popup {
  id: root

  property var items: []
  property bool multi: false
  property var values: []
  property string value: ""
  property string placeholder: "Search…"
  property string emptyText: "No matches"
  property color foreground: Color.popups.text
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property var filtered: items
  readonly property var popupBorderSpec: Border.localOrSurfaceSpec("popups", "border", Color.popups.border, Color.popups.border, Style.normalBorderWidth)

  signal picked(string value)
  signal changedValues(var values)

  width: Style.space(250)
  height: Math.min(Style.space(320), search.height + Math.max(1, filtered.length) * Style.space(28) + Style.spacing.lg * 3)
  padding: Style.spacing.md
  focus: true
  modal: false
  closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent

  background: Ui.BorderSurface {
    color: Color.popups.background
    borderSpec: root.popupBorderSpec
    radius: Style.cornerRadius
  }

  function refilter() {
    var q = search.text.trim().toLowerCase()
    var out = []
    for (var i = 0; i < root.items.length; i++) {
      var it = root.items[i]
      if (!q || String(it.label).toLowerCase().indexOf(q) !== -1) out.push(it)
    }
    if (root.multi && q && !out.some(function(it) { return String(it.label).toLowerCase() === q }))
      out.push({ value: search.text.trim(), label: search.text.trim(), detail: "new tag", create: true })
    root.filtered = out
    list.currentIndex = out.length ? 0 : -1
  }

  function isChecked(v) { return root.values.indexOf(v) !== -1 }

  function activate(index) {
    var it = root.filtered[index]
    if (!it) return
    if (root.multi) {
      var next = root.values.slice()
      var at = next.indexOf(it.value)
      if (at === -1) next.push(it.value)
      else next.splice(at, 1)
      root.values = next
      root.changedValues(next)
      if (it.create) { search.text = ""; }
    } else {
      root.picked(String(it.value))
      root.close()
    }
  }

  onItemsChanged: refilter()
  onOpened: {
    search.text = ""
    refilter()
    search.forceActiveFocus()
  }

  contentItem: Column {
    spacing: Style.spacing.md

    Ui.TextField {
      id: search
      width: parent.width
      placeholderText: root.placeholder
      foreground: root.foreground
      accent: root.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      onTextChanged: root.refilter()
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Down) { list.incrementCurrentIndex(); event.accepted = true }
        else if (event.key === Qt.Key_Up) { list.decrementCurrentIndex(); event.accepted = true }
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.activate(list.currentIndex); event.accepted = true }
        else if (event.key === Qt.Key_Escape) { root.close(); event.accepted = true }
      }
    }

    ListView {
      id: list
      width: parent.width
      height: root.availableHeight - search.height - parent.spacing
      clip: true
      model: root.filtered
      boundsBehavior: Flickable.StopAtBounds
      highlightMoveDuration: 0
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      delegate: Rectangle {
        required property var modelData
        required property int index
        width: ListView.view.width
        height: Style.space(28)
        radius: Math.max(Style.cornerRadius, Style.space(5))
        color: ListView.isCurrentItem ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.14)
          : (rowMouse.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06) : "transparent")

        Row {
          anchors.fill: parent
          anchors.leftMargin: Style.spacing.lg
          anchors.rightMargin: Style.spacing.lg
          spacing: Style.spacing.lg

          Text {
            textFormat: Text.PlainText
            visible: root.multi
            anchors.verticalCenter: parent.verticalCenter
            text: root.isChecked(modelData.value) ? "󰄵" : "󰄱"
            color: root.isChecked(modelData.value) ? root.accent : Color.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
          ProjectDot {
            visible: !root.multi
            anchors.verticalCenter: parent.verticalCenter
            dotColor: modelData.color ? modelData.color : Color.muted
          }
          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - Style.space(90)
            text: modelData.label
            color: !root.multi && modelData.color ? modelData.color : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: !root.multi && String(modelData.value) === String(root.value)
            elide: Text.ElideRight
          }
          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.detail || ""
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
          onClicked: root.activate(index)
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: root.filtered.length === 0
        anchors.centerIn: parent
        text: root.emptyText
        color: Color.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
