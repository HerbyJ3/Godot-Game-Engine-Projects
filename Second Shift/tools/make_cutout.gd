## Cut a prop out of home.png into an alpha PNG, locally.
##
##   godot --headless --path . --script res://tools/make_cutout.gd -- toyBox basket
##
## The painted art is drawn with a dark outline around every object, which is
## exactly what a flood fill needs to stop at. So: start from the region's
## border pixels (which are floor or wall by construction), grow inward while
## each step stays close in colour to the pixel it came from, and mark
## everything reached as background. The outline halts the fill; the prop keeps
## its own pixels.
##
## Region growing rather than "match the corner colour" because the floor and
## wall are shaded gradients — a single reference colour either leaks through
## the outline or leaves a halo.
##
## Output goes to assets/art/props/<id>.png at the prop's exact region size, so
## `foreground.gd` picks it up with no code change and it lands over its own
## painted copy in the background.
extends SceneTree

const Props := preload("res://scripts/props.gd")

## How far a neighbouring pixel may drift and still count as more background.
## Higher leaks through soft outlines; lower leaves a halo of floor around the
## prop. 0.055 was tuned against the toy box, which is the hardest case (a
## light wooden box on a light wall).
const TOLERANCE := 0.055

## Pixels this close to fully background are faded rather than cut, so the
## silhouette does not alias against the background it sits on.
const FEATHER := 1


static func _dist(a: Color, b: Color) -> float:
	return (absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)) / 3.0


func _cut(home: Image, id: String, tol: float) -> void:
	var region: Rect2 = Props.PROPS[id]["region"]
	var r := Rect2i(region)
	var img := home.get_region(r)
	img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()

	var is_bg := PackedByteArray()
	is_bg.resize(w * h)
	var queue: Array[Vector2i] = []

	# Seed from every border pixel — by construction the region is padded out
	# to floor/wall on all four sides.
	for x in w:
		for y in [0, h - 1]:
			if is_bg[y * w + x] == 0:
				is_bg[y * w + x] = 1
				queue.append(Vector2i(x, y))
	for y in h:
		for x in [0, w - 1]:
			if is_bg[y * w + x] == 0:
				is_bg[y * w + x] = 1
				queue.append(Vector2i(x, y))

	var head := 0
	while head < queue.size():
		var p: Vector2i = queue[head]
		head += 1
		var pc := img.get_pixelv(p)
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = p + d
			if n.x < 0 or n.y < 0 or n.x >= w or n.y >= h:
				continue
			var idx := n.y * w + n.x
			if is_bg[idx] != 0:
				continue
			if _dist(pc, img.get_pixelv(n)) <= tol:
				is_bg[idx] = 1
				queue.append(n)

	# Drop everything except the main mass. The painted outlines the fill stops
	# at include the skirting board and the floor's own line work, so what
	# survives the fill is the prop PLUS a few detached streaks and, at the toy
	# box, a toy car sitting on the floor beside it. Those would draw over her
	# as stray marks. Keeping only the largest connected component removes them
	# — and a toy on the floor beside the box should not occlude her anyway.
	var label := PackedInt32Array()
	label.resize(w * h)
	label.fill(0)
	var best_label := 0
	var best_size := 0
	var next_label := 0
	for sy in h:
		for sx in w:
			var start := sy * w + sx
			if is_bg[start] != 0 or label[start] != 0:
				continue
			next_label += 1
			var size := 0
			var stack: Array[Vector2i] = [Vector2i(sx, sy)]
			label[start] = next_label
			while not stack.is_empty():
				var q: Vector2i = stack.pop_back()
				size += 1
				for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var n: Vector2i = q + d
					if n.x < 0 or n.y < 0 or n.x >= w or n.y >= h:
						continue
					var ni := n.y * w + n.x
					if is_bg[ni] != 0 or label[ni] != 0:
						continue
					label[ni] = next_label
					stack.append(n)
			if size > best_size:
				best_size = size
				best_label = next_label
	var islands := 0
	for i in w * h:
		if is_bg[i] == 0 and label[i] != best_label:
			is_bg[i] = 1
			islands += 1

	var cut := 0
	for y in h:
		for x in w:
			if is_bg[y * w + x] != 0:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
				cut += 1

	# Soften the boundary: a kept pixel touching a cut one goes half alpha.
	if FEATHER > 0:
		var edge: Array[Vector2i] = []
		for y in range(1, h - 1):
			for x in range(1, w - 1):
				if is_bg[y * w + x] != 0:
					continue
				if (is_bg[y * w + x - 1] != 0 or is_bg[y * w + x + 1] != 0
						or is_bg[(y - 1) * w + x] != 0 or is_bg[(y + 1) * w + x] != 0):
					edge.append(Vector2i(x, y))
		for e in edge:
			var c := img.get_pixelv(e)
			c.a = 0.55
			img.set_pixelv(e, c)

	DirAccess.make_dir_recursive_absolute("res://assets/art/props")
	var out := "res://assets/art/props/%s.png" % id
	img.save_png(out)
	print("%-8s %dx%d  kept %d px, cut %d (%.0f%% bg), dropped %d px of stray islands  -> %s" % [
		id, w, h, w * h - cut, cut, 100.0 * float(cut) / float(w * h), islands, out])


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var ids: Array = args if args.size() > 0 else ["toyBox", "basket"]
	var tol := TOLERANCE
	var home := Image.load_from_file("res://assets/art/home.png")
	home.convert(Image.FORMAT_RGBA8)
	for id in ids:
		if not Props.PROPS.has(id):
			printerr("unknown prop: %s" % id)
			continue
		_cut(home, String(id), tol)
	quit(0)
