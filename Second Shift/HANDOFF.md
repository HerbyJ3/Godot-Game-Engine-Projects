# Second Shift — Godot port handoff

Everything below describes work already committed on branch
`claude/game-engine-godot-migration-4nfmon` of
`HerbyJ3/Godot-Game-Engine-Projects`. Read this first when picking the project
back up on another machine.

---

## 1. What this was, and what changed

**Before.** `secondshiftgamesource.zip` — a complete, working browser game built
on an AI platform's **multiplayer** game template:

| File | Role |
|---|---|
| `src/logic.js` (1292 lines) | All game rules, as six pure functions |
| `src/room.ts` (363 lines) | A Cloudflare Durable Object: one room, one WebSocket per player, state persistence |
| `src/worker.ts`, `protocol.ts`, `env.ts` | Worker entry, wire-format validation, bindings |
| `public/client.js` (1644 lines) | The whole renderer: Canvas2D, sprites, depth sorting, HUD, input, WebAudio |
| `public/art/`, `public/audio/` | A painted 960×640 interior, 23 Ruth frames, 7 SFX |
| `tests/` | 60 tests, split between pure logic and real-WebSocket wire tests |

**The key observation.** `meta.maxPlayers` is **1**. The entire server tier
existed because the *template* was multiplayer, not because the game needs it.
A single-player game paid for a Durable Object, a WebSocket, a reconnect loop,
a keepalive ping, and a 150 ms heartbeat to move its own clock.

**After.** A self-contained Godot 4.4 project in `Second Shift/`. The rules run
in-engine, there is no network, and the edit loop is "change GDScript, press
F5". The original JavaScript is kept verbatim at `second-shift-js/` — not as
dead weight, but because the parity harness diffs against it.

### Decisions taken (confirmed before starting)

1. **Native Godot, server dropped** — rather than keeping the Worker and making
   Godot a thin WebSocket client.
2. **Godot 4.4** — not 3.x. The Chapter 2–6 folders in this repo are Godot 3.0
   book code and are untouched.
3. **Top-level `Second Shift/` folder**, matching the repo's folder-per-project
   layout, plus `second-shift-js/` as the reference snapshot.
4. **HUD transcribed, not rebuilt** — the ~600 lines of hand-drawn Canvas2D
   became `_draw()` calls so the look is identical now; converting pieces to
   Control nodes is a later, optional refinement.

---

## 2. What was built

```
Second Shift/
  project.godot            960×640 viewport, canvas_items stretch, GL compatibility
  main.tscn                Main → World(Background, Overlays, Ruth, Foreground) + HUD
  CLAUDE.md                the rules that keep logic.gd pure — read before editing it
  README.md                what the game is
  HANDOFF.md               this file
  scripts/
    logic_data.gd   417 l  world tables: NODES/EDGES, FOOTPRINTS, OBJECTS, TASKS
    logic.gd       1123 l  the six pure functions
    session.gd             autoload — replaced the Durable Object
    audio.gd               autoload — 7 SFX + ambience loop
    main.gd                scene root: view, input routing, juice
    world.gd               nursery props + live overlays
    foreground.gd          depth sorting via re-blitted background rects
    ruth.gd                sprite sets + animation state machine
    hud.gd          411 l  clock, meter, bubbles, phone, kid choice, self bar, overlays
    draw_util.gd           Canvas2D primitives Godot lacks
    task_icons.gd          the 7 procedural demand glyphs
  tests/
    test_case.gd           minimal assertion base (no addon)
    run_tests.gd           the runner
    logic_test.gd          15 rules tests, ported from logic-offline.test.ts
    purity_test.gd         the logic.gd contract + data-table integrity
  tools/
    trace.gd               replays a fixed action script through GDScript
    trace_js.mjs           replays the SAME script through the original JS
    trace_actions.json     1600 fixed actions
    gen_actions.mjs        regenerates the above
    smoke.gd               plays a full round under a virtual display
  assets/art/              home.png + 23 ruth-*.png, copied verbatim
  assets/audio/            7 mp3s, copied verbatim
  assets/fonts/Nunito.ttf  the variable font the HUD's 500/600/700/800 weights need
```

### The hard part: the RNG

`logic.js` uses **mulberry32**, which is defined over 32-bit wrapping integers
and leans on JavaScript's `Math.imul`, `>>>`, and the implicit `ToInt32` that
every bitwise operator applies. GDScript ints are 64-bit and there is no `>>>`.

`logic.gd` makes all of that explicit — `_to_i32`, `_to_u32`, `_ushr`, `_imul`
at the top of the file. **This is the one place where a mistake does not
crash.** A wrong mask produces a perfectly plausible game that spawns demands
at different times, picks different kid spots, and rings the phone on a
different schedule. It is why the parity trace below exists.

