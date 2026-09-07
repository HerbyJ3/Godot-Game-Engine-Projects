/**
 * SECOND SHIFT v2 — casual-cartoon point-and-click client.
 *
 * Pure mouse/touch input: one click walks Ruth to an object, live chain steps
 * resolve on arrival, wrong clicks bounce, queued clicks show a pulsing ring.
 * ESC is the only key (pause). The server (room + logic.js) is authoritative
 * — this client only sends intents and draws what comes back in `view`.
 */

// ── palette & geometry (mirror of logic.js) ────────────────────────────────

const W = 960;
const H = 640;

// warm casual-cartoon palette — sunny yellows, terracotta, sage, warm wood
const C = {
  bg: "#F3E9D2",          // cream wall backdrop
  floorA: "#E7D3AE",      // honey wood floor
  floorB: "#D9BE93",      // shadow wood
  ink: "#4A3526",         // dark-brown outlines, never pure black
  inkSoft: "rgba(74,53,38,0.55)",
  paper: "rgba(255,251,240,0.92)",
  paperSolid: "#FFFBF0",
  terracotta: "#D97E4A",
  sunny: "#F2B33D",
  sage: "#8FAE7B",
  rose: "#D98A94",
  sky: "#A8CBE0",
  warn: "#E0B04A",
  bad: "#C95A4A",
  ok: "#7FAE6D",
  highlight: "#FFE8A8",   // hover glow
  shadow: "rgba(74,53,38,0.18)",
};

// Which task keys map to which bubble icon (no emoji — procedural glyphs).
const TASK_ICONS = {
  laundry: "laundry",
  cooking: "cooking",
  diaper: "diaper",
  email: "email",
  kids: "kid",
  self: "self",
  phone: "phone",
};

// ── net plumbing (unchanged from template) ─────────────────────────────────

// A single-player game: each player gets their OWN room (keyed by their
// local player id) so no one is ever a spectator in someone else's house.
// ?room=<name> still overrides, for a shared watch-along on purpose.
const room =
  new URLSearchParams(location.search).get("room") ||
  `solo-${playerId()}`;

function playerId() {
  const key = "hf:game:playerId";
  let id = localStorage.getItem(key);
  if (!id) {
    id = Math.random().toString(36).slice(2, 10);
    localStorage.setItem(key, id);
  }
  return id;
}

const PING = "__ping";
const PONG = "__pong";

let socket = null;
let retry = 0;
let connectedOnce = false;

function connect() {
  const proto = location.protocol === "https:" ? "wss:" : "ws:";
  socket = new WebSocket(`${proto}//${location.host}/ws/${encodeURIComponent(room)}`);

  socket.addEventListener("open", () => {
    retry = 0;
    net.online = true;
    connectedOnce = true;
    send({ type: "join", playerId: playerId() });
  });

  socket.addEventListener("message", (event) => {
    if (event.data === PONG) return;
    let msg;
    try { msg = JSON.parse(event.data); } catch { return; }
    if (msg.type === "state") onServerState(msg);
    else if (msg.type === "error") onServerError(msg.error);
  });

  socket.addEventListener("close", () => {
    net.online = false;
    retry = Math.min(retry + 1, 6);
    const wait = 500 * 2 ** (retry - 1);
    // Always retry — a first-attempt failure must not leave the game dead.
    setTimeout(connect, wait);
  });

  socket.addEventListener("error", () => {
    // Browsers fire a bare error then close; the close handler retries.
    net.online = false;
  });
}

function send(msg) {
  if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify(msg));
}

setInterval(() => {
  if (socket?.readyState === WebSocket.OPEN) socket.send(PING);
}, 30_000);

// ── audio (generated SFX, unlocked on first input) ─────────────────────────

const sfx = { ctx: null, buffers: {}, ambience: null, muted: false };

const SFX_FILES = {
  tick: "/audio/tick.mp3",
  served: "/audio/served.mp3",
  alert: "/audio/alert.mp3",
  fail: "/audio/fail.mp3",
  chain: "/audio/chain.mp3",
  buffer: "/audio/buffer.mp3",
  ambience: "/audio/ambience.mp3",
};

async function initAudio() {
  if (sfx.ctx) return;
  try {
    sfx.ctx = new (window.AudioContext || window.webkitAudioContext)();
    const entries = Object.entries(SFX_FILES);
    await Promise.all(
      entries.map(async ([name, url]) => {
        try {
          const res = await fetch(url);
          if (!res.ok) return;
          const buf = await res.arrayBuffer();
          sfx.buffers[name] = await sfx.ctx.decodeAudioData(buf);
        } catch { /* silent */ }
      }),
    );
    if (sfx.buffers.ambience) {
      const src = sfx.ctx.createBufferSource();
      const gain = sfx.ctx.createGain();
      src.buffer = sfx.buffers.ambience;
      src.loop = true;
      gain.gain.value = 0.04;
      src.connect(gain).connect(sfx.ctx.destination);
      src.start();
      sfx.ambience = gain;
    }
  } catch { /* quiet game */ }
}

function playSfx(name, volume = 1) {
  const ctxA = sfx.ctx;
  const buf = sfx.buffers[name];
  if (!ctxA || !buf || sfx.muted) return;
  const src = ctxA.createBufferSource();
  const gain = ctxA.createGain();
  src.buffer = buf;
  gain.gain.value = volume;
  src.connect(gain).connect(ctxA.destination);
  src.start();
}

// ── client game state ──────────────────────────────────────────────────────

const net = { online: false, meta: null, status: "waiting", you: null, firstLoadAt: performance.now() };

const view = {
  live: null,
  snap: null,
  snapAt: 0,
  seenQueueIds: new Set(),
};

const game = {
  started: false,
  paused: false,
  hover: null, // hovered object id
  queuedClick: null, // object id she'll do after this walk
  floatTexts: [], // {x,y,txt,at,color}
  bounces: [], // {x,y,at}
  particles: [], // {x,y,vx,vy,at,color}
  shakeT: 0,
  choiceOpen: null, // {kind:'kid'|'phone', x, y}
};

let lastActionSentAt = performance.now();

function dtSince(pastMs) {
  return Math.round(Math.max(8, Math.min(500, pastMs)));
}

function sendAction(action) {
  const now = performance.now();
  const dt = dtSince(now - lastActionSentAt);
  lastActionSentAt = now;
  send({ type: "action", action: { ...action, dtMs: dt } });
}

// ── canvas ─────────────────────────────────────────────────────────────────

const canvas = document.querySelector("#game");
const ctx = canvas.getContext("2d");

function rr(x, y, w, h, r) {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r);
  ctx.arcTo(x, y, x + w, y, r);
  ctx.closePath();
}

function circle(x, y, r) {
  ctx.beginPath();
  ctx.arc(x, y, r, 0, Math.PI * 2);
  ctx.closePath();
}

function hexA(hex, a) {
  const m = hex.replace("#", "");
  const n = parseInt(m.length === 3 ? m.split("").map((ch) => ch + ch).join("") : m, 16);
  const r = (n >> 16) & 255, g = (n >> 8) & 255, b = n & 255;
  return `rgba(${r},${g},${b},${a})`;
}

function fitText(text, x, y, size, weight = 600, color = C.ink, align = "left", spacing = 0) {
  ctx.save();
  ctx.font = `${weight} ${size}px "Nunito", "Segoe UI", system-ui, sans-serif`;
  ctx.fillStyle = color;
  ctx.textAlign = align;
  ctx.textBaseline = "middle";
  if (spacing > 0 && "letterSpacing" in ctx) ctx.letterSpacing = `${spacing}px`;
  ctx.fillText(text, x, y);
  ctx.restore();
}

// Hand-drawn wobbly line: two passes of a slightly offset stroke.
function wobblyStroke(fn, color, width) {
  ctx.save();
  ctx.strokeStyle = color;
  ctx.lineWidth = width;
  ctx.lineCap = "round";
  ctx.lineJoin = "round";
  fn(0, 0);
  ctx.stroke();
  ctx.restore();
}

// ── painted assets (generated scene + Ruth sprite sheet) ──────────────────

const art = { home: null, ruthIdle: null, ruthCarry: null, ruthWalk: [], ruthWalkFront: [], ruthWalkBack: [] };

