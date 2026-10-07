## SECOND SHIFT — "Her Morning": all game rules, as six pure functions.
##
## A near-literal port of the original `src/logic.js`. The JS version was
## written against a multiplayer template's contract — no imports, no
## `Date.now()`, no `Math.random()`, a seeded RNG carried in state, and time
## advancing only through a caller-reported `dtMs` (clamped to 500 ms). That
## discipline is exactly what a deterministic simulation needs, so it is kept
## here rather than replaced with `_process` timers and `randi()`.
##
## The six entry points are unchanged: `meta`, `setup`, `validate_action`,
## `apply_action`, `is_game_over`, `view_for`. `Session` (the autoload that
## replaced the Cloudflare Durable Object) is the only caller.
##
## STATE IS JSON-PRIMITIVE. Every value in the state dictionary is a float,
## int, bool, String, Array, Dictionary or null — never a Vector2, never a
## Node. That is what lets `tools/trace.gd` dump a run and diff it against the
## same run under the original JS, which is how this port is verified.
##
## FLOAT PRECISION: GDScript `float` is a double, matching JS numbers. Vector2
## is float32, so it is used ONLY for the static integer coordinate tables in
## LogicData (where it is lossless) and never for arithmetic — distances go
## through `_hyp()` in doubles.
class_name Logic
extends RefCounted

const D := preload("res://scripts/logic_data.gd")
const Level := preload("res://scripts/levels/her_morning.gd")
const Nav := preload("res://scripts/nav.gd")

# ── 32-bit integer arithmetic ──────────────────────────────────────────────
# The RNG below is mulberry32, which is defined over 32-bit wrapping integers.
# GDScript ints are 64-bit and have no `>>>`, so every operation the JS did
# implicitly through ToInt32 has to be done explicitly here. This is the single
# most delicate part of the port: a wrong mask does not crash, it silently
# changes every spawn time, every kid-spot pick, and every phone interval.

const _U32 := 0xFFFFFFFF

static func _to_i32(v: int) -> int:
	v &= _U32
	return v - 4294967296 if v >= 2147483648 else v


static func _to_u32(v: int) -> int:
	return v & _U32


## JS `v >>> n` — unsigned right shift.
static func _ushr(v: int, n: int) -> int:
	return (v & _U32) >> n


## JS `Math.imul(a, b)` — the low 32 bits of the product, as a signed int.
## Both operands are narrowed to signed 32-bit first so the 64-bit product
## cannot overflow (|a*b| <= 2^62); the low 32 bits are the same whether the
## operands are read as signed or unsigned.
static func _imul(a: int, b: int) -> int:
	return _to_i32(_to_i32(a) * _to_i32(b))


# ── seeded RNG (mulberry32) ────────────────────────────────────────────────
# Returns {"roll": float in [0,1), "seed": int} — the caller must carry the new
# seed forward, exactly as the JS did.

static func _rng_next(rng: int) -> Dictionary:
	var s := _to_i32(rng + 0x6d2b79f5)
	var t := s
	t = _imul(t ^ _ushr(t, 15), t | 1)
	t = _to_i32(t ^ _to_i32(t + _imul(t ^ _ushr(t, 7), t | 61)))
	var roll := float(_to_u32(t ^ _ushr(t, 14))) / 4294967296.0
	return {"roll": roll, "seed": s}


static func _roll_range(rng: int, lo: float, hi: float) -> Dictionary:
	var r := _rng_next(rng)
	return {"value": lo + (hi - lo) * float(r["roll"]), "seed": r["seed"]}


static func _roll_int(rng: int, lo: int, hi: int) -> Dictionary:
	var r := _rng_next(rng)
	return {"value": lo + int(floor(float(r["roll"]) * float(hi - lo + 1))), "seed": r["seed"]}


# ── small helpers ──────────────────────────────────────────────────────────

## Distance in doubles. The JS used `Math.hypot`; for coordinates in the low
## hundreds the naive form is bit-identical and considerably faster.
static func _hyp(dx: float, dy: float) -> float:
	return sqrt(dx * dx + dy * dy)


## JS `x == null` (absent OR null), which is a distinct question from `x` being
## falsy — `pending.email` is legitimately 0.0-adjacent once scheduled.
static func _nullish(d: Dictionary, k) -> bool:
	return not d.has(k) or d[k] == null


static func _take_last(arr: Array, n: int) -> Array:
	return arr.slice(maxi(0, arr.size() - n))


## A prop's visual centre — where the glow ring sits and where a bounce rings.
static func _prop_centre(id: String) -> Vector2:
	var art: Rect2 = Level.PROPS[id]["art"]
	return art.position + art.size * 0.5


## The clickable list the renderer draws, derived from the level. Kept in the
## shape the browser client used (x/y/hitW/hitH) so the HUD and the input
## router did not have to change when the map system was replaced.
static func _objects_view() -> Dictionary:
	var out := {}
	for id in Level.PROPS:
		var prop: Dictionary = Level.PROPS[id]
		var centre := _prop_centre(id)
		var hit: Vector2 = prop["hit"]
		out[id] = {
			"id": id, "station": prop["station"], "label": prop["label"],
			"x": centre.x, "y": centre.y, "hitW": hit.x, "hitH": hit.y,
		}
	return out


