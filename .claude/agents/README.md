# The Second Shift team

Nine specialist agents. This index exists so they get picked on purpose rather
than at random — read the "reach for" column before invoking one.

| Agent | Reach for it when | Model |
|---|---|---|
| `game-designer` | Chains, difficulty, scoring, patience and spawn timing, what a task *means* | opus |
| `gameplay-programmer` | `logic.gd`, `nav.gd`, `session.gd` — the rules and the router | opus |
| `engine-programmer` | Scenes, rendering, Ruth, performance, exports | inherit |
| `ux-designer` | HUD, readability, affordances, onboarding, feedback | opus |
| `art-director` | Any new visual asset, palette, style coherence | opus |
| `audio-designer` | Any new sound, mix levels, which events earn a sound | opus |
| `level-builder` | The floor plan, prop footprints, the F3 overlay | inherit |
| `project-manager` | "What should we do next?", phase order, dependencies | inherit |
| `qa-verify` | Before and after any change — runs everything, reports one line | **haiku** |

## The three rules that bind all of them

**1. All new graphics and audio come from Higgsfield.** No other generator, no
hand-drawn substitutes, no procedural stand-in promoted to final art. If
retrieval is blocked, report the result URLs for manual download — never
quietly substitute something else.

**2. The map is derived, never typed.** Anchors, facings and routes come out of
`nav.gd` from the level data. Hand-editing coordinates to make something look
right is the exact bug class the Phase A rewrite removed; it put her standing
in the sink basin for weeks without anyone noticing.

**3. Art is generated to the layout, never the layout to the art.** This is the
inversion that caused every map bug in the project's history. Phase order in
`ROADMAP.md` exists to enforce it.

## Where the context lives

Every agent is told to read these first. They are short and they are the reason
a cold agent does not have to rediscover the project badly.

- `Second Shift/CLAUDE.md` — the invariants, and how to verify a change
- `Second Shift/ROADMAP.md` — which phase we are in, and what must not start yet
- `Second Shift/HANDOFF.md` — how the project got here, and what is still unverified

## A note on cost

Subagents reduce *this session's context*, not total tokens — each starts cold
and re-derives. They pay off where an agent reads a lot and returns a little.
That is why `qa-verify` runs on Haiku and is forbidden from pasting logs back:
its whole job is turning several hundred lines of engine noise into one line.
