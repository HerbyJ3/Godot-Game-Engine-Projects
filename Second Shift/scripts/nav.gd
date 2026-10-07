## Navigation: the walkable grid, the router, and the derived stand-at anchors.
##
## This replaces 34 hand-placed walkway nodes and 34 hand-written edges. Every
## one of those numbers was typed by a person looking at a picture, and nothing
## checked them — which is how `sinkNode` ended up standing her in the sink
## basin and `toyboxNode` inside the toy box among the bears.
##
## Here nothing is typed. The grid is `floors − blocking props`. An anchor is
## the nearest walkable cell on a prop's approach side. A generated anchor
## CANNOT be inside furniture, because the furniture was subtracted before the
## anchor was chosen: the bug class stops existing rather than being patched
## prop by prop.
##
## PURITY: everything here is a deterministic function of the level constants.
## The cached grid is a memo, not state — same level in, same grid out, always.
## `logic.gd` may call into it freely without breaking its own contract.
class_name Nav
extends RefCounted

const Level := preload("res://scripts/levels/her_morning.gd")

## Grid resolution. 8px gives 120x80 = 9600 cells: fine enough that a doorway
## never closes up, small enough that A* is microseconds.
const CELL := 8.0

## Her feet are an ellipse, not a point, and `logic.gd` slides her along
## footprint edges with this same pad. Growing the blocked rects by it here
## keeps the grid honest about where she can actually stand — taken from the
## rules rather than copied, so the two can never drift apart.
const Rules := preload("res://scripts/logic_data.gd")
const FOOT_RX := Rules.FOOT_RX
const FOOT_RY := Rules.FOOT_RY

## Cost of changing direction, in cells. Without it A* returns whichever of the
## many equal-length staircases it happens to expand first, and she zigzags
## across the house. With it she walks a long straight run and turns once,
## which is what the hand-authored corridors used to give.
const TURN_COST := 6.0

const DIR_E := 0
const DIR_W := 1
const DIR_S := 2
const DIR_N := 3
const DIR_NONE := 4
const STEPS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

static var _built := false
static var _cols := 0
static var _rows := 0
static var _walkable: PackedByteArray = PackedByteArray()
## prop id -> {"cell": Vector2i, "pos": Vector2, "facing": String}
static var _anchors: Dictionary = {}


# ── grid ───────────────────────────────────────────────────────────────────

static func _ensure() -> void:
	if _built:
		return
	_built = true
	_cols = int(Level.WORLD.x / CELL)
	_rows = int(Level.WORLD.y / CELL)
	_walkable.resize(_cols * _rows)

	for cy in _rows:
		for cx in _cols:
			var p := Vector2((cx + 0.5) * CELL, (cy + 0.5) * CELL)
			var on_floor := false
			for k in Level.FLOORS:
				if (Level.FLOORS[k] as Rect2).has_point(p):
					on_floor = true
					break
			if on_floor:
				for id in Level.PROPS:
					var prop: Dictionary = Level.PROPS[id]
					if not bool(prop["blocks"]):
						continue
					if (prop["foot"] as Rect2).grow_individual(FOOT_RX, FOOT_RY, FOOT_RX, FOOT_RY).has_point(p):
						on_floor = false
						break
			_walkable[cy * _cols + cx] = 1 if on_floor else 0

	_build_anchors()


static func _build_anchors() -> void:
	_anchors.clear()
	for id in Level.PROPS:
		var prop: Dictionary = Level.PROPS[id]
		var foot: Rect2 = prop["foot"]
		var approach: String = prop.get("approach", "south")
		# The point she is trying to reach: just outside the prop, centred on
		# the side she approaches from.
		var margin := CELL * 2.0
		var target: Vector2
		var facing: String
		match approach:
			"north":
				target = Vector2(foot.position.x + foot.size.x * 0.5, foot.position.y - margin)
				facing = "down"
			"south":
				target = Vector2(foot.position.x + foot.size.x * 0.5, foot.end.y + margin)
				facing = "up"
			"east":
				target = Vector2(foot.end.x + margin, foot.position.y + foot.size.y * 0.5)
				facing = "left"
			_:  # west
				target = Vector2(foot.position.x - margin, foot.position.y + foot.size.y * 0.5)
				facing = "right"

		var cell := _nearest_walkable(target)
		_anchors[id] = {
			"cell": cell,
			"pos": cell_centre(cell),
			"facing": facing,
		}


## The walkable cell closest to a world point. Expanding rings rather than a
## scan of all 9600 cells, so it stays cheap and always terminates on a real
## cell even when the ideal spot is inside furniture.
static func _nearest_walkable(p: Vector2) -> Vector2i:
	var c := world_to_cell(p)
	if is_walkable(c):
		return c
	for r in range(1, maxi(_cols, _rows)):
		var best := Vector2i(-1, -1)
		var best_d := INF
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				# ring only
				if absi(dx) != r and absi(dy) != r:
					continue
				var t := Vector2i(c.x + dx, c.y + dy)
				if not is_walkable(t):
					continue
				var d := cell_centre(t).distance_squared_to(p)
				if d < best_d:
					best_d = d
					best = t
		if best.x >= 0:
			return best
	return c


# ── public queries ─────────────────────────────────────────────────────────

static func cols() -> int:
	_ensure()
	return _cols


static func rows() -> int:
	_ensure()
	return _rows


static func world_to_cell(p: Vector2) -> Vector2i:
	return Vector2i(int(floor(p.x / CELL)), int(floor(p.y / CELL)))


static func cell_centre(c: Vector2i) -> Vector2:
	return Vector2((c.x + 0.5) * CELL, (c.y + 0.5) * CELL)


