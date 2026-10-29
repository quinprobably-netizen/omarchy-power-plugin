import QtQuick
import qs.Commons
import qs.Commons as Commons

// qpc.power: one-of-N chooser drawn as adjoining cells. `model` is
// [{value, label}]; clicking a cell other than the current one emits
// selected(value). The caller owns `value` and updates it after the write.
Item {
  id: root

  property QtObject bar: null
  property var model: []
  property var value
  property bool busy: false

  signal selected(var value)

  readonly property int cellCount: Array.isArray(model) ? model.length : 0
  readonly property color fg: bar ? bar.foreground : Commons.Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  // Cells are sized by label length (the shell font is monospace, so that is
  // proportional to the painted width) with two characters of padding each.
  function labelWeight(i) { return String(model[i].label || "").length + 2 }
  readonly property int totalWeight: {
    var sum = 0
    for (var i = 0; i < cellCount; i++) sum += labelWeight(i)
    return Math.max(1, sum)
  }
  function cellLeft(i) {
    var x = 0
    for (var j = 0; j < i; j++) x += cellWidthAt(j)
    return x
  }
  function cellWidthAt(i) {
    if (i === cellCount - 1) return width - cellLeft(i)
    return Math.round(width * labelWeight(i) / totalWeight)
  }

  implicitHeight: Math.round(Style.spacing.controlHeight * 0.85)
  opacity: busy ? 0.5 : 1

  function select(v) {
    if (busy) return
    if (String(v) === String(root.value)) return
    selected(v)
  }

  // Left/Right keys move to the neighbouring cell when the item has focus.
  function selectByDelta(delta) {
    if (cellCount === 0) return
    var i = -1
    for (var k = 0; k < cellCount; k++) if (String(model[k].value) === String(root.value)) i = k
    var next = Math.max(0, Math.min(cellCount - 1, i + delta))
    if (next !== i) select(model[next].value)
  }

  activeFocusOnTab: !busy
  Keys.onLeftPressed: function(event) { selectByDelta(-1); event.accepted = true }
  Keys.onRightPressed: function(event) { selectByDelta(1); event.accepted = true }

  Repeater {
    model: root.model

    Rectangle {
      id: cell
      required property var modelData
      required property int index

      readonly property bool on: String(modelData.value) === String(root.value)

      // Cells overlap by one pixel so the shared borders stay single-width.
      x: root.cellLeft(index) - (index > 0 ? 1 : 0)
      width: root.cellWidthAt(index) + (index > 0 ? 1 : 0)
      height: root.height
      z: on ? 1 : 0
      radius: 0
      color: on ? Style.selectedFillFor(root.fg, Commons.Color.accent) : "transparent"
      border.width: 1
      border.color: Util.alpha(root.fg, on ? 0.6 : 0.35)

      Text {
        anchors.centerIn: parent
        width: parent.width - Style.space(4)
        horizontalAlignment: Text.AlignHCenter
        textFormat: Text.PlainText
        text: cell.modelData.label
        color: root.fg
        opacity: cell.on ? 1 : 0.75
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      MouseArea {
        anchors.fill: parent
        enabled: !root.busy
        cursorShape: Qt.PointingHandCursor
        onClicked: root.select(cell.modelData.value)
      }
    }
  }
}
