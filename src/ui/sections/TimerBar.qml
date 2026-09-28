import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui as Ui
import "../components"
import "../Model.js" as Model

// Top row of the web app: description · project chip · tags · $ · elapsed · round button.
// Idle: the description field is the quick-start input ("Research @stonks #deep $").
Item {
  id: root

  property var ctx: null
  readonly property var svc: ctx ? ctx.svc : null
  readonly property var running: svc ? svc.running : null
  readonly property bool editing: field.activeFocus
  readonly property var projects: svc && svc.snapshot ? svc.snapshot.projects : []
  readonly property var tags: svc && svc.snapshot ? svc.snapshot.tags : []

  // Draft values for the next entry when nothing runs.
  property var draftProjectId: undefined
  property var draftTags: []
  property bool draftBillable: false
  property int suggestionIndex: -1
  property var suggestions: []

  readonly property var chipProject: {
    var pid = running ? running.projectId : draftProjectId
    if (pid === undefined || pid === null) return null
    for (var i = 0; i < projects.length; i++) if (projects[i].id === pid) return projects[i]
    return running ? { id: pid, name: running.projectName || "", color: running.projectColor || "" } : null
  }
  readonly property var activeTags: running ? (running.tags || []) : draftTags
  readonly property bool activeBillable: running ? !!running.billable : draftBillable
  readonly property bool showSuggestions: editing && !running && suggestions.length > 0

  implicitHeight: Style.space(44)

  function focusInput() {
    field.forceActiveFocus()
    if (!running) field.selectAll()
  }

  function resetText() {
    field.text = running ? (running.description || "") : ""
  }

  function recomputeSuggestions() {
    if (!svc || running || !editing) { suggestions = []; suggestionIndex = -1; return }
    suggestions = Model.suggest(field.text, svc.allEntries, projects, tags, 6)
    suggestionIndex = field.text.trim() === "" ? -1 : (suggestions.length ? 0 : -1)
    if (suggestions.length && suggestions[0].kind !== "entry") suggestionIndex = 0
  }

  function applySuggestion(s) {
    if (!s) return false
    if (s.kind === "entry") {
      var e = s.entry
      svc.start(e.description || "", { projectId: e.projectId === undefined ? null : e.projectId,
                                       tags: e.tags || [], billable: !!e.billable }, afterStart)
      return true
    }
    field.text = s.completion
    field.cursorPosition = field.text.length
    return false
  }

  function afterStart(ok, result) {
    if (!ok) return
    root.draftProjectId = undefined
    root.draftTags = []
    root.draftBillable = false
    root.resetText()
    if (ctx) ctx.focusCatcher()
  }

  function submit() {
    if (!svc) return
    if (running) {
      if (field.text !== (running.description || "")) svc.update(running.id, { description: field.text })
      if (ctx) ctx.focusCatcher()
      return
    }
    if (showSuggestions && suggestionIndex >= 0) {
      if (applySuggestion(suggestions[suggestionIndex])) return
      return
    }
    var extra = { tags: draftTags, billable: draftBillable }
    if (draftProjectId !== undefined) extra.projectId = draftProjectId
    svc.start(field.text, extra, afterStart)
  }

  function primaryAction() {
    if (!svc) return
    if (running) svc.stop()
    else submit()
  }

  onRunningChanged: if (!editing) resetText()
  Component.onCompleted: resetText()

  Rectangle {
    anchors.fill: parent
    radius: Math.max(Style.cornerRadius, Style.space(9))
    color: Qt.rgba(ctx.foreground.r, ctx.foreground.g, ctx.foreground.b, root.editing ? 0.05 : 0.025)
    border.width: Style.spacing.hairline
    border.color: root.editing ? Qt.rgba(ctx.accent.r, ctx.accent.g, ctx.accent.b, 0.35)
      : Qt.rgba(ctx.foreground.r, ctx.foreground.g, ctx.foreground.b, 0.055)
  }

  Row {
    id: row
    anchors.fill: parent
    anchors.leftMargin: Style.spacing.md
    anchors.rightMargin: Style.spacing.xs
    spacing: Style.spacing.sm

    Ui.TextField {
      id: field
      width: row.width - chip.width - tagBtn.width - billBtn.width - elapsed.width - round.width - row.spacing * 5
      anchors.verticalCenter: parent.verticalCenter
      placeholderText: root.svc && !root.svc.signedIn ? "Connect Toggl in Settings" : "What are you working on?"
      enabled: !!(root.svc && root.svc.signedIn)
      foreground: ctx.foreground
      accent: ctx.accent
      font.family: ctx.fontFamily
      font.pixelSize: Style.font.subtitle
      font.bold: !!root.running
      background: Item {}
      horizontalPadding: Style.spacing.sm
      onTextChanged: root.recomputeSuggestions()
      onActiveFocusChanged: {
        if (!activeFocus) { root.resetText(); root.suggestions = [] }
        else root.recomputeSuggestions()
      }
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          root.resetText()
          if (ctx) ctx.focusCatcher()
          event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          root.submit()
          event.accepted = true
        } else if (event.key === Qt.Key_Down && root.showSuggestions) {
          root.suggestionIndex = Math.min(root.suggestions.length - 1, root.suggestionIndex + 1)
          event.accepted = true
        } else if (event.key === Qt.Key_Up && root.showSuggestions) {
          root.suggestionIndex = Math.max(-1, root.suggestionIndex - 1)
          event.accepted = true
        } else if (event.key === Qt.Key_Tab && root.showSuggestions && root.suggestionIndex >= 0) {
          var s = root.suggestions[root.suggestionIndex]
          if (s.kind === "entry") field.text = s.entry.description || ""
          else field.text = s.completion
          field.cursorPosition = field.text.length
          event.accepted = true
        }
      }
    }

    ProjectChip {
      id: chip
      anchors.verticalCenter: parent.verticalCenter
      name: root.chipProject ? String(root.chipProject.name || "") : ""
      projectColor: root.chipProject ? String(root.chipProject.color || "") : ""
      maxChars: root.running ? 6 : 8
      foreground: ctx.foreground
      fontFamily: ctx.fontFamily
      onClicked: projectPicker.open()

      PickerPopup {
        id: projectPicker
        y: parent.height + Style.spacing.xs
        x: Math.min(0, root.width - width - chip.x)
        placeholder: "Search projects…"
        foreground: ctx.foreground
        accent: ctx.accent
        fontFamily: ctx.fontFamily
        value: root.chipProject ? String(root.chipProject.id) : "none"
        items: {
          var out = [{ value: "none", label: "No project", color: "" }]
          for (var i = 0; i < root.projects.length; i++) {
            var p = root.projects[i]
            if (p.active === false) continue
            out.push({ value: String(p.id), label: p.name, color: p.color || "", detail: p.clientName || "" })
          }
          return out
        }
        onPicked: function(value) {
          var pid = value === "none" ? null : Number(value)
          if (root.running) root.svc.update(root.running.id, { projectId: pid })
          else root.draftProjectId = pid
        }
        onClosed: if (ctx) ctx.focusCatcher()
      }
    }

    IconToggle {
      id: tagBtn
      anchors.verticalCenter: parent.verticalCenter
      icon: "󰓹"
      active: root.activeTags.length > 0
      tooltip: root.activeTags.length ? root.activeTags.join(", ") : "Tags"
      foreground: ctx.foreground
      accent: ctx.accent
      fontFamily: ctx.fontFamily
      onClicked: tagPicker.open()

      PickerPopup {
        id: tagPicker
        multi: true
        y: parent.height + Style.spacing.xs
        x: Math.min(0, root.width - width - tagBtn.x)
        placeholder: "Search or create tags…"
        emptyText: "No tags yet"
        foreground: ctx.foreground
        accent: ctx.accent
        fontFamily: ctx.fontFamily
        values: root.activeTags
        items: root.tags.map(function(t) { return { value: t.name, label: t.name } })
        onChangedValues: function(values) { if (!root.running) root.draftTags = values }
        onClosed: {
          if (root.running && JSON.stringify(values) !== JSON.stringify(root.running.tags || []))
            root.svc.update(root.running.id, { tags: values })
          if (ctx) ctx.focusCatcher()
        }
      }
    }

    IconToggle {
      id: billBtn
      anchors.verticalCenter: parent.verticalCenter
      icon: "$"
      active: root.activeBillable
      tooltip: root.activeBillable ? "Billable" : "Non-billable"
      foreground: ctx.foreground
      accent: ctx.accent
      fontFamily: ctx.fontFamily
      onClicked: {
        if (root.running) root.svc.update(root.running.id, { billable: !root.running.billable })
        else root.draftBillable = !root.draftBillable
      }
    }

    Text {
      textFormat: Text.PlainText
      id: elapsed
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(implicitWidth, Style.space(64))
      horizontalAlignment: Text.AlignRight
      text: root.running ? Model.hms(root.svc.elapsed) : "0:00:00"
      color: root.running ? ctx.foreground : Color.muted
      font.family: ctx.fontFamily
      font.pixelSize: Style.font.heading
      font.bold: true
      font.features: { "tnum": 1 }

      MouseArea {
        id: elapsedMouse
        anchors.fill: parent
        enabled: !!root.running
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: startPopup.open()
      }
      Ui.PanelToolTip {
        visible: elapsedMouse.containsMouse && !!root.running
        text: root.running ? "Started " + Model.clock(root.running.start) + " · click to change" : ""
      }

      Popup {
        id: startPopup
        y: parent.height + Style.spacing.xs
        x: parent.width - width
        width: Style.space(200)
        padding: Style.spacing.lg
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
        background: Rectangle {
          color: Color.popups.background
          border.color: Color.popups.border
          border.width: Style.normalBorderWidth
          radius: Style.cornerRadius
        }
        onOpened: { startField.ms = Model.isoMs(root.running ? root.running.start : ""); startField.reset(); startField.forceActiveFocus(); startField.selectAll() }
        onClosed: if (ctx) ctx.focusCatcher()
        contentItem: Column {
          spacing: Style.spacing.md
          Text {
            textFormat: Text.PlainText
            text: "START TIME"
            color: Color.muted
            font.family: ctx.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1
          }
          DurationField {
            id: startField
            width: parent.width
            showDate: true
            nowMs: root.svc ? root.svc.now : Date.now()
            foreground: ctx.foreground
            accent: ctx.accent
            font.family: ctx.fontFamily
            onCommitted: function(ms) {
              if (root.running) root.svc.update(root.running.id, { start: Model.toIso(ms) })
              startPopup.close()
            }
            Keys.onReturnPressed: function(event) { focus = false; event.accepted = true }
          }
          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "14:02 · 2:02pm · -15m · yesterday 17:30"
            color: Color.muted
            font.family: ctx.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }

    RoundButton {
      id: round
      anchors.verticalCenter: parent.verticalCenter
      implicitWidth: Style.space(34)
      kind: root.running ? "stop" : "play"
      fill: root.running ? Color.urgent : ctx.accent
      glyphColor: Color.background
      fontFamily: ctx.fontFamily
      busy: !!(root.svc && root.svc.busy && ["start", "stop", "continue", "toggle"].indexOf(root.svc.busyCommand) !== -1)
      opacity: root.svc && root.svc.signedIn ? 1 : 0.4
      onClicked: if (root.svc && root.svc.signedIn) root.primaryAction()
    }
  }

  // Suggestion dropdown, overlaid on the content below (TimerBar has a raised z).
  Rectangle {
    id: suggestBox
    visible: root.showSuggestions
    y: root.height + Style.spacing.xs
    width: root.width
    height: suggestCol.implicitHeight + Style.spacing.xs * 2
    radius: Math.max(Style.cornerRadius, Style.space(8))
    color: Color.popups.background
    border.width: Style.normalBorderWidth
    border.color: Color.popups.border
    z: 50

    Column {
      id: suggestCol
      anchors.fill: parent
      anchors.margins: Style.spacing.xs
      Repeater {
        model: root.suggestions
        delegate: Rectangle {
          required property var modelData
          required property int index
          width: suggestCol.width
          height: Style.space(30)
          radius: Math.max(Style.cornerRadius, Style.space(5))
          color: index === root.suggestionIndex ? Qt.rgba(ctx.accent.r, ctx.accent.g, ctx.accent.b, 0.14)
            : (sMouse.containsMouse ? Qt.rgba(ctx.foreground.r, ctx.foreground.g, ctx.foreground.b, 0.06) : "transparent")
          Row {
            anchors.fill: parent
            anchors.leftMargin: Style.spacing.lg
            anchors.rightMargin: Style.spacing.lg
            spacing: Style.spacing.lg
            ProjectDot {
              anchors.verticalCenter: parent.verticalCenter
              visible: modelData.kind !== "tag"
              dotColor: modelData.color ? modelData.color : Color.muted
            }
            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - Style.space(120)
              text: modelData.label
              color: modelData.kind === "project" && modelData.color ? modelData.color : ctx.foreground
              font.family: ctx.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }
            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(90)
              text: modelData.kind === "entry" ? (modelData.projectName || "") : (modelData.kind === "project" ? "project" : "tag")
              color: modelData.kind === "entry" && modelData.color ? modelData.color : Color.muted
              font.family: ctx.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignRight
              elide: Text.ElideRight
            }
          }
          MouseArea {
            id: sMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { root.suggestionIndex = index; root.applySuggestion(modelData) }
          }
        }
      }
    }
  }
}
