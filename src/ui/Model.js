.pragma library

// Pure helpers for the Toggl panel. No QML types in here, so the whole file
// can be unit-tested with deno (tests/model_test.js strips the pragma line).
// Dates are handled as local "YYYY-MM-DD" day keys; timestamps as ms.

var DEFAULTS = {
  labelMode: "description",
  maxLabelChars: 18,
  idleDisplay: "today-total",
  showSeconds: true,
  syncMinutes: 5,
  historyDays: 7,
  idleMinutes: 10,
  remindMinutes: 0,
  workspaceId: "",
  defaultView: "list",
  groupSimilar: true
}

var DAY_MS = 86400000

function emptyState() {
  return {
    schema: 1, updatedAt: null, lastSyncAt: null, error: null,
    config: { historyDays: 7 }, auth: { ok: false, user: null, workspaces: [] },
    running: null, entries: [], ranges: {}, projects: [], tags: [], stats: {}, quota: {}, pending: []
  }
}

function parseState(text) {
  try {
    var data = JSON.parse(String(text || ""))
    if (!data || data.schema !== 1) return emptyState()
    var base = emptyState()
    for (var k in data) base[k] = data[k]
    if (!Array.isArray(base.entries)) base.entries = []
    if (!Array.isArray(base.projects)) base.projects = []
    if (!Array.isArray(base.tags)) base.tags = []
    if (!Array.isArray(base.pending)) base.pending = []
    if (!base.ranges || typeof base.ranges !== "object") base.ranges = {}
    return base
  } catch (e) {
    return emptyState()
  }
}

function setting(settings, key) {
  var v = settings ? settings[key] : undefined
  return v === undefined || v === null || v === "" && key !== "workspaceId" ? DEFAULTS[key] : v
}

// Boolean settings may arrive as strings ("false") when set with
// `omarchy bar set <id> <key> false` (without --json).
function flag(value) {
  return !(value === false || value === "false" || value === 0 || value === "0")
}

// ------------------------------------------------------------------ time

function pad2(n) { return n < 10 ? "0" + n : String(n) }

function isoMs(iso) {
  if (!iso) return NaN
  return Date.parse(iso)
}

function elapsedSec(startIso, nowMs) {
  var s = isoMs(startIso)
  if (isNaN(s)) return 0
  return Math.max(0, Math.floor((nowMs - s) / 1000))
}

function entrySeconds(entry, nowMs) {
  if (!entry) return 0
  if (!entry.stop) return elapsedSec(entry.start, nowMs)
  if (typeof entry.seconds === "number" && entry.seconds >= 0) return entry.seconds
  return Math.max(0, Math.floor((isoMs(entry.stop) - isoMs(entry.start)) / 1000))
}

function hms(sec, showSeconds) {
  sec = Math.max(0, Math.floor(Number(sec) || 0))
  var h = Math.floor(sec / 3600)
  var m = Math.floor(sec % 3600 / 60)
  var s = sec % 60
  if (showSeconds === false) return h + ":" + pad2(m)
  return h + ":" + pad2(m) + ":" + pad2(s)
}

function hm(sec) { return hms(sec, false) }

function compactDuration(sec) {
  sec = Math.max(0, Math.floor(Number(sec) || 0))
  if (sec === 0) return "–"
  return hm(sec)
}

function clock(iso) {
  var t = isoMs(iso)
  if (isNaN(t)) return ""
  var d = new Date(t)
  return pad2(d.getHours()) + ":" + pad2(d.getMinutes())
}

function dayKey(ms) {
  var d = new Date(ms)
  return d.getFullYear() + "-" + pad2(d.getMonth() + 1) + "-" + pad2(d.getDate())
}

function keyMs(key) {
  var p = String(key).split("-")
  return new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2])).getTime()
}

function addDays(key, n) {
  var p = String(key).split("-")
  return dayKey(new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]) + n).getTime())
}

function dayDiff(a, b) {
  return Math.round((keyMs(b) - keyMs(a)) / DAY_MS)
}

var WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

function dayLabel(key, todayKey) {
  if (key === todayKey) return "Today"
  if (key === addDays(todayKey, -1)) return "Yesterday"
  var d = new Date(keyMs(key))
  return WEEKDAYS[d.getDay()] + ", " + d.getDate() + " " + MONTHS[d.getMonth()]
}

function shortDate(key) {
  var d = new Date(keyMs(key))
  return d.getDate() + " " + MONTHS[d.getMonth()]
}

