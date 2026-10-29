import QtQuick
import qs.Commons
import qs.Commons as Commons

// qpc.power: circular charge gauge. `fraction` 0..1 fills clockwise from the
// top; `text` sits in the middle.
Item {
  id: root

  property real fraction: 0
  property int size: 64
  property int stroke: 6
  property color trackColor: Util.alpha(Commons.Color.foreground, 0.12)
  property color fillColor: Commons.Color.foreground
  property string text: ""
  property string fontFamily: Style.font.family

  implicitWidth: size
  implicitHeight: size

  Behavior on fraction { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }

  onFractionChanged: canvas.requestPaint()
  onTrackColorChanged: canvas.requestPaint()
  onFillColorChanged: canvas.requestPaint()
  onStrokeChanged: canvas.requestPaint()

  Canvas {
    id: canvas
    anchors.fill: parent
    antialiasing: true

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var centre = width / 2
      var radius = (Math.min(width, height) - root.stroke) / 2
      ctx.lineWidth = root.stroke
      ctx.lineCap = "butt"

      ctx.strokeStyle = root.trackColor
      ctx.beginPath()
      ctx.arc(centre, centre, radius, 0, 2 * Math.PI)
      ctx.stroke()

      var f = Math.max(0, Math.min(1, root.fraction))
      if (f > 0) {
        ctx.strokeStyle = root.fillColor
        ctx.beginPath()
        ctx.arc(centre, centre, radius, -Math.PI / 2, -Math.PI / 2 + 2 * Math.PI * f)
        ctx.stroke()
      }
    }
  }

  Text {
    anchors.centerIn: parent
    textFormat: Text.PlainText
    text: root.text
    color: root.fillColor
    font.family: root.fontFamily
    font.pixelSize: Style.font.title
    font.bold: true
  }
}
