## Pure-function regression tests for the rules — the six functions exercised
## directly, no scene, no autoloads.
##
## Ported from `tests/logic-offline.test.ts` in the JavaScript export. The wire
## tests that came with it (room.test.ts, secondshift.test.ts, boot.test.ts,
## state.test.ts) covered the WebSocket/Durable-Object tier and went away with
## it; meta.test.ts tested `resolveMeta` in room.ts, which is likewise gone.
##
## These overlap with tools/trace.gd, and that is on purpose: the tracer proves
## the port matches the JavaScript, while these say what the rules are supposed
## to DO. If the JS itself were wrong, the tracer would happily agree with it.
extends TestCase

const Logic := preload("res://scripts/logic.gd")


# ── harness ────────────────────────────────────────────────────────────────

## Advance the world by N seconds, 480 ms at a time — under the 500 ms clamp
## the rules enforce, which is how the real caller has to feed it too.
func idle(s: Dictionary, seconds: float, step_ms := 480.0) -> Dictionary:
	var cur := s
	var remaining := seconds * 1000.0
	while remaining > 0.0:
		var dt: float = minf(step_ms, remaining)
		cur = Logic.apply_action(cur, "ruth", {"type": "pause", "dtMs": dt})
		remaining -= dt
	return cur


func until(s: Dictionary, pred: Callable, cap_sec := 200.0) -> Dictionary:
	var cur := s
	var elapsed := 0.0
	while not pred.call(cur) and elapsed < cap_sec:
		cur = Logic.apply_action(cur, "ruth", {"type": "pause", "dtMs": 480.0})
		elapsed += 0.48
	return cur


func has_queue(s: Dictionary, key: String) -> bool:
	for q in s["queue"]:
		if q["key"] == key:
			return true
	return false


## Send the click, then walk there over `walk_sec` of world time.
func click_at(s: Dictionary, obj: String, walk_sec: float) -> Dictionary:
	var cur := Logic.apply_action(s, "ruth", {"type": "click", "object": obj, "dtMs": 16.0})
	return idle(cur, walk_sec)


func step_of(s: Dictionary, key: String) -> int:
	var ts = s["tasks"].get(key, null)
	return -1 if ts == null else int(ts["stepIdx"])


# ── the tests ──────────────────────────────────────────────────────────────

func test_meta_is_single_player_and_state_is_fresh() -> void:
	var m := Logic.meta()
	eq(m["game"], "Second Shift", "game name")
	eq(m["minPlayers"], 1, "minPlayers")
	eq(m["maxPlayers"], 1, "maxPlayers")

	var s := Logic.setup(["ruth"])
	eq(s["t"], 0.0, "fresh clock")
	eq(s["score"], 0, "fresh score")
	eq(s["roundSeconds"], 150.0, "round length")
	eq(s["target"], 40, "target score")
	eq((s["queue"] as Array).size(), 0, "empty queue")
	eq((s["tasks"] as Dictionary).size(), 0, "no live tasks")
	eq(Logic.is_game_over(s)["over"], false, "not over at t=0")

	var v := Logic.view_for(s, "ruth")
	check(not v.has("rng"), "the rng seed must never reach the view")


func test_dt_is_clamped_to_500ms_per_action() -> void:
	var s0 := Logic.setup(["ruth"])
	var s1 := Logic.apply_action(s0, "ruth", {"type": "pause", "dtMs": 9999.0})
	le(s1["t"], 0.500001, "a huge dt is clamped")
	gt(s1["t"], 0.4, "but still advances")


func test_a_demand_spawns_inside_its_window() -> void:
	var s := until(Logic.setup(["ruth"]), func(x): return (x["queue"] as Array).size() >= 1)
	eq((s["queue"] as Array).size(), 1, "exactly one demand first")
	var q: Dictionary = s["queue"][0]
	check(q["key"] == "cooking" or q["key"] == "laundry", "the first demand is cooking or laundry")
	eq(step_of(s, q["key"]), 0, "its chain waits at step 0")


func test_cooking_chain_completes_through_the_stove_timer() -> void:
	var s := until(Logic.setup(["ruth"]), func(x): return has_queue(x, "cooking"))
	check(has_queue(s, "cooking"), "cooking is on the board")

	s = click_at(s, "fridge", 7)
	eq(step_of(s, "cooking"), 1, "fridge -> step 1")
	s = click_at(s, "counter", 6)
	eq(step_of(s, "cooking"), 2, "chop -> step 2")
	s = click_at(s, "stove", 6)
	eq(step_of(s, "cooking"), 3, "stove -> step 3")
	gt(float(s["tasks"]["cooking"]["timerEnd"]), float(s["t"]), "the cook timer is armed")

	# Let the stove ding, then plate up before the burn window closes.
	s = idle(s, 10)
	is_null(s["tasks"]["cooking"]["timerEnd"], "the timer is consumed on the ding")
	eq(step_of(s, "cooking"), 4, "the ding advances past the wait slot")

	s = click_at(s, "stove", 6)
	eq(step_of(s, "cooking"), 5, "plate -> step 5")
	s = click_at(s, "table", 6)
	is_null(s["tasks"]["cooking"], "serving clears the task")
	check(not has_queue(s, "cooking"), "and takes it off the board")
	ge(float(s["score"]), 8.0, "a clean dinner is worth at least 8")
	eq(s["servedCount"], 1, "one demand served")


