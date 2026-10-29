function clampIndex(index, length) {
  if (length <= 0) return 0
  return Math.max(0, Math.min(length - 1, index))
}

function selectProfileIndex(index, delta, profiles) {
  var values = Array.isArray(profiles) ? profiles : []
  if (values.length === 0) return 0
  return clampIndex(index + delta, values.length)
}

function parseKeyValue(raw) {
  var next = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var idx = lines[i].indexOf("\t")
    if (idx <= 0) continue
    next[lines[i].substring(0, idx)] = lines[i].substring(idx + 1).trim()
  }
  return next
}

function parseProfiles(raw, previousIndex) {
  var lines = String(raw || "").split("\n")
  var list = []
  var active = ""
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    var parts = line.split("\t")
    list.push(parts[0])
    if (parts[1] === "1") active = parts[0]
  }
  return {
    profiles: list,
    activeProfile: active,
    profileIndex: clampIndex(previousIndex || 0, list.length)
  }
}

function profileIcon(name) {
  if (name === "power-saver") return "󰌪"
  if (name === "balanced") return "󰊚"
  if (name === "performance") return "󰓅"
  return "󰂄"
}

function batteryFraction(device) {
  return device && device.isPresent ? Math.max(0, Math.min(1, device.percentage)) : 0
}

function chargeThresholdActive(device, onBattery, states) {
  var d = device || {}
  var s = states || {}
  if (!(d && d.isPresent && !onBattery)) return false

  var fraction = batteryFraction(d)
  if (d.state === s.Discharging) return false
  if (d.state === s.PendingCharge) return true
  if (d.state === s.FullyCharged && fraction < 0.99) return true
  if (d.state !== s.Charging || fraction >= 0.99) return false

  return Number(d.changeRate || 0) <= 0.2 || Number(d.timeToFull || 0) >= 8 * 60 * 60
}

function batteryIcon(device, onBattery, states) {
  var d = device || {}
  if (!d.isPresent) return ""

  var chargingIcons = ["󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"]
  var defaultIcons = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
  var index = Math.max(0, Math.min(9, Math.floor(d.percentage * 10)))
  var threshold = chargeThresholdActive(d, onBattery, states)

  if (threshold) return defaultIcons[index]
  if (d.state === states.FullyCharged) return "󰂅"
  if (!onBattery) return chargingIcons[index]
  return defaultIcons[index]
}

function modeLabel(device, onBattery, states) {
  var d = device || {}
  if (!d.isPresent) return ""

  var percentage = d.isPresent ? d.percentage : 0
  if (chargeThresholdActive(d, onBattery, states)) return "Threshold"
  if (onBattery) return "On battery"
  if (!onBattery && percentage >= 1) return "Fully charged"
  return "Charging"
}

if (typeof module !== "undefined") {
  module.exports = {
    clampIndex: clampIndex,
    selectProfileIndex: selectProfileIndex,
    parseKeyValue: parseKeyValue,
    parseProfiles: parseProfiles,
    profileIcon: profileIcon,
    batteryFraction: batteryFraction,
    chargeThresholdActive: chargeThresholdActive,
    batteryIcon: batteryIcon,
    modeLabel: modeLabel
  }
}

// ---- durations, presets and labels for the redesigned panel ----

// "4h 20m" style duration. Empty for zero, negative or unknown so callers
// can fall back to a status phrase instead of showing "0m".
function formatDuration(seconds) {
  var s = Math.floor(Number(seconds))
  if (!(s > 0)) return ""
  if (s < 60) return s + "s"
  var minutes = Math.floor(s / 60)
  if (minutes < 60) return minutes + "m"
  var hours = Math.floor(minutes / 60)
  var rest = minutes % 60
  return rest > 0 ? hours + "h " + rest + "m" : hours + "h"
}

// systemd time span → seconds. Accepts NNs NNm NNmin NNh NNd and a bare
// number of seconds; anything else is NaN.
function timespanSeconds(text) {
  var m = /^\s*(\d+)\s*(s|sec|m|min|h|hr|d)?\s*$/.exec(String(text === undefined || text === null ? "" : text))
  if (!m) return NaN
  var n = Number(m[1])
  switch (m[2] || "s") {
    case "s": case "sec": return n
    case "m": case "min": return n * 60
    case "h": case "hr": return n * 3600
    case "d": return n * 86400
  }
  return NaN
}

var HIBERNATE_PRESETS = [
  { value: "30min", label: "30m" },
  { value: "1h", label: "1h" },
  { value: "2h", label: "2h" },
  { value: "3h", label: "3h" },
  { value: "4h", label: "4h" },
  { value: "6h", label: "6h" },
  { value: "8h", label: "8h" },
  { value: "12h", label: "12h" }
]

var IDLE_PRESETS = [
  { value: 0, label: "Off" },
  { value: 30, label: "30s" },
  { value: 60, label: "1m" },
  { value: 120, label: "2m" },
  { value: 300, label: "5m" },
  { value: 600, label: "10m" },
  { value: 900, label: "15m" },
  { value: 1800, label: "30m" },
  { value: 3600, label: "1h" }
]

// Index of the preset matching `value`, else the one nearest in seconds
// (ties round up). Unknown values and empty lists give 0.
function nearestPresetIndex(presets, value) {
  var list = Array.isArray(presets) ? presets : []
  if (list.length === 0) return 0
  for (var i = 0; i < list.length; i++) {
    if (String(list[i].value) === String(value)) return i
  }
  var target = timespanSeconds(value)
  if (isNaN(target)) return 0
  var best = 0, bestDistance = Infinity
  for (var j = 0; j < list.length; j++) {
    var distance = Math.abs(timespanSeconds(list[j].value) - target)
    if (distance < bestDistance || (distance === bestDistance && timespanSeconds(list[j].value) > target)) {
      best = j
      bestDistance = distance
    }
  }
  return best
}

function sleepActionLabel(value) {
  switch (String(value)) {
    case "suspend": return "Suspend"
    case "suspend-then-hibernate": return "Then hibernate"
    case "hibernate": return "Hibernate"
  }
  return String(value)
}

// Index to move to from `value` by `delta` (+1/-1). An exact preset steps to
// its neighbour; a value between presets goes to the first preset above (+)
// or the last preset below (−); an empty/unknown value goes to the first
// preset (+) or nowhere (−). Returns -1 for "nothing below", and the top
// index when already at the top.
function stepPresetIndex(presets, value, delta) {
  var list = Array.isArray(presets) ? presets : []
  if (list.length === 0) return -1
  var up = Number(delta) > 0
  var i
  for (i = 0; i < list.length; i++) {
    if (String(list[i].value) === String(value)) {
      return up ? Math.min(list.length - 1, i + 1) : i - 1
    }
  }
  var target = timespanSeconds(value)
  if (isNaN(target)) return up ? 0 : -1
  if (up) {
    for (i = 0; i < list.length; i++) if (timespanSeconds(list[i].value) > target) return i
    return list.length - 1
  }
  for (i = list.length - 1; i >= 0; i--) if (timespanSeconds(list[i].value) < target) return i
  return -1
}
