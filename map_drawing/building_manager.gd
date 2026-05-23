extends Node
class_name BuildingManager

const AGENT_SCENE := preload("res://sprites/character/character.tscn")
const BUILD_TILES_INDEX_PATH := "res://map_drawing/build_tiles_index.tres"
const DEFAULT_SPAWN_COOLDOWN: float = 2.0
const INVALID_CELL := Vector2i(2147483647, 2147483647)

@export var floorz: TileMapLayer
@export var wallz: TileMapLayer
@export var buildings: TileMapLayer
@export var flow: Node
@export var agent_manager: Node
@export var parent_for_agents: Node

var _tile_defs_by_atlas: Dictionary = {}
var _houses: Dictionary = {}
var _spawners: Dictionary = {}
var _spawn_timers: Dictionary = {}
var _scan_timer: float = 0.0
var _last_wall_signature: int = 0

func _ready() -> void:
	_load_tile_definitions()
	_migrate_special_tiles_from_wallz()
	_scan_buildings()

func _process(delta: float) -> void:
	_scan_timer -= delta
	if _scan_timer <= 0.0:
		_scan_timer = 0.25
		_scan_buildings()

	_process_spawners(delta)

func _load_tile_definitions() -> void:
	_tile_defs_by_atlas.clear()
	var res := load(BUILD_TILES_INDEX_PATH)
	if not (res is JSON):
		return

	for key in res.data.keys():
		var definition: Variant = res.data[key]
		if not (definition is Dictionary):
			continue
		var tile_definition: Dictionary = definition as Dictionary
		var atlas: Array = tile_definition.get("atlas", [])
		if atlas.size() != 2:
			continue
		var atlas_key := _atlas_key(Vector2i(int(atlas[0]), int(atlas[1])))
		_tile_defs_by_atlas[atlas_key] = {
			"key": str(key),
			"kind": str(tile_definition.get("kind", "")),
			"cooldown": float(tile_definition.get("cooldown", DEFAULT_SPAWN_COOLDOWN))
		}

func _scan_buildings() -> void:
	if not buildings:
		return

	_migrate_special_tiles_from_wallz()

	var wall_signature := _tile_layer_signature(wallz)
	var walls_changed := wall_signature != _last_wall_signature
	_last_wall_signature = wall_signature

	var seen_houses: Dictionary = {}
	var seen_spawners: Dictionary = {}
	_scan_special_layer(buildings, seen_houses, seen_spawners)
	_scan_special_layer(wallz, seen_houses, seen_spawners)

	for raw_house_cell in _houses.keys():
		var cell: Vector2i = raw_house_cell
		if not seen_houses.has(cell):
			_houses.erase(cell)

	for raw_spawner_cell in _spawners.keys():
		var cell: Vector2i = raw_spawner_cell
		if not seen_spawners.has(cell):
			_spawners.erase(cell)
			_spawn_timers.erase(cell)

	if walls_changed:
		_rebuild_house_flows()

func _scan_special_layer(layer: TileMapLayer, seen_houses: Dictionary, seen_spawners: Dictionary) -> void:
	if not layer:
		return

	for raw_cell in layer.get_used_cells():
		var map_cell: Vector2i = raw_cell
		var definition := _definition_for_layer_cell(layer, map_cell)
		var kind := str(definition.get("kind", ""))
		if kind == "house":
			seen_houses[map_cell] = true
			_register_house(map_cell)
		elif kind == "spawner":
			seen_spawners[map_cell] = true
			_register_spawner(map_cell, float(definition.get("cooldown", DEFAULT_SPAWN_COOLDOWN)))

func _migrate_special_tiles_from_wallz() -> void:
	if not wallz or not buildings:
		return

	var migrated := false
	for raw_cell in wallz.get_used_cells():
		var cell: Vector2i = raw_cell
		var definition := _definition_for_layer_cell(wallz, cell)
		var kind := str(definition.get("kind", ""))
		if kind == "" or kind == "wall":
			continue

		buildings.set_cell(
			cell,
			wallz.get_cell_source_id(cell),
			wallz.get_cell_atlas_coords(cell),
			wallz.get_cell_alternative_tile(cell)
		)
		wallz.erase_cell(cell)
		migrated = true

	if migrated:
		buildings.update_internals()
		wallz.update_internals()

func _definition_for_cell(cell: Vector2i) -> Dictionary:
	return _definition_for_layer_cell(buildings, cell)

func _definition_for_layer_cell(layer: TileMapLayer, cell: Vector2i) -> Dictionary:
	if not layer:
		return {}
	var atlas := layer.get_cell_atlas_coords(cell)
	var atlas_key := _atlas_key(atlas)
	return _tile_defs_by_atlas.get(atlas_key, {}) as Dictionary

func _register_house(cell: Vector2i) -> void:
	if _houses.has(cell):
		return
	if not agent_manager or not agent_manager.has_method("create_group"):
		return
	if not flow or not flow.has_method("assign_flow_to_group"):
		return

	var group_id := int(agent_manager.call("create_group"))
	if group_id < 0:
		return

	_houses[cell] = {
		"group_id": group_id,
		"world": _cell_center(cell)
	}
	_assign_house_flow(cell)

