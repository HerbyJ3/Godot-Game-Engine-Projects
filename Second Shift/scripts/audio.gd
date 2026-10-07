## The seven generated SFX plus the ambience loop.
##
## The browser client had to build an AudioContext lazily and unlock it on the
## first pointer event, because browsers refuse to play audio before a gesture.
## Godot has no such gate, so that whole dance is gone: the players exist from
## `_ready` and `play()` just works.
extends Node

const CLIPS := {
	"tick": "res://assets/audio/tick.mp3",
	"served": "res://assets/audio/served.mp3",
	"alert": "res://assets/audio/alert.mp3",
	"fail": "res://assets/audio/fail.mp3",
	"chain": "res://assets/audio/chain.mp3",
	"buffer": "res://assets/audio/buffer.mp3",
}

const AMBIENCE := "res://assets/audio/ambience.mp3"

var muted := false

var _players: Dictionary = {}
var _ambience: AudioStreamPlayer


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for name in CLIPS:
		var p := AudioStreamPlayer.new()
		p.stream = load(CLIPS[name])
		p.bus = "Master"
		add_child(p)
		_players[name] = p

	_ambience = AudioStreamPlayer.new()
	var stream: AudioStream = load(AMBIENCE)
	# mp3 loop points click unless the stream itself is told to loop.
	if stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = true
	_ambience.stream = stream
	_ambience.volume_db = linear_to_db(0.35)
	add_child(_ambience)


func play(sound: String, volume := 1.0) -> void:
	if muted or not _players.has(sound):
		return
	var p: AudioStreamPlayer = _players[sound]
	p.volume_db = linear_to_db(clampf(volume, 0.0001, 1.0))
	p.play()


func start_ambience() -> void:
	if not muted and _ambience and not _ambience.playing:
		_ambience.play()


func set_muted(value: bool) -> void:
	muted = value
	if muted and _ambience:
		_ambience.stop()
	elif not muted:
		start_ambience()