static func _empty_order() -> Dictionary:
	return {"mode": "idle", "to": null, "path": []}


static func _pt(x: float, y: float) -> Dictionary:
	return {"x": x, "y": y}


static func _push_history(state: Dictionary, entry) -> Array:
	var base: Array = state.get("history", [])
	var history := base.duplicate()
	if entry != null:
		history.append(entry)
	return _take_last(history, 24)


static func _clone_player(p: Dictionary) -> Dictionary:
	var order = p.get("order", null)
	var cloned_order: Dictionary
	if order:
		var path_in: Array = order.get("path", [])
		var path_out := []
		for pt in path_in:
			path_out.append((pt as Dictionary).duplicate())
		var to_in = order.get("to", null)
		cloned_order = {
			"mode": order.get("mode", "idle"),
			"to": (to_in as Dictionary).duplicate() if to_in != null else null,
			"path": path_out,
		}
	else:
		cloned_order = _empty_order()
	var working = p.get("working", null)
	return {
		"x": p["x"],
		"y": p["y"],
		"order": cloned_order,
		"queuedTarget": p.get("queuedTarget", null),
		"anim": p.get("anim", null),
		"busyUntil": p.get("busyUntil", 0.0),
		"working": (working as Dictionary).duplicate() if working != null else null,
		"facing": p.get("facing", "down"),
		"carrying": p.get("carrying", null),
		"seated": bool(p.get("seated", false)),
		# object id to resolve on arrival
		"pendingResolve": p.get("pendingResolve", null),
	}


static func _clone_task_state(ts) -> Variant:
	if ts == null:
		return null
	var t: Dictionary = ts
	return {
		"key": t["key"],
		"queueId": t.get("queueId", null),
		"stepIdx": t["stepIdx"],
		"carry": t.get("carry", null),
		"timerEnd": t.get("timerEnd", null),
		"burnUntil": t.get("burnUntil", null),
		"burned": bool(t.get("burned", false)),
		"kidSpot": t.get("kidSpot", null),
		"draft": t.get("draft", null),
	}


static func _clone_tasks(tasks: Dictionary) -> Dictionary:
	var out := {}
	for k in tasks:
		out[k] = _clone_task_state(tasks[k])
	return out


# ── the walkway network ────────────────────────────────────────────────────
# Deleted. Routing used to be Dijkstra over 34 hand-placed nodes joined by 34
# hand-written edges, every number typed by a person looking at a picture with
# nothing to check them — which is how `sinkNode` came to stand her in the sink
# basin. `nav.gd` now derives the grid, the routes and the stand-at anchors
# from the level data. See ROADMAP.md §4.

# ── blocked footprints ─────────────────────────────────────────────────────

## The floor rectangle she is standing in, or null. Base-of-object rectangles
## only: a tall fridge blocks the floor under it, not the wall above it.
static func _inside_footprint(x: float, y: float) -> Variant:
	for id in Level.PROPS:
		var prop: Dictionary = Level.PROPS[id]
		if not bool(prop["blocks"]):
			continue
		var f: Rect2 = prop["foot"]
		if (
			x + D.FOOT_RX > f.position.x
			and x - D.FOOT_RX < f.end.x
			and y + D.FOOT_RY > f.position.y
			and y - D.FOOT_RY < f.end.y
		):
			return f
	return null


## Move with slide: try the full step; if blocked, keep the axis component that
## stays on walkable floor so she slides along the edge instead of stopping.
static func _slide_move(px: float, py: float, nx: float, ny: float) -> Dictionary:
	if _inside_footprint(nx, ny) == null:
		return _pt(nx, ny)
	if _inside_footprint(nx, py) == null:
		return _pt(nx, py)  # slide horizontally
	if _inside_footprint(px, ny) == null:
		return _pt(px, ny)  # slide vertically
	return _pt(px, py)  # fully blocked — stay


# ── queue management ───────────────────────────────────────────────────────

## Timed demand spawn windows live on the type so a task starts "not yet here"
## and ticks in. Self-care never spawns — it is always there if she sits.
static func _initial_pending(rng_state: int) -> Dictionary:
	var rng := rng_state
	var pending := {}
	for key in ["cooking", "laundry"]:
		var spawn: Array = D.TASKS[key]["spawn"]
		var r := _roll_range(rng, spawn[0], spawn[1])
		rng = r["seed"]
		pending[key] = r["value"]
	for key in ["diaper", "kids"]:
		var spawn: Array = D.TASKS[key]["spawn"]
		var r := _roll_range(rng, spawn[0], spawn[1])
		rng = r["seed"]
		pending[key] = r["value"]
	return {"pending": pending, "rng": rng}


## Put a demand on the board. Returns only the fields it changes; callers merge.
static func _enqueue(queue: Array, tasks: Dictionary, rng: int, key: String, t: float) -> Dictionary:
	var cfg: Dictionary = D.TASKS[key]
	var item := {
		"id": "%s-%d" % [key, int(round(t * 1000.0))],
		"key": key,
		"station": cfg["station"],
		"bornT": t,
		"expiresT": t + float(cfg["patience"]),
		"penalty": cfg["penalty"],
	}
	var next_queue := queue.duplicate()
	next_queue.append(item)
	var next_tasks := tasks.duplicate()
	next_tasks[key] = {
		"key": key,
		"queueId": item["id"],
		"stepIdx": 0,
		"carry": null,
		"timerEnd": null,
		"burned": false,
	}
	if key == "kids":
		var pick := _roll_int(rng, 0, Level.KID_SPOTS.size() - 1)
		var kids: Dictionary = next_tasks["kids"]
		kids["kidSpot"] = Level.KID_SPOTS[pick["value"]]
		return {"queue": next_queue, "tasks": next_tasks, "rng": pick["seed"]}
	return {"queue": next_queue, "tasks": next_tasks, "rng": rng}


