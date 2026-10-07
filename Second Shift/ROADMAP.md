# Second Shift — build order

Written after the map work kept turning up drift bugs and the sequencing
started to feel wrong. It was. This is what to do instead, in order.

---

## 1. The ordering mistake

The game was built **art first**:

```
art generated  →  coordinates guessed to match it  →  rules built on those coordinates
```

Every map bug so far comes from that one inversion. `sinkNode` stood her in the
sink basin. `stoveNode` stood her on the hob. `toyboxNode` put her inside the
toy box among the bears. The fridge's collision box was `(125,95)-(174,158)`
against art painted at `(139,60)-(217,198)`. None of those are careless
mistakes — they are what you *always* get when coordinates are reverse-engineered
from a picture by eye, because nothing can check them.

The order it should be:

```
layout authored  →  art generated TO the layout  →  geometry DERIVED from the layout
```

The layout becomes the single source of truth, art serves it, and the tables
nobody can verify by eye stop being hand-written at all.

**The practical consequence, and the reason this is worth doing:** you can play
the entire game as coloured boxes before commissioning a single image. Every
layout decision gets tested when it is cheap to change.

---

## 2. What survives, and what does not

Not starting over. The expensive, verified part is independent of the map.

### Keep — proven, and untouched by any of this

| | |
|---|---|
| `scripts/logic.gd` | The rules. 1123 lines, verified byte-identical to the original JavaScript across 1600 steps. |
| `scripts/session.gd` | The tier that replaced the server. |
| `scripts/hud.gd`, `ruth.gd`, `draw_util.gd`, `task_icons.gd` | Renderer and HUD. Read the view; know nothing about the map. |
| `tests/`, `tools/` | 29 tests, the smoke playthrough, the local cutout tool. |
| `TASKS` in `logic_data.gd` | The chain definitions. **These reference prop IDs (`"washer"`, `"basket"`), not coordinates** — so they survive a total map rewrite as long as IDs are kept. |

### Replace — inherited from a generator, never designed

| | |
|---|---|
| `NODES`, `EDGES` | 34 hand-placed walkway nodes. Being deleted, not fixed — see §4. |
| `FOOTPRINTS` | Collision boxes that do not match the art. |
| `OBJECTS` x/y/hit sizes | Clickable positions, drifted off their own art. |
| `assets/art/home.png` | One flat painted image. Becomes floor and walls only. |
| `props.gd`, `foreground.gd` | The occlusion workaround. Y-sorting replaces both. |
| `_draw_nursery` in `world.gd` | ~80 lines drawing a crib and changing table by hand, because they were never in the painted image. Real props delete it. |

---

## 3. The steps

### Phase A — Foundations. No art. Nothing visual changes. ✅ DONE

> **Shipped.** `scripts/levels/her_morning.gd` (the level as data),
> `scripts/nav.gd` (grid, A\*, derived anchors), `scripts/nav_overlay.gd`
> (press **F3** in game), `tests/nav_test.gd`. `logic.gd` routes through Nav;
> `logic_data.gd` lost 224 lines of world tables and keeps only rules.
> **31 tests, 25247 checks, 0 failures.** Anchors inside furniture: 0, derived
> rather than typed. Grid 120×80, 4009 walkable cells, one connected island.

The whole phase runs against the existing `home.png` as a placeholder, so the
game stays playable throughout and every change is verifiable before any art
exists.

**A1. Define the level format.** One file per level describing: world size,
rooms (rect + name), wall rects, and props — `id`, `label`, `station`,
footprint rect (the floor it occupies), art rect, and which side she approaches
from. Nothing else. No nodes, no anchors, no hit boxes: those are all derived.

**A2. Build the walkable grid.** `floor − walls − footprints` → a boolean grid
at 16px cells (60×40 for a 960×640 world). *Done when:* the overlay shows
walkable cells and no cell sits inside a prop.

**A3. Replace the router with A\* over that grid.** 4-connected, so paths stay
strictly orthogonal — the walk keeps exactly the character it has now. *Done
when:* she routes between any two props without clipping furniture.

**A4. Derive the stand-at anchors.** For each prop, the nearest walkable cell on
its approach side. Computed, never typed. *This is the step that kills the
entire bug class* — a generated anchor cannot be inside the furniture, because
the grid excluded the furniture before the anchor was chosen.

**A5. Build the overlay tool.** Draws rooms, footprints, walkable cells, derived
anchors and the current path over the live game. This is the authoring
instrument for Phase B — without it you are back to guessing.