function weekdayShort(key) {
  return WEEKDAYS[new Date(keyMs(key)).getDay()].substring(0, 2)
}

// Toggl beginning_of_week: Sunday=0, Monday=1 ...
function weekStartKey(key, beginningOfWeek) {
  var dow = new Date(keyMs(key)).getDay()
  var back = (dow - (Number(beginningOfWeek) || 0) + 7) % 7
  return addDays(key, -back)
}

// Mirrors timeutil.parse_when (shared cases in tests/time_cases.json).
// Returns epoch ms, or NaN when the text is not understood.
function parseWhen(text, nowMs) {
  var raw = String(text || "").trim().toLowerCase()
  if (!raw) return NaN
  if (raw === "now") return Math.floor(nowMs / 1000) * 1000
  var rel = /^([+-])\s*(\d+)\s*(m|min|h|hr|s)?$/.exec(raw)
  if (rel) {
    var unit = rel[3] || "m"
    var secs = Number(rel[2]) * (unit.charAt(0) === "h" ? 3600 : unit === "s" ? 1 : 60)
    return Math.floor(nowMs / 1000) * 1000 + (rel[1] === "+" ? 1 : -1) * secs * 1000
  }
  var base = new Date(nowMs)
  var offset = 0
  if (raw.indexOf("yesterday") === 0) { offset = -1; raw = raw.substring(9).trim() }
  else if (raw.indexOf("today") === 0) { raw = raw.substring(5).trim() }
  var m = /^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$/.exec(raw)
  if (m) {
    var hour = Number(m[1]), minute = Number(m[2] || 0)
    if (m[3] === "pm" && hour < 12) hour += 12
    if (m[3] === "am" && hour === 12) hour = 0
    if (hour > 23 || minute > 59) return NaN
    return new Date(base.getFullYear(), base.getMonth(), base.getDate() + offset, hour, minute, 0).getTime()
  }
  if (/^\d{4}-\d{2}-\d{2}t/.test(raw)) {
    var t = Date.parse(String(text).trim())
    return isNaN(t) ? NaN : t
  }
  return NaN
}

function toIso(ms) {
  return new Date(Math.floor(ms / 1000) * 1000).toISOString().replace(".000Z", "Z")
}

// ---------------------------------------------------------------- colours

function projectColor(entryOrProject, fallback) {
  var c = entryOrProject ? (entryOrProject.projectColor || entryOrProject.color) : ""
  return c && /^#[0-9a-fA-F]{6}$/.test(c) ? c : fallback
}

// ------------------------------------------------------------ entry pools

function allEntries(state, running) {
  var list = (state && state.entries) ? state.entries.slice() : []
  if (running) list.unshift(running)
  return list
}

// Entries for [fromKey, toKey]: the cached window when it covers the range,
// otherwise a fetched range from state.ranges. `covered` false means the
// caller should ask the backend to fetch the range.
function entriesFor(state, fromKey, toKey, todayKey) {
  var days = Number(state && state.config && state.config.historyDays) || 7
  var windowStart = addDays(todayKey, -(days - 1))
  var running = state ? state.running : null
  if (!fromKey || fromKey >= windowStart) {
    return { covered: true, entries: allEntries(state, running) }
  }
  var key = fromKey + "_" + toKey
  var rng = state && state.ranges ? state.ranges[key] : null
  if (rng) {
    var list = rng.entries ? rng.entries.slice() : []
    if (running && toKey >= todayKey) list.unshift(running)
    return { covered: true, entries: list }
  }
  return { covered: false, entries: [] }
}

// Split an entry at local midnights: [{day, seconds}].
function pieces(entry, nowMs) {
  var start = isoMs(entry.start)
  var stop = entry.stop ? isoMs(entry.stop) : nowMs
  var out = []
  if (isNaN(start) || !(stop > start)) return out
  var cursor = start
  var guard = 0
  while (cursor < stop && guard++ < 400) {
    var key = dayKey(cursor)
    var next = keyMs(addDays(key, 1))
    var end = Math.min(stop, next)
    out.push({ day: key, seconds: (end - cursor) / 1000 })
    cursor = end
  }
  return out
}

function inRange(key, fromKey, toKey) {
  return (!fromKey || key >= fromKey) && (!toKey || key <= toKey)
}