function loadArt() {
  const singles = {
    home: "/art/home.png",
    ruthIdle: "/art/ruth-idle.png",
    ruthCarry: "/art/ruth-carry.png",
  };
  for (const [key, url] of Object.entries(singles)) {
    const img = new Image();
    img.onload = () => { art[key] = img; };
    img.src = url;
  }
  // side-profile walk cycle (8 frames)
  for (let i = 0; i < 8; i++) {
    const img = new Image();
    img.onload = () => { art.ruthWalk[i] = img; };
    img.src = `/art/ruth-w${i}.png`;
  }
  // front walk cycle (6 frames — walking south, toward the viewer)
  for (let i = 0; i < 6; i++) {
    const img = new Image();
    img.onload = () => { art.ruthWalkFront[i] = img; };
    img.src = `/art/ruth-front-w${i}.png`;
  }
  // back walk cycle (8 frames — walking north, away from the viewer)
  for (let i = 0; i < 8; i++) {
    const img = new Image();
    img.onload = () => { art.ruthWalkBack[i] = img; };
    img.src = `/art/ruth-back-w${i}.png`;
  }
}

// ── the world art — the painted home, then live overlays on top ───────────

// A static copy of logic.js OBJECTS used only by the pre-connect demo view.
const OBJECTS_DEMO = {
  fridge:   { id: "fridge",   station: "kitchen", x: 153, y: 108, hitW: 56, hitH: 98 },
  counter:  { id: "counter",  station: "kitchen", x: 369, y: 87,  hitW: 44, hitH: 48 },
  stove:    { id: "stove",    station: "kitchen", x: 287, y: 89,  hitW: 58, hitH: 60 },
  cabinet:  { id: "cabinet",  station: "kitchen", x: 277, y: 36,  hitW: 80, hitH: 42 },
  formula:  { id: "formula",  station: "kitchen", x: 265, y: 253, hitW: 44, hitH: 44 },
  kettle:   { id: "kettle",   station: "kitchen", x: 293, y: 80,  hitW: 34, hitH: 36 },
  table:    { id: "table",    station: "kitchen", x: 265, y: 253, hitW: 90, hitH: 62 },
  baby:     { id: "baby",     station: "kitchen", x: 128, y: 223, hitW: 46, hitH: 62 },
  basket:    { id: "basket",    station: "laundry", x: 84,  y: 547, hitW: 74, hitH: 56 },
  washer:    { id: "washer",    station: "laundry", x: 112, y: 435, hitW: 68, hitH: 74 },
  dryer:     { id: "dryer",     station: "laundry", x: 192, y: 435, hitW: 68, hitH: 74 },
  detergent: { id: "detergent", station: "laundry", x: 112, y: 360, hitW: 44, hitH: 44 },
  deskChair: { id: "deskChair", station: "office", x: 666, y: 172, hitW: 44, hitH: 58 },
  monitor:   { id: "monitor",   station: "office", x: 649, y: 95,  hitW: 44, hitH: 42 },
  couch: { id: "couch", station: "armchair", x: 695, y: 414, hitW: 160, hitH: 90 },
  windowWall: { id: "windowWall", station: "kitchen", x: 91,  y: 151, hitW: 66, hitH: 80 },
  toyBox:     { id: "toyBox",     station: "armchair",x: 877, y: 434, hitW: 64, hitH: 64 },
  studyDesk:  { id: "studyDesk",  station: "office",  x: 810, y: 233, hitW: 80, hitH: 60 },
};

function demoView(now) {
  return {
    t: 0, roundSeconds: 150, target: 40, score: 0, servedCount: 0, missed: 0,
    queue: [],
    player: {
      x: 480, y: 330,
      order: { mode: "idle", to: null },
      queuedTarget: null, anim: null, busyUntil: 0,
      carrying: null, seated: false, pendingResolve: null,
    },
    selfNeed: 82,
    phone: { state: "idle", nextAtT: 30, untilT: 0, caller: null },
    tasks: {},
    taskDefs: {},
    objects: OBJECTS_DEMO,
    stations: {},
    lastChainKey: null,
    history: [], events: [], outcome: null,
    world: { w: 960, h: 640 },
  };
}

function drawScene(v, now) {
  // Painted home interior as the full backdrop.
  if (art.home) {
    ctx.drawImage(art.home, 0, 0, W, H);
  } else {
    ctx.fillStyle = C.bg;
    ctx.fillRect(0, 0, W, H);
  }

  const tasks = v ? v.tasks : {};

  // The nursery corner is client-drawn over the painted art — the crib,
  // changing table and diaper pail aren't in the baked image.
  drawNursery(v, now);

  // Live object overlays — state changes that need to read on top of the art:
  // steam when dinner cooks, rumble rings when the washer runs, current
  // carry hints next to the machines, the kid acting out at her spot.
  drawLiveOverlays(v, tasks, now);
}

// The nursery corner: crib, changing table with diaper drawer, pail.
function drawNursery(v, now) {
  const O = (v && v.objects) || OBJECTS_DEMO;

  // Crib
  const crib = O.crib;
  if (crib) {
    ctx.save();
    ctx.translate(crib.x, crib.y);
    ctx.fillStyle = "#E8B4C4";
    rr(-34, -22, 68, 44, 10);
    ctx.fill();
    ctx.strokeStyle = C.ink;
    ctx.lineWidth = 3;
    rr(-34, -22, 68, 44, 10);
    ctx.stroke();
    // slats
    ctx.lineWidth = 2.5;
    for (let i = -2; i <= 2; i++) {
      ctx.beginPath();
      ctx.moveTo(i * 12, -20);
      ctx.lineTo(i * 12, 20);
      ctx.stroke();
    }
    // blanket
    ctx.fillStyle = C.sunny;
    rr(-30, 6, 60, 12, 6);
    ctx.fill();
    ctx.restore();
  }

  // Changing table + drawer
  const ct = O.changingTable;
  if (ct) {
    ctx.save();
    ctx.translate(ct.x, ct.y);
    ctx.fillStyle = "#A87F52";
    rr(-30, -18, 60, 36, 8);
    ctx.fill();
    ctx.strokeStyle = C.ink;
    ctx.lineWidth = 3;
    rr(-30, -18, 60, 36, 8);
    ctx.stroke();
    // pad
    ctx.fillStyle = C.rose;
    rr(-24, -14, 48, 12, 6);
    ctx.fill();
    // diaper drawer under
    ctx.fillStyle = C.paperSolid;
    rr(-22, 4, 44, 10, 3);
    ctx.fill();
    ctx.strokeStyle = C.ink;
    ctx.lineWidth = 2;
    rr(-22, 4, 44, 10, 3);
    ctx.stroke();
    // a folded diaper poking out when the drawer matters
    const ts = v?.tasks?.diaper;
    if (ts && ts.stepIdx === 2) {
      ctx.fillStyle = C.paperSolid;
      circle(0, -26, 8);
      ctx.fill();
      ctx.strokeStyle = C.ink;
      ctx.lineWidth = 2;
      circle(0, -26, 8);
      ctx.stroke();
    }
    ctx.restore();
  }

  // Diaper pail
  const bin = O.bin;
  if (bin) {
    ctx.save();
    ctx.translate(bin.x, bin.y);
    ctx.fillStyle = "#C9CFD6";
    rr(-14, -18, 28, 34, 6);
    ctx.fill();
    ctx.strokeStyle = C.ink;
    ctx.lineWidth = 2.5;
    rr(-14, -18, 28, 34, 6);
    ctx.stroke();
    // lid
    ctx.fillStyle = C.sage;
    rr(-16, -22, 32, 8, 4);
    ctx.fill();
    ctx.strokeStyle = C.ink;
    rr(-16, -22, 32, 8, 4);
    ctx.stroke();
    ctx.restore();
  }
  void now;
}

