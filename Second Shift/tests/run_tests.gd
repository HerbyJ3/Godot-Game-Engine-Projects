## The test runner.
##
##   godot --headless --path . --script res://tests/run_tests.gd
##
## Finds every `*_test.gd` under res://tests, runs each `test_*` method, and
## exits non-zero on the first suite with failures. No addon, no config.
extends SceneTree


func _init() -> void:
	var dir := DirAccess.open("res://tests")
	if dir == null:
		printerr("cannot open res://tests")
		quit(1)
		return

	var files: PackedStringArray = []
	for f in dir.get_files():
		# .gd may arrive as .gd.remap in an exported build.
		var name := f.trim_suffix(".remap")
		if name.ends_with("_test.gd"):
			files.append(name)
	files.sort()

	var total := 0
	var failed := 0
	var checks := 0

	for file in files:
		var suite_name := file.trim_suffix(".gd")
		var script: GDScript = load("res://tests/%s" % file)
		# A suite that fails to parse must be reported, not fatal: left
		# unguarded it takes down the runner before quit(), and the whole run
		# hangs until its timeout with no idea which file was at fault.
		if script == null:
			printerr("FAIL  %s did not load (parse error above)" % suite_name)
			failed += 1
			continue
		var suite: TestCase = script.new()

		for m in suite.get_method_list():
			var mname: String = m["name"]
			if not mname.begins_with("test_"):
				continue
			total += 1
			suite.begin("%s.%s" % [suite_name, mname])
			var started := Time.get_ticks_msec()
			suite.call(mname)
			var took := Time.get_ticks_msec() - started
			# Printed per test, not just per suite: a hang or a pathological
			# loop is otherwise invisible behind a buffered pipe.
			print("  %-58s %5d ms" % [mname, took])

		checks += suite.checks
		if suite.failures.size() > 0:
			failed += suite.failures.size()
			for f in suite.failures:
				printerr("FAIL  %s" % f)
		else:
			print("ok    %s (%d checks)" % [suite_name, suite.checks])

	print("\n%d tests, %d checks, %d failures" % [total, checks, failed])
	quit(1 if failed > 0 else 0)
