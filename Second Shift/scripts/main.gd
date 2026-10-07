## The scene root: the view everything else draws from, the input router, and
## the "juice" layer.
##
## In the browser this was three separate things — a `game` object holding
## transient UI state, a set of pointer handlers, and `onServerState`, which
## diffed each arriving server frame to decide what to celebrate. They belong
## together, because all three answer the same question: what changed, and how
## should the screen react?
##
## Input precedence is unchanged from the canvas version, and the order matters:
## start/replay button, then the kid-choice popup, then the phone chip, then a
## world object, then bare floor (which routes to the nearest anchor). A click
## that hits nothing is never a penalty — that is a design rule, not an
## oversight.
extends Node2D

const U := preload("res://scripts/draw_util.gd")

const W := 960.0
const H := 640.0

## The latest view from Session. Every drawing node reads this and nothing else.
var view: Dictionary = {}
## Object id under the cursor, or "".
var hover := ""
var paused := false
var started := false
var end_shown_at := 0.0

# Juice: {x, y, txt, at, color} / {x, y, at} / {x, y, vx, vy, at, color}
var float_texts: Array = []
var bounces: Array = []
var particles: Array = []
var shake_t := -1.0

var _prev_view: Dictionary = {}
var _rng := RandomNumberGenerator.new()

@onready var world: Node2D = $World
@onready var ruth: Node2D = $World/Ruth
@onready var hud: Control = $HUD/Screen


func _ready() -> void:
	_rng.randomize()
	Session.view_changed.connect(_on_view_changed)
	Session.round_over.connect(_on_round_over)
	view = Session.view()
	_prev_view = view


func ruth_feet_y() -> float:
	return ruth.feet_y()


func _process(_delta: float) -> void:
	var now := float(Time.get_ticks_msec())
	_expire_juice(now)
	_apply_shake(now)


# ── reacting to state changes ──────────────────────────────────────────────

## The old `onServerState`. It diffs consecutive views rather than reading
## events out of the state, because a diff catches everything — including
## score changes that no single event describes.
func _on_view_changed(v: Dictionary) -> void:
	var prev := _prev_view
	view = v
	_prev_view = v
	if prev.is_empty():
		return

	var now := float(Time.get_ticks_msec())
	var rx: float = ruth.render_pos.x
	var ry: float = ruth.render_pos.y

	if int(v["score"]) > int(prev["score"]):
		var delta: int = int(v["score"]) - int(prev["score"])
		float_texts.append({"x": rx, "y": ry - 96.0, "txt": "+%d" % delta, "at": now, "color": U.C["sage"]})
		_spawn_burst(rx, ry - 60.0, U.C["sunny"], 10)
		Sfx.play("served", 0.25)
		# A big single award is a completed chain, not a step.
		if delta >= 4:
			Sfx.play("chain", 0.2)

	if int(v["missed"]) > int(prev["missed"]):
		shake_t = now
		float_texts.append({"x": rx, "y": ry - 96.0, "txt": "−", "at": now, "color": U.C["bad"]})
		Sfx.play("fail", 0.3)

	var ringing_now: bool = v["phone"]["state"] == "ringing"
	var ringing_before: bool = prev["phone"]["state"] == "ringing"
	if ringing_now and not ringing_before:
		Sfx.play("alert", 0.35)

	# a task chain advanced?
	for key in v.get("tasks", {}):
		var after = v["tasks"][key]
		var before = prev.get("tasks", {}).get(key, null)
		if before != null and after != null and int(after["stepIdx"]) > int(before["stepIdx"]):
			_spawn_burst(rx, ry - 70.0, U.C["sunny"], 6)


func _on_round_over(result: Dictionary) -> void:
	if end_shown_at <= 0.0:
		end_shown_at = float(Time.get_ticks_msec())
		Sfx.play("chain" if result.get("winner", null) != null else "fail", 0.4)


func _spawn_burst(x: float, y: float, color: Color, n: int) -> void:
	var now := float(Time.get_ticks_msec())
	for i in n:
		var a := (float(i) / float(n)) * TAU + _rng.randf() * 0.5
		particles.append({
			"x": x, "y": y,
			"vx": cos(a) * (0.5 + _rng.randf()),
			"vy": sin(a) * (0.5 + _rng.randf()) - 0.4,
			"at": now, "color": color,
		})


func _expire_juice(now: float) -> void:
	float_texts = float_texts.filter(func(f): return now - float(f["at"]) <= 1100.0)
	bounces = bounces.filter(func(b): return now - float(b["at"]) <= 380.0)
	particles = particles.filter(func(p): return now - float(p["at"]) <= 600.0)