## When this demand type comes back. A "kids" demand that was only redirected
## acts up sooner.
static func _schedule_next(rng: int, pending: Dictionary, kids_quick: bool, key: String, t: float) -> Dictionary:
	var r := _roll_range(rng, 0.85, 1.15)
	var mult := 0.45 if (kids_quick and key == "kids") else 1.0
	var next_at := t + float(D.TASKS[key]["decay"]) * float(r["value"]) * mult
	var next_pending := pending.duplicate()
	next_pending[key] = next_at
	return {"rng": r["seed"], "pending": next_pending}


# ── the world tick ─────────────────────────────────────────────────────────

static func _tick(state: Dictionary, dt_sec: float) -> Dictionary:
	var t := float(state["t"]) + dt_sec
	var rng: int = state["rng"]
	var score: int = state["score"]
	var missed: int = state["missed"]
	var served_count: int = state["servedCount"]
	var self_need := float(state["selfNeed"])
	var restore_t := maxf(0.0, float(state["restoreT"]) - dt_sec)
	var player := _clone_player(state["player"])
	var queue := []
	for q in state["queue"]:
		queue.append((q as Dictionary).duplicate())
	var pending: Dictionary = (state["pending"] as Dictionary).duplicate()
	var tasks := _clone_tasks(state["tasks"])
	var phone: Dictionary = (state["phone"] as Dictionary).duplicate()
	var kids_quick_return: bool = state["kidsQuickReturn"]
	var history: Array = (state.get("history", []) as Array).duplicate()
	var events: Array = (state.get("events", []) as Array).duplicate()  # transient, view-only

	# ── phone: rings on its own cycle and is what wakes the email task.
	if phone["state"] == "ringing" and t >= float(phone["untilT"]):
		# Missed call — the school rings back, angrier, as the email demand.
		phone = {
			"state": "idle",
			"nextAtT": t + 45.0 + float(_rng_next(rng)["roll"]) * 20.0,
			"untilT": 0.0,
			"caller": null,
		}
		rng = _to_i32(rng + 1)
		if _nullish(pending, "email") and _nullish(tasks, "email"):
			var res := _enqueue(queue, tasks, rng, "email", t)
			queue = res["queue"]
			tasks = res["tasks"]
			rng = res["rng"]
			history.append({"tSec": int(round(t)), "type": "phone", "text": "missed call — school writes instead"})
	elif phone["state"] == "idle" and t >= float(phone["nextAtT"]):
		# Marriage-theme callers: the husband checks in, the mother-in-law has
		# opinions, the sister needs a favor.
		var callers := ["husband", "mother-in-law", "sister"]
		var pick := _roll_int(rng, 0, callers.size() - 1)
		rng = pick["seed"]
		phone = {
			"state": "ringing",
			"untilT": t + D.PHONE_RING_SECONDS,
			"caller": callers[pick["value"]],
			"nextAtT": 0.0,
		}
		events.append({"kind": "phoneRing", "at": t})

	# ── passive SELF bar drain (slows right after she actually sat).
	var self_rate := D.SELF_DRAIN_PER_SEC * (0.6 if restore_t > 0.0 else 1.0)
	var anim = player["anim"]
	var seated_self: bool = bool(player["seated"]) and anim != null and anim.get("task", "") == "self"
	if not seated_self:
		self_need = maxf(0.0, self_need - self_rate * dt_sec)

	# ── spawns.
	for key in D.DEMAND_ORDER:
		if key == "email":
			continue  # email only arrives off a missed call
		var already := false
		for q in queue:
			if q["key"] == key:
				already = true
				break
		if not already and not _nullish(tasks, key):
			already = true
		if not already and not _nullish(pending, key) and t >= float(pending[key]):
			var res := _enqueue(queue, tasks, rng, key, t)
			queue = res["queue"]
			tasks = res["tasks"]
			rng = res["rng"]
			events.append({"kind": "spawn", "key": key, "at": t})

	# ── patience drain.
	var kept := []
	for q in queue:
		if t >= float(q["expiresT"]):
			missed += 1
			var penalty: int = q["penalty"]
			score = maxi(0, score - penalty)
			var qkey: String = q["key"]
			var label: String = D.TASKS[qkey]["label"]
			history.append({
				"tSec": int(round(t)),
				"type": qkey,
				"text": "%s slipped –%d" % [label.to_lower(), penalty],
			})
			events.append({"kind": "fail", "key": qkey, "at": t, "points": penalty})
			# kids' mess stays as a follow-up cleanup
			if qkey == "kids":
				kids_quick_return = true
			tasks[qkey] = null
			var sched := _schedule_next(rng, pending, kids_quick_return, qkey, t)
			rng = sched["rng"]
			pending = sched["pending"]
			continue
		kept.append(q)
	queue = kept

	# ── movement along the current route, waypoint by waypoint, sliding along
	# any blocked footprint edge instead of entering it.
	var order: Dictionary = player["order"]
	if order["mode"] == "walk" and order["to"] != null:
		var to: Dictionary = order["to"]
		var dx := float(to["x"]) - float(player["x"])
		var dy := float(to["y"]) - float(player["y"])
		var d := _hyp(dx, dy)
		var step := D.PLAYER_SPEED * dt_sec
		if d <= maxf(step, D.ARRIVE_RADIUS * 0.5):
			var snapped := _slide_move(player["x"], player["y"], to["x"], to["y"])
			player["x"] = snapped["x"]
			player["y"] = snapped["y"]
			# Next waypoint, or done.
			var rest: Array = order["path"]
			if rest.size() > 0:
				player["order"] = {
					"mode": "walk",
					"to": (rest[0] as Dictionary).duplicate(),
					"path": rest.slice(1),
				}
			else:
				player["order"] = _empty_order()
		elif d > 0.0001:
			var nx := clampf(float(player["x"]) + (dx / d) * step, 20.0, D.W - 20.0)
			var ny := clampf(float(player["y"]) + (dy / d) * step, 20.0, D.H - 20.0)
			var moved := _slide_move(player["x"], player["y"], nx, ny)
			player["x"] = moved["x"]
			player["y"] = moved["y"]

	# ── anim housekeeping: a display-only anim (kneel etc.) ends on its own.
	# A WORKING anim is cleared by the commit, never here.
	if player["anim"] != null and player["working"] == null and float(player["busyUntil"]) > 0.0 and t >= float(player["busyUntil"]):
		player["anim"] = null
		player["busyUntil"] = 0.0

	# ── wait-timers (washer runs, dinner cooks, dry cycle). The self-sit has
	# its own completion path in apply_action and must not be eaten here.
	for key in tasks:
		if key == "self":
			continue
		var ts = tasks[key]
		if ts == null or ts["timerEnd"] == null:
			continue
		var cfg: Dictionary = D.TASKS[key]
		var wait_after: Dictionary = cfg.get("waitAfter", {})
		var slot: int = int(ts["stepIdx"]) - 1
		if not wait_after.has(slot):
			ts["timerEnd"] = null
			continue
		var wait: Dictionary = wait_after[slot]
		if t >= float(ts["timerEnd"]):
			# The bubble that tells her the machine dinged; the timer slot is
			# consumed and the chain advances to the next clickable step.
			events.append({"kind": "ding", "key": key, "at": t})
			ts["stepIdx"] = int(ts["stepIdx"]) + 1
			# Burning: the stove gives a short grace window before the pan chars.
			if wait.has("burnAfter") and key == "cooking":
				ts["burnUntil"] = t + float(wait["burnAfter"])
			ts["timerEnd"] = null

	var next := state.duplicate()
	next["t"] = t
	next["rng"] = rng
	next["score"] = score
	next["missed"] = missed
	next["servedCount"] = served_count
	next["queue"] = queue
	next["pending"] = pending
	next["tasks"] = tasks
	next["player"] = player
	next["selfNeed"] = self_need
	next["restoreT"] = restore_t
	next["phone"] = phone
	next["kidsQuickReturn"] = kids_quick_return
	next["history"] = _take_last(history, 24)
	next["events"] = _take_last(events, 24)
	return next


