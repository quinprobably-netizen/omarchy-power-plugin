# Power panel redesign — design spec

Date: 2026-10-29
Plugins: `qpc.power` (bar widget, owns the panel), `qpc.battery-saver` (headless service, owns the settings the panel now edits)
Status: approved in conversation; awaiting written review

## Goal

Give the `qpc.power` popup a new look (two-column cards, blend "A" from the
brainstorm) and make it the one place for every power setting on this laptop,
including the battery-saver plugin's sleep action, hibernate delay, idle timers
and master switch. No behaviour of the underlying scripts changes except where
a new subcommand is added.

## Visual design (approved)

Panel about 560 px wide (`Style.space(560)` through `panel.fittedContentWidth`,
so the shell clamps it on small or vertical screens). Two columns, left about
230 px, 16 px gutter, 12 px between cards.

Card surface: slightly lighter than the popup background plus a dark hairline.
Expressed in theme terms, not hex: fill `Util.alpha(foreground, 0.04)`, border
`Util.alpha(foreground, 0.12)`, padding `Style.space(12)`, square corners like
every other Omarchy popup. Section headers use the stock `PanelSectionHeader`.
Switches use the stock `ToggleSwitch` through the existing `SwitchRow`.
Buttons use the stock `Button`.

Left column:

1. **Battery card.** Ring gauge (64 px, stroke 6 px, fill = charge fraction,
   track = `Util.alpha(foreground, 0.12)`) with the percentage inside. Beside
   it, the headline: time to empty or time to full as `4h 20m`, or the existing
   `heroStatusText` when neither is known. Under the headline, a caption:
   state and power draw (`Discharging · 7.1 W`). Below, three label/value
   rows: Health, Full charge (Wh), Charge window (from
   `charge_control_start_threshold`/`end_threshold`, or "—"). Cycles row is
   dropped: this firmware reports 0.
2. **Power profile card.** The existing three profile buttons, stacked
   vertically to fit the narrow column, same keyboard handling as today.

Right column:

3. **Sleep card.** A three-way segmented control: Suspend · Then hibernate ·
   Hibernate, bound to `SLEEP_ACTION`. Below it a stepper row "Hibernate
   after" bound to `HIBERNATE_DELAY`, presets `30min 1h 2h 3h 4h 6h 8h 12h`.
   The stepper is disabled, with caption "Only used by Then hibernate", when
   the action is not suspend-then-hibernate.
4. **Lid closed card.** The three existing switches (Sleep, Lock session,
   Backlight off). The first label changes from "Suspend" to "Sleep" because
   it now runs whatever the Sleep card says.
5. **Battery saver card.** Master switch (plugin `enable`/`disable` IPC) with
   caption summarising the timers (`Dim 1m · screen off 2m · sleep 10m`).
   Three stepper rows: Dim after, Screen off after, Sleep after, bound to
   `IDLE_DIM_SECONDS`, `IDLE_SCREEN_OFF_SECONDS`, `IDLE_SUSPEND_SECONDS`.
   Presets `Off 30s 1m 2m 5m 10m 15m 30m 1h` (Off = 0). Then the two existing
   session switches, Stay awake and Keyboard backlight.

If the battery-saver plugin is not installed (its `bin/battery-saver` is not
executable), the Sleep and Battery saver cards are hidden and the right
column shows Lid closed followed by a Session card with the two switches.

Bar widget: unchanged.

## New QML components (inside `qpc.power/`)

- `Card.qml` — `Item` with the surface/hairline above and a default `Column`
  content slot. Props: `title` (optional header).
- `SegmentedControl.qml` — `Row` of equal-width cells. Props: `model`
  (`[{value, label}]`), `value`, `busy`; signal `selected(value)`. Selected
  cell uses `Style.selectedFillFor`. Keyboard: left/right when focused.
- `Stepper.qml` — label + caption on the left, `−  value  +` on the right.
  Props: `label`, `caption`, `presets` (`[{value, label}]`), `value`,
  `enabled`, `busy`; signal `changed(value)`. Clamps at the ends. If the
  current value is not in presets it is shown verbatim and `+`/`−` jump to the
  nearest preset.
- `RingGauge.qml` — `Canvas`; props `fraction`, `size`, `stroke`, `trackColor`,
  `fillColor`, `text`.

`Panel.qml` keeps its existing data plumbing (UPower, `omarchy-powerprofiles-*`,
`lid-switch`, `power-stats`, stay-awake) and gains the battery-saver plumbing
described next. `Model.js` gains `formatDuration(seconds)` for `4h 20m` and
the preset tables.

## Data flow

Reads, on open and on the existing 5 s timer:

| Source | Command | Fields used |
|---|---|---|
| UPower (live) | – | percentage, state, timeToEmpty, timeToFull, changeRate, energy, energyFull |
| battery-saver conf | `battery-saver conf-json` | `sleep_action`, `idle_*_seconds`, new `hibernate_delay` |
| battery-saver service | `omarchy-shell battery-saver status` | `enabled` |
| power-stats | `power-stats status` | `health`, `kbd`, new `window` (`50–80%`), new `full_wh` |
| lid-switch | `lid-switch status` | unchanged |

`conf-json` learns `hibernate_delay`: the user-side script reads
`HIBERNATE_DELAY` from `/etc/battery-saver.conf` (world-readable) so the panel
needs no root to display it.

Writes, each followed by an immediate re-read:

