extends Node
class_name ProjectileRuntime

## Project-owned combat interpretation around generic CPathLib projectile motion.

const INVALID_HANDLE: int = 0

@export var projectile_world_path: NodePath = NodePath("../ProjectileWorld")
@export var crowd_world_path: NodePath = NodePath("../CrowdWorld")
@export var crowd_runtime_path: NodePath = NodePath("../CrowdRuntime")

var _world: Node
var _crowd: Node
var _crowd_runtime: CrowdRuntime
var _gameplay_config_by_type: Dictionary = {}
var _impacts: Array = []


func _ready() -> void:
	_world = get_node_or_null(projectile_world_path)
	_crowd = get_node_or_null(crowd_world_path)
	_crowd_runtime = get_node_or_null(crowd_runtime_path) as CrowdRuntime
	if _world != null:
		_world.call(&"set_crowd_world", _crowd)
	set_process(true)


func _process(_delta: float) -> void:
	if _world == null:
		return
	var events: Array = _world.call(&"take_impacts") as Array
	for raw_event: Variant in events:
		var event: Dictionary = raw_event as Dictionary
		var type_handle: int = int(event.get("type_handle", INVALID_HANDLE))
		var config: Dictionary = _gameplay_config_by_type.get(type_handle, {}) as Dictionary
		var kind: int = int(event.get("kind", -1))
		var effect_config: Dictionary = _effect_config_for_impact(config, kind)
		if _crowd_runtime != null and not effect_config.is_empty():
			_crowd_runtime.apply_projectile_effect(event, effect_config)
		_impacts.append({
			"type_id": type_handle,
			"kind": kind,
			"pos": event.get("position", Vector2.ZERO),
			"dir": event.get("direction", Vector2.RIGHT),
			"radius": float(effect_config.get("aoe_radius", 0.0)),
			"collider_cell": event.get("collider_cell", Vector2i.ZERO),
			"collider_mask": int(event.get("collider_mask", 0)),
			"hit_agent_handle": int(event.get("hit_agent_handle", INVALID_HANDLE)),
		})


func _effect_config_for_impact(config: Dictionary, kind: int) -> Dictionary:
	if kind == 2:
		return config
	if not bool(config.get("end_of_life_aoe_enabled", false)):
		return {}
	return {
		"aoe_radius": float(config.get("end_aoe_radius", 0.0)),
		"smash_force": float(config.get("end_aoe_force", 0.0)),
		"smash_friction_loss": float(config.get("end_aoe_friction_loss", 0.0)),
		"smash_falloff": float(config.get("end_aoe_falloff", 0.0)),
		"smash_detach_flow": bool(config.get("end_aoe_detach_flow", false)),
		"smash_control_suppression": float(config.get("end_aoe_control_suppression", 0.0)),
		"smash_control_suppression_duration": float(config.get("end_aoe_control_suppression_duration", 0.0)),
		"damage": int(config.get("damage", 0)),
		"target_category_mask": int(config.get("target_category_mask", -1)),
	}


func register_type(configuration: Dictionary) -> int:
	if _world == null:
		return INVALID_HANDLE
	var generic_config: Dictionary = {
		"speed": float(configuration.get("speed", 0.0)),
		"lifetime": float(configuration.get("lifetime", 0.0)),
		"radius": float(configuration.get("radius", 0.0)),
		"static_collision_mask": int(configuration.get("static_collision_mask", 0)),
		"target_category_mask": int(configuration.get("target_category_mask", -1)),
		"pool_size": int(configuration.get("pool_size", 1)),
	}
	var type_handle: int = int(_world.call(&"create_projectile_type", generic_config))
	if type_handle != INVALID_HANDLE:
		_gameplay_config_by_type[type_handle] = configuration.duplicate(true)
	return type_handle


func fire(type_handle: int, position: Vector2, direction: Vector2, owner_agent_handle: int = 0, _category_mask: int = -1) -> bool:
	return fire_with_velocity(type_handle, position, direction, Vector2.ZERO, owner_agent_handle, _category_mask)