function drawLiveOverlays(v, tasks, now) {
  if (!v?.objects) return;
  const O = v.objects;

  // Next-step glow ring on the object the current chain needs.
  for (const key of Object.keys(tasks || {})) {
    const ts = tasks[key];
    if (!ts || key === "kids" || key === "self") continue;
    const def = v.taskDefs?.[key];
    if (!def) continue;
    const step = def.steps[ts.stepIdx];
    if (!step || ts.waiting) continue;
    const o = O[step.target];
    if (!o) continue;
    const pulse = 1 + Math.sin(now / 220) * 0.05;
    ctx.fillStyle = hexA(C.highlight, 0.4);
    ctx.beginPath();
    ctx.ellipse(o.x, o.y, (o.hitW / 2) * pulse, (o.hitH / 2) * 0.6 * pulse, 0, 0, Math.PI * 2);
    ctx.fill();
    ctx.strokeStyle = hexA(C.sunny, 0.85);
    ctx.lineWidth = 3;
    ctx.beginPath();
    ctx.ellipse(o.x, o.y, (o.hitW / 2) * pulse, (o.hitH / 2) * 0.6 * pulse, 0, 0, Math.PI * 2);
    ctx.stroke();
  }

  // Steam while the stove has a pan on it.
  const bf = tasks.cooking;
  if (bf && bf.stepIdx === 3 && O.stove) {
    const t = (now / 260) % 1;
    ctx.strokeStyle = hexA(C.paperSolid, 0.9 - t * 0.8);
    ctx.lineWidth = 3;
    ctx.beginPath();
    ctx.moveTo(O.stove.x - 8, O.stove.y - 40 - t * 18);
    ctx.quadraticCurveTo(O.stove.x - 2, O.stove.y - 50 - t * 18, O.stove.x - 8, O.stove.y - 60 - t * 18);
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(O.stove.x + 8, O.stove.y - 42 - t * 18);
    ctx.quadraticCurveTo(O.stove.x + 14, O.stove.y - 52 - t * 18, O.stove.x + 8, O.stove.y - 62 - t * 18);
    ctx.stroke();
  }
  // Smoke when it's burned.
  if (bf?.burned && O.stove) {
    ctx.fillStyle = hexA(C.ink, 0.45);
    circle(O.stove.x, O.stove.y - 70, 12); ctx.fill();
    circle(O.stove.x + 10, O.stove.y - 86, 9); ctx.fill();
  }

  // Washer / dryer rumble while their timers run.
  const la = tasks.laundry;
  if (la?.waiting && la.timerEnd != null && O.washer && O.dryer) {
    const runningWasher = la.stepIdx === 5;
    const machine = runningWasher ? O.washer : O.dryer;
    const r = Math.sin(now / 80) * 2;
    ctx.strokeStyle = hexA(C.ink, 0.35);
    ctx.lineWidth = 2.5;
    ctx.beginPath();
    ctx.ellipse(machine.x + r, machine.y + 10, 30, 16, 0, 0, Math.PI * 2);
    ctx.stroke();
    // countdown badge above the machine
    const left = Math.max(0, Math.ceil(la.timerEnd - v.t));
    ctx.fillStyle = C.paperSolid;
    circle(machine.x, machine.y - 52, 14);
    ctx.fill();
    ctx.strokeStyle = C.ink;
    ctx.lineWidth = 2.5;
    circle(machine.x, machine.y - 52, 14);
    ctx.stroke();
    fitText(`${left}`, machine.x, machine.y - 51, 12, 800, C.ink, "center");
  }

  // Kid acting out — only when the demand is live.
  if (tasks.kids && tasks.kids.kidSpot && O[tasks.kids.kidSpot]) {
    const o = O[tasks.kids.kidSpot];
    const wob = Math.sin(now / 140) * 4;
    ctx.save();
    ctx.translate(o.x, o.y + wob * 0.4);
    // a small cartoon kid scrambling
    ctx.fillStyle = C.sky;
    rr(-10, -18, 20, 24, 8);
    ctx.fill();
    ctx.strokeStyle = C.ink;
    ctx.lineWidth = 2.5;
    rr(-10, -18, 20, 24, 8);
    ctx.stroke();
    ctx.fillStyle = "#F2C89B";
    circle(0, -24, 8);
    ctx.fill();
    ctx.stroke();
    ctx.restore();
  }

  // The baby: crying bubble while the diaper demand is live.
  const wantsDiaper = v.queue?.some((q) => q.key === "diaper");
  if (wantsDiaper && O.baby) {
    const bob = Math.sin(now / 200) * 2;
    ctx.fillStyle = C.paperSolid;
    circle(O.baby.x + 18, O.baby.y - 28 + bob, 12);
    ctx.fill();
    ctx.strokeStyle = C.bad;
    ctx.lineWidth = 2;
    circle(O.baby.x + 18, O.baby.y - 28 + bob, 12);
    ctx.stroke();
    ctx.fillStyle = C.sky;
    circle(O.baby.x + 18, O.baby.y - 26 + bob, 4);
    ctx.fill();
  }

  // Hover affordance — every interactive object gets a soft glow ring when
  // the cursor is over it, so the player can see what is live without reading.
  if (game.hover && O[game.hover]) {
    const o = O[game.hover];
    const pulse = 1.05 + Math.sin(now / 220) * 0.04;
    ctx.strokeStyle = hexA(C.sunny, 0.95);
    ctx.lineWidth = 3.5;
    ctx.beginPath();
    ctx.ellipse(o.x, o.y, (Math.max(44, o.hitW) / 2) * pulse, (Math.max(44, o.hitH) / 2) * 0.62 * pulse, 0, 0, Math.PI * 2);
    ctx.stroke();
    ctx.fillStyle = hexA(C.highlight, 0.22);
    ctx.beginPath();
    ctx.ellipse(o.x, o.y, (Math.max(44, o.hitW) / 2) * pulse, (Math.max(44, o.hitH) / 2) * 0.62 * pulse, 0, 0, Math.PI * 2);
    ctx.fill();
  }
}


// ── the player (sprite-based Ruth, smoothed motion, 2-frame walk cycle) ────

// The server only tells us her position when an action lands (~1s heartbeat
// or per click). Rendering her AT that position would make her teleport, so
// the client keeps a smoothed render position that chases the server one.
const ruthRender = { x: 480, y: 330, facing: 1, lastNow: 0, walkPhase: 0 };

