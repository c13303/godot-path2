extends Node

const SPLASH_SCENE: PackedScene = preload("res://scenes/particles/splash.tscn")
const FLOOR_SPLASH_Z_INDEX: int = -99
const PLAYER_PATH: NodePath = ^"../../Player"
const WATERSOURCES_PATH: NodePath = ^"../../Map/MonTilemap/watersources"

@export var splash_pool_size: int = 12
@export var splash_freq: float = 0.1

var _player: Node2D
var _watersources: WaterSources
var _pool: Array[Node2D] = []
var _pool_cursor: int = 0
var _repeat_time_left: float = 0.0
var _was_in_water: bool = false


func _ready() -> void:
	_player = get_node_or_null(PLAYER_PATH) as Node2D
	_watersources = get_node_or_null(WATERSOURCES_PATH) as WaterSources
	_preload_pool()


func _process(delta: float) -> void:
	if _player == null or _watersources == null:
		return

	var in_water: bool = _watersources.has_water_at_foot_position(_player.global_position)
	if not in_water:
		_was_in_water = false
		_repeat_time_left = 0.0
		return

	_repeat_time_left = maxf(_repeat_time_left - delta, 0.0)
	if not _was_in_water or _repeat_time_left <= 0.0:
		_play_splash(_player.global_position)
		_repeat_time_left = maxf(splash_freq, 0.0)

	_was_in_water = true


func _preload_pool() -> void:
	var count: int = maxi(splash_pool_size, 0)
	for index: int in range(count):
		var splash: Node2D = SPLASH_SCENE.instantiate() as Node2D
		if splash == null:
			continue
		splash.name = "Splash%02d" % index
		splash.visible = false
		splash.z_as_relative = false
		splash.z_index = FLOOR_SPLASH_Z_INDEX
		add_child(splash)
		_pool.append(splash)


func _play_splash(world_position: Vector2) -> void:
	if _pool.is_empty():
		return

	var splash: Node2D = _next_available_splash()
	splash.global_position = world_position
	splash.visible = true
	for particle: CPUParticles2D in _particles_for(splash):
		particle.emitting = false
		particle.restart()
		particle.emitting = true


func _next_available_splash() -> Node2D:
	var pool_count: int = _pool.size()
	for offset: int in range(pool_count):
		var index: int = (_pool_cursor + offset) % pool_count
		var splash: Node2D = _pool[index]
		if not _is_splash_busy(splash):
			_pool_cursor = (index + 1) % pool_count
			return splash

	var fallback_index: int = _pool_cursor
	_pool_cursor = (_pool_cursor + 1) % pool_count
	return _pool[fallback_index]


func _is_splash_busy(splash: Node2D) -> bool:
	for particle: CPUParticles2D in _particles_for(splash):
		if particle.emitting:
			return true
	splash.visible = false
	return false


func _particles_for(root: Node) -> Array[CPUParticles2D]:
	var particles: Array[CPUParticles2D] = []
	_collect_particles(root, particles)
	return particles


func _collect_particles(root: Node, particles: Array[CPUParticles2D]) -> void:
	for child: Node in root.get_children():
		if child is CPUParticles2D:
			particles.append(child as CPUParticles2D)
		_collect_particles(child, particles)
