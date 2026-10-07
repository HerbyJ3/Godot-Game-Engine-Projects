## Static description of the world: geometry, walkways, furniture and the task
## chains. Ported verbatim from the tables at the top of the original
## `src/logic.js`.
##
## These live apart from `logic.gd` for the same reason they lived at the top of
## logic.js: they are the file you edit to change the GAME, while logic.gd is
## the file you edit to change the RULES. Adding a new demand is a new TASKS
## entry plus art — no engine change.
##
## Everything here is `const`, which in GDScript 4 means the nested dictionaries
## and arrays are read-only at runtime. That is deliberate: the logic layer must
## treat this as immutable, exactly as the JS closure over these tables did.
class_name LogicData
extends RefCounted

# ── world geometry (960 x 640 world units, 3/4-overhead flat) ───────────────

const W := 960.0
const H := 640.0

const ROUND_SECONDS := 150.0
const TARGET_SCORE := 40
const PLAYER_SPEED := 168.0  # world units per second
const ARRIVE_RADIUS := 16.0
const POINTS_PER_SERVE := 2
const CHAIN_WINDOW := 4.0  # s between completions that keeps a CHAIN alive
const CHAIN_BONUS := 2
const SELF_NEED_MAX := 100.0

# Passive own-needs decay. The self-care task must stay the worst value in
# the game — that deferral is the design's point, not a balance bug.
const SELF_DRAIN_PER_SEC := 4.0 / 150.0
const SELF_SERVE_SECONDS := 5.0

# Soft visual pressure only: with the longer round we let demands breathe a
# little so 6+ stay readable. Patience misses still cost.
const PHONE_RING_SECONDS := 14.0
const CALL_GOODWILL_FAST := -1  # quick brush-off — ends the call, costs a point
const CALL_GOODWILL_SLOW := 1   # stays on the line, tiny warm bonus
const KID_REDIRECT_REDUCTION := 4  # redirect respawns the act-up sooner

## Her collision is a small ellipse at her FEET, not a box around her body —
## she may overlap the drawn top of a counter, never its base. `logic.gd`
## slides her along footprint edges with this pad, and `nav.gd` grows the
## blocked rects by it when building the walkable grid, so the two agree.
const FOOT_RX := 4.0
const FOOT_RY := 3.0

# ── what used to live here ─────────────────────────────────────────────────
#
# NODES, EDGES, OBJECT_NODE, OBJECT_FACING, FOOTPRINTS, OBJECTS, STATIONS and
# KID_SPOTS have all moved to `scripts/levels/her_morning.gd`, and the parts of
# them that were derivable — the walkway graph, the stand-at anchors, the
# arrival facings — are not written down at all any more. `scripts/nav.gd`
# computes them from the level.
#
# They were removed rather than corrected. Every number in them was typed by a
# person looking at a picture, with nothing able to check the result, which is
# how her access node for the sink ended up inside the sink basin. See
# ROADMAP.md §4.
#
# What stays here is what is genuinely RULES rather than MAP: the tuning
# constants above, and the task chains below. A chain step names a prop by id
# ("washer", "basket"), never a coordinate, which is why TASKS survived the map
# being replaced underneath it.

# ── TASK chains — all multi-step demands live here as data ─────────────────
# steps[i]:   {target, anim, dur, carryIn?, carryOut?}
# waitAfter[i]: {seconds, bubble?} — a server-side timer after step i resolves;
#               nothing for the player until the bubble pops. A `null` entry in
#               `steps` is that waiting slot: nothing is clickable until the
#               timer dings and the chain advances past it.
# interruptible: leaving mid-chain keeps progress on a half-filled task.