func fire_with_velocity(type_handle: int, position: Vector2, direction: Vector2, inherited_velocity: Vector2, owner_agent_handle: int = 0, _category_mask: int = -1) -> bool:
	if _world == null:
		return false
	return int(_world.call(&"spawn_projectile", type_handle, position, direction, inherited_velocity, owner_agent_handle, type_handle)) != 0


func get_active_positions(type_handle: int) -> PackedVector2Array:
	return _world.call(&"get_active_positions", type_handle) as PackedVector2Array if _world != null else PackedVector2Array()


func get_active_projectile_states(type_handle: int) -> Array:
	return _world.call(&"get_active_projectile_states", type_handle) as Array if _world != null else []


func get_active_count(type_handle: int) -> int:
	return int(_world.call(&"get_active_count", type_handle)) if _world != null else 0


func get_type_count() -> int:
	return int(_world.call(&"get_type_count")) if _world != null else 0


func get_impacts() -> Array:
	var result: Array = _impacts
	_impacts = []
	return result


func set_static_collision_cells(cells: PackedVector2Array, masks: Variant, cell_size: float) -> void:
	if _world == null:
		return
	if cells.is_empty():
		_world.call(&"clear_static_collision_grid")
		return
	var min_cell: Vector2i = Vector2i(int(cells[0].x), int(cells[0].y))
	var max_cell: Vector2i = min_cell
	var converted_masks: PackedInt64Array = PackedInt64Array()
	for index: int in range(cells.size()):
		var cell: Vector2i = Vector2i(int(cells[index].x), int(cells[index].y))
		min_cell.x = mini(min_cell.x, cell.x)
		min_cell.y = mini(min_cell.y, cell.y)
		max_cell.x = maxi(max_cell.x, cell.x)
		max_cell.y = maxi(max_cell.y, cell.y)
		converted_masks.append(int(masks[index]))
	var bounds: Rect2i = Rect2i(min_cell, max_cell - min_cell + Vector2i.ONE)
	var world_origin: Vector2 = Vector2(min_cell) * cell_size
	_world.call(&"set_static_collision_grid", bounds, cell_size, world_origin, cells, converted_masks)


func set_static_collision_layers(configurations: Array, floor_layer: TileMapLayer) -> void:
	if floor_layer == null:
		return
	var cells: PackedVector2Array = PackedVector2Array()
	var masks: PackedInt64Array = PackedInt64Array()
	var mask_by_cell: Dictionary = {}
	for raw_config: Variant in configurations:
		var config: Dictionary = raw_config as Dictionary
		var layer: TileMapLayer = config.get("layer") as TileMapLayer
		if layer == null:
			continue
		var atlas_filter: Array = config.get("atlas_coords", []) as Array
		var channel: int = int(config.get("channel", 0))
		for cell: Vector2i in layer.get_used_cells():
			if not atlas_filter.is_empty() and not atlas_filter.has(layer.get_cell_atlas_coords(cell)):
				continue
			var world_position: Vector2 = layer.to_global(layer.map_to_local(cell))
			var grid_cell: Vector2i = Vector2i(floori(world_position.x / float(floor_layer.tile_set.tile_size.x)), floori(world_position.y / float(floor_layer.tile_set.tile_size.x)))
			mask_by_cell[grid_cell] = int(mask_by_cell.get(grid_cell, 0)) | channel
	for raw_cell: Variant in mask_by_cell:
		var cell: Vector2i = raw_cell as Vector2i
		cells.append(Vector2(cell))
		masks.append(int(mask_by_cell[cell]))
	set_static_collision_cells(cells, masks, float(floor_layer.tile_set.tile_size.x))


func clear_static_collisions() -> void:
	if _world != null:
		_world.call(&"clear_static_collision_grid")


func clear_walls() -> void:
	clear_static_collisions()


func set_paused(paused: bool) -> void:
	if _world != null:
		_world.call(&"set_paused", paused)
