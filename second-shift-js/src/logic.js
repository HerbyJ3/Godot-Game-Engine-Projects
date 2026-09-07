/**
 * SECOND SHIFT v3 — "Her Morning": the housewife level of a marriage-themed
 * time-management game in the Delicious / Diner Dash tradition.
 *
 * Three demand families run the housewife's morning: LAUNDRY (basket → washer
 * → detergent → washer → dial → dry), COOKING (fridge → chop → stove with a
 * burn window → plate → table), and BABY-CHANGING (baby → changing table →
 * clean diaper → change → bin). The phone rings with family callers — the
 * husband, the mother-in-law, the sister — and a missed call becomes a school
 * email. Kids act up. The couch is the one station that is hers alone.
 *
 * The husband's portion ("His Evening") hangs off the same LEVELS structure
 * and lands later — the engine takes a level key at setup.
 *
 * Pure-rules contract as before: no imports, no Date.now(), no Math.random(),
 * seeded RNG in state, time moves only through client-reported `dtMs`
 * (clamped to 500ms per action). Six exports: meta, setup, validateAction,
 * applyAction, isGameOver, viewFor. See ../AGENTS.md.
 */

// ── world geometry (960 × 640 world units, 3/4-overhead flat) ─────────────

const W = 960;
const H = 640;

const ROUND_SECONDS = 150;
const TARGET_SCORE = 40;
const PLAYER_SPEED = 168; // world units per second
const ARRIVE_RADIUS = 16;
const POINTS_PER_SERVE = 2;
const CHAIN_WINDOW = 4; // s between completions that keeps a CHAIN alive
const CHAIN_BONUS = 2;
const SELF_NEED_MAX = 100;

// Passive own-needs decay. The self-care task must stay the worst value in
// the game — that deferral is the design's point, not a balance bug.
const SELF_DRAIN_PER_SEC = 4 / 150;
const SELF_SERVE_SECONDS = 5;

// Soft visual pressure only: with the longer round we let demands breathe a
// little so 6+ stay readable. Patience misses still cost.
const PHONE_RING_SECONDS = 14;
const CALL_GOODWILL_FAST = -1; // quick brush-off — ends the call, costs a point
const CALL_GOODWILL_SLOW = 1; // stays on the line, tiny warm bonus
const KID_REDIRECT_REDUCTION = 4; // redirect respawns the act-up sooner

// ── the walkway network (strictly orthogonal: up / down / left / right) ───
// Ruth never walks through furniture or walls: every click routes over this
// grid, and every edge is axis-aligned, so her path only ever runs N/S/E/W.
// Nodes sit on corridor junctions; each object maps to the access node in
// front of it. Routing is shortest-by-distance (Dijkstra), never fewest hops.

const NODES = {
  // hallway spine (x=475)
  hallTopUp:   { x: 475, y: 67 },
  hallTop:     { x: 475, y: 177 },
  hallMid:     { x: 475, y: 393 },
  hallLow:     { x: 475, y: 473 },
  hallBottom:  { x: 475, y: 600 },

  // kitchen: top appliance row (y=137), right entry (x=422), mid corridor (y=213)
  fridgeNode:  { x: 178, y: 137 },
  stoveNode:   { x: 274, y: 137 },
  sinkNode:    { x: 356, y: 137 },
  kitchenEntryN:{x: 422, y: 137 },
  kitchenEntry:{ x: 422, y: 177 },
  kitchenBR:   { x: 422, y: 213 },
  kitchenBL:   { x: 178, y: 213 },
  kBLd:        { x: 178, y: 253 },
  tableNode:   { x: 216, y: 253 },
  babyTop:     { x: 100, y: 213 },
  babyNode:    { x: 100, y: 253 },

  // office: entry corridor (y=213), desk leg (x=676)
  officeEntryN:{ x: 544, y: 177 },
  officeEntry: { x: 544, y: 213 },
  chairNode:   { x: 676, y: 213 },
  deskNode:    { x: 676, y: 180 },
  kidsDeskNode:{ x: 821, y: 213 },

  // laundry + nursery: main run (y=473), legs down to machines and nursery
  washerNode:  { x: 99,  y: 473 },
  dryerNode:   { x: 188, y: 473 },
  basketNode:  { x: 99,  y: 547 },
  nurseryT1:   { x: 330, y: 473 },
  cribNode:    { x: 330, y: 507 },
  laundryEntry:{ x: 366, y: 473 },
  nurseryT2:   { x: 415, y: 473 },
  changingNode:{ x: 415, y: 507 },
  nurseryT3:   { x: 462, y: 473 },
  binNode:     { x: 462, y: 507 },

  // living corner (y=473)
  livingEntry: { x: 573, y: 473 },
  couchNode:   { x: 699, y: 473 },
  toyboxNode:  { x: 877, y: 473 },
};

const EDGES = [
  // spine
  ["hallTopUp", "hallTop"],
  ["hallTop", "hallMid"],
  ["hallMid", "hallLow"],
  ["hallLow", "hallBottom"],
  // kitchen grid
  ["fridgeNode", "stoveNode"],
  ["stoveNode", "sinkNode"],
  ["sinkNode", "kitchenEntryN"],
  ["kitchenEntryN", "kitchenEntry"],
  ["kitchenEntry", "kitchenBR"],
  ["kitchenEntry", "hallTop"],
  ["kitchenBR", "kitchenBL"],
  ["kitchenBL", "kBLd"],
  ["kBLd", "tableNode"],
  ["kitchenBL", "fridgeNode"],
  ["kitchenBL", "babyTop"],
  ["babyTop", "babyNode"],
  // office grid
  ["officeEntryN", "officeEntry"],
  ["officeEntry", "chairNode"],
  ["chairNode", "deskNode"],
  ["chairNode", "kidsDeskNode"],
  ["officeEntryN", "hallTop"],
  // laundry + nursery grid
  ["washerNode", "dryerNode"],
  ["washerNode", "basketNode"],
  ["dryerNode", "nurseryT1"],
  ["nurseryT1", "cribNode"],
  ["nurseryT1", "laundryEntry"],
  ["laundryEntry", "nurseryT2"],
  ["nurseryT2", "changingNode"],
  ["nurseryT2", "nurseryT3"],
  ["nurseryT3", "binNode"],
  ["nurseryT3", "hallLow"],
  // living grid
  ["hallLow", "livingEntry"],
  ["livingEntry", "couchNode"],
  ["couchNode", "toyboxNode"],
];