**A6. Tests.** Every prop reachable from every other; every anchor walkable and
adjacent to its prop; no two footprints overlap; every `TASKS` target resolves
to a real prop. Most of `tests/props_test.gd` already does versions of these and
gets rewritten against the new format.

> **Cost, stated plainly:** A3 changes walk paths, so the JavaScript parity
> trace stops matching. That is correct and expected — retire it deliberately
> here rather than letting it rot. `second-shift-js/` stays as a design
> reference. From A3 onward the GDScript tests are the regression net, which is
> why A6 is not optional.

### Phase B — Layout. Still no art.

**B1. Author the floor plan** for Her Morning in the new format. Start from the
current layout as a first draft — the room arrangement is fine, it is the
coordinates that were never trustworthy.

**B2. Iterate against the overlay** until walkability and flow are right.

**B3. Play it as coloured boxes.** Rooms as flat colour, props as labelled
rectangles, Ruth as she is. Run full 150-second rounds. *Done when:* the loop
is fun and the distances feel right **before any art is commissioned.**

This is the step that is normally skipped and the one that saves the most. A
layout mistake found here costs an edit. Found after the art, it costs the art.

### Phase C — Art, generated to the plan.

**C1. Export a blockout reference** from the floor plan: labelled boxes at exact
positions. This is the composition brief.

**C2. Generate the empty room** — floor, walls, windows, doorways. No furniture.

**C3. Generate props individually,** each sized to its footprint in the plan,
each with alpha. A shared style reference across all of them.

**C4. Drop in and y-sort.** Each prop's node origin sits at its floor line,
Ruth's at her feet, and Godot's `y_sort_enabled` handles depth. `props.gd`,
`foreground.gd` and `_draw_nursery` all delete.

> **The real risk in this phase is style consistency** — props generated
> separately drifting apart in palette and line weight. Generate one prop first,
> put it in the scene next to the existing art, and judge before committing to
> the full set. If consistency fails, the fallback is generating the room
> complete and cutting props out with `tools/make_cutout.gd`, which already
> works.

### Phase D — Retune.

**Already needed, and measured.** The same automated playthrough that scored
43/40 with 5 served and 1 missed on the old map now scores **83/40 with 10
served, 0 missed, in fewer clicks**. Routing got materially more efficient —
routes were verified clean (3–5 waypoints, no segment passing through
furniture), so this is real, not a bug. The game is currently far too easy.

Do not fix it yet: retuning against a first-draft floor plan is wasted work.
It lands after Phase B settles the layout.

The numbers tuned against the old map and now wrong:
`PLAYER_SPEED`, each task's `patience` and `spawn` window, `ROUND_SECONDS`,
`TARGET_SCORE`. The smoke test's win/loss margin is the fastest signal.

Then the deferred polish: Ruth's walk smoothing (`1 - exp(-10 * delta)`, tuned
for 7Hz server updates and probably now adding latency), audio levels, HUD.

### Phase E — His Evening.

A level is now data. The second level is a new level file plus props, and props
already made are reusable. `state.level` is already in the rules.

---

## 4. Why the walkway graph gets deleted rather than fixed

The current router is Dijkstra over 34 hand-placed nodes joined by 34
hand-written edges. Every one of those numbers was typed by a person looking at
a picture, and nothing checks them. That is the whole source of the drift.

A generated grid removes the possibility of the error:

- an anchor **cannot** be inside furniture, because the grid subtracted
  furniture before anchors were chosen;
- moving a prop moves its collision, its anchor and its art together, because
  all three come from one rect;
- adding a prop needs no graph surgery — no new nodes, no new edges, no
  checking that the orthogonal invariant still holds.

4-connected A\* keeps the strictly N/S/E/W walk, which is a real part of how the
game reads. What is lost is the hand-tuned corridor routing — the current graph
encodes some deliberate choices about which way she rounds a corner. Expect to
spend time in B2 getting that back, and treat it as a real cost rather than a
detail.

---

## 5. Order of work, condensed

```
A1 level format ──► A2 walkable grid ──► A3 A* router ──► A4 derived anchors
                                                               │
                                          A5 overlay tool ◄─────┤
                                          A6 tests       ◄─────┘
                                                │
                          B1 author plan ──► B2 iterate ──► B3 play as boxes
                                                                    │
                    C1 blockout ──► C2 empty room ──► C3 props ──► C4 y-sort
                                                                    │
                                                    D retune ──► E level 2
```

Phases A and B ship no art and break nothing visual. C is where the look
changes. Do not start C until B3 says the layout is right.