### Other translation notes

| JavaScript | GDScript |
|---|---|
| `{...state, x: 1}` | `var next := state.duplicate(); next.x = 1` — the original's `clonePlayer`/`cloneTaskState` helpers were kept, not replaced with blanket deep copies |
| `Math.hypot(dx, dy)` | `_hyp()` in doubles. **Not** `Vector2.length()` — Vector2 is float32 and would break parity |
| `null` slots in `TASKS.steps` | kept as `null`; the wait-slot logic depends on it |
| `Object.entries` / `.find` / `.filter` | plain loops |
| `pending.email == null` | `_nullish()` — "absent OR null", which is not the same as falsy |

`Vector2`/`Vector4` appear **only** in the static tables in `logic_data.gd`,
where every value is an exact small integer and float32 storage is lossless.
Nothing in the state dictionary is anything but a JSON primitive.

---

## 3. What is verified, and how

### a. Parity with the original JavaScript — the strongest evidence

`tools/trace.gd` and `tools/trace_js.mjs` replay the **same** 1600 actions
(`tools/trace_actions.json`) through the two implementations and print one line
per step: clock, RNG seed, score, misses, served count, self-need, restore
timer, position to 9 decimals, order mode, carry, seated, pending target,
facing, working step, queue ids, all pending spawn times, every task's step
index and timer, phone state, chain tracking, and outcome.

**The two outputs are byte-identical across all 1600 steps** — a full 160-second
round covering the RNG stream, the walkway router, chain timers, the phone
escalation into the school email, patience misses and the round close.

```sh
cd "Second Shift"
bun tools/trace_js.mjs > /tmp/js.txt          # or: node tools/trace_js.mjs
godot --headless --path . --script res://tools/trace.gd \
  | grep -v '^Godot Engine' | grep -v '^$' > /tmp/gd.txt
diff /tmp/js.txt /tmp/gd.txt && echo "PARITY OK"
```

Run this after **any** change to `logic.gd` or `logic_data.gd`. A diff that
starts at step N points straight at whatever first executed on that step.

*(If you deliberately change the rules and no longer want parity with the
JavaScript, that is fine — but retire the harness on purpose rather than
letting it rot. It is the only thing that can catch a silent RNG regression.)*

### b. The scene actually plays — `tools/smoke.gd`

Headless Godot never calls `_draw`, so the rendering code needs a real context.
`smoke.gd` boots `main.tscn` under a virtual display and plays a full round by
**following the glow** — clicking whatever object the live chain wants next,
which is exactly the affordance the title card teaches. It then asserts that
the clock advanced, demands spawned, chains completed, the score moved, and the
round closed, and saves screenshots along the way.

A recorded run: **71 clicks, 5 tasks served, 1 missed, score 43/40, round won.**

```sh
xvfb-run -a godot --path "Second Shift" --rendering-driver opengl3 \
  --script res://tools/smoke.gd -- /tmp/shots
```

### c. Rules unit tests — `tests/`

**25 tests, 336 checks, 0 failures, ~150 ms.** 15 ported from `logic-offline.test.ts` (chain progression, the stove burn
window, both laundry machine timers, interruptibility, the phone escalation,
the diaper chain, kid resolution, the self-care bar, the round close, JSON
serializability), plus `purity_test.gd`, which carries over
`scripts/check-logic.mjs`: `logic.gd` must have no clock, no engine RNG, no
I/O, no scene tree, no `await`. It also checks data-table integrity — every
`TASKS` step targets a real object with an access node and a facing, every
`stepScore` lines up with its steps, every `null` step pairs with a `waitAfter`
entry, every object is reachable on the walkway graph, and no walkway node sits
inside a blocked footprint.

```sh
godot --headless --path "Second Shift" --script res://tests/run_tests.gd
```

### Tests that were NOT ported, and why

`room.test.ts` (23), `secondshift.test.ts` (7), `boot.test.ts` (3) and
`state.test.ts` (3) tested the WebSocket/Durable-Object tier — sockets,
hibernation, room isolation, storage — and went away with it. `meta.test.ts`
(9) tested `resolveMeta` in `room.ts`, a compatibility shim for games migrated
from an older engine; also gone. That is 45 of the 60 original tests, all of
them about the server.

---

## 4. Picking this up on Ubuntu