# ── chain progression ──────────────────────────────────────────────────────
# A click intent targets an OBJECT; once she is in range we ask the task engine
# whether this object is the next expected step. Correct click → the step runs
# (an animation with a duration), maybe a timer arms, maybe points tick. Wrong
# click → a soft bounce, no penalty.

## Resolve a click at an object — she has already arrived; decide what the
## click means against live tasks. Returns {state, acted, bounce?, ding?}.
static func _resolve_click(state: Dictionary, object_id: String) -> Dictionary:
	if not Level.PROPS.has(object_id):
		return {"state": state, "acted": false}
	var obj_centre := _prop_centre(object_id)
	var next := state

	if object_id == "couch":
		# The couch is always hers — she can sit whenever she isn't already
		# there. The engine still gates the restore on the bar being
		# meaningfully drained, so clicking it mid-full does nothing.
		if not bool(next["player"]["seated"]) and _nullish(next["tasks"], "self") and float(next["selfNeed"]) < D.SELF_NEED_MAX:
			var player := _clone_player(next["player"])
			player["seated"] = true
			player["anim"] = {"task": "self", "kind": "sit", "startedAt": next["t"]}
			player["busyUntil"] = float(next["t"]) + D.SELF_SERVE_SECONDS
			var tasks: Dictionary = (next["tasks"] as Dictionary).duplicate()
			tasks["self"] = {
				"key": "self",
				"stepIdx": 0,
				"carry": null,
				"timerEnd": float(next["t"]) + D.SELF_SERVE_SECONDS,
				"queueId": null,
				"kidSpot": null,
				"burned": false,
				"draft": null,
			}
			next = next.duplicate()
			next["player"] = player
			next["tasks"] = tasks
		return {"state": next, "acted": true}

	# Live kid acting-up at this spot?
	var kids = next["tasks"].get("kids", null)
	if kids != null and kids["kidSpot"] == object_id:
		var kid_queued := false
		for q in next["queue"]:
			if q["key"] == "kids":
				kid_queued = true
				break
		if kid_queued:
			var player := _clone_player(next["player"])
			player["seated"] = false
			player["anim"] = {"task": "kids", "kind": "kneel", "startedAt": next["t"]}
			player["busyUntil"] = float(next["t"]) + 0.7
			next = next.duplicate()
			next["player"] = player
			return {"state": next, "acted": true, "kidChoice": true}

	# Live chainable task routed to this object?
	var hit = null
	for key in next["tasks"]:
		var ts = next["tasks"][key]
		if ts == null or key == "self" or key == "kids":
			continue
		var queued := false
		for q in next["queue"]:
			if q["key"] == key:
				queued = true
				break
		if not queued:
			continue
		var steps: Array = D.TASKS[key]["steps"]
		var idx: int = ts["stepIdx"]
		if idx < 0 or idx >= steps.size():
			continue
		var step_def = steps[idx]
		if step_def == null:
			continue  # wait slot — nothing clickable until the timer dings
		if step_def["target"] == object_id:
			hit = {"key": key, "ts": ts, "stepDef": step_def}
			break

	if hit != null:
		var key: String = hit["key"]
		var ts: Dictionary = hit["ts"]
		var step_def: Dictionary = hit["stepDef"]
		# Email is uninterruptible: once she's seated at the desk, clicks
		# elsewhere are bounces.
		if key != "email" and bool(next["player"]["seated"]) and not _nullish(next["tasks"], "email"):
			return {"state": next, "acted": false, "bounce": _pt(obj_centre.x, obj_centre.y)}
		# ARRIVING → WORKING: she has stopped at the anchor, turns to face the
		# object, and the step runs for its full duration. Nothing commits until
		# the work FINISHES (_commit_work) — walking away abandons the step with
		# no progress and no points.
		var player := _clone_player(next["player"])
		player["anim"] = {"task": key, "kind": step_def["anim"], "startedAt": next["t"]}
		player["busyUntil"] = float(next["t"]) + float(step_def["dur"])
		player["facing"] = Nav.facing_for(object_id)
		player["working"] = {
			"key": key,
			"stepIdx": ts["stepIdx"],
			"objectId": object_id,
			"endsAt": float(next["t"]) + float(step_def["dur"]),
		}
		next = next.duplicate()
		next["player"] = player
		return {
			"state": next,
			"acted": true,
			"ding": {"key": key, "stepIdx": ts["stepIdx"], "completes": false},
		}

	return {"state": next, "acted": false, "bounce": _pt(obj_centre.x, obj_centre.y)}


