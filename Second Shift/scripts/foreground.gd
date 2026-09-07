## Depth: the props that redraw ON TOP of Ruth.
##
## `home.png` already contains every prop painted in place, so a prop she is
## standing BEHIND is the only case that needs anything drawn — the background
## is correct for everything else. This layer sits above her in the scene and
## redraws exactly those props.
##
## Two ways to draw one, chosen per prop in `props.gd`:
##
##   * an alpha CUTOUT, drawn at the prop's own position — it lands over its
##     own painted copy, so only the furniture's silhouette covers her;
##   * failing that, the prop's RECTANGLE re-blitted out of `home.png`. This is
##     the original trick from the browser build. It works, but a rectangle
##     near a neighbour also redraws the neighbour, so her head can disappear
##     while she stands beside a tall prop rather than behind it.
##
## Dropping `assets/art/props/<id>.png` next to a manifest entry upgrades that
## prop from the second to the first with no code change.
extends Node2D

const World := preload("res://scripts/world.gd")
const Props := preload("res://scripts/props.gd")

## The client-drawn nursery props (crib, changing table, pail) are not in the
## painted image at all — `world.gd` draws them — so they occlude her the same
## way, off their shared floor line.
const NURSERY_BASE_Y := 567.0

@onready var game: Node = owner

var _home: Texture2D
## id -> Texture2D, resolved once. A prop with no cutout maps to null and takes
## the region path; `assets/art/props/` is only scanned at load.
var _cutouts := {}


func _ready() -> void:
	_home = load("res://assets/art/home.png")
	for id in Props.PROPS:
		_cutouts[id] = Props.texture_for(id)


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	var v: Dictionary = game.view
	if v.is_empty() or _home == null:
		return
	var feet_y: float = game.ruth_feet_y()

	for id in Props.sorted_ids():
		var prop: Dictionary = Props.PROPS[id]
		# Her feet above the floor line means she is behind it.
		if feet_y >= float(prop["base_y"]):
			continue
		var region: Rect2 = prop["region"]
		var cutout: Texture2D = _cutouts.get(id, null)
		if cutout != null:
			# Cutouts are authored at their region's size and position, so they
			# need no offset — they land on their own painted copy.
			draw_texture(cutout, prop.get("pos", region.position))
		else:
			draw_texture_rect_region(_home, region, region)

	if feet_y < NURSERY_BASE_Y:
		World.draw_nursery(self, v, float(Time.get_ticks_msec()))


## How many props are still on the rectangle fallback. Printed by the smoke
## test so the art backlog is visible rather than something you notice later
## as a graphical glitch.
func pending_cutouts() -> Array:
	var pending := []
	for id in Props.PROPS:
		if _cutouts.get(id, null) == null and bool(Props.PROPS[id].get("needs_cutout", false)):
			pending.append(id)
	return pending
