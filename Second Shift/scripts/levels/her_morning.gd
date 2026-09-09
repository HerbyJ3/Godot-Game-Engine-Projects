## "Her Morning" — the level, as data.
##
## This is the SOURCE OF TRUTH for the map. Everything the old `logic_data.gd`
## world tables held by hand — the walkway nodes, the edges, the stand-at
## anchors, the arrival facings — is now derived from this file by `nav.gd`.
## Nothing here is a coordinate anybody has to keep in sync with anything else.
##
## What a prop declares:
##
##   foot     the floor rectangle it occupies AND is used from. For something
##            mounted on a wall or standing on another prop, that is the floor
##            of its HOST, not where it is painted — the cabinet is reached
##            from in front of the stove beneath it, so it borrows the stove's
##            foot. Get this wrong and the anchor lands under the wall.
##   blocks   whether that rectangle is subtracted from the walkable grid.
##            `false` for things that sit ON something else — a kettle on the
##            hob, the diaper drawer under the changing table — which still
##            need somewhere to be used from but block nothing.
##   approach which side of the prop she stands on. Her arrival FACING is the
##            opposite, derived; it is not written down anywhere.
##   art      where the prop is painted, for occlusion and the hover ring.
##   hit      the clickable box, minimum 44x44 enforced by the input router.
##
## STATUS: first draft. The `foot` rects were traced from home.png during the
## geometry fix and are trustworthy. The FLOORS below are a first pass and are
## the thing to refine in Phase B with the overlay (F3 in game) — see ROADMAP.md.
class_name LevelHerMorning
extends RefCounted

const NAME := "Her Morning"
const WORLD := Vector2(960, 640)

## Walkable floor, as overlapping rectangles. The grid is FLOORS minus the
## blocking props, so furniture never has to be excluded by hand.
##
## The two `*Link` rects are doorways: the rooms do not touch the hallway
## directly and without them the house is four disconnected islands. If a room
## becomes unreachable after an edit, this is the first place to look —
## `tests/nav_test.gd` fails loudly rather than letting it ship.
const FLOORS := {
	"kitchen": Rect2(65, 190, 367, 105),
	"hall": Rect2(432, 20, 86, 605),
	"office": Rect2(518, 190, 382, 105),
	"laundry": Rect2(60, 355, 315, 245),
	"laundryLink": Rect2(370, 450, 66, 60),
	"living": Rect2(578, 330, 352, 270),
	"livingLink": Rect2(514, 450, 70, 60),
}

## Rooms, for the HUD and for grouping demands. Purely descriptive.
const STATIONS := {
	"kitchen": {"key": "kitchen", "label": "Kitchen"},
	"laundry": {"key": "laundry", "label": "Laundry"},
	"office": {"key": "office", "label": "Office"},
	"armchair": {"key": "armchair", "label": "Living room"},
}

