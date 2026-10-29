# Power Panel Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the `qpc.power` popup as a two-column card panel that also edits the `qpc.battery-saver` plugin's sleep action, hibernate delay, idle timers and master switch.

**Architecture:** Bash scripts in both plugins gain small, validated `set` subcommands and extra status fields; the Quickshell panel gets four reusable QML components and a new two-column body that reads through the existing 5 s refresh and writes through `Process` calls, re-reading after every write. The one root-side setting (hibernate delay) is written through `pkexec` under a dedicated polkit rule.

**Tech Stack:** Bash, Quickshell QML (Qt 6.12), Omarchy shell `qs.Ui` / `qs.Commons`, polkit JS rules, systemd sleep drop-ins.

**Spec:** `/home/qpc/.config/omarchy/plugins/qpc.power/docs/superpowers/specs/2026-10-29-power-panel-redesign-design.md`

## Global Constraints

- `~/.config/omarchy` is not a git repository. Skip every commit step; instead copy each file to `<file>.bak.<unix-ts>` before its first edit in a task (the plugins already follow that convention).
- Never edit anything under `/usr/share/omarchy/`. Root-side files are installed with one `pkexec` call per file, never a bundled script (a bundled root script gets blocked in this environment).
- Tests are plain bash scripts in `/tmp/claude-1000/-home-qpc/3bdeec28-1e12-401d-bb98-42a596a8ad5b/scratchpad/`; the existing `test-sleep-controls.sh` there is the pattern (`ok`/`bad` helpers, temp dir under the scratchpad, env-var overrides for every absolute path).
- All colours derive from `root.bar.foreground` / `Commons.Color`; no hex literals in QML. Card fill alpha `0.04`, card hairline alpha `0.12`, panel width `Style.space(560)`, left column `Style.space(230)`, gutter `Style.space(16)`, card gap `Style.space(12)`, card padding `Style.space(12)`, ring 64 px / stroke 6 px.
- Preset tables (exact): hibernate delay `30min 1h 2h 3h 4h 6h 8h 12h`; idle timers (seconds) `0 30 60 120 300 600 900 1800 3600` labelled `Off 30s 1m 2m 5m 10m 15m 30m 1h`.
- `battery-saver set` allowed keys: `SLEEP_ACTION IDLE_DIM_SECONDS IDLE_SCREEN_OFF_SECONDS IDLE_SUSPEND_SECONDS IDLE_DIM_PERCENT BAT_BRIGHTNESS BAT_REFRESH`. Exit 2 on bad key or value.
- The panel must still open, with the Sleep and Battery saver cards hidden, when `~/.config/omarchy/plugins/qpc.battery-saver/bin/battery-saver` is not executable.

## Review Focus

1. A conf file whose `SLEEP_ACTION=` line is commented out (`# SLEEP_ACTION=...`) must be left alone and a new uncommented line appended. Test in Task 1.
2. A conf value with surrounding quotes (`IDLE_DIM_SECONDS="60"`) must be replaced as a whole line, not produce `IDLE_DIM_SECONDS=90"`. Test in Task 1.
3. `HIBERNATE_DELAY` currently stored but not in the preset list (for example `90min`) must display verbatim and step to the nearest preset. Test in Task 4 (`nearestPresetIndex`).
4. UPower reports `timeToEmpty` of 0 while it is still estimating; the headline must fall back to `heroStatusText`, not show `0m`. Test in Task 4 (`formatDuration(0)` returns `""`).
5. A pkexec write that is cancelled (exit 126/127) must leave the stepper on the previous value with no retry loop. Covered by the Task 7 manual check; the `busy` guard is the code path.

---

### Task 1: `battery-saver set` and `hibernate_delay` in `conf-json`

**Files:**
- Modify: `~/.config/omarchy/plugins/qpc.battery-saver/bin/battery-saver` (defaults block lines 27–39, `conf_json` near line 247, `case` at the end)
- Test: `scratchpad/test-battery-saver-set.sh`

