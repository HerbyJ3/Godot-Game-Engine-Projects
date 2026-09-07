## A minimal assertion base, so the suite needs no addon.
##
## The original project was deliberately dependency-free — `bun install` was
## instant and no game could fail to build on a transitive dependency. Keeping
## that here means not vendoring GUT for what amounts to six assertion helpers.
## A test is any method named `test_*`; a failed check records a message and
## keeps going, so one broken chain does not hide the next.
class_name TestCase
extends RefCounted

var failures: PackedStringArray = []
var checks := 0

var _current := ""


func begin(test_name: String) -> void:
	_current = test_name


func _fail(msg: String) -> void:
	failures.append("%s: %s" % [_current, msg])


func check(cond: bool, msg: String) -> void:
	checks += 1
	if not cond:
		_fail(msg)


func eq(actual, expected, msg: String) -> void:
	checks += 1
	if actual != expected:
		_fail("%s — expected %s, got %s" % [msg, str(expected), str(actual)])


func close_to(actual: float, expected: float, tol: float, msg: String) -> void:
	checks += 1
	if absf(actual - expected) > tol:
		_fail("%s — expected ~%f, got %f" % [msg, expected, actual])


func gt(actual: float, bound: float, msg: String) -> void:
	checks += 1
	if not (actual > bound):
		_fail("%s — expected > %f, got %f" % [msg, bound, actual])


func ge(actual: float, bound: float, msg: String) -> void:
	checks += 1
	if not (actual >= bound):
		_fail("%s — expected >= %f, got %f" % [msg, bound, actual])


func lt(actual: float, bound: float, msg: String) -> void:
	checks += 1
	if not (actual < bound):
		_fail("%s — expected < %f, got %f" % [msg, bound, actual])


func le(actual: float, bound: float, msg: String) -> void:
	checks += 1
	if not (actual <= bound):
		_fail("%s — expected <= %f, got %f" % [msg, bound, actual])


func is_null(value, msg: String) -> void:
	checks += 1
	if value != null:
		_fail("%s — expected null, got %s" % [msg, str(value)])


func not_null(value, msg: String) -> void:
	checks += 1
	if value == null:
		_fail("%s — expected a value, got null" % msg)
