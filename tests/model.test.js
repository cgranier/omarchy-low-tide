// Run with: node tests/model.test.js
const assert = require("assert")
const M = require("../Model.js")
let passed = 0
function test(name, fn) { fn(); passed += 1; console.log("ok - " + name) }

const cfg = M.readConfig({})
const types = (r) => r.effects.map((e) => e.type)
// Drives step() through a series of readings, one per `tickMs`.
function run(readings, config = cfg, start = {}, tickMs = 10000) {
  let state = start, now = 1000000, log = []
  for (const [percent, discharging] of readings) {
    const r = M.step(state, { percent, discharging }, config, now)
    state = r.state
    log.push(...r.effects.map((e) => ({ at: percent, ...e })))
    now += tickMs
  }
  return { state, log }
}

test("readConfig: defaults, sorting, and an action level kept below every alert", () => {
  assert.deepStrictEqual(cfg, { levels: [20, 15, 10], action: "hibernate", actionAt: 7, countdownSec: 60, frame: true, notify: true })
  assert.deepStrictEqual(M.readConfig({ levels: [10, "25", 15, 15, 999, "x"] }).levels, [25, 15, 10])
  assert.deepStrictEqual(M.readConfig({ levels: [] }).levels, [20, 15, 10])
  assert.strictEqual(M.readConfig({ levels: [20, 8], actionAt: 12 }).actionAt, 7)      // forced under the lowest level
  assert.strictEqual(M.readConfig({ action: "explode" }).action, "hibernate")
  assert.strictEqual(M.readConfig({ action: "none" }).action, "none")
  assert.strictEqual(M.readConfig({ countdownSec: 1 }).countdownSec, 10)
})

test("stageFor", () => {
  assert.deepStrictEqual([50, 21, 20, 16, 15, 10, 3].map((p) => M.stageFor(p, cfg.levels)), [-1, -1, 0, 0, 1, 2, 2])
})

test("a normal discharge announces each level exactly once", () => {
  const { log } = run([[25, true], [21, true], [20, true], [19, true], [16, true], [15, true], [14, true], [11, true], [10, true], [9, true]])
  assert.deepStrictEqual(log.map((e) => [e.type, e.at, e.stage]), [["alert", 20, 0], ["alert", 15, 1], ["alert", 10, 2]])
  assert.strictEqual(log[2].last, true)
  assert.strictEqual(log[0].last, false)
})

test("waking up already low announces only the deepest level", () => {
  const { log } = run([[12, true], [12, true]])
  assert.deepStrictEqual(log.map((e) => [e.type, e.stage]), [["alert", 1]])
})

test("plugging in stands down and re-arms", () => {
  const { log, state } = run([[18, true], [17, false], [19, false], [18, true]])
  assert.deepStrictEqual(log.map((e) => [e.type, e.at]), [["alert", 18], ["alert", 18]])
  assert.strictEqual(state.announced, 0)
  assert.deepStrictEqual(run([[50, false], [-1, true]]).log, [])                       // no battery: nothing
})

test("a gauge that wobbles around a level doesn't chatter", () => {
  const { log } = run([[20, true], [21, true], [20, true], [22, true], [20, true], [23, true], [20, true]])
  // 21 and 22 are within the 2% slack of level 20; 23 re-arms it.
  assert.deepStrictEqual(log.map((e) => e.at), [20, 20])
})

test("countdown starts at the action level, then acts when it runs out", () => {
  const { log, state } = run([[8, true], [7, true], [7, true], [7, true], [7, true], [7, true], [7, true], [6, true]])
  assert.deepStrictEqual(log.map((e) => e.type), ["alert", "countdown", "act"])
  assert.deepStrictEqual(log[1], { at: 7, type: "countdown", seconds: 60, action: "hibernate" })
  assert.strictEqual(log[2].at, 6)                                                      // 60 s = 6 ticks of 10 s later
  assert.strictEqual(state.actedAt, 6)
  assert.strictEqual(state.countdownEndsAt, 0)
})