## The work FINISHED: commit the step — advance the chain, award points, arm
## wait timers, complete the task. Runs from `apply_action` when t passes
## `working.endsAt` and she is still standing at the anchor.
static func _commit_work(state: Dictionary) -> Dictionary:
	var working = state["player"]["working"]
	if working == null:
		return state
	var key: String = working["key"]
	var step_idx: int = working["stepIdx"]
	var ts = state["tasks"].get(key, null)
	var cfg = D.TASKS.get(key, null)

	# The task may have expired mid-work, or the state may have moved on.
	if ts == null or cfg == null or int(ts["stepIdx"]) != step_idx:
		var cleared := _clone_player(state["player"])
		cleared["working"] = null
		cleared["anim"] = null
		cleared["busyUntil"] = 0.0
		var out := state.duplicate()
		out["player"] = cleared
		return out

	var step_def: Dictionary = cfg["steps"][step_idx]
	var t := float(state["t"])

	var player := _clone_player(state["player"])
	player["working"] = null
	player["anim"] = null
	player["busyUntil"] = 0.0
	if step_def.has("carryOut"):
		player["carrying"] = step_def["carryOut"]
	if key == "email" and step_def["anim"] == "sit":
		player["seated"] = true
	if key == "email" and step_def["anim"] == "send":
		player["seated"] = false

	var ts_next: Dictionary = _clone_task_state(ts)
	ts_next["stepIdx"] = step_idx + 1
	ts_next["carry"] = step_def.get("carryOut", ts.get("carry", null))
	# Arm the wait timer tied to THIS step (the one that just finished).
	var wait_after: Dictionary = cfg.get("waitAfter", {})
	ts_next["timerEnd"] = (t + float(wait_after[step_idx]["seconds"])) if wait_after.has(step_idx) else null

	# Burning: plating past burnUntil marks the dish charred.
	if key == "cooking" and step_def["anim"] == "plate" and ts.get("burnUntil", null) != null and t >= float(ts["burnUntil"]):
		ts_next["burned"] = true

	var score: int = state["score"]
	var served_count: int = state["servedCount"]
	var last_chain_key = state["lastChainKey"]
	var last_chain_time := float(state["lastChainTime"])
	var history: Array = state["history"]
	var step_score: Array = cfg["stepScore"]
	var gained: int = step_score[step_idx] if step_idx < step_score.size() else 0
	if bool(ts_next["burned"]) and step_def["anim"] == "serve":
		gained = 4  # burned finish
	var completes: bool = int(ts_next["stepIdx"]) >= (cfg["steps"] as Array).size()

	if gained > 0:
		var award := gained
		if completes:
			var chain_okay: bool = last_chain_key == key and t - last_chain_time <= D.CHAIN_WINDOW
			award = gained + (D.CHAIN_BONUS if chain_okay else 0)
			last_chain_key = key
			last_chain_time = t
			served_count += 1
		score += award
		history = _push_history({"history": history}, {
			"tSec": int(round(t)), "type": key, "text": "+%d %s" % [award, cfg["label"]],
		})
		if completes:
			history = _push_history({"history": history}, {
				"tSec": int(round(t)), "type": key, "text": "%s — done" % String(cfg["label"]).to_lower(),
			})

	var queue: Array = state["queue"]
	var pending: Dictionary = state["pending"]
	var rng: int = state["rng"]
	var kids_quick_return: bool = state["kidsQuickReturn"]
	var tasks: Dictionary = (state["tasks"] as Dictionary).duplicate()
	tasks[key] = ts_next

	if completes:
		var kept := []
		for q in queue:
			if q["key"] != key:
				kept.append(q)
		queue = kept
		tasks[key] = null
		player["carrying"] = null
		var sched := _schedule_next(rng, pending, kids_quick_return, key, t)
		rng = sched["rng"]
		pending = sched["pending"]

	var out := state.duplicate()
	out["player"] = player
	out["tasks"] = tasks
	out["queue"] = queue
	out["pending"] = pending
	out["rng"] = rng
	out["score"] = score
	out["servedCount"] = served_count
	out["lastChainKey"] = last_chain_key
	out["lastChainTime"] = last_chain_time
	out["kidsQuickReturn"] = kids_quick_return
	out["history"] = history
	return out