// Which access node each clickable object is used from, and the direction
// she turns on arrival (from the anchor toward the object's center).
const OBJECT_NODE = {
  fridge: "fridgeNode",
  counter: "sinkNode",
  stove: "stoveNode",
  cabinet: "stoveNode",
  kettle: "stoveNode",
  formula: "tableNode",
  table: "tableNode",
  baby: "babyNode",
  basket: "basketNode",
  washer: "washerNode",
  dryer: "dryerNode",
  detergent: "washerNode", // the shelf hangs above the washer — she reaches up from in front of it
  deskChair: "chairNode",
  monitor: "deskNode",
  couch: "couchNode",
  windowWall: "babyTop",
  toyBox: "toyboxNode",
  studyDesk: "kidsDeskNode",
  crib: "cribNode",
  changingTable: "changingNode",
  diaperDrawer: "changingNode",
  bin: "binNode",
};

const OBJECT_FACING = {
  fridge: "left",
  counter: "up",
  stove: "up",
  cabinet: "up",
  kettle: "up",
  formula: "right",
  table: "right",
  baby: "right",
  basket: "left",
  washer: "up",
  dryer: "up",
  detergent: "up",
  deskChair: "up",
  monitor: "up",
  couch: "up",
  windowWall: "left",
  toyBox: "up",
  studyDesk: "down",
  crib: "down",
  changingTable: "down",
  diaperDrawer: "down",
  bin: "down",
};

function nearestNodeId(pos) {
  let best = null;
  let bestD = Infinity;
  for (const [id, n] of Object.entries(NODES)) {
    const d = Math.hypot(pos.x - n.x, pos.y - n.y);
    if (d < bestD) { bestD = d; best = id; }
  }
  return best;
}

// Dijkstra — shortest path BY DISTANCE over the orthogonal grid.
function dijkstra(fromId, toId) {
  if (fromId === toId) return [fromId];
  const dist = { [fromId]: 0 };
  const prev = { [fromId]: null };
  const open = new Set(Object.keys(NODES));
  while (open.size) {
    let cur = null;
    let best = Infinity;
    for (const id of open) {
      const d = dist[id] ?? Infinity;
      if (d < best) { best = d; cur = id; }
    }
    if (cur == null || best === Infinity) break;
    open.delete(cur);
    if (cur === toId) break;
    for (const [a, b] of EDGES) {
      let nxt = null;
      if (a === cur) nxt = b;
      else if (b === cur) nxt = a;
      if (!nxt || !open.has(nxt)) continue;
      const w = Math.hypot(NODES[a].x - NODES[b].x, NODES[a].y - NODES[b].y);
      const alt = best + w;
      if (alt < (dist[nxt] ?? Infinity)) {
        dist[nxt] = alt;
        prev[nxt] = cur;
      }
    }
  }
  if (!(toId in prev)) return [fromId];
  const path = [toId];
  let p = prev[toId];
  while (p) { path.unshift(p); p = prev[p]; }
  return path;
}

function pathLengthIds(ids) {
  let len = 0;
  for (let i = 1; i < ids.length; i++) {
    len += Math.hypot(NODES[ids[i]].x - NODES[ids[i - 1]].x, NODES[ids[i]].y - NODES[ids[i - 1]].y);
  }
  return len;
}

// The corridor edge nearest to a position, with the projection point onto it.
// Entering the graph via this edge can never cross a wall or footprint: the
// edge IS walkable corridor, and she is standing next to it.
function nearestEdge(pos) {
  let best = null;
  for (const [aId, bId] of EDGES) {
    const a = NODES[aId];
    const b = NODES[bId];
    const abx = b.x - a.x;
    const aby = b.y - a.y;
    const len2 = abx * abx + aby * aby || 1;
    let u = ((pos.x - a.x) * abx + (pos.y - a.y) * aby) / len2;
    u = Math.max(0, Math.min(1, u));
    const px = a.x + abx * u;
    const py = a.y + aby * u;
    const d = Math.hypot(pos.x - px, pos.y - py);
    if (!best || d < best.d) best = { aId, bId, px, py, d };
  }
  return best;
}

// ── blocked footprints: the FLOOR each piece of furniture occupies ─────────
// Base-of-object rectangles (where it meets the floor), not drawn height —
// a tall fridge blocks only the floor under it. Ruth's collision is a small
// ellipse at her FEET; movement slides along footprint edges, never enters.

const FOOTPRINTS = {
  // kitchen
  fridge:    { x0: 125, y0: 95,  x1: 174, y1: 158 },
  stove:     { x0: 258, y0: 95,  x1: 316, y1: 125 },
  sink:      { x0: 330, y0: 90,  x1: 410, y1: 125 },
  table:     { x0: 230, y0: 228, x1: 300, y1: 278 },
  windowWall:{ x0: 58,  y0: 150, x1: 125, y1: 190 },
  babyChair: { x0: 112, y0: 235, x1: 148, y1: 258 },
  // laundry + nursery
  washer:    { x0: 77,  y0: 405, x1: 147, y1: 466 },
  dryer:     { x0: 155, y0: 405, x1: 225, y1: 466 },
  detergent: { x0: 90,  y0: 345, x1: 135, y1: 370 },
  basket:    { x0: 47,  y0: 520, x1: 95,  y1: 575 },
  crib:      { x0: 296, y0: 523, x1: 364, y1: 567 },
  changing:  { x0: 385, y0: 527, x1: 445, y1: 563 },
  bin:       { x0: 448, y0: 523, x1: 476, y1: 567 },
  // office
  desk:      { x0: 590, y0: 100, x1: 755, y1: 165 },
  deskChair: { x0: 655, y0: 150, x1: 697, y1: 170 },
  studyDesk: { x0: 775, y0: 218, x1: 848, y1: 260 },
  // living
  couch:     { x0: 615, y0: 370, x1: 775, y1: 460 },
  toyBox:    { x0: 845, y0: 400, x1: 910, y1: 466 },
};

const FOOT_RX = 4; // feet-point pad — she may overlap drawn tops, never bases
const FOOT_RY = 3;

function insideFootprint(x, y) {
  for (const f of Object.values(FOOTPRINTS)) {
    if (x + FOOT_RX > f.x0 && x - FOOT_RX < f.x1 && y + FOOT_RY > f.y0 && y - FOOT_RY < f.y1) {
      return f;
    }
  }
  return null;
}

// Move with slide: try the full step; if blocked, keep the axis component
// that stays on walkable floor so she slides along the edge instead of
// stopping dead.
function slideMove(px, py, nx, ny) {
  if (!insideFootprint(nx, ny)) return { x: nx, y: ny };
  if (!insideFootprint(nx, py)) return { x: nx, y: py }; // slide horizontally
  if (!insideFootprint(px, ny)) return { x: px, y: ny }; // slide vertically
  return { x: px, y: py }; // fully blocked — stay
}
// hitW/hitH hold the 44×44 minimum; the visible art can be smaller. `station`
// groups the clickable into a room. `active: false` objects render but refuse
// with "not here".