**Interfaces:**
- Produces: `battery-saver set KEY VALUE` (exit 0 ok, 2 invalid key/value, 1 write failure; writes `$CONF_USER`; seeds from `$PLUGIN_DIR/battery-saver.conf.example` when absent; runs `omarchy-shell battery-saver reload` if that command exists and `SLEEP_DRY_RUN` is unset).
- Produces: `conf-json` field `"hibernate_delay":"<string>"` read from `${BATTERY_SAVER_SYS_CONF:-/etc/battery-saver.conf}`.

- [ ] **Step 1: Write the failing test**

```bash
# test-battery-saver-set.sh — same harness as test-sleep-controls.sh; run_user sets HOME/XDG_* to $T/home and SLEEP_DRY_RUN=1
conf=$T/home/.config/omarchy/battery-saver.conf
printf '%s\n' '# header comment' 'IDLE_DIM_SECONDS="60"' '# SLEEP_ACTION=hibernate' 'NOTIFY=1' >"$conf"
run_user set IDLE_DIM_SECONDS 90;            # exit 0; line 2 becomes exactly IDLE_DIM_SECONDS=90; lines 1,3,4 byte-identical
run_user set SLEEP_ACTION suspend;           # exit 0; commented line 3 untouched; last line is SLEEP_ACTION=suspend
run_user set SLEEP_ACTION bogus;             # exit 2; file unchanged (cmp against copy)
run_user set IDLE_DIM_SECONDS -5;            # exit 2
run_user set IDLE_DIM_SECONDS 12abc;         # exit 2
run_user set MEM_SLEEP deep;                 # exit 2 (not an allowed key)
rm "$conf"; run_user set BAT_REFRESH 60;     # exit 0; conf now exists, contains BAT_REFRESH=60 and the example's "# Idle timers" comment
printf 'HIBERNATE_DELAY=90min\n' >"$T/sys.conf"
BATTERY_SAVER_SYS_CONF=$T/sys.conf run_user conf-json | grep -q '"hibernate_delay":"90min"'
BATTERY_SAVER_SYS_CONF=$T/missing run_user conf-json | grep -q '"hibernate_delay":""'
```

- [ ] **Step 2: Run it, expect failures** — `bash scratchpad/test-battery-saver-set.sh`; expected: every `set` case fails with the usage error, both `conf-json` cases fail.

- [ ] **Step 3: Implement `set_value KEY VALUE` and `read_sys_hibernate_delay` in `bin/battery-saver`**

`set_value`: check key against the allowed list; validate (`SLEEP_ACTION` ∈ three actions; others `^[0-9]+$`); seed conf from the example if missing; `awk` the file to a temp file in the same directory replacing the first line matching `^KEY=` and appending `KEY=VALUE` if none matched; `mv` over the original; then `have omarchy-shell && [[ -z ${SLEEP_DRY_RUN:-} ]] && omarchy-shell battery-saver reload >/dev/null 2>&1`. `read_sys_hibernate_delay`: `grep -m1 '^HIBERNATE_DELAY=' "$sysconf"`, strip key and surrounding quotes, print (empty if unreadable). Add `set) set_value "$2" "$3" ;;` to the `case` and the new field to `conf_json`. Update the header usage block.

- [ ] **Step 4: Run the test, expect all pass**, then re-run `scratchpad/test-sleep-controls.sh` (must still be 14/14) and `omarchy-plugin-validate ~/.config/omarchy/plugins/qpc.battery-saver`.

---

### Task 2: `battery-saver-sys set-hibernate-delay` and the polkit rule

**Files:**
- Modify: `~/.config/omarchy/plugins/qpc.battery-saver/bin/battery-saver-sys` (after `apply_sleep_conf`, and the `case`)
- Create: `~/.config/omarchy/plugins/qpc.battery-saver/system/50-battery-saver.rules` (exact text in the spec, section "Polkit rule")
- Modify: `install.sh` `system_install` (install the rule to `/etc/polkit-1/rules.d/50-battery-saver.rules` mode 0644 and echo the one-line scope note from the spec), `uninstall.sh` `system_uninstall` (`rm -f` it)
- Modify: `README.md` of the battery-saver plugin (sleep controls table: mention `set-hibernate-delay` and the rule)
- Test: `scratchpad/test-set-hibernate-delay.sh`

