import QtQuick
import Quickshell
import Quickshell.Io

// Serial bridge to the Python CLI. One process at a time; every command
// prints a single JSON line which is parsed and handed to the callback.
// The state file changes too, so most UI updates arrive via the FileView and
// callbacks are only used for inline errors and results.
Item {
  id: root

  property string cliPath: ""
  // The CLI bounds its own run (per-request deadlines, a 120 s budget, a 60 s
  // lock wait); this watchdog is the last line so one stuck run can never
  // block the queue for good.
  property int watchdogMs: 180000
  property bool timedOut: false
  property var queue: []
  property var current: null
  readonly property bool busy: current !== null || queue.length > 0
  readonly property string currentCommand: current ? String(current.args[0] || "") : ""

  signal finished(var args, bool ok, var result)

  visible: false

  function run(args, cb, stdinText) {
    var list = args.map(function(a) { return String(a) })
    if (list[0] === "sync") {
      // Coalesce: a queued sync already covers this request.
      for (var i = 0; i < queue.length; i++) if (queue[i].args[0] === "sync") return
    }
    queue = queue.concat([{ args: list, cb: cb || null, stdin: stdinText === undefined ? null : String(stdinText) }])
    Qt.callLater(next)
  }

  function next() {
    if (current || queue.length === 0 || !cliPath) return
    current = queue[0]
    queue = queue.slice(1)
    collector.exited = false
    collector.outDone = false
    collector.errDone = false
    collector.code = -1
    proc.stdinEnabled = current.stdin !== null
    proc.command = ["python3", root.cliPath].concat(current.args)
    root.timedOut = false
    proc.running = true
    watchdog.restart()
  }

  function finish() {
    if (!collector.exited || !collector.outDone || !collector.errDone || !current) return
    watchdog.stop()
    var job = current
    var raw = String(out.text || "").trim()
    var lines = raw.split("\n")
    var result = null
    try {
      result = JSON.parse(lines[lines.length - 1])
    } catch (e) {
      var err = String(errOut.text || "").trim().split("\n")
      result = { ok: false, error: { kind: "backend", message: root.timedOut ? "The backend took too long and was stopped"
                                     : (err[err.length - 1] || ("backend exited with " + collector.code)),
                                     details: String(errOut.text || "") } }
    }
    var ok = !!(result && result.ok)
    current = null
    if (job.cb) {
      try { job.cb(ok, result) } catch (e2) { console.warn("omarchy-toggl callback failed:", e2) }
    }
    root.finished(job.args, ok, result)
    Qt.callLater(next)
  }

  Timer {
    id: watchdog
    interval: root.watchdogMs
    repeat: false
    onTriggered: {
      if (!proc.running) return
      root.timedOut = true
      proc.running = false          // Quickshell terminates the process; finish() then reports it
    }
  }

  QtObject {
    id: collector
    property bool exited: false
    property bool outDone: false
    property bool errDone: false
    property int code: -1
  }

  Process {
    id: proc
    stdout: StdioCollector {
      id: out
      waitForEnd: true
      onStreamFinished: { collector.outDone = true; root.finish() }
    }
    stderr: StdioCollector {
      id: errOut
      waitForEnd: true
      onStreamFinished: { collector.errDone = true; root.finish() }
    }
    onStarted: {
      if (root.current && root.current.stdin !== null) {
        write(root.current.stdin + "\n")
        root.current.stdin = ""
      }
    }
    onExited: function(exitCode) {
      collector.code = exitCode
      collector.exited = true
      root.finish()
    }
  }
}