const OBJECTS = {
  // KITCHEN (top-left of the painted home)
  fridge:   { id: "fridge",   station: "kitchen", x: 153, y: 108, hitW: 56, hitH: 98, label: "Fridge" },
  counter:  { id: "counter",  station: "kitchen", x: 369, y: 87,  hitW: 44, hitH: 48, label: "Sink" },
  stove:    { id: "stove",    station: "kitchen", x: 287, y: 89,  hitW: 58, hitH: 60, label: "Stove" },
  cabinet:  { id: "cabinet",  station: "kitchen", x: 277, y: 36,  hitW: 80, hitH: 42, label: "Cabinet" },
  formula:  { id: "formula",  station: "kitchen", x: 265, y: 253, hitW: 44, hitH: 44, label: "Kitchen table" },
  kettle:   { id: "kettle",   station: "kitchen", x: 293, y: 80,  hitW: 34, hitH: 36, label: "Kettle" },
  table:    { id: "table",    station: "kitchen", x: 265, y: 253, hitW: 90, hitH: 62, label: "Dining table" },
  baby:     { id: "baby",     station: "kitchen", x: 128, y: 223, hitW: 46, hitH: 62, label: "Baby" },

  // LAUNDRY (bottom-left)
  basket:    { id: "basket",    station: "laundry", x: 84,  y: 547, hitW: 74, hitH: 56, label: "Laundry basket" },
  washer:    { id: "washer",    station: "laundry", x: 112, y: 435, hitW: 68, hitH: 74, label: "Washer" },
  dryer:     { id: "dryer",     station: "laundry", x: 192, y: 435, hitW: 68, hitH: 74, label: "Dryer" },
  detergent: { id: "detergent", station: "laundry", x: 112, y: 360, hitW: 44, hitH: 44, label: "Detergent" },

  // OFFICE (top-right)
  deskChair: { id: "deskChair", station: "office", x: 666, y: 172, hitW: 44, hitH: 58, label: "Desk chair" },
  monitor:   { id: "monitor",   station: "office", x: 649, y: 95,  hitW: 44, hitH: 42, label: "Monitor" },

  // MY OWN NEEDS (bottom-right)
  couch: { id: "couch", station: "armchair", x: 695, y: 414, hitW: 160, hitH: 90, label: "Couch" },

  // NURSERY CORNER (bottom of the laundry room — drawn by the client overlay)
  crib:          { id: "crib",          station: "laundry", x: 330, y: 545, hitW: 80, hitH: 60, label: "Crib" },
  changingTable: { id: "changingTable", station: "laundry", x: 415, y: 545, hitW: 70, hitH: 56, label: "Changing table" },
  diaperDrawer:  { id: "diaperDrawer",  station: "laundry", x: 415, y: 500, hitW: 44, hitH: 44, label: "Diaper drawer" },
  bin:           { id: "bin",           station: "laundry", x: 462, y: 545, hitW: 44, hitH: 48, label: "Diaper pail" },

  // KIDS — anchor posts they act out next to
  windowWall: { id: "windowWall", station: "kitchen", x: 91,  y: 151, hitW: 66, hitH: 80, label: "Window wall" },
  toyBox:     { id: "toyBox",     station: "armchair",x: 877, y: 434, hitW: 64, hitH: 64, label: "Toy box" },
  studyDesk:  { id: "studyDesk",  station: "office",  x: 810, y: 233, hitW: 80, hitH: 60, label: "Kids' desk" },
};

// Rooms the client knows how to draw; clickable object count > walls.
const STATIONS = {
  kitchen:  { key: "kitchen",  room: { x: 40,  y: 60,  w: 440, h: 230 }, color: "#E0A95A" },
  laundry:  { key: "laundry",  room: { x: 40,  y: 360, w: 440, h: 230 }, color: "#7FA6C9" },
  office:   { key: "office",   room: { x: 480, y: 60,  w: 440, h: 230 }, color: "#C9A24D" },
  armchair: { key: "armchair", room: { x: 480, y: 360, w: 440, h: 230 }, color: "#D08C96" },
};

// Kid act-up anchor posts, in the order they get picked by the seeded RNG.
const KID_SPOTS = ["windowWall", "studyDesk", "toyBox"];

// ── TASK chains — all multi-step demands live here as data ────────────────
// steps[i]:   { target, anim, dur, carryIn?, carryOut? }
// waitAfter[i]: { seconds, resumeBubble? } — a server-side timer after step i
//               resolves; nothing for the player until the bubble pops.
// interruptible: leaving mid-chain keeps progress on a half-filled task.
// busyLock holds her at the engaged object for the step's duration — walking
// away is free unless interruptible=false (the office email).