**Interfaces:**
- Produces: `battery-saver-sys set-hibernate-delay VALUE` (exit 1 when `EUID != 0` unless `BATTERY_SAVER_SYS_ALLOW_UNPRIV=1` is set for tests; exit 2 on invalid timespan; rewrites `HIBERNATE_DELAY=` in `$CONF` with the same replace-or-append rule as Task 1; then calls `apply_sleep_conf`).

- [ ] **Step 1: Write the failing test**

```bash
# run_sys from test-sleep-controls.sh plus BATTERY_SAVER_SYS_ALLOW_UNPRIV=1
printf '%s\n' '# root conf' 'MEM_SLEEP=""' 'HIBERNATE_DELAY=2h' >"$T/sys.conf"
run_sys set-hibernate-delay 4h     # exit 0; conf line is HIBERNATE_DELAY=4h; other two lines identical; $T/sleepd/10-battery-saver.conf has HibernateDelaySec=4h
run_sys set-hibernate-delay soon   # exit 2; conf and drop-in unchanged
run_sys set-hibernate-delay ""     # exit 0; conf line is HIBERNATE_DELAY=""; drop-in removed
sed -i '/HIBERNATE_DELAY/d' "$T/sys.conf"; run_sys set-hibernate-delay 1h   # exit 0; line appended
env -u BATTERY_SAVER_SYS_ALLOW_UNPRIV ... set-hibernate-delay 1h            # exit 1, message mentions root
grep -q 'battery-saver-sys' system/50-battery-saver.rules && grep -q 'isInGroup("wheel")' system/50-battery-saver.rules
grep -q '50-battery-saver.rules' install.sh && grep -q '50-battery-saver.rules' uninstall.sh
```

- [ ] **Step 2: Run it, expect failures** (usage error from the helper; missing rule file).

- [ ] **Step 3: Implement `set_hibernate_delay VALUE`** in `bin/battery-saver-sys`, the rule file, and the install/uninstall lines. Factor the replace-or-append `awk` into a `conf_set FILE KEY VALUE` function in this script (the user-side script keeps its own copy; the two scripts do not source each other).

- [ ] **Step 4: Run the test, expect all pass**; re-run `test-sleep-controls.sh`; `bash -n` on install.sh and uninstall.sh.

---

### Task 3: `power-stats` window and full energy

**Files:**
- Modify: `~/.config/omarchy/plugins/qpc.power/bin/power-stats` (`status` function near line 43)
- Test: `scratchpad/test-power-stats.sh`

**Interfaces:**
- Produces: two extra `status` lines, `window<TAB><start>–<end>%` (en dash) or `window<TAB>—`, and `full_wh<TAB><n.n>` or `full_wh<TAB>—`. Battery sysfs root overridable with `POWER_STATS_SYS=<dir>` (default `/sys/class/power_supply`).

- [ ] **Step 1: Write the failing test** — build `$T/ps/BAT0/` with `charge_control_start_threshold=50`, `charge_control_end_threshold=80`, `charge_full=2259000`, `voltage_min_design=11400000`; assert `window	50–80%` and `full_wh	25.8` (2259000 µAh × 11.4 V / 1e6 = 25.75 → one decimal). Second fixture with `energy_full=34336800` only: `full_wh	34.3`. Third fixture with neither threshold file: `window	—`.

- [ ] **Step 2: Run it, expect failures** (lines absent).

- [ ] **Step 3: Implement `window()` and `full_wh()`** in `power-stats`, printed from `status` after `kbd`. Use `awk` for the one-decimal division. Add `POWER_STATS_SYS` at the top and use it in `health()` too.

- [ ] **Step 4: Run the test, expect pass**; run `bin/power-stats status` on the real machine and confirm `window	50–80%` and `full_wh	34.3`.

---

### Task 4: `Model.js` helpers

**Files:**
- Modify: `~/.config/omarchy/plugins/qpc.power/Model.js`
- Test: `scratchpad/test-model.mjs` (run with `node -I`-equivalent: `node --input-type=module` reading the file with `fs` and evaluating it in a `vm` context, since Model.js is plain ES5 with no imports)