| Control | Command |
|---|---|
| Sleep action | `battery-saver set SLEEP_ACTION <value>` |
| Idle timers | `battery-saver set IDLE_DIM_SECONDS <n>` (and the other two keys) |
| Master switch | `omarchy-shell battery-saver enable|disable` |
| Hibernate delay | `pkexec /usr/local/bin/battery-saver-sys set-hibernate-delay <value>` |
| Profile, lid, stay awake, keyboard | unchanged |

While a write is running, the control shows `busy` and ignores further input.
If the process exits non-zero, the control snaps back to the last read value
and the error line is logged with `console.log("qpc.power: ...")`.

## Script changes

### `qpc.battery-saver/bin/battery-saver`

New subcommand `set KEY VALUE`:

- Allowed keys: `SLEEP_ACTION`, `IDLE_DIM_SECONDS`, `IDLE_SCREEN_OFF_SECONDS`,
  `IDLE_SUSPEND_SECONDS`, `IDLE_DIM_PERCENT`, `BAT_BRIGHTNESS`, `BAT_REFRESH`.
  Anything else exits 2.
- Validation: `SLEEP_ACTION` must be one of the three actions; numeric keys
  must be non-negative integers. Invalid exits 2 with a message on stderr.
- Edits `~/.config/omarchy/battery-saver.conf` in place with a temp file and
  `mv`, replacing the first uncommented `KEY=` line and preserving every other
  line (comments included). If the key is absent, appends `KEY=VALUE`. If the
  conf file does not exist, seeds it from `battery-saver.conf.example` first.
- After writing, runs `omarchy-shell battery-saver reload` if available, so the
  idle timers re-arm without waiting for the file watcher.
- `conf-json` gains `"hibernate_delay":"2h"` read from `/etc/battery-saver.conf`
  (empty string when unset or unreadable).

### `qpc.battery-saver/bin/battery-saver-sys`

New subcommand `set-hibernate-delay VALUE`:

- Root only (exits 1 otherwise).
- `VALUE` must pass the existing `valid_timespan`, or be empty to clear.
- Rewrites the `HIBERNATE_DELAY=` line in `/etc/battery-saver.conf` the same
  way as the user-side `set` (temp file, comments preserved, append if
  missing), then calls `apply_sleep_conf` so the systemd drop-in follows.

### Polkit rule `qpc.battery-saver/system/50-battery-saver.rules`

Installed to `/etc/polkit-1/rules.d/50-battery-saver.rules` by
`install.sh --system`, removed by `uninstall.sh --system`:

```js
// qpc.battery-saver: let wheel change the hibernate delay from the panel
// without a password. Only this one program and action are covered.
polkit.addRule(function(action, subject) {
  if (action.id == "org.freedesktop.policykit.exec" &&
      action.lookup("program") == "/usr/local/bin/battery-saver-sys" &&
      subject.isInGroup("wheel") && subject.active && subject.local) {
    return polkit.Result.YES;
  }
});
```

Note: this allows any `battery-saver-sys` subcommand via pkexec for active
local wheel users, which is acceptable because every subcommand only applies
settings already defined in `/etc/battery-saver.conf` or validated inputs.
The install step prints this so the user knows.

### `qpc.power/bin/power-stats`

`status` gains two lines: `window<TAB>50–80%` (from
`charge_control_start_threshold`/`end_threshold`; `—` if absent) and
`full_wh<TAB>34.3` (from `energy_full` or `charge_full × voltage_min_design`).

### `qpc.power/bin/lid-switch`

Already calls `battery-saver sleep`; only the panel label changes.

## Installation

- QML and `bin/` changes hot-reload (user plugins reload on save; `omarchy
  restart shell` if needed).
- Root side, run as separate pkexec steps, each backed up with a dated suffix
  as before: install the new `battery-saver-sys`, install the polkit rule.
  No conf changes needed on the root side.

## Testing

Scripted (bash, in the session scratchpad, extend `test-sleep-controls.sh`):

- `battery-saver set` for each allowed key: value replaced, comments and
  other keys byte-identical, append when missing, seed when the conf is absent,
  rejection of bad keys and bad values, exit codes.
- `battery-saver conf-json` includes `hibernate_delay` from a test conf.
- `battery-saver-sys set-hibernate-delay` against a temp conf and temp
  `sleep.conf.d`: line rewritten, drop-in updated, empty clears, invalid
  rejected, non-root exits 1.
- `power-stats status` emits `window` and `full_wh` lines.
- `bash -n` on every script; `omarchy-plugin-validate` on both plugins.

Manual, after reload: open the panel on AC and on battery and screenshot both
(`omarchy capture screenshot` of the region); flip the sleep action and watch
`battery-saver status`; step the hibernate delay and confirm
`systemd-analyze cat-config systemd/sleep.conf` follows; toggle the master
switch and confirm `omarchy-shell battery-saver status`; confirm the bar
widget is unchanged; confirm the panel is usable on a vertical bar.

## Out of scope

- Charge threshold editing (firmware setting; stays in sysfs).
- Editing `MEM_SLEEP` or any other root-side knob besides the hibernate delay.
- Changing the bar widget.
- Light-theme tuning beyond using theme tokens (all colours derive from the
  theme foreground/background so other themes keep working).

## Revision 2026-10-29 (compact pass)

After the first build the panel was judged too tall. Changes: Sleep card
moved to the left column under Power profile, Lid closed moved to the right
column above Battery saver so both columns end level; panel 540 px wide,
column gap 12, card gap 8, card padding 10, inner spacing 4; ring 52/5;
switch and stepper rows lose 4 px each; segmented control 85% of control
height; shorter lid and hibernate captions. Height dropped by about a third.
