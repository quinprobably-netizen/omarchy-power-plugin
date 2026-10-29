import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "qpc.power"
  ipcTarget: "qpc.power"
  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the togglePercentage method below.
  manageIpc: false
  property var batteryInfo: ({})
  property var systemInfo: ({})
  property var profiles: []
  property string activeProfile: ""
  property int profileIndex: 0
  property bool cursorActive: false

  // ---- qpc.power additions: lid-close behavior, stay awake, extras ----
  readonly property string pluginDir: Quickshell.env("HOME") + "/.config/omarchy/plugins/qpc.power"
  readonly property string lidScript: pluginDir + "/bin/lid-switch"
  readonly property string statsScript: pluginDir + "/bin/power-stats"
  // {suspend, lock, backlightOff, mode} as reported by `lid-switch status`.
  property var lidState: ({})
  // {health, kbd} as reported by `power-stats status`.
  property var extras: ({})
  // Third-party plugins get a scoped shell API with no first-party service
  // lookup, so stay-awake goes through `omarchy toggle idle`, whose state file
  // the idle service watches.
  property bool stayAwake: false

  // ---- qpc.battery-saver bridge: sleep action, hibernate delay, idle timers,
  // master switch. Reads go through the plugin's conf-json and IPC status;
  // writes through `battery-saver set`, pkexec for the root-side delay, and
  // the enable/disable IPC. Every write re-reads so the controls snap back
  // to the real value if a write fails.
  readonly property string batterySaverTool: Quickshell.env("HOME") + "/.config/omarchy/plugins/qpc.battery-saver/bin/battery-saver"
  property bool batterySaverPresent: false
  // The headless service answers the status IPC; false until it does.
  property bool saverServiceUp: false
  property var saverConf: ({})
  property bool saverEnabled: false
  readonly property bool saverBusy: saverSetProc.running || hibernateProc.running || saverToggleProc.running
  readonly property var sleepActions: [
    { value: "suspend", label: Model.sleepActionLabel("suspend") },
    { value: "suspend-then-hibernate", label: Model.sleepActionLabel("suspend-then-hibernate") },
    { value: "hibernate", label: Model.sleepActionLabel("hibernate") }
  ]

  function refreshSaver() {
    if (!saverConfProc.running) saverConfProc.running = true
    if (batterySaverPresent && !saverStatusProc.running) saverStatusProc.running = true
  }

  function applySaverConf(raw) {
    try {
      var next = JSON.parse(String(raw || "").trim())
      if (next && typeof next === "object") saverConf = next
    } catch (error) {
      // Empty output when the plugin is missing; presence is set from the exit code.
    }
  }

  function applySaverStatus(raw) {
    try {
      var next = JSON.parse(String(raw || "").trim())
      if (next && typeof next === "object" && next.enabled !== undefined) {
        saverEnabled = next.enabled === true
        saverServiceUp = true
        return
      }
    } catch (error) {
      // "Target not found." when the service plugin is disabled: not an error worth logging each tick.
    }
    saverServiceUp = false
  }

  function setSaverValue(key, value) {
    if (saverSetProc.running) return
    saverSetProc.command = [root.batterySaverTool, "set", String(key), String(value)]
    saverSetProc.running = true
  }

  function setHibernateDelay(value) {
    if (hibernateProc.running) return
    hibernateProc.command = ["pkexec", "/usr/local/bin/battery-saver-sys", "set-hibernate-delay", String(value)]
    hibernateProc.running = true
  }

  function toggleSaver() {
    if (saverToggleProc.running) return
    saverToggleProc.command = ["omarchy-shell", "battery-saver", root.saverEnabled ? "disable" : "enable"]
    saverToggleProc.running = true
  }

  function idleWord(seconds) {
    var n = Number(seconds)
    return n > 0 ? Model.formatDuration(n) : "off"
  }

  readonly property string idleSummary: "Dim " + idleWord(saverConf.idle_dim_seconds)
    + " · screen " + idleWord(saverConf.idle_screen_off_seconds)
    + " · sleep " + idleWord(saverConf.idle_suspend_seconds)
  readonly property bool lidBusy: lidSetProc.running
  // The bar shows a marker only when lid close does more than dim the panel.
  readonly property bool lidIndicator: lidState.suspend === true || lidState.lock === true
  readonly property string lidGlyph: lidState.suspend === true ? "\u{f04b2}" : (lidState.lock === true ? "\u{f033e}" : "")
  readonly property real lidSlotExtra: lidIndicator && !button.vertical ? Style.bar.iconSlot * 0.8 : 0

  function refreshLid() {
    if (!lidProc.running) lidProc.running = true
  }

  function refreshExtras() {
    if (!extrasProc.running) extrasProc.running = true
  }

  function applyLidJson(raw) {
    try {
      var next = JSON.parse(String(raw || "").trim())
      if (next && typeof next === "object") lidState = next
    } catch (error) {
      console.log("qpc.power: lid status parse failed: " + error)
    }
  }

  function setLidFlag(flag) {
    if (lidSetProc.running) return
    lidSetProc.command = [root.lidScript, "set", flag, "toggle"]
    lidSetProc.running = true
  }

  function refreshStayAwake() {
    if (!stayAwakeProc.running) stayAwakeProc.running = true
  }

  function applyStayAwakeJson(raw) {
    try {
      var next = JSON.parse(String(raw || "").trim())
      if (next && typeof next === "object") stayAwake = next.enabled === true
    } catch (error) {
      console.log("qpc.power: stay-awake status parse failed: " + error)
    }
  }

  function toggleStayAwake() {
    if (stayAwakeToggleProc.running) return
    stayAwakeToggleProc.running = true
  }

  function toggleKeyboardBacklight() {
    if (kbdProc.running) return
    kbdProc.running = true
  }
  readonly property bool showPercentage: setting("showPercentage", false) === true
  // With the percentage shown the button paints a text block wider than an
  // icon, so the open-panel mark takes the painted width instead of the
  // icon-sized fraction of the slot the fallback assumes.
  readonly property real openPanelIndicatorWidth: showPercentage && !button.vertical ? button.glyphPaintedWidth : 0
  readonly property bool batteryPresent: {
    var device = UPower.displayDevice
    return !!(device && device.isPresent)
  }

  function upowerStates() {
    return {
      Charging: UPowerDeviceState.Charging,
      Discharging: UPowerDeviceState.Discharging,
      FullyCharged: UPowerDeviceState.FullyCharged,
      PendingCharge: UPowerDeviceState.PendingCharge
    }
  }

  function selectProfileByDelta(delta) {
    profileIndex = Model.selectProfileIndex(profileIndex, delta, profiles)
  }

  function activateSelectedProfile() {
    if (profileIndex < 0 || profileIndex >= profiles.length) return
    setProfile(profiles[profileIndex])
  }

  function batteryIcon() {
    var device = UPower.displayDevice
    return Model.batteryIcon(device, root.discharging, upowerStates())
  }

  function modeLabel() {
    var device = UPower.displayDevice
    return Model.modeLabel(device, root.discharging, upowerStates())
  }

  function profileIcon(name) {
    return Model.profileIcon(name)
  }

  readonly property bool fullyCharged: {
    var device = UPower.displayDevice
    return device && device.isPresent && device.state === UPowerDeviceState.FullyCharged && !root.chargeThresholdActive
  }
  readonly property bool discharging: {
    var device = UPower.displayDevice
    return !!(device && device.isPresent && UPower.onBattery)
  }
  readonly property bool chargeThresholdActive: {
    var device = UPower.displayDevice
    return Model.chargeThresholdActive(device, root.discharging, upowerStates())
  }
  readonly property bool batteryFull: fullyCharged || (!root.discharging && batteryFraction >= 1)
  readonly property bool batteryFlowIdle: batteryFull || chargeThresholdActive

  // 0..1 charge level, used by the visual progress bar.
  readonly property real batteryFraction: {
    var d = UPower.displayDevice
    return Model.batteryFraction(d)
  }

  readonly property bool charging: {
    var d = UPower.displayDevice
    return d && d.isPresent && !UPower.onBattery && !root.batteryFlowIdle
  }

  readonly property color batteryFillColor: {
    return root.bar ? root.bar.foreground : Commons.Color.foreground
  }

  // Cute agent-flavored phrases shown in the hero status line, rotated on a
  // timer so the panel feels alive when current is flowing (either direction).
  readonly property var chargingPhrases: [
    "Pumping power",
    "Injecting electrons",
    "Pouring juice",
    "Amassing watts",
    "Hoarding joules",
    "Sucking volts",
    "Topping reserves",
    "Soaking amps",
    "Inhaling kilowatts"
  ]
  readonly property var onBatteryPhrases: [
    "Slurping power",
    "Spending joules",
    "Draining watts",
    "Burning electrons",
    "Sipping juice",
    "Spending coulombs",
    "Bleeding amps",
    "Guzzling volts",
    "Munching reserves"
  ]
  property int phraseIndex: 0

  // Whichever list is "active" given the current power state.
  readonly property var activePhrases: {
    if (fullyCharged) return []
    if (charging) return chargingPhrases
    if (discharging) return onBatteryPhrases
    return []
  }
  readonly property bool rotatingPhrases: activePhrases.length > 0

  readonly property string heroStatusText: {
    if (fullyCharged) return "Fully charged"
    if (rotatingPhrases) return activePhrases[phraseIndex % activePhrases.length]
    return modeLabel()
  }

  // Big line of the battery card: time left / to full, "Holding" at the
  // charge cap, "Full" when full; otherwise the status phrase.
  readonly property string headlineText: {
    if (chargeThresholdActive) return "Holding"
    if (batteryFull) return "Full"
    var t = String(batteryInfo.time || "")
    return (t !== "" && t !== "—" && t !== "-") ? t : heroStatusText
  }
  // Caption under it: the plain state (Discharging / Charging / Fully
  // charged / Holding) plus the current draw.
  readonly property string captionText: {
    var base = chargeThresholdActive ? "At charge limit" : modeLabel()
    var rate = batteryFlowIdle ? "" : String(batteryInfo.rate || "")
    return rate !== "" ? base + " · " + rate : base
  }

  function refresh() {
    if (!batteryPresent) return

    if (!batteryProc.running) batteryProc.running = true
    if (!profilesProc.running) profilesProc.running = true
    if (!systemProc.running) systemProc.running = true
    refreshLid()
    refreshExtras()
    refreshStayAwake()
    refreshSaver()
  }

  function updateKeyValue(raw, targetName) {
    var next = Model.parseKeyValue(raw)
    // Keep last known good data if a refresh briefly returns nothing — happens
    // around AC plug/unplug events. Avoids the section collapsing mid-transition.
    if (Object.keys(next).length === 0) return
    if (targetName === "battery") batteryInfo = next
    else systemInfo = next
  }

  function updateProfiles(raw) {
    var parsed = Model.parseProfiles(raw, profileIndex)
    // Same guard as battery: preserve the last known profile list across
    // transient empty payloads so the buttons don't blink out.
    if (parsed.profiles.length === 0) return
    profiles = parsed.profiles
    activeProfile = parsed.activeProfile
    profileIndex = parsed.profileIndex
    if (opened && !cursorActive) {
      var idx = profiles.indexOf(activeProfile)
      if (idx >= 0) profileIndex = idx
    }
  }

  function setProfile(profile) {
    if (!profile || actionProc.running) return
    actionProc.command = ["omarchy-powerprofiles-set", root.discharging ? "battery" : "ac", profile]
    actionProc.running = true
  }

  function togglePercentage() {
    root.settings = Object.assign({}, root.settings, { showPercentage: !root.showPercentage })
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  IpcHandler {
    target: "qpc.power"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function togglePercentage() { root.togglePercentage() }
  }

  onOpenedChanged: {
    if (opened) {
      if (!batteryPresent) {
        close()
        return
      }

      refresh()
      var idx = profiles.indexOf(activeProfile)
      profileIndex = idx >= 0 ? idx : 0
      cursorActive = false
    }
  }

  onBatteryPresentChanged: if (!batteryPresent) close()

  visible: batteryPresent
  implicitWidth: batteryPresent ? button.implicitWidth : 0
  implicitHeight: batteryPresent ? button.implicitHeight : 0

  Process {
    id: batteryProc
    command: ["omarchy-battery-status", "--shell"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateKeyValue(text, "battery") }
  }

  Process {
    id: profilesProc
    command: ["omarchy-powerprofiles-list", "--active-state"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateProfiles(text) }
  }

  Process {
    id: systemProc
    command: ["omarchy-system-stats"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateKeyValue(text, "system") }
  }

  Process {
    id: actionProc
    onExited: root.refresh()
  }

  Process {
    id: lidProc
    command: [root.lidScript, "status"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyLidJson(text) }
  }

  Process {
    id: lidSetProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyLidJson(text) }
  }

  Process {
    id: stayAwakeProc
    command: ["omarchy-toggle-idle", "status"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyStayAwakeJson(text) }
  }

  Process {
    id: stayAwakeToggleProc
    command: ["omarchy-toggle-idle", "toggle"]
    onExited: root.refreshStayAwake()
  }

  Process {
    id: extrasProc
    command: [root.statsScript, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var next = Model.parseKeyValue(text)
        if (Object.keys(next).length > 0) root.extras = next
      }
    }
  }

  Process {
    id: kbdProc
    command: [root.statsScript, "kbd", "toggle"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var next = Model.parseKeyValue(text)
        if (Object.keys(next).length > 0) root.extras = next
      }
    }
  }

  Process {
    id: saverConfProc
    // bash wrapper: a missing plugin exits 1 instead of failing to spawn.
    command: ["bash", "-c", "test -x \"$1\" && exec \"$1\" conf-json", "_", root.batterySaverTool]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applySaverConf(text) }
    onExited: function(code, status) {
      root.batterySaverPresent = (code === 0)
      if (root.batterySaverPresent && !saverStatusProc.running) saverStatusProc.running = true
    }
  }

  Process {
    id: saverStatusProc
    command: ["omarchy-shell", "battery-saver", "status"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applySaverStatus(text) }
  }

  Process {
    id: saverSetProc
    onExited: function(code, status) {
      if (code !== 0) console.log("qpc.power: battery-saver set failed (" + code + ")")
      root.refreshSaver()
    }
  }

  Process {
    id: hibernateProc
    onExited: function(code, status) {
      if (code !== 0) console.log("qpc.power: set-hibernate-delay failed or cancelled (" + code + ")")
      root.refreshSaver()
    }
  }

  Process {
    id: saverToggleProc
    onExited: function(code, status) {
      if (code !== 0) console.log("qpc.power: battery-saver toggle failed (" + code + ")")
      root.refreshSaver()
    }
  }

  // The bar marker needs the lid state before the panel is ever opened.
  Component.onCompleted: { refreshLid(); refreshSaver() }

  Timer { interval: 5000; running: root.opened; repeat: true; onTriggered: root.refresh() }

  // Rotate the status phrase while the panel is open and we're in a
  // rotating state (charging or on battery). The text swap is wrapped in a
  // fade so the changeover reads as one organism rather than a hard cut.
  Timer {
    id: phraseTimer
    interval: 2800
    running: root.opened && root.rotatingPhrases
    repeat: true
    triggeredOnStart: false
    onTriggered: phraseSwap.restart()
  }

  SequentialAnimation {
    id: phraseSwap
    PropertyAnimation {
      target: heroStatus; property: "opacity"
      to: 0.0; duration: 180; easing.type: Easing.OutQuad
    }
    ScriptAction {
      script: {
        var n = root.activePhrases.length
        if (n > 0) root.phraseIndex = (root.phraseIndex + 1) % n
      }
    }
    PropertyAnimation {
      target: heroStatus; property: "opacity"
      to: 1.0; duration: 260; easing.type: Easing.InQuad
    }
  }

  // If we leave a rotating state mid-swap, halt the animation and snap back
  // to full opacity so "FULLY CHARGED" is legible immediately rather than
  // appearing dimmed.
  Connections {
    target: root
    function onRotatingPhrasesChanged() {
      if (!root.rotatingPhrases) {
        phraseSwap.stop()
        heroStatus.opacity = 1.0
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: {
      var base = root.showPercentage && !vertical
        ? Math.round(root.batteryFraction * 100) + "% " + root.batteryIcon()
        : root.batteryIcon()
      return root.lidIndicator && !vertical ? base + " " + root.lidGlyph : base
    }
    slotSize: Style.bar.iconSlot * (root.showPercentage && !vertical ? 2 : 1) + root.lidSlotExtra
    tooltipText: root.lidIndicator ? "Lid close: " + (root.lidState.mode || "") : ""
    onPressed: function(b) {
      if (!root.batteryPresent) return
      if (b === Qt.RightButton) root.togglePercentage()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.batteryPresent
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight(columns.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dx !== 0) root.selectProfileByDelta(dx)
        else if (dy !== 0) root.selectProfileByDelta(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateSelectedProfile()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      // Two columns: status + profile on the left, settings cards on the right.
      Row {
        id: columns
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(16)

        Column {
          id: leftCol
          width: Style.space(230)
          spacing: Style.space(12)

          // ---------- Battery card ----------
          Card {
            bar: root.bar
            width: parent.width

            Row {
              width: parent.width
              spacing: Style.space(12)

              RingGauge {
                id: ring
                anchors.verticalCenter: parent.verticalCenter
                fraction: root.batteryFraction
                text: root.batteryInfo.percentage || "—"
                trackColor: Util.alpha(root.bar.foreground, 0.12)
                fillColor: root.batteryFillColor
                fontFamily: root.bar.fontFamily

                // Subtle pulse while charging — visible signal that energy is flowing in.
                SequentialAnimation on opacity {
                  running: root.charging && !root.fullyCharged && root.opened
                  loops: Animation.Infinite
                  alwaysRunToEnd: true
                  NumberAnimation { from: 1.0; to: 0.55; duration: 950; easing.type: Easing.InOutSine }
                  NumberAnimation { from: 0.55; to: 1.0; duration: 950; easing.type: Easing.InOutSine }
                }
              }

              Column {
                width: parent.width - ring.width - parent.spacing
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  textFormat: Text.PlainText
                  text: root.headlineText
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                  elide: Text.ElideRight
                  width: parent.width
                }

                Text {
                  id: heroStatus
                  textFormat: Text.PlainText
                  text: root.captionText
                  color: root.bar.foreground
                  opacity: 0.6
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  width: parent.width
                }
              }
            }

            Column {
              width: parent.width
              spacing: Style.spacing.labelGap
              InfoPair { label: "Health"; value: root.extras.health || "—" }
              InfoPair { label: "Full charge"; value: root.extras.full_wh && root.extras.full_wh !== "—" ? root.extras.full_wh + " Wh" : (root.batteryInfo.size || "—") }
              InfoPair { label: "Charge window"; value: root.extras.window || root.batteryInfo.threshold || "—" }
            }
          }

          // ---------- Power profile card ----------
          Card {
            bar: root.bar
            title: "POWER PROFILE"
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.profiles
              Button {
                required property var modelData
                required property int index
                width: parent.width
                leftAlign: true
                iconText: root.profileIcon(String(modelData))
                iconSize: Style.font.title
                text: String(modelData).charAt(0).toUpperCase() + String(modelData).slice(1)
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                bordered: true
                active: root.activeProfile === modelData
                hasCursor: root.cursorActive && root.profileIndex === index
                onClicked: root.setProfile(modelData)
                onHovered: function(h) {
                  if (h) {
                    root.cursorActive = true
                    root.profileIndex = index
                  }
                }
              }
            }
          }
        }

        Column {
          id: rightCol
          width: columns.width - leftCol.width - columns.spacing
          spacing: Style.space(12)

          // ---------- Sleep card ----------
          Card {
            bar: root.bar
            title: "SLEEP"
            width: parent.width
            visible: root.batterySaverPresent

            SegmentedControl {
              width: parent.width
              bar: root.bar
              model: root.sleepActions
              value: root.saverConf.sleep_action
              busy: root.saverBusy
              onSelected: function(v) { root.setSaverValue("SLEEP_ACTION", v) }
            }

            Stepper {
              bar: root.bar
              label: "Hibernate after"
              caption: editable ? "Asleep this long, then hibernate" : "Only used by Then hibernate"
              presets: Model.HIBERNATE_PRESETS
              value: root.saverConf.hibernate_delay
              emptyLabel: "Default"
              editable: root.saverConf.sleep_action === "suspend-then-hibernate"
              busy: root.saverBusy
              onChanged: function(v) { root.setHibernateDelay(v) }
            }
          }

          // ---------- Lid closed card ----------
          Card {
            bar: root.bar
            title: "LID CLOSED"
            width: parent.width

            SwitchRow {
              label: "Sleep"
              description: root.lidState.suspend === true ? "Runs the sleep action above. Skipped on an external display." : "Stays running with the lid shut"
              checked: root.lidState.suspend === true
              busy: root.lidBusy
              onToggled: root.setLidFlag("suspend")
            }

            SwitchRow {
              label: "Lock session"
              description: root.lidState.lock === true ? "Locks on close. Skipped on an external display." : "Session stays unlocked"
              checked: root.lidState.lock === true
              busy: root.lidBusy
              onToggled: root.setLidFlag("lock")
            }

            SwitchRow {
              label: "Backlight off"
              description: root.lidState.backlightOff === true ? "Screen and keyboard light off, restored on open" : "Brightness left as is"
              checked: root.lidState.backlightOff === true
              busy: root.lidBusy
              onToggled: root.setLidFlag("backlight-off")
            }
          }

          // ---------- Battery saver card ----------
          Card {
            bar: root.bar
            title: "BATTERY SAVER"
            width: parent.width
            visible: root.batterySaverPresent

            SwitchRow {
              label: "Enabled"
              description: root.saverServiceUp ? root.idleSummary : "Battery-saver service not loaded"
              checked: root.saverServiceUp && root.saverEnabled
              busy: saverToggleProc.running
              onToggled: root.toggleSaver()
            }

            Stepper {
              bar: root.bar
              label: "Dim after"
              presets: Model.IDLE_PRESETS
              value: root.saverConf.idle_dim_seconds
              busy: root.saverBusy
              onChanged: function(v) { root.setSaverValue("IDLE_DIM_SECONDS", v) }
            }

            Stepper {
              bar: root.bar
              label: "Screen off after"
              presets: Model.IDLE_PRESETS
              value: root.saverConf.idle_screen_off_seconds
              busy: root.saverBusy
              onChanged: function(v) { root.setSaverValue("IDLE_SCREEN_OFF_SECONDS", v) }
            }

            Stepper {
              bar: root.bar
              label: "Sleep after"
              presets: Model.IDLE_PRESETS
              value: root.saverConf.idle_suspend_seconds
              busy: root.saverBusy
              onChanged: function(v) { root.setSaverValue("IDLE_SUSPEND_SECONDS", v) }
            }

            SwitchRow {
              label: "Stay awake"
              description: root.stayAwake ? "Idle lock and screensaver paused" : "Idle lock and screensaver as configured"
              checked: root.stayAwake
              busy: stayAwakeToggleProc.running
              onToggled: root.toggleStayAwake()
            }

            SwitchRow {
              visible: root.extras.kbd !== undefined && root.extras.kbd !== "none"
              label: "Keyboard backlight"
              description: root.extras.kbd === "on" ? "On" : "Off"
              checked: root.extras.kbd === "on"
              busy: kbdProc.running
              onToggled: root.toggleKeyboardBacklight()
            }
          }

          // ---------- Session card (only without the battery-saver plugin) ----------
          Card {
            bar: root.bar
            title: "SESSION"
            width: parent.width
            visible: !root.batterySaverPresent

            SwitchRow {
              label: "Stay awake"
              description: root.stayAwake ? "Idle lock and screensaver paused" : "Idle lock and screensaver as configured"
              checked: root.stayAwake
              busy: stayAwakeToggleProc.running
              onToggled: root.toggleStayAwake()
            }

            SwitchRow {
              visible: root.extras.kbd !== undefined && root.extras.kbd !== "none"
              label: "Keyboard backlight"
              description: root.extras.kbd === "on" ? "On" : "Off"
              checked: root.extras.kbd === "on"
              busy: kbdProc.running
              onToggled: root.toggleKeyboardBacklight()
            }
          }
        }
      }
    }
  }

  // Compact label + caption on the left, ToggleSwitch on the right. The whole
  // row is clickable so the switch does not have to be hit precisely.
  component SwitchRow: Item {
    id: switchRow
    property string label: ""
    property string description: ""
    property bool checked: false
    property bool busy: false
    signal toggled()

    width: parent.width
    implicitHeight: Math.max(labels.implicitHeight, toggle.implicitHeight) + Style.space(6)

    Column {
      id: labels
      anchors.left: parent.left
      anchors.right: toggle.left
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        textFormat: Text.PlainText
        text: switchRow.label
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
        width: parent.width
      }

      Text {
        textFormat: Text.PlainText
        visible: switchRow.description !== ""
        text: switchRow.description
        color: root.bar.foreground
        opacity: 0.6
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
        maximumLineCount: 2
        elide: Text.ElideRight
        width: parent.width
      }
    }

    ToggleSwitch {
      id: toggle
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      checked: switchRow.checked
      busy: switchRow.busy
      foreground: root.bar.foreground
      onToggled: switchRow.toggled()
    }

    MouseArea {
      anchors.fill: labels
      cursorShape: Qt.PointingHandCursor
      onClicked: switchRow.toggled()
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    InfoLabel { text: label }
    Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2); height: 1 }
    InfoValue { text: value }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    opacity: 0.6
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