**Interfaces:**
- Produces: `formatDuration(seconds) -> string` (`0`/negative/NaN → `""`; `< 60` → `"45s"`; `< 3600` → `"12m"`; else `"4h 20m"`, minutes omitted when 0 → `"4h"`).
- Produces: `HIBERNATE_PRESETS` (`[{value:"30min",label:"30m"},{value:"1h",label:"1h"},…{value:"12h",label:"12h"}]`) and `IDLE_PRESETS` (`[{value:0,label:"Off"},{value:30,label:"30s"},…{value:3600,label:"1h"}]`).
- Produces: `nearestPresetIndex(presets, value) -> int` (exact match wins; else the index whose numeric magnitude is closest; strings parsed with `timespanSeconds`; unknown → 0).
- Produces: `timespanSeconds(str) -> number` for `NNs NNmin NNm NNh NNd` and bare numbers (seconds); `NaN` otherwise.
- Produces: `sleepActionLabel(value) -> string` (`suspend`→`Suspend`, `suspend-then-hibernate`→`Then hibernate`, `hibernate`→`Hibernate`).

- [ ] **Step 1: Write the failing test** with the assertions above plus `nearestPresetIndex(HIBERNATE_PRESETS,"90min") === 2` (90 min is equidistant from 1h and 2h; ties round up, so index 2) and `nearestPresetIndex(IDLE_PRESETS, 45) === 2` (60).

- [ ] **Step 2: Run it, expect `is not a function`.**

- [ ] **Step 3: Implement the five exports** in `Model.js`, same style as the existing functions.

- [ ] **Step 4: Run the test, expect pass.**

---

### Task 5: Reusable QML components

**Files:**
- Create: `~/.config/omarchy/plugins/qpc.power/Card.qml`, `RingGauge.qml`, `SegmentedControl.qml`, `Stepper.qml`
- Test: `omarchy-plugin-validate ~/.config/omarchy/plugins/qpc.power` plus a throwaway `scratchpad/components-smoke.qml` loaded with `quickshell -p` that instantiates each component once (visual check only).

**Interfaces (Produces):**

```qml
// Card.qml  — Item; default property alias content: inner.data
property QtObject bar          // for foreground + fontFamily
property string title: ""      // rendered with PanelSectionHeader when non-empty
property real padding: Style.space(12)
// background: Rectangle fill Util.alpha(bar.foreground, 0.04), border Util.alpha(bar.foreground, 0.12), width 1, radius Style.cornerRadius

// RingGauge.qml — Canvas-based Item
property real fraction: 0      // 0..1
property int size: 64
property int stroke: 6
property color trackColor
property color fillColor
property string text: ""       // centred, Style.font.title, bold
// repaint on fractionChanged / colour change via requestPaint()

// SegmentedControl.qml — Item
property QtObject bar
property var model: []         // [{value, label}]
property var value
property bool busy: false
signal selected(var value)
// cells equal width, bordered (Util.alpha(fg,0.35)), selected cell fill Style.selectedFillFor(bar.foreground, Commons.Color.accent); busy → opacity 0.5, no clicks

// Stepper.qml — Item, width: parent.width
property QtObject bar
property string label; property string caption: ""
property var presets: []       // [{value,label}]
property var value
property bool enabled: true; property bool busy: false
signal changed(var value)
// left: label (bodySmall) + caption (caption, 0.6 opacity); right: "−" Button, value Text (min width Style.space(44), centred), "+" Button; index = Model.nearestPresetIndex(presets, value); ends disable the matching button; disabled → opacity 0.4
```

- [ ] **Step 1: Write the smoke file** that shows a `Card` containing a `RingGauge{fraction:0.92;text:"92%"}`, a `SegmentedControl` with the three sleep actions, and a `Stepper` with `Model.IDLE_PRESETS` value 600, logging each signal with `console.log`.

- [ ] **Step 2: Run `quickshell -p scratchpad/components-smoke.qml`**, expect import errors (files missing).

- [ ] **Step 3: Create the four components** per the interface block. `Stepper` clamps: `−` at index 0 and `+` at the last index do nothing.

- [ ] **Step 4: Re-run the smoke file**: window shows all four, clicking cells and ± logs the expected values; `omarchy-plugin-validate` passes.

---

### Task 6: Panel body, left column

