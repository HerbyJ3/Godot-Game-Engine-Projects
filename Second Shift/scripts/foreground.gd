## Depth sorting, the way the painted art allows it.
##
## `home.png` is exactly world-sized, so re-drawing a furniture-shaped rect
## FROM the background AT its own position paints that furniture back over
## whatever was drawn in between — which is Ruth. Each cut carries the `baseY`
## where the object meets the floor: when her feet are above that line she is
## standing behind the object, so the cut redraws and occludes her.
##
## This is `FG_CUTS` / `drawForeground` from public/client.js, kept literally
## rather than replaced with `y_sort_enabled`. The rects are hand-tuned to the
## painted image; y-sorting only becomes the better answer once each prop is
## its own texture.
extends Node2D

const World := preload("res://scripts/world.gd")

## x, y, w, h of the region in home.png; baseY is the floor contact line.
const CUTS := [
	{"rect": Rect2(222, 214, 86, 74), "baseY": 285.0},   # kitchen table
	{"rect": Rect2(610, 362, 172, 102), "baseY": 462.0}, # couch
	{"rect": Rect2(582, 92, 180, 80), "baseY": 168.0},   # office desk
	{"rect": Rect2(642, 135, 62, 70), "baseY": 202.0},   # desk chair
	{"rect": Rect2(766, 196, 90, 70), "baseY": 262.0},   # kids' desk
	{"rect": Rect2(72, 398, 80, 74), "baseY": 468.0},    # washer
	{"rect": Rect2(150, 398, 80, 74), "baseY": 468.0},   # dryer
]

## The client-drawn nursery props occlude her the same way; their bases sit at
## roughly y=567.
const NURSERY_BASE_Y := 567.0

@onready var game: Node = owner

var _home: Texture2D


func _ready() -> void:
	_home = load("res://assets/art/home.png")


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	var v: Dictionary = game.view
	if v.is_empty() or _home == null:
		return
	var feet_y: float = game.ruth_feet_y()

	for cut in CUTS:
		if feet_y < float(cut["baseY"]):
			var r: Rect2 = cut["rect"]
			draw_texture_rect_region(_home, r, r)

	if feet_y < NURSERY_BASE_Y:
		World.draw_nursery(self, v, float(Time.get_ticks_msec()))