const PROPS := {
	# ── KITCHEN ────────────────────────────────────────────────────────────
	"fridge": {
		"label": "Fridge", "station": "kitchen", "approach": "south",
		"foot": Rect2(139, 160, 78, 38), "blocks": true,
		"art": Rect2(135, 25, 88, 175), "hit": Vector2(78, 138),
	},
	"stove": {
		"label": "Stove", "station": "kitchen", "approach": "south",
		"foot": Rect2(247, 160, 73, 33), "blocks": true,
		"art": Rect2(245, 95, 78, 100), "hit": Vector2(73, 95),
	},
	"counter": {
		"label": "Sink", "station": "kitchen", "approach": "south",
		"foot": Rect2(320, 150, 87, 38), "blocks": true,
		"art": Rect2(318, 102, 92, 86), "hit": Vector2(84, 50),
	},
	"cabinet": {
		"label": "Cabinet", "station": "kitchen", "approach": "south",
		# mounted on the wall above the stove — reached from the stove's floor
		"foot": Rect2(247, 160, 73, 33), "blocks": false,
		"art": Rect2(237, 15, 80, 42), "hit": Vector2(80, 44),
	},
	"kettle": {
		"label": "Kettle", "station": "kitchen", "approach": "south",
		# sits on the hob
		"foot": Rect2(247, 160, 73, 33), "blocks": false,
		"art": Rect2(276, 62, 34, 36), "hit": Vector2(44, 44),
	},
	"table": {
		"label": "Dining table", "station": "kitchen", "approach": "west",
		"foot": Rect2(230, 228, 70, 50), "blocks": true,
		"art": Rect2(222, 214, 86, 74), "hit": Vector2(90, 62),
	},
	"formula": {
		"label": "Kitchen table", "station": "kitchen", "approach": "west",
		"foot": Rect2(230, 228, 70, 50), "blocks": false,
		"art": Rect2(222, 214, 86, 74), "hit": Vector2(44, 44),
	},
	"baby": {
		"label": "Baby", "station": "kitchen", "approach": "west",
		"foot": Rect2(112, 235, 36, 23), "blocks": true,
		"art": Rect2(104, 196, 56, 66), "hit": Vector2(46, 62),
	},
	"windowWall": {
		"label": "Window wall", "station": "kitchen", "approach": "south",
		"foot": Rect2(58, 150, 67, 40), "blocks": true,
		"art": Rect2(58, 110, 67, 80), "hit": Vector2(66, 80),
	},

	# ── LAUNDRY + NURSERY ──────────────────────────────────────────────────
	"washer": {
		"label": "Washer", "station": "laundry", "approach": "south",
		"foot": Rect2(77, 405, 70, 61), "blocks": true,
		"art": Rect2(72, 398, 80, 74), "hit": Vector2(68, 74),
	},
	"dryer": {
		"label": "Dryer", "station": "laundry", "approach": "south",
		"foot": Rect2(155, 405, 70, 61), "blocks": true,
		"art": Rect2(150, 398, 80, 74), "hit": Vector2(68, 74),
	},
	"detergent": {
		"label": "Detergent", "station": "laundry", "approach": "south",
		# shelf above the washer — she reaches up from in front of the machine
		"foot": Rect2(77, 405, 70, 61), "blocks": false,
		"art": Rect2(88, 340, 50, 32), "hit": Vector2(44, 44),
	},
	"basket": {
		"label": "Laundry basket", "station": "laundry", "approach": "east",
		"foot": Rect2(47, 520, 48, 55), "blocks": true,
		"art": Rect2(40, 508, 66, 70), "hit": Vector2(74, 56),
	},
	"crib": {
		"label": "Crib", "station": "laundry", "approach": "north",
		"foot": Rect2(296, 523, 68, 44), "blocks": true,
		"art": Rect2(292, 518, 76, 54), "hit": Vector2(80, 60),
	},
	"changingTable": {
		"label": "Changing table", "station": "laundry", "approach": "north",
		"foot": Rect2(385, 527, 60, 36), "blocks": true,
		"art": Rect2(382, 520, 66, 48), "hit": Vector2(70, 56),
	},
	"diaperDrawer": {
		"label": "Diaper drawer", "station": "laundry", "approach": "north",
		"foot": Rect2(385, 527, 60, 36), "blocks": false,
		"art": Rect2(390, 528, 50, 20), "hit": Vector2(44, 44),
	},
	"bin": {
		"label": "Diaper pail", "station": "laundry", "approach": "north",
		"foot": Rect2(448, 523, 28, 44), "blocks": true,
		"art": Rect2(444, 518, 36, 54), "hit": Vector2(44, 48),
	},

	# ── OFFICE ─────────────────────────────────────────────────────────────
	"deskChair": {
		"label": "Desk chair", "station": "office", "approach": "south",
		"foot": Rect2(655, 150, 42, 20), "blocks": true,
		"art": Rect2(642, 135, 62, 70), "hit": Vector2(44, 58),
	},
	"monitor": {
		"label": "Monitor", "station": "office", "approach": "south",
		"foot": Rect2(590, 100, 165, 65), "blocks": true,
		"art": Rect2(582, 92, 180, 80), "hit": Vector2(44, 42),
	},
	"studyDesk": {
		"label": "Kids' desk", "station": "office", "approach": "north",
		"foot": Rect2(775, 218, 73, 42), "blocks": true,
		"art": Rect2(766, 196, 90, 70), "hit": Vector2(80, 60),
	},

	# ── LIVING ─────────────────────────────────────────────────────────────
	"couch": {
		"label": "Couch", "station": "armchair", "approach": "south",
		"foot": Rect2(615, 370, 160, 90), "blocks": true,
		"art": Rect2(610, 362, 172, 102), "hit": Vector2(160, 90),
	},
	"toyBox": {
		"label": "Toy box", "station": "armchair", "approach": "west",
		"foot": Rect2(840, 422, 86, 93), "blocks": true,
		"art": Rect2(838, 386, 90, 132), "hit": Vector2(86, 93),
	},
}

## Kid act-up anchor posts, in the order the seeded RNG picks them.
const KID_SPOTS := ["windowWall", "studyDesk", "toyBox"]