function drawRuth(v, now) {
  const p = v?.player;
  if (!p) return;

  // frame delta for the smoother
  const dtMs = ruthRender.lastNow ? Math.min(100, now - ruthRender.lastNow) : 16;
  ruthRender.lastNow = now;
  const dtSec = dtMs / 1000;

  // exponential chase — reaches the target in a few hundred ms, no snapping
  const chase = 1 - Math.exp(-10 * dtSec);
  const dx = p.x - ruthRender.x;
  const dy = p.y - ruthRender.y;
  ruthRender.x += dx * chase;
  ruthRender.y += dy * chase;

  const moving = Math.hypot(dx, dy) > 2 || p.order?.mode === "walk";
  // Heading decides the sprite set: vertical legs show front/back,
  // horizontal legs show the profile, mirrored by direction.
  let heading = "south";
  if (moving && p.order?.to) {
    const hx = p.order.to.x - ruthRender.x;
    const hy = p.order.to.y - ruthRender.y;
    if (Math.abs(hy) >= Math.abs(hx)) heading = hy < 0 ? "north" : "south";
    else heading = hx < 0 ? "west" : "east";
    if (heading === "west") ruthRender.facing = -1;
    else if (heading === "east") ruthRender.facing = 1;
  }
  if (moving) ruthRender.walkPhase += dtSec * 11; // ~1.4 full gait cycles/sec

  const x = ruthRender.x;
  const y = ruthRender.y;
  const carry = p.carrying;

  // ── animation state machine: IDLE / WALKING / WORKING / FINISHING
  const working = p.working && p.anim;
  if (working) ruthRender.lastWorkSeen = now;
  const finishing = !working && !moving && ruthRender.lastWorkSeen && now - ruthRender.lastWorkSeen < 220;

  // sprite pick: working/idle face by p.facing; walking by heading
  let img = art.ruthIdle;
  let mirror = false;
  const stationaryFacing = p.facing || "down";
  if (moving) {
    if (heading === "north" && art.ruthWalkBack.filter(Boolean).length === 8) {
      img = art.ruthWalkBack[Math.floor(ruthRender.walkPhase) % 8];
    } else if (heading === "south" && art.ruthWalkFront.filter(Boolean).length === 6) {
      img = art.ruthWalkFront[Math.floor(ruthRender.walkPhase) % 6];
    } else if (art.ruthWalk.filter(Boolean).length === 8) {
      img = art.ruthWalk[Math.floor(ruthRender.walkPhase) % 8];
      mirror = ruthRender.facing < 0;
    }
    if (carry && art.ruthCarry) img = art.ruthCarry, mirror = ruthRender.facing < 0;
  } else {
    // stationary: turn toward the object she's at
    if (stationaryFacing === "up" && art.ruthWalkBack[0]) img = art.ruthWalkBack[0];
    else if ((stationaryFacing === "left" || stationaryFacing === "right") && art.ruthWalk[0]) {
      img = art.ruthWalk[0];
      mirror = stationaryFacing === "left";
    } else img = art.ruthIdle;
    if (carry && art.ruthCarry && !working) {
      img = art.ruthCarry;
      mirror = stationaryFacing === "left";
    }
  }

  // shadow under her feet — flat contact ellipse, low opacity, no halo
  ctx.fillStyle = "rgba(74,53,38,0.22)";
  ctx.beginPath();
  ctx.ellipse(x, y + 4, 24, 7, 0, 0, Math.PI * 2);
  ctx.fill();

  // body — human scale: she's 5'6" next to ~85cm appliances
  const H_PX = 128;
  if (img) {
    const w = (img.width / img.height) * H_PX;
    ctx.save();
    ctx.translate(x, y);

    if (moving) {
      // WALKING: stride bob
      ctx.translate(0, Math.abs(Math.sin(ruthRender.walkPhase * Math.PI)) * -5);
    } else if (working) {
      // WORKING: visibly distinct per station, procedural
      const kind = p.anim.kind;
      const wt = now / 1000;
      if (kind === "grab" || kind === "pour" || kind === "press" || kind === "dispose") {
        // bending down, loading motion (washer / dryer / basket / bin)
        const crouch = 0.5 + 0.5 * Math.sin(wt * 6);
        ctx.translate(0, crouch * 7);
        ctx.scale(1, 1 - crouch * 0.08);
      } else if (kind === "chop" || kind === "cook" || kind === "plate" || kind === "fill" || kind === "scoop" || kind === "serve") {
        // arms working at counter height: quick small bob
        ctx.translate(0, Math.sin(wt * 11) * 2.5);
      } else if (kind === "lay" || kind === "change" || kind === "feed" || kind === "shake") {
        // leaning in, gentle rocking (crib / baby / changing table)
        const lean = stationaryFacing === "left" ? -1 : stationaryFacing === "right" ? 1 : 0.6;
        ctx.rotate(Math.sin(wt * 3.2) * 0.05 + lean * 0.07);
        ctx.translate(0, 2);
      } else if (kind === "type" || kind === "wake" || kind === "send") {
        // leaning over the desk
        ctx.translate(0, 4 + Math.sin(wt * 9) * 1.2);
        ctx.scale(1, 0.97);
      } else if (kind === "sit") {
        // actually sitting — the one state at rest
        ctx.translate(0, 10);
        ctx.scale(1, 0.94);
      }
    } else if (finishing) {
      // FINISHING: a brief completion pulse
      const fp = 1 - (now - ruthRender.lastWorkSeen) / 220;
      const s = 1 + fp * 0.06;
      ctx.scale(s, s);
    } else {
      // IDLE: subtle breathing bob
      ctx.scale(1, 1 + Math.sin(now / 800) * 0.008);
    }

    if (mirror) ctx.scale(-1, 1);
    ctx.drawImage(img, -w / 2, -H_PX + 6, w, H_PX);
    ctx.restore();
  } else {
    ctx.fillStyle = C.terracotta;
    rr(x - 18, y - 76, 36, 76, 14);
    ctx.fill();
  }

  // carrying indicator: a small floating item chip near her hands
  if (carry) {
    const chipY = y - 72;
    ctx.save();
    ctx.translate(x + 24 * ruthRender.facing, chipY);
    ctx.fillStyle = C.paperSolid;
    circle(0, 0, 13);
    ctx.fill();
    ctx.strokeStyle = C.ink;
    ctx.lineWidth = 2;
    circle(0, 0, 13);
    ctx.stroke();
    drawTaskIcon(carry === "ingredients" ? "cooking" : carry === "diaper" ? "diaper" : carry === "baby" ? "diaper" : carry === "plated" ? "cooking" : "laundry", 0, 0, 14, C.ink);
    ctx.restore();
  }

  // the active route, drawn as a soft dashed path (mirrors the floor plan)
  if (p.order?.mode === "walk" && p.order.to) {
    const pts = [ { x: ruthRender.x, y: ruthRender.y }, p.order.to, ...(p.order.path || []) ];
    ctx.save();
    ctx.strokeStyle = "rgba(255, 251, 240, 0.75)";
    ctx.lineWidth = 3;
    ctx.setLineDash([8, 7]);
    ctx.lineCap = "round";
    ctx.beginPath();
    ctx.moveTo(pts[0].x, pts[0].y);
    for (let i = 1; i < pts.length; i++) ctx.lineTo(pts[i].x, pts[i].y);
    ctx.stroke();
    ctx.setLineDash([]);
    // destination dot
    const dest = pts[pts.length - 1];
    ctx.fillStyle = "rgba(255, 251, 240, 0.9)";
    circle(dest.x, dest.y, 5);
    ctx.fill();
    ctx.strokeStyle = hexA(C.ink, 0.5);
    ctx.lineWidth = 2;
    circle(dest.x, dest.y, 5);
    ctx.stroke();
    ctx.restore();
  }

  // queued destination ring
  const queued = v?.player?.queuedTarget;
  if (queued && v?.objects?.[queued]) {
    const q = v.objects[queued];
    const pulse = 1 + Math.sin(now / 220) * 0.1;
    ctx.strokeStyle = hexA(C.sunny, 0.85);
    ctx.lineWidth = 3;
    ctx.beginPath();
    ctx.ellipse(q.x, q.y, (q.hitW / 2) * pulse, (q.hitH / 2) * 0.55 * pulse, 0, 0, Math.PI * 2);
    ctx.stroke();
  }
}

// ── the HUD (star meter, clock, thought-bubble demands, phone, SELF bar) ───

function drawHUD(v, now) {
  const frac = v ? Math.min(1, v.t / v.roundSeconds) : 0;

  // ── top-left cluster: clock face + star meter
  drawClockHUD(frac);
  drawStarMeter(v);

  // ── thought bubbles for live demands
  drawDemandBubbles(v, now);

  // ── phone / incoming call
  if (v?.phone?.state === "ringing") drawPhoneCall(v, now);

  // ── kid choice popup
  if (v?.tasks?.kids && v.player?.anim?.kind === "kneel") {
    drawKidChoice(v, now);
  }

  // ── SELF bar (bottom-left), and the emotional line
  drawSelfBar(v);

  // ── juice: floating +points, bounce rings, particles, screen shake
  drawJuice(now);

  // ── pause + menu overlays
  if (game.paused) drawPauseOverlay(v);
  if (!game.started && v) drawMenuOverlay(v);
  if (v?.outcome) drawEndOverlay(v, now);
}

function drawClockHUD(frac) {
  const cx = 46, cy = 46, r = 26;
  ctx.fillStyle = C.paper;
  circle(cx, cy, r + 8);
  ctx.fill();
  ctx.strokeStyle = C.ink;
  ctx.lineWidth = 3;
  circle(cx, cy, r + 8);
  ctx.stroke();

  // clock face
  ctx.fillStyle = C.paperSolid;
  circle(cx, cy, r);
  ctx.fill();
  ctx.strokeStyle = hexA(C.ink, 0.3);
  ctx.lineWidth = 2;
  circle(cx, cy, r);
  ctx.stroke();

  // marks
  ctx.strokeStyle = C.ink;
  ctx.lineWidth = 2;
  for (let i = 0; i < 12; i++) {
    const a = (i / 12) * Math.PI * 2;
    ctx.beginPath();
    ctx.moveTo(cx + Math.cos(a) * (r - 5), cy + Math.sin(a) * (r - 5));
    ctx.lineTo(cx + Math.cos(a) * (r - 1), cy + Math.sin(a) * (r - 1));
    ctx.stroke();
  }

  // hands — 07:55 → 08:10 over the round
  const totalMin = 55 + frac * 15;
  const mAngle = (-90 + totalMin * 6) * (Math.PI / 180);
  const hAngle = (-90 + (7 + totalMin / 60) * 30) * (Math.PI / 180);
  ctx.strokeStyle = C.ink;
  ctx.lineWidth = 3.5;
  ctx.beginPath();
  ctx.moveTo(cx, cy);
  ctx.lineTo(cx + Math.cos(mAngle) * (r - 8), cy + Math.sin(mAngle) * (r - 8));
  ctx.stroke();
  ctx.lineWidth = 4.5;
  ctx.beginPath();
  ctx.moveTo(cx, cy);
  ctx.lineTo(cx + Math.cos(hAngle) * (r - 14), cy + Math.sin(hAngle) * (r - 14));
  ctx.stroke();
  ctx.fillStyle = C.ink;
  circle(cx, cy, 3);
  ctx.fill();

  // a tiny fill arc that drains as the round runs
  ctx.strokeStyle = frac > 0.85 ? C.bad : C.sage;
  ctx.lineWidth = 4;
  ctx.beginPath();
  ctx.arc(cx, cy, r + 8, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * (1 - frac));
  ctx.stroke();
}

