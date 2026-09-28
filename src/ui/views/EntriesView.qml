import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui as Ui
import "../components"
import "../Model.js" as Model

// The web app's "List view": day groups with totals and checkboxes, collapsed
// similar entries with a count badge, two-line rows (description / ● project)
// and hover actions (tags, $, ▶, ⋮).
Item {
  id: root
  property var ctx: null
  readonly property var svc: ctx ? ctx.svc : null
  readonly property var rows: ctx ? ctx.rows : []
  property int selectedIndex: -1
  readonly property var selectedRow: selectedIndex >= 0 && selectedIndex < rows.length ? rows[selectedIndex] : null
  readonly property int checkedCount: Object.keys(ctx ? ctx.checked : {}).length
  readonly property bool searching: search.activeFocus

  function clampSelection() {
    if (selectedIndex >= rows.length) selectedIndex = rows.length - 1
  }
  onRowsChanged: clampSelection()

  function move(dy) {
    if (!rows.length) return
    var i = selectedIndex < 0 ? (dy > 0 ? -1 : rows.length) : selectedIndex
    do { i += dy } while (i >= 0 && i < rows.length && rows[i].kind === "day")
    if (i < 0 || i >= rows.length) return
    selectedIndex = i
    list.positionViewAtIndex(i, ListView.Contain)
  }

  function rowEntry(row) { return row ? row.entry : null }

  function continueRow(row) {
    if (!row || row.kind === "day") return
    if (row.running) svc.stop()
    else svc.continueEntry(row.entry.id)
  }

  function toggleGroup(row, open) {
    if (!row || row.kind !== "group") return
    var next = {}
    for (var k in ctx.expanded) next[k] = ctx.expanded[k]
    if (open === undefined ? !next[row.key] : open) next[row.key] = true
    else delete next[row.key]
    ctx.expanded = next
  }

  function idsOf(row) {
    if (!row) return []
    if (row.kind === "group" || row.kind === "day") return row.ids
    return row.running ? [] : [row.entry.id]
  }

  function toggleChecked(ids, on) {
    var next = {}
    for (var k in ctx.checked) next[k] = true
    for (var i = 0; i < ids.length; i++) {
      if (on) next[String(ids[i])] = true
      else delete next[String(ids[i])]
    }
    ctx.checked = next
  }

  function allChecked(ids) {
    if (!ids.length) return false
    for (var i = 0; i < ids.length; i++) if (!ctx.checked[String(ids[i])]) return false
    return true
  }

  function anyChecked(ids) {
    for (var i = 0; i < ids.length; i++) if (ctx.checked[String(ids[i])]) return true
    return false
  }

  function requestDelete(row) {
    var ids = idsOf(row)
    if (!ids.length) return
    var e = row.entry
    var msg = row.kind === "group"
      ? "Delete " + ids.length + " entries of '" + (e.description || "(no description)") + "' (" + Model.dayLabel(row.day, ctx.todayKey) + ")?"
      : "Delete '" + (e.description || "(no description)") + " · " + Model.hms(row.seconds) + "' (" + Model.dayLabel(row.day, ctx.todayKey) + " " + Model.clock(e.start) + ")?"
    ctx.askConfirm(msg, ids)
  }

  function menuFor(row) {
    var items = []
    if (row.running) items.push({ id: "stop", label: "Stop", icon: "󰓛", hint: "s" })
    else items.push({ id: "continue", label: "Continue", icon: "󰐊", hint: "↵" })
    if (row.kind === "group") items.push({ id: "expand", label: row.expanded ? "Collapse" : "Expand", icon: row.expanded ? "󰅀" : "󰅂", hint: row.expanded ? "h" : "l" })
    else items.push({ id: "edit", label: "Edit…", icon: "󰏫", hint: "e" })
    if (!row.running && row.kind !== "group") items.push({ id: "duplicate", label: "Duplicate", icon: "󰆏" })
    items.push({ id: "copy", label: "Copy description", icon: "󰆏" })
    if (!row.running) items.push({ id: "delete", label: row.kind === "group" ? "Delete " + row.count + " entries…" : "Delete…", icon: "󰆴", destructive: true, hint: "x" })
    return items
  }

  function openMenu(index) {
    var row = rows[index]
    if (!row || row.kind === "day") return
    selectedIndex = index
    var item = list.itemAtIndex(index)
    if (!item) return
    rowMenu.row = row
    rowMenu.items = menuFor(row)
    rowMenu.parent = item
    rowMenu.x = item.width - rowMenu.width - Style.spacing.md
    rowMenu.y = item.height - Style.spacing.md
    rowMenu.open()
  }

  function runMenu(id, row) {
    if (!row) return
    if (id === "continue" || id === "stop") continueRow(row)
    else if (id === "expand") toggleGroup(row)
    else if (id === "edit") ctx.openEditor(row.entry)
    else if (id === "duplicate") svc.duplicate(row.entry.id)
    else if (id === "copy") Util.execArgv(["wl-copy", "--", row.entry.description || ""])
    else if (id === "delete") requestDelete(row)
  }

  // Keyboard entry points used by Panel's key catcher.
  function keyActivate() { continueRow(selectedRow) }
  function keyEdit() { if (selectedRow && selectedRow.kind === "entry") ctx.openEditor(selectedRow.entry); else if (selectedRow) toggleGroup(selectedRow, true) }
  function keyDelete() { if (checkedCount) ctx.askConfirm("Delete " + checkedCount + " selected entries?", Object.keys(ctx.checked)); else requestDelete(selectedRow) }
  function keyMenu() { openMenu(selectedIndex) }
  function keyExpand(open) { toggleGroup(selectedRow, open) }
  function keyCheck() { var ids = idsOf(selectedRow); toggleChecked(ids, !allChecked(ids)) }
  function focusSearch() { searchBar.visible = true; search.forceActiveFocus() }

  // Search bar (opened with "/") --------------------------------------------
  Item {
    id: searchBar
    visible: ctx.query !== ""
    width: parent.width
    height: visible ? Style.spacing.controlHeight + Style.spacing.md : 0

    Ui.TextField {
      id: search
      width: parent.width
      placeholderText: "󰍉  Search description, project, tag…"
      text: ctx.query
      foreground: ctx.foreground
      accent: ctx.accent
      font.family: ctx.fontFamily
      font.pixelSize: Style.font.bodySmall
      onTextChanged: ctx.query = text
      onActiveFocusChanged: if (!activeFocus && text === "") searchBar.visible = Qt.binding(function() { return ctx.query !== "" })
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          if (text !== "") text = ""
          ctx.focusCatcher()
          event.accepted = true
        } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          ctx.focusCatcher()
          root.move(1)
          event.accepted = true
        }
      }
    }
  }

  ListView {
    id: list
    anchors.top: searchBar.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    clip: true
    model: root.rows
    boundsBehavior: Flickable.StopAtBounds
    reuseItems: true
    cacheBuffer: 400
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    delegate: Item {
      id: rowItem
      required property var modelData
      required property int index
      readonly property var row: modelData
      readonly property bool isDay: row.kind === "day"
      readonly property bool selected: index === root.selectedIndex
      readonly property bool hot: selected || rowMouse.containsMouse
      readonly property var entry: row.entry || null
      readonly property color tone: entry ? Model.projectColor(entry, Color.muted) : Color.muted
      readonly property var ids: root.idsOf(row)
      // Rows are rebuilt only when the state changes; the running entry and
      // its day total tick live on top of that snapshot.
      readonly property bool runningToday: isDay && !!(svc && svc.running) && Model.dayKey(Model.isoMs(svc.running.start)) === row.day
      readonly property int liveTotal: (row.total || 0) + (runningToday && svc.running ? svc.elapsed - Model.elapsedSec(svc.running.start, ctx.buildNow) : 0)
      readonly property int liveSeconds: row.running && svc ? svc.elapsed : (row.seconds || 0)
      width: ListView.view.width
      height: isDay ? Style.space(row.first ? 36 : 46) : Style.space(54)

      // ---- day header ---------------------------------------------------
      Item {
        anchors.fill: parent
        visible: rowItem.isDay

        Rectangle {
          visible: !row.first
          anchors.top: parent.top
          anchors.topMargin: Style.space(4)
          width: parent.width
          height: Math.max(2, Style.space(2))
          color: Qt.rgba(ctx.foreground.r, ctx.foreground.g, ctx.foreground.b, 0.12)
        }
        Row {
          anchors.left: parent.left
          anchors.leftMargin: Style.spacing.md
          anchors.bottom: parent.bottom
          anchors.bottomMargin: Style.space(8)
          spacing: Style.spacing.xl
          Checkbox {
            anchors.verticalCenter: parent.verticalCenter
            visible: rowItem.ids.length > 0
            checked: root.allChecked(rowItem.ids)
            partial: !checked && root.anyChecked(rowItem.ids)
            foreground: ctx.foreground
            accent: ctx.accent
            fontFamily: ctx.fontFamily
            onToggled: root.toggleChecked(rowItem.ids, !root.allChecked(rowItem.ids))
          }
          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: row.label || ""
            color: ctx.foreground
            font.family: ctx.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }
        }
        Text {
          textFormat: Text.PlainText
          anchors.right: parent.right
          anchors.rightMargin: Style.spacing.xl
          anchors.bottom: parent.bottom
          anchors.bottomMargin: Style.space(8)
          text: Model.hms(rowItem.liveTotal)
          color: ctx.foreground
          font.family: ctx.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          font.features: { "tnum": 1 }
        }
      }

      // ---- entry / group row ------------------------------------------
      Rectangle {
        anchors.fill: parent
        anchors.topMargin: Style.spacing.xxs
        anchors.bottomMargin: Style.spacing.xxs
        visible: !rowItem.isDay
        radius: Math.max(Style.cornerRadius, Style.space(6))
        color: rowItem.selected ? Qt.rgba(ctx.accent.r, ctx.accent.g, ctx.accent.b, 0.12)
          : (rowMouse.containsMouse ? Qt.rgba(ctx.foreground.r, ctx.foreground.g, ctx.foreground.b, 0.055) : "transparent")
        Behavior on color { ColorAnimation { duration: 90 } }

        Rectangle {
          visible: rowItem.selected
          width: Style.space(3)
          height: parent.height - Style.spacing.lg
          radius: width / 2
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          color: ctx.accent
        }

        MouseArea {
          id: rowMouse
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          onClicked: function(mouse) {
            root.selectedIndex = rowItem.index
            ctx.focusCatcher()
            if (mouse.button === Qt.RightButton) root.openMenu(rowItem.index)
          }
          onDoubleClicked: if (rowItem.row.kind === "entry" && !rowItem.row.running) ctx.openEditor(rowItem.entry)
        }

        // checkbox + badge column
        Row {
          id: lead
          anchors.left: parent.left
          anchors.leftMargin: Style.spacing.md + (rowItem.row.child ? Style.space(18) : 0)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.md
          Checkbox {
            anchors.verticalCenter: parent.verticalCenter
            opacity: (rowItem.hot || root.checkedCount > 0) && rowItem.ids.length ? 1 : 0
            enabled: rowItem.ids.length > 0
            checked: root.allChecked(rowItem.ids)
            foreground: ctx.foreground
            accent: ctx.accent
            fontFamily: ctx.fontFamily
            onToggled: root.toggleChecked(rowItem.ids, !root.allChecked(rowItem.ids))
          }
          Item {
            width: Style.space(24)
            height: Style.space(24)
            anchors.verticalCenter: parent.verticalCenter
            CountBadge {
              visible: rowItem.row.kind === "group"
              count: rowItem.row.count || 0
              expanded: !!rowItem.row.expanded
              foreground: ctx.foreground
              accent: ctx.accent
              fontFamily: ctx.fontFamily
              onClicked: root.toggleGroup(rowItem.row)
            }
            ProjectDot {
              visible: !!rowItem.row.running
              anchors.centerIn: parent
              dotColor: rowItem.tone
              size: Style.spaceReal(9)
              pulsing: true
            }
          }
        }

        // two text lines
        Column {
          id: texts
          anchors.left: lead.right
          anchors.leftMargin: Style.spacing.lg
          anchors.right: trail.left
          anchors.rightMargin: Style.spacing.md
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.xxs

          Row {
            width: parent.width
            spacing: Style.spacing.md
            Text {
              textFormat: Text.PlainText
              width: Math.min(implicitWidth, parent.width - indicators.width - parent.spacing)
              text: rowItem.entry ? (rowItem.entry.description || "(no description)") : ""
              color: rowItem.entry && rowItem.entry.description ? ctx.foreground : Color.muted
              font.family: ctx.fontFamily
              font.pixelSize: Style.font.body
              font.bold: !!rowItem.row.running
              elide: Text.ElideRight
            }
            Row {
              id: indicators
              spacing: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              visible: rowItem.hot && rowItem.entry
              Text {
                textFormat: Text.PlainText
                text: "󰓹"
                visible: rowItem.entry && (rowItem.entry.tags || []).length > 0 || rowItem.hot
                color: rowItem.entry && (rowItem.entry.tags || []).length ? ctx.accent : Color.muted
                font.family: ctx.fontFamily
                font.pixelSize: Style.font.caption
                Ui.PanelToolTip {
                  visible: tagHover.hovered && rowItem.entry && (rowItem.entry.tags || []).length > 0
                  text: rowItem.entry ? (rowItem.entry.tags || []).join(", ") : ""
                }
                HoverHandler { id: tagHover }
              }
              Text {
                textFormat: Text.PlainText
                text: "$"
                color: rowItem.entry && rowItem.entry.billable ? ctx.accent : Color.muted
                font.family: ctx.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }
          }
          Row {
            width: parent.width
            spacing: Style.spacing.sm
            ProjectDot {
              anchors.verticalCenter: parent.verticalCenter
              dotColor: rowItem.tone
              visible: rowItem.entry && !!rowItem.entry.projectId
            }
            Text {
              textFormat: Text.PlainText
              width: parent.width - Style.space(12)
              text: {
                var e = rowItem.entry
                if (!e) return ""
                var parts = []
                if (e.projectId) parts.push(e.projectName || "Project")
                else parts.push("No project")
                var extra = []
                if (e.clientName) extra.push(e.clientName)
                if (rowItem.row.child || rowItem.row.running) extra.push(Model.clock(e.start) + "–" + (e.stop ? Model.clock(e.stop) : "now"))
                return parts.join("") + (extra.length ? "  ·  " + extra.join(" · ") : "")
              }
              color: rowItem.entry && rowItem.entry.projectId ? Qt.lighter(rowItem.tone, 1.2) : Color.muted
              font.family: ctx.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }
          }
        }

        // duration + actions
        Column {
          id: trail
          anchors.right: parent.right
          anchors.rightMargin: Style.spacing.xl
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.xxs
          Text {
            textFormat: Text.PlainText
            anchors.right: parent.right
            text: Model.hms(rowItem.liveSeconds)
            color: ctx.foreground
            font.family: ctx.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            font.features: { "tnum": 1 }
          }
          Row {
            anchors.right: parent.right
            spacing: Style.spacing.xs
            opacity: rowItem.hot ? 1 : 0
            IconToggle {
              implicitWidth: Style.space(22)
              implicitHeight: Style.space(20)
              icon: rowItem.row.running ? "󰓛" : "󰐊"
              glyphSize: Style.font.bodySmall
              idleColor: ctx.foreground
              tooltip: rowItem.row.running ? "Stop" : "Continue"
              foreground: ctx.foreground
              accent: ctx.accent
              fontFamily: ctx.fontFamily
              onClicked: root.continueRow(rowItem.row)
            }
            IconToggle {
              implicitWidth: Style.space(22)
              implicitHeight: Style.space(20)
              icon: "⋮"
              glyphSize: Style.font.body
              idleColor: ctx.foreground
              tooltip: "More  m"
              foreground: ctx.foreground
              accent: ctx.accent
              fontFamily: ctx.fontFamily
              onClicked: root.openMenu(rowItem.index)
            }
          }
        }
      }
    }

    footer: Item {
      width: ListView.view ? ListView.view.width : 0
      height: Style.space(40)
      visible: root.rows.length > 0
      Text {
        textFormat: Text.PlainText
        anchors.centerIn: parent
        text: "Older entries → Open Toggl ↗"
        color: Color.muted
        font.family: ctx.fontFamily
        font.pixelSize: Style.font.caption
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: { Util.execArgv(["xdg-open", "https://track.toggl.com/timer"]); ctx.close() }
        }
      }
    }
  }

  EmptyState {
    visible: root.rows.length === 0 && ctx.bodyReady
    anchors.centerIn: parent
    width: parent.width - Style.space(40)
    icon: ctx.query || ctx.projectFilter ? "󰍉" : "󱎫"
    title: ctx.query || ctx.projectFilter ? "No matching entries" : "No entries in this range"
    detail: ctx.query || ctx.projectFilter ? "Clear the search or project filter" : "Start a timer above, or pick another range"
    foreground: ctx.foreground
    accent: ctx.accent
    fontFamily: ctx.fontFamily
  }

  RowMenu {
    id: rowMenu
    property var row: null
    foreground: ctx.foreground
    accent: ctx.accent
    fontFamily: ctx.fontFamily
    onChosen: function(id) { root.runMenu(id, rowMenu.row) }
    onClosed: ctx.focusCatcher()
  }
}
