## The HUD: clock, score meter, demand bubbles, phone chip, kid choice, the
## self-care bar, the juice layer, and the three overlays.
##
## Transcribed from `drawHUD` and its helpers in public/client.js rather than
## rebuilt as Control nodes, so the look is identical on day one. Every
## coordinate below is in the same 960x640 space the world uses, which is why
## the floaters can be positioned on Ruth and the bubbles on the screen without
## converting anything.
##
## It also PUBLISHES its hit rects (`start_rect`, `replay_rect`, `phone_rect`,
## `kid_talk_rect`, `kid_redirect_rect`) for the input router to test against —
## the same contract the canvas version had, where drawing and hit-testing
## agreed by construction because the drawing code wrote the rects down.
extends Control

const U := preload("res://scripts/draw_util.gd")
const Icons := preload("res://scripts/task_icons.gd")

const W := 960.0
const H := 640.0

@onready var game: Node = owner

# Published for input_router.gd. An empty Rect2 means "not on screen".
var start_rect := Rect2()
var replay_rect := Rect2()
var phone_rect := Rect2()
var kid_talk_rect := Rect2()
var kid_redirect_rect := Rect2()

# Bubble bookkeeping: which demands we have already seen (so a new one pops and
# chimes exactly once) and when each arrived.
var _seen_queue_ids := {}
var _born_at := {}
var _warned_beat := {}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	var v: Dictionary = game.view
	if v.is_empty():
		return
	var now := float(Time.get_ticks_msec())
	var frac: float = minf(1.0, float(v["t"]) / float(v["roundSeconds"]))

	# top-left cluster: clock face + score meter
	_draw_clock(frac)
	_draw_star_meter(v)

	_draw_demand_bubbles(v, now)

	phone_rect = Rect2()
	if v["phone"]["state"] == "ringing":
		_draw_phone_call(v, now)

	kid_talk_rect = Rect2()
	kid_redirect_rect = Rect2()
	var anim = v["player"].get("anim", null)
	if v["tasks"].has("kids") and anim != null and anim.get("kind", "") == "kneel":
		_draw_kid_choice(v, now)

	_draw_self_bar(v)
	_draw_juice(now)

	start_rect = Rect2()
	replay_rect = Rect2()
	if game.paused:
		_draw_pause_overlay()
	if not game.started:
		_draw_menu_overlay()
	if v.get("outcome", null) != null:
		_draw_end_overlay(v, now)


# ── clock: 07:55 → 08:10 over the round ────────────────────────────────────

func _draw_clock(frac: float) -> void:
	var cx := 46.0
	var cy := 46.0
	var r := 26.0
	var ink: Color = U.C["ink"]

	U.fill_circle(self, cx, cy, r + 8, U.C["paper"])
	U.stroke_circle(self, cx, cy, r + 8, ink, 3)
	U.fill_circle(self, cx, cy, r, U.C["paperSolid"])
	U.stroke_circle(self, cx, cy, r, U.hex_a(ink, 0.3), 2)

	for i in 12:
		var a := (float(i) / 12.0) * TAU
		U.line(
			self,
			Vector2(cx + cos(a) * (r - 5), cy + sin(a) * (r - 5)),
			Vector2(cx + cos(a) * (r - 1), cy + sin(a) * (r - 1)),
			ink, 2
		)

	var total_min := 55.0 + frac * 15.0
	var m_angle := deg_to_rad(-90.0 + total_min * 6.0)
	var h_angle := deg_to_rad(-90.0 + (7.0 + total_min / 60.0) * 30.0)
	U.line(self, Vector2(cx, cy), Vector2(cx + cos(m_angle) * (r - 8), cy + sin(m_angle) * (r - 8)), ink, 3.5)
	U.line(self, Vector2(cx, cy), Vector2(cx + cos(h_angle) * (r - 14), cy + sin(h_angle) * (r - 14)), ink, 4.5)
	U.fill_circle(self, cx, cy, 3, ink)

	# the ring that drains as the round runs
	var ring: Color = U.C["bad"] if frac > 0.85 else U.C["sage"]
	U.stroke_arc(self, cx, cy, r + 8, -PI / 2.0, -PI / 2.0 + TAU * (1.0 - frac), ring, 4)


