// Pure logic for Low Tide: which warning stage a battery reading is in, what
// to announce, and when to start, cancel, or carry out the last-resort action.
// No QML imports, so it runs under node for tests.

function glyph(codePoint) {
  return String.fromCodePoint(codePoint)
}

var GLYPHS = {
  low: glyph(0xF007A),       // md-battery-alert
  critical: glyph(0xF0083),  // md-battery-outline
  charging: glyph(0xF0084),  // md-battery-charging
  hibernate: glyph(0xF0904)  // md-power-sleep
}

var ACTIONS = ["hibernate", "poweroff", "none"]

function clampInt(value, fallback, min, max) {
  var n = parseInt(String(value === undefined || value === null ? fallback : value), 10)
  if (!isFinite(n)) n = fallback
  return Math.max(min, Math.min(max, n))
}

// Settings from the plugin's shell.json entry. `levels` are alert percentages,
// highest first; the lowest of them is where the screen frame starts.
// `actionAt` must sit below every alert level or the warnings would be moot.
function readConfig(entry) {
  var e = entry || {}
  var raw = Array.isArray(e.levels) ? e.levels : [20, 15, 10]
  var levels = []
  for (var i = 0; i < raw.length; i++) {
    var n = parseInt(String(raw[i]), 10)
    if (isFinite(n) && n >= 2 && n <= 95 && levels.indexOf(n) === -1) levels.push(n)
  }
  if (levels.length === 0) levels = [20, 15, 10]
  levels.sort(function(a, b) { return b - a })
  var action = ACTIONS.indexOf(String(e.action)) !== -1 ? String(e.action) : "hibernate"
  var lowest = levels[levels.length - 1]
  return {
    levels: levels,
    action: action,
    actionAt: Math.min(clampInt(e.actionAt, 7, 1, 50), lowest - 1),
    countdownSec: clampInt(e.countdownSec, 60, 10, 600),
    frame: e.frame !== false,
    notify: e.notify !== false
  }
}

// Deepest alert level a percentage has reached: 0 is the first (highest)
// level, levels.length-1 the last. -1 means above all of them.
function stageFor(percent, levels) {
  var stage = -1
  for (var i = 0; i < levels.length; i++) if (percent <= levels[i]) stage = i
  return stage
}

// The heart of it. Given where things stood and a new reading, returns the
// next state and a list of effects for the service to carry out.
//   reading: { percent, discharging }     (percent < 0 means "no battery")
//   state:   { announced, countdownEndsAt, actedAt }
//     announced        deepest stage already announced this discharge, -1 none
//     countdownEndsAt  ms timestamp the action fires, 0 when not counting
//     actedAt          percent at which the action last ran, -1 never
//   effects: { type: "alert", stage, percent } | { type: "countdown", seconds }
//            | { type: "cancel", reason } | { type: "act", action }
function step(previous, reading, config, nowMs) {
  // A fresh install has no stored state at all, so every field needs a default.
  var p = previous || {}
  var state = {
    announced: typeof p.announced === "number" ? p.announced : -1,
    countdownEndsAt: typeof p.countdownEndsAt === "number" ? p.countdownEndsAt : 0,
    actedAt: typeof p.actedAt === "number" ? p.actedAt : -1
  }
  var effects = []

  // Plugged in, full, or no battery at all: stand down and re-arm everything.
  if (!reading.discharging || reading.percent < 0) {
    if (state.countdownEndsAt > 0) effects.push({ type: "cancel", reason: "charging" })
    return { state: { announced: -1, countdownEndsAt: 0, actedAt: -1 }, effects: effects }
  }

  var stage = stageFor(reading.percent, config.levels)
  // Climbing back above a level (a recalibrating gauge, a lighter load)
  // re-arms that level's alert, with 2% of slack so it can't chatter.
  if (stage < state.announced) {
    var ceiling = state.announced >= 0 ? config.levels[state.announced] : 0
    if (reading.percent > ceiling + 2) state.announced = stage
  }
  // Only the deepest stage reached is announced: waking at 12% on battery
  // gets one alert, not the three it slept through.
  if (stage > state.announced) {
    state.announced = stage
    effects.push({ type: "alert", stage: stage, percent: reading.percent, last: stage === config.levels.length - 1 })
  }

  if (config.action === "none") return { state: state, effects: effects }

  // After acting once (say, a hibernate you resumed from while still
  // unplugged), don't fire again until the charge has fallen a further 2%.
  var rearmed = state.actedAt < 0 || reading.percent <= state.actedAt - 2
  if (reading.percent <= config.actionAt && rearmed) {
    if (state.countdownEndsAt === 0) {
      state.countdownEndsAt = nowMs + config.countdownSec * 1000
      effects.push({ type: "countdown", seconds: config.countdownSec, action: config.action })
    } else if (nowMs >= state.countdownEndsAt) {
      state.countdownEndsAt = 0
      state.actedAt = reading.percent
      effects.push({ type: "act", action: config.action })
    }
  } else if (state.countdownEndsAt > 0 && reading.percent > config.actionAt) {
    state.countdownEndsAt = 0
    effects.push({ type: "cancel", reason: "recovered" })
  }
  return { state: state, effects: effects }
}

