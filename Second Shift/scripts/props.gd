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

	# ── NOT LISTED, ON PURPOSE: fridge, stove, sink, toyBox, highChair ─────
	#
	# Each of these BLOCKS her (they have FOOTPRINTS entries) but must not
	# occlude her yet, because her walkway access node is inside the prop's
	# own art rather than on the floor in front of it:
	#
	#   fridgeNode (178, 137)   inside the fridge body      (art y 57..195)
	#   stoveNode  (274, 137)   on top of the hob           (art y 95..195)
	#   sinkNode   (356, 137)   standing in the basin       (art y 100..185)
	#   toyboxNode (877, 473)   inside the toy box          (art y 386..490)
	#
	# Without occlusion she simply draws over them, which reads as "at the
	# stove" at a glance. Switch occlusion on and she is drawn BEHIND a prop
	# she is standing in the middle of — she vanishes completely at the
	# fridge. That is worse than the bug it fixes, so these stay off until
	# their access nodes move onto the floor and their FOOTPRINTS are
	# re-derived from the art. See HANDOFF.md § "The kitchen counter run".
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
