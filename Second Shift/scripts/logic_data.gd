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

# ── the walkway network (strictly orthogonal: up / down / left / right) ─────
# Ruth never walks through furniture or walls: every click routes over this
# grid, and every edge is axis-aligned, so her path only ever runs N/S/E/W.
# Nodes sit on corridor junctions; each object maps to the access node in
# front of it. Routing is shortest-by-distance (Dijkstra), never fewest hops.

const NODES := {
	# hallway spine (x=475)
	"hallTopUp": Vector2(475, 67),
	"hallTop": Vector2(475, 177),
	"hallMid": Vector2(475, 393),
	"hallLow": Vector2(475, 473),
	"hallBottom": Vector2(475, 600),

	# kitchen: top appliance row (y=137), right entry (x=422), mid corridor (y=213)
	# The appliance anchors sit on the y=213 floor corridor IN FRONT of the
	# counter run, not on the counters themselves. The painted counters end at
	# y~188-198 and the terracotta floor starts at y~200, so this is the first
	# walkable line below them. (They used to be at y=137, which put her
	# standing in the sink basin and on top of the hob — see HANDOFF.md 5b.)
	"fridgeNode": Vector2(178, 213),
	"stoveNode": Vector2(274, 213),
	# Shifted right of the dining chair at x~327-357.
	"sinkNode": Vector2(380, 213),
	"kitchenEntry": Vector2(422, 177),
	"kitchenBR": Vector2(422, 213),
	"kBLd": Vector2(178, 253),
	"tableNode": Vector2(216, 253),
	"babyTop": Vector2(100, 213),
	"babyNode": Vector2(100, 253),

	# office: entry corridor (y=213), desk leg (x=676)
	"officeEntryN": Vector2(544, 177),
	"officeEntry": Vector2(544, 213),
	"chairNode": Vector2(676, 213),
	"deskNode": Vector2(676, 180),
	"kidsDeskNode": Vector2(821, 213),

	# laundry + nursery: main run (y=473), legs down to machines and nursery
	"washerNode": Vector2(99, 473),
	"dryerNode": Vector2(188, 473),
	"basketNode": Vector2(99, 547),
	"nurseryT1": Vector2(330, 473),
	"cribNode": Vector2(330, 507),
	"laundryEntry": Vector2(366, 473),
	"nurseryT2": Vector2(415, 473),
	"changingNode": Vector2(415, 507),
	"nurseryT3": Vector2(462, 473),
	"binNode": Vector2(462, 507),

	# living corner (y=473)
	"livingEntry": Vector2(573, 473),
	"couchNode": Vector2(699, 473),
	# Beside the toy box, in the floor gap between it and the couch — it used
	# to be at x=877, which stood her inside the box among the bears.
	"toyboxNode": Vector2(810, 473),
}

const EDGES := [
	# spine
	["hallTopUp", "hallTop"],
	["hallTop", "hallMid"],
	["hallMid", "hallLow"],
	["hallLow", "hallBottom"],
	# kitchen grid — one straight run along the floor in front of the counters
	["kitchenEntry", "hallTop"],
	["kitchenEntry", "kitchenBR"],
	["kitchenBR", "sinkNode"],
	["sinkNode", "stoveNode"],
	["stoveNode", "fridgeNode"],
	["fridgeNode", "kBLd"],
	["kBLd", "tableNode"],
	["fridgeNode", "babyTop"],
	["babyTop", "babyNode"],
	# office grid
	["officeEntryN", "officeEntry"],
	["officeEntry", "chairNode"],
	["chairNode", "deskNode"],
	["chairNode", "kidsDeskNode"],
	["officeEntryN", "hallTop"],
	# laundry + nursery grid
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
	# living grid
	["hallLow", "livingEntry"],
	["livingEntry", "couchNode"],
	["couchNode", "toyboxNode"],
]