const TASKS = {
  laundry: {
    key: "laundry",
    station: "laundry",
    label: "Laundry",
    bubble: "The basket is full again",
    spawn: [4, 7],
    patience: 95,
    decay: 26,
    penalty: 9,
    points: 8,
    icon: "laundry",
    interruptible: true,
    steps: [
      { target: "basket",    anim: "grab",  dur: 0.8,  carryOut: "clothes" },
      { target: "washer",    anim: "pour",  dur: 1.0 },
      { target: "detergent", anim: "grab",  dur: 0.7,  carryOut: "detergent" },
      { target: "washer",    anim: "pour",  dur: 1.0 },
      { target: "washer",    anim: "press", dur: 0.6 },
      null, // timer 1 — the machine runs
      { target: "washer",    anim: "grab",  dur: 0.9,  carryOut: "wet" },
      { target: "dryer",     anim: "pour",  dur: 0.9 },
      { target: "dryer",     anim: "press", dur: 0.6 },
      null, // timer 2
      { target: "dryer",     anim: "grab",  dur: 0.8 },
    ],
    waitAfter: { 4: { seconds: 16, bubble: "washer dings" }, 8: { seconds: 14, bubble: "dryer dings" } },
    stepScore: [0,0,0,0,1, 0,0,0,1, 0, 6], // completion lands on the last
  },

  cooking: {
    key: "cooking",
    station: "kitchen",
    label: "Cooking",
    bubble: "Dinner won't make itself",
    spawn: [2, 4],
    patience: 65,
    decay: 22,
    penalty: 8,
    points: 10,
    icon: "cooking",
    interruptible: true,
    steps: [
      { target: "fridge",  anim: "grab",  dur: 0.8, carryOut: "ingredients" },
      { target: "counter", anim: "chop",  dur: 1.4 },
      { target: "stove",   anim: "cook",  dur: 1.0 },
      null, // cook timer — burn window starts
      { target: "stove",   anim: "plate", dur: 0.9, carryOut: "plated" },
      { target: "table",   anim: "serve", dur: 0.7 },
    ],
    waitAfter: { 2: { seconds: 9, bubble: "dinner is ready", burnAfter: 8 } },
    stepScore: [0,0,1, 0, 1, 8],
  },

  diaper: {
    key: "diaper",
    station: "laundry",
    label: "Diaper change",
    bubble: "The baby needs changing",
    spawn: [18, 30],
    patience: 70,
    decay: 30,
    penalty: 10,
    points: 9,
    icon: "diaper",
    interruptible: true,
    steps: [
      { target: "baby",          anim: "grab",    dur: 1.0, carryOut: "baby" },
      { target: "changingTable", anim: "lay",     dur: 0.8 },
      { target: "diaperDrawer",  anim: "grab",    dur: 0.7, carryOut: "diaper" },
      { target: "changingTable", anim: "change",  dur: 1.6 },
      { target: "bin",           anim: "dispose", dur: 0.7 },
    ],
    stepScore: [0,1,1,5,2],
  },

  email: {
    key: "email",
    station: "office",
    label: "School email",
    bubble: "School needs a reply",
    spawn: [null, null], // arrives as a phone escalation / scheduled notification
    patience: 90,
    decay: 45,
    penalty: 6,
    points: 8,
    icon: "email",
    interruptible: false,
    steps: [
      { target: "deskChair", anim: "sit",   dur: 0.7 },
      { target: "monitor",   anim: "wake",  dur: 0.9 },
      { target: "monitor",   anim: "type",  dur: 3.6 },
      { target: "monitor",   anim: "send",  dur: 0.5 },
    ],
    stepScore: [0,1,1,6],
  },

  kids: {
    key: "kids",
    station: null, // anchored on a KID_SPOT instance
    label: "The kids",
    bubble: "Someone's misbehaving",
    spawn: [30, 46],
    patience: 75,
    decay: 34,
    penalty: 6,
    points: 6,
    icon: "kid",
    interruptible: true,
    // Only step 0 is engine-walked; the resolution is chosen face-to-face.
    steps: [{ target: null, anim: "kneel", dur: 0.8 }],
  },

  self: {
    key: "self",
    station: "armchair",
    label: "A minute of her own",
    bubble: "Her own needs",
    passivelyPresent: true, // always available, lowest value, highest patience
    patience: 999,
    points: 2,
    icon: "self",
    interruptible: true,
    steps: [{ target: "couch", anim: "sit", dur: SELF_SERVE_SECONDS }],
  },
};

// HUD demand-pool order: which task types can be live at once.
const DEMAND_ORDER = ["cooking", "laundry", "diaper", "email", "kids"];

// ── seeded RNG (mulberry32) ───────────────────────────────────────────────

function rngNext(rng) {
  const seed = (rng + 0x6d2b79f5) | 0;
  let t = seed;
  t = Math.imul(t ^ (t >>> 15), t | 1);
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
  const roll = ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  return { roll, seed };
}

function rollRange(rng, min, max) {
  const { roll, seed } = rngNext(rng);
  return { value: min + (max - min) * roll, seed };
}

function rollInt(rng, lo, hi) {
  const { roll, seed } = rngNext(rng);
  return { value: lo + Math.floor(roll * (hi - lo + 1)), seed };
}

// ── small helpers ─────────────────────────────────────────────────────────

function clamp(v, lo, hi) {
  return v < lo ? lo : v > hi ? hi : v;
}

function dist(a, b) {
  const dx = a.x - b.x;
  const dy = a.y - b.y;
  return Math.hypot(dx, dy);
}

function emptyOrder() {
  return { mode: "idle", to: null, path: [] };
}

function pushHistory(state, entry) {
  const base = state.history || [];
  const history = entry ? base.concat([entry]) : base.slice();
  return history.length > 24 ? history.slice(history.length - 24) : history;
}

function clonePlayer(p) {
  return {
    x: p.x,
    y: p.y,
    order: p.order
      ? {
          mode: p.order.mode,
          to: p.order.to ? { ...p.order.to } : null,
          path: p.order.path ? p.order.path.map((pt) => ({ ...pt })) : [],
        }
      : emptyOrder(),
    queuedTarget: p.queuedTarget || null,
    anim: p.anim || null,
    busyUntil: p.busyUntil || 0,
    working: p.working ? { ...p.working } : null,
    facing: p.facing || "down",
    carrying: p.carrying || null,
    seated: p.seated || false,
    pendingResolve: p.pendingResolve || null, // object id to resolve on arrival
  };
}

function cloneTaskState(ts) {
  if (!ts) return null;
  return {
    key: ts.key,
    queueId: ts.queueId || null,
    stepIdx: ts.stepIdx,
    carry: ts.carry || null,
    timerEnd: ts.timerEnd ?? null,
    burnUntil: ts.burnUntil ?? null,
    burned: !!ts.burned,
    kidSpot: ts.kidSpot || null,
    draft: ts.draft != null ? ts.draft : null,
  };
}

// (arrivalPoint removed — access nodes on the walkway network replaced it)

// Timed demand spawn windows live on the type so a task starts "not yet here"
// and ticks in. Self-care never spawns — it is always there if she sits.
function initialPending(rngState) {
  let rng = rngState;
  const pending = {};
  for (const key of ["cooking", "laundry"]) {
    const r = rollRange(rng, TASKS[key].spawn[0], TASKS[key].spawn[1]);
    rng = r.seed;
    pending[key] = r.value;
  }
  for (const key of ["diaper", "kids"]) {
    const r = rollRange(rng, TASKS[key].spawn[0], TASKS[key].spawn[1]);
    rng = r.seed;
    pending[key] = r.value;
  }
  return { pending, rng };
}

// ── queue management ──────────────────────────────────────────────────────

function enqueue(state, key, t) {
  const cfg = TASKS[key];
  const item = {
    id: `${key}-${Math.round(t * 1000)}`,
    key,
    station: cfg.station,
    bornT: t,
    expiresT: t + cfg.patience,
    penalty: cfg.penalty,
  };
  const queue = state.queue.concat([item]);
  const tasks = { ...state.tasks, [key]: { key, queueId: item.id, stepIdx: 0, carry: null, timerEnd: null, burned: false } };
  if (key === "kids") {
    const pick = rollInt(state.rng, 0, KID_SPOTS.length - 1);
    return {
      ...state,
      queue,
      tasks: { ...tasks, kids: { ...tasks.kids, kidSpot: KID_SPOTS[pick.value] } },
      rng: pick.seed,
    };
  }
  return { ...state, queue, tasks };
}