static func is_walkable(c: Vector2i) -> bool:
	_ensure()
	if c.x < 0 or c.y < 0 or c.x >= _cols or c.y >= _rows:
		return false
	return _walkable[c.y * _cols + c.x] != 0


## Where she stands to use `id`, and which way she turns on arrival.
static func anchor(id: String) -> Dictionary:
	_ensure()
	return _anchors.get(id, {})


static func anchor_pos(id: String) -> Vector2:
	var a := anchor(id)
	return a["pos"] if a.has("pos") else Vector2.ZERO


static func facing_for(id: String) -> String:
	var a := anchor(id)
	return a["facing"] if a.has("facing") else "down"


# ── A* ─────────────────────────────────────────────────────────────────────

## 4-connected, so every path is strictly N/S/E/W — the walk keeps exactly the
## character the hand-authored corridors gave it. The search state carries the
## incoming direction so a turn can be charged for; that is what stops it
## returning a staircase.
##
## Deterministic: the open set is a binary heap keyed by (f, insertion order),
## so equal-cost paths always resolve the same way.
static func find_path(from: Vector2, to_cell: Vector2i) -> Array[Vector2]:
	_ensure()
	var start := _nearest_walkable(from)
	if start == to_cell or not is_walkable(to_cell):
		return [] as Array[Vector2]

	var n := _cols * _rows
	var g := PackedFloat32Array()
	g.resize(n * 5)
	g.fill(INF)
	var came := PackedInt32Array()
	came.resize(n * 5)
	came.fill(-1)

	var start_state := (start.y * _cols + start.x) * 5 + DIR_NONE
	g[start_state] = 0.0

	var heap: Array = []  # [f, seq, state]
	var seq := 0
	_heap_push(heap, [_h(start, to_cell), seq, start_state])
	seq += 1

	var goal_state := -1
	while not heap.is_empty():
		var top: Array = _heap_pop(heap)
		var state: int = top[2]
		var ci := state / 5
		var dir := state % 5
		var cur := Vector2i(ci % _cols, ci / _cols)
		if cur == to_cell:
			goal_state = state
			break
		var base: float = g[state]
		if top[0] > base + _h(cur, to_cell) + 0.0001:
			continue  # stale heap entry
		for nd in 4:
			var nxt: Vector2i = cur + STEPS[nd]
			if not is_walkable(nxt):
				continue
			var step_cost := 1.0
			if dir != DIR_NONE and nd != dir:
				step_cost += TURN_COST
			var ns := (nxt.y * _cols + nxt.x) * 5 + nd
			var tentative := base + step_cost
			if tentative < g[ns]:
				g[ns] = tentative
				came[ns] = state
				_heap_push(heap, [tentative + _h(nxt, to_cell), seq, ns])
				seq += 1

	if goal_state < 0:
		return [] as Array[Vector2]

	# Walk the parents back, then keep only the corners: a run of cells in one
	# direction becomes a single waypoint, which is what `logic.gd` moves along.
	var cells: Array[Vector2i] = []
	var s := goal_state
	while s >= 0:
		var ci := s / 5
		cells.push_front(Vector2i(ci % _cols, ci / _cols))
		s = came[s]

	var out: Array[Vector2] = []
	for i in range(1, cells.size()):
		var is_corner := i == cells.size() - 1
		if not is_corner:
			var a: Vector2i = cells[i] - cells[i - 1]
			var b: Vector2i = cells[i + 1] - cells[i]
			is_corner = a != b
		if is_corner:
			out.append(cell_centre(cells[i]))
	return out


## Manhattan distance in cells — admissible for 4-connected uniform steps, and
## still admissible with turn costs, since turns only ever add.
static func _h(a: Vector2i, b: Vector2i) -> float:
	return float(absi(a.x - b.x) + absi(a.y - b.y))


static func _heap_push(heap: Array, item: Array) -> void:
	heap.append(item)
	var i := heap.size() - 1
	while i > 0:
		var parent := (i - 1) / 2
		if _heap_less(heap[i], heap[parent]):
			var t = heap[i]
			heap[i] = heap[parent]
			heap[parent] = t
			i = parent
		else:
			break


static func _heap_pop(heap: Array) -> Array:
	var top: Array = heap[0]
	var last: Array = heap.pop_back()
	if not heap.is_empty():
		heap[0] = last
		var i := 0
		while true:
			var l := i * 2 + 1
			var r := l + 1
			var small := i
			if l < heap.size() and _heap_less(heap[l], heap[small]):
				small = l
			if r < heap.size() and _heap_less(heap[r], heap[small]):
				small = r
			if small == i:
				break
			var t = heap[i]
			heap[i] = heap[small]
			heap[small] = t
			i = small
	return top


static func _heap_less(a: Array, b: Array) -> bool:
	if a[0] != b[0]:
		return a[0] < b[0]
	return a[1] < b[1]  # insertion order — keeps ties deterministic


## Debug/authoring: how many cells are walkable, and are all of them one island?
static func stats() -> Dictionary:
	_ensure()
	var total := 0
	var first := Vector2i(-1, -1)
	for i in _walkable.size():
		if _walkable[i] != 0:
			total += 1
			if first.x < 0:
				first = Vector2i(i % _cols, i / _cols)
	# flood the first island
	var seen := {}
	var q: Array[Vector2i] = [first]
	seen[first.y * _cols + first.x] = true
	var head := 0
	while head < q.size():
		var p: Vector2i = q[head]
		head += 1
		for d in STEPS:
			var t: Vector2i = p + d
			if not is_walkable(t):
				continue
			var k := t.y * _cols + t.x
			if seen.has(k):
				continue
			seen[k] = true
			q.append(t)
	return {"cols": _cols, "rows": _rows, "walkable": total, "largest_island": seen.size()}