# ── score meter ────────────────────────────────────────────────────────────

func _draw_star_meter(v: Dictionary) -> void:
	var score := float(v["score"])
	var target := float(v["target"])
	var frac := minf(1.0, score / target) if target > 0.0 else 0.0
	var x := 92.0
	var y := 22.0
	var w := 200.0
	var h := 18.0
	var ink: Color = U.C["ink"]

	U.fill_rr(self, x - 10, y - 10, w + 20, h + 20, 14, U.C["paper"])
	U.stroke_rr(self, x - 10, y - 10, w + 20, h + 20, 14, ink, 3)

	U.fill_rr(self, x, y, w, h, 9, U.hex_a(ink, 0.08))
	if frac > 0.0:
		U.fill_rr_gradient(self, x, y, w * frac, h, 9, U.C["sunny"], U.C["terracotta"])

	# three star thresholds
	for m in [0.34, 0.67, 1.0]:
		var sx := x + w * float(m)
		var reached: bool = frac >= float(m)
		U.star(
			self, sx, y + h / 2.0, 9.0 if reached else 7.0,
			U.C["sunny"] if reached else U.hex_a(ink, 0.25), ink
		)

	# which half of the marriage this is
	if v.has("level") and v["level"] != null:
		U.text(self, String(v["level"]["name"]).to_upper(), x + 4, y + h + 26, 10, 800, U.hex_a(ink, 0.55), "left", 1.5)


# ── thought bubbles: one per live demand ───────────────────────────────────

func _draw_demand_bubbles(v: Dictionary, now: float) -> void:
	var queue: Array = v.get("queue", [])
	var task_defs: Dictionary = v.get("taskDefs", {})
	var tasks: Dictionary = v.get("tasks", {})
	var ink: Color = U.C["ink"]
	var live := queue.slice(0, 6)  # the HUD shows up to 6

	for i in live.size():
		var q: Dictionary = live[i]
		var qid: String = q["id"]
		var x := 340.0 + i * 110.0
		var y := 30.0
		var key: String = q["key"]
		var def = task_defs.get(key, null)
		var ts = tasks.get(key, null)

		# pop on arrival
		if not _seen_queue_ids.has(qid):
			_seen_queue_ids[qid] = true
			_born_at[qid] = now
			Sfx.play("served", 0.1)
		var born_ago: float = now - float(_born_at.get(qid, now - 9999.0))
		var pop := 1.0 + sin((born_ago / 350.0) * PI) * 0.12 if born_ago < 350.0 else 1.0

		# patience, always shown as a ring and never as a number
		var patience := float(def["patience"]) if def != null else 30.0
		var remaining: float = maxf(0.0, float(q["expiresT"]) - float(v["t"]))
		var frac := minf(1.0, remaining / patience)
		var col: Color = U.C["ok"] if frac > 0.5 else (U.C["warn"] if frac > 0.25 else U.C["bad"])

		# shake, and a chirp on the beat, once it is nearly gone
		var shake_x := 0.0
		if frac < 0.25 and frac > 0.0:
			shake_x = sin(now / 50.0) * 2.5
			var beat := int(now / 600.0)
			if _warned_beat.get(qid, -1) != beat:
				_warned_beat[qid] = beat
				Sfx.play("alert", 0.15)

		draw_set_transform(Vector2(x + shake_x, y), 0.0, Vector2(pop, pop))

		U.fill_circle(self, 0, 0, 26, U.C["paperSolid"])
		U.stroke_circle(self, 0, 0, 26, ink, 3)
		U.stroke_circle(self, 0, 0, 26, U.hex_a(ink, 0.12), 5)
		if frac > 0.0:
			U.stroke_arc(self, 0, 0, 26, -PI / 2.0, -PI / 2.0 + TAU * frac, col, 5)

		Icons.draw_icon(self, Icons.FOR_TASK.get(key, "laundry"), 0, 0, 16, ink)

		# step progress dots
		if ts != null and def != null:
			var done: int = ts["stepIdx"]
			var total := 0
			for s in def["steps"]:
				if s != null:
					total += 1
			for s_i in total:
				var dx := (float(s_i) - float(total - 1) / 2.0) * 7.0
				var filled := s_i < done
				U.fill_circle(self, dx, 32, 3.0 if filled else 2.0, U.hex_a(ink, 1.0 if filled else 0.3))

		# a small label under it — fallback text, never the primary read
		U.text(self, String(def["label"]) if def != null else key, 0, 46, 10, 600, U.C["inkSoft"], "center")

		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

		# waiting-for-machine badge
		if ts != null and bool(ts.get("waiting", false)) and ts.get("timerEnd", null) != null:
			var left: float = maxf(0.0, float(ts["timerEnd"]) - float(v["t"]))
			U.fill_circle(self, x + 24, y - 22, 11, U.C["paper"])
			U.stroke_circle(self, x + 24, y - 22, 11, ink, 2)
			U.text(self, "%d" % int(ceil(left)), x + 24, y - 21, 10, 700, ink, "center")


