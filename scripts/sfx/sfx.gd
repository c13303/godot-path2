extends Node

const DEFAULT_VOLUME: float = 0.3
const DEFAULT_OVERLAP: int = 2
const MUSIC_VOLUME: float = 0.3

const MONSTER_VOLUME : float = 0.6

# overlap is the maximum number of simultaneous voices. A value of 0 disables
# overlap and uses a single voice that restarts when the sound is requested.
const SOUNDS: Dictionary = {
	&"bubble1": {"stream": preload("res://assets/sfx/bubble1.wav"), "overlap": DEFAULT_OVERLAP, "volume": DEFAULT_VOLUME},
	&"splash": {"stream": preload("res://assets/sfx/splash.wav"), "overlap": DEFAULT_OVERLAP, "volume": DEFAULT_VOLUME},
	&"buy": {"stream": preload("res://assets/sfx/buy.wav"), "overlap": DEFAULT_OVERLAP, "volume": DEFAULT_VOLUME},
	&"pop1": {"stream": preload("res://assets/sfx/pop1.wav"), "overlap": DEFAULT_OVERLAP, "volume": DEFAULT_VOLUME},
	&"pop2": {"stream": preload("res://assets/sfx/pop2.wav"), "overlap": DEFAULT_OVERLAP, "volume": DEFAULT_VOLUME},
	&"pop3": {"stream": preload("res://assets/sfx/pop3.wav"), "overlap": DEFAULT_OVERLAP, "volume": DEFAULT_VOLUME},
	&"pop4": {"stream": preload("res://assets/sfx/pop4.wav"), "overlap": DEFAULT_OVERLAP, "volume": DEFAULT_VOLUME},
	&"bag": {"stream": preload("res://assets/sfx/bag.wav"), "overlap": DEFAULT_OVERLAP, "volume": DEFAULT_VOLUME},
	&"plant": {"stream": preload("res://assets/sfx/plant.wav"), "overlap": DEFAULT_OVERLAP, "volume": DEFAULT_VOLUME},
	&"crunsh": {"stream": preload("res://assets/sfx/crunsh.wav"), "overlap": DEFAULT_OVERLAP, "volume": DEFAULT_VOLUME},
	&"scream1": {"stream": preload("res://assets/sfx/scream1.wav"), "overlap": DEFAULT_OVERLAP, "volume": MONSTER_VOLUME},
	&"scream2": {"stream": preload("res://assets/sfx/scream2.wav"), "overlap": DEFAULT_OVERLAP, "volume": MONSTER_VOLUME},
	&"scream3": {"stream": preload("res://assets/sfx/scream3.wav"), "overlap": DEFAULT_OVERLAP, "volume": MONSTER_VOLUME},
	&"scream4": {"stream": preload("res://assets/sfx/scream4.wav"), "overlap": DEFAULT_OVERLAP, "volume": MONSTER_VOLUME},
	&"gem": {"stream": preload("res://assets/sfx/gem.wav"), "overlap": DEFAULT_OVERLAP, "volume": DEFAULT_VOLUME},
}

const POP_SOUNDS: Array[StringName] = [&"pop1", &"pop2", &"pop3", &"pop4"]
const SCREAM_SOUNDS: Array[StringName] = [&"scream1", &"scream2", &"scream3", &"scream4"]
const THEME: AudioStream = preload("res://assets/music/theme1.wav")

var _players: Dictionary = {}
var _next_player: Dictionary = {}
var _music_player: AudioStreamPlayer


func _ready() -> void:
	_build_player_pools()
	_start_music()


func play_sound(sound_id: StringName) -> bool:
	var sound_props: Dictionary = SOUNDS.get(sound_id, {}) as Dictionary
	if sound_props.is_empty():
		push_warning("Sfx: unknown sound '%s'" % String(sound_id))
		return false
	var pool: Array = _players.get(sound_id, []) as Array
	if pool.is_empty():
		return false
	var player_index: int = int(_next_player.get(sound_id, 0)) % pool.size()
	var player: AudioStreamPlayer = pool[player_index] as AudioStreamPlayer
	_next_player[sound_id] = (player_index + 1) % pool.size()
	player.play()
	return true


func play_random(sound_ids: Array[StringName]) -> bool:
	if sound_ids.is_empty():
		return false
	var random_index: int = randi_range(0, sound_ids.size() - 1)
	return play_sound(sound_ids[random_index])


func play_random_pop() -> bool:
	return play_random(POP_SOUNDS)


func play_random_scream() -> bool:
	return play_random(SCREAM_SOUNDS)


func _build_player_pools() -> void:
	for sound_key: Variant in SOUNDS.keys():
		var sound_id: StringName = sound_key as StringName
		var sound_props: Dictionary = SOUNDS[sound_id] as Dictionary
		var overlap: int = maxi(0, int(sound_props.get("overlap", DEFAULT_OVERLAP)))
		var player_count: int = maxi(1, overlap)
		var volume: float = clampf(float(sound_props.get("volume", DEFAULT_VOLUME)), 0.0, 1.0)
		var stream: AudioStream = sound_props.get("stream") as AudioStream
		var pool: Array[AudioStreamPlayer] = []
		for player_index: int in range(player_count):
			var player: AudioStreamPlayer = AudioStreamPlayer.new()
			player.name = "%s_%d" % [String(sound_id), player_index]
			player.stream = stream
			player.volume_db = linear_to_db(volume) if volume > 0.0 else -80.0
			add_child(player)
			pool.append(player)
		_players[sound_id] = pool
		_next_player[sound_id] = 0


func _start_music() -> void:
	_music_player = AudioStreamPlayer.new()
	_music_player.name = "Theme1"
	_music_player.stream = THEME
	_music_player.volume_db = linear_to_db(MUSIC_VOLUME) if MUSIC_VOLUME > 0.0 else -80.0
	_music_player.finished.connect(_on_music_finished)
	add_child(_music_player)
	_music_player.play()


func _on_music_finished() -> void:
	_music_player.play()
