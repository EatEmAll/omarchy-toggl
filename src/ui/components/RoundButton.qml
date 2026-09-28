import QtQuick
import qs.Commons

// The Toggl-style round start/stop button. The play triangle and stop square
// are drawn rather than typed: text glyphs like "▶" fall back to fonts that
// render them as slanted arrows and sit off-centre.
Rectangle {
  id: root
  property string kind: "play"          // "play" | "stop"
  property color fill: Color.accent
  property color glyphColor: "white"
  property string fontFamily: Style.font.family
  property bool busy: false
  signal clicked()

  implicitWidth: Style.space(36)
  implicitHeight: implicitWidth
  radius: width / 2
  color: mouse.pressed ? Qt.darker(fill, 1.25) : (mouse.containsMouse ? Qt.lighter(fill, 1.12) : fill)
  Behavior on color { ColorAnimation { duration: 100 } }

  // Play: a right-pointing triangle's centroid sits a third of the way in from
  // its flat edge, so a box-centred triangle looks left-heavy. Shift it right
  // by w/6 to put the centroid on the circle's centre, snapped to whole pixels
  // (fractional positions blur the edge into a coloured fringe).
  Canvas {
    id: play
    visible: !root.busy && root.kind === "play"
    width: Math.round(root.width * 0.34)
    height: Math.round(width * 1.12)
    x: Math.round((root.width - width) / 2 + width / 6)
    y: Math.floor((root.height - height) / 2)
    antialiasing: true
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      ctx.fillStyle = root.glyphColor
      ctx.beginPath()
      ctx.moveTo(0, 0)
      ctx.lineTo(width, height / 2)
      ctx.lineTo(0, height)
      ctx.closePath()
      ctx.fill()
    }
    onWidthChanged: requestPaint()
    onVisibleChanged: requestPaint()
    Connections {
      target: root
      function onGlyphColorChanged() { play.requestPaint() }
    }
  }

  Rectangle {
    visible: !root.busy && root.kind === "stop"
    width: Math.round(root.width * 0.3)
    height: width
    radius: Math.max(1, width * 0.12)
    anchors.centerIn: parent
    color: root.glyphColor
  }

  Text {
    textFormat: Text.PlainText
    visible: root.busy
    anchors.centerIn: parent
    text: "󰑓"
    color: root.glyphColor
    font.family: root.fontFamily
    font.pixelSize: Style.font.heading
    RotationAnimator on rotation {
      running: root.busy
      from: 0; to: 360; duration: 900; loops: Animation.Infinite
      onRunningChanged: if (!running) parent.rotation = 0
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}
