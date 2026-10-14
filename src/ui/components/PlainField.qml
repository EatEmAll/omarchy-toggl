import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui as Ui
import "../FieldLogic.js" as Logic

// Single-line text field that draws its own text.
//
// Qt's text inputs keep their paste state in sync with the system clipboard
// and read whatever any program has put there, with no size or time limit, so
// a hostile clipboard owner could stall or exhaust the shared shell. This field
// never touches the clipboard itself: typing is handled from key events, and
// paste (Ctrl+V / Shift+Insert) runs one bounded `wl-paste` (2 s, 4 KB) on
// demand. Not supported: input methods, drag-and-drop, middle-click paste.
//
// Return/Enter, Escape, Up/Down and Tab are not consumed, so an owner's
// Keys.onPressed handlers see them (they run after the field's own handling).
FocusScope {
  id: root

  property string text: ""
  property string placeholderText: ""
  property bool password: false
  property bool digitsOnly: false
  property int maxLength: 4096
  property color foreground: Color.foreground
  property color accent: Color.accent
  property color selectionTint: Style.selectionFillFor(foreground, accent)
  property bool bare: false                       // no border or fill
  property real horizontalPadding: Style.spacing.controlPaddingX
  property real verticalPadding: Style.spacing.inputPaddingY
  property int horizontalAlignment: Qt.AlignLeft
  property alias font: label.font
  property int cursorPosition: 0
  readonly property bool hovered: hover.hovered
  readonly property bool hasSelection: cursorPosition !== _anchor

  signal accepted()
  signal editingFinished()

  property int _anchor: 0
  property real _scroll: 0
  property bool _writing: false
  readonly property string _display: password ? Logic.mask(text) : text
  readonly property var _borderSpec: Border.controlSpec(activeFocus ? "focus" : (hovered ? "hover-cursor" : "normal"), foreground, accent)

  implicitWidth: Style.space(160)
  implicitHeight: Math.ceil(fm.height) + verticalPadding * 2 + (bare ? 0 : Border.top(_borderSpec) + Border.bottom(_borderSpec))
  opacity: enabled ? 1 : 0.6
  clip: false

  function selectAll() { _set(Logic.selectAll(_state())) }
  function clear() { _edit(Logic.state("", 0)) }
  function copySelection() {
    if (root.password || !root.hasSelection) return
    Util.execArgv(["wl-copy", "--", Logic.selectedText(_state())])
  }
  function paste() {
    if (pasteProc.running || !root.enabled) return
    pasteProc.running = true
  }

  property var _undo: []
  property var _redo: []

  // Edits go through _edit so they can be undone; caret moves use _set.
  function _edit(s) {
    var before = _state()
    if (s.text === before.text) { _set(s); return }
    var u = _undo.concat([before])
    if (u.length > Logic.MAX_UNDO) u = u.slice(u.length - Logic.MAX_UNDO)
    _undo = u
    _redo = []
    _set(s)
  }
  function undo() {
    if (!_undo.length) return
    _redo = _redo.concat([_state()])
    var prev = _undo[_undo.length - 1]
    _undo = _undo.slice(0, -1)
    _set(prev)
  }
  function redo() {
    if (!_redo.length) return
    _undo = _undo.concat([_state()])
    var next = _redo[_redo.length - 1]
    _redo = _redo.slice(0, -1)
    _set(next)
  }

  function _state() { return Logic.state(text, cursorPosition, _anchor) }
  function _set(s) {
    root._writing = true
    if (root.text !== s.text) root.text = s.text
    root.cursorPosition = s.cursor
    root._anchor = s.anchor
    root._writing = false
    ensureVisible()
  }
  function _advance(n) { return n >= _display.length ? label.implicitWidth : fm.advanceWidth(_display.substring(0, n)) }

  // Keep the caret inside the visible part of long text.
  function ensureVisible() {
    var overflow = label.implicitWidth - view.width
    if (overflow <= 0) { _scroll = 0; return }
    var cx = _advance(cursorPosition)
    if (cx - _scroll > view.width - 2) _scroll = cx - view.width + 2
    else if (cx - _scroll < 0) _scroll = cx
    _scroll = Math.max(0, Math.min(overflow + 2, _scroll))
  }

  onTextChanged: {
    if (_writing) return
    _undo = []                                       // set from outside: new content,
    _redo = []                                       // caret to the end
    var s = Logic.state(text, text.length)
    cursorPosition = s.cursor
    _anchor = s.anchor
    ensureVisible()
  }
  onCursorPositionChanged: {
    if (_writing) return
    var c = Math.max(0, Math.min(text.length, cursorPosition))
    if (c !== cursorPosition) { cursorPosition = c; return }
    _anchor = c
    ensureVisible()
  }
  onActiveFocusChanged: if (!activeFocus) editingFinished()
  Component.onCompleted: ensureVisible()

  FontMetrics { id: fm; font: label.font }
  HoverHandler { id: hover; enabled: root.enabled }

  Process {
    id: pasteProc
    command: ["sh", "-c", "timeout -k 1 2 wl-paste --no-newline --type text 2>/dev/null | head -c " + Logic.MAX_PASTE]
    stdout: StdioCollector {
      onStreamFinished: {
        if (!root.activeFocus) return
        // head -c may cut a multi-byte character; drop the partial one
        root._edit(Logic.insert(root._state(), text.replace(/\uFFFD$/, ""), root.maxLength, root.digitsOnly))
      }
    }
  }

  Ui.BorderSurface {
    anchors.fill: parent
    visible: !root.bare
    color: Style.controlFill(root.activeFocus, root.hovered, root.foreground, root.accent)
    borderSpec: root._borderSpec
    radius: Style.cornerRadius
  }

  Item {
    id: view
    x: root.horizontalPadding + (root.bare ? 0 : Border.left(root._borderSpec))
    y: root.verticalPadding + (root.bare ? 0 : Border.top(root._borderSpec))
    width: root.width - x * 2
    height: root.height - y * 2
    clip: true
    onWidthChanged: root.ensureVisible()

    readonly property real textX: {
      var spare = view.width - label.implicitWidth
      if (spare <= 0) return -root._scroll
      if (root.horizontalAlignment === Qt.AlignHCenter) return spare / 2
      if (root.horizontalAlignment === Qt.AlignRight) return spare
      return 0
    }

    Rectangle {
      visible: root.hasSelection
      x: view.textX + root._advance(Math.min(root.cursorPosition, root._anchor))
      width: root._advance(Math.max(root.cursorPosition, root._anchor)) - root._advance(Math.min(root.cursorPosition, root._anchor))
      height: view.height
      color: root.selectionTint
    }

    Text {
      id: label
      textFormat: Text.PlainText
      x: view.textX
      anchors.verticalCenter: parent.verticalCenter
      text: root._display
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      onImplicitWidthChanged: root.ensureVisible()
    }

    Text {
      textFormat: Text.PlainText
      visible: root.text === ""
      x: view.textX
      anchors.verticalCenter: parent.verticalCenter
      width: view.width
      text: root.placeholderText
      color: Qt.darker(root.foreground, 1.6)
      font: label.font
      elide: Text.ElideRight
      horizontalAlignment: root.horizontalAlignment
    }

    Rectangle {
      visible: root.activeFocus && root.enabled
      x: view.textX + root._advance(root.cursorPosition)
      width: Math.max(1, Math.round(Style.space(1)))
      height: Math.min(view.height, Math.ceil(fm.height))
      anchors.verticalCenter: parent.verticalCenter
      color: root.foreground
    }
  }

  MouseArea {
    anchors.fill: parent
    enabled: root.enabled
    cursorShape: Qt.IBeamCursor
    function indexAt(mouse) {
      var x = mouse.x - view.x - view.textX
      return Logic.indexAtX(root._display, x, root._advance)
    }
    onPressed: function(mouse) {
      root.forceActiveFocus()
      root._set(Logic.setCursor(root._state(), indexAt(mouse), mouse.modifiers & Qt.ShiftModifier))
    }
    onPositionChanged: function(mouse) {
      if (pressed) root._set(Logic.setCursor(root._state(), indexAt(mouse), true))
    }
    onDoubleClicked: root.selectAll()
  }

  Item {
    id: keys
    focus: true
    Keys.onPressed: function(event) {
      var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
      var shift = (event.modifiers & Qt.ShiftModifier) !== 0
      var s = root._state()
      var done = true
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        root.accepted()
        root.editingFinished()
        return                                       // not accepted: owners still see it
      }
      if (event.key === Qt.Key_Backspace) root._edit(Logic.backspace(s, ctrl))
      else if (event.key === Qt.Key_Delete && !shift) root._edit(Logic.del(s, ctrl))
      else if (event.key === Qt.Key_Left) root._set(Logic.move(s, "left", { word: ctrl, extend: shift }))
      else if (event.key === Qt.Key_Right) root._set(Logic.move(s, "right", { word: ctrl, extend: shift }))
      else if (event.key === Qt.Key_Home) root._set(Logic.move(s, "home", { extend: shift }))
      else if (event.key === Qt.Key_End) root._set(Logic.move(s, "end", { extend: shift }))
      else if (ctrl && event.key === Qt.Key_A) root.selectAll()
      else if (ctrl && event.key === Qt.Key_C) root.copySelection()
      else if (ctrl && event.key === Qt.Key_X) {
        if (Logic.hasSelection(s) && !root.password) { root.copySelection(); root._edit(Logic.backspace(s, false)) }
      }
      else if (ctrl && (event.key === Qt.Key_Y || (shift && event.key === Qt.Key_Z))) root.redo()
      else if (ctrl && event.key === Qt.Key_Z) root.undo()
      else if ((ctrl && event.key === Qt.Key_V) || (shift && event.key === Qt.Key_Insert)) root.paste()
      else if (event.text.length > 0 && !ctrl && !(event.modifiers & Qt.MetaModifier)
               && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127)
        root._edit(Logic.insert(s, event.text, root.maxLength, root.digitsOnly))
      else done = false
      event.accepted = done
    }
  }
}