function scheduleNext(state, key, t) {
  let rng = state.rng;
  const r = rollRange(rng, 0.85, 1.15);
  rng = r.seed;
  // A completed "kids" demand that was only redirected acts up sooner.
  const mult = state.kidsQuickReturn && key === "kids" ? 0.45 : 1;
  const nextAt = t + TASKS[key].decay * r.value * mult;
  return { ...state, rng, pending: { ...state.pending, [key]: nextAt } };
}

// ── the world tick ────────────────────────────────────────────────────────

function tick(state, dtSec) {
  const t = state.t + dtSec;
  let rng = state.rng;
  let score = state.score;
  let missed = state.missed;
  let servedCount = state.servedCount;
  let lastChainTime = state.lastChainTime;
  let lastChainKey = state.lastChainKey;
  let selfNeed = state.selfNeed;
  const restoreT = Math.max(0, state.restoreT - dtSec);
  let player = clonePlayer(state.player);
  let queue = state.queue.map((q) => ({ ...q }));
  let pending = { ...state.pending };
  let tasks = {};
  for (const k of Object.keys(state.tasks)) tasks[k] = cloneTaskState(state.tasks[k]);
  let phone = { ...state.phone };
  let kidsQuickReturn = state.kidsQuickReturn;
  const history = state.history ? state.history.slice() : [];
  const events = state.events ? state.events.slice() : []; // transient, view-only

  // ── phone: rings on its own cycle and is what wakes the email task.
  if (phone.state === "ringing" && t >= phone.untilT) {
    // Missed call — the school rings back, angrier, as the email demand.
    phone = { state: "idle", nextAtT: t + 45 + rngNext(rng).roll * 20, untilT: 0, caller: null };
    rng = (rng + 1) | 0;
    if (pending.email == null && !tasks.email) {
      enqueueResult: {
        const next = enqueue({ ...state, queue, pending, tasks, rng }, "email", t);
        queue = next.queue; pending = next.pending; tasks = next.tasks; rng = next.rng;
      }
      history.push({ tSec: Math.round(t), type: "phone", text: "missed call — school writes instead" });
    }
  } else if (phone.state === "idle" && t >= phone.nextAtT) {
    // Marriage-theme callers: the husband checks in, the mother-in-law has
    // opinions, the sister needs a favor.
    const callers = ["husband", "mother-in-law", "sister"];
    const pick = rollInt(rng, 0, callers.length - 1);
    rng = pick.seed;
    phone = { state: "ringing", untilT: t + PHONE_RING_SECONDS, caller: callers[pick.value], nextAtT: 0 };
    events.push({ kind: "phoneRing", at: t });
  }

  // ── passive SELF bar drain (slows right after she actually sat).
  const selfRate = restoreT > 0 ? SELF_DRAIN_PER_SEC * 0.6 : SELF_DRAIN_PER_SEC;
  const seatedSelf = player.seated && player.anim && player.anim.task === "self";
  if (!seatedSelf) selfNeed = Math.max(0, selfNeed - selfRate * dtSec);

  // ── spawns.
  for (const key of DEMAND_ORDER) {
    if (key === "email") continue; // email only arrives off a missed call
    const already = queue.some((q) => q.key === key) || !!tasks[key];
    if (!already && pending[key] != null && t >= pending[key]) {
      const next = enqueue({ ...state, queue, pending, tasks, rng }, key, t);
      queue = next.queue; pending = next.pending; tasks = next.tasks; rng = next.rng;
      events.push({ kind: "spawn", key, at: t });
    }
  }

  // ── patience drain.
  const kept = [];
  for (const q of queue) {
    if (t >= q.expiresT) {
      missed += 1;
      score = Math.max(0, score - q.penalty);
      history.push({ tSec: Math.round(t), type: q.key, text: `${TASKS[q.key].label.toLowerCase()} slipped –${q.penalty}` });
      events.push({ kind: "fail", key: q.key, at: t, points: q.penalty });
      // kids' mess stays as a follow-up cleanup
      if (q.key === "kids") kidsQuickReturn = true;
      tasks[q.key] = null;
      const sched = scheduleNext({ ...state, rng, pending, kidsQuickReturn }, q.key, t);
      rng = sched.rng; pending = sched.pending;
      continue;
    }
    kept.push(q);
  }
  queue = kept;

  // ── movement along the current route, waypoint by waypoint, sliding along
  // any blocked footprint edge instead of entering it.
  const speed = PLAYER_SPEED;
  if (player.order.mode === "walk" && player.order.to) {
    const dx = player.order.to.x - player.x;
    const dy = player.order.to.y - player.y;
    const d = Math.hypot(dx, dy);
    const step = speed * dtSec;
    if (d <= Math.max(step, ARRIVE_RADIUS * 0.5)) {
      const snapped = slideMove(player.x, player.y, player.order.to.x, player.order.to.y);
      player.x = snapped.x;
      player.y = snapped.y;
      // Next waypoint, or done.
      const rest = player.order.path || [];
      if (rest.length > 0) {
        player.order = { mode: "walk", to: { ...rest[0] }, path: rest.slice(1) };
      } else {
        player.order = emptyOrder();
      }
    } else if (d > 0.0001) {
      const nx = clamp(player.x + (dx / d) * step, 20, W - 20);
      const ny = clamp(player.y + (dy / d) * step, 20, H - 20);
      const moved = slideMove(player.x, player.y, nx, ny);
      player.x = moved.x;
      player.y = moved.y;
    }
  }

  // ── anim housekeeping: a display-only anim (kneel etc.) ends on its own.
  // A WORKING anim is cleared by the commit, never here.
  if (player.anim && !player.working && player.busyUntil > 0 && t >= player.busyUntil) {
    player.anim = null;
    player.busyUntil = 0;
  }

  // ── wait-timers (washer runs, dinner cooks, dry cycle). The self-sit has
  // its own completion path below and must not be eaten here.
  for (const key of Object.keys(tasks)) {
    if (key === "self") continue;
    const ts = tasks[key];
    if (!ts || ts.timerEnd == null) continue;
    const cfg = TASKS[key];
    const wait = cfg.waitAfter && cfg.waitAfter[ts.stepIdx - 1];
    if (!wait) { ts.timerEnd = null; continue; }
    if (t >= ts.timerEnd) {
      // The bubble that tells her the machine dinged; the timer slot is
      // consumed and the chain advances to the next clickable step.
      events.push({ kind: "ding", key, at: t });
      ts.stepIdx += 1;
      // Burning: the stove gives a short grace window before the pan chars.
      if (wait.burnAfter && key === "cooking") {
        ts.burnUntil = t + wait.burnAfter;
      }
      ts.timerEnd = null;
    }
  }

  return {
    ...state,
    t,
    rng,
    score,
    missed,
    servedCount,
    queue,
    pending,
    tasks,
    player,
    selfNeed,
    restoreT,
    phone,
    lastChainTime,
    lastChainKey,
    kidsQuickReturn,
    history: history.slice(-24),
    events: events.slice(-24),
  };
}

