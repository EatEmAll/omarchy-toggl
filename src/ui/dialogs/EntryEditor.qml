import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui as Ui
import "../components"
import "../Model.js" as Model

// Overlay card to edit a finished entry, or create one (Calendar click).
Rectangle {
  id: root
  property var ctx: null
  readonly property var svc: ctx ? ctx.svc : null
  property var entry: null          // null => create mode
  property bool createMode: false
  property double startMs: NaN
  property double stopMs: NaN
  property var projectId: null
  property var tags: []
  property bool billable: false
  property string error: ""
  readonly property bool opened: visible
  readonly property var projects: svc ? svc.snapshot.projects : []
  readonly property var project: {
    for (var i = 0; i < projects.length; i++) if (projects[i].id === projectId) return projects[i]
    return entry && entry.projectId === projectId && projectId ? { id: projectId, name: entry.projectName, color: entry.projectColor } : null
  }

  signal closed()

  visible: false
  radius: Math.max(Style.cornerRadius, Style.space(10))
  color: Color.popups.background
  border.width: Style.normalBorderWidth
  border.color: Qt.rgba(ctx.accent.r, ctx.accent.g, ctx.accent.b, 0.35)
  implicitHeight: form.implicitHeight + Style.spacing.xxl * 2

  function openFor(e) {
    entry = e
    createMode = false
    desc.text = e.description || ""
    startMs = Model.isoMs(e.start)
    stopMs = e.stop ? Model.isoMs(e.stop) : NaN
    projectId = e.projectId || null
    tags = (e.tags || []).slice()
    billable = !!e.billable
    error = ""
    startField.ms = startMs; stopField.ms = stopMs; startField.reset(); stopField.reset()
    durField.text = Model.hms(Math.round((stopMs - startMs) / 1000))
    visible = true
    desc.forceActiveFocus()
  }

  function openCreate(fromMs, toMs) {
    entry = null
    createMode = true
    desc.text = ""
    startMs = fromMs
    stopMs = toMs
    projectId = null
    tags = []
    billable = false
    error = ""
    startField.ms = startMs; stopField.ms = stopMs; startField.reset(); stopField.reset()
    durField.text = Model.hms(Math.round((stopMs - startMs) / 1000))
    visible = true
    desc.forceActiveFocus()
  }

  function close() {
    visible = false
    root.closed()
  }

  function parseDuration(text) {
    var m = /^(\d+)(?::(\d{1,2}))?(?::(\d{1,2}))?$/.exec(String(text).trim())
    if (!m) return NaN
    if (m[3] !== undefined) return Number(m[1]) * 3600 + Number(m[2]) * 60 + Number(m[3])
    if (m[2] !== undefined) return Number(m[1]) * 3600 + Number(m[2]) * 60
    return Number(m[1]) * 60
  }

  function save() {
    if (!(stopMs > startMs)) { error = "Stop must be after start"; return }
    if (stopMs > Date.now() + 60000) { error = "Stop time is in the future"; return }
    error = ""
    var done = function(ok, result) {
      if (ok) root.close()
      else root.error = result && result.error ? result.error.message : "Save failed"
    }
    if (createMode) {
      var args = ["add", "--start", Model.toIso(startMs), "--stop", Model.toIso(stopMs),
                  "--project", projectId === null ? "none" : String(projectId)]
      for (var i = 0; i < tags.length; i++) args.push("--tag=" + tags[i])
      if (billable) args.push("--billable")
      args.push("--")
      if (desc.text.trim()) args.push(desc.text.trim())
      svc.call(args, done)
      return
    }
    var fields = {}
    if (desc.text !== (entry.description || "")) fields.description = desc.text
    if ((projectId || null) !== (entry.projectId || null)) fields.projectId = projectId
    if (JSON.stringify(tags) !== JSON.stringify(entry.tags || [])) fields.tags = tags
    if (billable !== !!entry.billable) fields.billable = billable
    if (Model.toIso(startMs) !== entry.start) fields.start = Model.toIso(startMs)
    if (entry.stop && Model.toIso(stopMs) !== entry.stop) fields.stop = Model.toIso(stopMs)
    if (Object.keys(fields).length === 0) { close(); return }
    svc.update(entry.id, fields, done)
  }

  function remove() {
    if (!entry) return
    ctx.askConfirm("Delete '" + (entry.description || "(no description)") + "'?", [entry.id])
    close()
  }

  MouseArea { anchors.fill: parent }   // swallow clicks behind the card

  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Escape) { root.close(); event.accepted = true }
    else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier)) { root.save(); event.accepted = true }
  }

  Column {
    id: form
    anchors.fill: parent
    anchors.margins: Style.spacing.xxl
    spacing: Style.spacing.lg

    Row {
      width: parent.width
      Text {
        textFormat: Text.PlainText
        width: parent.width - closeChip.width
        text: root.createMode ? "New entry" : "Edit entry"
        color: ctx.foreground
        font.family: ctx.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
      }
      ActionChip {
        id: closeChip
        text: "Esc"
        icon: "󰅖"
        foreground: ctx.foreground
        accent: ctx.accent
        fontFamily: ctx.fontFamily
        onClicked: root.close()
      }
    }

    Ui.TextField {
      id: desc
      width: parent.width
      placeholderText: "Description"
      foreground: ctx.foreground
      accent: ctx.accent
      font.family: ctx.fontFamily
      font.pixelSize: Style.font.body
      Keys.onEscapePressed: function(event) { root.close(); event.accepted = true }
      Keys.onReturnPressed: function(event) { root.save(); event.accepted = true }
    }

    Row {
      spacing: Style.spacing.md
      ProjectChip {
        id: chip
        name: root.project ? String(root.project.name || "") : ""
        projectColor: root.project ? String(root.project.color || "") : ""
        maxChars: 18
        placeholder: !root.project
        foreground: ctx.foreground
        fontFamily: ctx.fontFamily
        onClicked: projPicker.open()
        PickerPopup {
          id: projPicker
          y: parent.height + Style.spacing.xs
          placeholder: "Search projects…"
          foreground: ctx.foreground
          accent: ctx.accent
          fontFamily: ctx.fontFamily
          value: root.projectId === null ? "none" : String(root.projectId)
          items: {
            var out = [{ value: "none", label: "No project", color: "" }]
            for (var i = 0; i < root.projects.length; i++) {
              var p = root.projects[i]
              if (p.active === false) continue
              out.push({ value: String(p.id), label: p.name, color: p.color || "", detail: p.clientName || "" })
            }
            return out
          }
          onPicked: function(value) { root.projectId = value === "none" ? null : Number(value) }
        }
      }
      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        visible: !root.project
        text: "No project"
        color: Color.muted
        font.family: ctx.fontFamily
        font.pixelSize: Style.font.caption
      }
      IconToggle {
        id: tagToggle
        icon: "󰓹"
        active: root.tags.length > 0
        tooltip: root.tags.length ? root.tags.join(", ") : "Tags"
        foreground: ctx.foreground
        accent: ctx.accent
        fontFamily: ctx.fontFamily
        onClicked: tagPicker2.open()
        PickerPopup {
          id: tagPicker2
          multi: true
          y: parent.height + Style.spacing.xs
          placeholder: "Search or create tags…"
          foreground: ctx.foreground
          accent: ctx.accent
          fontFamily: ctx.fontFamily
          values: root.tags
          items: (root.svc ? root.svc.snapshot.tags : []).map(function(t) { return { value: t.name, label: t.name } })
          onChangedValues: function(values) { root.tags = values }
        }
      }
      IconToggle {
        icon: "$"
        active: root.billable
        tooltip: root.billable ? "Billable" : "Non-billable"
        foreground: ctx.foreground
        accent: ctx.accent
        fontFamily: ctx.fontFamily
        onClicked: root.billable = !root.billable
      }
      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        visible: root.tags.length > 0
        text: root.tags.join(", ")
        color: ctx.accent
        font.family: ctx.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    Grid {
      columns: 3
      columnSpacing: Style.spacing.md
      rowSpacing: Style.spacing.xs
      width: parent.width
      readonly property real cell: (width - columnSpacing * 2) / 3

      Repeater {
        model: ["START", "STOP", "DURATION"]
        delegate: Text {
          textFormat: Text.PlainText
          required property var modelData
          text: modelData
          color: Color.muted
          font.family: ctx.fontFamily
          font.pixelSize: Style.font.caption
          font.letterSpacing: 1
        }
      }
      DurationField {
        id: startField
        width: parent.cell
        showDate: true
        nowMs: root.svc ? root.svc.now : Date.now()
        foreground: ctx.foreground
        accent: ctx.accent
        font.family: ctx.fontFamily
        onCommitted: function(ms) {
          var dur = root.stopMs - root.startMs
          root.startMs = ms
          durField.text = Model.hms(Math.round((root.stopMs - root.startMs) / 1000))
        }
      }
      DurationField {
        id: stopField
        width: parent.cell
        showDate: true
        nowMs: root.svc ? root.svc.now : Date.now()
        foreground: ctx.foreground
        accent: ctx.accent
        font.family: ctx.fontFamily
        onCommitted: function(ms) {
          // A bare clock time before the start means "after midnight".
          if (ms <= root.startMs && ms + 86400000 > root.startMs) ms += 86400000
          root.stopMs = ms
          durField.text = Model.hms(Math.round((root.stopMs - root.startMs) / 1000))
        }
      }
      Ui.TextField {
        id: durField
        width: parent.cell
        foreground: ctx.foreground
        accent: ctx.accent
        font.family: ctx.fontFamily
        font.pixelSize: Style.font.bodySmall
        horizontalAlignment: TextInput.AlignHCenter
        onEditingFinished: {
          var secs = root.parseDuration(text)
          if (!isNaN(secs) && secs > 0) {
            root.stopMs = root.startMs + secs * 1000
            stopField.ms = root.stopMs
            stopField.reset()
          }
          text = Model.hms(Math.round((root.stopMs - root.startMs) / 1000))
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: root.error !== ""
      width: parent.width
      text: root.error
      color: Color.urgent
      font.family: ctx.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Row {
      spacing: Style.spacing.md
      ActionChip {
        text: root.createMode ? "Add  ⌃↵" : "Save  ⌃↵"
        icon: "󰄬"
        selected: true
        foreground: ctx.foreground
        accent: ctx.accent
        fontFamily: ctx.fontFamily
        onClicked: root.save()
      }
      ActionChip {
        visible: !root.createMode
        text: "Delete"
        icon: "󰆴"
        destructive: true
        foreground: ctx.foreground
        accent: ctx.accent
        fontFamily: ctx.fontFamily
        onClicked: root.remove()
      }
      ActionChip {
        text: "Cancel"
        foreground: ctx.foreground
        accent: ctx.accent
        fontFamily: ctx.fontFamily
        onClicked: root.close()
      }
    }
  }
}
