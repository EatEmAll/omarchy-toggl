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
  visible: false

  function reload() {
    if (!root.path) return
    if (reader.running) { root._again = true; return }
    reader.command = ["timeout", "-k", "1", "5", "head", "-c", String(root.maxBytes + 1), "--", root.path]
    reader.running = true
  }

  onPathChanged: reload()

  FileView {
    path: root.path
    preload: false          // watch only: this FileView never reads the file
    watchChanges: root.watch
    printErrors: false
    onFileChanged: root.reload()
  }

  Process {
    id: reader
    property int code: -1
    stdout: StdioCollector {
      id: collected
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var bytes = collected.data ? collected.data.byteLength : 0
      if (exitCode === 0 && bytes <= root.maxBytes) root.loaded(collected.text)
      else root.loadFailed()
      if (root._again) { root._again = false; Qt.callLater(root.reload) }
    }
  }
}