function matchesFilter(entry, projectFilter, query) {
  if (projectFilter !== undefined && projectFilter !== null && projectFilter !== "") {
    var pid = entry.projectId === null || entry.projectId === undefined ? "none" : String(entry.projectId)
    if (pid !== String(projectFilter)) return false
  }
  if (query) {
    var q = String(query).toLowerCase()
    var hay = [entry.description || "", entry.projectName || "", (entry.tags || []).join(" "), entry.clientName || ""]
      .join(" ").toLowerCase()
    if (hay.indexOf(q) === -1) return false
  }
  return true
}

// Totals for a day range, including the live running entry.
function rangeStats(entries, fromKey, toKey, nowMs, opts) {
  opts = opts || {}
  var dayKeys = []
  if (fromKey && toKey) {
    for (var k = fromKey, g = 0; k <= toKey && g < 400; k = addDays(k, 1), g++) dayKeys.push(k)
  }
  var byDay = {}
  for (var i = 0; i < dayKeys.length; i++) byDay[dayKeys[i]] = 0
  var projects = {}
  var order = []
  var total = 0, billable = 0, count = 0
  var seenDays = {}
  for (var e = 0; e < entries.length; e++) {
    var entry = entries[e]
    if (!matchesFilter(entry, opts.projectFilter, opts.query)) continue
    var ps = pieces(entry, nowMs)
    var touched = false
    for (var p = 0; p < ps.length; p++) {
      var piece = ps[p]
      if (!inRange(piece.day, fromKey, toKey)) continue
      touched = true
      seenDays[piece.day] = true
      total += piece.seconds
      if (entry.billable) billable += piece.seconds
      byDay[piece.day] = (byDay[piece.day] || 0) + piece.seconds
      var pk = entry.projectId === null || entry.projectId === undefined ? "none" : String(entry.projectId)
      if (!projects[pk]) {
        projects[pk] = {
          key: pk, projectId: entry.projectId || null,
          name: entry.projectName || (pk === "none" ? "(No project)" : "Project " + pk),
          color: pk === "none" ? "" : (entry.projectColor || ""), seconds: 0, days: {}
        }
        order.push(pk)
      }
      projects[pk].seconds += piece.seconds
      projects[pk].days[piece.day] = (projects[pk].days[piece.day] || 0) + piece.seconds
    }
    if (touched) count++
  }
  var list = []
  for (var o = 0; o < order.length; o++) list.push(projects[order[o]])
  list.sort(function(a, b) { return b.seconds - a.seconds })
  var dayList = []
  var keys = dayKeys.length ? dayKeys : Object.keys(byDay).sort()
  for (var d = 0; d < keys.length; d++) dayList.push({ date: keys[d], seconds: byDay[keys[d]] || 0 })
  var activeDays = Object.keys(seenDays).length
  return {
    from: fromKey || "", to: toKey || "", total: total, billable: billable, count: count,
    byDay: dayList, byProject: list, activeDays: activeDays,
    avgPerDay: activeDays ? total / activeDays : 0
  }
}

// Proportional legend segments (ProjectLegend).
function legend(stats, minLabelShare) {
  var total = stats ? stats.total : 0
  var out = []
  if (!total) return out
  var list = stats.byProject || []
  for (var i = 0; i < list.length; i++) {
    var share = list[i].seconds / total
    out.push({
      key: list[i].key, projectId: list[i].projectId, name: list[i].name, color: list[i].color,
      seconds: list[i].seconds, share: share, showLabel: share >= (minLabelShare || 0.06)
    })
  }
  return out
}

function groupKey(entry) {
  return [entry.description || "", entry.projectId || "none", (entry.tags || []).slice().sort().join(","),
          entry.billable ? 1 : 0].join("|")
}

