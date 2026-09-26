import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "ui/Model.js" as Model

// The bar pill: "● Research 0:30:05" while tracking, "󰔛 3:23" (today) when
// idle. One instance per monitor; all state lives in the shared service.
BarWidget {
  id: root
  moduleName: "io.github.eatemall.toggl"

  property var svc: null

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  readonly property var running: svc ? svc.running : null
  readonly property bool hasError: !!(svc && (svc.hasTokenError || !svc.signedIn
    || (svc.snapshot.error && svc.snapshot.error.kind === "quota")))
  readonly property string labelMode: String(opt("labelMode"))
  readonly property bool showSeconds: opt("showSeconds") !== false
  readonly property string idleDisplay: String(opt("idleDisplay"))
  readonly property string pillLabel: {
    if (!running) return ""
    var text = labelMode === "project" ? (running.projectName || running.description)
      : labelMode === "timer" ? "" : (running.description || running.projectName || "")
    return Model.elide(text, Number(opt("maxLabelChars")))
  }
  readonly property string timeText: running ? Model.hms(svc.elapsed, showSeconds) : ""
  readonly property string idleText: svc ? Model.hm(svc.todayStats.total) : ""
  readonly property color dotColor: running ? Model.projectColor(running, Color.muted) : Color.muted

  function opt(key) { return Model.setting(root.settings, key) }

  function resolveService() {
    if (root.svc) return
    var s = root.bar && root.bar.shell && typeof root.bar.shell.serviceFor === "function"
      ? root.bar.shell.serviceFor("io.github.eatemall.toggl") : null
    if (s) {
      root.svc = s
      s.applySettings(root.settings)
      root.attachPopup(panelLoader.item)
    }
  }

  function attachPopup(popup) {
    if (!popup) return
    popup.bar = root.bar
    popup.settings = root.settings
    popup.anchorItem = button
    popup.hostWidget = root
    popup.svc = root.svc
  }

  function open() { if (panelLoader.item) panelLoader.item.openFromHotkey() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function tooltip() {
    if (!svc) return "Toggl Track: starting…"
    if (!svc.signedIn) return "Toggl Track: not connected (click to sign in)"
    var err = svc.snapshot.error
    var lines = []
    if (running) lines.push((running.description || "(no description)") + (running.projectName ? " · " + running.projectName : "")
                            + "  " + Model.hms(svc.elapsed))
    lines.push("Today " + Model.hm(svc.todayStats.total) + " · Week " + Model.hm(svc.weekStats.total))
    if (err && err.kind === "quota") lines.push("API limit reached · resets in " + Model.resetsIn(err.resetsAt, svc.now))
    else if (err && err.message) lines.push(err.message)
    return lines.join("\n")
  }

  function showTotals() {
    if (!svc) return
    var body = "Today " + Model.hms(svc.todayStats.total) + " · Week " + Model.hms(svc.weekStats.total)
    var title = running ? ((running.description || "(no description)") + "  " + Model.hms(svc.elapsed)) : "Not tracking"
    svc.notify("󱎫", title, body)
  }

  visible: !(idleDisplay === "hidden" && !running && svc && svc.signedIn && !hasError)
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: button.implicitHeight

  onBarChanged: { resolveService(); attachPopup(panelLoader.item) }
  onSettingsChanged: {
    if (svc) svc.applySettings(root.settings)
    attachPopup(panelLoader.item)
  }
  Component.onCompleted: resolveService()

  Timer {
    // The service is created asynchronously; keep asking until it exists.
    interval: 400
    repeat: true
    running: root.svc === null
    onTriggered: root.resolveService()
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("ui/Panel.qml")
    visible: false
    onItemChanged: root.attachPopup(item)
  }

  Connections {
    target: root.svc
    ignoreUnknownSignals: true
    function onFocusTimerBarRequested() {
      if (panelLoader.item) panelLoader.item.requestTimerFocus()
    }
    function onViewRequested(name) {
      if (panelLoader.item) panelLoader.item.showView(name)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    labelVisible: false
    hasVisualContent: true
    horizontalMargin: root.vertical ? 0 : 6
    fixedWidth: root.vertical ? root.barSize : Math.ceil(pill.implicitWidth + scaledHorizontalMargin * 2)
    fixedHeight: root.vertical ? Math.ceil(stack.implicitHeight + scaledVerticalPadding * 2) : -1
    tooltipText: root.tooltip()

    onPressed: function(b) {
      if (b === Qt.LeftButton) root.togglePanel()
      else if (b === Qt.MiddleButton) { if (root.svc && root.svc.signedIn) root.svc.toggle() }
      else if (b === Qt.RightButton) root.showTotals()
    }

    // Horizontal pill ------------------------------------------------------
    Row {
      id: pill
      visible: !root.vertical
      anchors.centerIn: parent
      spacing: Style.spaceReal(4)

      Item {
        width: Style.spaceReal(7)
        height: width
        visible: !!root.running
        anchors.verticalCenter: parent.verticalCenter

        Rectangle {
          anchors.centerIn: parent
          width: Style.spaceReal(7)
          height: width
          radius: width / 2
          color: root.dotColor
        }
      }

      Item {
        visible: !root.running
        width: idleIcon.implicitWidth
        height: idleIcon.implicitHeight
        anchors.verticalCenter: parent.verticalCenter

        Text {
          id: idleIcon
          text: "󰔛"
          color: button.foreground
          opacity: 0.75
          font.family: button.fontFamily
          font.pixelSize: button.fontSize
          renderType: Text.NativeRendering
        }

        Rectangle {
          visible: root.hasError
          width: Style.spaceReal(5)
          height: width
          radius: width / 2
          color: Color.urgent
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.rightMargin: -Style.spaceReal(2)
        }
      }

      Text {
        visible: text !== ""
        text: root.pillLabel
        color: button.foreground
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        renderType: Text.NativeRendering
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        visible: text !== ""
        text: root.running ? root.timeText : (root.idleDisplay === "today-total" && root.svc && root.svc.signedIn ? root.idleText : "")
        color: button.foreground
        opacity: root.running ? 1 : 0.7
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        font.features: { "tnum": 1 }
        font.bold: !!root.running
        renderType: Text.NativeRendering
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    // Vertical bar: stacked dot / hours / minutes ------------------------
    Column {
      id: stack
      visible: root.vertical
      anchors.centerIn: parent
      spacing: Style.spaceReal(1)

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.running ? "●" : "󰔛"
        color: root.running ? root.dotColor : button.foreground
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: !!root.running
        text: root.running ? String(Math.floor(root.svc.elapsed / 3600)) : ""
        color: button.foreground
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: !!root.running
        text: root.running ? String(Math.floor(root.svc.elapsed % 3600 / 60)).padStart(2, "0") : ""
        color: button.foreground
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
      }
    }
  }
}