# ── phone, kids, and her own bar ───────────────────────────────────────────

func _draw_phone_call(v: Dictionary, now: float) -> void:
	var x := W - 180.0
	var y := 16.0
	var w := 164.0
	var h := 56.0
	var shake := sin(now / 80.0) * 2.0

	draw_set_transform(Vector2(x + shake, y), 0.0, Vector2.ONE)
	U.fill_rr(self, 0, 0, w, h, 14, U.C["paperSolid"])
	U.stroke_rr(self, 0, 0, w, h, 14, U.C["bad"], 3)
	Icons.draw_icon(self, "phone", 22, h / 2.0, 14, U.C["bad"])
	var caller = v["phone"].get("caller", null)
	U.text(self, String(caller) if caller != null else "the phone", 42, h / 2.0 - 8, 12, 700, U.C["ink"])
	U.text(self, "tap to answer", 42, h / 2.0 + 9, 10, 600, U.C["inkSoft"])
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	phone_rect = Rect2(x, y, w, h)


## The one decision the game asks out loud: talk it out, or redirect. Talking
## scores more and holds; redirecting is cheaper now and costs later.
func _draw_kid_choice(v: Dictionary, now: float) -> void:
	var p: Dictionary = v["player"]
	var x := float(p["x"])
	var y := float(p["y"]) - 64.0
	var bob := sin(now / 240.0) * 1.5
	var ink: Color = U.C["ink"]

	draw_set_transform(Vector2(x, y + bob), 0.0, Vector2.ONE)
	U.fill_rr(self, -110, -26, 220, 52, 14, U.C["paperSolid"])
	U.stroke_rr(self, -110, -26, 220, 52, 14, ink, 3)

	U.fill_rr(self, -102, -18, 100, 36, 10, U.C["sage"])
	U.stroke_rr(self, -102, -18, 100, 36, 10, ink, 2.5)
	U.text(self, "Talk it out", -52, 0, 13, 700, U.C["paperSolid"], "center")

	U.fill_rr(self, 2, -18, 100, 36, 10, U.C["sunny"])
	U.stroke_rr(self, 2, -18, 100, 36, 10, ink, 2.5)
	U.text(self, "Redirect", 52, 0, 13, 700, ink, "center")
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	kid_talk_rect = Rect2(x - 102, y - 18 + bob, 100, 36)
	kid_redirect_rect = Rect2(x + 2, y - 18 + bob, 100, 36)


