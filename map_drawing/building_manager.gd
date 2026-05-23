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
@export var debug_logs: bool = false

var _tile_defs_by_atlas: Dictionary = {}
var _houses: Dictionary = {}
var _spawners: Dictionary = {}
var _spawn_timers: Dictionary = {}
var _scan_timer: float = 0.0
var _last_wall_signature: int = 0
var _flow_rebuild_pending: bool = false
var _last_scan_summary: String = ""
var _last_spawn_failure: String = ""
var _flow_ready: bool = false

func _ready() -> void:
	_load_tile_definitions()
	_migrate_special_tiles_from_wallz()
	_wait_for_flow_ready()

func _wait_for_flow_ready() -> void:
	var code_node: Node = null
	if flow:
		for child in flow.get_children():
			if child.has_signal("flow_field_ready"):
				code_node = child
				break
	if code_node == null:
		_flow_ready = true
		_scan_buildings()
		return
	if bool(code_node.get("is_ready")):
		_flow_ready = true
		_scan_buildings()
		return
	code_node.connect("flow_field_ready", Callable(self, "_on_flow_field_ready"))

func _on_flow_field_ready() -> void:
	_flow_ready = true
	_scan_buildings()

func _process(delta: float) -> void:
	if not _flow_ready:
		return
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

	var migrated := _migrate_special_tiles_from_wallz()

	var wall_signature := _tile_layer_signature(wallz)
	var walls_changed := wall_signature != _last_wall_signature or migrated
	_last_wall_signature = wall_signature

	var seen_houses: Dictionary = {}
	var seen_spawners: Dictionary = {}
	_scan_special_layer(buildings, seen_houses, seen_spawners)
	_scan_special_layer(wallz, seen_houses, seen_spawners)
	_log_scan_summary(seen_houses, seen_spawners, migrated, walls_changed)

	for raw_house_cell in _houses.keys():
		var cell: Vector2i = raw_house_cell
		if not seen_houses.has(cell):
			_houses.erase(cell)

	for raw_spawner_cell in _spawners.keys():
		var cell: Vector2i = raw_spawner_cell
		if not seen_spawners.has(cell):
			_spawners.erase(cell)
			_spawn_timers.erase(cell)

	if walls_changed or _has_pending_house_flows():
		_queue_house_flow_rebuild()

func _scan_special_layer(layer: TileMapLayer, seen_houses: Dictionary, seen_spawners: Dictionary) -> void:
	if not layer:
		return

	for raw_cell in layer.get_used_cells():
		var map_cell: Vector2i = raw_cell
		var definition := _definition_for_layer_cell(layer, map_cell)
		var kind := str(definition.get("kind", ""))
		if kind == "house":
			_log("detected house layer=%s cell=%s atlas=%s floor=%s wall=%s" % [
				layer.name,
				map_cell,
				layer.get_cell_atlas_coords(map_cell),
				_has_floor(map_cell),
				_has_wall(map_cell)
			])
			seen_houses[map_cell] = true
			_register_house(map_cell)
		elif kind == "spawner":
			_log("detected spawner layer=%s cell=%s atlas=%s floor=%s wall=%s" % [
				layer.name,
				map_cell,
				layer.get_cell_atlas_coords(map_cell),
				_has_floor(map_cell),
				_has_wall(map_cell)
			])
			seen_spawners[map_cell] = true
			_register_spawner(map_cell, float(definition.get("cooldown", DEFAULT_SPAWN_COOLDOWN)))

func _migrate_special_tiles_from_wallz() -> bool:
	if not wallz or not buildings:
		return false

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
		_log("migrated special tile kind=%s cell=%s atlas=%s from wallz to buildings" % [
			kind,
			cell,
			buildings.get_cell_atlas_coords(cell)
		])

	if migrated:
		buildings.update_internals()
		wallz.update_internals()
	return migrated

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
		var house: Dictionary = _houses[cell] as Dictionary
		if not bool(house.get("flow_ready", false)):
			_queue_house_flow_rebuild()
		return
	if not agent_manager or not agent_manager.has_method("create_group"):
		push_warning("BuildingManager: cannot register house, AgentManager has no create_group().")
		return
	if not flow or not flow.has_method("assign_flow_to_group"):
		push_warning("BuildingManager: cannot register house, FlowFieldNative has no assign_flow_to_group().")
		return

	var group_id := int(agent_manager.call("create_group"))
	if group_id < 0:
		push_warning("BuildingManager: cannot register house at %s, create_group() returned %d." % [cell, group_id])
		return

	var target_cell := _find_walkable_cell_near(cell)
	if target_cell == INVALID_CELL:
		push_warning("BuildingManager: house at %s has no walkable floor tile within range." % cell)
		return

	_houses[cell] = {
		"flow_ready": false,
		"group_id": group_id,
		"target_cell": target_cell,
		"world": _cell_center(target_cell)
	}
	_log("registered house cell=%s target=%s world=%s group=%d" % [
		cell,
		target_cell,
		_houses[cell]["world"],
		group_id
	])
	_queue_house_flow_rebuild()

