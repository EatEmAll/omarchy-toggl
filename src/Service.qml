import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import "ui"
import "ui/Model.js" as Model

// The single, shell-wide instance of the plugin (bar widgets exist once per
// monitor). Owns the watched state file, the backend queue, background sync,
// the live clock, idle/suspend detection, reminders and the IPC target.
Item {
  id: root

  // Injected by the shell (capability-scoped PluginShellApi).
  property var shell: null
  property var manifest: null

  readonly property string pluginId: "io.github.eatemall.toggl"
  readonly property string cliPath: Qt.resolvedUrl("toggl.py").toString().replace(/^file:\/\//, "")
  // Same rule as the backend: a relative $XDG_CACHE_HOME must be ignored.
  readonly property string xdgCache: String(Quickshell.env("XDG_CACHE_HOME") || "")
  readonly property string cacheDir: (xdgCache.charAt(0) === "/" ? xdgCache : Quickshell.env("HOME") + "/.cache") + "/omarchy-toggl"

  // Widget settings: pushed by the bar widget (the facade only gives a
  // start-up snapshot of the bar config), with that snapshot as fallback.
  property var settings: initialSettings()
  function opt(key) { return Model.setting(root.settings, key) }

  property var snapshot: Model.emptyState()
  property var ui: ({})
  property double now: Date.now()
  property double lastTick: Date.now()
  property string todayKey: Model.dayKey(Date.now())
  property var idlePrompt: null
  property var lastError: null
  property bool quickFocusPending: false
  property string pendingView: ""
  property bool panelOpen: false
  property double lastPanelSync: 0
  property double lastReminderAt: 0

  readonly property var running: snapshot ? snapshot.running : null
  readonly property bool signedIn: !!(snapshot && snapshot.auth && snapshot.auth.ok)
  readonly property bool hasTokenError: !!(snapshot && snapshot.error && snapshot.error.kind === "auth")
  readonly property bool busy: backend.busy
  readonly property string busyCommand: backend.currentCommand
  readonly property int elapsed: running ? Model.elapsedSec(running.start, now) : 0
  readonly property int beginningOfWeek: snapshot && snapshot.auth && snapshot.auth.user
    ? Number(snapshot.auth.user.beginningOfWeek || 0) : 1
  readonly property var allEntries: Model.allEntries(snapshot, running)
  readonly property var todayStats: Model.rangeStats(allEntries, todayKey, todayKey, now)
  readonly property string weekStartKey: Model.weekStartKey(todayKey, beginningOfWeek)
  readonly property var weekStats: Model.rangeStats(allEntries, weekStartKey, Model.addDays(weekStartKey, 6), now)
  readonly property int pendingCount: snapshot && snapshot.pending ? snapshot.pending.length : 0

  signal focusTimerBarRequested()
  signal viewRequested(string name)

  function initialSettings() {
    var cfg = root.shell && root.shell.barConfig ? root.shell.barConfig : null
    var layout = cfg && cfg.layout ? cfg.layout : (cfg && cfg.bar && cfg.bar.layout ? cfg.bar.layout : null)
    if (!layout) return ({})
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var list = layout[sections[s]] || []
      for (var i = 0; i < list.length; i++) {
        if (list[i] && list[i].id === root.pluginId) {
          var copy = {}
          for (var k in list[i]) if (k !== "id") copy[k] = list[i][k]
          return copy
        }
      }
    }
    return ({})
  }

  function applySettings(next) {
    var before = JSON.stringify(root.settings || {})
    var after = JSON.stringify(next || {})
    if (before === after) return
    var oldDays = root.opt("historyDays"), oldWs = String(root.opt("workspaceId") || "")
    root.settings = next || ({})
    if (root.opt("historyDays") !== oldDays || String(root.opt("workspaceId") || "") !== oldWs) root.refresh(true)
  }

  // ---------------------------------------------------------------- backend
  function syncArgs(force, meta) {
    var args = ["sync", "--history-days", String(root.opt("historyDays"))]
    args.push("--workspace", String(root.opt("workspaceId") || ""))
    if (force) args.push("--force")
    if (meta) args.push("--meta")
    return args
  }

  function reportError(ok, result) {
    if (ok) return
    var err = result && result.error ? result.error : { kind: "backend", message: "Unknown error" }
    root.lastError = { kind: err.kind, message: err.message, candidates: err.candidates || [], details: err.details || "",
                       at: Date.now() }
    errorClear.restart()
  }

  function call(args, cb, stdinText) {
    backend.run(args, function(ok, result) {
      if (!ok && args[0] !== "sync") root.reportError(ok, result)
      if (cb) cb(ok, result)
    }, stdinText)
  }

  function refresh(force, meta) { call(syncArgs(force, meta)) }

  function refreshForPanel() {
    // Panel open: at most one sync per minute (the CLI throttles too).
    if (Date.now() - root.lastPanelSync < 60000) return
    root.lastPanelSync = Date.now()
    refresh(true)
  }

  function start(text, extra, cb) {
    var args = ["start"]
    extra = extra || {}
    if (extra.projectId !== undefined) args.push("--project", extra.projectId === null ? "none" : String(extra.projectId))
    if (extra.tags) for (var i = 0; i < extra.tags.length; i++) args.push("--tag=" + String(extra.tags[i]))
    if (extra.billable) args.push("--billable")
    if (extra.at) args.push("--at", String(extra.at))
    args.push("--")
    if (text && String(text).trim()) args.push(String(text).trim())
    call(args, cb)
  }
  function stop(atIso, cb) { call(atIso ? ["stop", "--at", atIso] : ["stop"], cb) }
  function toggle(cb) { call(["toggle"], cb) }
  function continueEntry(id, cb) { call(id === undefined || id === null ? ["continue"] : ["continue", String(id)], cb) }
  function duplicate(id, cb) { call(["duplicate", String(id)], cb) }
  function remove(ids, cb) { call(["delete"].concat(ids.map(function(x) { return String(x) })), cb) }
  function fetchRange(fromKey, toKey, cb) { call(["range", "--from", fromKey, "--to", toKey], cb) }

  // fields: {description, projectId (null = none), tags [], billable, start, stop (ISO)}
  function update(id, fields, cb) {
    var args = ["update", String(id)]
    if (fields.description !== undefined) args.push("--description=" + String(fields.description))
    if (fields.projectId !== undefined) args.push("--project", fields.projectId === null ? "none" : String(fields.projectId))
    if (fields.tags !== undefined) args.push("--tags=" + fields.tags.join(","))
    if (fields.billable !== undefined) args.push(fields.billable ? "--billable" : "--no-billable")
    if (fields.start) args.push("--start", String(fields.start))
    if (fields.stop) args.push("--stop", String(fields.stop))
    call(args, cb)
  }

  function login(token, cb) {
    call(["auth", "login", "--stdin"], function(ok, result) {
      if (ok) root.lastError = null
      if (cb) cb(ok, result)
    }, String(token || "").trim())
  }
  function logout(cb) { call(["auth", "logout"], cb) }
  function doctor(cb) { call(["doctor"], cb) }

  function setUi(key, value) {
    var next = {}
    for (var k in root.ui) next[k] = root.ui[k]
    if (value === null || value === undefined) delete next[key]
    else next[key] = value
    root.ui = next
    call(["ui-set", key, JSON.stringify(value === undefined ? null : value)])
  }

  function saveSettings(patch) {
    var merged = {}
    for (var k in root.settings) merged[k] = root.settings[k]
    for (var p in patch) merged[p] = patch[p]
    root.applySettings(merged)
    if (root.shell && typeof root.shell.updateEntryInline === "function")
      return root.shell.updateEntryInline(root.pluginId, merged)
    return false
  }

  // ------------------------------------------------------------ idle prompt
  function resolveIdle(mode) {
    var prompt = root.idlePrompt
    root.idlePrompt = null
    root.setUi("idleSince", null)
    if (!prompt || mode === "keep") return
    call(["idle-resolve", "--since", Model.toIso(prompt.since), "--mode", mode])
  }

  function raiseIdle(sinceMs, reason) {
    if (!root.running) return
    var startMs = Model.isoMs(root.running.start)
    var since = Math.max(sinceMs, startMs)
    var minutes = Math.round((Date.now() - since) / 60000)
    if (minutes < 1) return
    if (root.idlePrompt && root.idlePrompt.since <= since) return
    root.idlePrompt = { since: since, until: Date.now(), reason: reason, entryId: root.running.id,
                        description: root.running.description || "(no description)",
                        projectName: root.running.projectName || "", projectColor: root.running.projectColor || "" }
    notify("󰒲", (reason === "suspend" ? "Suspended " : "Away ") + minutes + " min",
           "while tracking " + root.idlePrompt.description + (root.idlePrompt.projectName ? " · " + root.idlePrompt.projectName : ""))
    summonPanel()
  }

  function summonPanel() {
    if (root.shell && typeof root.shell.summon === "function" && root.shell.summon(root.pluginId, "{}")) return
    Util.execArgv(["omarchy-shell", "shell", "summon", root.pluginId])
  }

  function notify(glyph, title, body) {
    Util.execArgv(["omarchy-notification-send", "-g", glyph, "--app-name", "Toggl Track", String(title), String(body || "")])
  }

  function consumeView() {
    var v = root.pendingView
    root.pendingView = ""
    return v
  }

  function consumeQuickFocus() {
    var v = root.quickFocusPending
    root.quickFocusPending = false
    return v
  }

  onRunningChanged: {
    if (!root.running && root.idlePrompt) {
      root.idlePrompt = null
      root.setUi("idleSince", null)
    }
  }

  // --------------------------------------------------------------- state io
  Backend {
    id: backend
    cliPath: root.cliPath
  }

  FileView {
    id: stateFile
    path: root.cacheDir + "/state.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.snapshot = Model.parseState(text())
    onLoadFailed: root.snapshot = Model.emptyState()
  }

  FileView {
    id: uiFile
    path: root.cacheDir + "/ui.json"
    printErrors: false
    onLoaded: {
      try { root.ui = JSON.parse(text()) || {} } catch (e) { root.ui = {} }
      var since = Number(root.ui.idleSince || 0)
      if (since > 0) Qt.callLater(function() { if (root.running) root.raiseIdle(since, "restart") })
    }
  }

  // FileView's first read can race start-up (same fix as the weather widget).
  Timer {
    interval: 1500
    running: true
    onTriggered: stateFile.reload()
  }

  Timer {
    id: errorClear
    interval: 10000
    onTriggered: root.lastError = null
  }

  // --------------------------------------------------------------- timers
  Timer {
    id: syncTimer
    interval: Math.max(3, Number(root.opt("syncMinutes")) || 5) * 60000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh(false)
  }

  Timer {
    interval: 1000
    repeat: true
    running: true
    onTriggered: {
      var t = Date.now()
      // A tick gap means the machine was suspended while tracking.
      if (t - root.lastTick > 90000 && root.running && Number(root.opt("idleMinutes")) > 0)
        root.raiseIdle(root.lastTick, "suspend")
      root.lastTick = t
      root.now = t
      var key = Model.dayKey(t)
      if (key !== root.todayKey) {
        root.todayKey = key
        root.refresh(true)
      }
    }
  }

  Timer {
    interval: 60000
    repeat: true
    running: Number(root.opt("remindMinutes")) > 0
    onTriggered: {
      if (!root.signedIn || root.running || reminderIdle.isIdle) return
      var minutes = Number(root.opt("remindMinutes"))
      var last = root.snapshot.entries && root.snapshot.entries.length ? Model.isoMs(root.snapshot.entries[0].stop) : 0
      var since = Math.max(last || 0, root.lastReminderAt)
      if (Date.now() - since < minutes * 60000) return
      root.lastReminderAt = Date.now()
      root.notify("󱎫", "Not tracking", "No Toggl timer for " + Math.round((Date.now() - (last || Date.now())) / 60000) + " min")
    }
  }

  // Reminders fire only while nothing is tracked, when idleMonitor is off,
  // so they need their own presence check: never nag an idle or locked session.
  IdleMonitor {
    id: reminderIdle
    enabled: Number(root.opt("remindMinutes")) > 0 && root.running === null
    timeout: 300
    respectInhibitors: true
  }

  IdleMonitor {
    id: idleMonitor
    enabled: Number(root.opt("idleMinutes")) > 0 && root.running !== null
    timeout: Math.max(1, Number(root.opt("idleMinutes"))) * 60
    respectInhibitors: true
    onIsIdleChanged: {
      if (isIdle) {
        var since = Date.now() - timeout * 1000
        root.setUi("idleSince", since)
      } else {
        var start = Number(root.ui.idleSince || 0)
        if (start > 0 && root.running) root.raiseIdle(start, "idle")
        else root.setUi("idleSince", null)
      }
    }
  }

  // -------------------------------------------------------------------- ipc
  IpcHandler {
    target: "omarchy-toggl"

    function toggle(): string { root.toggle(); return "ok" }
    function start(text: string): string { root.start(text); return "ok" }
    function stop(): string { root.stop(); return "ok" }
    function continueLast(): string { root.continueEntry(null); return "ok" }
    function sync(): string { root.refresh(true); return "ok" }
    function quick(): string {
      root.quickFocusPending = true
      root.focusTimerBarRequested()
      root.summonPanel()
      return "ok"
    }
    // name: list | timesheet | calendar | settings
    function openView(name: string): string {
      root.pendingView = name
      root.viewRequested(name)
      root.summonPanel()
      return "ok"
    }
    function status(): string {
      return JSON.stringify({
        running: root.running, elapsed: root.elapsed,
        today: root.todayStats.total, week: root.weekStats.total,
        signedIn: root.signedIn, error: root.snapshot.error, panelOpen: root.panelOpen
      })
    }
  }
}