## Route her to a prop, over the derived walkable grid.
##
## The old version projected her onto the nearest corridor EDGE, then chose
## whichever of that edge's two endpoints gave the shorter total walk — a lot of
## machinery to compensate for a sparse hand-authored graph. With a grid there
## is nothing to compensate for: find the nearest walkable cell to where she is,
## A* to the prop's anchor cell, and walk the corners.
static func _set_walk(state: Dictionary, object_id) -> Dictionary:
	if typeof(object_id) != TYPE_STRING or not Level.PROPS.has(object_id):
		return state
	var anchor := Nav.anchor(object_id)
	if anchor.is_empty():
		return state

	var player := _clone_player(state["player"])
	var here := Vector2(float(player["x"]), float(player["y"]))
	var path := Nav.find_path(here, anchor["cell"])

	var pts := []
	for wp in path:
		pts.append(_pt(wp.x, wp.y))
	# Always finish on the anchor itself: A* works in cell centres, and she
	# should stop exactly where the prop expects her, not one cell short.
	var goal: Vector2 = anchor["pos"]
	if pts.is_empty() or absf(float(pts[-1]["x"]) - goal.x) > 0.5 or absf(float(pts[-1]["y"]) - goal.y) > 0.5:
		pts.append(_pt(goal.x, goal.y))

	# Walking drops any seat lock; a mid-flight work step is ABANDONED — no
	# progress, no points. The clicked object becomes pendingResolve.
	player["seated"] = false
	player["anim"] = null
	player["busyUntil"] = 0.0
	player["working"] = null
	player["order"] = {"mode": "walk", "to": pts[0], "path": pts.slice(1)}
	player["pendingResolve"] = object_id

	var out := state.duplicate()
	out["player"] = player
	return out


# ── the contract ───────────────────────────────────────────────────────────

const META := {
	"game": "Second Shift",
	"minPlayers": 1,
	"maxPlayers": 1,
}


static func meta() -> Dictionary:
	return META


static func setup(players: Array) -> Dictionary:
	var raw := String(players[0]) if players.size() > 0 and players[0] != null else "ruth"
	if raw.is_empty():
		raw = "ruth"
	var seed_i := 7
	for i in raw.length():
		seed_i = _to_i32(seed_i * 31 + raw.unicode_at(i))
	seed_i = absi(seed_i)
	if seed_i == 0:
		seed_i = 1

	var rng := seed_i
	var phone_first := _roll_range(rng, 28.0, 42.0)
	rng = phone_first["seed"]
	var pen := _initial_pending(rng)
	rng = pen["rng"]

	return {
		"t": 0.0,
		"roundSeconds": D.ROUND_SECONDS,
		"target": D.TARGET_SCORE,
		"score": 0,
		"servedCount": 0,
		"missed": 0,
		"rng": rng,
		# The marriage frame: this level is the housewife's morning. The
		# husband's evening hangs off the same engine and ships next.
		"level": {"key": "wife", "name": "Her Morning", "partner": "His Evening"},
		"queue": [],
		"pending": pen["pending"],  # email added on a missed call; self never
		"tasks": {},  # key -> task state
		"player": {
			"x": 480.0,
			"y": 320.0,
			"order": _empty_order(),
			"queuedTarget": null,
			"anim": null,
			"busyUntil": 0.0,
			"carrying": null,
			"seated": false,
		},
		"selfNeed": D.SELF_NEED_MAX,
		"restoreT": 0.0,
		"phone": {"state": "idle", "nextAtT": phone_first["value"], "untilT": 0.0, "caller": null},
		"lastChainKey": null,
		"lastChainTime": -999.0,
		"kidsQuickReturn": false,
		"history": [],
		"events": [],
		"outcome": null,
	}