function drawStarMeter(v) {
  const score = v ? v.score : 0;
  const target = v ? v.target : 40;
  const frac = Math.min(1, score / target);
  const x = 92, y = 22, w = 200, h = 18;

  // chunky rounded bar
  ctx.fillStyle = C.paper;
  rr(x - 10, y - 10, w + 20, h + 20, 14);
  ctx.fill();
  ctx.strokeStyle = C.ink;
  ctx.lineWidth = 3;
  rr(x - 10, y - 10, w + 20, h + 20, 14);
  ctx.stroke();

  // fill
  ctx.fillStyle = hexA(C.ink, 0.08);
  rr(x, y, w, h, 9);
  ctx.fill();
  const grad = ctx.createLinearGradient(x, 0, x + w, 0);
  grad.addColorStop(0, C.sunny);
  grad.addColorStop(1, C.terracotta);
  ctx.fillStyle = grad;
  if (frac > 0) {
    rr(x, y, w * frac, h, 9);
    ctx.fill();
  }

  // 3 star thresholds
  const marks = [0.34, 0.67, 1.0];
  marks.forEach((m, i) => {
    const sx = x + w * m;
    const reached = frac >= m;
    drawStar(sx, y + h / 2, reached ? 9 : 7, reached ? C.sunny : hexA(C.ink, 0.25));
    void i;
  });

  // Level chip under the meter — which half of the marriage this is.
  if (v?.level) {
    fitText(v.level.name.toUpperCase(), x + 4, y + h + 26, 10, 800, hexA(C.ink, 0.55), "left", 1.5);
  }
}

function drawStar(x, y, r, color) {
  ctx.save();
  ctx.translate(x, y);
  ctx.fillStyle = color;
  ctx.strokeStyle = C.ink;
  ctx.lineWidth = 2.5;
  ctx.beginPath();
  for (let i = 0; i < 5; i++) {
    const a = (-90 + i * 72) * (Math.PI / 180);
    const a2 = (-90 + i * 72 + 36) * (Math.PI / 180);
    if (i === 0) ctx.moveTo(Math.cos(a) * r, Math.sin(a) * r);
    else ctx.lineTo(Math.cos(a) * r, Math.sin(a) * r);
    ctx.lineTo(Math.cos(a2) * (r * 0.45), Math.sin(a2) * (r * 0.45));
  }
  ctx.closePath();
  ctx.fill();
  ctx.stroke();
  ctx.restore();
}

function drawDemandBubbles(v, now) {
  if (!v) return;
  const queue = v.queue || [];
  const live = queue.slice(0, 6); // HUD shows up to 6 bubbles
  live.forEach((q, i) => {
    const x = 340 + i * 110;
    const y = 30;
    const def = v.taskDefs?.[q.key];
    const ts = v.tasks?.[q.key];

    // pop on arrival
    if (!view.seenQueueIds.has(q.id)) {
      view.seenQueueIds.add(q.id);
      q._bornAt = now;
      playSfx("served", 0.1);
    }
    const bornAgo = q._bornAt ? now - q._bornAt : 9999;
    const pop = bornAgo < 350 ? 1 + Math.sin((bornAgo / 350) * Math.PI) * 0.12 : 1;

    // patience fraction (visual, never a number)
    const patienceTotal = def?.patience || 30;
    const remaining = Math.max(0, q.expiresT - v.t);
    const frac = Math.min(1, remaining / patienceTotal);
    const col = frac > 0.5 ? C.ok : frac > 0.25 ? C.warn : C.bad;

    // shake at ≤25%
    let shakeX = 0;
    if (frac < 0.25 && frac > 0) {
      shakeX = Math.sin(now / 50) * 2.5;
      if (Math.floor(now / 600) !== q._warnedBeat) {
        q._warnedBeat = Math.floor(now / 600);
        playSfx("alert", 0.15);
      }
    }

    ctx.save();
    ctx.translate(x + shakeX, y);
    ctx.scale(pop, pop);

    // the bubble itself
    ctx.fillStyle = C.paperSolid;
    circle(0, 0, 26);
    ctx.fill();
    ctx.strokeStyle = C.ink;
    ctx.lineWidth = 3;
    circle(0, 0, 26);
    ctx.stroke();

    // patience ring (drains)
    ctx.strokeStyle = hexA(C.ink, 0.12);
    ctx.lineWidth = 5;
    circle(0, 0, 26);
    ctx.stroke();
    if (frac > 0) {
      ctx.strokeStyle = col;
      ctx.lineWidth = 5;
      ctx.beginPath();
      ctx.arc(0, 0, 26, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * frac);
      ctx.stroke();
    }

    // task icon
    drawTaskIcon(TASK_ICONS[q.key] || "laundry", 0, 0, 16, C.ink);

    // step progress dots
    if (ts && def) {
      const doneSteps = ts.stepIdx;
      const total = def.steps.filter(Boolean).length;
      ctx.fillStyle = C.ink;
      for (let s = 0; s < total; s++) {
        const dx = (s - (total - 1) / 2) * 7;
        circle(dx, 32, s < doneSteps ? 3 : 2);
        ctx.globalAlpha = s < doneSteps ? 1 : 0.3;
        ctx.fill();
      }
      ctx.globalAlpha = 1;
    }

    // small label under (fallback text, never primary)
    fitText(def?.label || q.key, 0, 46, 10, 600, C.inkSoft, "center");

    ctx.restore();

    // waiting-for-machine badge
    if (ts?.waiting && ts.timerEnd != null) {
      const left = Math.max(0, ts.timerEnd - v.t);
      ctx.fillStyle = C.paper;
      circle(x + 24, y - 22, 11);
      ctx.fill();
      ctx.strokeStyle = C.ink;
      ctx.lineWidth = 2;
      circle(x + 24, y - 22, 11);
      ctx.stroke();
      fitText(`${Math.ceil(left)}`, x + 24, y - 21, 10, 700, C.ink, "center");
    }
  });
}

