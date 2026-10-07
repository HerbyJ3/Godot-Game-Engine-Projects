## Ruth — the sprite, the animation state machine, and her route.
##
## The rules layer moves her in whole simulation steps; this layer is entirely
## cosmetic. Two things are worth keeping from the browser client even though
## the server is gone:
##
##   * the exponential position chase. It existed because the server only sent
##     a position when an action landed (~7 Hz), and rendering her AT that
##     position made her teleport. At frame rate it now costs nothing and still
##     smooths the per-step integration into continuous motion.
##   * the four-state machine — IDLE / WALKING / WORKING / FINISHING — where
##     WORKING branches per animation kind. That per-station body language
##     (crouching at the washer, bobbing at the counter, rocking at the crib)
##     is most of what sells the game, and it is all procedural.
##
## Ported from `drawRuth` in public/client.js.
extends Node2D

const U := preload("res://scripts/draw_util.gd")
const Icons := preload("res://scripts/task_icons.gd")

## She is drawn 128 px tall — 5'6" next to ~85 cm appliances.
const H_PX := 128.0
## Her feet sit 6 px below the anchor, so the contact shadow lands right.
const FOOT_OFFSET := 6.0

@onready var game: Node = owner

# Smoothed render state. `facing` is -1 (west) or 1 (east) for the mirrored
# side-profile set.
var render_pos := Vector2(480, 330)
var facing := 1
var walk_phase := 0.0
var last_work_seen := -1.0

var _idle: Texture2D
var _carry: Texture2D
var _walk: Array[Texture2D] = []
var _walk_front: Array[Texture2D] = []
var _walk_back: Array[Texture2D] = []


func _ready() -> void:
	_idle = load("res://assets/art/ruth-idle.png")
	_carry = load("res://assets/art/ruth-carry.png")
	for i in 8:
		_walk.append(load("res://assets/art/ruth-w%d.png" % i))
	for i in 6:
		_walk_front.append(load("res://assets/art/ruth-front-w%d.png" % i))
	for i in 8:
		_walk_back.append(load("res://assets/art/ruth-back-w%d.png" % i))


func _process(delta: float) -> void:
	_advance(delta)
	queue_redraw()


func feet_y() -> float:
	return render_pos.y


# ── transform helpers (canvas translate/scale/rotate, composed explicitly) ──

static func _tr(v: Vector2) -> Transform2D:
	return Transform2D(0.0, Vector2.ONE, 0.0, v)


static func _sc(v: Vector2) -> Transform2D:
	return Transform2D(0.0, v, 0.0, Vector2.ZERO)


static func _rot(a: float) -> Transform2D:
	return Transform2D(a, Vector2.ONE, 0.0, Vector2.ZERO)


var _moving := false
var _heading := "south"


func _advance(delta: float) -> void:
	var v: Dictionary = game.view
	if v.is_empty():
		return
	var p: Dictionary = v["player"]

	# Exponential chase — reaches the target in a few hundred ms, no snapping.
	var chase := 1.0 - exp(-10.0 * delta)
	var d := Vector2(float(p["x"]) - render_pos.x, float(p["y"]) - render_pos.y)
	render_pos += d * chase

	var order: Dictionary = p["order"]
	_moving = d.length() > 2.0 or order["mode"] == "walk"

	# Heading decides the sprite set: vertical legs show front/back, horizontal
	# legs show the profile, mirrored by direction.
	_heading = "south"
	if _moving and order["to"] != null:
		var to: Dictionary = order["to"]
		var hx := float(to["x"]) - render_pos.x
		var hy := float(to["y"]) - render_pos.y
		if absf(hy) >= absf(hx):
			_heading = "north" if hy < 0.0 else "south"
		else:
			_heading = "west" if hx < 0.0 else "east"
			facing = -1 if _heading == "west" else 1
	if _moving:
		walk_phase += delta * 11.0  # ~1.4 full gait cycles/sec


func _draw() -> void:
	var v: Dictionary = game.view
	if v.is_empty():
		return
	var p: Dictionary = v["player"]
	var now := float(Time.get_ticks_msec())
	var x := render_pos.x
	var y := render_pos.y
	var carry = p.get("carrying", null)
	var anim = p.get("anim", null)

	# ── animation state machine
	var working: bool = p.get("working", null) != null and anim != null
	if working:
		last_work_seen = now
	var finishing: bool = (
		not working and not _moving and last_work_seen >= 0.0 and now - last_work_seen < 220.0
	)

	# ── sprite pick: working/idle face by p.facing, walking by heading
	var tex: Texture2D = _idle
	var mirror := false
	var stationary_facing: String = p.get("facing", "down")
	if _moving:
		if _heading == "north":
			tex = _walk_back[int(walk_phase) % 8]
		elif _heading == "south":
			tex = _walk_front[int(walk_phase) % 6]
		else:
			tex = _walk[int(walk_phase) % 8]
			mirror = facing < 0
		if carry != null and _carry != null:
			tex = _carry
			mirror = facing < 0
	else:
		if stationary_facing == "up":
			tex = _walk_back[0]
		elif stationary_facing == "left" or stationary_facing == "right":
			tex = _walk[0]
			mirror = stationary_facing == "left"
		else:
			tex = _idle
		if carry != null and _carry != null and not working:
			tex = _carry
			mirror = stationary_facing == "left"

	# ── contact shadow — a flat ellipse at her feet, low opacity, no halo
	U.fill_ellipse(self, x, y + 4, 24, 7, Color(0.290196, 0.207843, 0.149020, 0.22))

	if tex != null:
		var w := (float(tex.get_width()) / float(tex.get_height())) * H_PX
		var t := _tr(Vector2(x, y)) * _body_transform(p, now, working, finishing, stationary_facing)
		if mirror:
			t = t * _sc(Vector2(-1, 1))
		draw_set_transform_matrix(t)
		draw_texture_rect(tex, Rect2(-w / 2.0, -H_PX + FOOT_OFFSET, w, H_PX), false)
		draw_set_transform_matrix(Transform2D.IDENTITY)
	else:
		U.fill_rr(self, x - 18, y - 76, 36, 76, 14, U.C["terracotta"])

	_draw_carry_chip(carry, x, y)
	_draw_route(p)
	_draw_queued_ring(v, now)


