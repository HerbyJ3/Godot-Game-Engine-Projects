## The world layer that sits ON TOP of the painted background and UNDER Ruth.
##
## `assets/art/home.png` is the whole 960x640 interior, painted. Two kinds of
## thing still have to be drawn over it:
##
##   * the nursery corner (crib, changing table, diaper pail) — those props are
##     not in the baked image, so they are drawn every frame;
##   * live state that has to read at a glance — the glow ring on the object
##     the current chain wants next, steam off the stove, the washer rumbling
##     with its countdown, the kid acting out, the baby crying, hover.
##
## Ported from `drawNursery` and `drawLiveOverlays` in public/client.js.
extends Node2D

const U := preload("res://scripts/draw_util.gd")
const Icons := preload("res://scripts/task_icons.gd")

@onready var game: Node = owner


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	var v: Dictionary = game.view
	if v.is_empty():
		return
	var now := float(Time.get_ticks_msec())
	draw_nursery(self, v, now)
	_draw_live_overlays(v, now)


## The nursery corner. Static enough to be a texture one day; drawn for now so
## the props can react (the drawer pops a folded diaper when the chain wants
## it) and so nothing has to be re-baked to move them.
##
## Called twice per frame: once here, and again by the foreground layer when
## Ruth is standing behind them.
static func draw_nursery(ci: CanvasItem, v: Dictionary, _now: float) -> void:
	var objects: Dictionary = v.get("objects", {})
	var ink: Color = U.C["ink"]

	# Crib
	if objects.has("crib"):
		var c: Dictionary = objects["crib"]
		var cx := float(c["x"])
		var cy := float(c["y"])
		U.fill_rr(ci, cx - 34, cy - 22, 68, 44, 10, U.C["cribPink"])
		U.stroke_rr(ci, cx - 34, cy - 22, 68, 44, 10, ink, 3)
		for i in range(-2, 3):
			U.line(ci, Vector2(cx + i * 12, cy - 20), Vector2(cx + i * 12, cy + 20), ink, 2.5)
		U.fill_rr(ci, cx - 30, cy + 6, 60, 12, 6, U.C["sunny"])

	# Changing table + drawer
	if objects.has("changingTable"):
		var t: Dictionary = objects["changingTable"]
		var tx := float(t["x"])
		var ty := float(t["y"])
		U.fill_rr(ci, tx - 30, ty - 18, 60, 36, 8, U.C["changingWood"])
		U.stroke_rr(ci, tx - 30, ty - 18, 60, 36, 8, ink, 3)
		U.fill_rr(ci, tx - 24, ty - 14, 48, 12, 6, U.C["rose"])  # pad
		U.fill_rr(ci, tx - 22, ty + 4, 44, 10, 3, U.C["paperSolid"])  # drawer
		U.stroke_rr(ci, tx - 22, ty + 4, 44, 10, 3, ink, 2)
		# a folded diaper poking out when the drawer is the next step
		var diaper = v.get("tasks", {}).get("diaper", null)
		if diaper != null and int(diaper["stepIdx"]) == 2:
			U.fill_circle(ci, tx, ty - 26, 8, U.C["paperSolid"])
			U.stroke_circle(ci, tx, ty - 26, 8, ink, 2)

	# Diaper pail
	if objects.has("bin"):
		var b: Dictionary = objects["bin"]
		var bx := float(b["x"])
		var by := float(b["y"])
		U.fill_rr(ci, bx - 14, by - 18, 28, 34, 6, U.C["pailGrey"])
		U.stroke_rr(ci, bx - 14, by - 18, 28, 34, 6, ink, 2.5)
		U.fill_rr(ci, bx - 16, by - 22, 32, 8, 4, U.C["sage"])
		U.stroke_rr(ci, bx - 16, by - 22, 32, 8, 4, ink, 2)


