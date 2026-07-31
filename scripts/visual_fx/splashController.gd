extends Node

const SPLASH_SCENE: PackedScene = preload("res://scenes/particles/splash.tscn")
const FLOOR_SPLASH_Z_INDEX: int = -99
const PLAYER_PATH: NodePath = ^"../../Player"
const WATERSOURCES_PATH: NodePath = ^"../../Map/MonTilemap/watersources"

@export var splash_pool_size: int = 50

var _player: Node2D
var _watersources: WaterSources
var _pool: Array[Node2D] = []
var _pool_cursor: int = 0
var _water_cell: Vector2i = WaterSources.INVALID_WATER_CELL
var _last_player_position: Vector2 = Vector2.ZERO
var _has_last_player_position: bool = false
var _was_player_moving: bool = false


func _ready() -> void:
	_player = get_node_or_null(PLAYER_PATH) as Node2D
	_watersources = get_node_or_null(WATERSOURCES_PATH) as WaterSources
	_preload_pool()


func _process(_delta: float) -> void:
	if _player == null or _watersources == null:
		return

	var water_cell: Vector2i = _watersources.water_cell_at_foot_position(_player.global_position)
	var current_position: Vector2 = _player.global_position
	var moved: bool = _has_last_player_position and current_position.distance_squared_to(_last_player_position) > WaterSources.SPLASH_MOVEMENT_EPSILON * WaterSources.SPLASH_MOVEMENT_EPSILON
	if water_cell == WaterSources.INVALID_WATER_CELL:
		_water_cell = WaterSources.INVALID_WATER_CELL
		_has_last_player_position = false
		_was_player_moving = false
		return

	if water_cell != _water_cell or (moved and not _was_player_moving):
		_play_splash(_player.global_position)
	_water_cell = water_cell
	_last_player_position = current_position
	_has_last_player_position = true
	_was_player_moving = moved


# Public one-shot: fire a pooled splash at an arbitrary world position (e.g. an
# enemy hit), independent of the player water-walking logic in _process.
func play_at(world_position: Vector2) -> void:
	_play_splash(world_position)


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
