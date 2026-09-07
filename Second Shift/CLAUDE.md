# Second Shift — notes for Claude Code

A Godot 4.4 port of a browser game ("Her Morning", a Delicious/Diner-Dash-style
time-management game). The original was built on an AI platform's **multiplayer**
game template — pure rules in `logic.js`, hosted by a Cloudflare Durable Object
over a WebSocket. The game is single-player, so the port dropped the whole
server tier. The unmodified JavaScript export lives at `../second-shift-js/`.

## Layout

| Path | What it is |
|---|---|
| `scripts/logic.gd` | ALL game rules. A near-literal port of `logic.js`. |
| `scripts/logic_data.gd` | The world tables: walkway graph, footprints, objects, `TASKS`. Data only, no functions. |
| `scripts/session.gd` | Autoload. Replaced the Durable Object: owns state, ticks it, exposes `view()`. |
| `scripts/main.gd` | Scene root: the view, input routing, view-diffing for juice. |
| `scripts/world.gd`, `foreground.gd`, `ruth.gd`, `hud.gd` | Rendering, all `_draw()`. |
| `scripts/draw_util.gd`, `task_icons.gd` | Canvas2D primitives Godot lacks, and the procedural glyphs. |
| `tools/trace.gd`, `tools/trace_js.mjs` | The JS-parity harness. |
| `tools/smoke.gd` | Full playthrough under a virtual display. |

## The rules are pure — keep them that way

`logic.gd` must have no clock, no engine RNG, no I/O, no scene tree, no `await`.
Time arrives only as `dtMs` (clamped to 500 ms); randomness is a seeded
mulberry32 carried in `state.rng`. `tests/purity_test.gd` enforces this.

Two consequences worth remembering before editing it:

* **The RNG is 32-bit.** `_to_i32`, `_ushr` and `_imul` in `logic.gd` reproduce
  JavaScript's implicit `ToInt32`. Break one and nothing crashes — every spawn
  time and kid-spot pick silently changes.
* **State must stay JSON-primitive.** No `Vector2` in state; `Vector2` appears
  only in the static tables, where the values are exact integers.

## Adding a demand

A new task is a new `TASKS` entry in `logic_data.gd` plus art — nothing else.
A `null` in `steps` is a wait slot and must be paired with a `waitAfter` entry
for the preceding index; `stepScore` needs one entry per step. `purity_test.gd`
checks all three.

## Verifying a change

All four run from inside the `Second Shift/` directory:

```sh
godot --headless --path . --import                          # assets + parse
godot --headless --path . --script res://tests/run_tests.gd # unit tests

# JS parity — the two outputs must be byte-identical
bun tools/trace_js.mjs > /tmp/js.txt                        # or: node tools/trace_js.mjs
godot --headless --path . --script res://tools/trace.gd \
  | grep -v '^Godot Engine' | grep -v '^$' > /tmp/gd.txt
diff /tmp/js.txt /tmp/gd.txt && echo "PARITY OK"

# full playthrough; drop `xvfb-run -a` if you have a display
xvfb-run -a godot --path . --rendering-driver opengl3 \
  --script res://tools/smoke.gd -- /tmp/shots
```

If you touched `logic.gd`, run the **parity trace** (HANDOFF.md § Verifying).
It replays 1600 actions through both implementations and diffs them; the two
outputs are currently byte-identical, so any diff is a regression you just made.

Headless mode never calls `_draw`, so rendering changes need the smoke test,
which requires `xvfb-run` and `--rendering-driver opengl3`.