// Flat row model for the EntriesView, in the web app's order: newest day
// first, then newest entry first. Rows:
//   {kind:"day", day, label, total, ids}
//   {kind:"group", day, key, count, expanded, ids, entry (newest), seconds, first}
//   {kind:"entry", day, entry, seconds, child, running}
function groupEntries(entries, opts, nowMs) {
  opts = opts || {}
  var todayKey = opts.todayKey || dayKey(nowMs)
  var groupSimilar = opts.groupSimilar !== false
  var expanded = opts.expanded || {}
  var days = {}
  var dayOrder = []
  for (var i = 0; i < entries.length; i++) {
    var entry = entries[i]
    if (!matchesFilter(entry, opts.projectFilter, opts.query)) continue
    var key = dayKey(isoMs(entry.start))
    if (!inRange(key, opts.fromKey, opts.toKey)) continue
    if (!days[key]) { days[key] = []; dayOrder.push(key) }
    days[key].push(entry)
  }
  dayOrder.sort().reverse()
  var rows = []
  for (var d = 0; d < dayOrder.length; d++) {
    var day = dayOrder[d]
    var list = days[day].slice().sort(function(a, b) {
      if (!a.stop !== !b.stop) return a.stop ? 1 : -1
      return isoMs(b.start) - isoMs(a.start)
    })
    var total = 0
    var ids = []
    for (var t = 0; t < list.length; t++) {
      total += entrySeconds(list[t], nowMs)
      if (list[t].stop) ids.push(list[t].id)
    }
    rows.push({ kind: "day", day: day, label: dayLabel(day, todayKey), total: total, ids: ids, first: d === 0 })
    var groups = {}
    var gorder = []
    for (var x = 0; x < list.length; x++) {
      var item = list[x]
      var gk = !item.stop || !groupSimilar ? "single:" + item.id : groupKey(item)
      if (!groups[gk]) { groups[gk] = []; gorder.push(gk) }
      groups[gk].push(item)
    }
    for (var y = 0; y < gorder.length; y++) {
      var members = groups[gorder[y]]
      if (members.length === 1) {
        rows.push({ kind: "entry", day: day, entry: members[0], seconds: entrySeconds(members[0], nowMs),
                    child: false, running: !members[0].stop, count: 1 })
        continue
      }
      var sum = 0
      var gids = []
      for (var z = 0; z < members.length; z++) { sum += entrySeconds(members[z], nowMs); gids.push(members[z].id) }
      var gkey = day + "|" + gorder[y]
      var isOpen = !!expanded[gkey]
      rows.push({ kind: "group", day: day, key: gkey, count: members.length, expanded: isOpen, ids: gids,
                  entry: members[0], seconds: sum, running: false })
      if (isOpen) {
        for (var c = 0; c < members.length; c++)
          rows.push({ kind: "entry", day: day, entry: members[c], seconds: entrySeconds(members[c], nowMs),
                      child: true, running: false, count: 1 })
      }
    }
  }
  return rows
}

function recentUnique(entries, n) {
  var seen = {}
  var out = []
  for (var i = 0; i < entries.length && out.length < n; i++) {
    var e = entries[i]
    if (!e || !e.stop) continue
    var k = (e.description || "") + "|" + (e.projectId || "none")
    if (seen[k]) continue
    seen[k] = true
    out.push(e)
  }
  return out
}

