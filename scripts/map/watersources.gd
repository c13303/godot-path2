extends TileMapLayer
class_name WaterSources

const SPLASH_SCENE: PackedScene = preload("res://scenes/particles/splash.tscn")
const FLOOR_SPLASH_Z_INDEX: int = -99
const INVALID_WATER_CELL: Vector2i = Vector2i(2147483647, 2147483647)
const SPLASH_MOVEMENT_EPSILON: float = 0.5

@export var refill_amount: int = 10
@export var refill_interval_seconds: float = 0.1
@export_range(0.01, 1.0, 0.01) var player_slowdown: float = 0.5
## Zero commits drownable agents as soon as their foot sample enters water. Navigation
## remains coverage-blocked separately, while the drowning phase's directional field
## carries the captured agent visibly inward instead of leaving it on the shoreline.
@export_range(0.0, 1.0, 0.01) var drowning_coverage_threshold: float = 0.0
@export_range(0.0, 1.0, 0.01) var navigation_blocking_coverage_threshold: float = 0.8
@export var foot_sample_offset: Vector2 = Vector2.ZERO
@export_group("Waterpools")
@export var waterpool_drift_enabled: bool = true
@export_range(0.0, 128.0, 1.0, "or_greater") var waterpool_drift_speed: float = 64.0
@export var waterpool_drift_sample_offset: Vector2 = Vector2.ZERO
@export_range(0.0, 128.0, 1.0, "or_greater") var waterpool_drift_sample_radius: float = 24.0
@export var waterpool_directional_field_id: int = 1
@export var waterpool_bound_phase: int = 7
@export_group("Visual FX")
@export var pre_instantiated_splashes: int = 32
@export_group("")

var _splash_pool: Array[Node2D] = []
var _splash_cursor: int = 0


func _ready() -> void:
	_preload_splash_pool()


func has_water_at_foot_position(world_position: Vector2) -> bool:
	return water_cell_at_foot_position(world_position) != INVALID_WATER_CELL

func water_cell_at_foot_position(world_position: Vector2) -> Vector2i:
	var sample_position: Vector2 = world_position + foot_sample_offset
	var cell: Vector2i = local_to_map(to_local(sample_position))
	if get_cell_source_id(cell) == -1:
		return INVALID_WATER_CELL
	return cell

func water_coverage_of_world_rect(world_rect: Rect2) -> float:
	var rect_area: float = world_rect.get_area()
	if rect_area <= 0.0:
		return 0.0

	var local_rect: Rect2 = _world_rect_to_local_aabb(world_rect)
	var local_area: float = local_rect.get_area()
	if local_area <= 0.0:
		return 0.0

	var tile_size: Vector2 = _tile_size()
	var first_cell: Vector2i = local_to_map(local_rect.position)
	var last_cell: Vector2i = local_to_map(local_rect.position + local_rect.size)
	var min_x: int = mini(first_cell.x, last_cell.x) - 1
	var max_x: int = maxi(first_cell.x, last_cell.x) + 1
	var min_y: int = mini(first_cell.y, last_cell.y) - 1
	var max_y: int = maxi(first_cell.y, last_cell.y) + 1
	var water_area: float = 0.0

	for y: int in range(min_y, max_y + 1):
		for x: int in range(min_x, max_x + 1):
			var cell: Vector2i = Vector2i(x, y)
			if get_cell_source_id(cell) == -1:
				continue
			var cell_center: Vector2 = map_to_local(cell)
			var cell_rect: Rect2 = Rect2(cell_center - tile_size * 0.5, tile_size)
			var overlap: Rect2 = local_rect.intersection(cell_rect)
			if overlap.get_area() > 0.0:
				water_area += overlap.get_area()

	return clampf(water_area / local_area, 0.0, 1.0)

func _world_rect_to_local_aabb(world_rect: Rect2) -> Rect2:
	var p0: Vector2 = to_local(world_rect.position)
	var p1: Vector2 = to_local(world_rect.position + Vector2(world_rect.size.x, 0.0))
	var p2: Vector2 = to_local(world_rect.position + Vector2(0.0, world_rect.size.y))
	var p3: Vector2 = to_local(world_rect.position + world_rect.size)
	var min_x: float = minf(minf(p0.x, p1.x), minf(p2.x, p3.x))
	var min_y: float = minf(minf(p0.y, p1.y), minf(p2.y, p3.y))
	var max_x: float = maxf(maxf(p0.x, p1.x), maxf(p2.x, p3.x))
	var max_y: float = maxf(maxf(p0.y, p1.y), maxf(p2.y, p3.y))
	return Rect2(Vector2(min_x, min_y), Vector2(max_x - min_x, max_y - min_y))

func _tile_size() -> Vector2:
	var current_tile_set: TileSet = tile_set
	if current_tile_set == null:
		return Vector2(32.0, 32.0)
	var size: Vector2i = current_tile_set.tile_size
	return Vector2(maxf(1.0, float(size.x)), maxf(1.0, float(size.y)))

