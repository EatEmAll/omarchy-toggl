import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui as Ui
import "../components"
import "../Model.js" as Model

// Behind the gear: account/token, widget settings (written to shell.json via
// updateEntryInline) and API quota. The shell has no generic settings form.
Flickable {
  id: root
  property var ctx: null
  readonly property var svc: ctx ? ctx.svc : null
  readonly property var st: svc ? svc.snapshot : Model.emptyState()
  readonly property var auth: st.auth || {}
  readonly property var quota: st.quota || {}
  property string doctorText: ""
  property string loginError: ""
  property bool loggingIn: false
  readonly property bool editingText: tokenField.activeFocus || wsField.activeFocus

  clip: true
  contentHeight: body.implicitHeight + Style.spacing.xl
  boundsBehavior: Flickable.StopAtBounds
  ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

  function opt(key) { return svc ? svc.opt(key) : Model.DEFAULTS[key] }
  function save(key, value) { var p = {}; p[key] = value; if (svc) svc.saveSettings(p) }
  function focusToken() { tokenField.forceActiveFocus() }

  function connect() {
    var token = tokenField.text.trim()
    if (!token || !svc) return
    root.loggingIn = true
    root.loginError = ""
    svc.login(token, function(ok, result) {
      root.loggingIn = false
      if (!ok) root.loginError = result && result.error ? result.error.message : "Sign-in failed"
      else ctx.toggleSettings(false)
    })
    tokenField.text = ""
  }

  component SectionTitle: Text {
    textFormat: Text.PlainText
    color: Color.muted
    font.family: ctx.fontFamily
    font.pixelSize: Style.font.caption
    font.letterSpacing: 1
    font.bold: true
  }

  component SettingRow: Item {
    id: settingRow
    property string label: ""
    property string hint: ""
    default property alias control: holder.data
    width: parent ? parent.width : 0
    height: Math.max(Style.space(34), labels.implicitHeight + Style.spacing.md)
    Column {
      id: labels
      anchors.left: parent.left
      anchors.right: holder.left
      anchors.rightMargin: Style.spacing.lg
      anchors.verticalCenter: parent.verticalCenter
      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: settingRow.label
        color: ctx.foreground
        font.family: ctx.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }
      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: settingRow.hint !== ""
        text: settingRow.hint
        color: Color.muted
        font.family: ctx.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
    Item {
      id: holder
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: childrenRect.width
      height: childrenRect.height
    }
  }

  Column {
    id: body
    width: root.width
    spacing: Style.spacing.xl

    // Account ---------------------------------------------------------------
    SectionTitle { text: "ACCOUNT" }
    SurfaceCard {
      width: parent.width
      foreground: ctx.foreground
      accent: ctx.accent
      fontFamily: ctx.fontFamily
      padding: Style.spacing.xl

      Row {
        visible: !!root.auth.ok
        width: parent.width
        spacing: Style.spacing.lg
        Text {
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          text: "●"
          color: ctx.accent
          font.pixelSize: Style.font.body
        }
        Column {
          width: parent.width - signOut.width - Style.space(30)
          anchors.verticalCenter: parent.verticalCenter
          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "Connected as " + (root.auth.user ? (root.auth.user.fullname || root.auth.user.email || "") : "")
            color: ctx.foreground
            font.family: ctx.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            elide: Text.ElideRight
          }
          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: (root.auth.user && root.auth.user.email ? root.auth.user.email + " · " : "")
              + "token in " + (root.auth.source === "keyring" ? "keyring" : root.auth.source === "file" ? "0600 file" : String(root.auth.source || "?"))
            color: Color.muted
            font.family: ctx.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
        ActionChip {
          id: signOut
          anchors.verticalCenter: parent.verticalCenter
          text: "Sign out"
          destructive: true
          foreground: ctx.foreground
          accent: ctx.accent
          fontFamily: ctx.fontFamily
          onClicked: root.svc.logout()
        }
      }

      Column {
        visible: !root.auth.ok
        width: parent.width
        spacing: Style.spacing.md
        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: "Paste your Toggl Track API token. It is stored in the system keyring (or a 0600 file) and never written to shell.json."
          color: ctx.foreground
          font.family: ctx.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
        Row {
          width: parent.width
          spacing: Style.spacing.md
          Ui.TextField {
            id: tokenField
            width: parent.width - connectChip.width - parent.spacing
            password: true
            placeholderText: "API token"
            foreground: ctx.foreground
            accent: ctx.accent
            font.family: ctx.fontFamily
            font.pixelSize: Style.font.bodySmall
            onAccepted: root.connect()
            Keys.onEscapePressed: function(event) { text = ""; ctx.focusCatcher(); event.accepted = true }
          }
          ActionChip {
            id: connectChip
            text: root.loggingIn ? "Connecting…" : "Connect"
            selected: true
            foreground: ctx.foreground
            accent: ctx.accent
            fontFamily: ctx.fontFamily
            onClicked: root.connect()
          }
        }
        Text {
          textFormat: Text.PlainText
          visible: root.loginError !== ""
          width: parent.width
          text: root.loginError
          color: Color.urgent
          font.family: ctx.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
        Text {
          textFormat: Text.PlainText
          text: "Find it at track.toggl.com/profile ↗"
          color: ctx.accent
          font.family: ctx.fontFamily
          font.pixelSize: Style.font.caption
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: { Util.execArgv(["xdg-open", "https://track.toggl.com/profile"]); ctx.close() }
          }
        }
      }

      SettingRow {
        visible: !!root.auth.ok && (root.auth.workspaces || []).length > 1
        label: "Workspace"
        Ui.Dropdown {
          width: Style.space(170)
          showLabel: false
          foreground: ctx.foreground
          accent: ctx.accent
          fontFamily: ctx.fontFamily
          value: String(root.opt("workspaceId") || root.auth.workspaceId || "")
          options: (root.auth.workspaces || []).map(function(w) { return { value: String(w.id), label: w.name } })
          onChanged: function(value) { root.save("workspaceId", value) }
        }
      }
    }

    // Widget ------------------------------------------------------------------
    SectionTitle { text: "WIDGET" }
    SurfaceCard {
      width: parent.width
      foreground: ctx.foreground
      accent: ctx.accent
      fontFamily: ctx.fontFamily
      padding: Style.spacing.xl
      contentSpacing: Style.spacing.xs

      SettingRow {
        label: "Pill label"
        Ui.Dropdown {
          width: Style.space(150)
          showLabel: false
          foreground: ctx.foreground
          accent: ctx.accent
          fontFamily: ctx.fontFamily
          value: String(root.opt("labelMode"))
          options: [{ value: "description", label: "Description" }, { value: "project", label: "Project" }, { value: "timer", label: "Timer only" }]
          onChanged: function(value) { root.save("labelMode", value) }
        }
      }
      SettingRow {
        label: "When no timer runs"
        Ui.Dropdown {
          width: Style.space(150)
          showLabel: false
          foreground: ctx.foreground
          accent: ctx.accent
          fontFamily: ctx.fontFamily
          value: String(root.opt("idleDisplay"))
          options: [{ value: "today-total", label: "Today's total" }, { value: "icon", label: "Icon only" }, { value: "hidden", label: "Hide pill" }]
          onChanged: function(value) { root.save("idleDisplay", value) }
        }
      }
      SettingRow {
        label: "Default view"
        Ui.Dropdown {
          width: Style.space(150)
          showLabel: false
          foreground: ctx.foreground
          accent: ctx.accent
          fontFamily: ctx.fontFamily
          value: String(root.opt("defaultView"))
          options: [{ value: "list", label: "List view" }, { value: "timesheet", label: "Timesheet" }, { value: "calendar", label: "Calendar" }]
          onChanged: function(value) { root.save("defaultView", value) }
        }
      }
      SettingRow {
        label: "Timer in bar"
        hint: "Right-click the pill while tracking to cycle"
        Ui.Dropdown {
          width: Style.space(150)
          showLabel: false
          foreground: ctx.foreground
          accent: ctx.accent
          fontFamily: ctx.fontFamily
          value: Model.timerMode(root.svc ? root.svc.settings : null)
          options: [{ value: "hms", label: "0:30:05" }, { value: "hm", label: "0:30" }, { value: "hidden", label: "Hidden" }]
          onChanged: function(value) { root.save("timerMode", value) }
        }
      }
      SettingRow {
        label: "Group similar entries"
        hint: "Same description, project and tags on a day"
        Ui.ToggleSwitch {
          checked: Model.flag(root.opt("groupSimilar"))
          foreground: ctx.foreground
          accent: ctx.accent
          onToggled: root.save("groupSimilar", !checked)
        }
      }
      SettingRow {
        label: "Max label length"
        Ui.NumberField {
          from: 6; to: 40
          value: Number(root.opt("maxLabelChars"))
          foreground: ctx.foreground
          accent: ctx.accent
          fontFamily: ctx.fontFamily
          onModified: function(v) { root.save("maxLabelChars", v) }
        }
      }
      SettingRow {
        label: "Background sync (minutes)"
        hint: "Each sync costs one of 30 hourly /me API calls"
        Ui.NumberField {
          from: 3; to: 60
          value: Number(root.opt("syncMinutes"))
          foreground: ctx.foreground
          accent: ctx.accent
          fontFamily: ctx.fontFamily
          onModified: function(v) { root.save("syncMinutes", v) }
        }
      }
      SettingRow {
        label: "Days of entries to keep"
        Ui.NumberField {
          from: 2; to: 14
          value: Number(root.opt("historyDays"))
          foreground: ctx.foreground
          accent: ctx.accent
          fontFamily: ctx.fontFamily
          onModified: function(v) { root.save("historyDays", v) }
        }
      }
      SettingRow {
        label: "Idle detection (minutes)"
        hint: "0 turns it off"
        Ui.NumberField {
          from: 0; to: 120
          value: Number(root.opt("idleMinutes"))
          foreground: ctx.foreground
          accent: ctx.accent
          fontFamily: ctx.fontFamily
          onModified: function(v) { root.save("idleMinutes", v) }
        }
      }
      SettingRow {
        label: "Not-tracking reminder (minutes)"
        hint: "0 turns it off"
        Ui.NumberField {
          from: 0; to: 240; stepSize: 5
          value: Number(root.opt("remindMinutes"))
          foreground: ctx.foreground
          accent: ctx.accent
          fontFamily: ctx.fontFamily
          onModified: function(v) { root.save("remindMinutes", v) }
        }
      }
      SettingRow {
        label: "Workspace ID"
        hint: "Empty uses your default workspace"
        Ui.TextField {
          id: wsField
          width: Style.space(120)
          text: String(root.opt("workspaceId") || "")
          placeholderText: "default"
          foreground: ctx.foreground
          accent: ctx.accent
          font.family: ctx.fontFamily
          font.pixelSize: Style.font.bodySmall
          validator: RegularExpressionValidator { regularExpression: /[0-9]*/ }
          onEditingFinished: if (text !== String(root.opt("workspaceId") || "")) root.save("workspaceId", text)
          Keys.onEscapePressed: function(event) { ctx.focusCatcher(); event.accepted = true }
        }
      }
    }

    // API ------------------------------------------------------------------
    SectionTitle { text: "API" }
    SurfaceCard {
      width: parent.width
      foreground: ctx.foreground
      accent: ctx.accent
      fontFamily: ctx.fontFamily
      padding: Style.spacing.xl
      contentSpacing: Style.spacing.md

      StatPair {
        width: parent.width
        label: "Personal (/me) requests left"
        value: root.quota.user && root.quota.user.remaining !== undefined
          ? root.quota.user.remaining + "/30 · resets " + Model.resetsIn(root.quota.user.resetsAt, root.svc ? root.svc.now : Date.now()) : "—"
        foreground: ctx.foreground
        fontFamily: ctx.fontFamily
      }
      StatPair {
        width: parent.width
        label: "Workspace requests left"
        value: root.quota.workspace && root.quota.workspace.remaining !== undefined
          ? root.quota.workspace.remaining + " · resets " + Model.resetsIn(root.quota.workspace.resetsAt, root.svc ? root.svc.now : Date.now()) : "—"
        foreground: ctx.foreground
        fontFamily: ctx.fontFamily
      }
      StatPair {
        width: parent.width
        label: "Last sync"
        value: Model.relativeAge(root.st.lastSyncAt, root.svc ? root.svc.now : Date.now())
        foreground: ctx.foreground
        fontFamily: ctx.fontFamily
      }
      StatPair {
        width: parent.width
        label: "Queued offline changes"
        value: String((root.st.pending || []).length)
        foreground: ctx.foreground
        fontFamily: ctx.fontFamily
      }
      Row {
        spacing: Style.spacing.md
        ActionChip {
          text: "Refresh metadata"
          icon: "󰑓"
          foreground: ctx.foreground
          accent: ctx.accent
          fontFamily: ctx.fontFamily
          onClicked: root.svc.refresh(true, true)
        }
        ActionChip {
          text: "Run doctor"
          icon: "󰓙"
          foreground: ctx.foreground
          accent: ctx.accent
          fontFamily: ctx.fontFamily
          onClicked: root.svc.doctor(function(ok, result) {
            var d = result && result.doctor ? result.doctor : result
            var lines = []
            for (var k in d) lines.push(k + ": " + JSON.stringify(d[k]))
            root.doctorText = lines.join("\n")
          })
        }
      }
      Rectangle {
        visible: root.doctorText !== ""
        width: parent.width
        height: doctorLabel.implicitHeight + Style.spacing.lg * 2
        radius: Math.max(Style.cornerRadius, Style.space(6))
        color: Qt.rgba(ctx.foreground.r, ctx.foreground.g, ctx.foreground.b, 0.04)
        Text {
          textFormat: Text.PlainText
          id: doctorLabel
          anchors.fill: parent
          anchors.margins: Style.spacing.lg
          text: root.doctorText
          color: ctx.foreground
          font.family: "monospace"
          font.pixelSize: Style.font.caption
          wrapMode: Text.WrapAnywhere
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: "Keys: n or / new entry · s stop · space stop/continue · 1-3 views · , settings · [ ] range · t today · f search · j/k move · h/l fold · ↵ continue · e edit · x delete · m menu · v select · r sync · c compact"
      color: Color.muted
      font.family: ctx.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }
}
