import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Low Tide's face in the bar. Omarchy's own power widget already shows the
// battery, so this one stays out of the way until the charge is actually low,
// then shows what matters: how much is left, and for how long.
Panel {
  id: root
  moduleName: "cgranier.lowtide"
  ipcTarget: "cgranier.lowtide.panel"
  manageIpc: false

  property var tide: null

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical : false

  readonly property var config: tide ? tide.config : Model.readConfig(null)
  readonly property bool low: tide ? (tide.stage >= 0 || tide.counting) : false
  readonly property bool showInBar: low || opened || setting("alwaysShow", false) === true
  readonly property var device: UPower.displayDevice
  readonly property string health: device && device.healthSupported ? Math.round(device.healthPercentage) + "%" : ""

  // The service is this plugin's other half and may mount a beat later.
  function findTide() {
    if (tide || !bar || !bar.shell || typeof bar.shell.serviceFor !== "function") return
    tide = bar.shell.serviceFor(moduleName)
  }

  function runTest() {
    if (!tide) return
    tide.simulate(9, true)
    testTimer.restart()
  }

  visible: showInBar
  implicitWidth: showInBar ? button.implicitWidth : 0
  implicitHeight: showInBar ? button.implicitHeight : 0

  onBarChanged: findTide()
  onOpenedChanged: if (opened) {
    findTide()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.tide === null
    triggeredOnStart: true
    onTriggered: root.findTide()
  }

  Timer {
    id: testTimer
    interval: 12000
    repeat: false
    onTriggered: if (root.tide) root.tide.stopSimulation()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function linked(): string { return root.tide ? "true" : "false" }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: !root.tide || !root.low ? Model.GLYPHS.low : (root.vertical ? Model.GLYPHS.low : root.tide.barText)
    active: root.low
    dimmed: !root.low
    tooltipText: root.opened ? "" : "Low Tide: " + (root.tide ? root.tide.status : "starting…")
    onPressed: function(buttonCode) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        PanelHero {
          width: parent.width
          title: "Low Tide"
          meta: root.tide ? root.tide.status : "Starting…"
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconComponent: Component {
            Text {
              textFormat: Text.PlainText
              text: root.low ? Model.GLYPHS.critical : Model.GLYPHS.low
              color: root.low ? root.urgent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(6)

          InfoLine { label: "Alerts at"; value: root.config.levels.map(function(l) { return l + "%" }).join(" · ") }
          InfoLine {
            label: "Last resort"
            value: root.config.action === "none" ? "off"
              : (root.config.action === "poweroff" ? "shut down" : "hibernate") + " at " + root.config.actionAt + "% · " + root.config.countdownSec + " s warning"
          }
          InfoLine { label: "Screen frame"; value: root.config.frame ? "from " + root.config.levels[root.config.levels.length - 1] + "%" : "off" }
          InfoLine { visible: root.health !== ""; label: "Battery health"; value: root.health + " of design capacity" }
        }

        Text {
          textFormat: Text.PlainText
          visible: root.tide !== null && root.tide.simulated !== null
          width: parent.width
          text: "Simulation running. Nothing real will happen; it ends by itself."
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        RowLayout {
          width: parent.width
          spacing: Style.space(10)

          Button {
            Layout.fillWidth: true
            text: "Test alerts"
            bordered: true
            enabled: root.tide !== null && root.tide.simulated === null
            onClicked: { root.runTest(); root.close() }
          }

          Button {
            Layout.fillWidth: true
            text: "Hibernate now"
            bordered: true
            enabled: root.tide !== null && root.tide.simulated === null
            onClicked: { root.close(); root.tide.hibernateNow() }
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: "Plugging in cancels everything, at any point."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  component InfoLine: Item {
    property string label: ""
    property string value: ""
    width: parent ? parent.width : 0
    implicitHeight: Math.max(labelText.implicitHeight, valueText.implicitHeight)

    Text {
      id: labelText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: parent.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      id: valueText
      anchors.right: parent.right
      anchors.left: labelText.right
      anchors.leftMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignRight
      textFormat: Text.PlainText
      text: parent.value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
  }
}
