## The Canvas2D primitives the browser client leaned on, as Godot draw calls.
##
## `public/client.js` built its whole look out of five helpers — `rr()` rounded
## rects, `circle()`, `hexA()`, `fitText()` and ellipse arcs. Godot's `_draw()`
## has `draw_rect` and `draw_circle` but no rounded rect, no ellipse and no
## quadratic curve, so those are rebuilt here as point generators. Keeping them
## in one file is what let the HUD be transcribed almost line-for-line instead
## of redesigned.
##
## Every function takes the CanvasItem to draw into, so these stay static and
## any node can use them.
class_name DrawUtil
extends RefCounted

## The warm casual-cartoon palette, straight from the `C` object in client.js.
## Sunny yellows, terracotta, sage, warm wood — and never pure black: the
## outlines are `ink`, a dark brown.
const C := {
	"bg": Color(0.952941, 0.913725, 0.823529),        # cream wall backdrop
	"floorA": Color(0.905882, 0.827451, 0.682353),    # honey wood floor
	"floorB": Color(0.850980, 0.745098, 0.576471),    # shadow wood
	"ink": Color(0.290196, 0.207843, 0.149020),       # dark-brown outlines
	"inkSoft": Color(0.290196, 0.207843, 0.149020, 0.55),
	"paper": Color(1.0, 0.984314, 0.941176, 0.92),
	"paperSolid": Color(1.0, 0.984314, 0.941176),
	"terracotta": Color(0.850980, 0.494118, 0.290196),
	"sunny": Color(0.949020, 0.701961, 0.239216),
	"sage": Color(0.560784, 0.682353, 0.482353),
	"rose": Color(0.850980, 0.541176, 0.580392),
	"sky": Color(0.658824, 0.796078, 0.878431),
	"warn": Color(0.878431, 0.690196, 0.290196),
	"bad": Color(0.788235, 0.352941, 0.290196),
	"ok": Color(0.498039, 0.682353, 0.427451),
	"highlight": Color(1.0, 0.909804, 0.658824),      # hover glow
	"shadow": Color(0.290196, 0.207843, 0.149020, 0.18),
	# props the painted background does not contain
	"cribPink": Color(0.909804, 0.705882, 0.768627),
	"changingWood": Color(0.658824, 0.498039, 0.321569),
	"pailGrey": Color(0.788235, 0.811765, 0.839216),
	"kidSkin": Color(0.949020, 0.784314, 0.607843),
}

const FONT_PATH := "res://assets/fonts/Nunito.ttf"

## Nunito is a variable font, so the client's 500/600/700/800 weights survive
## the port as FontVariation instances rather than collapsing to one face.
static var _font_cache: Dictionary = {}
static var _base_font: FontFile = null


static func hex_a(color: Color, a: float) -> Color:
	return Color(color.r, color.g, color.b, a)


static func font_for(weight: int, spacing: float = 0.0) -> Font:
	var key := "%d:%s" % [weight, spacing]
	if _font_cache.has(key):
		return _font_cache[key]
	if _base_font == null:
		_base_font = load(FONT_PATH)
	var fv := FontVariation.new()
	fv.base_font = _base_font
	fv.variation_opentype = {"wght": weight}
	if spacing > 0.0:
		fv.spacing_glyph = int(round(spacing))
	_font_cache[key] = fv
	return fv


## `fitText` — canvas draws with textBaseline "middle", Godot draws on the
## baseline, so the vertical centring is done here rather than at every call.
static func text(
	ci: CanvasItem,
	s: String,
	x: float,
	y: float,
	size: int,
	weight: int = 600,
	color: Color = C["ink"],
	align: String = "left",
	spacing: float = 0.0,
) -> void:
	var font := font_for(weight, spacing)
	var w := font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var ox := 0.0
	if align == "center":
		ox = -w / 2.0
	elif align == "right":
		ox = -w
	var baseline := y + (font.get_ascent(size) - font.get_descent(size)) / 2.0
	ci.draw_string(font, Vector2(x + ox, baseline), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)


static func text_width(s: String, size: int, weight: int = 600) -> float:
	return font_for(weight).get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x


# ── shapes ─────────────────────────────────────────────────────────────────

## Rounded-rect outline points, matching the four `arcTo` corners of `rr()`.
static func rr_points(x: float, y: float, w: float, h: float, r: float, seg: int = 6) -> PackedVector2Array:
	r = minf(r, minf(w, h) / 2.0)
	var pts := PackedVector2Array()
	# corner centres, clockwise from top-left
	var corners := [
		[Vector2(x + r, y + r), PI, 1.5 * PI],
		[Vector2(x + w - r, y + r), 1.5 * PI, TAU],
		[Vector2(x + w - r, y + h - r), 0.0, 0.5 * PI],
		[Vector2(x + r, y + h - r), 0.5 * PI, PI],
	]
	for c in corners:
		var centre: Vector2 = c[0]
		var a0: float = c[1]
		var a1: float = c[2]
		for i in range(seg + 1):
			var a: float = a0 + (a1 - a0) * (float(i) / float(seg))
			pts.append(centre + Vector2(cos(a), sin(a)) * r)
	return pts