func _rebuild_house_flows() -> void:
	_flow_rebuild_pending = false
	for raw_house_cell in _houses.keys():
		var cell: Vector2i = raw_house_cell
		_assign_house_flow(cell)

func _has_pending_house_flows() -> bool:
	for raw_house_cell in _houses.keys():
		var cell: Vector2i = raw_house_cell
		var house: Dictionary = _houses[cell] as Dictionary
		if not bool(house.get("flow_ready", false)):
			return true
	return false

func _queue_house_flow_rebuild() -> void:
	if _flow_rebuild_pending:
		return
	_flow_rebuild_pending = true
	call_deferred("_rebuild_house_flows")

func _assign_house_flow(cell: Vector2i) -> void:
	if not _houses.has(cell):
		return
	if not flow or not flow.has_method("assign_flow_to_group"):
		push_warning("BuildingManager: cannot assign house flow, FlowFieldNative missing assign_flow_to_group().")
		return
	var house: Dictionary = _houses[cell] as Dictionary
	var group_id := int(house.get("group_id", -1))
	if group_id < 0:
		push_warning("BuildingManager: cannot assign house flow for %s, invalid group %d." % [cell, group_id])
		return
	var world: Vector2 = house.get("world", _cell_center(cell))
	if flow.has_method("rebuild_async"):
		var can_build := bool(flow.call("rebuild_async", world))
		_log("house flow precheck cell=%s group=%d world=%s can_build=%s" % [
			cell,
			group_id,
			world,
			can_build
		])
		if not can_build:
			house["flow_ready"] = false
			_houses[cell] = house
			return
	flow.call("assign_flow_to_group", group_id, world)
	house["flow_ready"] = true
	_houses[cell] = house
	_log("house flow ready cell=%s group=%d world=%s" % [cell, group_id, world])

func _register_spawner(cell: Vector2i, cooldown: float) -> void:
	_spawners[cell] = {
		"cooldown": max(0.05, cooldown)
	}
	if not _spawn_timers.has(cell):
		_spawn_timers[cell] = 0.0

func _process_spawners(delta: float) -> void:
	if _houses.is_empty():
		if not _spawners.is_empty():
			_log_spawn_failure("no valid house found for %d spawner(s)" % _spawners.size())
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
		_log_spawn_failure("spawner %s has no nearest house" % spawner_cell)
		return false

	var house: Dictionary = _houses[house_cell] as Dictionary
	if not bool(house.get("flow_ready", false)):
		_log_spawn_failure("spawner %s nearest house %s exists but flow is not ready" % [spawner_cell, house_cell])
		return false
	var group_id := int(house.get("group_id", -1))
	if group_id < 0:
		_log_spawn_failure("spawner %s nearest house %s has invalid group %d" % [spawner_cell, house_cell, group_id])
		return false

	var occupied := _occupied_cells()
	var spawn_cell := _find_free_cell_near(spawner_cell, occupied)
	if spawn_cell == INVALID_CELL:
		_log_spawn_failure("spawner %s could not find a walkable spawn cell" % spawner_cell)
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
		if agent_manager.has_method("set_agent_never_rest"):
			agent_manager.call("set_agent_never_rest", nav_id, true)
		_log("spawned monster nav_id=%d spawn_cell=%s target_house=%s group=%d" % [
			nav_id,
			spawn_cell,
			house_cell,
			group_id
		])

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

func _find_walkable_cell_near(start_cell: Vector2i, max_radius: int = 8) -> Vector2i:
	if _is_walkable(start_cell):
		return start_cell
	for r in range(1, max_radius + 1):
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				var cell := start_cell + Vector2i(dx, dy)
				if _is_walkable(cell):
					return cell
	return INVALID_CELL

func _is_walkable(cell: Vector2i) -> bool:
	return _has_floor(cell) and not _has_wall(cell)

func _has_floor(cell: Vector2i) -> bool:
	return floorz != null and floorz.get_cell_tile_data(cell) != null

func _has_wall(cell: Vector2i) -> bool:
	return wallz != null and wallz.get_cell_tile_data(cell) != null

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

func _log(message: String) -> void:
	if debug_logs:
		print("BuildingManager: ", message)

func _log_spawn_failure(message: String) -> void:
	if message == _last_spawn_failure:
		return
	_last_spawn_failure = message
	push_warning("BuildingManager: " + message)

func _log_scan_summary(seen_houses: Dictionary, seen_spawners: Dictionary, migrated: bool, walls_changed: bool) -> void:
	var summary := "scan houses=%d spawners=%d registered_houses=%d registered_spawners=%d migrated=%s walls_changed=%s" % [
		seen_houses.size(),
		seen_spawners.size(),
		_houses.size(),
		_spawners.size(),
		migrated,
		walls_changed
	]
	if summary == _last_scan_summary:
		return
	_last_scan_summary = summary
	_log(summary)
