import QtQuick
import Quickshell.Io

// Reads one of our cache files with a byte cap and a total deadline.
// FileView would read the whole file into the shell however large it is, so
// it is used here only to watch for changes (preload off, never read); the
// read itself is `head -c` under `timeout`. A file over `maxBytes` counts as
// a failed load, never as a truncated one.
Item {
  id: root
  property string path: ""
  property int maxBytes: 8 * 1024 * 1024
  property bool watch: true
  signal loaded(string text)
  signal loadFailed()

  property bool _again: false
  property bool _busy: false      // from start until both exit and stream end
  visible: false

  function reload() {
    if (!root.path) return
    if (root._busy) { root._again = true; return }
    root._busy = true
    root._exited = false
    root._drained = false
    reader.command = ["timeout", "-k", "1", "5", "head", "-c", String(root.maxBytes + 1), "--", root.path]
    reader.running = true
    guard.restart()
  }

  onPathChanged: reload()

  FileView {
    path: root.path
    preload: false          // watch only: this FileView never reads the file
    watchChanges: root.watch
    printErrors: false
    onFileChanged: root.reload()
  }

  // Quickshell does not order `exited` against the end of the output stream,
  // so the result is used only once both have happened.
  property bool _exited: false
  property bool _drained: false
  property int _code: -1

  function _finish() {
    if (!root._busy || !root._exited || !root._drained) return
    root._busy = false
    guard.stop()
    var bytes = collected.data ? collected.data.byteLength : 0
    if (root._code === 0 && bytes <= root.maxBytes) root.loaded(collected.text)
    else root.loadFailed()
    if (root._again) { root._again = false; Qt.callLater(root.reload) }
  }

  Process {
    id: reader
    stdout: StdioCollector {
      id: collected
      waitForEnd: true
      onStreamFinished: { root._drained = true; root._finish() }
    }
    onExited: function(exitCode) {
      root._code = exitCode
      root._exited = true
      root._finish()
    }
  }

  // Last resort if the reader never reports back (e.g. it failed to start).
  Timer {
    id: guard
    interval: 10000
    onTriggered: {
      if (!root._busy) return
      reader.running = false
      root._busy = false
      root.loadFailed()
      if (root._again) { root._again = false; Qt.callLater(root.reload) }
    }
  }
}