func test_burning_dinner_cuts_the_finish_bonus() -> void:
	var s := until(Logic.setup(["ruth"]), func(x): return has_queue(x, "cooking"))
	s = click_at(s, "fridge", 7)
	s = click_at(s, "counter", 6)
	s = click_at(s, "stove", 6)
	# Leave the pan 20s — well past the burn window.
	s = idle(s, 20)
	not_null(s["tasks"]["cooking"]["burnUntil"], "the burn window opened")
	s = click_at(s, "stove", 6)
	eq(s["tasks"]["cooking"]["burned"], true, "plating late chars it")
	s = click_at(s, "table", 6)
	is_null(s["tasks"]["cooking"], "it still serves")
	lt(float(s["score"]), 10.0, "but for less than a clean dinner")


func test_laundry_runs_the_long_chain_with_two_machine_timers() -> void:
	var s := until(Logic.setup(["ruth"]), func(x): return has_queue(x, "laundry"))
	check(has_queue(s, "laundry"), "laundry is on the board")

	s = click_at(s, "basket", 8)
	eq(step_of(s, "laundry"), 1, "basket -> step 1")
	s = click_at(s, "washer", 7)
	eq(step_of(s, "laundry"), 2, "load -> step 2")
	s = click_at(s, "detergent", 6)
	eq(step_of(s, "laundry"), 3, "detergent -> step 3")
	s = click_at(s, "washer", 7)
	eq(step_of(s, "laundry"), 4, "pour -> step 4")
	s = click_at(s, "washer", 5)
	eq(step_of(s, "laundry"), 5, "dial -> step 5, the machine runs")
	gt(float(s["tasks"]["laundry"]["timerEnd"]), float(s["t"]), "wash timer armed")

	s = idle(s, 17)
	is_null(s["tasks"]["laundry"]["timerEnd"], "washer dings")

	s = click_at(s, "washer", 5)
	eq(step_of(s, "laundry"), 7, "unloading wet clothes skips the spent wait slot")
	s = click_at(s, "dryer", 5)
	s = click_at(s, "dryer", 5)
	gt(float(s["tasks"]["laundry"]["timerEnd"]), float(s["t"]), "dry timer armed")
	s = idle(s, 16)
	s = click_at(s, "dryer", 5)
	is_null(s["tasks"]["laundry"], "the chain completes")
	check(not has_queue(s, "laundry"), "and leaves the board")
	eq(s["servedCount"], 1, "one demand served")


func test_chains_are_interruptible() -> void:
	var s := until(Logic.setup(["ruth"]), func(x): return has_queue(x, "laundry"))
	s = click_at(s, "basket", 8)
	s = click_at(s, "washer", 6)
	eq(step_of(s, "laundry"), 2, "two steps in")

	# Wander off to the couch, after the washer pour has finished.
	s = idle(s, 1.2)
	s = click_at(s, "couch", 8)
	not_null(s["tasks"].get("self", null), "she sat down")
	eq(step_of(s, "laundry"), 2, "leaving keeps the half-done chain")
	s = idle(s, 5.5)
	gt(float(s["selfNeed"]), 50.0, "the sit restored her")

	s = click_at(s, "detergent", 9)
	eq(step_of(s, "laundry"), 3, "and the chain resumes where she left it")


func test_a_fast_phone_answer_costs_a_point() -> void:
	var s := until(Logic.setup(["ruth"]), func(x): return x["phone"]["state"] == "ringing")
	ge(float(s["t"]), 27.0, "the first call is not immediate")
	s = Logic.apply_action(s, "ruth", {"type": "answer", "mode": "fast", "dtMs": 60.0})
	eq(s["phone"]["state"], "idle", "answering ends the call")
	le(float(s["score"]), 0.0, "brushing them off costs")
	gt(float(s["phone"]["nextAtT"]), float(s["t"]), "and the next call is scheduled")


func test_an_unanswered_call_escalates_into_the_school_email() -> void:
	var s := until(Logic.setup(["ruth"]), func(x): return x["phone"]["state"] == "ringing")
	s = until(s, func(x): return x["phone"]["state"] == "idle", 30)
	eq(s["phone"]["state"], "idle", "it rang out")
	s = until(s, func(x): return has_queue(x, "email"), 8)
	check(has_queue(s, "email"), "the school writes instead")