function drawTaskIcon(kind, x, y, s, color) {
  ctx.save();
  ctx.translate(x, y);
  ctx.strokeStyle = color;
  ctx.fillStyle = color;
  ctx.lineWidth = Math.max(2, s * 0.14);
  ctx.lineCap = "round";
  ctx.lineJoin = "round";

  if (kind === "cooking") {
    // a pot with steam
    rr(-s * 0.5, -s * 0.15, s, s * 0.6, s * 0.12);
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(-s * 0.5, -s * 0.15);
    ctx.lineTo(s * 0.5, -s * 0.15);
    ctx.stroke();
    // handles
    ctx.beginPath();
    ctx.moveTo(-s * 0.62, -s * 0.05); ctx.lineTo(-s * 0.5, -s * 0.05);
    ctx.moveTo(s * 0.5, -s * 0.05); ctx.lineTo(s * 0.62, -s * 0.05);
    ctx.stroke();
    // steam
    ctx.beginPath();
    ctx.moveTo(-s * 0.15, -s * 0.3);
    ctx.quadraticCurveTo(-s * 0.05, -s * 0.45, -s * 0.15, -s * 0.6);
    ctx.moveTo(s * 0.15, -s * 0.3);
    ctx.quadraticCurveTo(s * 0.25, -s * 0.45, s * 0.15, -s * 0.6);
    ctx.stroke();
  } else if (kind === "diaper") {
    // a folded diaper: body + two wing flaps + pins
    ctx.beginPath();
    ctx.moveTo(-s * 0.5, -s * 0.25);
    ctx.quadraticCurveTo(0, -s * 0.05, s * 0.5, -s * 0.25);
    ctx.lineTo(s * 0.42, s * 0.35);
    ctx.quadraticCurveTo(0, s * 0.6, -s * 0.42, s * 0.35);
    ctx.closePath();
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(-s * 0.5, -s * 0.25);
    ctx.lineTo(-s * 0.42, s * 0.35);
    ctx.moveTo(s * 0.5, -s * 0.25);
    ctx.lineTo(s * 0.42, s * 0.35);
    ctx.stroke();
    circle(-s * 0.34, -s * 0.05, s * 0.08);
    ctx.fill();
    circle(s * 0.34, -s * 0.05, s * 0.08);
    ctx.fill();
  } else if (kind === "breakfast") {
    // frying pan
    ctx.beginPath();
    ctx.arc(0, 2, s * 0.5, 0, Math.PI * 2);
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(s * 0.5, 2);
    ctx.lineTo(s * 0.85, -s * 0.1);
    ctx.stroke();
    // egg
    ctx.fillStyle = C.paperSolid;
    circle(0, 2, s * 0.2);
    ctx.fill();
    ctx.fillStyle = C.sunny;
    circle(0, 2, s * 0.09);
    ctx.fill();
  } else if (kind === "laundry") {
    rr(-s * 0.55, -s * 0.5, s * 1.1, s * 1.05, s * 0.16);
    ctx.stroke();
    circle(0, s * 0.06, s * 0.24);
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(-s * 0.3, -s * 0.32); ctx.lineTo(-s * 0.12, -s * 0.32);
    ctx.moveTo(s * 0.1, -s * 0.32); ctx.lineTo(s * 0.3, -s * 0.32);
    ctx.stroke();
  } else if (kind === "bottle") {
    rr(-s * 0.28, -s * 0.4, s * 0.56, s * 0.85, s * 0.14);
    ctx.stroke();
    rr(-s * 0.16, -s * 0.62, s * 0.32, s * 0.24, s * 0.08);
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(-s * 0.18, s * 0.05); ctx.lineTo(s * 0.18, s * 0.05);
    ctx.stroke();
  } else if (kind === "email") {
    rr(-s * 0.6, -s * 0.42, s * 1.2, s * 0.84, s * 0.1);
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(-s * 0.6, -s * 0.42);
    ctx.lineTo(0, s * 0.05);
    ctx.lineTo(s * 0.6, -s * 0.42);
    ctx.stroke();
  } else if (kind === "kid") {
    // crayon scribble
    ctx.beginPath();
    ctx.moveTo(-s * 0.5, -s * 0.1);
    ctx.quadraticCurveTo(-s * 0.2, -s * 0.5, 0, -s * 0.15);
    ctx.quadraticCurveTo(s * 0.2, s * 0.2, s * 0.5, -s * 0.05);
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(-s * 0.5, s * 0.3);
    ctx.quadraticCurveTo(-s * 0.1, s * 0.05, s * 0.3, s * 0.35);
    ctx.stroke();
  } else if (kind === "self") {
    // a heart
    ctx.beginPath();
    ctx.moveTo(0, s * 0.5);
    ctx.bezierCurveTo(-s * 0.7, s * 0.05, -s * 0.55, -s * 0.5, 0, -s * 0.15);
    ctx.bezierCurveTo(s * 0.55, -s * 0.5, s * 0.7, s * 0.05, 0, s * 0.5);
    ctx.stroke();
  } else if (kind === "phone") {
    ctx.beginPath();
    ctx.moveTo(-s * 0.42, -s * 0.1);
    ctx.quadraticCurveTo(0, -s * 0.55, s * 0.42, -s * 0.1);
    ctx.lineTo(s * 0.28, s * 0.1);
    ctx.quadraticCurveTo(0, -s * 0.12, -s * 0.28, s * 0.1);
    ctx.closePath();
    ctx.stroke();
  }
  ctx.restore();
}

function drawPhoneCall(v, now) {
  // top-right ringing chip, click-to-answer
  const x = W - 180, y = 16, w = 164, h = 56;
  const shake = Math.sin(now / 80) * 2;

  ctx.save();
  ctx.translate(x + shake, y);
  ctx.fillStyle = C.paperSolid;
  rr(0, 0, w, h, 14);
  ctx.fill();
  ctx.strokeStyle = C.bad;
  ctx.lineWidth = 3;
  rr(0, 0, w, h, 14);
  ctx.stroke();

  drawTaskIcon("phone", 22, h / 2, 14, C.bad);
  fitText(`${v.phone.caller || "the phone"}`, 42, h / 2 - 8, 12, 700, C.ink);
  fitText("tap to answer", 42, h / 2 + 9, 10, 600, C.inkSoft);
  ctx.restore();

  // remember the rect for click hit-testing
  game.choiceOpen = game.choiceOpen || {};
  game.choiceOpen.phoneRect = { x, y, w, h };
}

function drawKidChoice(v, now) {
  // a small talk/redirect popup near the player
  const p = v.player;
  const x = p.x, y = p.y - 64;
  const bob = Math.sin(now / 240) * 1.5;

  ctx.save();
  ctx.translate(x, y + bob);
  ctx.fillStyle = C.paperSolid;
  rr(-110, -26, 220, 52, 14);
  ctx.fill();
  ctx.strokeStyle = C.ink;
  ctx.lineWidth = 3;
  rr(-110, -26, 220, 52, 14);
  ctx.stroke();

  // two option pills
  ctx.fillStyle = C.sage;
  rr(-102, -18, 100, 36, 10);
  ctx.fill();
  ctx.strokeStyle = C.ink;
  ctx.lineWidth = 2.5;
  rr(-102, -18, 100, 36, 10);
  ctx.stroke();
  fitText("Talk it out", -52, 0, 13, 700, C.paperSolid, "center");

  ctx.fillStyle = C.sunny;
  rr(2, -18, 100, 36, 10);
  ctx.fill();
  ctx.strokeStyle = C.ink;
  ctx.lineWidth = 2.5;
  rr(2, -18, 100, 36, 10);
  ctx.stroke();
  fitText("Redirect", 52, 0, 13, 700, C.ink, "center");
  ctx.restore();

  game.choiceOpen = game.choiceOpen || {};
  game.choiceOpen.kidRect = {
    talk: { x: x - 102, y: y - 18 + bob, w: 100, h: 36 },
    redirect: { x: x + 2, y: y - 18 + bob, w: 100, h: 36 },
  };
}

function drawSelfBar(v) {
  const x = 16, y = H - 36, w = 180, h = 14;
  const frac = v ? v.selfNeed / 100 : 1;
  const low = frac < 0.3;

  ctx.fillStyle = C.paper;
  rr(x - 8, y - 24, w + 16, h + 34, 12);
  ctx.fill();
  ctx.strokeStyle = C.ink;
  ctx.lineWidth = 3;
  rr(x - 8, y - 24, w + 16, h + 34, 12);
  ctx.stroke();

  fitText("HER OWN NEEDS", x, y - 13, 10, 700, low ? C.bad : C.inkSoft);

  // the bar itself
  ctx.fillStyle = hexA(C.ink, 0.08);
  rr(x, y, w, h, 7);
  ctx.fill();
  ctx.fillStyle = low ? C.bad : C.rose;
  if (frac > 0) {
    rr(x, y, w * frac, h, 7);
    ctx.fill();
  }

  // the emotional line — bottom of the screen
  fitText("Hers, while she holds it.", x, y + h + 12, 10, 500, C.inkSoft);
}

// ── juice: floaters, particles, bounce rings, screen shake ─────────────────

