import QtQuick
import qs.Commons
import qs.Ui

// Small square glyph button (tags / billable / gear / compact). Accent when
// active, muted otherwise, hover tint like omarchy-stats chips.
Rectangle {
  id: root
  property string icon: ""
  property bool active: false
  property bool enabledState: true
  property string tooltip: ""
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property real glyphSize: Style.font.body
  property color idleColor: Color.muted
  // Spins the glyph only; the button's own box (hover tint, outline) stays put.
  property bool spinning: false
  signal clicked()

  implicitWidth: Style.space(26)
  implicitHeight: Style.space(26)
  radius: Math.max(Style.cornerRadius, Style.space(6))
  opacity: enabledState ? 1 : 0.4
  color: mouse.containsMouse && enabledState
    ? Qt.rgba(foreground.r, foreground.g, foreground.b, 0.08)
    : (active ? Qt.rgba(accent.r, accent.g, accent.b, 0.12) : "transparent")
  border.width: active ? Style.spacing.hairline : 0
  border.color: Qt.rgba(accent.r, accent.g, accent.b, 0.28)

  onSpinningChanged: if (!spinning) glyph.rotation = 0

  Text {
    id: glyph
    textFormat: Text.PlainText
    anchors.centerIn: parent
    text: root.icon
    color: root.active ? root.accent : root.idleColor
    font.family: root.fontFamily
    font.pixelSize: root.glyphSize
    font.bold: true
    NumberAnimation on rotation {
      running: root.spinning
      from: 0; to: 360; duration: 900; loops: Animation.Infinite
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    enabled: root.enabledState
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }

  PanelToolTip {
    visible: mouse.containsMouse && root.tooltip !== ""
    text: root.tooltip
  }
}