func test_the_email_chain_sits_her_down_then_sends() -> void:
	var s := until(Logic.setup(["ruth"]), func(x): return x["phone"]["state"] == "ringing")
	s = until(s, func(x): return has_queue(x, "email"), 30)
	check(has_queue(s, "email"), "the email demand arrived")

	s = click_at(s, "deskChair", 8)
	eq(step_of(s, "email"), 1, "she sits")
	eq(s["player"]["seated"], true, "and is held there")

	s = click_at(s, "monitor", 4)
	eq(step_of(s, "email"), 2, "wake the machine")
	s = click_at(s, "monitor", 6)
	eq(step_of(s, "email"), 3, "type the reply")
	s = click_at(s, "monitor", 4)
	is_null(s["tasks"].get("email", null), "send finishes it")
	eq(s["player"]["seated"], false, "and lets her up")
	eq(s["servedCount"], 1, "one demand served")


func test_the_diaper_chain_runs_baby_to_bin() -> void:
	var s := until(Logic.setup(["ruth"]), func(x): return has_queue(x, "diaper"))
	check(has_queue(s, "diaper"), "the baby needs changing")

	s = click_at(s, "baby", 8)
	eq(step_of(s, "diaper"), 1, "pick the baby up")
	s = click_at(s, "changingTable", 9)
	eq(step_of(s, "diaper"), 2, "lay them down")
	s = click_at(s, "diaperDrawer", 4)
	eq(step_of(s, "diaper"), 3, "fetch a clean one")
	s = click_at(s, "changingTable", 4.5)
	eq(step_of(s, "diaper"), 4, "the change itself")
	s = click_at(s, "bin", 4)
	is_null(s["tasks"].get("diaper", null), "dispose finishes it")
	check(not has_queue(s, "diaper"), "and clears the board")

	# The chain paid out through history even if OTHER demands decayed during
	# the long walks — their misses hit the score too, so score alone lies.
	var awards := 0
	for h in s["history"]:
		var txt: String = h["text"]
		if h["type"] == "diaper" and txt.begins_with("+"):
			awards += int(txt.substr(1, txt.find(" ") - 1))
	ge(float(awards), 9.0, "the diaper chain paid at least its 9 points")
	ge(float(s["servedCount"]), 1.0, "and counted as served")


func test_kids_route_to_their_spot_and_resolve_face_to_face() -> void:
	var s := until(Logic.setup(["ruth"]), func(x): return has_queue(x, "kids"))
	var spot = s["tasks"]["kids"]["kidSpot"]
	not_null(spot, "a kid spot was picked")

	s = click_at(s, spot, 8)
	not_null(s["tasks"].get("kids", null), "kneeling does not resolve it on its own")

	s = Logic.apply_action(s, "ruth", {"type": "resolveKid", "mode": "talk", "dtMs": 60.0})
	is_null(s["tasks"]["kids"], "talking resolves it")
	check(not has_queue(s, "kids"), "and clears the board")
	ge(float(s["score"]), 8.0, "talking is the warmer, better-paid route")


func test_self_need_drains_and_the_couch_refills_it() -> void:
	var s := idle(Logic.setup(["ruth"]), 30)
	lt(float(s["selfNeed"]), 100.0, "it drains on its own")

	s = click_at(s, "couch", 4)
	not_null(s["tasks"].get("self", null), "she sat")
	s = idle(s, 8.0)
	is_null(s["tasks"].get("self", null), "the sit completes")
	gt(float(s["selfNeed"]), 97.0, "and refills her")
	eq(s["score"], 2, "worth the fewest points in the game — that is the point")


func test_the_round_closes_at_150s() -> void:
	var s0 := Logic.setup(["ruth"])

	var late := s0.duplicate(true)
	late["t"] = 149.4
	var lost := idle(late, 1)
	ge(float(lost["t"]), 150.0, "the clock reaches the end")
	eq(lost["outcome"], "lost", "under target is a loss")
	eq(Logic.is_game_over(lost)["over"], true, "and the round is over")

	var late_won := s0.duplicate(true)
	late_won["t"] = 149.4
	late_won["score"] = 41
	var won := idle(late_won, 1)
	eq(won["outcome"], "won", "over target is a win")
	eq(Logic.is_game_over(won)["winner"], "her", "and she is the winner")

	var v := Logic.view_for(won, "ruth")
	check(not v.has("rng"), "the seed still never leaks")
	check(v.has("tasks"), "the view carries task state")
	gt(float((v["taskDefs"]["laundry"]["steps"] as Array).size()), 4.0, "and the chain definitions")


func test_state_stays_json_serializable() -> void:
	var s := idle(Logic.setup(["ruth"]), 20)
	# The whole state must survive a JSON round-trip: that is what let the
	# room persist it, and it is what lets tools/trace.gd diff it against JS.
	var json := JSON.stringify(s)
	check(json != "", "state serializes")
	var back = JSON.parse_string(json)
	check(back is Dictionary, "and parses back to a dictionary")
	close_to(float(back["t"]), float(s["t"]), 0.000001, "the clock round-trips")
	check(back["queue"] is Array, "the queue round-trips as an array")