// ── depth sorting: foreground cutouts from the painted art ─────────────────
// home.png is exactly world-sized (960×640), so re-drawing a furniture rect at
// its own position occludes whatever was drawn under it. Each cut carries the
// baseY where the object meets the floor: Ruth standing ABOVE that line (feet
// y < baseY) is BEHIND the object, so the cut re-draws over her.
const FG_CUTS = [
  { x: 222, y: 214, w: 86,  h: 74,  baseY: 285 }, // kitchen table
  { x: 610, y: 362, w: 172, h: 102, baseY: 462 }, // couch
  { x: 582, y: 92,  w: 180, h: 80,  baseY: 168 }, // office desk
  { x: 642, y: 135, w: 62,  h: 70,  baseY: 202 }, // desk chair
  { x: 766, y: 196, w: 90,  h: 70,  baseY: 262 }, // kids' desk
  { x: 72,  y: 398, w: 80,  h: 74,  baseY: 468 }, // washer
  { x: 150, y: 398, w: 80,  h: 74,  baseY: 468 }, // dryer
];

function drawForeground(v, ruthFeetY, now) {
  if (art.home) {
    for (const c of FG_CUTS) {
      if (ruthFeetY < c.baseY) {
        ctx.drawImage(art.home, c.x, c.y, c.w, c.h, c.x, c.y, c.w, c.h);
      }
    }
  }
  // The client-drawn nursery props occlude her the same way (base ≈ y 567).
  if (ruthFeetY < 567) drawNursery(v, now);
}

function drawJuice(now) {
  // floaters (+points)
  for (let i = game.floatTexts.length - 1; i >= 0; i--) {
    const f = game.floatTexts[i];
    const age = now - f.at;
    if (age > 1100) { game.floatTexts.splice(i, 1); continue; }
    const p = age / 1100;
    ctx.save();
    ctx.globalAlpha = 1 - p * p;
    ctx.translate(f.x, f.y - p * 44);
    fitText(f.txt, 0, 0, 15, 800, f.color || C.sunny, "center");
    ctx.restore();
  }

  // bounce rings (wrong click)
  for (let i = game.bounces.length - 1; i >= 0; i--) {
    const b = game.bounces[i];
    const age = now - b.at;
    if (age > 380) { game.bounces.splice(i, 1); continue; }
    const p = age / 380;
    ctx.strokeStyle = hexA(C.bad, 0.9 * (1 - p));
    ctx.lineWidth = 3;
    circle(b.x, b.y, 6 + p * 18);
    ctx.stroke();
  }

  // particles (task-complete pop)
  for (let i = game.particles.length - 1; i >= 0; i--) {
    const pt = game.particles[i];
    const age = now - pt.at;
    if (age > 600) { game.particles.splice(i, 1); continue; }
    const p = age / 600;
    ctx.save();
    ctx.globalAlpha = 1 - p;
    ctx.fillStyle = pt.color;
    circle(pt.x + pt.vx * p * 60, pt.y + pt.vy * p * 60, 3.5 * (1 - p * 0.5));
    ctx.fill();
    ctx.restore();
  }
}

function spawnBurst(x, y, color = C.sunny, n = 10) {
  for (let i = 0; i < n; i++) {
    const a = (i / n) * Math.PI * 2 + Math.random() * 0.5;
    game.particles.push({
      x, y,
      vx: Math.cos(a) * (0.5 + Math.random()),
      vy: Math.sin(a) * (0.5 + Math.random()) - 0.4,
      at: performance.now(),
      color,
    });
  }
}

// ── overlays ───────────────────────────────────────────────────────────────

function drawMenuOverlay(v) {
  ctx.fillStyle = "rgba(74,53,38,0.5)";
  ctx.fillRect(0, 0, W, H);

  ctx.fillStyle = C.paperSolid;
  rr(W / 2 - 260, 138, 520, 372, 22);
  ctx.fill();
  ctx.strokeStyle = C.ink;
  ctx.lineWidth = 4;
  rr(W / 2 - 260, 138, 520, 372, 22);
  ctx.stroke();

  fitText("SECOND SHIFT", W / 2, 182, 34, 800, C.ink, "center", 1);
  fitText("Her Morning", W / 2, 214, 18, 700, C.terracotta, "center");
  fitText("A marriage, in clicks — the housewife's turn first.", W / 2, 242, 13, 600, C.inkSoft, "center");

  fitText("Dinner won't make itself. The laundry won't fold itself.", W / 2, 290, 14, 600, C.ink, "center");
  fitText("The baby won't change itself. Click a room, follow the glow.", W / 2, 314, 14, 600, C.ink, "center");
  fitText("Wrong clicks never punish. The couch is always hers.", W / 2, 338, 14, 600, C.ink, "center");

  // start button
  const bx = W / 2 - 110, by = 396, bw = 220, bh = 56;
  ctx.fillStyle = C.terracotta;
  rr(bx, by, bw, bh, 16);
  ctx.fill();
  ctx.strokeStyle = C.ink;
  ctx.lineWidth = 4;
  rr(bx, by, bw, bh, 16);
  ctx.stroke();
  fitText("START HER MORNING", W / 2, by + bh / 2, 16, 800, C.paperSolid, "center");
  game.startRect = { x: bx, y: by, w: bw, h: bh };

  fitText("ESC pauses. Everything else is a click.", W / 2, 480, 11, 500, C.inkSoft, "center");
  fitText("His Evening comes next.", W / 2, 496, 11, 600, C.inkSoft, "center");
  void v;
}

function drawPauseOverlay(_v) {
  ctx.fillStyle = "rgba(74,53,38,0.45)";
  ctx.fillRect(0, 0, W, H);
  ctx.fillStyle = C.paperSolid;
  rr(W / 2 - 170, H / 2 - 60, 340, 120, 20);
  ctx.fill();
  ctx.strokeStyle = C.ink;
  ctx.lineWidth = 4;
  rr(W / 2 - 170, H / 2 - 60, 340, 120, 20);
  ctx.stroke();
  fitText("PAUSED", W / 2, H / 2 - 18, 24, 800, C.ink, "center");
  fitText("ESC to keep going", W / 2, H / 2 + 16, 13, 600, C.inkSoft, "center");
}

function drawEndOverlay(v, now) {
  ctx.fillStyle = "rgba(74,53,38,0.55)";
  ctx.fillRect(0, 0, W, H);

  ctx.fillStyle = C.paperSolid;
  rr(W / 2 - 250, 130, 500, 380, 22);
  ctx.fill();
  ctx.strokeStyle = C.ink;
  ctx.lineWidth = 4;
  rr(W / 2 - 250, 130, 500, 380, 22);
  ctx.stroke();

  const won = v.outcome === "won";
  fitText(won ? "THE MORNING HELD" : "THE MORNING WON", W / 2, 178, 28, 800, won ? C.sage : C.bad, "center");
  fitText(`Score ${v.score} / ${v.target}`, W / 2, 216, 16, 700, C.ink, "center");

  // stars earned
  const frac = Math.min(1, v.score / v.target);
  const starCount = frac >= 1 ? 3 : frac >= 0.67 ? 2 : frac >= 0.34 ? 1 : 0;
  for (let i = 0; i < 3; i++) {
    const sx = W / 2 + (i - 1) * 46;
    const earned = i < starCount;
    const pop = Math.min(1, (now - (game.endShownAt || now)) / 200 - i * 0.2);
    if (pop <= 0) continue;
    ctx.save();
    ctx.translate(sx, 260);
    ctx.scale(Math.min(1, pop * 1.3), Math.min(1, pop * 1.3));
    drawStar(0, 0, earned ? 18 : 16, earned ? C.sunny : hexA(C.ink, 0.15));
    ctx.restore();
  }

  // recap lines
  const selfLine = v.selfNeed < 30 ? "she never got her minute" : "she kept a piece of herself";
  const missLine = v.missed === 0 ? "nothing slipped" : `${v.missed} slipped`;
  fitText(selfLine, W / 2, 320, 14, 600, C.ink, "center");
  fitText(missLine, W / 2, 344, 14, 600, C.inkSoft, "center");

  // play again button
  const bx = W / 2 - 100, by = 420, bw = 200, bh = 52;
  ctx.fillStyle = C.terracotta;
  rr(bx, by, bw, bh, 16);
  ctx.fill();
  ctx.strokeStyle = C.ink;
  ctx.lineWidth = 4;
  rr(bx, by, bw, bh, 16);
  ctx.stroke();
  fitText("PLAY AGAIN", W / 2, by + bh / 2, 15, 800, C.paperSolid, "center");
  game.replayRect = { x: bx, y: by, w: bw, h: bh };

  fitText("The house remembers who did the work.", W / 2, 494, 11, 500, C.inkSoft, "center");
}