// Suggestions for the TimerBar. The last token decides the mode:
// "@pro" -> projects, "#ta" -> tags, otherwise previous entries.
function suggest(text, entries, projects, tags, limit) {
  limit = limit || 6
  var value = String(text || "")
  var tokens = value.split(/\s+/)
  var last = tokens[tokens.length - 1] || ""
  var out = []
  var q
  if (last.charAt(0) === "@") {
    q = last.substring(1).replace(/"/g, "").toLowerCase()
    for (var i = 0; i < projects.length && out.length < limit; i++) {
      var p = projects[i]
      if (p.active === false) continue
      if (String(p.name || "").toLowerCase().indexOf(q) === -1) continue
      var name = String(p.name)
      out.push({ kind: "project", label: name, color: p.color || "", projectId: p.id,
                 completion: value.substring(0, value.length - last.length) + "@" + (name.indexOf(" ") >= 0 ? '"' + name + '"' : name) + " " })
    }
    return out
  }
  if (last.charAt(0) === "#") {
    q = last.substring(1).toLowerCase()
    for (var t = 0; t < tags.length && out.length < limit; t++) {
      var tag = String(tags[t].name || "")
      if (tag.toLowerCase().indexOf(q) === -1) continue
      out.push({ kind: "tag", label: "#" + tag, completion: value.substring(0, value.length - last.length) + "#" + tag + " " })
    }
    return out
  }
  q = value.trim().toLowerCase()
  var recent = recentUnique(entries, 200)
  for (var r = 0; r < recent.length && out.length < limit; r++) {
    var e = recent[r]
    var hay = ((e.description || "") + " " + (e.projectName || "")).toLowerCase()
    if (q && hay.indexOf(q) === -1) continue
    out.push({ kind: "entry", label: e.description || "(no description)", color: e.projectColor || "",
               projectName: e.projectName || "", entry: e })
  }
  return out
}

// Project x day grid for the TimesheetView.
function timesheet(stats) {
  var days = (stats && stats.byDay) ? stats.byDay : []
  var rows = []
  var max = 0
  var list = stats ? stats.byProject : []
  for (var i = 0; i < list.length; i++) {
    var cells = []
    for (var d = 0; d < days.length; d++) {
      var v = list[i].days[days[d].date] || 0
      if (v > max) max = v
      cells.push(v)
    }
    rows.push({ key: list[i].key, name: list[i].name, color: list[i].color, cells: cells, total: list[i].seconds })
  }
  return { days: days, rows: rows, max: max, total: stats ? stats.total : 0 }
}

// Timeline blocks for the CalendarView: minutes from local midnight, with
// overlapping entries placed in side-by-side lanes.
function dayBlocks(entries, dayKeyValue, nowMs) {
  var dayStart = keyMs(dayKeyValue)
  var dayEnd = keyMs(addDays(dayKeyValue, 1))
  var blocks = []
  for (var i = 0; i < entries.length; i++) {
    var e = entries[i]
    var s = isoMs(e.start)
    var t = e.stop ? isoMs(e.stop) : nowMs
    if (isNaN(s) || t <= dayStart || s >= dayEnd) continue
    var a = Math.max(s, dayStart), b = Math.min(t, dayEnd)
    blocks.push({ entry: e, startMin: (a - dayStart) / 60000, endMin: Math.max((b - dayStart) / 60000, (a - dayStart) / 60000 + 1),
                  running: !e.stop, seconds: entrySeconds(e, nowMs), lane: 0, lanes: 1 })
  }
  blocks.sort(function(x, y) { return x.startMin - y.startMin })
  var cluster = []
  var clusterEnd = -1
  function flush() {
    var laneEnds = []
    for (var c = 0; c < cluster.length; c++) {
      var placed = false
      for (var l = 0; l < laneEnds.length; l++) {
        if (laneEnds[l] <= cluster[c].startMin) { cluster[c].lane = l; laneEnds[l] = cluster[c].endMin; placed = true; break }
      }
      if (!placed) { cluster[c].lane = laneEnds.length; laneEnds.push(cluster[c].endMin) }
    }
    for (var k = 0; k < cluster.length; k++) cluster[k].lanes = laneEnds.length
    cluster = []
  }
  for (var j = 0; j < blocks.length; j++) {
    if (cluster.length && blocks[j].startMin >= clusterEnd) flush()
    cluster.push(blocks[j])
    clusterEnd = Math.max(clusterEnd, blocks[j].endMin)
  }
  if (cluster.length) flush()
  return blocks
}

// DateNav: resolve a range from mode + anchor day.
function rangeFor(mode, anchorKey, todayKey, historyDays, beginningOfWeek) {
  if (mode === "day") return { mode: mode, from: anchorKey, to: anchorKey, label: dayLabel(anchorKey, todayKey) }
  if (mode === "week") {
    var ws = weekStartKey(anchorKey, beginningOfWeek)
    var we = addDays(ws, 6)
    var thisWeek = weekStartKey(todayKey, beginningOfWeek)
    var label = ws === thisWeek ? "This week" : ws === addDays(thisWeek, -7) ? "Last week"
      : shortDate(ws) + " – " + shortDate(we)
    return { mode: mode, from: ws, to: we, label: label }
  }
  var days = Number(historyDays) || 7
  return { mode: "all", from: addDays(todayKey, -(days - 1)), to: todayKey, label: "All dates" }
}

function stepRange(mode, anchorKey, direction) {
  if (mode === "day") return addDays(anchorKey, direction)
  if (mode === "week") return addDays(anchorKey, 7 * direction)
  return anchorKey
}

function relativeAge(epochSec, nowMs) {
  if (!epochSec) return "never"
  var d = Math.max(0, Math.floor(nowMs / 1000 - epochSec))
  if (d < 60) return "just now"
  if (d < 3600) return Math.floor(d / 60) + "m ago"
  if (d < 86400) return Math.floor(d / 3600) + "h ago"
  return Math.floor(d / 86400) + "d ago"
}

function resetsIn(epochSec, nowMs) {
  if (!epochSec) return ""
  var d = Math.max(0, Math.ceil(epochSec - nowMs / 1000))
  if (d < 60) return d + "s"
  return Math.ceil(d / 60) + "m"
}

function elide(text, max) {
  var s = String(text || "")
  max = Number(max) || 18
  return s.length > max ? s.substring(0, Math.max(1, max - 1)) + "…" : s
}