// ── chain progression ─────────────────────────────────────────────────────

// The heart of v2. A click intent targets an OBJECT; once she is in range we
// ask the task engine whether this object is the next expected step. Correct
// click → the step runs (an animation with a duration), maybe a timer arms,
// maybe points tick. Wrong click → a soft bounce, no penalty.

function tryAdvanceStep(state, queueItem, taskState, t) {
  const cfg = TASKS[taskState.key];
  const step = cfg.steps[taskState.stepIdx];
  if (step == null) return { state, advanced: false, reason: "waiting" }; // mid-timer
  return { state, advanced: false };
}

// Resolve a click at an object — she has already arrived; decide what the
// click means against live tasks. Returns { state, acted, bounce?, ding? }.
function resolveClick(state, objectId) {
  const obj = OBJECTS[objectId];
  if (!obj) return { state, acted: false };
  let next = state;
  let bounce = null;

  if (objectId === "couch") {
    // The couch is always hers — she can sit whenever she isn't already there.
    // The engine still gates the restore on the bar being meaningfully drained
    // so clicking it mid-full does nothing.
    if (!next.player.seated && !next.tasks.self && next.selfNeed < SELF_NEED_MAX) {
      const player = clonePlayer(next.player);
      player.seated = true;
      player.anim = { task: "self", kind: "sit", startedAt: next.t };
      player.busyUntil = next.t + SELF_SERVE_SECONDS;
      next = {
        ...next,
        player,
        tasks: { ...next.tasks, self: { key: "self", stepIdx: 0, carry: null, timerEnd: next.t + SELF_SERVE_SECONDS, queueId: null, kidSpot: null, burned: false, draft: null } },
      };
    }
    return { state: next, acted: true };
  }

  // Live kid acting-up at this spot?
  if (next.tasks.kids && next.tasks.kids.kidSpot === objectId && next.queue.some((q) => q.key === "kids")) {
    const player = clonePlayer(next.player);
    player.seated = false;
    player.anim = { task: "kids", kind: "kneel", startedAt: next.t };
    player.busyUntil = next.t + 0.7;
    return { state: { ...next, player }, acted: true, kidChoice: true };
  }

  // Live chainable task routed to this object?
  let hit = null;
  for (const key of Object.keys(next.tasks)) {
    const ts = next.tasks[key];
    if (!ts || key === "self" || key === "kids") continue;
    const qi = next.queue.find((q) => q.key === key);
    if (!qi) continue;
    const cfg = TASKS[key];
    const stepDef = cfg.steps[ts.stepIdx];
    if (!stepDef) continue; // wait slot — nothing clickable until the timer dings
    if (stepDef.target === objectId) { hit = { key, ts, cfg, qi, stepDef }; break; }
  }

  if (hit) {
    const { key, ts, stepDef } = hit;
    // Email is uninterruptible: once she's seated, clicks elsewhere are bounces
    // unless she's mid-step at this task already (draft loss on leave).
    if (key !== "email" && next.player.seated && next.tasks.email) {
      // sitting at the desk working on an email — other clicks are bounced
      bounce = { x: obj.x, y: obj.y };
      return { state: next, acted: false, bounce };
    }
    // ARRIVING → WORKING: she has stopped at the anchor, turns to face the
    // object, and the step runs for its full duration. Nothing commits until
    // the work FINISHES (commitWork in applyAction) — walking away abandons
    // the step with no progress and no points.
    const player = clonePlayer(next.player);
    player.anim = { task: key, kind: stepDef.anim, startedAt: next.t };
    player.busyUntil = next.t + stepDef.dur;
    player.facing = OBJECT_FACING[objectId] || "down";
    player.working = { key, stepIdx: ts.stepIdx, objectId, endsAt: next.t + stepDef.dur };
    return { state: { ...next, player }, acted: true, ding: { key, stepIdx: ts.stepIdx, completes: false } };
  }

  bounce = { x: obj.x, y: obj.y };
  return { state: next, acted: false, bounce };
}

// The work FINISHED: commit the step — advance the chain, award points, arm
// wait timers, complete the task. Runs from applyAction when t passes
// working.endsAt and she is still standing at the anchor.
function commitWork(state) {
  const working = state.player.working;
  if (!working) return state;
  const { key, stepIdx, objectId } = working;
  const ts = state.tasks[key];
  const cfg = TASKS[key];
  // The task may have expired mid-work, or the state may have moved on.
  if (!ts || !cfg || ts.stepIdx !== stepIdx) {
    const player = clonePlayer(state.player);
    player.working = null;
    player.anim = null;
    player.busyUntil = 0;
    return { ...state, player };
  }
  const stepDef = cfg.steps[stepIdx];
  let next = state;

  const player = clonePlayer(next.player);
  player.working = null;
  player.anim = null;
  player.busyUntil = 0;
  if (stepDef.carryOut) player.carrying = stepDef.carryOut;
  if (key === "email" && stepDef.anim === "sit") player.seated = true;
  if (key === "email" && stepDef.anim === "send") player.seated = false;

  const tsNext = cloneTaskState(ts);
  tsNext.stepIdx = ts.stepIdx + 1;
  tsNext.carry = stepDef.carryOut || ts.carry || null;
  // Arm the wait timer tied to THIS step (the one that just finished).
  const wait = cfg.waitAfter && cfg.waitAfter[ts.stepIdx];
  tsNext.timerEnd = wait ? next.t + wait.seconds : null;

  // Burning: plating past burnUntil halves the finishing points.
  if (key === "cooking" && stepDef.anim === "plate" && ts.burnUntil != null && next.t >= ts.burnUntil) {
    tsNext.burned = true;
  }

  let score = next.score;
  let servedCount = next.servedCount;
  let lastChainKey = next.lastChainKey;
  let lastChainTime = next.lastChainTime;
  let history = next.history;
  let gained = cfg.stepScore[ts.stepIdx] || 0;
  if (tsNext.burned && stepDef.anim === "serve") gained = 4; // burned finish
  const completes = tsNext.stepIdx >= cfg.steps.length;
  if (gained > 0) {
    let award = gained;
    if (completes) {
      const chainOkay = lastChainKey === key && next.t - lastChainTime <= CHAIN_WINDOW;
      award = gained + (chainOkay ? CHAIN_BONUS : 0);
      lastChainKey = key;
      lastChainTime = next.t;
      servedCount += 1;
    }
    score = next.score + award;
    history = pushHistory({ ...next, history }, { tSec: Math.round(next.t), type: key, text: `+${award} ${cfg.label}` });
    if (completes) history = pushHistory({ ...next, history }, { tSec: Math.round(next.t), type: key, text: `${cfg.label.toLowerCase()} — done` });
  }

  let queue = next.queue;
  let pending = next.pending;
  let rng = next.rng;
  let kidsQuickReturn = next.kidsQuickReturn;
  let tasks = { ...next.tasks, [key]: tsNext };

  if (completes) {
    queue = queue.filter((q) => q.key !== key);
    tasks[key] = null;
    player.carrying = null;
    const sched = scheduleNext({ ...next, rng, pending, kidsQuickReturn }, key, next.t);
    rng = sched.rng; pending = sched.pending;
  }
  void objectId;

  return {
    ...next,
    player,
    tasks,
    queue,
    pending,
    rng,
    score,
    servedCount,
    lastChainKey,
    lastChainTime,
    kidsQuickReturn,
    history,
  };
}