static func fill_rr(ci: CanvasItem, x: float, y: float, w: float, h: float, r: float, color: Color) -> void:
	ci.draw_colored_polygon(rr_points(x, y, w, h, r), color)


static func stroke_rr(ci: CanvasItem, x: float, y: float, w: float, h: float, r: float, color: Color, width: float) -> void:
	var pts := rr_points(x, y, w, h, r)
	pts.append(pts[0])
	ci.draw_polyline(pts, color, width, true)


static func ellipse_points(cx: float, cy: float, rx: float, ry: float, seg: int = 48) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(seg):
		var a := TAU * float(i) / float(seg)
		pts.append(Vector2(cx + cos(a) * rx, cy + sin(a) * ry))
	return pts


static func fill_ellipse(ci: CanvasItem, cx: float, cy: float, rx: float, ry: float, color: Color) -> void:
	ci.draw_colored_polygon(ellipse_points(cx, cy, rx, ry), color)


static func stroke_ellipse(ci: CanvasItem, cx: float, cy: float, rx: float, ry: float, color: Color, width: float) -> void:
	var pts := ellipse_points(cx, cy, rx, ry)
	pts.append(pts[0])
	ci.draw_polyline(pts, color, width, true)


static func fill_circle(ci: CanvasItem, cx: float, cy: float, r: float, color: Color) -> void:
	ci.draw_circle(Vector2(cx, cy), r, color)


static func stroke_circle(ci: CanvasItem, cx: float, cy: float, r: float, color: Color, width: float) -> void:
	ci.draw_arc(Vector2(cx, cy), r, 0.0, TAU, 48, color, width, true)


## A partial ring, for the patience drains and the clock's round timer.
static func stroke_arc(ci: CanvasItem, cx: float, cy: float, r: float, from: float, to: float, color: Color, width: float) -> void:
	if absf(to - from) < 0.0001:
		return
	ci.draw_arc(Vector2(cx, cy), r, from, to, 48, color, width, true)


## Canvas `quadraticCurveTo`, sampled. Used by the steam wisps and the icon
## glyphs, where the curve shape is the whole point of the mark.
static func quad_points(p0: Vector2, ctrl: Vector2, p1: Vector2, seg: int = 12) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(seg + 1):
		var t := float(i) / float(seg)
		var u := 1.0 - t
		pts.append(p0 * (u * u) + ctrl * (2.0 * u * t) + p1 * (t * t))
	return pts


static func cubic_points(p0: Vector2, c1: Vector2, c2: Vector2, p1: Vector2, seg: int = 16) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(seg + 1):
		var t := float(i) / float(seg)
		var u := 1.0 - t
		pts.append(p0 * (u * u * u) + c1 * (3.0 * u * u * t) + c2 * (3.0 * u * t * t) + p1 * (t * t * t))
	return pts


static func line(ci: CanvasItem, a: Vector2, b: Vector2, color: Color, width: float) -> void:
	ci.draw_line(a, b, color, width, true)


## The five-pointed star used by the score meter and the end card.
static func star(ci: CanvasItem, x: float, y: float, r: float, fill: Color, ink: Color, width: float = 2.5) -> void:
	var pts := PackedVector2Array()
	for i in range(5):
		var a := deg_to_rad(-90.0 + i * 72.0)
		var a2 := deg_to_rad(-90.0 + i * 72.0 + 36.0)
		pts.append(Vector2(x + cos(a) * r, y + sin(a) * r))
		pts.append(Vector2(x + cos(a2) * r * 0.45, y + sin(a2) * r * 0.45))
	ci.draw_colored_polygon(pts, fill)
	var outline := pts.duplicate()
	outline.append(pts[0])
	ci.draw_polyline(outline, ink, width, true)


## A horizontal two-stop gradient bar, standing in for the canvas
## `createLinearGradient` on the score meter. Godot interpolates per-vertex
## colours across a polygon, so the rounded shape and the gradient come out of
## a single `draw_polygon` — no shader, no square corners.
static func fill_rr_gradient(
	ci: CanvasItem, x: float, y: float, w: float, h: float, r: float, from: Color, to: Color
) -> void:
	if w <= 0.0:
		return
	var pts := rr_points(x, y, w, h, r)
	var colors := PackedColorArray()
	for p in pts:
		colors.append(from.lerp(to, clampf((p.x - x) / w, 0.0, 1.0)))
	ci.draw_polygon(pts, colors)
