## The rules contract, enforced.
##
## This is `scripts/check-logic.mjs` from the JavaScript project, carried over
## because the constraint it guards is exactly why the port was mechanical:
## `logic.gd` must be pure. Same inputs, same outputs. No clock, no RNG source,
## no I/O, no scene tree.
##
## Break it and nothing crashes — the game just stops being reproducible, the
## tracer stops agreeing with the JavaScript, and a saved round stops replaying.
## That failure mode is silent, which is what makes it worth a test.
extends TestCase

const Logic := preload("res://scripts/logic.gd")

const LOGIC_PATH := "res://scripts/logic.gd"
const DATA_PATH := "res://scripts/logic_data.gd"

## Anything that reads the wall clock, the machine's entropy, the filesystem or
## the scene tree. `_rng_next` is the seeded mulberry32 in state and is fine;
## Godot's own `randi`/`randf` are not.
const FORBIDDEN := [
	["Time.", "the rules must not read the clock — time arrives as dtMs"],
	["OS.", "the rules must not touch the OS"],
	["Engine.", "the rules must not read engine state"],
	["randi(", "the rules must not use engine randomness — the seed lives in state"],
	["randf(", "the rules must not use engine randomness — the seed lives in state"],
	["randomize(", "the rules must not reseed — determinism is the whole contract"],
	["RandomNumberGenerator", "the rules must not use engine randomness"],
	["FileAccess", "the rules must not do I/O"],
	["DirAccess", "the rules must not do I/O"],
	["get_tree(", "the rules must not reach the scene tree"],
	["get_node(", "the rules must not reach the scene tree"],
	["await ", "the rules must not be asynchronous"],
	["Timer", "the rules must not use timers — waits are data in TASKS"],
]

const REQUIRED_FUNCS := ["setup", "validate_action", "apply_action", "is_game_over", "view_for"]