**Files:**
- Modify: `~/.config/omarchy/plugins/qpc.power/Panel.qml` (`KeyboardPanel` block, currently lines 413–703; keep everything above 413 and the `component` definitions after 703)
- Modify: `bin/power-stats` consumer: `extras.window`, `extras.full_wh` (already parsed by `Model.parseKeyValue` via `extrasProc`)

**Interfaces:**
- Consumes: Task 3 fields, Task 4 `formatDuration`, Task 5 `Card`, `RingGauge`.
- Produces: `root.headlineText` (`formatDuration(timeToEmpty)` when discharging, `formatDuration(timeToFull)` when charging, else `heroStatusText`; when the duration string is empty fall back to `heroStatusText`), `root.captionText` (`modeLabel() + " · " + rate + " W"` when `changeRate > 0`, else `modeLabel()`), and the two-column skeleton: `Row { id: columns; spacing: Style.space(16); Column { id: leftCol; width: Style.space(230) } Column { id: rightCol; width: columns.width - leftCol.width - columns.spacing } }` with `contentWidth: panel.fittedContentWidth(Style.space(560))`, `contentHeight: panel.fittedContentHeight(columns.implicitHeight)`.

- [ ] **Step 1: Back up `Panel.qml`** to `Panel.qml.bak.<ts>`.

- [ ] **Step 2: Replace the `Column { id: column … }` body** with the two-column skeleton. Left column: Battery `Card` (Row: `RingGauge` + Column of headline `Style.font.title` bold and caption `Style.font.caption` 0.6 opacity; then three `InfoPair`s: `Health`→`extras.health`, `Full charge`→`extras.full_wh + " Wh"`, `Charge window`→`extras.window`), then Power profile `Card { title: "POWER PROFILE" }` with the existing `Repeater`/`Button` stacked in a `Column` (width `parent.width`, `leftAlign: true`). Keep the existing keyboard handling (`selectProfileByDelta`, `activateSelectedProfile`). Right column temporarily holds the existing Lid closed and Session columns unchanged so the panel stays usable.

- [ ] **Step 3: Verify**: `omarchy-plugin-validate` passes; open the panel (click the bar battery): two columns, ring at 92-ish %, headline shows `Nh Nm` on battery; `journalctl --user -u omarchy-shell -n 50` (or `omarchy-shell` console) shows no QML errors.

---

### Task 7: Right column with battery-saver controls

**Files:**
- Modify: `~/.config/omarchy/plugins/qpc.power/Panel.qml` (properties block near line 20, `refresh()` near line 193, new `Process`es next to the existing ones at 276–346, right column)
- Modify: `README.md` of `qpc.power` (controls list) and `manifest.json` `description` (mention sleep + battery saver)

**Interfaces:**
- Consumes: Task 1 `set`/`conf-json`, Task 2 `set-hibernate-delay`, Task 4 presets/labels, Task 5 `SegmentedControl`/`Stepper`/`Card`.
- Produces (in `Panel.qml`):

```qml
readonly property string batterySaverTool: Quickshell.env("HOME") + "/.config/omarchy/plugins/qpc.battery-saver/bin/battery-saver"
property bool batterySaverPresent: false      // set by a Process running: ["test","-x",batterySaverTool]
property var saverConf: ({})                  // parsed conf-json
property bool saverEnabled: true              // from omarchy-shell battery-saver status
function refreshSaver()                       // runs saverConfProc + saverStatusProc; called from refresh()
function setSaverValue(key, value)            // saverSetProc.command = [batterySaverTool,"set",key,String(value)]; on exit → refreshSaver()
function setHibernateDelay(value)             // hibernateProc.command = ["pkexec","/usr/local/bin/battery-saver-sys","set-hibernate-delay",String(value)]; on exit → refreshSaver()
function toggleSaver()                        // ["omarchy-shell","battery-saver", saverEnabled ? "disable" : "enable"]; on exit → refreshSaver()
readonly property bool saverBusy: saverSetProc.running || hibernateProc.running || saverToggleProc.running
```

- [ ] **Step 1: Add the properties, four `Process` objects and functions** above. Each `Process` has `stdout: StdioCollector { onStreamFinished: … }` like the existing ones; on `exitCode !== 0` log `"qpc.power: <action> failed (" + exitCode + ")"` and still call `refreshSaver()` so the control snaps back.

