import QtQuick
import qs.Commons

Rectangle {
  id: root
  property color dotColor: Color.muted
  property real size: Style.spaceReal(7)
  property bool pulsing: false
  width: size
  height: size
  radius: size / 2
  color: dotColor

  SequentialAnimation on opacity {
    running: root.pulsing
    loops: Animation.Infinite
    onRunningChanged: if (!running) root.opacity = 1
    NumberAnimation { to: 0.4; duration: 1000; easing.type: Easing.InOutSine }
    NumberAnimation { to: 1; duration: 1000; easing.type: Easing.InOutSine }
  }
}