```sh
# Godot 4.4.1, no install needed — it is a single binary
wget https://github.com/godotengine/godot/releases/download/4.4.1-stable/Godot_v4.4.1-stable_linux.x86_64.zip
unzip Godot_v4.4.1-stable_linux.x86_64.zip
sudo mv Godot_v4.4.1-stable_linux.x86_64 /usr/local/bin/godot

# for the smoke test (headless machines only)
sudo apt-get install -y xvfb

# for the parity trace
curl -fsSL https://bun.sh/install | bash     # or use an existing node

git clone https://github.com/HerbyJ3/Godot-Game-Engine-Projects
cd Godot-Game-Engine-Projects
git checkout claude/game-engine-godot-migration-4nfmon
godot --path "Second Shift" --import        # first run generates .godot/
godot --path "Second Shift"                 # play it
```

`.godot/` is gitignored and regenerates on first import.

---

## 5. Known gaps and honest caveats

* **Never run on a real display.** Everything above was verified headless and
  under `xvfb` in a container. The screenshots look right, but nobody has
  played it with a mouse. That is the first thing to do.
* **No audio verification.** The container has no sound device — Godot fell
  back to its dummy driver every run. `audio.gd` loads all seven clips and sets
  the ambience stream to loop, but whether the mix levels feel right is
  unchecked. The old client's per-call volumes were carried over as-is.
* **`bounces` is drawn but never fed.** The red ring for a wrong click exists
  in `hud.gd` and `main.gd` — as it did in the browser build, where it was
  *also* never populated. `logic.gd._resolve_click` genuinely computes a bounce
  and returns it, but the room discarded it. To wire it up, surface the bounce
  as a view event the way `spawn`/`ding`/`fail` already are.
* **A dead branch was ported faithfully.** In `apply_action`, the `click`
  handler tests `order.target`, which nothing ever sets, so the `queuedTarget`
  path is unreachable and every click walks immediately. This is a latent bug
  in the *original*, kept verbatim so the parity trace holds. Fixing it is a
  deliberate rules change: fix it, watch the trace diverge, and retire the
  trace's authority at that point.
* **Dead code not carried over.** `logic.js` had three unused functions —
  `tryAdvanceStep` (always returned `advanced: false`, never called),
  `nearestNodeId`, and `dist`. They are not in `logic.gd`.
* **Depth sorting is the old trick, not `y_sort_enabled`.** `foreground.gd`
  re-blits seven furniture rects from `home.png` over Ruth when her feet are
  above their floor line. The rects are hand-tuned to the painted image.
  Y-sorting only becomes the better answer once each prop is its own texture —
  which is the natural move as you generate more art.
* **The `self` task's `waitAfter` is absent by design.** The couch sit is
  closed by a separate branch at the end of `apply_action`, not by the wait
  timer loop, which explicitly skips `self`. Do not "tidy" that.
* **A parse error in a test file used to hang the runner.** Fixed — `run_tests.gd`
  now reports an unloadable suite and continues. Worth knowing because the
  symptom was a silent timeout with no output, not an error.

---

## 5b. The map geometry fix (done)

Found while adding furniture occlusion, fixed in the same pass. Worth reading
before doing any more work on the map, because the same drift may exist in
props nobody has looked at yet.

**The bug: she was not walking over the furniture. She was standing inside it.**

Several walkway access nodes sit on top of the prop they belong to, rather than
on the floor in front of it:

| Node | Position | Where that actually is |
|---|---|---|
| `sinkNode` | (356, 137) | **in the sink basin** |
| `stoveNode` | (274, 137) | **on the hob** |
| `fridgeNode` | (178, 137) | **inside the fridge body** (art spans y 57–195) |
| `toyboxNode` | (877, 473) | **inside the toy box**, among the bears |

With nothing drawing over her this reads as "standing at the stove" and nobody
notices. The moment a prop occludes her it becomes obvious: she is drawn behind
furniture she is standing in the middle of, and at the fridge she disappears
from the screen entirely. Occlusion did not cause this — it revealed it.

`FOOTPRINTS` has the same drift. The fridge's collision box is
`(125, 95)–(174, 158)`, but the fridge is *painted* at roughly
`(137, 57)–(217, 195)`. The tables were tuned by feel against a game where
furniture never occluded anything, not traced from the art.

### What was changed

The kitchen already had the right corridor at `y = 213`, running along the floor
in front of the counter, so the appliance anchors moved down onto it rather than
somewhere new. `kitchenBL` and `kitchenEntryN` were folded away and the kitchen
became one straight orthogonal run:

```
kitchenEntry(422,177) — kitchenBR(422,213) — sinkNode(380,213)
  — stoveNode(274,213) — fridgeNode(178,213) — { kBLd(178,253), babyTop(100,213) }
```

`sinkNode` sits at x=380 rather than 356 to clear the dining chair painted at
x 327–357. `toyboxNode` moved to (810, 473) — the floor gap between the couch
and the box — which keeps its edge to `couchNode` horizontal, so no extra node
was needed.

