import QtQuick
import qs.Commons
import qs.Ui as Ui
import "../Model.js" as Model

// Time input accepting "14:02", "2:02pm", "-15m", "yesterday 17:30".
// `ms` is the committed value; invalid input shows an urgent border.
Ui.TextField {
  id: root
  property double ms: NaN
  property double nowMs: Date.now()
  property bool showDate: false
  readonly property double parsed: Model.parseWhen(text, nowMs)
  readonly property bool valid: text.trim() === "" || !isNaN(parsed)
  signal committed(double ms)

  function display(value) {
    if (isNaN(value)) return ""
    var key = Model.dayKey(value)
    var clock = Model.clock(Model.toIso(value))
    if (!root.showDate || key === Model.dayKey(root.nowMs)) return clock
    if (key === Model.addDays(Model.dayKey(root.nowMs), -1)) return "yesterday " + clock
    return Model.toIso(value).substring(0, 16).replace("T", " ")
  }

  function reset() { text = display(ms) }

  font.pixelSize: Style.font.bodySmall
  horizontalAlignment: TextInput.AlignHCenter
  placeholderText: "hh:mm"
  Component.onCompleted: reset()
  onMsChanged: if (!activeFocus) reset()
  onEditingFinished: {
    if (!isNaN(parsed) && parsed !== ms) root.committed(parsed)
    else reset()
  }
  // Esc resets and propagates so the owning popup/editor can close.
  Keys.onEscapePressed: function(event) { reset(); event.accepted = false }
}