## Which access node each clickable object is used from.
const OBJECT_NODE := {
	"fridge": "fridgeNode",
	"counter": "sinkNode",
	"stove": "stoveNode",
	"cabinet": "stoveNode",
	"kettle": "stoveNode",
	"formula": "tableNode",
	"table": "tableNode",
	"baby": "babyNode",
	"basket": "basketNode",
	"washer": "washerNode",
	"dryer": "dryerNode",
	# the shelf hangs above the washer — she reaches up from in front of it
	"detergent": "washerNode",
	"deskChair": "chairNode",
	"monitor": "deskNode",
	"couch": "couchNode",
	"windowWall": "babyTop",
	"toyBox": "toyboxNode",
	"studyDesk": "kidsDeskNode",
	"crib": "cribNode",
	"changingTable": "changingNode",
	"diaperDrawer": "changingNode",
	"bin": "binNode",
}

## The direction she turns on arrival (from the anchor toward the object).
const OBJECT_FACING := {
	"fridge": "left",
	"counter": "up",
	"stove": "up",
	"cabinet": "up",
	"kettle": "up",
	"formula": "right",
	"table": "right",
	"baby": "right",
	"basket": "left",
	"washer": "up",
	"dryer": "up",
	"detergent": "up",
	"deskChair": "up",
	"monitor": "up",
	"couch": "up",
	"windowWall": "left",
	"toyBox": "up",
	"studyDesk": "down",
	"crib": "down",
	"changingTable": "down",
	"diaperDrawer": "down",
	"bin": "down",
}

# ── blocked footprints: the FLOOR each piece of furniture occupies ──────────
# Base-of-object rectangles (where it meets the floor), not drawn height —
# a tall fridge blocks only the floor under it. Ruth's collision is a small
# ellipse at her FEET; movement slides along footprint edges, never enters.
#
# Stored as Vector4(x0, y0, x1, y1) so the per-step collision scan stays a
# tight loop over packed floats rather than dictionary lookups.

const FOOTPRINTS := {
	# kitchen
	# Traced from home.png: the fridge is painted at x 139-217, y 60-198, the
	# range at x 247-320, y 98-193, and the sink counter at x 320-407,
	# y 110-188. These are the FLOOR strips under them.
	"fridge": Vector4(139, 160, 217, 198),
	"stove": Vector4(247, 160, 320, 193),
	"sink": Vector4(320, 150, 407, 188),
	"table": Vector4(230, 228, 300, 278),
	"windowWall": Vector4(58, 150, 125, 190),
	"babyChair": Vector4(112, 235, 148, 258),
	# laundry + nursery
	"washer": Vector4(77, 405, 147, 466),
	"dryer": Vector4(155, 405, 225, 466),
	"detergent": Vector4(90, 345, 135, 370),
	"basket": Vector4(47, 520, 95, 575),
	"crib": Vector4(296, 523, 364, 567),
	"changing": Vector4(385, 527, 445, 563),
	"bin": Vector4(448, 523, 476, 567),
	# office
	"desk": Vector4(590, 100, 755, 165),
	"deskChair": Vector4(655, 150, 697, 170),
	"studyDesk": Vector4(775, 218, 848, 260),
	# living
	"couch": Vector4(615, 370, 775, 460),
	# The box is painted at x 840-926 and meets the floor at y 515; the old
	# box stopped at y 466 and she could walk into its front half.
	"toyBox": Vector4(840, 422, 926, 515),
}

const FOOT_RX := 4.0  # feet-point pad — she may overlap drawn tops, never bases
const FOOT_RY := 3.0

# ── clickable objects ──────────────────────────────────────────────────────
# hitW/hitH hold the 44x44 minimum; the visible art can be smaller. `station`
# groups the clickable into a room.

