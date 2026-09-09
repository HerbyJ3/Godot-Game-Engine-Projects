## The map, checked by machine.
##
## These are the assertions that would have caught every geometry bug the
## project hit — an anchor inside the furniture it belongs to, a collision box
## that does not match the art, a room quietly cut off from the rest of the
## house. None of them were checkable while the walkway graph was hand-typed,
## because there was nothing to check it against. Now the level is data and the
## navigation is derived, so all of it is testable.
extends TestCase

const Nav := preload("res://scripts/nav.gd")
const Level := preload("res://scripts/levels/her_morning.gd")
const Rules := preload("res://scripts/logic_data.gd")


func test_the_house_is_one_connected_island() -> void:
	# A room reachable from nowhere is the worst kind of map bug: the game runs,
	# she just never arrives, and the demand times out looking like a balance
	# problem. The doorway rects in FLOORS are what stitch the rooms together.
	var s := Nav.stats()
	gt(float(s["walkable"]), 500.0, "the house has walkable floor at all")
	eq(s["largest_island"], s["walkable"],
		"every walkable cell is reachable from every other — %d of %d are not" % [
			int(s["walkable"]) - int(s["largest_island"]), int(s["walkable"])])


func test_no_anchor_sits_inside_furniture() -> void:
	# The bug that started all of this: sinkNode in the sink basin, stoveNode on
	# the hob, toyboxNode among the teddy bears. It cannot recur — the grid
	# subtracts furniture before an anchor is chosen — so this test is really
	# checking that the derivation is still wired up at all.
	for id in Level.PROPS:
		var a := Nav.anchor(id)
		not_null(a.get("pos", null), "prop `%s` has no derived anchor" % id)
		var pos: Vector2 = a["pos"]
		for other in Level.PROPS:
			var prop: Dictionary = Level.PROPS[other]
			if not bool(prop["blocks"]):
				continue
			check(not (prop["foot"] as Rect2).has_point(pos),
				"the anchor for `%s` at (%d,%d) is inside `%s`" % [id, pos.x, pos.y, other])


func test_every_anchor_is_walkable_and_near_its_prop() -> void:
	for id in Level.PROPS:
		var a := Nav.anchor(id)
		check(Nav.is_walkable(a["cell"]), "the anchor for `%s` is not on walkable floor" % id)
		# Far away means the approach side was blocked and the search wandered.
		var foot: Rect2 = Level.PROPS[id]["foot"]
		var centre := foot.position + foot.size * 0.5
		lt((a["pos"] as Vector2).distance_to(centre), 140.0,
			"the anchor for `%s` is far from it — its approach side is probably blocked" % id)


func test_every_prop_is_reachable_from_every_other() -> void:
	# O(n^2) over 22 props, which is cheap and worth it: this is what catches a
	# prop walled into a corner by a footprint edit.
	var ids: Array = Level.PROPS.keys()
	for a in ids:
		for b in ids:
			if a == b:
				continue
			var from: Vector2 = Nav.anchor(a)["pos"]
			var goal: Vector2i = Nav.anchor(b)["cell"]
			if Nav.anchor(a)["cell"] == goal:
				continue  # two props sharing one anchor, e.g. the desk
			var path := Nav.find_path(from, goal)
			check(path.size() > 0, "no route from `%s` to `%s`" % [a, b])


func test_routes_are_straight_runs_not_staircases() -> void:
	# 4-connected A* over a grid returns one of many equal-length paths, and
	# without a turn cost it happily zigzags across the house. Waypoints are
	# corners, so a staircase shows up as a large count.
	var checks := [["basket", "monitor"], ["fridge", "toyBox"], ["crib", "counter"]]
	for pair in checks:
		var from: Vector2 = Nav.anchor(pair[0])["pos"]
		var goal: Vector2i = Nav.anchor(pair[1])["cell"]
		var path := Nav.find_path(from, goal)
		gt(float(path.size()), 0.0, "route %s -> %s exists" % [pair[0], pair[1]])
		lt(float(path.size()), 10.0,
			"route %s -> %s takes %d turns — the turn cost is not doing its job" % [
				pair[0], pair[1], path.size()])


func test_routes_never_pass_through_furniture() -> void:
	# The waypoint list is what `logic.gd` actually walks her along, in straight
	# lines between corners. A* only guarantees the CELLS are walkable; this
	# checks the straight lines between them are too, which is the thing the
	# player sees. Samples every 4px along each segment.
	var pairs := [["basket", "monitor"], ["basket", "studyDesk"], ["fridge", "toyBox"],
		["crib", "cabinet"], ["couch", "baby"], ["bin", "windowWall"], ["dryer", "couch"]]
	for pair in pairs:
		var from: Vector2 = Nav.anchor(pair[0])["pos"]
		var pts: Array = []
		for p in Nav.find_path(from, Nav.anchor(pair[1])["cell"]):
			pts.append(p)
		pts.append(Nav.anchor(pair[1])["pos"])

		var prev := from
		for target in pts:
			var steps: int = int(prev.distance_to(target) / 4.0) + 1
			for i in range(steps + 1):
				var q: Vector2 = prev.lerp(target, float(i) / float(steps))
				for id in Level.PROPS:
					var prop: Dictionary = Level.PROPS[id]
					if not bool(prop["blocks"]):
						continue
					check(not (prop["foot"] as Rect2).has_point(q),
						"route %s -> %s passes through `%s` at (%d,%d)" % [pair[0], pair[1], id, q.x, q.y])
			prev = target


func test_every_task_step_targets_a_real_prop() -> void:
	# The likeliest way to break the game while adding content: a chain step
	# naming a prop that does not exist. It would sit there un-clickable with
	# no error at all.
	for key in Rules.TASKS:
		var cfg: Dictionary = Rules.TASKS[key]
		for step in cfg["steps"]:
			if step == null or step["target"] == null:
				continue
			check(Level.PROPS.has(step["target"]),
				"TASKS.%s targets unknown prop `%s`" % [key, step["target"]])
	for spot in Level.KID_SPOTS:
		check(Level.PROPS.has(spot), "KID_SPOTS names unknown prop `%s`" % spot)


func test_task_tables_are_internally_consistent() -> void:
	for key in Rules.TASKS:
		var cfg: Dictionary = Rules.TASKS[key]
		if cfg.has("stepScore"):
			eq((cfg["stepScore"] as Array).size(), (cfg["steps"] as Array).size(),
				"TASKS.%s needs one stepScore per step" % key)
		# A null step IS a wait slot; the two must come in pairs or the chain
		# either stalls forever or skips its timer.
		var waits: Dictionary = cfg.get("waitAfter", {})
		for i in (cfg["steps"] as Array).size():
			eq(cfg["steps"][i] == null, waits.has(i - 1),
				"TASKS.%s step %d: null step and waitAfter entry must pair" % [key, i])


func test_props_declare_a_usable_shape() -> void:
	for id in Level.PROPS:
		var prop: Dictionary = Level.PROPS[id]
		var foot: Rect2 = prop["foot"]
		var art: Rect2 = prop["art"]
		gt(foot.size.x, 0.0, "prop `%s` has no footprint width" % id)
		gt(foot.size.y, 0.0, "prop `%s` has no footprint height" % id)
		check(Rect2(Vector2.ZERO, Level.WORLD).encloses(art),
			"prop `%s` art runs outside the world" % id)
		check(["north", "south", "east", "west"].has(prop.get("approach", "south")),
			"prop `%s` has an unknown approach side" % id)