// (resumeTargetFor / resumeStepFor removed — wait slots live in TASKS data)

function setWalk(state, objectId) {
  const obj = OBJECTS[objectId];
  if (!obj) return state;
  const nodeId = OBJECT_NODE[objectId];
  const node = nodeId ? NODES[nodeId] : null;
  if (!node) return state;

  // Route: she enters the graph through the corridor edge she is standing on
  // (projection onto it — a tiny perpendicular step, never through a wall),
  // then leaves it through whichever endpoint gives the shorter TOTAL walk to
  // the target. That also kills the back-step: she exits the edge on the side
  // that heads toward the destination.
  const player = clonePlayer(state.player);
  const edge = nearestEdge(player);
  const viaA = { id: edge.aId };
  const viaB = { id: edge.bId };
  for (const via of [viaA, viaB]) {
    via.ids = dijkstra(via.id, nodeId);
    const n = NODES[via.id];
    via.total = Math.hypot(edge.px - n.x, edge.py - n.y) + pathLengthIds(via.ids);
  }
  const best = viaA.total <= viaB.total ? viaA : viaB;

  const pts = [];
  // Perpendicular hop onto the corridor (skip when she's already on it).
  if (edge.d > 6) pts.push({ x: edge.px, y: edge.py });
  // Then along the edge to the chosen endpoint (skip a null hop).
  const entryNode = NODES[best.id];
  if (Math.hypot(edge.px - entryNode.x, edge.py - entryNode.y) > 6) {
    pts.push({ x: entryNode.x, y: entryNode.y });
  }
  for (let i = 1; i < best.ids.length; i++) {
    const n = NODES[best.ids[i]];
    pts.push({ x: n.x, y: n.y });
  }
  if (!pts.length) pts.push({ x: node.x, y: node.y });

  // Walking drops any seat lock; a mid-flight work step is ABANDONED — no
  // progress, no points. The clicked object becomes pendingResolve.
  player.seated = false;
  player.anim = null;
  player.busyUntil = 0;
  player.working = null;
  player.order = { mode: "walk", to: pts[0], path: pts.slice(1) };
  player.pendingResolve = objectId || null;
  return { ...state, player };
}

// ── the contract ──────────────────────────────────────────────────────────

export const meta = {
  game: "Second Shift",
  minPlayers: 1,
  maxPlayers: 1,
};

export function setup(players) {
  const raw = String(players[0] || "ruth");
  let seed = 7;
  for (let i = 0; i < raw.length; i++) seed = (seed * 31 + raw.charCodeAt(i)) | 0;
  seed = Math.abs(seed) || 1;

  let rng = seed;
  const phoneFirst = rollRange(rng, 28, 42);
  rng = phoneFirst.seed;
  const pen = initialPending(rng);
  rng = pen.rng;

  return {
    t: 0,
    roundSeconds: ROUND_SECONDS,
    target: TARGET_SCORE,
    score: 0,
    servedCount: 0,
    missed: 0,
    rng,
    // The marriage frame: this level is the housewife's morning. The
    // husband's evening hangs off the same engine and ships next.
    level: { key: "wife", name: "Her Morning", partner: "His Evening" },
    queue: [],
    pending: pen.pending, // email added on a missed call; self never
    tasks: {},            // key -> task state
    player: {
      x: 480,
      y: 320,
      order: emptyOrder(),
      queuedTarget: null,
      anim: null,
      busyUntil: 0,
      carrying: null,
      seated: false,
    },
    selfNeed: SELF_NEED_MAX,
    restoreT: 0,
    phone: { state: "idle", nextAtT: phoneFirst.value, untilT: 0, caller: null },
    lastChainKey: null,
    lastChainTime: -999,
    kidsQuickReturn: false,
    history: [],
    events: [],
    outcome: null,
  };
}

export function validateAction(state, playerId, action) {
  if (!action || typeof action !== "object" || Array.isArray(action)) {
    return { ok: false, error: "action must be an object" };
  }
  if (state.outcome) return { ok: false, error: "round is over" };
  const type = action.type;

  if (type === "click") {
    const obj = action.object;
    if (typeof obj !== "string" || !OBJECTS[obj]) {
      return { ok: false, error: "unknown object" };
    }
    return { ok: true };
  }
  if (type === "answer") {
    if (state.phone.state !== "ringing") return { ok: false, error: "phone is quiet" };
    const mode = action.mode;
    if (mode !== "fast" && mode !== "slow") return { ok: false, error: "answer needs mode fast|slow" };
    return { ok: true };
  }
  if (type === "resolveKid") {
    if (!state.tasks.kids) return { ok: false, error: "no kid acting up" };
    const mode = action.mode;
    if (mode !== "talk" && mode !== "redirect") return { ok: false, error: "resolveKid needs mode talk|redirect" };
    return { ok: true };
  }
  if (type === "pause") return { ok: true };
  return { ok: false, error: "unknown action type" };
}