func _draw_live_overlays(v: Dictionary, now: float) -> void:
	var objects: Dictionary = v.get("objects", {})
	if objects.is_empty():
		return
	var tasks: Dictionary = v.get("tasks", {})
	var task_defs: Dictionary = v.get("taskDefs", {})
	var ink: Color = U.C["ink"]

	# Next-step glow ring on the object the current chain needs. This is the
	# game's only tutorial: follow the glow.
	for key in tasks:
		if key == "kids" or key == "self":
			continue
		var ts: Dictionary = tasks[key]
		if not task_defs.has(key) or bool(ts.get("waiting", false)):
			continue
		var steps: Array = task_defs[key]["steps"]
		var idx: int = ts["stepIdx"]
		if idx < 0 or idx >= steps.size() or steps[idx] == null:
			continue
		var target = steps[idx]["target"]
		if target == null or not objects.has(target):
			continue
		var o: Dictionary = objects[target]
		var pulse := 1.0 + sin(now / 220.0) * 0.05
		var rx := (float(o["hitW"]) / 2.0) * pulse
		var ry := (float(o["hitH"]) / 2.0) * 0.6 * pulse
		U.fill_ellipse(self, o["x"], o["y"], rx, ry, U.hex_a(U.C["highlight"], 0.4))
		U.stroke_ellipse(self, o["x"], o["y"], rx, ry, U.hex_a(U.C["sunny"], 0.85), 3)

	# Steam while the stove has a pan on it, smoke once it has charred.
	var cooking = tasks.get("cooking", null)
	if cooking != null and objects.has("stove"):
		var stove: Dictionary = objects["stove"]
		var sx := float(stove["x"])
		var sy := float(stove["y"])
		if int(cooking["stepIdx"]) == 3:
			var t := fmod(now / 260.0, 1.0)
			var col := U.hex_a(U.C["paperSolid"], 0.9 - t * 0.8)
			draw_polyline(U.quad_points(
				Vector2(sx - 8, sy - 40 - t * 18), Vector2(sx - 2, sy - 50 - t * 18), Vector2(sx - 8, sy - 60 - t * 18)
			), col, 3, true)
			draw_polyline(U.quad_points(
				Vector2(sx + 8, sy - 42 - t * 18), Vector2(sx + 14, sy - 52 - t * 18), Vector2(sx + 8, sy - 62 - t * 18)
			), col, 3, true)
		if bool(cooking.get("burned", false)):
			U.fill_circle(self, sx, sy - 70, 12, U.hex_a(ink, 0.45))
			U.fill_circle(self, sx + 10, sy - 86, 9, U.hex_a(ink, 0.45))

	# Washer / dryer rumble while their timers run, with a countdown badge —
	# the one place a raw number beats a ring, because she is deciding whether
	# there is time to start something else.
	var laundry = tasks.get("laundry", null)
	if laundry != null and bool(laundry.get("waiting", false)) and laundry.get("timerEnd", null) != null:
		var running_washer: bool = int(laundry["stepIdx"]) == 5
		var machine_id := "washer" if running_washer else "dryer"
		if objects.has(machine_id):
			var m: Dictionary = objects[machine_id]
			var mx := float(m["x"])
			var my := float(m["y"])
			var r := sin(now / 80.0) * 2.0
			U.stroke_ellipse(self, mx + r, my + 10, 30, 16, U.hex_a(ink, 0.35), 2.5)
			var left := maxf(0.0, ceil(float(laundry["timerEnd"]) - float(v["t"])))
			U.fill_circle(self, mx, my - 52, 14, U.C["paperSolid"])
			U.stroke_circle(self, mx, my - 52, 14, ink, 2.5)
			U.text(self, "%d" % int(left), mx, my - 51, 12, 800, ink, "center")

	# Kid acting out — only while the demand is live.
	var kids = tasks.get("kids", null)
	if kids != null and kids.get("kidSpot", null) != null and objects.has(kids["kidSpot"]):
		var o: Dictionary = objects[kids["kidSpot"]]
		var wob := sin(now / 140.0) * 4.0
		var kx := float(o["x"])
		var ky := float(o["y"]) + wob * 0.4
		U.fill_rr(self, kx - 10, ky - 18, 20, 24, 8, U.C["sky"])
		U.stroke_rr(self, kx - 10, ky - 18, 20, 24, 8, ink, 2.5)
		U.fill_circle(self, kx, ky - 24, 8, U.C["kidSkin"])
		U.stroke_circle(self, kx, ky - 24, 8, ink, 2.5)

	# The baby: a crying bubble while the diaper demand is on the board.
	var wants_diaper := false
	for q in v.get("queue", []):
		if q["key"] == "diaper":
			wants_diaper = true
			break
	if wants_diaper and objects.has("baby"):
		var baby: Dictionary = objects["baby"]
		var bob := sin(now / 200.0) * 2.0
		var bx := float(baby["x"]) + 18.0
		var by := float(baby["y"]) - 28.0 + bob
		U.fill_circle(self, bx, by, 12, U.C["paperSolid"])
		U.stroke_circle(self, bx, by, 12, U.C["bad"], 2)
		U.fill_circle(self, bx, by + 2, 4, U.C["sky"])

	# Hover affordance — every interactive object gets a soft glow ring under
	# the cursor, so what is live can be seen without reading anything.
	var hover: String = game.hover
	if hover != "" and objects.has(hover):
		var o: Dictionary = objects[hover]
		var pulse := 1.05 + sin(now / 220.0) * 0.04
		var rx := (maxf(44.0, float(o["hitW"])) / 2.0) * pulse
		var ry := (maxf(44.0, float(o["hitH"])) / 2.0) * 0.62 * pulse
		U.stroke_ellipse(self, o["x"], o["y"], rx, ry, U.hex_a(U.C["sunny"], 0.95), 3.5)
		U.fill_ellipse(self, o["x"], o["y"], rx, ry, U.hex_a(U.C["highlight"], 0.22))
