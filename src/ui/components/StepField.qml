import QtQuick
import qs.Commons
import qs.Ui as Ui

// Integer stepper (− value +). Replaces a spin box, whose editable text input
// would be one more clipboard-reading Qt text field.
Item {
  id: root
  property int value: 0
  property int from: 0
  property int to: 100
  property int stepSize: 1
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.body
  property real fieldWidth: Style.spacing.numberFieldWidth
  signal modified(int value)

  property int current: value
  onValueChanged: current = value

  implicitWidth: fieldWidth
  implicitHeight: Math.max(Style.spacing.controlHeight, fontSize + Style.spacing.controlPaddingY * 2)

  function step(direction) {
    var next = Math.max(from, Math.min(to, current + direction * stepSize))
    if (next === current) return
    current = next
    root.modified(next)
  }

  Ui.BorderSurface {
    anchors.fill: parent
    color: Style.controlFill(false, hover.hovered, root.foreground, root.accent)
    borderSpec: Border.controlSpec(hover.hovered ? "hover-cursor" : "normal", root.foreground, root.accent)
    radius: Style.cornerRadius
  }
  HoverHandler { id: hover }

  IconToggle {
    id: minus
    anchors.left: parent.left
    anchors.leftMargin: Style.spacing.xs
    anchors.verticalCenter: parent.verticalCenter
    implicitWidth: Style.space(22)
    implicitHeight: Style.space(22)
    icon: "󰍴"
    glyphSize: Style.font.bodySmall
    idleColor: root.foreground
    enabledState: root.current > root.from
    foreground: root.foreground
    accent: root.accent
    fontFamily: root.fontFamily
    onClicked: root.step(-1)
  }
  Text {
    textFormat: Text.PlainText
    anchors.centerIn: parent
    text: String(root.current)
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: root.fontSize
    font.features: { "tnum": 1 }
  }
  IconToggle {
    anchors.right: parent.right
    anchors.rightMargin: Style.spacing.xs
    anchors.verticalCenter: parent.verticalCenter
    implicitWidth: Style.space(22)
    implicitHeight: Style.space(22)
    icon: "󰐕"
    glyphSize: Style.font.bodySmall
    idleColor: root.foreground
    enabledState: root.current < root.to
    foreground: root.foreground
    accent: root.accent
    fontFamily: root.fontFamily
    onClicked: root.step(1)
  }
}
