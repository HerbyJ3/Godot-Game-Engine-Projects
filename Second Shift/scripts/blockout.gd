## Blockout mode. Press F4 in game.
##
## Hides the painted art and draws the level as flat coloured rooms with
## labelled boxes for props. Ruth keeps her sprite, because her size against a
## doorway is the one read that actually matters.
##
## ROADMAP.md Phase B3 asks for a full round played as coloured boxes **before
## any art is commissioned**, and this is the thing that makes that possible.
## The F3 nav overlay draws on top of `home.png`, so the painting still carries
## the judgement — which is the exact influence B3 exists to remove. A layout
## mistake found here costs an edit; found after the art, it costs the art.
##
## This node sits between the background and Ruth in the scene so its fills
## land UNDER her. The F3 annotations stay above everything, so the two modes
## compose: F4 for the layout, F3 for the derived navigation on top of it.
extends Node2D

const Level := preload("res://scripts/levels/her_morning.gd")
const U := preload("res://scripts/draw_util.gd")

## Anything not inside a floor rect reads as solid not-floor, so the walkable
## shape of the house is unmistakable.
const VOID := Color(0.16, 0.14, 0.17)

## One colour per room. A room missing from here still draws — it falls back to
## a hash of its name — so adding a room to FLOORS never silently renders black.
const ROOM_COLOURS := {
	"kitchen": Color(0.85, 0.62, 0.42),
	"hall": Color(0.80, 0.68, 0.46),
	"office": Color(0.78, 0.66, 0.34),
	"laundry": Color(0.48, 0.62, 0.74),
	"living": Color(0.76, 0.52, 0.58),
	"nursery": Color(0.66, 0.56, 0.74),
}

## Doorway rects are tinted brighter than the rooms they join: a link that is
## too narrow to walk is the single easiest way to break the map, and it should
## be impossible to miss here.
const LINK_TINT := Color(0.42, 0.80, 0.56)

@onready var game: Node = owner

var shown := false

var _hidden_when_on: Array[Node2D] = []


func _ready() -> void:
	visible = false
	# The art layers this mode stands in for. Resolved once; a missing node is
	# skipped rather than crashing, so the scene can be rearranged freely.
	for path in ["../Background", "../Overlays", "../Foreground"]:
		var n := get_node_or_null(path)
		if n is Node2D:
			_hidden_when_on.append(n)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and (event as InputEventKey).keycode == KEY_F4:
		set_shown(not shown)
		get_viewport().set_input_as_handled()


func set_shown(value: bool) -> void:
	shown = value
	visible = value
	for n in _hidden_when_on:
		n.visible = not value
	queue_redraw()


func _process(_delta: float) -> void:
	if shown:
		queue_redraw()


func _fallback_colour(key: String) -> Color:
	# Deterministic per name, and kept mid-value so labels stay readable on it.
	var h := float(abs(key.hash()) % 360) / 360.0
	return Color.from_hsv(h, 0.35, 0.72)


func _draw() -> void:
	if not shown:
		return

	draw_rect(Rect2(Vector2.ZERO, Level.WORLD), VOID)

	# ── rooms
	for key in Level.FLOORS:
		var r: Rect2 = Level.FLOORS[key]
		var is_link: bool = key.ends_with("Link")
		var base: Color = ROOM_COLOURS.get(key, _fallback_colour(key))
		if is_link:
			base = base.lerp(LINK_TINT, 0.55)
		draw_rect(r, base)
		draw_rect(r, base.darkened(0.35), false, 2.0)
		U.text(self, key, r.position.x + 5, r.position.y + 11, 10, 800, base.darkened(0.6))

	# ── props: where it is PAINTED vs where it BLOCKS
	# Keeping those two visually distinct is the main thing a layout review
	# needs, and the gap between them is exactly where the geometry bugs lived.
	for id in Level.PROPS:
		var prop: Dictionary = Level.PROPS[id]
		var art: Rect2 = prop["art"]
		var foot: Rect2 = prop["foot"]
		var blocks := bool(prop["blocks"])

		# footprint first, so the art box reads on top of it
		var foot_col := Color(0.90, 0.32, 0.28, 0.55) if blocks else Color(0.55, 0.55, 0.60, 0.30)
		draw_rect(foot, foot_col)
		draw_rect(foot, Color(0.55, 0.14, 0.12) if blocks else Color(0.40, 0.40, 0.45), false, 1.5)

		draw_rect(art, Color(0.18, 0.15, 0.12, 0.18))
		draw_rect(art, Color(0.18, 0.15, 0.12, 0.75), false, 1.5)
		U.text(self, id, art.position.x + 3, art.position.y + 9, 9, 700, Color(0.12, 0.10, 0.08))

	_draw_legend()


func _draw_legend() -> void:
	var x := 8.0
	var y := Level.WORLD.y - 54.0
	U.fill_rr(self, x - 4, y - 12, 250, 46, 6, Color(0.10, 0.09, 0.11, 0.80))
	U.text(self, "F4 blockout · F3 nav data", x, y, 11, 800, Color(1, 1, 1))
	draw_rect(Rect2(x, y + 10, 14, 9), Color(0.90, 0.32, 0.28, 0.75))
	U.text(self, "blocks", x + 19, y + 15, 9, 600, Color(0.92, 0.92, 0.95))
	draw_rect(Rect2(x + 64, y + 10, 14, 9), Color(0.18, 0.15, 0.12, 0.30))
	U.text(self, "painted", x + 83, y + 15, 9, 600, Color(0.92, 0.92, 0.95))
	draw_rect(Rect2(x + 134, y + 10, 14, 9), LINK_TINT)
	U.text(self, "doorway", x + 153, y + 15, 9, 600, Color(0.92, 0.92, 0.95))
