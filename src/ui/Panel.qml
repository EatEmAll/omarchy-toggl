import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "components"
import "sections"
import "views"
import "dialogs"

// The popout, laid out like the Toggl web app's narrow List view:
// TimerBar · TODAY/WEEK TOTAL · date nav · Calendar|List view|Timesheet + gear
// · project legend · body. Styling follows omarchy-stats.
Panel {
  id: root
  moduleName: "io.github.eatemall.toggl"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var svc: null
  readonly property var barIdentity: hostWidget || root

  readonly property color foreground: root.bar ? root.bar.barForeground : Color.foreground
  readonly property color accent: Color.accent
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  // View state ---------------------------------------------------------------
  property string view: svc ? String(svc.opt("defaultView")) : "list"
  property bool showSettings: false
  property bool compact: false
  property string rangeMode: "all"
  property string anchorKey: todayKey
  property string projectFilter: ""
  property string query: ""
  property var expanded: ({})
  property var checked: ({})
  property var confirm: null
  property double buildNow: Date.now()
  property var requestedRanges: ({})
  property bool rangeLoading: false
  property bool enterPressed: false

  readonly property string todayKey: svc ? svc.todayKey : Model.dayKey(Date.now())
  readonly property int historyDays: svc ? Number(svc.opt("historyDays")) : 7
  readonly property var snapshot: svc ? svc.snapshot : Model.emptyState()
  readonly property var range: Model.rangeFor(rangeMode, anchorKey, todayKey, historyDays, svc ? svc.beginningOfWeek : 1)
  readonly property var pool: Model.entriesFor(snapshot, range.from, range.to, todayKey)
  readonly property var poolEntries: pool.entries
  readonly property var stats: Model.rangeStats(poolEntries, range.from, range.to, buildNow, { projectFilter: projectFilter })
  readonly property var legendSegments: Model.legend(Model.rangeStats(poolEntries, range.from, range.to, buildNow), 0.07)
  readonly property var rows: Model.groupEntries(poolEntries, {
    fromKey: range.from, toKey: range.to, projectFilter: projectFilter, query: query, todayKey: todayKey,
    groupSimilar: svc ? Model.flag(svc.opt("groupSimilar")) : true, expanded: expanded
  }, buildNow)
  readonly property bool bodyReady: !!(svc && (snapshot.lastSyncAt || !svc.signedIn)) && pool.covered
  readonly property bool textEditing: timerBar.editing || entriesView.searching || settingsView.editingText || editor.visible

  // Panel contract -----------------------------------------------------------
  function open() { root.controller.show() }
  function openFromHotkey() { root.controller.show() }
  function close() { root.controller.hide() }
  function toggle() { root.opened ? root.close() : root.open() }
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function focusCatcher() { Qt.callLater(function() { keyCatcher.forceActiveFocus() }) }
  function requestTimerFocus() {
    if (root.opened) Qt.callLater(function() { timerBar.focusInput() })
  }

  // Navigation -----------------------------------------------------------------
  function setView(v) {
    root.showSettings = false
    root.view = v
    if (v === "timesheet" && rangeMode !== "week") { rangeMode = "week"; anchorKey = todayKey }
    if (v === "calendar" && rangeMode !== "day") { rangeMode = "day"; anchorKey = todayKey }
    if (v === "list" && rangeMode === "day" && anchorKey === todayKey) rangeMode = "all"
    if (svc) svc.setUi("lastView", v)
    focusCatcher()
  }
  function showView(name) {
    if (name === "settings") toggleSettings(true)
    else if (name === "list" || name === "timesheet" || name === "calendar") setView(name)
  }
  function toggleSettings(force) {
    root.showSettings = force === undefined ? !root.showSettings : force
    focusCatcher()
  }
  function stepRange(direction) {
    if (rangeMode === "all") return
    var next = Model.stepRange(rangeMode, anchorKey, direction)
    if (next > todayKey) return
    anchorKey = next
  }
  function pickRange(id) {
    if (id === "all") { rangeMode = "all"; anchorKey = todayKey; if (view !== "list") view = "list" }
    else if (id === "today") { rangeMode = "day"; anchorKey = todayKey }
    else if (id === "yesterday") { rangeMode = "day"; anchorKey = Model.addDays(todayKey, -1) }
    else if (id === "week") { rangeMode = "week"; anchorKey = todayKey }
    else if (id === "lastweek") { rangeMode = "week"; anchorKey = Model.addDays(todayKey, -7) }
    if (view === "calendar" && rangeMode !== "day") view = "list"
  }
  function jumpTo(v, mode, key) {
    showSettings = false
    view = v
    rangeMode = mode
    anchorKey = key
  }
  function drillDown(dayKeyValue, projectKey) {
    jumpTo("list", "day", dayKeyValue)
    projectFilter = projectKey || ""
  }

  // Dialogs ----------------------------------------------------------------------
  function openEditor(entry) {
    if (!entry || !entry.stop) { timerBar.focusInput(); return }
    editor.openFor(entry)
  }
  function openCreator(fromMs, toMs) { editor.openCreate(fromMs, toMs) }
  function askConfirm(message, ids) {
    root.confirm = { message: message, ids: ids }
    focusCatcher()
  }
  function runConfirm() {
    var c = root.confirm
    root.confirm = null
    if (!c || !svc) return
    svc.remove(c.ids.map(function(x) { return Number(x) }), function(ok) { if (ok) root.checked = ({}) })
    focusCatcher()
  }

  function ensureRange() {
    if (!svc || pool.covered || !svc.signedIn) { rangeLoading = false; return }
    var key = range.from + "_" + range.to
    if (requestedRanges[key]) return
    var next = {}
    for (var k in requestedRanges) next[k] = requestedRanges[k]
    next[key] = true
    requestedRanges = next
    rangeLoading = true
    svc.fetchRange(range.from, range.to, function() { root.rangeLoading = false })
  }

  function subtitle() {
    if (!svc) return "Starting…"
    if (!svc.signedIn) return snapshot.error && snapshot.error.kind === "auth" && snapshot.auth && snapshot.auth.user ? "Token rejected · sign in again" : "Not connected"
    var parts = []
    var user = snapshot.auth && snapshot.auth.user ? (snapshot.auth.user.fullname || "") : ""
    if (user) parts.push(user)
    var ws = snapshot.auth ? (snapshot.auth.workspaces || []) : []
    for (var i = 0; i < ws.length; i++) if (ws[i].id === snapshot.auth.workspaceId && ws.length > 1) parts.push(ws[i].name)
    if (svc.busy && svc.busyCommand === "sync") parts.push("syncing…")
    else parts.push("synced " + Model.relativeAge(snapshot.lastSyncAt, svc.now))
    return parts.join("  ·  ")
  }

  onPoolChanged: Qt.callLater(ensureRange)
  onOpenedChanged: {
    if (svc) svc.panelOpen = opened
    if (opened) {
      buildNow = Date.now()
      if (svc) svc.refreshForPanel()
      var pending = svc ? svc.consumeView() : ""
      if (pending) showView(pending)
      if (svc && svc.consumeQuickFocus()) requestTimerFocus()
      else if (svc && !svc.signedIn) { showSettings = true; Qt.callLater(function() { settingsView.focusToken() }) }
      else focusCatcher()
    } else {
      confirm = null
      if (editor.visible) editor.close()
    }
  }
  onSvcChanged: if (svc && svc.ui && svc.ui.lastView && !svc.opt("defaultView")) view = svc.ui.lastView

  Connections {
    target: root.svc
    ignoreUnknownSignals: true
    function onSnapshotChanged() { root.buildNow = Date.now() }
  }

  Timer {
    // Refresh aggregated rows/totals now and then so a long-running entry's
    // share of legends and grids stays close to live without rebuilding
    // delegates every second (rows show live durations themselves).
    interval: 30000
    repeat: true
    running: root.opened
    onTriggered: root.buildNow = Date.now()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.cappedContentHeight(Style.space(760))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.textEditing

      onCloseRequested: {
        if (root.svc && root.svc.idlePrompt) { root.svc.resolveIdle("keep"); return }
        if (root.confirm) { root.confirm = null; return }
        if (Object.keys(root.checked).length) { root.checked = ({}); return }
        if (root.showSettings) { root.showSettings = false; return }
        if (root.query !== "") { root.query = ""; return }
        if (root.projectFilter !== "") { root.projectFilter = ""; return }
        root.close()
      }
      onTabRequested: function(direction) {
        var order = ["calendar", "list", "timesheet"]
        var i = order.indexOf(root.view)
        root.setView(order[(i + (direction > 0 ? 1 : 2)) % 3])
      }
      onMoveRequested: function(dx, dy) {
        if (root.showSettings) {
          if (dy !== 0) settingsView.flick(0, -dy * 900)
          return
        }
        if (root.view === "list") {
          if (dy !== 0) entriesView.move(dy)
          else entriesView.keyExpand(dx > 0)
        } else if (dy !== 0) {
          var f = root.view === "calendar" ? calendarView : timesheetView
          f.contentY = Math.max(0, Math.min(f.contentHeight - f.height, f.contentY + dy * Style.space(48)))
        } else {
          root.stepRange(dx)
        }
      }
      onReturnRequested: root.enterPressed = true
      onActivateRequested: {
        var enter = root.enterPressed
        root.enterPressed = false
        if (root.confirm) { if (enter) root.runConfirm(); return }
        if (!root.svc || !root.svc.signedIn) return
        if (enter && root.view === "list" && !root.showSettings && entriesView.selectedRow) entriesView.keyActivate()
        else if (enter) timerBar.focusInput()
        else root.svc.toggle()
      }
      onDeleteRequested: if (root.view === "list" && !root.showSettings) entriesView.keyDelete()
      onTextKey: function(text) {
        if (root.svc && root.svc.idlePrompt) {
          if (text === "d") root.svc.resolveIdle("discard-continue")
          else if (text === "s") root.svc.resolveIdle("discard")
          return
        }
        switch (text) {
        case "/": case "n": timerBar.focusInput(); break
        case "s": if (root.svc && root.svc.running) root.svc.stop(); break
        case "1": root.setView("calendar"); break
        case "2": root.setView("list"); break
        case "3": root.setView("timesheet"); break
        case ",": root.toggleSettings(); break
        case "[": root.stepRange(-1); break
        case "]": root.stepRange(1); break
        case "t": root.pickRange(root.view === "timesheet" ? "week" : "today"); break
        case "a": root.pickRange("all"); break
        case "f": if (root.view !== "list") root.setView("list"); entriesView.focusSearch(); break
        case "e": if (root.view === "list") entriesView.keyEdit(); break
        case "m": if (root.view === "list") entriesView.keyMenu(); break
        case "v": if (root.view === "list") entriesView.keyCheck(); break
        case "r": if (root.svc) { root.svc.lastPanelSync = Date.now(); root.svc.refresh(true) } break
        case "c": root.compact = !root.compact; break
        }
      }

      Column {
        id: layout
        anchors.fill: parent
        spacing: Style.spacing.lg

        // Slim header (stands in for the web app's logo bar) ------------------
        Item {
          width: parent.width
          height: Style.space(28)

          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.md
            width: parent.width - headerActions.width - Style.spacing.md
            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              text: "󱎫"
              color: root.svc && root.svc.running ? Model.projectColor(root.svc.running, root.accent) : root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
            }
            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              text: "Toggl Track"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - Style.space(130)
              text: root.subtitle()
              color: root.svc && root.snapshot.error && root.snapshot.error.kind === "quota" ? Color.urgent : Color.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
          Row {
            id: headerActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.sm
            IconToggle {
              anchors.verticalCenter: parent.verticalCenter
              icon: "󰑓"
              tooltip: "Sync now  r"
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              enabledState: !!(root.svc && root.svc.signedIn)
              onClicked: { root.svc.lastPanelSync = Date.now(); root.svc.refresh(true) }
              RotationAnimator on rotation {
                running: !!(root.svc && root.svc.busy && root.svc.busyCommand === "sync")
                from: 0; to: 360; duration: 900; loops: Animation.Infinite
                onRunningChanged: if (!running) parent.rotation = 0
              }
            }
            ActionChip {
              anchors.verticalCenter: parent.verticalCenter
              text: "Esc"
              icon: "󰅖"
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.close()
            }
          }
        }

        TimerBar {
          id: timerBar
          ctx: root
          width: parent.width
          z: 10
        }

        IdlePrompt {
          ctx: root
          width: parent.width
          z: 9
        }

        SummaryRow {
          ctx: root
          visible: !root.compact
          width: parent.width
        }

        DateNav {
          ctx: root
          visible: !root.compact && !root.showSettings
          width: Style.space(250)
        }

        ViewSwitch {
          ctx: root
          width: parent.width
        }

        ProjectLegend {
          ctx: root
          visible: !root.compact && !root.showSettings && segments.length > 0
          width: parent.width
          segments: root.legendSegments
        }

        Row {
          visible: root.projectFilter !== "" && !root.showSettings
          spacing: Style.spacing.md
          ActionChip {
            text: {
              var seg = root.legendSegments.filter(function(s) { return s.key === root.projectFilter })[0]
              return (seg ? seg.name : "Project") + "  ×"
            }
            icon: "●"
            selected: true
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            onClicked: root.projectFilter = ""
          }
        }

        // Banners ----------------------------------------------------------
        Banner {
          width: parent.width
          visible: !!(root.svc && root.snapshot.error && root.snapshot.error.kind === "quota")
          icon: "󰔟"
          urgent: true
          text: "Showing cached data · API limit resets in " + (root.snapshot.error ? Model.resetsIn(root.snapshot.error.resetsAt, root.svc ? root.svc.now : Date.now()) : "")
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
        }
        Banner {
          width: parent.width
          visible: !!(root.svc && (root.svc.pendingCount > 0 || (root.snapshot.error && root.snapshot.error.kind === "net")))
          icon: "󰖪"
          text: root.svc && root.svc.pendingCount > 0 ? "Offline · " + root.svc.pendingCount + " change" + (root.svc.pendingCount === 1 ? "" : "s") + " queued"
            : "Offline · showing cached data"
          actionText: "Retry"
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          onAction: root.svc.refresh(true)
        }
        Banner {
          width: parent.width
          readonly property var dropped: root.snapshot && root.snapshot.dropped ? root.snapshot.dropped : []
          visible: dropped.length > 0
          icon: "󰀦"
          urgent: true
          text: dropped.length === 1
            ? "An offline change couldn't be applied: " + (dropped[0].description ? "'" + dropped[0].description + "' — " : "") + dropped[0].reason
            : dropped.length + " offline changes couldn't be applied (latest: " + dropped[dropped.length - 1].reason + ")"
          actionText: "Dismiss"
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          onAction: root.svc.dismissDropped()
        }
        Banner {
          width: parent.width
          visible: !!(root.svc && root.svc.lastError)
          icon: "󰀦"
          urgent: true
          text: root.svc && root.svc.lastError
            ? root.svc.lastError.message + (root.svc.lastError.candidates && root.svc.lastError.candidates.length ? " — " + root.svc.lastError.candidates.join(", ") : "")
            : ""
          actionText: root.svc && root.svc.lastError && root.svc.lastError.details ? "Copy details" : "Dismiss"
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          onAction: {
            if (root.svc.lastError.details) Util.execArgv(["wl-copy", "--", root.svc.lastError.details])
            root.svc.lastError = null
          }
        }

        // Body -------------------------------------------------------------
        Item {
          id: bodyArea
          width: parent.width
          height: Math.max(0, layout.height - y)

          EntriesView {
            id: entriesView
            ctx: root
            anchors.fill: parent
            anchors.bottomMargin: bottomBar.visible ? bottomBar.height + Style.spacing.md : 0
            visible: root.view === "list" && !root.showSettings && root.svc && root.svc.signedIn
          }
          TimesheetView {
            id: timesheetView
            ctx: root
            anchors.fill: parent
            visible: root.view === "timesheet" && !root.showSettings && root.svc && root.svc.signedIn
          }
          CalendarView {
            id: calendarView
            ctx: root
            anchors.fill: parent
            visible: root.view === "calendar" && !root.showSettings && root.svc && root.svc.signedIn
          }
          SettingsView {
            id: settingsView
            ctx: root
            anchors.fill: parent
            visible: root.showSettings
          }

          EmptyState {
            visible: !root.showSettings && !!root.svc && !root.svc.signedIn
            anchors.centerIn: parent
            width: parent.width - Style.space(40)
            icon: "󰌾"
            title: "Connect Toggl Track"
            detail: "Paste your API token in Settings (⚙). It stays in your keyring."
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
          }
          ActionChip {
            visible: !root.showSettings && !!root.svc && !root.svc.signedIn
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.verticalCenter
            anchors.topMargin: Style.space(70)
            text: "Open Settings"
            icon: "󰒓"
            selected: true
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            onClicked: { root.toggleSettings(true); settingsView.focusToken() }
          }

          // Loading placeholder while a range beyond the cache is fetched.
          Column {
            visible: !root.pool.covered && !root.showSettings
            anchors.fill: parent
            anchors.topMargin: Style.spacing.xl
            spacing: Style.spacing.md
            Repeater {
              model: 6
              delegate: Rectangle {
                width: bodyArea.width
                height: Style.space(44)
                radius: Math.max(Style.cornerRadius, Style.space(6))
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
              }
            }
          }

          // Confirm strip / bulk selection bar -------------------------------
          Item {
            id: bottomBar
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            visible: !root.showSettings && (!!root.confirm || entriesView.checkedCount > 0)
            height: root.confirm ? confirmStrip.implicitHeight : bulk.height

            ConfirmStrip {
              id: confirmStrip
              visible: !!root.confirm
              width: parent.width
              message: root.confirm ? root.confirm.message : ""
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onConfirmed: root.runConfirm()
              onCanceled: { root.confirm = null; root.focusCatcher() }
            }
            Rectangle {
              id: bulk
              visible: !root.confirm
              width: parent.width
              height: Style.space(42)
              radius: Math.max(Style.cornerRadius, Style.space(8))
              color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.10)
              border.width: Style.spacing.hairline
              border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.28)
              Text {
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.xl
                anchors.verticalCenter: parent.verticalCenter
                text: entriesView.checkedCount + " selected"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }
              Row {
                anchors.right: parent.right
                anchors.rightMargin: Style.spacing.md
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.spacing.md
                ActionChip {
                  text: "Delete"
                  icon: "󰆴"
                  destructive: true
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  onClicked: root.askConfirm("Delete " + entriesView.checkedCount + " selected entries?", Object.keys(root.checked))
                }
                ActionChip {
                  text: "Cancel"
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  onClicked: root.checked = ({})
                }
              }
            }
          }

          EntryEditor {
            id: editor
            ctx: root
            width: parent.width
            anchors.top: parent.top
            z: 20
            onClosed: root.focusCatcher()
          }
        }
      }
    }
  }
}
