## The tier that replaced the server.
##
## In the browser build a Cloudflare Durable Object (`src/room.ts`) owned the
## game state: it validated each client frame, applied it through `logic.js`,
## persisted the result, and fanned a per-player `view` back over a WebSocket.
## The game is single-player, so all of that collapses to this autoload. What
## is deliberately KEPT from the room:
##
##   * validate-then-apply, in that order. An illegal action is refused, not
##     crashed on, even though the only caller is now our own input router.
##   * the `view_for` boundary. Renderers read `view()` and never touch
##     `_state`, which is what lets them stay dumb.
##   * the `dtMs` clamp inside `apply_action`. It used to protect the sim from
##     a stalled socket; it now protects it from a stalled frame.
##
## What is dropped: sockets, hibernation, storage, seats, spectators, the
## reconnect/ping dance, and the 150 ms heartbeat (we tick every frame).
extends Node

const Logic := preload("res://scripts/logic.gd")

const PLAYER_ID := "ruth"

## Emitted after every applied action, with the fresh view.
signal view_changed(view: Dictionary)
## Emitted once, the moment the round closes.
signal round_over(result: Dictionary)

var _state: Dictionary = {}
var _running := false
var _announced_over := false

## Transient, view-only events the renderer has not consumed yet
## ("spawn", "ding", "fail", "phoneRing"). Drained by the HUD each frame.
var _last_event_count := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	reset()


## Start a fresh round. The seed is derived from the player id inside
## `Logic.setup`, so the same id always plays the same morning — that is what
## makes a run reproducible, and it is why the tracer can diff against JS.
func reset() -> void:
	_state = Logic.setup([PLAYER_ID])
	_running = false
	_announced_over = false
	_last_event_count = 0
	view_changed.emit(view())


## The round does not advance until the player has dismissed the title card.
func begin() -> void:
	_running = true


func is_running() -> bool:
	return _running


func _process(delta: float) -> void:
	if not _running or get_tree().paused:
		return
	if _state.get("outcome", null) != null:
		return
	# The heartbeat. `pause` carries no intent — it only moves world time.
	_advance({"type": "pause", "dtMs": delta * 1000.0})


## Submit a player intent. Time still advances by the frame delta, exactly as
## the browser client folded `dtMs` into every action it sent.
func submit(action: Dictionary) -> bool:
	if not _running:
		return false
	var a := action.duplicate()
	if not a.has("dtMs"):
		a["dtMs"] = get_process_delta_time() * 1000.0
	return _advance(a)


func _advance(action: Dictionary) -> bool:
	var verdict := Logic.validate_action(_state, PLAYER_ID, action)
	if not verdict["ok"]:
		return false
	_state = Logic.apply_action(_state, PLAYER_ID, action)
	view_changed.emit(view())
	if not _announced_over:
		var over := Logic.is_game_over(_state)
		if over["over"]:
			_announced_over = true
			_running = false
			round_over.emit(over)
	return true


func view() -> Dictionary:
	return Logic.view_for(_state, PLAYER_ID)


## Events the renderer has not seen yet, oldest first. Consuming them here
## rather than in each drawer keeps "did this ding already play?" in one place.
func drain_events() -> Array:
	var events: Array = _state.get("events", [])
	var fresh := events.slice(mini(_last_event_count, events.size()))
	_last_event_count = events.size()
	return fresh