## The bar the whole design is about: it drains on its own, the task that
## refills it is worth the fewest points in the game, and the end card asks
## whether she ever got to it.
func _draw_self_bar(v: Dictionary) -> void:
	var x := 16.0
	var y := H - 36.0
	var w := 180.0
	var h := 14.0
	var frac := float(v["selfNeed"]) / 100.0
	var low := frac < 0.3
	var ink: Color = U.C["ink"]

	U.fill_rr(self, x - 8, y - 24, w + 16, h + 34, 12, U.C["paper"])
	U.stroke_rr(self, x - 8, y - 24, w + 16, h + 34, 12, ink, 3)

	U.text(self, "HER OWN NEEDS", x, y - 13, 10, 700, U.C["bad"] if low else U.C["inkSoft"])

	U.fill_rr(self, x, y, w, h, 7, U.hex_a(ink, 0.08))
	if frac > 0.0:
		U.fill_rr(self, x, y, w * frac, h, 7, U.C["bad"] if low else U.C["rose"])

	U.text(self, "Hers, while she holds it.", x, y + h + 12, 10, 500, U.C["inkSoft"])


# ── juice: floaters, bounce rings, particles ───────────────────────────────

func _draw_juice(now: float) -> void:
	for f in game.float_texts:
		var age: float = now - float(f["at"])
		var p := age / 1100.0
		var col: Color = f["color"]
		U.text(self, f["txt"], f["x"], float(f["y"]) - p * 44.0, 15, 800, U.hex_a(col, 1.0 - p * p), "center")

	for b in game.bounces:
		var p: float = (now - float(b["at"])) / 380.0
		U.stroke_circle(self, b["x"], b["y"], 6.0 + p * 18.0, U.hex_a(U.C["bad"], 0.9 * (1.0 - p)), 3)

	for pt in game.particles:
		var p: float = (now - float(pt["at"])) / 600.0
		var col: Color = pt["color"]
		U.fill_circle(
			self,
			float(pt["x"]) + float(pt["vx"]) * p * 60.0,
			float(pt["y"]) + float(pt["vy"]) * p * 60.0,
			3.5 * (1.0 - p * 0.5),
			U.hex_a(col, 1.0 - p)
		)


# ── overlays ───────────────────────────────────────────────────────────────

func _draw_menu_overlay() -> void:
	var ink: Color = U.C["ink"]
	draw_rect(Rect2(0, 0, W, H), Color(0.290196, 0.207843, 0.149020, 0.5))

	U.fill_rr(self, W / 2.0 - 260, 138, 520, 372, 22, U.C["paperSolid"])
	U.stroke_rr(self, W / 2.0 - 260, 138, 520, 372, 22, ink, 4)

	U.text(self, "SECOND SHIFT", W / 2.0, 182, 34, 800, ink, "center", 1)
	U.text(self, "Her Morning", W / 2.0, 214, 18, 700, U.C["terracotta"], "center")
	U.text(self, "A marriage, in clicks — the housewife's turn first.", W / 2.0, 242, 13, 600, U.C["inkSoft"], "center")

	U.text(self, "Dinner won't make itself. The laundry won't fold itself.", W / 2.0, 290, 14, 600, ink, "center")
	U.text(self, "The baby won't change itself. Click a room, follow the glow.", W / 2.0, 314, 14, 600, ink, "center")
	U.text(self, "Wrong clicks never punish. The couch is always hers.", W / 2.0, 338, 14, 600, ink, "center")

	var bx := W / 2.0 - 110.0
	var by := 396.0
	var bw := 220.0
	var bh := 56.0
	U.fill_rr(self, bx, by, bw, bh, 16, U.C["terracotta"])
	U.stroke_rr(self, bx, by, bw, bh, 16, ink, 4)
	U.text(self, "START HER MORNING", W / 2.0, by + bh / 2.0, 16, 800, U.C["paperSolid"], "center")
	start_rect = Rect2(bx, by, bw, bh)

	U.text(self, "ESC pauses. Everything else is a click.", W / 2.0, 480, 11, 500, U.C["inkSoft"], "center")
	U.text(self, "His Evening comes next.", W / 2.0, 496, 11, 600, U.C["inkSoft"], "center")


