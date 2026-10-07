## The furniture manifest — what occludes Ruth, and where its feet are.
##
## `home.png` is a single painted image with every prop already composited into
## it. That has one consequence worth stating plainly, because the whole design
## here follows from it:
##
##   **A prop BEHIND her never needs drawing.** The background already shows it.
##   Only a prop she is standing BEHIND has to be redrawn, on top of her.
##
## So there is no Y-sorted scene of sprites and no repainted empty room. There
## is one layer (`foreground.gd`) that redraws a prop when her feet are above
## its floor line, and this table says which props those are.
##
## Each entry can be drawn two ways, and can be upgraded from one to the other
## without touching any code:
##
##   region only     — re-blit that rectangle straight out of home.png. Cheap,
##                     no art, but RECTANGULAR: if she stands beside a prop
##                     with her head inside its rect, her head is erased.
##   + texture       — an alpha cutout of the prop. Per-pixel, so only the
##                     furniture's actual silhouette covers her. Placed at the
##                     region's top-left by default, which means it lands
##                     exactly over its own painted copy in the background —
##                     nothing has to be erased from home.png first.
##
## Adding a cutout is therefore: save the PNG, add one `texture` line. Nothing
## else changes and nothing can regress, because the region fallback stays.
##
## `base_y` is where the prop meets the floor, in world units. Getting it wrong
## is the one thing that looks broken: too low and she clips through the front
## of the furniture, too high and she vanishes behind something she is standing
## in front of.
##
## NOTE: this table is presentation only. Collision lives in
## `logic_data.gd → FOOTPRINTS` and is part of the deterministic rules. If you
## MOVE a prop, both have to move, plus the walkway `NODES` she stands on to
## use it. `tests/props_test.gd` checks the two stay plausible.
class_name Props
extends RefCounted

const DIR := "res://assets/art/props/"

const PROPS := {
	# ── already occluding, via home.png regions (the original seven) ────────
	"kitchenTable": {"region": Rect2(222, 214, 86, 74), "base_y": 285.0},
	"couch": {"region": Rect2(610, 362, 172, 102), "base_y": 462.0},
	"officeDesk": {"region": Rect2(582, 92, 180, 80), "base_y": 168.0},
	"deskChair": {"region": Rect2(642, 135, 62, 70), "base_y": 202.0},
	"studyDesk": {"region": Rect2(766, 196, 90, 70), "base_y": 262.0},
	"washer": {"region": Rect2(72, 398, 80, 74), "base_y": 468.0},
	"dryer": {"region": Rect2(150, 398, 80, 74), "base_y": 468.0},

	# ── the laundry basket: short, and she reaches INTO it ─────────────────
	# Her access node sits inside the basket's art, which for a low prop is
	# exactly right — it occludes her shins and reads as reaching in.
	"basket": {"region": Rect2(40, 508, 66, 70), "base_y": 575.0, "needs_cutout": true},

	# ── the toy box: she now stands BESIDE it, so it occludes her properly ─
	# Painted at x 840-926, meeting the floor at y 515. Her anchor moved to
	# (810, 473), in the gap between the couch and the box, so the box covers
	# the right side of her — which is exactly right. It wants a real cutout:
	# the rectangle also spans the wall above the box, so the fallback takes a
	# bite out of her shoulder.
	"toyBox": {"region": Rect2(838, 386, 90, 132), "base_y": 515.0, "needs_cutout": true},

	# ── NOT LISTED, ON PURPOSE: fridge, stove, sink, highChair ─────────────
	#
	# Each of these BLOCKS her (they have FOOTPRINTS entries) but must not
	# occlude her yet, because her walkway access node is inside the prop's
	# own art rather than on the floor in front of it:
	#
	# Not because of a bug any more — their anchors were moved onto the floor
	# corridor in front of the counter run, so the original problem is fixed.
	# They are absent because occlusion for them is now MOOT: she stands at
	# y=213 and the counters meet the floor at y 188..198, so she is always in
	# front of them and can never be behind one. An entry here would never
	# fire, and a cutout for them would never be drawn.
	#
	# The high chair is the same story at y=253 against a floor line of 262 —
	# marginal, and it covers only her ankles. Left out until it is worth it.
}


## Draw order: farthest floor line first, so a nearer prop covers a farther one
## exactly as the painted image already composites them.
static func sorted_ids() -> Array:
	var ids := PROPS.keys()
	ids.sort_custom(func(a, b): return float(PROPS[a]["base_y"]) < float(PROPS[b]["base_y"]))
	return ids


## The cutout for a prop, or null if it has none yet (fall back to the region).
static func texture_for(id: String) -> Texture2D:
	var path := DIR + id + ".png"
	if not ResourceLoader.exists(path):
		return null
	return load(path)
