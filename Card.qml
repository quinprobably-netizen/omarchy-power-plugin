import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// qpc.power: a grouped block in the panel. Slightly lit surface plus a dark
// hairline, both derived from the bar foreground so every theme works.
// Children go into the inner column; give them `width: parent.width`.
Item {
  id: root

  property QtObject bar: null
  property string title: ""
  property real padding: Style.space(12)
  property real spacing: Style.space(6)

  readonly property color fg: bar ? bar.foreground : Commons.Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  default property alias content: inner.data

  implicitHeight: column.implicitHeight + padding * 2

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: Util.alpha(root.fg, 0.04)
    border.width: 1
    border.color: Util.alpha(root.fg, 0.12)
  }

  Column {
    id: column
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: root.padding
    spacing: Style.space(8)

    PanelSectionHeader {
      visible: root.title !== ""
      text: root.title
      foreground: root.fg
      fontFamily: root.fontFamily
    }

    Column {
      id: inner
      width: parent.width
      spacing: root.spacing
    }
  }
}