export function applyAction(state, playerId, action) {
  let next = {
    ...state,
    player: clonePlayer(state.player),
    queue: state.queue.map((q) => ({ ...q })),
    pending: { ...state.pending },
    phone: { ...state.phone },
    history: state.history.slice(),
    events: state.events.slice(),
    tasks: {},
  };
  for (const k of Object.keys(state.tasks)) next.tasks[k] = cloneTaskState(state.tasks[k]);

  // ── the intent lands first (no world time has passed yet).
  if (action.type === "click") {
    if (next.player.order.mode === "walk" && next.player.order.target) {
      // Already walking somewhere — the click queues the next destination.
      next.player = { ...next.player, queuedTarget: action.object };
    } else {
      next = setWalk(next, action.object);
    }
  } else if (action.type === "answer") {
    const t = next.t;
    const delta = action.mode === "fast" ? CALL_GOODWILL_FAST : CALL_GOODWILL_SLOW;
    next.score = Math.max(0, next.score + delta);
    next.phone = { state: "idle", nextAtT: t + 30 + rngNext(next.rng).roll * 24, untilT: 0, caller: null };
    next.rng = (next.rng + 7) | 0;
    next.history = pushHistory(next, {
      tSec: Math.round(t),
      type: "phone",
      text: action.mode === "fast" ? "brushed off the call –1" : "stayed on the line +1",
    });
  } else if (action.type === "resolveKid") {
    const ts = cloneTaskState(next.tasks.kids);
    const queueItem = next.queue.find((q) => q.key === "kids");
    if (ts && queueItem) {
      const t = next.t;
      const cfg = TASKS.kids;
      let gain = cfg.points;
      let kidsQuickReturn = false;
      if (action.mode === "redirect") {
        gain = Math.max(2, cfg.points - 2);
        kidsQuickReturn = true; // acts up again sooner
      } else {
        gain = cfg.points + 2; // talking takes hold — a small bonus
      }
      next.score += gain;
      next.servedCount += 1;
      next.lastChainKey = "kids";
      next.lastChainTime = t;
      next.kidsQuickReturn = kidsQuickReturn;
      next.queue = next.queue.filter((q) => q.key !== "kids");
      next.tasks.kids = null;
      const sched = scheduleNext({ ...next, kidsQuickReturn }, "kids", t);
      next.rng = sched.rng;
      next.pending = sched.pending;
      next.history = pushHistory(next, {
        tSec: Math.round(t),
        type: "kids",
        text: action.mode === "talk" ? `talked it out +${gain}` : `redirected +${gain} (they'll act up sooner)`,
      });
    }
  }
  // "pause" carries no intent; it only advances the world.

  // ── world time.
  const dtMs = clamp(action.dtMs || 0, 0, 500);
  if (dtMs > 0.5) {
    const dtSec = dtMs / 1000;
    next = tick(next, dtSec);

    // Auto-arrive: she was walking to a pendingResolve object and has stopped
    // moving — resolve the click against any live task chain. This STARTS the
    // work; the commit happens when the work's duration has fully elapsed.
    if (next.player.order.mode === "idle" && next.player.pendingResolve) {
      const arrivedAt = next.player.pendingResolve;
      next.player = { ...next.player, pendingResolve: null };
      const r = resolveClick(next, arrivedAt);
      next = r.state;
    }

    // WORKING → FINISHING: the step's full duration has elapsed and she is
    // still standing at the anchor — commit it (points, timers, completion).
    if (next.player.working && next.t >= next.player.working.endsAt && next.player.order.mode === "idle") {
      next = commitWork(next);
    }

    // A queued click is consumed only when she is free — never mid-work.
    if (next.player.queuedTarget && !next.player.working && next.player.order.mode === "idle" && !next.player.pendingResolve) {
      const queued = next.player.queuedTarget;
      next.player = { ...next.player, queuedTarget: null };
      next = setWalk(next, queued);
    }

    // Self-sit completion (no queue item closes it).
    const selfTs = next.tasks.self;
    if (selfTs && selfTs.timerEnd != null && next.t >= selfTs.timerEnd) {
      next.selfNeed = SELF_NEED_MAX;
      next.restoreT = 6;
      next.servedCount += 1;
      next.score += TASKS.self.points;
      next.tasks.self = null;
      next.player = { ...next.player, seated: false, anim: null, busyUntil: 0 };
      next.history = pushHistory(next, { tSec: Math.round(next.t), type: "self", text: "took a minute for herself" });
    }
  }

  // ── round close.
  if (next.t >= next.roundSeconds && !next.outcome) {
    const won = next.score >= next.target;
    const selfText = next.selfNeed < 30 ? "she never got her minute" : "she kept a piece of herself";
    const missText = next.missed === 0 ? "nothing slipped" : `${next.missed} slipped`;
    next = {
      ...next,
      outcome: won ? "won" : "lost",
      player: { ...next.player, order: emptyOrder(), anim: null, busyUntil: 0, seated: false },
      history: pushHistory(next, {
        tSec: Math.round(next.t),
        type: "end",
        text: `${won ? "shift survived" : "the morning won"} · ${selfText} · ${missText}`,
      }),
    };
  }

  return next;
}

export function isGameOver(state) {
  if (state.t >= state.roundSeconds || state.outcome) {
    return { over: true, winner: state.score >= state.target ? "her" : null };
  }
  return { over: false };
}

export function viewFor(state, playerId) {
  // Everything is client-visible; only the rng seed stays server-side.
  const taskViews = {};
  for (const k of Object.keys(state.tasks)) {
    const ts = state.tasks[k];
    if (!ts) continue;
    taskViews[k] = {
      key: k,
      stepIdx: ts.stepIdx,
      stepsLen: TASKS[k].steps.length,
      carry: ts.carry,
      burned: !!ts.burned,
      waiting: ts.stepIdx < TASKS[k].steps.length && TASKS[k].steps[ts.stepIdx] == null,
      timerEnd: ts.timerEnd ?? null,
      kidSpot: ts.kidSpot || null,
      partialText: ts.stepIdx > 0 ? `step ${ts.stepIdx}/${TASKS[k].steps.filter(Boolean).length}` : null,
    };
  }
  return {
    t: state.t,
    roundSeconds: state.roundSeconds,
    target: state.target,
    score: state.score,
    servedCount: state.servedCount,
    missed: state.missed,
    level: state.level,
    queue: state.queue,
    player: state.player,
    selfNeed: state.selfNeed,
    phone: state.phone,
    tasks: taskViews,
    taskDefs: TASKS,
    objects: OBJECTS,
    stations: STATIONS,
    lastChainKey: state.lastChainKey,
    history: state.history.slice(-6),
    events: state.events.slice(-8),
    outcome: state.outcome,
    world: { w: W, h: H },
  };
}
