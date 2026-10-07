// Generates tools/trace_actions.json — the fixed action script both tracers
// replay. Deterministic (its own tiny LCG), so regenerating it is a no-op
// unless you change the parameters below.
import { writeFileSync } from "node:fs";

const OBJECTS = [
  "basket", "washer", "detergent", "washer", "washer", "dryer", "dryer",
  "fridge", "counter", "stove", "stove", "table",
  "baby", "changingTable", "diaperDrawer", "changingTable", "bin",
  "deskChair", "monitor", "couch", "windowWall", "studyDesk", "toyBox",
];

let s = 12345;
const rnd = () => (s = (s * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff;

const actions = [];
// 1600 heartbeats of 100ms = 160s of world time, past the 150s round close.
for (let i = 0; i < 1600; i++) {
  const r = rnd();
  if (r < 0.06) {
    actions.push({ type: "click", object: OBJECTS[Math.floor(rnd() * OBJECTS.length)], dtMs: 100 });
  } else if (r < 0.075) {
    actions.push({ type: "answer", mode: rnd() < 0.5 ? "fast" : "slow", dtMs: 100 });
  } else if (r < 0.09) {
    actions.push({ type: "resolveKid", mode: rnd() < 0.5 ? "talk" : "redirect", dtMs: 100 });
  } else {
    actions.push({ type: "pause", dtMs: 100 });
  }
}
writeFileSync(new URL("./trace_actions.json", import.meta.url), JSON.stringify(actions));
console.log("wrote", actions.length, "actions");
