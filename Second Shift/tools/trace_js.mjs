// Replays tools/trace_actions.json through the ORIGINAL JavaScript rules
// (../second-shift-js/src/logic.js) and prints one line per step.
//
// tools/trace.gd prints the same lines from the GDScript port. If the two
// files are byte-identical, the port is exact — including the mulberry32
// 32-bit arithmetic, which is the one thing that can silently diverge.
import { readFileSync } from "node:fs";
import * as logic from "../../second-shift-js/src/logic.js";

const actions = JSON.parse(readFileSync(new URL("./trace_actions.json", import.meta.url), "utf8"));
const f = (n) => (n === null || n === undefined ? "-" : Number(n).toFixed(9));
const s = (v) => (v === null || v === undefined ? "-" : String(v));

let state = logic.setup(["ruth"]);
const lines = [];

for (let i = 0; i < actions.length; i++) {
  const a = actions[i];
  const v = logic.validateAction(state, "ruth", a);
  if (v.ok) state = logic.applyAction(state, "ruth", a);

  const p = state.player;
  const w = p.working ? `${p.working.key}:${p.working.stepIdx}:${f(p.working.endsAt)}` : "-";
  const pend = Object.keys(state.pending).sort().map((k) => `${k}=${f(state.pending[k])}`).join(",");
  const tasks = Object.keys(state.tasks).sort().map((k) => {
    const t = state.tasks[k];
    return t ? `${k}=${t.stepIdx}:${f(t.timerEnd)}:${t.burned ? 1 : 0}:${s(t.carry)}` : `${k}=null`;
  }).join(",");
  const q = state.queue.map((x) => x.id).join(",");
  const ph = `${state.phone.state}:${f(state.phone.nextAtT)}:${f(state.phone.untilT)}:${s(state.phone.caller)}`;

  lines.push([
    i, v.ok ? 1 : 0, f(state.t), state.rng, state.score, state.missed, state.servedCount,
    f(state.selfNeed), f(state.restoreT), f(p.x), f(p.y), p.order.mode, s(p.carrying),
    p.seated ? 1 : 0, s(p.pendingResolve), s(p.facing), w, q, pend, tasks, ph,
    s(state.lastChainKey), f(state.lastChainTime), s(state.outcome),
  ].join("|"));
}
process.stdout.write(lines.join("\n") + "\n");