## Called BEFORE any mutation. This is the only thing standing between input
## and the state, so it is strict about shape and says nothing about intent.
static func validate_action(state: Dictionary, _player_id: String, action) -> Dictionary:
	if typeof(action) != TYPE_DICTIONARY:
		return {"ok": false, "error": "action must be an object"}
	if state.get("outcome", null) != null:
		return {"ok": false, "error": "round is over"}
	var type = action.get("type", null)

	if type == "click":
		var obj = action.get("object", null)
		if typeof(obj) != TYPE_STRING or not Level.PROPS.has(obj):
			return {"ok": false, "error": "unknown object"}
		return {"ok": true}
	if type == "answer":
		if state["phone"]["state"] != "ringing":
			return {"ok": false, "error": "phone is quiet"}
		var mode = action.get("mode", null)
		if mode != "fast" and mode != "slow":
			return {"ok": false, "error": "answer needs mode fast|slow"}
		return {"ok": true}
	if type == "resolveKid":
		if _nullish(state["tasks"], "kids"):
			return {"ok": false, "error": "no kid acting up"}
		var mode = action.get("mode", null)
		if mode != "talk" and mode != "redirect":
			return {"ok": false, "error": "resolveKid needs mode talk|redirect"}
		return {"ok": true}
	if type == "pause":
		return {"ok": true}
	return {"ok": false, "error": "unknown action type"}


## Apply an already-validated action and return the NEW state. Treats `state`
## as immutable — copies what it changes.
static func apply_action(state: Dictionary, _player_id: String, action: Dictionary) -> Dictionary:
	var next := state.duplicate()
	next["player"] = _clone_player(state["player"])
	var queue := []
	for q in state["queue"]:
		queue.append((q as Dictionary).duplicate())
	next["queue"] = queue
	next["pending"] = (state["pending"] as Dictionary).duplicate()
	next["phone"] = (state["phone"] as Dictionary).duplicate()
	next["history"] = (state["history"] as Array).duplicate()
	next["events"] = (state["events"] as Array).duplicate()
	next["tasks"] = _clone_tasks(state["tasks"])

	var type = action.get("type", null)

	# ── the intent lands first (no world time has passed yet).
	if type == "click":
		# NOTE: `order.target` is never set anywhere in the original engine, so
		# this branch is dead and every click walks immediately — the
		# `queuedTarget` path below is only ever fed by... nothing. Ported
		# as-is so the two implementations agree; see HANDOFF.md.
		if next["player"]["order"]["mode"] == "walk" and next["player"]["order"].get("target", null):
			next["player"]["queuedTarget"] = action.get("object", null)
		else:
			next = _set_walk(next, action.get("object", null))
	elif type == "answer":
		var t := float(next["t"])
		var delta: int = D.CALL_GOODWILL_FAST if action.get("mode") == "fast" else D.CALL_GOODWILL_SLOW
		next["score"] = maxi(0, int(next["score"]) + delta)
		next["phone"] = {
			"state": "idle",
			"nextAtT": t + 30.0 + float(_rng_next(next["rng"])["roll"]) * 24.0,
			"untilT": 0.0,
			"caller": null,
		}
		next["rng"] = _to_i32(int(next["rng"]) + 7)
		next["history"] = _push_history(next, {
			"tSec": int(round(t)),
			"type": "phone",
			"text": "brushed off the call –1" if action.get("mode") == "fast" else "stayed on the line +1",
		})
	elif type == "resolveKid":
		var ts = next["tasks"].get("kids", null)
		var has_queue_item := false
		for q in next["queue"]:
			if q["key"] == "kids":
				has_queue_item = true
				break
		if ts != null and has_queue_item:
			var t := float(next["t"])
			var cfg: Dictionary = D.TASKS["kids"]
			var base_points: int = cfg["points"]
			var gain := base_points
			var kids_quick_return := false
			if action.get("mode") == "redirect":
				gain = maxi(2, base_points - 2)
				kids_quick_return = true  # acts up again sooner
			else:
				gain = base_points + 2  # talking takes hold — a small bonus
			next["score"] = int(next["score"]) + gain
			next["servedCount"] = int(next["servedCount"]) + 1
			next["lastChainKey"] = "kids"
			next["lastChainTime"] = t
			next["kidsQuickReturn"] = kids_quick_return
			var kept := []
			for q in next["queue"]:
				if q["key"] != "kids":
					kept.append(q)
			next["queue"] = kept
			next["tasks"]["kids"] = null
			var sched := _schedule_next(next["rng"], next["pending"], kids_quick_return, "kids", t)
			next["rng"] = sched["rng"]
			next["pending"] = sched["pending"]
			next["history"] = _push_history(next, {
				"tSec": int(round(t)),
				"type": "kids",
				"text": ("talked it out +%d" % gain) if action.get("mode") == "talk" else ("redirected +%d (they'll act up sooner)" % gain),
			})
	# "pause" carries no intent; it only advances the world.

	# ── world time. The 500 ms clamp is what protects the simulation from a
	# stalled caller — a dropped frame here, a dropped socket there.
	var dt_ms := clampf(float(action.get("dtMs", 0.0)), 0.0, 500.0)
	if dt_ms > 0.5:
		next = _tick(next, dt_ms / 1000.0)

		# Auto-arrive: she was walking to a pendingResolve object and has
		# stopped moving — resolve the click against any live task chain. This
		# STARTS the work; the commit happens when the duration has elapsed.
		if next["player"]["order"]["mode"] == "idle" and next["player"]["pendingResolve"] != null:
			var arrived_at: String = next["player"]["pendingResolve"]
			var p := _clone_player(next["player"])
			p["pendingResolve"] = null
			next = next.duplicate()
			next["player"] = p
			next = _resolve_click(next, arrived_at)["state"]

		# WORKING → FINISHING: the step's full duration has elapsed and she is
		# still standing at the anchor — commit it (points, timers, completion).
		var working = next["player"]["working"]
		if working != null and float(next["t"]) >= float(working["endsAt"]) and next["player"]["order"]["mode"] == "idle":
			next = _commit_work(next)

		# A queued click is consumed only when she is free — never mid-work.
		if next["player"]["queuedTarget"] != null and next["player"]["working"] == null and next["player"]["order"]["mode"] == "idle" and next["player"]["pendingResolve"] == null:
			var queued = next["player"]["queuedTarget"]
			var p2 := _clone_player(next["player"])
			p2["queuedTarget"] = null
			next = next.duplicate()
			next["player"] = p2
			next = _set_walk(next, queued)

		# Self-sit completion (no queue item closes it).
		var self_ts = next["tasks"].get("self", null)
		if self_ts != null and self_ts["timerEnd"] != null and float(next["t"]) >= float(self_ts["timerEnd"]):
			next["selfNeed"] = D.SELF_NEED_MAX
			next["restoreT"] = 6.0
			next["servedCount"] = int(next["servedCount"]) + 1
			next["score"] = int(next["score"]) + int(D.TASKS["self"]["points"])
			next["tasks"] = (next["tasks"] as Dictionary).duplicate()
			next["tasks"]["self"] = null
			var p3 := _clone_player(next["player"])
			p3["seated"] = false
			p3["anim"] = null
			p3["busyUntil"] = 0.0
			next["player"] = p3
			next["history"] = _push_history(next, {
				"tSec": int(round(float(next["t"]))), "type": "self", "text": "took a minute for herself",
			})

	# ── round close.
	if float(next["t"]) >= float(next["roundSeconds"]) and next.get("outcome", null) == null:
		var won: bool = int(next["score"]) >= int(next["target"])
		var self_text := "she never got her minute" if float(next["selfNeed"]) < 30.0 else "she kept a piece of herself"
		var miss_text := "nothing slipped" if int(next["missed"]) == 0 else ("%d slipped" % int(next["missed"]))
		var history := _push_history(next, {
			"tSec": int(round(float(next["t"]))),
			"type": "end",
			"text": "%s · %s · %s" % ["shift survived" if won else "the morning won", self_text, miss_text],
		})
		var closed := _clone_player(next["player"])
		closed["order"] = _empty_order()
		closed["anim"] = null
		closed["busyUntil"] = 0.0
		closed["seated"] = false
		next = next.duplicate()
		next["outcome"] = "won" if won else "lost"
		next["player"] = closed
		next["history"] = history

	return next