const OBJECTS := {
	# KITCHEN (top-left of the painted home)
	"fridge": {"id": "fridge", "station": "kitchen", "x": 178, "y": 129, "hitW": 78, "hitH": 138, "label": "Fridge"},
	"counter": {"id": "counter", "station": "kitchen", "x": 362, "y": 129, "hitW": 84, "hitH": 50, "label": "Sink"},
	"stove": {"id": "stove", "station": "kitchen", "x": 283, "y": 145, "hitW": 73, "hitH": 95, "label": "Stove"},
	"cabinet": {"id": "cabinet", "station": "kitchen", "x": 277, "y": 36, "hitW": 80, "hitH": 42, "label": "Cabinet"},
	"formula": {"id": "formula", "station": "kitchen", "x": 265, "y": 253, "hitW": 44, "hitH": 44, "label": "Kitchen table"},
	"kettle": {"id": "kettle", "station": "kitchen", "x": 293, "y": 80, "hitW": 34, "hitH": 36, "label": "Kettle"},
	"table": {"id": "table", "station": "kitchen", "x": 265, "y": 253, "hitW": 90, "hitH": 62, "label": "Dining table"},
	"baby": {"id": "baby", "station": "kitchen", "x": 128, "y": 223, "hitW": 46, "hitH": 62, "label": "Baby"},

	# LAUNDRY (bottom-left)
	"basket": {"id": "basket", "station": "laundry", "x": 84, "y": 547, "hitW": 74, "hitH": 56, "label": "Laundry basket"},
	"washer": {"id": "washer", "station": "laundry", "x": 112, "y": 435, "hitW": 68, "hitH": 74, "label": "Washer"},
	"dryer": {"id": "dryer", "station": "laundry", "x": 192, "y": 435, "hitW": 68, "hitH": 74, "label": "Dryer"},
	"detergent": {"id": "detergent", "station": "laundry", "x": 112, "y": 360, "hitW": 44, "hitH": 44, "label": "Detergent"},

	# OFFICE (top-right)
	"deskChair": {"id": "deskChair", "station": "office", "x": 666, "y": 172, "hitW": 44, "hitH": 58, "label": "Desk chair"},
	"monitor": {"id": "monitor", "station": "office", "x": 649, "y": 95, "hitW": 44, "hitH": 42, "label": "Monitor"},

	# MY OWN NEEDS (bottom-right)
	"couch": {"id": "couch", "station": "armchair", "x": 695, "y": 414, "hitW": 160, "hitH": 90, "label": "Couch"},

	# NURSERY CORNER (bottom of the laundry room — drawn by the client overlay)
	"crib": {"id": "crib", "station": "laundry", "x": 330, "y": 545, "hitW": 80, "hitH": 60, "label": "Crib"},
	"changingTable": {"id": "changingTable", "station": "laundry", "x": 415, "y": 545, "hitW": 70, "hitH": 56, "label": "Changing table"},
	"diaperDrawer": {"id": "diaperDrawer", "station": "laundry", "x": 415, "y": 500, "hitW": 44, "hitH": 44, "label": "Diaper drawer"},
	"bin": {"id": "bin", "station": "laundry", "x": 462, "y": 545, "hitW": 44, "hitH": 48, "label": "Diaper pail"},

	# KIDS — anchor posts they act out next to
	"windowWall": {"id": "windowWall", "station": "kitchen", "x": 91, "y": 151, "hitW": 66, "hitH": 80, "label": "Window wall"},
	"toyBox": {"id": "toyBox", "station": "armchair", "x": 883, "y": 468, "hitW": 86, "hitH": 93, "label": "Toy box"},
	"studyDesk": {"id": "studyDesk", "station": "office", "x": 810, "y": 233, "hitW": 80, "hitH": 60, "label": "Kids' desk"},
}

## Rooms the client knows how to draw.
const STATIONS := {
	"kitchen": {"key": "kitchen", "room": {"x": 40, "y": 60, "w": 440, "h": 230}, "color": "#E0A95A"},
	"laundry": {"key": "laundry", "room": {"x": 40, "y": 360, "w": 440, "h": 230}, "color": "#7FA6C9"},
	"office": {"key": "office", "room": {"x": 480, "y": 60, "w": 440, "h": 230}, "color": "#C9A24D"},
	"armchair": {"key": "armchair", "room": {"x": 480, "y": 360, "w": 440, "h": 230}, "color": "#D08C96"},
}

## Kid act-up anchor posts, in the order they get picked by the seeded RNG.
const KID_SPOTS := ["windowWall", "studyDesk", "toyBox"]

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
