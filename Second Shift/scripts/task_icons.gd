## The demand glyphs — a pot, a diaper, a washing machine, an envelope, a
## crayon scribble, a heart, a phone handset.
##
## These are drawn rather than shipped as textures for the same reason the
## browser client drew them: they scale to any bubble size, they take the
## bubble's ink colour, and adding a new demand type never waits on an asset.
## Ported shape-for-shape from `drawTaskIcon` in public/client.js.
class_name TaskIcons
extends RefCounted

const U := preload("res://scripts/draw_util.gd")

## Task key -> glyph. Anything unmapped falls back to "laundry".
const FOR_TASK := {
	"laundry": "laundry",
	"cooking": "cooking",
	"diaper": "diaper",
	"email": "email",
	"kids": "kid",
	"self": "self",
	"phone": "phone",
}


static func draw_icon(ci: CanvasItem, kind: String, x: float, y: float, s: float, color: Color) -> void:
	var lw := maxf(2.0, s * 0.14)
	var o := Vector2(x, y)

	match kind:
		"cooking":
			# a pot with steam
			U.stroke_rr(ci, x - s * 0.5, y - s * 0.15, s, s * 0.6, s * 0.12, color, lw)
			U.line(ci, o + Vector2(-s * 0.5, -s * 0.15), o + Vector2(s * 0.5, -s * 0.15), color, lw)
			# handles
			U.line(ci, o + Vector2(-s * 0.62, -s * 0.05), o + Vector2(-s * 0.5, -s * 0.05), color, lw)
			U.line(ci, o + Vector2(s * 0.5, -s * 0.05), o + Vector2(s * 0.62, -s * 0.05), color, lw)
			# steam
			ci.draw_polyline(U.quad_points(
				o + Vector2(-s * 0.15, -s * 0.3), o + Vector2(-s * 0.05, -s * 0.45), o + Vector2(-s * 0.15, -s * 0.6)
			), color, lw, true)
			ci.draw_polyline(U.quad_points(
				o + Vector2(s * 0.15, -s * 0.3), o + Vector2(s * 0.25, -s * 0.45), o + Vector2(s * 0.15, -s * 0.6)
			), color, lw, true)

		"diaper":
			# a folded diaper: body + two wing flaps + pins
			var body := PackedVector2Array()
			body.append_array(U.quad_points(
				o + Vector2(-s * 0.5, -s * 0.25), o + Vector2(0, -s * 0.05), o + Vector2(s * 0.5, -s * 0.25)
			))
			body.append(o + Vector2(s * 0.42, s * 0.35))
			body.append_array(U.quad_points(
				o + Vector2(s * 0.42, s * 0.35), o + Vector2(0, s * 0.6), o + Vector2(-s * 0.42, s * 0.35)
			))
			body.append(o + Vector2(-s * 0.5, -s * 0.25))
			ci.draw_polyline(body, color, lw, true)
			U.line(ci, o + Vector2(-s * 0.5, -s * 0.25), o + Vector2(-s * 0.42, s * 0.35), color, lw)
			U.line(ci, o + Vector2(s * 0.5, -s * 0.25), o + Vector2(s * 0.42, s * 0.35), color, lw)
			U.fill_circle(ci, x - s * 0.34, y - s * 0.05, s * 0.08, color)
			U.fill_circle(ci, x + s * 0.34, y - s * 0.05, s * 0.08, color)

		"breakfast":
			# frying pan
			U.stroke_circle(ci, x, y + 2.0, s * 0.5, color, lw)
			U.line(ci, o + Vector2(s * 0.5, 2.0), o + Vector2(s * 0.85, -s * 0.1), color, lw)
			U.fill_circle(ci, x, y + 2.0, s * 0.2, U.C["paperSolid"])
			U.fill_circle(ci, x, y + 2.0, s * 0.09, U.C["sunny"])

		"laundry":
			U.stroke_rr(ci, x - s * 0.55, y - s * 0.5, s * 1.1, s * 1.05, s * 0.16, color, lw)
			U.stroke_circle(ci, x, y + s * 0.06, s * 0.24, color, lw)
			U.line(ci, o + Vector2(-s * 0.3, -s * 0.32), o + Vector2(-s * 0.12, -s * 0.32), color, lw)
			U.line(ci, o + Vector2(s * 0.1, -s * 0.32), o + Vector2(s * 0.3, -s * 0.32), color, lw)

		"bottle":
			U.stroke_rr(ci, x - s * 0.28, y - s * 0.4, s * 0.56, s * 0.85, s * 0.14, color, lw)
			U.stroke_rr(ci, x - s * 0.16, y - s * 0.62, s * 0.32, s * 0.24, s * 0.08, color, lw)
			U.line(ci, o + Vector2(-s * 0.18, s * 0.05), o + Vector2(s * 0.18, s * 0.05), color, lw)

		"email":
			U.stroke_rr(ci, x - s * 0.6, y - s * 0.42, s * 1.2, s * 0.84, s * 0.1, color, lw)
			ci.draw_polyline(PackedVector2Array([
				o + Vector2(-s * 0.6, -s * 0.42), o + Vector2(0, s * 0.05), o + Vector2(s * 0.6, -s * 0.42),
			]), color, lw, true)

		"kid":
			# crayon scribble
			var a := PackedVector2Array()
			a.append_array(U.quad_points(
				o + Vector2(-s * 0.5, -s * 0.1), o + Vector2(-s * 0.2, -s * 0.5), o + Vector2(0, -s * 0.15)
			))
			a.append_array(U.quad_points(
				o + Vector2(0, -s * 0.15), o + Vector2(s * 0.2, s * 0.2), o + Vector2(s * 0.5, -s * 0.05)
			))
			ci.draw_polyline(a, color, lw, true)
			ci.draw_polyline(U.quad_points(
				o + Vector2(-s * 0.5, s * 0.3), o + Vector2(-s * 0.1, s * 0.05), o + Vector2(s * 0.3, s * 0.35)
			), color, lw, true)

		"self":
			# a heart — the one demand that is hers
			var heart := PackedVector2Array()
			heart.append_array(U.cubic_points(
				o + Vector2(0, s * 0.5), o + Vector2(-s * 0.7, s * 0.05),
				o + Vector2(-s * 0.55, -s * 0.5), o + Vector2(0, -s * 0.15)
			))
			heart.append_array(U.cubic_points(
				o + Vector2(0, -s * 0.15), o + Vector2(s * 0.55, -s * 0.5),
				o + Vector2(s * 0.7, s * 0.05), o + Vector2(0, s * 0.5)
			))
			ci.draw_polyline(heart, color, lw, true)

		"phone":
			var handset := PackedVector2Array()
			handset.append_array(U.quad_points(
				o + Vector2(-s * 0.42, -s * 0.1), o + Vector2(0, -s * 0.55), o + Vector2(s * 0.42, -s * 0.1)
			))
			handset.append(o + Vector2(s * 0.28, s * 0.1))
			handset.append_array(U.quad_points(
				o + Vector2(s * 0.28, s * 0.1), o + Vector2(0, -s * 0.12), o + Vector2(-s * 0.28, s * 0.1)
			))
			handset.append(o + Vector2(-s * 0.42, -s * 0.1))
			ci.draw_polyline(handset, color, lw, true)


## What she is carrying, as a glyph. The chain steps hand back raw carry names
## ("ingredients", "plated", "baby"), which map onto the demand icons.
static func for_carry(carry: String) -> String:
	match carry:
		"ingredients", "plated":
			return "cooking"
		"diaper", "baby":
			return "diaper"
		_:
			return "laundry"