// The frame shows from the last alert level down, while discharging.
function frameActive(reading, config) {
  if (!config.frame || !reading.discharging || reading.percent < 0) return false
  return reading.percent <= config.levels[config.levels.length - 1]
}

function secondsLeftText(seconds) {
  var s = Math.max(0, Math.round(Number(seconds) || 0))
  if (s <= 0) return ""
  if (s < 90) return "about a minute"
  var minutes = Math.round(s / 60)
  if (minutes < 90) return minutes + " min"
  return Math.floor(minutes / 60) + " h " + (minutes % 60) + " min"
}

function actionVerb(action) {
  return action === "poweroff" ? "Shutting down" : "Hibernating"
}

// Alerts get louder as they go: a quiet toast, then one that breaks through
// Do Not Disturb, then one that stays on screen until dismissed.
function alertToast(effect, config, secondsLeft) {
  var left = secondsLeftText(secondsLeft)
  var body = left !== "" ? left + " left at this rate." : "Plug in soon."
  if (effect.last && config.action !== "none") {
    body += " " + (config.action === "poweroff" ? "Shuts down" : "Hibernates") + " at " + config.actionAt + "%."
  }
  return {
    headline: "Battery at " + effect.percent + "%",
    body: body,
    urgency: effect.stage === 0 ? "normal" : "critical",
    bypassDnd: effect.stage > 0,
    sticky: effect.last === true
  }
}

function countdownToast(effect) {
  return {
    headline: actionVerb(effect.action) + " in " + effect.seconds + " s",
    body: "Plug in to cancel.",
    urgency: "critical", bypassDnd: true, sticky: true
  }
}

function barText(reading, secondsLeft, countdownSecLeft) {
  if (countdownSecLeft > 0) return GLYPHS.hibernate + " " + countdownSecLeft + "s"
  var left = secondsLeftText(secondsLeft)
  return GLYPHS.low + " " + reading.percent + "%" + (left !== "" && left.indexOf("min") !== -1 && left.indexOf("h") === -1 ? " · " + left.replace(" min", "m") : "")
}

function statusText(reading, config, state, secondsLeft, nowMs) {
  if (reading.percent < 0) return "No battery"
  if (!reading.discharging) return reading.percent + "% · on power"
  if (state && state.countdownEndsAt > 0) {
    return actionVerb(config.action) + " in " + Math.max(0, Math.ceil((state.countdownEndsAt - nowMs) / 1000)) + " s"
  }
  var left = secondsLeftText(secondsLeft)
  return reading.percent + "%" + (left !== "" ? " · " + left + " left" : "")
}

function entryFromShellJson(raw, id) {
  var merged = null
  function take(entry) {
    if (!entry || entry.id !== id) return
    if (!merged) merged = { id: id }
    for (var key in entry) merged[key] = entry[key]
  }
  try {
    var doc = JSON.parse(String(raw || "{}"))
    var list = (doc && doc.plugins) || []
    for (var i = 0; i < list.length; i++) take(list[i])
    var layout = (doc && doc.bar && doc.bar.layout) || {}
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var widgets = layout[sections[s]] || []
      for (var w = 0; w < widgets.length; w++) take(widgets[w])
    }
  } catch (e) {
    return null
  }
  return merged
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    GLYPHS: GLYPHS, readConfig: readConfig, stageFor: stageFor, step: step, frameActive: frameActive,
    secondsLeftText: secondsLeftText, actionVerb: actionVerb, alertToast: alertToast, countdownToast: countdownToast,
    barText: barText, statusText: statusText, entryFromShellJson: entryFromShellJson
  }
}
