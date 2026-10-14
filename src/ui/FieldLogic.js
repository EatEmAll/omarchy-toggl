.pragma library

// Pure editing logic for components/PlainField.qml. PlainField draws its own
// text instead of using a Qt text input, because every Qt text input keeps
// itself in sync with the system clipboard (reading foreign text without a
// size or time limit). Paste goes through a bounded `wl-paste` instead.
//
// A state is { text, cursor, anchor }; anchor === cursor means no selection.

var MAX_PASTE = 4096
var MAX_UNDO = 100

function state(text, cursor, anchor) {
  var t = String(text === undefined || text === null ? "" : text)
  var c = clampIndex(cursor === undefined ? t.length : cursor, t.length)
  var a = anchor === undefined ? c : clampIndex(anchor, t.length)
  return { text: t, cursor: c, anchor: a }
}

function clampIndex(i, len) {
  i = Math.round(Number(i))
  if (isNaN(i)) return len
  return Math.max(0, Math.min(len, i))
}

function hasSelection(s) { return s.cursor !== s.anchor }
function selFrom(s) { return Math.min(s.cursor, s.anchor) }
function selTo(s) { return Math.max(s.cursor, s.anchor) }
function selectedText(s) { return s.text.slice(selFrom(s), selTo(s)) }

// Control characters never enter a field; line breaks and tabs become spaces
// so a pasted block stays one line. `digitsOnly` keeps 0-9 only.
function sanitize(str, digitsOnly) {
  var out = String(str === undefined || str === null ? "" : str)
  if (digitsOnly) return out.replace(/[^0-9]/g, "")
  return out.replace(/[\r\n\t]+/g, " ").replace(/[\u0000-\u001f\u007f-\u009f]/g, "")
}

function insert(s, str, maxLength, digitsOnly) {
  var add = sanitize(str, digitsOnly)
  var from = selFrom(s), to = selTo(s)
  var room = Math.max(0, (maxLength > 0 ? maxLength : 1e9) - (s.text.length - (to - from)))
  if (add.length > room) add = add.slice(0, room)
  if (add === "" && from === to) return s
  var text = s.text.slice(0, from) + add + s.text.slice(to)
  var cursor = from + add.length
  return { text: text, cursor: cursor, anchor: cursor }
}

// No Unicode property escapes here: Qt's JS engine does not support them.
// Anything that is not whitespace or ASCII punctuation is part of a word.
function isWordChar(ch) { return ch !== "" && !/[\s!-\/:-@\[-^`{-~]/.test(ch) }

function wordLeft(text, i) {
  while (i > 0 && !isWordChar(text.charAt(i - 1))) i--
  while (i > 0 && isWordChar(text.charAt(i - 1))) i--
  return i
}

function wordRight(text, i) {
  var n = text.length
  while (i < n && !isWordChar(text.charAt(i))) i++
  while (i < n && isWordChar(text.charAt(i))) i++
  return i
}

function backspace(s, byWord) {
  if (hasSelection(s)) return insert(s, "", 0)
  if (s.cursor === 0) return s
  var from = byWord ? wordLeft(s.text, s.cursor) : prevIndex(s.text, s.cursor)
  return { text: s.text.slice(0, from) + s.text.slice(s.cursor), cursor: from, anchor: from }
}

function del(s, byWord) {
  if (hasSelection(s)) return insert(s, "", 0)
  if (s.cursor >= s.text.length) return s
  var to = byWord ? wordRight(s.text, s.cursor) : nextIndex(s.text, s.cursor)
  return { text: s.text.slice(0, s.cursor) + s.text.slice(to), cursor: s.cursor, anchor: s.cursor }
}

// Step over a whole surrogate pair so an emoji is never split.
function prevIndex(text, i) {
  if (i <= 0) return 0
  var low = text.charCodeAt(i - 1)
  if (i >= 2 && low >= 0xdc00 && low <= 0xdfff) {
    var high = text.charCodeAt(i - 2)
    if (high >= 0xd800 && high <= 0xdbff) return i - 2
  }
  return i - 1
}

function nextIndex(text, i) {
  var n = text.length
  if (i >= n) return n
  var high = text.charCodeAt(i)
  if (i + 1 < n && high >= 0xd800 && high <= 0xdbff) {
    var low = text.charCodeAt(i + 1)
    if (low >= 0xdc00 && low <= 0xdfff) return i + 2
  }
  return i + 1
}

// kind: "left" | "right" | "home" | "end"; opts: { word, extend }
function move(s, kind, opts) {
  opts = opts || {}
  var c = s.cursor
  if (!opts.extend && hasSelection(s) && (kind === "left" || kind === "right") && !opts.word) {
    var edge = kind === "left" ? selFrom(s) : selTo(s)
    return { text: s.text, cursor: edge, anchor: edge }
  }
  if (kind === "left") c = opts.word ? wordLeft(s.text, c) : prevIndex(s.text, c)
  else if (kind === "right") c = opts.word ? wordRight(s.text, c) : nextIndex(s.text, c)
  else if (kind === "home") c = 0
  else if (kind === "end") c = s.text.length
  return { text: s.text, cursor: c, anchor: opts.extend ? s.anchor : c }
}

function selectAll(s) { return { text: s.text, cursor: s.text.length, anchor: 0 } }

function setCursor(s, index, extend) {
  var c = clampIndex(index, s.text.length)
  return { text: s.text, cursor: c, anchor: extend ? s.anchor : c }
}

// Index nearest to x, given advance(prefixLength) = pixel width of the first
// n characters. Binary search; never lands inside a surrogate pair.
function indexAtX(text, x, advance) {
  var lo = 0, hi = text.length
  if (x <= 0) return 0
  if (x >= advance(hi)) return hi
  while (hi - lo > 1) {
    var mid = (lo + hi) >> 1
    if (advance(mid) <= x) lo = mid
    else hi = mid
  }
  var pick = (x - advance(lo) <= advance(hi) - x) ? lo : hi
  var code = text.charCodeAt(pick)
  if (pick > 0 && code >= 0xdc00 && code <= 0xdfff) pick--
  return pick
}

function mask(text) {
  var out = ""
  for (var i = 0; i < text.length; i++) out += "•"
  return out
}