test("plugging in during the countdown cancels it", () => {
  const { log, state } = run([[7, true], [7, true], [7, false], [7, false]])
  assert.deepStrictEqual(log.map((e) => [e.type, e.reason]), [["alert", undefined], ["countdown", undefined], ["cancel", "charging"]])
  assert.strictEqual(state.countdownEndsAt, 0)
})

test("no hibernate loop: after resuming unplugged it waits for a further 2% drop", () => {
  const resumed = { announced: 2, countdownEndsAt: 0, actedAt: 6 }
  assert.deepStrictEqual(run([[6, true], [6, true], [5, true]], cfg, resumed).log, [])
  const again = run([[4, true]], cfg, resumed)
  assert.deepStrictEqual(again.log.map((e) => e.type), ["countdown"])
})

test("action 'none' only ever alerts", () => {
  const { log } = run([[10, true], [7, true], [3, true], [1, true]], M.readConfig({ action: "none" }))
  assert.deepStrictEqual(log.map((e) => e.type), ["alert"])
})

test("frame, texts, and toasts", () => {
  assert.strictEqual(M.frameActive({ percent: 10, discharging: true }, cfg), true)
  assert.strictEqual(M.frameActive({ percent: 11, discharging: true }, cfg), false)
  assert.strictEqual(M.frameActive({ percent: 5, discharging: false }, cfg), false)
  assert.strictEqual(M.frameActive({ percent: 5, discharging: true }, M.readConfig({ frame: false })), false)
  assert.deepStrictEqual([0, 45, 600, 5400, 8000].map(M.secondsLeftText), ["", "about a minute", "10 min", "1 h 30 min", "2 h 13 min"])
  const first = M.alertToast({ stage: 0, percent: 20, last: false }, cfg, 1500)
  assert.deepStrictEqual(first, { headline: "Battery at 20%", body: "25 min left at this rate.", urgency: "normal", bypassDnd: false, sticky: false })
  const last = M.alertToast({ stage: 2, percent: 10, last: true }, cfg, 600)
  assert.deepStrictEqual(last, { headline: "Battery at 10%", body: "10 min left at this rate. Hibernates at 7%.", urgency: "critical", bypassDnd: true, sticky: true })
  assert.strictEqual(M.alertToast({ stage: 2, percent: 10, last: true }, M.readConfig({ action: "poweroff" }), 0).body, "Plug in soon. Shuts down at 7%.")
  assert.strictEqual(M.alertToast({ stage: 2, percent: 10, last: true }, M.readConfig({ action: "none" }), 0).body, "Plug in soon.")
  assert.deepStrictEqual(M.countdownToast({ seconds: 60, action: "hibernate" }).headline, "Hibernating in 60 s")
  assert.strictEqual(M.countdownToast({ seconds: 30, action: "poweroff" }).headline, "Shutting down in 30 s")
  assert.strictEqual(M.barText({ percent: 12 }, 840, 0), M.GLYPHS.low + " 12% · 14m")
  assert.strictEqual(M.barText({ percent: 12 }, 0, 0), M.GLYPHS.low + " 12%")
  assert.strictEqual(M.barText({ percent: 7 }, 300, 42), M.GLYPHS.hibernate + " 42s")
  assert.strictEqual(M.statusText({ percent: 80, discharging: false }, cfg, {}, 0, 0), "80% · on power")
  assert.strictEqual(M.statusText({ percent: 12, discharging: true }, cfg, {}, 840, 0), "12% · 14 min left")
  assert.strictEqual(M.statusText({ percent: 7, discharging: true }, cfg, { countdownEndsAt: 61000 }, 0, 20500), "Hibernating in 41 s")
  assert.strictEqual(M.statusText({ percent: -1, discharging: false }, cfg, {}, 0, 0), "No battery")
})

console.log("\n" + passed + " tests passed")
