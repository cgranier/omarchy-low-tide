import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.UPower
import qs.Commons
import "Model.js" as Model

// Low Tide's engine: watches the battery, raises alerts that get louder,
// draws a pulsing frame around every screen at the critical level, and, as a
// last resort, hibernates before the battery gives out.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string pluginId: (manifest && manifest.id) || "cgranier.lowtide"
  readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")

  property var config: Model.readConfig(null)
  // Test readings injected over IPC. While set, nothing real is ever done:
  // the last-resort action only says what it would have done.
  property var simulated: null
  property double now: Date.now()
  property string lastEvent: ""

  readonly property var device: UPower.displayDevice
  readonly property var reading: simulated ? simulated : ({
    percent: device && device.isPresent ? Math.round(Number(device.percentage || 0) * 100) : -1,
    // The battery's own state, and nothing else. UPower's daemon-wide
    // `onBattery` looks like the obvious extra check, but it is derived from
    // the charger device, and some hardware (a Surface Pro 4, for one) reports
    // "on-battery: no" while unplugged and draining. Requiring it would mean
    // never alerting at all on exactly the machines that need this most.
    discharging: !!(device && device.isPresent && device.state === UPowerDeviceState.Discharging) && kernelDischarging
  })

  // UPower can take several seconds to notice a charger going in (on some
  // hardware it misses the event altogether until something makes it re-read).
  // That lag is harmless for raising an alert, but not for taking one down: a
  // charger plugged in during the last seconds of the countdown has to stop it.
  // So while an alert or countdown is live, the kernel's own battery status is
  // read directly. It can only ever stand things down sooner, never raise them.
  property bool kernelDischarging: true
  readonly property bool watchingKernel: !simulated && (tide.announced >= 0 || tide.countdownEndsAt > 0)
  onWatchingKernelChanged: if (!watchingKernel) kernelDischarging = true

  Timer {
    interval: 1000
    repeat: true
    running: root.watchingKernel
    triggeredOnStart: true
    onTriggered: if (!kernelProcess.running) kernelProcess.running = true
  }

  Process {
    id: kernelProcess
    running: false
    command: ["timeout", "5", "sh", "-c", 'for d in /sys/class/power_supply/*/; do [ "$(head -c 64 "$d/type" 2>/dev/null)" = Battery ] && head -c 64 "$d/status" 2>/dev/null; done; exit 0']
    stdout: StdioCollector { id: kernelStdout; waitForEnd: true }
    onExited: function(exitCode) {
      var lines = String(kernelStdout.text || "").trim()
      // No battery readable this way: stay out of it and let UPower decide.
      var draining = lines === "" || /(^|\n)Discharging(\n|$)/.test(lines)
      if (draining !== root.kernelDischarging) {
        root.kernelDischarging = draining
        root.evaluate()
      }
    }
  }
  readonly property real secondsLeft: simulated ? simulated.percent * 60 : (device ? Number(device.timeToEmpty || 0) : 0)
  readonly property int stage: reading.discharging ? Model.stageFor(reading.percent, config.levels) : -1
  readonly property bool counting: tide.countdownEndsAt > 0
  readonly property int countdownSecLeft: counting ? Math.max(0, Math.ceil((tide.countdownEndsAt - now) / 1000)) : 0
  readonly property bool frameActive: Model.frameActive(reading, config)
  readonly property string status: Model.statusText(reading, config, tide, secondsLeft, now)
  readonly property string barText: Model.barText(reading, secondsLeft, countdownSecLeft)

  // Survives a plugin reload, so editing a file mid-discharge doesn't replay
  // every alert or forget a countdown.
  PersistentProperties {
    id: tide
    reloadableId: "cgranier-lowtide"
    property int announced: -1
    property double countdownEndsAt: 0
    property int actedAt: -1
  }

  function evaluate() {
    now = Date.now()
    var result = Model.step({ announced: tide.announced, countdownEndsAt: tide.countdownEndsAt, actedAt: tide.actedAt }, reading, config, now)
    tide.announced = result.state.announced
    tide.countdownEndsAt = result.state.countdownEndsAt
    tide.actedAt = result.state.actedAt
    for (var i = 0; i < result.effects.length; i++) perform(result.effects[i])
  }

  function perform(effect) {
    lastEvent = effect.type + (effect.stage !== undefined ? " stage " + effect.stage : "") + " at " + reading.percent + "%"
    if (effect.type === "alert") {
      if (config.notify) toast(Model.alertToast(effect, config, secondsLeft), effect.last ? Model.GLYPHS.critical : Model.GLYPHS.low)
    } else if (effect.type === "countdown") {
      toast(Model.countdownToast(effect), Model.GLYPHS.hibernate)
    } else if (effect.type === "clear") {
      dismissAlerts()
    } else if (effect.type === "cancel") {
      dismissAlerts()
      Quickshell.execDetached(["omarchy-notification-dismiss", Model.actionVerb(config.action) + " in"])
      toast({ headline: "Cancelled", body: effect.reason === "charging" ? "On power again." : "Battery recovered.",
        urgency: "normal", bypassDnd: false, sticky: false }, Model.GLYPHS.charging)
    } else if (effect.type === "act") {
      act(effect.action)
    }
  }

  // Do Not Disturb only admits critical alerts under the bare "notify-send"
  // identity, so the alerts that must get through borrow it.
  function toast(t, glyph) {
    var command = ["omarchy-notification-send", "--app-name", t.bypassDnd ? "notify-send" : "Low Tide", "-g", glyph, "-u", t.urgency]
    if (!t.sticky) command = command.concat(["-t", "20000"])
    Quickshell.execDetached(command.concat([t.headline, t.body]))
    // Omarchy never expires a critical notification, whatever timeout it asks
    // for, and critical is the only kind that gets through Do Not Disturb. So a
    // toast that should break through AND go away has to be taken down by hand.
    if (t.urgency === "critical" && !t.sticky) {
      expiring = expiring.concat([t.headline])
      expireTimer.restart()
    }
  }

  property var expiring: []

  function dismissAlerts() {
    Quickshell.execDetached(["omarchy-notification-dismiss", "Battery at"])
    expiring = []
  }

  Timer {
    id: expireTimer
    interval: 20000
    repeat: false
    onTriggered: {
      for (var i = 0; i < root.expiring.length; i++) Quickshell.execDetached(["omarchy-notification-dismiss", root.expiring[i]])
      root.expiring = []
    }
  }

  function act(action) {
    Quickshell.execDetached(["omarchy-notification-dismiss", Model.actionVerb(action) + " in"])
    if (simulated) {
      toast({ headline: "Simulation: would " + (action === "poweroff" ? "shut down" : "hibernate") + " now", body: "Nothing was done.",
        urgency: "normal", bypassDnd: false, sticky: false }, Model.GLYPHS.hibernate)
      return
    }
    actionProcess.startedAt = Date.now()
    actionProcess.action = action
    actionProcess.command = ["systemctl", action === "poweroff" ? "poweroff" : "hibernate"]
    actionProcess.running = true
  }

  function loadConfig(raw) {
    config = Model.readConfig(Model.entryFromShellJson(raw, pluginId))
    evaluate()
  }

  // ---- For the bar widget and for testing ----
  function simulate(percent, discharging) {
    simulated = { percent: percent, discharging: discharging }
    evaluate()
  }

  function stopSimulation() {
    simulated = null
    Quickshell.execDetached(["omarchy-notification-dismiss", "Battery at"])
    Quickshell.execDetached(["omarchy-notification-dismiss", Model.actionVerb(config.action) + " in"])
    tide.announced = -1
    tide.countdownEndsAt = 0
    tide.actedAt = -1
    evaluate()
  }

  function hibernateNow() { if (!simulated) act("hibernate") }

  IpcHandler {
    target: "cgranier.lowtide"
    function status(): string { return root.status }
    function state(): string {
      return JSON.stringify({ reading: root.reading, stage: root.stage, frame: root.frameActive, counting: root.counting,
        countdownSecLeft: root.countdownSecLeft, announced: tide.announced, actedAt: tide.actedAt, simulated: root.simulated !== null,
        secondsLeft: Math.round(root.secondsLeft), config: root.config, lastEvent: root.lastEvent })
    }
    function simulate(percent: string, mode: string): string {
      var p = parseInt(percent, 10)
      if (!isFinite(p) || p < 0 || p > 100) return "usage: simulate <0-100> <discharging|charging>"
      root.simulate(p, mode !== "charging")
      return "simulating " + p + "% " + (mode !== "charging" ? "discharging" : "charging") + " — nothing real will happen"
    }
    function stopSimulation(): string { root.stopSimulation(); return root.status }
  }

  Connections {
    target: UPower
    function onOnBatteryChanged() { root.evaluate() }
  }

  Connections {
    target: root.device
    ignoreUnknownSignals: true
    function onPercentageChanged() { root.evaluate() }
    function onStateChanged() { root.evaluate() }
  }

  // The battery's own change signals do most of the work; this keeps the
  // countdown honest to the second and the "minutes left" text fresh.
  Timer {
    interval: root.counting ? 1000 : 15000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.evaluate()
  }

  // A service plugin gets no settings injected, so it reads its own entry
  // out of shell.json. The shell never opens the file itself: a bounded read
  // runs when the file's modification time changes, checked every 10 s.
  property string configStamp: ""

  Timer {
    interval: 10000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: if (!stampProcess.running) stampProcess.running = true
  }

  Process {
    id: stampProcess
    running: false
    command: ["timeout", "5", "stat", "-c", "%Y %s", root.configHome + "/omarchy/shell.json"]
    stdout: StdioCollector { id: stampOut; waitForEnd: true }
    onExited: function(exitCode) {
      var stamp = String(stampOut.text || "").trim()
      if (exitCode !== 0 || stamp === root.configStamp) return
      root.configStamp = stamp
      if (!configProcess.running) configProcess.running = true
    }
  }

  Process {
    id: configProcess
    running: false
    command: ["timeout", "5", "head", "-c", "1000000", root.configHome + "/omarchy/shell.json"]
    stdout: StdioCollector { id: configOut; waitForEnd: true }
    onExited: function(exitCode) { if (exitCode === 0) root.loadConfig(String(configOut.text || "")) }
  }

  Process {
    id: actionProcess
    property double startedAt: 0
    property string action: ""
    running: false
    command: []
    onExited: function(exitCode) {
      // A hibernate that fails does so within seconds; one that worked returns
      // after resume, long after. Only the quick failure falls back to a clean
      // shutdown, which still beats the battery cutting out mid-write.
      if (exitCode === 0 || action === "poweroff" || Date.now() - startedAt > 20000) return
      if (!root.reading.discharging) return
      root.toast({ headline: "Hibernate failed", body: "Shutting down in 15 s instead. Plug in to cancel.",
        urgency: "critical", bypassDnd: true, sticky: true }, Model.GLYPHS.hibernate)
      fallbackTimer.restart()
    }
  }

  Timer {
    id: fallbackTimer
    interval: 15000
    repeat: false
    onTriggered: if (root.reading.discharging && !root.simulated) root.act("poweroff")
  }

  // ---- The frame: one click-through window per screen ----
  Variants {
    model: Quickshell.screens

    PanelWindow {
      required property var modelData
      screen: modelData
      visible: root.frameActive
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "cgranier-lowtide"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      // An empty input region: every click and key passes straight through.
      mask: Region {}

      Rectangle {
        id: frame
        anchors.fill: parent
        color: "transparent"
        border.color: Color.urgent
        border.width: Style.space(root.counting ? 10 : 6)

        SequentialAnimation on opacity {
          running: root.frameActive
          loops: Animation.Infinite
          NumberAnimation { from: 0.9; to: 0.2; duration: root.counting ? 350 : 1100; easing.type: Easing.InOutSine }
          NumberAnimation { from: 0.2; to: 0.9; duration: root.counting ? 350 : 1100; easing.type: Easing.InOutSine }
        }
      }
    }
  }
}