func _read(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	return "" if f == null else f.get_as_text()


func test_the_six_entry_points_exist() -> void:
	# Loaded into a Script-typed variable rather than used through the
	# `const Logic := preload(...)` above: a preloaded const is a CLASS
	# reference, and GDScript rejects instance methods on it as static calls.
	var script: Script = load(LOGIC_PATH)
	var names := {}
	for m in script.get_script_method_list():
		names[m["name"]] = true
	for fn in REQUIRED_FUNCS:
		check(names.has(fn), "logic.gd must export %s()" % fn)
	check(script.get_script_constant_map().has("META"), "logic.gd must declare META")


func test_meta_is_sane() -> void:
	var m := Logic.meta()
	check(m.has("game") and String(m["game"]).strip_edges() != "", "meta needs a game name")
	ge(float(m["minPlayers"]), 1.0, "minPlayers >= 1")
	ge(float(m["maxPlayers"]), float(m["minPlayers"]), "maxPlayers >= minPlayers")


func test_the_rules_are_pure() -> void:
	var src := _read(LOGIC_PATH)
	check(src != "", "logic.gd is readable")
	# Strip comments first: this file names most of the forbidden APIs while
	# explaining why they are forbidden, and so does logic.gd's own header.
	var code := PackedStringArray()
	for line in src.split("\n"):
		var stripped := line.strip_edges()
		if stripped.begins_with("#"):
			continue
		var hash_at := line.find("#")
		code.append(line if hash_at < 0 else line.substr(0, hash_at))
	var body := "\n".join(code)

	for rule in FORBIDDEN:
		check(not body.contains(rule[0]), "logic.gd uses `%s` — %s" % [rule[0], rule[1]])


func test_the_data_tables_are_pure_too() -> void:
	var src := _read(DATA_PATH)
	check(src != "", "logic_data.gd is readable")
	check(not src.contains("func "), "logic_data.gd is data only — behaviour belongs in logic.gd")


func test_setup_is_deterministic_for_a_given_player() -> void:
	# Two independent setups with the same id must be byte-identical, and a
	# different id must produce a different morning.
	var a := JSON.stringify(Logic.setup(["ruth"]))
	var b := JSON.stringify(Logic.setup(["ruth"]))
	eq(a, b, "the same player id always gets the same round")
	var c := JSON.stringify(Logic.setup(["someone-else"]))
	check(a != c, "a different player id gets a different round")


func test_apply_action_does_not_mutate_its_input() -> void:
	# The room persisted whatever came back and kept the old state around; the
	# renderer now holds the previous view for diffing. Either way an in-place
	# mutation would corrupt a value someone else is still holding.
	var s := Logic.setup(["ruth"])
	var before := JSON.stringify(s)
	for i in 40:
		Logic.apply_action(s, "ruth", {"type": "pause", "dtMs": 480.0})
	eq(JSON.stringify(s), before, "apply_action left its input untouched")

	var walked := Logic.apply_action(s, "ruth", {"type": "click", "object": "couch", "dtMs": 480.0})
	eq(JSON.stringify(s), before, "a click leaves its input untouched too")
	check(JSON.stringify(walked) != before, "and still returns a changed state")


func test_validate_action_refuses_junk() -> void:
	var s := Logic.setup(["ruth"])
	eq(Logic.validate_action(s, "ruth", {"type": "click", "object": "nope"})["ok"], false, "unknown object")
	eq(Logic.validate_action(s, "ruth", {"type": "nonsense"})["ok"], false, "unknown action type")
	eq(Logic.validate_action(s, "ruth", {"type": "answer", "mode": "slow"})["ok"], false, "answering a quiet phone")
	eq(Logic.validate_action(s, "ruth", {"type": "resolveKid", "mode": "talk"})["ok"], false, "resolving an absent kid")
	eq(Logic.validate_action(s, "ruth", "not a dictionary")["ok"], false, "a non-dictionary action")
	eq(Logic.validate_action(s, "ruth", {"type": "click", "object": "couch"})["ok"], true, "a real click passes")
	eq(Logic.validate_action(s, "ruth", {"type": "pause"})["ok"], true, "a bare heartbeat passes")


func test_every_task_step_targets_a_real_object() -> void:
	# The single most likely way to break the game while adding content: a
	# TASKS entry pointing at an object id that does not exist. It would sit
	# there un-clickable with no error.
	var data := preload("res://scripts/logic_data.gd")
	for key in data.TASKS:
		var cfg: Dictionary = data.TASKS[key]
		for step in cfg["steps"]:
			if step == null or step["target"] == null:
				continue
			var target: String = step["target"]
			check(data.OBJECTS.has(target), "TASKS.%s targets unknown object `%s`" % [key, target])
			check(data.OBJECT_NODE.has(target), "object `%s` has no walkway access node" % target)
			check(data.OBJECT_FACING.has(target), "object `%s` has no arrival facing" % target)
		# A chain scores through stepScore, which must line up with the steps.
		if cfg.has("stepScore"):
			eq((cfg["stepScore"] as Array).size(), (cfg["steps"] as Array).size(),
				"TASKS.%s stepScore must have one entry per step" % key)
		# Every wait slot must be a null step, and every null step a wait slot.
		var waits: Dictionary = cfg.get("waitAfter", {})
		for i in (cfg["steps"] as Array).size():
			var is_null_step: bool = cfg["steps"][i] == null
			var is_wait_slot: bool = waits.has(i - 1)
			eq(is_null_step, is_wait_slot,
				"TASKS.%s step %d: a null step and a waitAfter entry must come in pairs" % [key, i])


func test_every_object_is_reachable_on_the_walkway_graph() -> void:
	# A clickable whose access node is not connected to the rest of the graph
	# would strand her: the router would return a one-node path and she would
	# never arrive.
	var data := preload("res://scripts/logic_data.gd")
	var start := "hallMid"
	for obj_id in data.OBJECTS:
		check(data.OBJECT_NODE.has(obj_id), "object `%s` has no access node" % obj_id)
		if not data.OBJECT_NODE.has(obj_id):
			continue
		var node: String = data.OBJECT_NODE[obj_id]
		check(data.NODES.has(node), "object `%s` names a node `%s` that does not exist" % [obj_id, node])
		var path: Array = Logic._dijkstra(start, node)
		check(path.size() > 0 and path[path.size() - 1] == node,
			"no walkway route from %s to `%s` (%s)" % [start, obj_id, node])


func test_no_object_anchor_stands_inside_furniture() -> void:
	# She stops AT the access node. If that node is inside a blocked footprint
	# the slide-collision would shove her out and she would never "arrive".
	var data := preload("res://scripts/logic_data.gd")
	for node_id in data.NODES:
		var n: Vector2 = data.NODES[node_id]
		is_null(Logic._inside_footprint(float(n.x), float(n.y)),
			"walkway node `%s` sits inside a blocked footprint" % node_id)
