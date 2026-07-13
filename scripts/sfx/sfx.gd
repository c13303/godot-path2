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
const THEME: AudioStream = preload("res://assets/music/college quest.mp3")

## If false, music is never played.
@export var music_enable: bool = false:
	set(value):
		music_enable = value
		if _music_player == null:
			return
		if music_enable:
			if not _music_player.playing:
				_music_player.play()
		else:
			_music_player.stop()
## Music volume. 1.0 = full volume; matches the previous default of 0.3.
@export_range(0.0, 1.0) var music_volume: float = MUSIC_VOLUME:
	set(value):
		music_volume = clampf(value, 0.0, 1.0)
		_apply_music_volume()
## General sfx multiplier applied on top of each sound's own volume.
## 1.0 = current game default volume.
@export_range(0.0, 1.0) var sfx_general_volume: float = 1.0:
	set(value):
		sfx_general_volume = clampf(value, 0.0, 1.0)
		_apply_sfx_volume()

var _players: Dictionary = {}
var _next_player: Dictionary = {}
var _music_player: AudioStreamPlayer


func _ready() -> void:
	_build_player_pools()
	_build_music_player()


## Starts the persistent theme player if it is not already playing.
## The Sfx autoload owns music playback so scene changes do not restart it.
func start_music() -> void:
	music_enable = true


## Stops the persistent theme player and prevents it from looping.
func stop_music() -> void:
	music_enable = false


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


func stop_sound(sound_id: StringName) -> bool:
	var pool: Array = _players.get(sound_id, []) as Array
	if pool.is_empty():
		return false
	for player_variant: Variant in pool:
		var player: AudioStreamPlayer = player_variant as AudioStreamPlayer
		if player != null:
			player.stop()
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
			player.set_meta(&"base_volume", volume)
			player.volume_db = _linear_to_volume_db(volume * sfx_general_volume)
			add_child(player)
			pool.append(player)
		_players[sound_id] = pool
		_next_player[sound_id] = 0


func _build_music_player() -> void:
	_music_player = AudioStreamPlayer.new()
	_music_player.name = "Theme1"
	_music_player.stream = THEME
	_music_player.volume_db = _linear_to_volume_db(music_volume)
	_music_player.finished.connect(_on_music_finished)
	add_child(_music_player)
	if music_enable:
		_music_player.play()


func _on_music_finished() -> void:
	if music_enable:
		_music_player.play()


func _apply_music_volume() -> void:
	if _music_player != null:
		_music_player.volume_db = _linear_to_volume_db(music_volume)


func _apply_sfx_volume() -> void:
	for pool_variant: Variant in _players.values():
		for player_variant: Variant in pool_variant as Array:
			var player: AudioStreamPlayer = player_variant as AudioStreamPlayer
			if player == null:
				continue
			var base_volume: float = float(player.get_meta(&"base_volume", DEFAULT_VOLUME))
			player.volume_db = _linear_to_volume_db(base_volume * sfx_general_volume)


func _linear_to_volume_db(volume: float) -> float:
	return linear_to_db(volume) if volume > 0.0 else -80.0