const TASKS := {
	"laundry": {
		"key": "laundry",
		"station": "laundry",
		"label": "Laundry",
		"bubble": "The basket is full again",
		"spawn": [4.0, 7.0],
		"patience": 95.0,
		"decay": 26.0,
		"penalty": 9,
		"points": 8,
		"icon": "laundry",
		"interruptible": true,
		"steps": [
			{"target": "basket", "anim": "grab", "dur": 0.8, "carryOut": "clothes"},
			{"target": "washer", "anim": "pour", "dur": 1.0},
			{"target": "detergent", "anim": "grab", "dur": 0.7, "carryOut": "detergent"},
			{"target": "washer", "anim": "pour", "dur": 1.0},
			{"target": "washer", "anim": "press", "dur": 0.6},
			null,  # timer 1 — the machine runs
			{"target": "washer", "anim": "grab", "dur": 0.9, "carryOut": "wet"},
			{"target": "dryer", "anim": "pour", "dur": 0.9},
			{"target": "dryer", "anim": "press", "dur": 0.6},
			null,  # timer 2
			{"target": "dryer", "anim": "grab", "dur": 0.8},
		],
		"waitAfter": {
			4: {"seconds": 16.0, "bubble": "washer dings"},
			8: {"seconds": 14.0, "bubble": "dryer dings"},
		},
		"stepScore": [0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 6],  # completion lands on the last
	},

	"cooking": {
		"key": "cooking",
		"station": "kitchen",
		"label": "Cooking",
		"bubble": "Dinner won't make itself",
		"spawn": [2.0, 4.0],
		"patience": 65.0,
		"decay": 22.0,
		"penalty": 8,
		"points": 10,
		"icon": "cooking",
		"interruptible": true,
		"steps": [
			{"target": "fridge", "anim": "grab", "dur": 0.8, "carryOut": "ingredients"},
			{"target": "counter", "anim": "chop", "dur": 1.4},
			{"target": "stove", "anim": "cook", "dur": 1.0},
			null,  # cook timer — burn window starts
			{"target": "stove", "anim": "plate", "dur": 0.9, "carryOut": "plated"},
			{"target": "table", "anim": "serve", "dur": 0.7},
		],
		"waitAfter": {
			2: {"seconds": 9.0, "bubble": "dinner is ready", "burnAfter": 8.0},
		},
		"stepScore": [0, 0, 1, 0, 1, 8],
	},

	"diaper": {
		"key": "diaper",
		"station": "laundry",
		"label": "Diaper change",
		"bubble": "The baby needs changing",
		"spawn": [18.0, 30.0],
		"patience": 70.0,
		"decay": 30.0,
		"penalty": 10,
		"points": 9,
		"icon": "diaper",
		"interruptible": true,
		"steps": [
			{"target": "baby", "anim": "grab", "dur": 1.0, "carryOut": "baby"},
			{"target": "changingTable", "anim": "lay", "dur": 0.8},
			{"target": "diaperDrawer", "anim": "grab", "dur": 0.7, "carryOut": "diaper"},
			{"target": "changingTable", "anim": "change", "dur": 1.6},
			{"target": "bin", "anim": "dispose", "dur": 0.7},
		],
		"stepScore": [0, 1, 1, 5, 2],
	},

	"email": {
		"key": "email",
		"station": "office",
		"label": "School email",
		"bubble": "School needs a reply",
		"spawn": [null, null],  # arrives as a phone escalation, never on a timer
		"patience": 90.0,
		"decay": 45.0,
		"penalty": 6,
		"points": 8,
		"icon": "email",
		"interruptible": false,
		"steps": [
			{"target": "deskChair", "anim": "sit", "dur": 0.7},
			{"target": "monitor", "anim": "wake", "dur": 0.9},
			{"target": "monitor", "anim": "type", "dur": 3.6},
			{"target": "monitor", "anim": "send", "dur": 0.5},
		],
		"stepScore": [0, 1, 1, 6],
	},

	"kids": {
		"key": "kids",
		"station": null,  # anchored on a KID_SPOT instance
		"label": "The kids",
		"bubble": "Someone's misbehaving",
		"spawn": [30.0, 46.0],
		"patience": 75.0,
		"decay": 34.0,
		"penalty": 6,
		"points": 6,
		"icon": "kid",
		"interruptible": true,
		# Only step 0 is engine-walked; the resolution is chosen face-to-face.
		"steps": [{"target": null, "anim": "kneel", "dur": 0.8}],
	},

	"self": {
		"key": "self",
		"station": "armchair",
		"label": "A minute of her own",
		"bubble": "Her own needs",
		"passivelyPresent": true,  # always available, lowest value, highest patience
		"patience": 999.0,
		"points": 2,
		"icon": "self",
		"interruptible": true,
		"steps": [{"target": "couch", "anim": "sit", "dur": SELF_SERVE_SECONDS}],
	},
}

## HUD demand-pool order: which task types can be live at once.
const DEMAND_ORDER := ["cooking", "laundry", "diaper", "email", "kids"]
