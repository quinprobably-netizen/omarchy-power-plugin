import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// qpc.power: label + caption on the left, "− value +" on the right. Values
// come from `presets` ([{value, label}]); a current value that is not in the
// list is shown verbatim, "+" goes to the first preset above it and "−" to
// the last preset below. An empty value shows `emptyLabel`. The caller owns
// `value` and updates it after the write; this emits changed(newValue).
// Left/Right keys step when the item has focus.
Item {
  id: root

  property QtObject bar: null
  property string label: ""
  property string caption: ""
  property var presets: []
  property var value
  property string emptyLabel: ""
  property bool editable: true
  property bool busy: false

  signal changed(var value)

  readonly property color fg: bar ? bar.foreground : Commons.Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property int count: Array.isArray(presets) ? presets.length : 0
  readonly property bool empty: value === undefined || value === null || String(value) === "" || (typeof value === "number" && isNaN(value))
  readonly property int index: Model.nearestPresetIndex(presets, value)
  readonly property bool exact: !empty && count > 0 && String(presets[index].value) === String(value)
  readonly property string displayText: empty ? emptyLabel : (exact ? String(presets[index].label) : String(value))
  readonly property int downIndex: Model.stepPresetIndex(presets, empty ? "" : value, -1)
  readonly property int upIndex: Model.stepPresetIndex(presets, empty ? "" : value, 1)
  readonly property bool canDecrease: editable && !busy && downIndex >= 0
  readonly property bool canIncrease: editable && !busy && upIndex >= 0 && !(exact && upIndex === index)

  function stepBy(delta) {
    if (!editable || busy || count === 0) return
    var next = delta > 0 ? upIndex : downIndex
    if (next < 0 || next >= count) return
    if (exact && next === index) return
    changed(presets[next].value)
  }

  activeFocusOnTab: editable
  Keys.onLeftPressed: function(event) { stepBy(-1); event.accepted = true }
  Keys.onRightPressed: function(event) { stepBy(1); event.accepted = true }

  width: parent ? parent.width : implicitWidth
  implicitHeight: Math.max(labels.implicitHeight, controls.implicitHeight) + Style.space(2)
  opacity: editable ? 1 : 0.4

  Column {
    id: labels
    anchors.left: parent.left
    anchors.right: controls.left
    anchors.rightMargin: Style.space(12)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(1)

    Text {
      textFormat: Text.PlainText
      text: root.label
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      width: parent.width
    }

    Text {
      textFormat: Text.PlainText
      visible: root.caption !== ""
      text: root.caption
      color: root.fg
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.Wrap
      maximumLineCount: 2
      elide: Text.ElideRight
      width: parent.width
    }
  }

  Row {
    id: controls
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(4)

    Button {
      text: "−"
      bordered: true
      foreground: root.fg
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      horizontalPadding: Style.space(7)
      verticalPadding: Style.space(1)
      opacity: root.canDecrease ? 1 : 0.35
      onClicked: root.stepBy(-1)
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(Style.space(44), implicitWidth)
      horizontalAlignment: Text.AlignHCenter
      textFormat: Text.PlainText
      text: root.displayText
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Button {
      text: "+"
      bordered: true
      foreground: root.fg
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      horizontalPadding: Style.space(7)
      verticalPadding: Style.space(1)
      opacity: root.canIncrease ? 1 : 0.35
      onClicked: root.stepBy(1)
    }
  }
}