func _rebuild_house_flows() -> void:
	for raw_house_cell in _houses.keys():
		var cell: Vector2i = raw_house_cell
		_assign_house_flow(cell)

func _assign_house_flow(cell: Vector2i) -> void:
	if not _houses.has(cell):
		return
	if not flow or not flow.has_method("assign_flow_to_group"):
		return
	var house: Dictionary = _houses[cell] as Dictionary
	var group_id := int(house.get("group_id", -1))
	if group_id < 0:
		return
	flow.call("assign_flow_to_group", group_id, house.get("world", _cell_center(cell)))

func _register_spawner(cell: Vector2i, cooldown: float) -> void:
	_spawners[cell] = {
		"cooldown": max(0.05, cooldown)
	}
	if not _spawn_timers.has(cell):
		_spawn_timers[cell] = 0.0

func _process_spawners(delta: float) -> void:
	if _houses.is_empty():
		return

	for raw_cell in _spawners.keys():
		var cell: Vector2i = raw_cell
		var timer := float(_spawn_timers.get(cell, 0.0)) - delta
		if timer > 0.0:
			_spawn_timers[cell] = timer
			continue

		if _spawn_monster_from(cell):
			var spawner: Dictionary = _spawners[cell] as Dictionary
			_spawn_timers[cell] = float(spawner.get("cooldown", DEFAULT_SPAWN_COOLDOWN))
		else:
			_spawn_timers[cell] = 0.25

func _spawn_monster_from(spawner_cell: Vector2i) -> bool:
	var house_cell := _nearest_house_cell(spawner_cell)
	if house_cell == INVALID_CELL:
		return false

	var house: Dictionary = _houses[house_cell] as Dictionary
	var group_id := int(house.get("group_id", -1))
	if group_id < 0:
		return false

	var occupied := _occupied_cells()
	var spawn_cell := _find_free_cell_near(spawner_cell, occupied)
	if spawn_cell == INVALID_CELL:
		return false

	var agent: Node2D = AGENT_SCENE.instantiate()
	var parent: Node = parent_for_agents if parent_for_agents else get_tree().current_scene
	parent.add_child(agent)
	agent.global_position = _cell_center(spawn_cell)
	agent.z_index = int(agent.global_position.y)
	agent.add_to_group("monsters")

	if agent_manager and agent_manager.has_method("spawn_agent"):
		var nav_id := int(agent_manager.call("spawn_agent", agent, group_id))
		agent.set("nav_id", nav_id)
		if agent_manager.has_method("assign_agent"):
			agent_manager.call("assign_agent", agent, group_id)

	return true

func _nearest_house_cell(from_cell: Vector2i) -> Vector2i:
	var best_cell := INVALID_CELL
	var best_dist_sq := 2147483647
	for raw_house_cell in _houses.keys():
		var house_cell: Vector2i = raw_house_cell
		var d: Vector2i = house_cell - from_cell
		var dist_sq := d.x * d.x + d.y * d.y
		if dist_sq < best_dist_sq:
			best_dist_sq = dist_sq
			best_cell = house_cell
	return best_cell

func _occupied_cells() -> Array[Vector2i]:
	var occupied: Array[Vector2i] = []
	for group_name in ["main_chars", "monsters", "player"]:
		for node in get_tree().get_nodes_in_group(group_name):
			if node is Node2D:
				var unit: Node2D = node
				occupied.append(floorz.local_to_map(floorz.to_local(unit.global_position)))
	return occupied

func _find_free_cell_near(start_cell: Vector2i, occupied: Array[Vector2i], max_radius: int = 8) -> Vector2i:
	if start_cell not in occupied and _is_walkable(start_cell):
		return start_cell
	for r in range(1, max_radius + 1):
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				var cell := start_cell + Vector2i(dx, dy)
				if cell not in occupied and _is_walkable(cell):
					return cell
	return INVALID_CELL

func _is_walkable(cell: Vector2i) -> bool:
	if not floorz:
		return false
	var has_floor := floorz.get_cell_tile_data(cell) != null
	var has_wall := wallz and wallz.get_cell_tile_data(cell) != null
	return has_floor and not has_wall

func _cell_center(cell: Vector2i) -> Vector2:
	return floorz.to_global(floorz.map_to_local(cell))

func _atlas_key(atlas: Vector2i) -> String:
	return "%d,%d" % [atlas.x, atlas.y]

func _tile_layer_signature(layer: TileMapLayer) -> int:
	if not layer:
		return 0
	var signature := 17
	for raw_cell in layer.get_used_cells():
		var cell: Vector2i = raw_cell
		var atlas := layer.get_cell_atlas_coords(cell)
		signature += int(cell.x * 73856093 + cell.y * 19349663)
		signature += int(atlas.x * 83492791 + atlas.y * 2654435761)
	return signature