## The per-state body language. Every branch here is the same arithmetic the
## canvas version used — these constants were tuned by eye and are worth
## nothing rederived.
func _body_transform(p: Dictionary, now: float, working: bool, finishing: bool, stationary_facing: String) -> Transform2D:
	if _moving:
		# WALKING: stride bob
		return _tr(Vector2(0, absf(sin(walk_phase * PI)) * -5.0))

	if working:
		var kind: String = p["anim"]["kind"]
		var wt := now / 1000.0
		match kind:
			"grab", "pour", "press", "dispose":
				# bending down, loading motion (washer / dryer / basket / bin)
				var crouch := 0.5 + 0.5 * sin(wt * 6.0)
				return _tr(Vector2(0, crouch * 7.0)) * _sc(Vector2(1, 1.0 - crouch * 0.08))
			"chop", "cook", "plate", "fill", "scoop", "serve":
				# arms working at counter height: quick small bob
				return _tr(Vector2(0, sin(wt * 11.0) * 2.5))
			"lay", "change", "feed", "shake":
				# leaning in, gentle rocking (crib / baby / changing table)
				var lean := -1.0 if stationary_facing == "left" else (1.0 if stationary_facing == "right" else 0.6)
				return _rot(sin(wt * 3.2) * 0.05 + lean * 0.07) * _tr(Vector2(0, 2))
			"type", "wake", "send":
				# leaning over the desk
				return _tr(Vector2(0, 4.0 + sin(wt * 9.0) * 1.2)) * _sc(Vector2(1, 0.97))
			"sit":
				# actually sitting — the one state at rest
				return _tr(Vector2(0, 10)) * _sc(Vector2(1, 0.94))
		return Transform2D.IDENTITY

	if finishing:
		# FINISHING: a brief completion pulse
		var fp := 1.0 - (now - last_work_seen) / 220.0
		var s := 1.0 + fp * 0.06
		return _sc(Vector2(s, s))

	# IDLE: subtle breathing bob
	return _sc(Vector2(1, 1.0 + sin(now / 800.0) * 0.008))


## A small floating item chip near her hands, so what she is carrying reads
## without a label.
func _draw_carry_chip(carry, x: float, y: float) -> void:
	if carry == null:
		return
	var cx := x + 24.0 * float(facing)
	var cy := y - 72.0
	U.fill_circle(self, cx, cy, 13, U.C["paperSolid"])
	U.stroke_circle(self, cx, cy, 13, U.C["ink"], 2)
	Icons.draw_icon(self, Icons.for_carry(String(carry)), cx, cy, 14, U.C["ink"])


## The active route, as a soft dashed path with a destination dot — the same
## line the walkway graph actually routed her along.
func _draw_route(p: Dictionary) -> void:
	var order: Dictionary = p["order"]
	if order["mode"] != "walk" or order["to"] == null:
		return
	var pts: Array[Vector2] = [render_pos]
	pts.append(Vector2(order["to"]["x"], order["to"]["y"]))
	for pt in order.get("path", []):
		pts.append(Vector2(pt["x"], pt["y"]))

	var line_col := Color(1.0, 0.984314, 0.941176, 0.75)
	for i in range(1, pts.size()):
		draw_dashed_line(pts[i - 1], pts[i], line_col, 3, 8.0, false, true)

	var dest: Vector2 = pts[pts.size() - 1]
	U.fill_circle(self, dest.x, dest.y, 5, Color(1.0, 0.984314, 0.941176, 0.9))
	U.stroke_circle(self, dest.x, dest.y, 5, U.hex_a(U.C["ink"], 0.5), 2)


## The pulsing ring on a destination she will head to once she is free.
func _draw_queued_ring(v: Dictionary, now: float) -> void:
	var queued = v["player"].get("queuedTarget", null)
	if queued == null:
		return
	var objects: Dictionary = v.get("objects", {})
	if not objects.has(queued):
		return
	var q: Dictionary = objects[queued]
	var pulse := 1.0 + sin(now / 220.0) * 0.1
	U.stroke_ellipse(
		self, q["x"], q["y"],
		(float(q["hitW"]) / 2.0) * pulse, (float(q["hitH"]) / 2.0) * 0.55 * pulse,
		U.hex_a(U.C["sunny"], 0.85), 3
	)