func _draw_pause_overlay() -> void:
	var ink: Color = U.C["ink"]
	draw_rect(Rect2(0, 0, W, H), Color(0.290196, 0.207843, 0.149020, 0.45))
	U.fill_rr(self, W / 2.0 - 170, H / 2.0 - 60, 340, 120, 20, U.C["paperSolid"])
	U.stroke_rr(self, W / 2.0 - 170, H / 2.0 - 60, 340, 120, 20, ink, 4)
	U.text(self, "PAUSED", W / 2.0, H / 2.0 - 18, 24, 800, ink, "center")
	U.text(self, "ESC to keep going", W / 2.0, H / 2.0 + 16, 13, 600, U.C["inkSoft"], "center")


func _draw_end_overlay(v: Dictionary, now: float) -> void:
	var ink: Color = U.C["ink"]
	draw_rect(Rect2(0, 0, W, H), Color(0.290196, 0.207843, 0.149020, 0.55))

	U.fill_rr(self, W / 2.0 - 250, 130, 500, 380, 22, U.C["paperSolid"])
	U.stroke_rr(self, W / 2.0 - 250, 130, 500, 380, 22, ink, 4)

	var won: bool = v["outcome"] == "won"
	U.text(
		self, "THE MORNING HELD" if won else "THE MORNING WON",
		W / 2.0, 178, 28, 800, U.C["sage"] if won else U.C["bad"], "center"
	)
	U.text(self, "Score %d / %d" % [int(v["score"]), int(v["target"])], W / 2.0, 216, 16, 700, ink, "center")

	var frac := minf(1.0, float(v["score"]) / float(v["target"]))
	var star_count := 3 if frac >= 1.0 else (2 if frac >= 0.67 else (1 if frac >= 0.34 else 0))
	var shown_at: float = game.end_shown_at if game.end_shown_at > 0.0 else now
	for i in 3:
		var sx := W / 2.0 + (i - 1) * 46.0
		var earned := i < star_count
		var pop := minf(1.0, (now - shown_at) / 200.0 - i * 0.2)
		if pop <= 0.0:
			continue
		var s := minf(1.0, pop * 1.3)
		draw_set_transform(Vector2(sx, 260), 0.0, Vector2(s, s))
		U.star(self, 0, 0, 18.0 if earned else 16.0, U.C["sunny"] if earned else U.hex_a(ink, 0.15), ink)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	# The recap the whole design is pointed at.
	var self_line := "she never got her minute" if float(v["selfNeed"]) < 30.0 else "she kept a piece of herself"
	var miss_line := "nothing slipped" if int(v["missed"]) == 0 else ("%d slipped" % int(v["missed"]))
	U.text(self, self_line, W / 2.0, 320, 14, 600, ink, "center")
	U.text(self, miss_line, W / 2.0, 344, 14, 600, U.C["inkSoft"], "center")

	var bx := W / 2.0 - 100.0
	var by := 420.0
	var bw := 200.0
	var bh := 52.0
	U.fill_rr(self, bx, by, bw, bh, 16, U.C["terracotta"])
	U.stroke_rr(self, bx, by, bw, bh, 16, ink, 4)
	U.text(self, "PLAY AGAIN", W / 2.0, by + bh / 2.0, 15, 800, U.C["paperSolid"], "center")
	replay_rect = Rect2(bx, by, bw, bh)

	U.text(self, "The house remembers who did the work.", W / 2.0, 494, 11, 500, U.C["inkSoft"], "center")


## Called when the round restarts, so a replayed demand pops and chimes again.
func reset_bubbles() -> void:
	_seen_queue_ids.clear()
	_born_at.clear()
	_warned_beat.clear()
