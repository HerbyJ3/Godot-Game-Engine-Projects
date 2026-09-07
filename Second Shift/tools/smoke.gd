## Headless playthrough: boot main.tscn, play the game by following the glow,
## and check that the loop actually closes.
##
## tools/trace.gd proves the RULES match the original JavaScript. This proves
## the other half — that the scene boots, that every `_draw` path runs without
## erroring, and that a real session scores, serves and ends. Headless mode
## never calls `_draw`, so this needs a virtual display:
##
##   xvfb-run -a godot --path . --rendering-driver opengl3 \
##     --script res://tools/smoke.gd -- /tmp/shots
##
## The bot is deliberately dumb: whenever Ruth is free it clicks whatever
## object the current chain wants next — exactly the "follow the glow" the
## title card teaches. If the chain tables, the router, the timers or the
## commit step were wrong, it would stall and the run would fail its checks.
extends SceneTree

## World time is scaled up so a full 150-second round runs in about a minute.
## The rules only ever see the frame delta, well under the 500 ms clamp.
const TIME_SCALE := 4.0
const MAX_FRAMES := 3600
const SHOT_EVERY := 600

var _out_dir := "/tmp/shots"
var _scene: Node
var _session: Node
var _shots := 0
var _clicks := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out_dir = args[0]
	_run.call_deferred()


## The object the live chains want next, or "" if there is nothing to do.
## Mirrors the glow ring in world.gd, which is the point — the bot sees exactly
## what the player is shown.
func _next_target(v: Dictionary) -> String:
	var tasks: Dictionary = v.get("tasks", {})
	var defs: Dictionary = v.get("taskDefs", {})
	# A live kid demand is resolved face-to-face, so walk to their spot first.
	var kids = tasks.get("kids", null)
	if kids != null and kids.get("kidSpot", null) != null:
		return kids["kidSpot"]
	for key in defs:
		if key == "kids" or key == "self":
			continue
		var ts = tasks.get(key, null)
		if ts == null or bool(ts.get("waiting", false)):
			continue
		var steps: Array = defs[key]["steps"]
		var idx: int = ts["stepIdx"]
		if idx < 0 or idx >= steps.size() or steps[idx] == null:
			continue
		var target = steps[idx]["target"]
		if target != null:
			return target
	return ""


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(_out_dir)
	Engine.time_scale = TIME_SCALE

	_session = root.get_node_or_null("Session")
	if _session == null:
		printerr("SMOKE FAIL: Session autoload missing")
		quit(1)
		return

	_scene = load("res://main.tscn").instantiate()
	root.add_child(_scene)
	await process_frame

	# Dismiss the title card the way a player does.
	_scene.started = true
	_session.begin()

	var peak_queue := 0
	var last_click_frame := -999

	for frame in MAX_FRAMES:
		var v: Dictionary = _scene.view
		peak_queue = maxi(peak_queue, (v.get("queue", []) as Array).size())

		if v.get("outcome", null) != null:
			print("SMOKE round closed at frame %d" % frame)
			break

		var p: Dictionary = v["player"]
		var free: bool = p["order"]["mode"] == "idle" and p.get("working", null) == null and p.get("pendingResolve", null) == null

		# The kid popup is modal — answer it before anything else.
		if _scene.hud.kid_talk_rect.size.x > 0.0:
			_scene._on_click(_scene.hud.kid_talk_rect.get_center())
			_clicks += 1
		elif _scene.hud.phone_rect.size.x > 0.0 and frame % 30 == 0:
			_scene._on_click(_scene.hud.phone_rect.get_center())
			_clicks += 1
		elif free and frame - last_click_frame > 4:
			var target := _next_target(v)
			if target == "" and float(v["selfNeed"]) < 90.0:
				target = "couch"  # nothing pending — take the minute
			if target != "" and v["objects"].has(target):
				var o: Dictionary = v["objects"][target]
				_scene._on_click(Vector2(float(o["x"]), float(o["y"])))
				_clicks += 1
				last_click_frame = frame

		if frame % SHOT_EVERY == 0:
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png("%s/frame-%04d.png" % [_out_dir, frame])
			_shots += 1
			print("SMOKE frame %4d  t=%5.1f  score=%3d  served=%d  missed=%d  self=%3.0f  queue=%d" % [
				frame, float(v["t"]), int(v["score"]), int(v["servedCount"]),
				int(v["missed"]), float(v["selfNeed"]), (v.get("queue", []) as Array).size(),
			])
		await process_frame

	# Let the end card's staggered star pop finish before the last shot,
	# otherwise it is caught mid-animation and looks like a bug.
	for _i in 45:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("%s/frame-final.png" % _out_dir)
	_shots += 1

	var final: Dictionary = _scene.view
	print("SMOKE done: clicks=%d shots=%d t=%.1f score=%d served=%d missed=%d peakQueue=%d outcome=%s" % [
		_clicks, _shots, float(final["t"]), int(final["score"]), int(final["servedCount"]),
		int(final["missed"]), peak_queue, str(final.get("outcome", null)),
	])

	# The checks. Each one fails for a different reason, so the message says
	# which part of the loop broke rather than just "smoke failed".
	var problems := PackedStringArray()
	if float(final["t"]) < 100.0:
		problems.append("world clock barely advanced (t=%.1f) — Session is not ticking" % float(final["t"]))
	if int(final["servedCount"]) == 0:
		problems.append("nothing was ever served — chains never reached their last step")
	if int(final["score"]) == 0:
		problems.append("score never moved — commit_work is not awarding")
	if peak_queue == 0:
		problems.append("no demand ever spawned — the spawn timers are not firing")
	if final.get("outcome", null) == null:
		problems.append("round never closed — the %ds timer did not fire" % int(final["roundSeconds"]))

	if problems.is_empty():
		print("SMOKE PASS")
		quit(0)
	else:
		for p in problems:
			printerr("SMOKE FAIL: %s" % p)
		quit(1)