- [ ] **Step 2: Build the right column**: `Card { title: "SLEEP"; visible: batterySaverPresent }` with `SegmentedControl { model: [suspend, suspend-then-hibernate, hibernate] labelled via Model.sleepActionLabel; value: saverConf.sleep_action; busy: saverBusy; onSelected: setSaverValue("SLEEP_ACTION", value) }` and `Stepper { label: "Hibernate after"; caption: enabled ? "Time asleep before writing to disk" : "Only used by Then hibernate"; presets: Model.HIBERNATE_PRESETS; value: saverConf.hibernate_delay; enabled: saverConf.sleep_action === "suspend-then-hibernate"; busy: saverBusy; onChanged: setHibernateDelay(value) }`. Then `Card { title: "LID CLOSED" }` with the three existing `SwitchRow`s, first label `"Sleep"`, description `"Runs the sleep action above"`. Then `Card { title: "BATTERY SAVER"; visible: batterySaverPresent }`: `SwitchRow { label: "Enabled"; description: "Dim " + Model.formatDuration(idle_dim) + " · screen off " + … + " · sleep " + …; checked: saverEnabled; busy: saverToggleProc.running; onToggled: toggleSaver() }`, three `Stepper`s (`Dim after`/`IDLE_DIM_SECONDS`, `Screen off after`/`IDLE_SCREEN_OFF_SECONDS`, `Sleep after`/`IDLE_SUSPEND_SECONDS`, presets `Model.IDLE_PRESETS`), then the Stay awake and Keyboard backlight `SwitchRow`s. When `!batterySaverPresent`, a `Card { title: "SESSION" }` holds those two switches instead.

- [ ] **Step 3: Verify in the shell**: validate passes; panel opens; flipping the segmented control changes `battery-saver status` → `sleep action:` within a second; stepping Hibernate after shows no password dialog yet (rule not installed) → the pkexec dialog appears, cancel it, confirm the stepper snaps back to `2h` and no retry dialog appears; toggling Enabled flips `omarchy-shell battery-saver status` `enabled`; Dim after step changes the conf and the Enabled caption updates.

- [ ] **Step 4: Update `README.md` and `manifest.json` description.**

---

### Task 8: Root-side install, final verification, docs

**Files:**
- Install: `/usr/local/bin/battery-saver-sys` (from Task 2), `/etc/polkit-1/rules.d/50-battery-saver.rules`
- Modify: `~/.claude/projects/-home-qpc/memory/latitude-5511-maintenance-2026-10-28.md` (one line: panel now edits battery-saver; polkit rule present)
- Replace: `~/.config/omarchy/plugins/qpc.power/preview.png` with a fresh screenshot

- [ ] **Step 1: Back up and install the helper**: `pkexec cp -a /usr/local/bin/battery-saver-sys /usr/local/bin/battery-saver-sys.bak-20261029b`, then `pkexec install -m 0755 <plugin>/bin/battery-saver-sys /usr/local/bin/battery-saver-sys`; `diff -q` both.

- [ ] **Step 2: Install the polkit rule**: `pkexec install -m 0644 <plugin>/system/50-battery-saver.rules /etc/polkit-1/rules.d/50-battery-saver.rules`. Verify: `pkexec /usr/local/bin/battery-saver-sys status` returns without a dialog.

- [ ] **Step 3: End-to-end**: in the panel step Hibernate after to `3h`; `systemd-analyze cat-config systemd/sleep.conf | grep HibernateDelaySec` shows `3h`; step back to `2h`; confirm again. Flip sleep action to Suspend and back; `lid-switch plan` with the suspend flag on still lists `suspend`.

- [ ] **Step 4: Screenshots**: `omarchy capture screenshot` of the open panel on AC and, after unplugging, on battery (ring and headline change); save the AC one as `preview.png` (back up the old one).

- [ ] **Step 5: Vertical bar check**: temporarily set `"position":"left"` in `~/.config/omarchy/shell.json`, open the panel, confirm it fits and both columns are usable, restore `"top"`.

- [ ] **Step 6: Memory note** one-line update; stop the brainstorm companion server (`bash <skill>/scripts/stop-server.sh <session dir>`).