## Screen shake on a miss. The canvas translated the whole frame; here the
## world node and the HUD layer are nudged together so they stay locked.
func _apply_shake(now: float) -> void:
	var offset := Vector2.ZERO
	if shake_t > 0.0 and now - shake_t < 300.0:
		var p := (now - shake_t) / 300.0
		offset = Vector2(sin(now / 22.0) * 3.0 * (1.0 - p), cos(now / 27.0) * 2.0 * (1.0 - p))
	world.position = offset
	($HUD as CanvasLayer).offset = offset


# ── hit testing ────────────────────────────────────────────────────────────

## The object under a point. Every clickable honours a 44x44 minimum hit box
## however small its art is, and the nearest centre wins an overlap.
func object_at(p: Vector2) -> String:
	var objects: Dictionary = view.get("objects", {})
	var best := ""
	var best_d := INF
	for id in objects:
		var o: Dictionary = objects[id]
		var hw: float = maxf(44.0, float(o["hitW"])) / 2.0
		var hh: float = maxf(44.0, float(o["hitH"])) / 2.0
		var ox := float(o["x"])
		var oy := float(o["y"])
		if p.x >= ox - hw and p.x <= ox + hw and p.y >= oy - hh and p.y <= oy + hh:
			var d := p.distance_to(Vector2(ox, oy))
			if d < best_d:
				best_d = d
				best = id
	return best


## Clicking bare floor still means something: walk toward the nearest anchor
## within 200 px. Outside that, the click is ignored rather than sending her
## across the house for nothing.
func nearest_object(p: Vector2) -> String:
	var objects: Dictionary = view.get("objects", {})
	var best := ""
	var best_d := INF
	for id in objects:
		var o: Dictionary = objects[id]
		var d := p.distance_to(Vector2(float(o["x"]), float(o["y"])))
		if d < best_d:
			best_d = d
			best = id
	return best if best_d < 200.0 else ""


# ── input ──────────────────────────────────────────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		hover = object_at((event as InputEventMouseMotion).position)
		Input.set_default_cursor_shape(Input.CURSOR_POINTING_HAND if hover != "" else Input.CURSOR_ARROW)
		return

	if event.is_action_pressed("ui_cancel"):
		# ESC — the only key in the game.
		paused = not paused
		get_tree().paused = paused
		get_viewport().set_input_as_handled()
		return

	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	_on_click(mb.position)
	get_viewport().set_input_as_handled()


func _on_click(p: Vector2) -> void:
	Sfx.start_ambience()

	# overlays first
	if not started and hud.start_rect.has_point(p):
		started = true
		Session.begin()
		return
	if view.get("outcome", null) != null and hud.replay_rect.has_point(p):
		_restart()
		return
	if paused:
		return
	if not started:
		return

	# kid choice popup
	if hud.kid_talk_rect.has_point(p):
		Session.submit({"type": "resolveKid", "mode": "talk"})
		Sfx.play("served", 0.2)
		return
	if hud.kid_redirect_rect.has_point(p):
		Session.submit({"type": "resolveKid", "mode": "redirect"})
		Sfx.play("served", 0.15)
		return

	# phone answer chip — defaults to the warm route (stay on the line)
	if view["phone"]["state"] == "ringing" and hud.phone_rect.has_point(p):
		Session.submit({"type": "answer", "mode": "slow"})
		Sfx.play("buffer", 0.3)
		return

	# world click
	var id := object_at(p)
	if id != "":
		_click_object(id, p)
	else:
		var nearest := nearest_object(p)
		if nearest != "":
			Session.submit({"type": "click", "object": nearest})


func _click_object(id: String, _p: Vector2) -> void:
	Session.submit({"type": "click", "object": id})
	Sfx.play("tick", 0.1)
	# NOTE: `bounces` (the red ring for a wrong click) is drawn but never fed.
	# The rules layer does compute a bounce in `_resolve_click`, but it returns
	# it alongside the state and the room threw it away, so the browser build
	# never rang either. Wiring it up means surfacing the bounce as a view
	# event — see HANDOFF.md.


func _restart() -> void:
	Session.reset()
	Session.begin()
	started = true
	paused = false
	get_tree().paused = false
	end_shown_at = 0.0
	float_texts.clear()
	bounces.clear()
	particles.clear()
	shake_t = -1.0
	hud.reset_bubbles()