// ── input: pure point-and-click ────────────────────────────────────────────

function canvasPoint(evt) {
  const r = canvas.getBoundingClientRect();
  const x = ((evt.clientX - r.left) / r.width) * W;
  const y = ((evt.clientY - r.top) / r.height) * H;
  return { x, y };
}

function hitRect(p, r) {
  return r && p.x >= r.x && p.x <= r.x + r.w && p.y >= r.y && p.y <= r.y + r.h;
}

function objectAt(v, p) {
  if (!v?.objects) return null;
  let best = null;
  let bestD = Infinity;
  for (const id of Object.keys(v.objects)) {
    const o = v.objects[id];
    const hw = Math.max(44, o.hitW) / 2;
    const hh = Math.max(44, o.hitH) / 2;
    if (p.x >= o.x - hw && p.x <= o.x + hw && p.y >= o.y - hh && p.y <= o.y + hh) {
      const d = Math.hypot(p.x - o.x, p.y - o.y);
      if (d < bestD) { bestD = d; best = id; }
    }
  }
  return best;
}

canvas.addEventListener("pointermove", (e) => {
  const v = view.live;
  const p = canvasPoint(e);
  game.hover = objectAt(v, p);
  canvas.style.cursor = game.hover ? "pointer" : "default";
});

canvas.addEventListener("pointerdown", (e) => {
  initAudio();
  const v = view.live || demoView(performance.now());
  const p = canvasPoint(e);

  // overlays first
  if (!game.started && game.startRect && hitRect(p, game.startRect)) {
    game.started = true;
    sendAction({ type: "pause" }); // wake the room clock
    return;
  }
  if (v.outcome && game.replayRect && hitRect(p, game.replayRect)) {
    send({ type: "reset" });
    game.started = true;
    return;
  }
  if (game.paused) return;
  if (!view.live) return; // server not with us yet — swallow world clicks

  // kid choice popup?
  if (game.choiceOpen?.kidRect) {
    if (hitRect(p, game.choiceOpen.kidRect.talk)) {
      sendAction({ type: "resolveKid", mode: "talk" });
      game.choiceOpen.kidRect = null;
      playSfx("served", 0.2);
      return;
    }
    if (hitRect(p, game.choiceOpen.kidRect.redirect)) {
      sendAction({ type: "resolveKid", mode: "redirect" });
      game.choiceOpen.kidRect = null;
      playSfx("served", 0.15);
      return;
    }
  }

  // phone answer chip?
  if (v.phone?.state === "ringing" && game.choiceOpen?.phoneRect && hitRect(p, game.choiceOpen.phoneRect)) {
    sendAction({ type: "answer", mode: "slow" }); // default to the warm route
    playSfx("buffer", 0.3);
    return;
  }

  // world click
  const id = objectAt(v, p);
  if (id) {
    sendAction({ type: "click", object: id });
    playSfx("tick", 0.1);
  } else {
    // click the floor: walk there, nearest-object anchor (pathfind-by-room)
    const nearest = nearestObject(v, p);
    if (nearest) sendAction({ type: "click", object: nearest });
  }
});

function nearestObject(v, p) {
  if (!v?.objects) return null;
  let best = null;
  let bestD = Infinity;
  for (const id of Object.keys(v.objects)) {
    const o = v.objects[id];
    const d = Math.hypot(p.x - o.x, p.y - o.y);
    if (d < bestD) { bestD = d; best = id; }
  }
  return bestD < 200 ? best : null;
}

// ESC — the only key in the game.
window.addEventListener("keydown", (e) => {
  if (e.code === "Escape") {
    game.paused = !game.paused;
    if (!game.paused) sendAction({ type: "pause" });
  }
});

// ── server frame handling ──────────────────────────────────────────────────

function onServerState(msg) {
  view.snap = view.live;
  view.live = msg.view;
  view.snapAt = performance.now();
  net.status = msg.status;
  net.meta = msg.meta;
  net.you = msg.you;

  // diff for juice
  const prev = view.snap;
  const cur = view.live;
  if (prev && cur) {
    if (cur.score > prev.score) {
      const delta = cur.score - prev.score;
      game.floatTexts.push({
        x: ruthRender.x, y: ruthRender.y - 96,
        txt: `+${delta}`, at: performance.now(), color: C.sage,
      });
      spawnBurst(ruthRender.x, ruthRender.y - 60, C.sunny, 10);
      playSfx("served", 0.25);
      if (delta >= 4) playSfx("chain", 0.2);
    }
    if (cur.missed > prev.missed) {
      game.shakeT = performance.now();
      game.floatTexts.push({
        x: ruthRender.x, y: ruthRender.y - 96,
        txt: "−", at: performance.now(), color: C.bad,
      });
      playSfx("fail", 0.3);
    }
    if ((cur.phone?.state === "ringing") !== (prev.phone?.state === "ringing") && cur.phone?.state === "ringing") {
      playSfx("alert", 0.35);
    }
    // a task chain advanced?
    for (const key of Object.keys(cur.tasks || {})) {
      const before = prev.tasks?.[key]?.stepIdx;
      const after = cur.tasks[key]?.stepIdx;
      if (before != null && after != null && after > before) {
        spawnBurst(ruthRender.x, ruthRender.y - 70, C.sunny, 6);
      }
    }
  }

  if (msg.view?.outcome && !game.endShownAt) {
    game.endShownAt = performance.now();
    playSfx(msg.view.outcome === "won" ? "chain" : "fail", 0.4);
  }
  if (msg.status === "playing" && !msg.view?.outcome) game.endShownAt = null;
}

function onServerError(err) {
  game.floatTexts.push({
    x: W / 2, y: 100, txt: String(err), at: performance.now(), color: C.bad,
  });
  // Seat problems are fatal for a single-player game — say so out loud.
  if (String(err).includes("spectator")) {
    net.online = false;
    net.status = "waiting";
    game.floatTexts.push({
      x: W / 2, y: 130, txt: "wrong house — refreshing into your own", at: performance.now(), color: C.bad,
    });
    // Force a clean reconnect into the solo room.
    setTimeout(() => { try { socket?.close(); } catch { /* noop */ } connect(); }, 400);
  }
}

// ── main loop ──────────────────────────────────────────────────────────────

function frame(now) {
  // heartbeat: the world only moves when we tell it time passed. The server
  // integrates Ruth's movement per action, so a fast heartbeat is what makes
  // her walk smooth — 150ms keeps position updates flowing at ~7Hz.
  if (!game.paused && net.status === "playing" && !view.live?.outcome) {
    const idleFor = now - lastActionSentAt;
    if (idleFor >= 150) sendAction({ type: "pause" });
  }

  const v = view.live || demoView(now);

  ctx.save();
  // screen shake on a miss
  if (game.shakeT && now - game.shakeT < 300) {
    const p = (now - game.shakeT) / 300;
    ctx.translate(Math.sin(now / 22) * 3 * (1 - p), Math.cos(now / 27) * 2 * (1 - p));
  }

  drawScene(v, now);
  drawRuth(v, now);
  // depth pass: furniture whose base is below her feet re-draws over her
  drawForeground(v, ruthRender.y, now);
  if (v) drawHUD(v, now);

  // offline banner — shows from the very first frame until the server is live
  if (!net.online) {
    const waited = now - (net.firstLoadAt || now);
    ctx.fillStyle = C.paperSolid;
    rr(W / 2 - 150, H - 46, 300, 32, 10);
    ctx.fill();
    ctx.strokeStyle = waited > 6000 ? C.bad : C.ink;
    ctx.lineWidth = 3;
    rr(W / 2 - 150, H - 46, 300, 32, 10);
    ctx.stroke();
    fitText(
      waited > 6000 ? "Still can't reach the house — click to retry" : "Connecting to the house…",
      W / 2, H - 30, 13, 700, waited > 6000 ? C.bad : C.ink, "center",
    );
  }

  ctx.restore();
  requestAnimationFrame(frame);
}

connect();
loadArt();
requestAnimationFrame(frame);