`FOOTPRINTS` were then traced from the painted art. The fridge is painted at
x 139–217, y 60–198 but its collision box was `(125,95)–(174,158)`; the toy box
meets the floor at y 515 but stopped at y 466, so she could walk into its front
half. `OBJECTS` had drifted too — the "Sink" clickable was at (369, 87), up on
the backsplash rather than on the basin at (362, 129).

### Why the parity trace still passes

This is a rules change: `NODES`, `FOOTPRINTS` and `OBJECTS` feed the
deterministic simulation, so walk distances and timings all moved — **462 of
the tracer's 1600 steps differ from the pre-change baseline.**

Rather than retire the trace, the *same* table edits were mirrored into
`second-shift-js/src/logic.js`. The two implementations still produce
byte-identical output, which now proves something more useful than before: the
change was purely geometric, with no logic drift smuggled in alongside it.

Keeping the JS reference in step costs about ten lines per table change and is
worth it while the tables are still moving. Once you change actual *rules*
(rather than coordinates), retire it deliberately — do not let it rot.

### The guard that is already in place

`tests/props_test.gd` fails any prop whose art would cover more than 70px of her
128px height at an anchor she can stand on, naming the prop, the node and the
object. Low props are meant to occlude her — the laundry basket covering her
shins is the effect working correctly — so only torso-and-head cases fail.

Verified by re-adding the fridge before the fix: `prop 'fridge' covers 109px of
her while she stands at 'fridgeNode' to use 'fridge'`.

### What still needs a cutout, and what does not

After the fix, the fridge, stove and sink can never occlude her — she stands at
y=213 and they meet the floor at y 188–198, so she is always in front of them.
Occlusion entries for them would never fire, and cutout art for them would never
be drawn. They are deliberately absent from `props.gd`.

The two props that DO want cutouts are the **laundry basket** (she reaches into
it, and it should cover her shins) and the **toy box** (she now stands beside
it; its rectangle also spans the wall above, so the fallback takes a bite out of
her shoulder). Both now have them — see below.

### Making a cutout: `tools/make_cutout.gd`

```sh
godot --headless --path . --script res://tools/make_cutout.gd -- toyBox basket
```

Cuts a prop out of `home.png` into an alpha PNG at `assets/art/props/<id>.png`,
sized to its manifest region, which is all `foreground.gd` needs to start using
it. No service, no network, and it can be re-run after any art change.

It works because the painted art has a dark outline around every object, which
is exactly what a flood fill stops at. It seeds from the region's border pixels
(floor or wall by construction), grows inward while each step stays within
`TOLERANCE` of the pixel it came from, then keeps only the largest connected
component. That last step matters: the fill also stops at the skirting board and
the floor's own line work, so without it you get thin stray streaks and, at the
toy box, a toy car sitting on the floor beside it — all of which would draw over
her as debris.

`TOLERANCE` (0.055) was tuned against the toy box, the hardest case: a light
wooden box against a light wall. Raise it and the fill leaks through soft
outlines; lower it and a halo of floor stays around the prop.

### Why not Higgsfield for this

It was tried first and the generation itself worked — upload via `media_upload`
presigned URLs, `remove_background`, both jobs completed. **The results could not
be retrieved:** this environment's egress policy denies CONNECT to both
`d8j0ntlcm91z4.cloudfront.net` and `d2ol7oe51mr4n9.cloudfront.net`, so the
finished PNGs were unreachable (importing them back with `media_import_url` just
moves them to the other blocked domain).

From a machine without that restriction the Higgsfield route works fine. But for
cutting a prop out of art you already have, the local tool is the better answer
anyway: it uses the original painted pixels rather than a re-rendered
approximation, it is deterministic, and it costs nothing to re-run.

## 6. Suggested next steps

1. **Play it on a real display.** Nothing substitutes for this.
2. **Check the feel of the walk.** The exponential position chase
   (`1 - exp(-10 * dt)`) existed to smooth 7 Hz server updates. At frame rate
   it may now be adding latency rather than removing jitter; try raising the
   constant or removing the chase entirely.
3. **New art drops straight in.** Put PNGs in `assets/art/`. The two places
   that would want it first are the nursery props (currently drawn by hand in
   `world.gd`) and the demand glyphs (`task_icons.gd`) — replacing either with
   textures is a local change.
4. **"His Evening"** — the second level the original was written toward. The
   `level` field is already in the state and `LEVELS` was the intended shape.
   It is a new `TASKS` table plus art, and nothing in the engine has to change.
5. **Export presets.** None are configured. `project.godot` targets GL
   Compatibility, so desktop and web exports should both work once you add
   presets in the editor.
