## The authoring instrument. Press F3 in game.
##
## Draws what `nav.gd` derived on top of the live scene: walkable cells, the
## floor rectangles they came from, each prop's blocking footprint, and the
## anchor she will actually stand on with the direction she will face.
##
## This exists because the whole class of bug we hit was invisible without it.
## A footprint that does not match the art, a doorway too narrow to walk, a
## room accidentally cut off from the house — all of them are obvious here and
## all of them are silent in the running game until something looks wrong much
## later. Phase B of ROADMAP.md is authoring the floor plan against this view.
extends Node2D

const Nav := preload("res://scripts/nav.gd")
const Level := preload("res://scripts/levels/her_morning.gd")
const U := preload("res://scripts/draw_util.gd")

@onready var game: Node = owner

var shown := false


func _ready() -> void:
	z_index = 100
	visible = false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and (event as InputEventKey).keycode == KEY_F3:
		shown = not shown
		visible = shown
		queue_redraw()
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if shown:
		queue_redraw()


func _draw() -> void:
	if not shown:
		return

	# walkable cells
	var cell := Nav.CELL
	for cy in Nav.rows():
		for cx in Nav.cols():
			if Nav.is_walkable(Vector2i(cx, cy)):
				draw_rect(Rect2(cx * cell, cy * cell, cell - 1, cell - 1), Color(0.2, 0.9, 0.4, 0.22))

	# the floor rects the grid was built from
	for k in Level.FLOORS:
		var r: Rect2 = Level.FLOORS[k]
		draw_rect(r, Color(0.3, 0.8, 1.0, 0.9), false, 2.0)
		U.text(self, k, r.position.x + 4, r.position.y + 10, 10, 700, Color(0.3, 0.8, 1.0))

	# props: blocking footprints solid, non-blocking dashed-ish
	for id in Level.PROPS:
		var prop: Dictionary = Level.PROPS[id]
		var foot: Rect2 = prop["foot"]
		var blocks := bool(prop["blocks"])
		draw_rect(foot, Color(1, 0.3, 0.3, 0.95 if blocks else 0.35), false, 2.0)

		var a := Nav.anchor(id)
		if a.is_empty():
			continue
		var pos: Vector2 = a["pos"]
		# the anchor, and the way she turns on arrival
		draw_circle(pos, 4.0, Color(1, 0.9, 0.2))
		draw_arc(pos, 6.0, 0, TAU, 16, Color(0.2, 0.15, 0.1), 1.5)
		var dir := Vector2.ZERO
		match String(a["facing"]):
			"up": dir = Vector2(0, -1)
			"down": dir = Vector2(0, 1)
			"left": dir = Vector2(-1, 0)
			"right": dir = Vector2(1, 0)
		draw_line(pos, pos + dir * 14.0, Color(1, 0.9, 0.2), 2.0)
		U.text(self, id, pos.x + 8, pos.y - 8, 9, 700, Color(0.15, 0.1, 0.05))

	# her live route
	var v: Dictionary = game.view
	if not v.is_empty():
		var p: Dictionary = v["player"]
		var order: Dictionary = p["order"]
		if order["mode"] == "walk" and order["to"] != null:
			var pts := PackedVector2Array([Vector2(p["x"], p["y"]), Vector2(order["to"]["x"], order["to"]["y"])])
			for wp in order.get("path", []):
				pts.append(Vector2(wp["x"], wp["y"]))
			draw_polyline(pts, Color(1, 0.2, 0.8, 0.9), 2.5)
			for wp in pts:
				draw_circle(wp, 3.0, Color(1, 0.2, 0.8))

	var s := Nav.stats()
	U.text(self, "F3  grid %dx%d  walkable %d  island %d  %s" % [
		s["cols"], s["rows"], s["walkable"], s["largest_island"],
		"connected" if s["walkable"] == s["largest_island"] else "SPLIT"],
		8, 620, 12, 800, Color(1, 1, 1))
