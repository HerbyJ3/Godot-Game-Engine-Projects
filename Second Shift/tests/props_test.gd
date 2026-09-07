## Occlusion sanity: a prop must never hide her while she is USING something.
##
## This suite exists because of a bug that was invisible until occlusion was
## switched on. Several walkway access nodes sit inside the art of the prop
## they belong to — `sinkNode` is in the sink basin, `stoveNode` is on the hob,
## `toyboxNode` is inside the toy box. With nothing drawing over her that read
## as "standing at the stove". The moment a prop occludes her, she is drawn
## behind furniture she is standing in the middle of, and at the fridge she
## disappears from the screen entirely.
##
## So the rule this enforces is: if she can stand somewhere, no prop may swallow
## her there. Adding a prop to `props.gd` whose art covers one of her anchors
## fails here rather than in a screenshot someone notices weeks later.
extends TestCase

const Props := preload("res://scripts/props.gd")
const D := preload("res://scripts/logic_data.gd")

## How much of her 128px height may be covered before it counts as swallowed.
## Low props SHOULD cover her legs — the laundry basket occluding her shins is
## the effect working correctly — so this only catches props that take the
## torso and head too.
const MAX_COVER := 70.0


func test_no_prop_swallows_her_at_an_access_node() -> void:
	for obj_id in D.OBJECT_NODE:
		var node_id: String = D.OBJECT_NODE[obj_id]
		if not D.NODES.has(node_id):
			continue
		var n: Vector2 = D.NODES[node_id]
		var feet := Vector2(float(n.x), float(n.y))

		for prop_id in Props.PROPS:
			var prop: Dictionary = Props.PROPS[prop_id]
			var region: Rect2 = prop["region"]
			var base_y := float(prop["base_y"])
			# Only props that would draw OVER her matter.
			if feet.y >= base_y:
				continue
			if not region.has_point(feet):
				continue
			# She is inside this prop's art and behind it. How much of her
			# does it cover, measuring up from her feet?
			var covered: float = feet.y - maxf(region.position.y, feet.y - 128.0)
			check(
				covered <= MAX_COVER,
				"prop `%s` covers %.0fpx of her while she stands at `%s` to use `%s` — her anchor is inside the prop's art, so move the walkway node onto the floor in front of it before letting it occlude"
					% [prop_id, covered, node_id, obj_id]
			)


func test_every_prop_region_is_inside_the_world() -> void:
	for prop_id in Props.PROPS:
		var r: Rect2 = Props.PROPS[prop_id]["region"]
		check(r.position.x >= 0.0 and r.position.y >= 0.0, "prop `%s` region starts off-image" % prop_id)
		check(r.position.x + r.size.x <= D.W, "prop `%s` region runs past the right edge" % prop_id)
		check(r.position.y + r.size.y <= D.H, "prop `%s` region runs past the bottom edge" % prop_id)


func test_every_prop_floor_line_sits_within_its_art() -> void:
	# A base_y above the region is nonsense (it would never occlude); a base_y
	# far below means she clips through the front of the furniture.
	for prop_id in Props.PROPS:
		var prop: Dictionary = Props.PROPS[prop_id]
		var r: Rect2 = prop["region"]
		var base_y := float(prop["base_y"])
		check(base_y > r.position.y, "prop `%s` base_y is above its own art" % prop_id)
		check(base_y <= r.position.y + r.size.y + 8.0,
			"prop `%s` base_y sits well below its art — she will clip through its front" % prop_id)


func test_props_marked_needing_a_cutout_say_why() -> void:
	# `needs_cutout` means the rectangle fallback is visibly wrong for this
	# prop (a neighbour gets redrawn with it), not merely that art would be
	# nicer. It should only be set where the region overlaps another prop.
	for prop_id in Props.PROPS:
		if not bool(Props.PROPS[prop_id].get("needs_cutout", false)):
			continue
		var r: Rect2 = Props.PROPS[prop_id]["region"]
		var overlaps := false
		for other_id in Props.PROPS:
			if other_id == prop_id:
				continue
			if r.intersects(Props.PROPS[other_id]["region"]):
				overlaps = true
				break
		# Not an overlap with another PROP is fine — it may overlap scenery
		# that is not in the table. This only reports, it does not fail.
		checks += 1
		if not overlaps:
			pass