static func is_game_over(state: Dictionary) -> Dictionary:
	if float(state["t"]) >= float(state["roundSeconds"]) or state.get("outcome", null) != null:
		return {"over": true, "winner": "her" if int(state["score"]) >= int(state["target"]) else null}
	return {"over": false}


## What the renderer is allowed to see. Everything is client-visible here — only
## the RNG seed stays behind. The boundary is kept even without a network,
## because it is what lets the renderer stay dumb.
static func view_for(state: Dictionary, _player_id: String) -> Dictionary:
	var task_views := {}
	for k in state["tasks"]:
		var ts = state["tasks"][k]
		if ts == null:
			continue
		var steps: Array = D.TASKS[k]["steps"]
		var idx: int = ts["stepIdx"]
		var real_steps := 0
		for s in steps:
			if s != null:
				real_steps += 1
		task_views[k] = {
			"key": k,
			"stepIdx": idx,
			"stepsLen": steps.size(),
			"carry": ts.get("carry", null),
			"burned": bool(ts.get("burned", false)),
			"waiting": idx < steps.size() and steps[idx] == null,
			"timerEnd": ts.get("timerEnd", null),
			"kidSpot": ts.get("kidSpot", null),
			"partialText": ("step %d/%d" % [idx, real_steps]) if idx > 0 else null,
		}
	return {
		"t": state["t"],
		"roundSeconds": state["roundSeconds"],
		"target": state["target"],
		"score": state["score"],
		"servedCount": state["servedCount"],
		"missed": state["missed"],
		"level": state["level"],
		"queue": state["queue"],
		"player": state["player"],
		"selfNeed": state["selfNeed"],
		"phone": state["phone"],
		"tasks": task_views,
		"taskDefs": D.TASKS,
		"objects": _objects_view(),
		"stations": Level.STATIONS,
		"lastChainKey": state["lastChainKey"],
		"history": _take_last(state["history"], 6),
		"events": _take_last(state["events"], 8),
		"outcome": state.get("outcome", null),
		"world": {"w": D.W, "h": D.H},
	}