func rebuild_waterpool_directional_field(steering: Node) -> bool:
	if steering == null:
		print("Waterpools: no steering node; upload skipped")
		return false
	if not steering.has_method("set_directional_cell_field"):
		print("Waterpools: steering lacks set_directional_cell_field; upload skipped")
		return false
	if not steering.has_method("bind_phase_directional_cell_field"):
		print("Waterpools: steering lacks bind_phase_directional_cell_field; upload skipped")
		return false
	if not waterpool_drift_enabled or waterpool_drift_speed <= 0.0:
		_clear_waterpool_directional_field(steering)
		CppDebugOptions.dlog("Waterpools: disabled; field cleared")
		return true

	var used_water_cells: Array[Vector2i] = get_used_cells()
	if used_water_cells.is_empty():
		_clear_waterpool_directional_field(steering)
		CppDebugOptions.dlog("Waterpools: no water cells; field cleared")
		return true

	var waterpool_field: Dictionary = Waterpools.build_directional_field(used_water_cells)
	var field_cells: PackedVector2Array = waterpool_field.get("cells", PackedVector2Array()) as PackedVector2Array
	var field_directions: PackedVector2Array = waterpool_field.get("directions", PackedVector2Array()) as PackedVector2Array
	var pool_count: int = int(waterpool_field.get("pool_count", 0))
	var deep_count: int = int(waterpool_field.get("deep_cells", 0))

	if field_cells.size() == 0:
		_clear_waterpool_directional_field(steering)
		CppDebugOptions.dlog("Waterpools: pools=%d water_cells=%d deep_cells=%d field_cells=0; field cleared" % [
			pool_count,
			used_water_cells.size(),
			deep_count,
		])
		return true

	var size: Vector2 = _tile_size()
	var origin_world: Vector2 = to_global(map_to_local(Vector2i.ZERO) - size * 0.5)
	steering.call(
		"set_directional_cell_field",
		waterpool_directional_field_id,
		origin_world,
		maxf(1.0, size.x),
		waterpool_drift_speed,
		field_cells,
		field_directions,
		waterpool_drift_sample_offset,
		waterpool_drift_sample_radius
	)
	steering.call("bind_phase_directional_cell_field", waterpool_bound_phase, waterpool_directional_field_id)
	CppDebugOptions.dlog("Waterpools: pools=%d water_cells=%d deep_cells=%d field_cells=%d speed=%.1f sample_radius=%.1f field_id=%d phase=%d" % [
		pool_count,
		used_water_cells.size(),
		deep_count,
		field_cells.size(),
		waterpool_drift_speed,
		waterpool_drift_sample_radius,
		waterpool_directional_field_id,
		waterpool_bound_phase,
	])
	return true

func clear_waterpool_directional_field(steering: Node) -> void:
	_clear_waterpool_directional_field(steering)

func _clear_waterpool_directional_field(steering: Node) -> void:
	if steering == null:
		return
	if steering.has_method("clear_directional_cell_field"):
		steering.call("clear_directional_cell_field", waterpool_directional_field_id)
	if steering.has_method("clear_phase_directional_cell_field"):
		steering.call("clear_phase_directional_cell_field", waterpool_bound_phase)

# --- Splash visual FX pool ------------------------------------------------
# Pre-instantiated, reused splash scenes (no per-event instantiate/free spam).
# Plays for any agent over the water; mirrors the player's splashController.

func _preload_splash_pool() -> void:
	var count: int = maxi(pre_instantiated_splashes, 0)
	for index: int in range(count):
		var splash: Node2D = SPLASH_SCENE.instantiate() as Node2D
		if splash == null:
			continue
		splash.name = "MonsterSplash%02d" % index
		splash.visible = false
		splash.z_as_relative = false
		splash.z_index = FLOOR_SPLASH_Z_INDEX
		add_child(splash)
		_splash_pool.append(splash)

func play_splash_at(world_position: Vector2) -> void:
	if _splash_pool.is_empty():
		return
	var splash: Node2D = _next_available_splash()
	if splash == null:
		return
	splash.global_position = world_position
	splash.visible = true
	for particle: CPUParticles2D in _particles_for(splash):
		particle.emitting = false
		particle.restart()
		particle.emitting = true

func _next_available_splash() -> Node2D:
	var pool_count: int = _splash_pool.size()
	for offset: int in range(pool_count):
		var index: int = (_splash_cursor + offset) % pool_count
		var splash: Node2D = _splash_pool[index]
		if not _is_splash_busy(splash):
			_splash_cursor = (index + 1) % pool_count
			return splash
	var fallback_index: int = _splash_cursor
	_splash_cursor = (_splash_cursor + 1) % pool_count
	return _splash_pool[fallback_index]

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
