## Replays tools/trace_actions.json through the GDScript rules and prints one
## line per step, in exactly the format tools/trace_js.mjs prints.
##
## Run:  godot --headless --path . --script res://tools/trace.gd > /tmp/gd.txt
##       bun tools/trace_js.mjs > /tmp/js.txt
##       diff /tmp/js.txt /tmp/gd.txt
##
## An empty diff is the port's correctness proof. A diff that starts partway
## through points at whatever ran for the first time on that step.
extends SceneTree

const Logic := preload("res://scripts/logic.gd")


func _fmt(v) -> String:
	if v == null:
		return "-"
	return "%.9f" % float(v)


func _s(v) -> String:
	if v == null:
		return "-"
	return str(v)


func _init() -> void:
	var file := FileAccess.open("res://tools/trace_actions.json", FileAccess.READ)
	if file == null:
		printerr("cannot open trace_actions.json")
		quit(1)
		return
	var actions: Array = JSON.parse_string(file.get_as_text())

	var state := Logic.setup(["ruth"])
	var out := PackedStringArray()

	for i in actions.size():
		var a: Dictionary = actions[i]
		var v := Logic.validate_action(state, "ruth", a)
		if v["ok"]:
			state = Logic.apply_action(state, "ruth", a)

		var p: Dictionary = state["player"]
		var working = p["working"]
		var w := "-" if working == null else "%s:%d:%s" % [working["key"], int(working["stepIdx"]), _fmt(working["endsAt"])]

		var pend_keys: Array = (state["pending"] as Dictionary).keys()
		pend_keys.sort()
		var pend := PackedStringArray()
		for k in pend_keys:
			pend.append("%s=%s" % [k, _fmt(state["pending"][k])])

		var task_keys: Array = (state["tasks"] as Dictionary).keys()
		task_keys.sort()
		var tasks := PackedStringArray()
		for k in task_keys:
			var t = state["tasks"][k]
			if t == null:
				tasks.append("%s=null" % k)
			else:
				tasks.append("%s=%d:%s:%d:%s" % [
					k, int(t["stepIdx"]), _fmt(t["timerEnd"]),
					1 if bool(t["burned"]) else 0, _s(t.get("carry", null)),
				])

		var q := PackedStringArray()
		for item in state["queue"]:
			q.append(item["id"])

		var phone: Dictionary = state["phone"]
		var ph := "%s:%s:%s:%s" % [phone["state"], _fmt(phone["nextAtT"]), _fmt(phone["untilT"]), _s(phone["caller"])]

		out.append("|".join(PackedStringArray([
			str(i), "1" if v["ok"] else "0", _fmt(state["t"]), str(state["rng"]),
			str(state["score"]), str(state["missed"]), str(state["servedCount"]),
			_fmt(state["selfNeed"]), _fmt(state["restoreT"]), _fmt(p["x"]), _fmt(p["y"]),
			str(p["order"]["mode"]), _s(p["carrying"]), "1" if bool(p["seated"]) else "0",
			_s(p["pendingResolve"]), _s(p.get("facing", null)), w,
			",".join(q), ",".join(pend), ",".join(tasks), ph,
			_s(state["lastChainKey"]), _fmt(state["lastChainTime"]), _s(state["outcome"]),
		])))

	print("\n".join(out))
	quit(0)
