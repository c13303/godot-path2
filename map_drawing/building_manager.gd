extends Node
class_name BuildingManager

const AGENT_SCENE: PackedScene = preload("res://sprites/character/character.tscn")
const BUILD_TILES_INDEX_PATH: String = "res://map_drawing/build_tiles_index.tres"
const DEFAULT_SPAWN_COOLDOWN: float = 2.0
const EATING_COOLDOWN: float = 5.0
const IDLE_GROUP: int = 0
const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)

@export var floorz: TileMapLayer
@export var wallz: TileMapLayer
@export var plantz: TileMapLayer
@export var buildings: TileMapLayer
@export var plant_manager: Node
@export var flow: Node
@export var agent_manager: Node
@export var parent_for_agents: Node
@export var global_config: Node
@export var debug_logs: bool = false

var _tile_defs_by_atlas: Dictionary = {}
var _spawners: Dictionary = {}
var _spawn_timers: Dictionary = {}
var _spawner_routes: Dictionary = {}
var _eating_agents: Dictionary = {}
var _escaping_agents: Dictionary = {}
var _removed_monsters: Array[Node2D] = []
var _scan_timer: float = 0.0
var _last_wall_signature: int = 0
var _last_scan_summary: String = ""
var _last_spawn_failure: String = ""
var _flow_ready: bool = false
var _dirty_spawner_plants: Dictionary = {}
var _dirty_spawner_escapes: Dictionary = {}

const DEBUG_PLANTFF_FRAME_LAG_MS_FALLBACK: float = 100.0
const DEBUG_PLANTFF_FF_LAG_MS_FALLBACK: float = 10.0

func _frame_lag_threshold_ms() -> float:
	if global_config and global_config.has_method("get_debug_plantff_frame_lag_ms"):
		return float(global_config.call("get_debug_plantff_frame_lag_ms"))
	return DEBUG_PLANTFF_FRAME_LAG_MS_FALLBACK

func _ff_lag_threshold_ms() -> float:
	if global_config and global_config.has_method("get_debug_plantff_ff_lag_ms"):
		return float(global_config.call("get_debug_plantff_ff_lag_ms"))
	return DEBUG_PLANTFF_FF_LAG_MS_FALLBACK

func _ready() -> void:
	_load_tile_definitions()
	_migrate_special_tiles_from_wallz()
	_setup_plant_manager()
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
		_sync_runtime_state()
		return
	if bool(code_node.get("is_ready")):
		_flow_ready = true
		_sync_runtime_state()
		return
	code_node.connect("flow_field_ready", Callable(self, "_on_flow_field_ready"))

func _on_flow_field_ready() -> void:
	_flow_ready = true
	_sync_runtime_state()

func _process(delta: float) -> void:
	if not _flow_ready:
		return
	var frame_start_ms: int = Time.get_ticks_msec()
	_scan_timer -= delta
	if _scan_timer <= 0.0:
		_scan_timer = 0.25
		_scan_buildings()

	if not _dirty_spawner_plants.is_empty() or not _dirty_spawner_escapes.is_empty():
		_drain_dirty_routes()

	_process_eating_agents(delta)
	_process_plant_arrivals()
	_process_escape_arrivals()
	_process_spawners(delta)

	var frame_ms: int = Time.get_ticks_msec() - frame_start_ms
	var frame_threshold_ms: float = _frame_lag_threshold_ms()
	if float(frame_ms) > frame_threshold_ms:
		push_warning("debug_plantff_frame_lag: %dms (threshold=%dms) eating=%d escaping=%d spawners=%d" % [
			frame_ms,
			int(frame_threshold_ms),
			_eating_agents.size(),
			_escaping_agents.size(),
			_spawners.size()
		])

func _load_tile_definitions() -> void:
	_tile_defs_by_atlas.clear()
	var res: Resource = load(BUILD_TILES_INDEX_PATH)
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
		var atlas_key: String = _atlas_key(Vector2i(int(atlas[0]), int(atlas[1])))
		_tile_defs_by_atlas[atlas_key] = {
			"key": str(key),
			"kind": str(tile_definition.get("kind", "")),
			"cooldown": float(tile_definition.get("cooldown", DEFAULT_SPAWN_COOLDOWN))
		}

func _scan_buildings() -> void:
	if not buildings:
		return

	var migrated: bool = _migrate_special_tiles_from_wallz()

	var wall_signature: int = _tile_layer_signature(wallz)
	var walls_changed: bool = wall_signature != _last_wall_signature or migrated
	_last_wall_signature = wall_signature

	var seen_spawners: Dictionary = {}
	_scan_special_layer(buildings, seen_spawners)
	_scan_special_layer(wallz, seen_spawners)
	_log_scan_summary(seen_spawners, migrated, walls_changed)

	for raw_spawner_cell in _spawners.keys():
		var cell: Vector2i = raw_spawner_cell
		if not seen_spawners.has(cell):
			_spawners.erase(cell)
			_spawn_timers.erase(cell)
			_release_spawner_route(cell)
			_dirty_spawner_plants.erase(cell)
			_dirty_spawner_escapes.erase(cell)

	if walls_changed:
		for raw_spawner_cell in _spawners.keys():
			_dirty_spawner_plants[raw_spawner_cell] = true
			_dirty_spawner_escapes[raw_spawner_cell] = true

func _sync_runtime_state() -> void:
	_scan_buildings()
	for raw_spawner_cell in _spawners.keys():
		_dirty_spawner_plants[raw_spawner_cell] = true
		_dirty_spawner_escapes[raw_spawner_cell] = true

func _setup_plant_manager() -> void:
	if not plant_manager:
		return
	if plant_manager.has_method("initialize_from_layer"):
		plant_manager.call("initialize_from_layer")
	if plant_manager.has_signal("plant_added") and not plant_manager.is_connected("plant_added", Callable(self, "_on_plant_added")):
		plant_manager.connect("plant_added", Callable(self, "_on_plant_added"))
	if plant_manager.has_signal("plant_removed") and not plant_manager.is_connected("plant_removed", Callable(self, "_on_plant_removed")):
		plant_manager.connect("plant_removed", Callable(self, "_on_plant_removed"))

func _on_plant_added(cell: Vector2i) -> void:
	if not _flow_ready:
		return
	for raw_spawner_cell in _spawners.keys():
		var route: Dictionary = _spawner_routes.get(raw_spawner_cell, {}) as Dictionary
		var current_plant: Vector2i = route.get("plant_cell", INVALID_CELL) as Vector2i
		if current_plant == INVALID_CELL:
			_dirty_spawner_plants[raw_spawner_cell] = true
			continue
		var d_new: Vector2i = cell - raw_spawner_cell
		var d_cur: Vector2i = current_plant - raw_spawner_cell
		if (d_new.x * d_new.x + d_new.y * d_new.y) < (d_cur.x * d_cur.x + d_cur.y * d_cur.y):
			_dirty_spawner_plants[raw_spawner_cell] = true

func _on_plant_removed(cell: Vector2i) -> void:
	for raw_spawner_cell in _spawner_routes.keys():
		var route: Dictionary = _spawner_routes[raw_spawner_cell] as Dictionary
		if route.get("plant_cell", INVALID_CELL) == cell:
			_dirty_spawner_plants[raw_spawner_cell] = true
	if _no_plants_remaining():
		_start_escape_for_all_monsters()

func _scan_special_layer(layer: TileMapLayer, seen_spawners: Dictionary) -> void:
	if not layer:
		return

	for raw_cell in layer.get_used_cells():
		var map_cell: Vector2i = raw_cell
		var definition: Dictionary = _definition_for_layer_cell(layer, map_cell)
		var kind: String = str(definition.get("kind", ""))
		if kind == "spawner":
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

	var migrated: bool = false
	for raw_cell in wallz.get_used_cells():
		var cell: Vector2i = raw_cell
		var definition: Dictionary = _definition_for_layer_cell(wallz, cell)
		var kind: String = str(definition.get("kind", ""))
		if kind == "" or kind == "wall":
			continue

		var target_layer: TileMapLayer = plantz if kind == "plantsToTarget" else buildings
		if not target_layer:
			continue
		target_layer.set_cell(
			cell,
			wallz.get_cell_source_id(cell),
			wallz.get_cell_atlas_coords(cell),
			wallz.get_cell_alternative_tile(cell)
		)
		wallz.erase_cell(cell)
		migrated = true
		_log("migrated special tile kind=%s cell=%s atlas=%s from wallz to %s" % [
			kind,
			cell,
			target_layer.get_cell_atlas_coords(cell),
			target_layer.name
		])

	if migrated:
		buildings.update_internals()
		if plantz:
			plantz.update_internals()
		wallz.update_internals()
	return migrated

func _definition_for_cell(cell: Vector2i) -> Dictionary:
	return _definition_for_layer_cell(buildings, cell)

func _definition_for_layer_cell(layer: TileMapLayer, cell: Vector2i) -> Dictionary:
	if not layer:
		return {}
	var atlas: Vector2i = layer.get_cell_atlas_coords(cell)
	var atlas_key: String = _atlas_key(atlas)
	return _tile_defs_by_atlas.get(atlas_key, {}) as Dictionary

func _register_spawner(cell: Vector2i, cooldown: float) -> void:
	if not _spawners.has(cell):
		_dirty_spawner_plants[cell] = true
		_dirty_spawner_escapes[cell] = true
	_spawners[cell] = {
		"cooldown": max(0.05, cooldown)
	}
	if not _spawn_timers.has(cell):
		_spawn_timers[cell] = 0.0

func _release_spawner_route(spawner_cell: Vector2i) -> void:
	if not _spawner_routes.has(spawner_cell):
		return
	var route: Dictionary = _spawner_routes[spawner_cell] as Dictionary
	var plant_group: int = int(route.get("plant_group", -1))
	var escape_group: int = int(route.get("escape_group", -1))
	if agent_manager and agent_manager.has_method("dissolve_group"):
		if plant_group > IDLE_GROUP:
			agent_manager.call("dissolve_group", plant_group)
		if escape_group > IDLE_GROUP:
			agent_manager.call("dissolve_group", escape_group)
	_spawner_routes.erase(spawner_cell)

func _drain_dirty_routes() -> void:
	if not _flow_ready:
		return
	if not agent_manager or not agent_manager.has_method("create_group"):
		return
	if not flow or not flow.has_method("assign_flow_to_group"):
		return

	var plant_cells: Array = _dirty_spawner_plants.keys()
	var escape_cells: Array = _dirty_spawner_escapes.keys()
	_dirty_spawner_plants.clear()
	_dirty_spawner_escapes.clear()

	for raw_cell in plant_cells:
		if _spawners.has(raw_cell):
			_rebuild_spawner_plant_route(raw_cell)
	for raw_cell in escape_cells:
		if _spawners.has(raw_cell):
			_rebuild_spawner_escape_route(raw_cell)

func _rebuild_spawner_plant_route(spawner_cell: Vector2i) -> void:
	var route: Dictionary = _spawner_routes.get(spawner_cell, {}) as Dictionary
	var plant_cell: Vector2i = _nearest_plant_cell_for_spawner(spawner_cell)
	if plant_cell == INVALID_CELL:
		route["plant_cell"] = INVALID_CELL
		route["plant_target_cell"] = INVALID_CELL
		route["plant_ready"] = false
		_spawner_routes[spawner_cell] = route
		return
	var plant_target_cell: Vector2i = _resolve_walkable_goal(plant_cell, "plantsToTarget@%s" % spawner_cell)
	if plant_target_cell == INVALID_CELL:
		route["plant_cell"] = INVALID_CELL
		route["plant_target_cell"] = INVALID_CELL
		route["plant_ready"] = false
		_spawner_routes[spawner_cell] = route
		return
	var plant_group: int = int(route.get("plant_group", -1))
	if plant_group <= IDLE_GROUP:
		plant_group = int(agent_manager.call("create_group"))
	if plant_group <= IDLE_GROUP:
		push_error("BuildingManager: spawner %s could not allocate plant group (MAX_GROUPS exhausted)" % spawner_cell)
		route["plant_ready"] = false
		_spawner_routes[spawner_cell] = route
		return
	var plant_world: Vector2 = _cell_center(plant_target_cell)
	var ff_start_ms: int = Time.get_ticks_msec()
	flow.call("assign_flow_to_group", plant_group, plant_world)
	var ff_ms: int = Time.get_ticks_msec() - ff_start_ms
	if float(ff_ms) > _ff_lag_threshold_ms():
		push_warning("debug_plantff_slow_plant_ff: spawner=%s plant=%s took=%dms" % [spawner_cell, plant_cell, ff_ms])
	route["plant_cell"] = plant_cell
	route["plant_target_cell"] = plant_target_cell
	route["plant_world"] = plant_world
	route["plant_group"] = plant_group
	route["plant_ready"] = true
	_spawner_routes[spawner_cell] = route

func _rebuild_spawner_escape_route(spawner_cell: Vector2i) -> void:
	var route: Dictionary = _spawner_routes.get(spawner_cell, {}) as Dictionary
	var escape_target_cell: Vector2i = _resolve_walkable_goal(spawner_cell, "escape@%s" % spawner_cell)
	if escape_target_cell == INVALID_CELL:
		route["escape_target_cell"] = INVALID_CELL
		route["escape_ready"] = false
		_spawner_routes[spawner_cell] = route
		return
	var escape_group: int = int(route.get("escape_group", -1))
	if escape_group <= IDLE_GROUP:
		escape_group = int(agent_manager.call("create_group"))
	if escape_group <= IDLE_GROUP:
		push_error("BuildingManager: spawner %s could not allocate escape group (MAX_GROUPS exhausted)" % spawner_cell)
		route["escape_ready"] = false
		_spawner_routes[spawner_cell] = route
		return
	var escape_world: Vector2 = _cell_center(escape_target_cell)
	var ff_start_ms: int = Time.get_ticks_msec()
	flow.call("assign_flow_to_group", escape_group, escape_world)
	var ff_ms: int = Time.get_ticks_msec() - ff_start_ms
	if float(ff_ms) > _ff_lag_threshold_ms():
		push_warning("debug_plantff_slow_escape_ff: spawner=%s took=%dms" % [spawner_cell, ff_ms])
	route["escape_target_cell"] = escape_target_cell
	route["escape_world"] = escape_world
	route["escape_group"] = escape_group
	route["escape_ready"] = true
	_spawner_routes[spawner_cell] = route

func _nearest_plant_cell_for_spawner(spawner_cell: Vector2i) -> Vector2i:
	if plant_manager and plant_manager.has_method("nearest_plant_cell"):
		return plant_manager.call("nearest_plant_cell", spawner_cell, INVALID_CELL) as Vector2i
	return INVALID_CELL

func _no_plants_remaining() -> bool:
	if plant_manager and plant_manager.has_method("is_empty"):
		return bool(plant_manager.call("is_empty"))
	return true

func _resolve_walkable_goal(cell: Vector2i, purpose: String) -> Vector2i:
	if _is_walkable(cell):
		return cell
	var fallback: Vector2i = _find_walkable_cell_near(cell)
	if fallback == INVALID_CELL:
		push_error("BuildingManager: %s target cell %s is not walkable and no walkable cell found within range. floor=%s wall=%s" % [
			purpose, cell, _has_floor(cell), _has_wall(cell)
		])
		return INVALID_CELL
	push_error("BuildingManager: %s target cell %s is a wall/non-walkable; falling back to nearest free tile %s" % [
		purpose, cell, fallback
	])
	return fallback

func _process_spawners(delta: float) -> void:
	if _no_plants_remaining():
		if not _spawners.is_empty():
			_log_spawn_failure("no plants remaining for %d spawner(s)" % _spawners.size())
		return

	for raw_cell in _spawners.keys():
		var cell: Vector2i = raw_cell
		var timer: float = float(_spawn_timers.get(cell, 0.0)) - delta
		if timer > 0.0:
			_spawn_timers[cell] = timer
			continue

		if _spawn_monster_from(cell):
			var spawner: Dictionary = _spawners[cell] as Dictionary
			_spawn_timers[cell] = float(spawner.get("cooldown", DEFAULT_SPAWN_COOLDOWN))
		else:
			_spawn_timers[cell] = 0.25

func _spawn_monster_from(spawner_cell: Vector2i) -> bool:
	var route: Dictionary = _spawner_routes.get(spawner_cell, {}) as Dictionary
	if not bool(route.get("plant_ready", false)):
		_log_spawn_failure("spawner %s plant route not ready" % spawner_cell)
		return false
	var plant_group: int = int(route.get("plant_group", -1))
	if plant_group <= IDLE_GROUP:
		_log_spawn_failure("spawner %s plant group invalid" % spawner_cell)
		return false
	var plant_cell: Vector2i = route.get("plant_cell", INVALID_CELL) as Vector2i
	if plant_cell == INVALID_CELL:
		_log_spawn_failure("spawner %s has no plant cell" % spawner_cell)
		return false

	var occupied: Array[Vector2i] = _occupied_cells()
	var spawn_cell: Vector2i = _find_free_cell_near(spawner_cell, occupied)
	if spawn_cell == INVALID_CELL:
		_log_spawn_failure("spawner %s could not find a walkable spawn cell" % spawner_cell)
		return false

	var agent: Node2D = AGENT_SCENE.instantiate() as Node2D
	var parent: Node = parent_for_agents if parent_for_agents else get_tree().current_scene
	parent.add_child(agent)
	agent.global_position = _cell_center(spawn_cell)
	agent.z_index = int(agent.global_position.y)
	agent.add_to_group("monsters")

	if agent_manager and agent_manager.has_method("spawn_agent"):
		var nav_id: int = int(agent_manager.call("spawn_agent", agent, plant_group))
		agent.set("nav_id", nav_id)
		agent.set_meta("spawner_cell", spawner_cell)
		if agent_manager.has_method("set_agent_never_rest"):
			agent_manager.call("set_agent_never_rest", nav_id, true)
		_log("spawned monster nav_id=%d spawn_cell=%s plant=%s plant_group=%d spawner=%s" % [
			nav_id,
			spawn_cell,
			plant_cell,
			plant_group,
			spawner_cell
		])

	return true

func _process_plant_arrivals() -> void:
	for node in get_tree().get_nodes_in_group("monsters"):
		if not (node is Node2D):
			continue
		var agent: Node2D = node
		var nav_id: int = int(agent.get("nav_id"))
		if _eating_agents.has(nav_id) or _escaping_agents.has(nav_id):
			continue
		if not agent.has_meta("spawner_cell"):
			continue
		var spawner_cell: Vector2i = agent.get_meta("spawner_cell") as Vector2i
		var route: Dictionary = _spawner_routes.get(spawner_cell, {}) as Dictionary
		var plant_cell: Vector2i = route.get("plant_cell", INVALID_CELL) as Vector2i
		if plant_cell == INVALID_CELL:
			continue
		var plant_target_cell: Vector2i = route.get("plant_target_cell", plant_cell) as Vector2i
		if _agent_reached_cell(agent, plant_target_cell):
			if plant_manager and plant_manager.has_method("has_plant") and not bool(plant_manager.call("has_plant", plant_cell)):
				continue
			_consume_plant(agent, spawner_cell, plant_cell)

func _consume_plant(eater: Node2D, _spawner_cell: Vector2i, plant_cell: Vector2i) -> void:
	_start_agent_eating(eater, EATING_COOLDOWN)
	if plant_manager and plant_manager.has_method("remove_plant"):
		plant_manager.call("remove_plant", plant_cell, true)
	elif plantz:
		plantz.erase_cell(plant_cell)
		plantz.update_internals()
	if plantz and plantz.get_cell_source_id(plant_cell) >= 0:
		plantz.erase_cell(plant_cell)
		plantz.update_internals()

func _process_eating_agents(delta: float) -> void:
	var finished: Array[int] = []
	for raw_nav_id in _eating_agents.keys():
		var nav_id: int = int(raw_nav_id)
		var data: Dictionary = _eating_agents[nav_id] as Dictionary
		var timer: float = float(data.get("timer", 0.0)) - delta
		data["timer"] = timer
		_eating_agents[nav_id] = data
		if timer <= 0.0:
			finished.append(nav_id)

	for nav_id in finished:
		var data: Dictionary = _eating_agents.get(nav_id, {}) as Dictionary
		_erase_eating_agent(nav_id)
		var agent: Node2D = data.get("node", null) as Node2D
		if is_instance_valid(agent):
			if agent.has_method("stop_eating"):
				agent.call("stop_eating")
			_assign_agent_to_escape(agent)

func _erase_eating_agent(nav_id: int) -> void:
	_eating_agents.erase(nav_id)

func _start_agent_eating(agent: Node2D, seconds: float) -> void:
	var nav_id: int = int(agent.get("nav_id"))
	_eating_agents[nav_id] = {
		"node": agent,
		"timer": seconds
	}
	if agent_manager and agent_manager.has_method("detach_agent_flow"):
		agent_manager.call("detach_agent_flow", nav_id)
	if agent.has_method("start_eating"):
		agent.call("start_eating", seconds)

func _start_escape_for_all_monsters() -> void:
	for node in get_tree().get_nodes_in_group("monsters"):
		if node is Node2D:
			var agent: Node2D = node
			var nav_id: int = int(agent.get("nav_id"))
			if _escaping_agents.has(nav_id) or _eating_agents.has(nav_id):
				continue
			_assign_agent_to_escape(agent)

func _assign_agent_to_escape(agent: Node2D) -> void:
	if not agent_manager or not agent_manager.has_method("assign_agent"):
		return
	var spawner_cell: Vector2i = INVALID_CELL
	if agent.has_meta("spawner_cell"):
		var pre_linked: Vector2i = agent.get_meta("spawner_cell") as Vector2i
		if _spawner_routes.has(pre_linked):
			spawner_cell = pre_linked
	if spawner_cell == INVALID_CELL:
		var from_cell: Vector2i = floorz.local_to_map(floorz.to_local(agent.global_position))
		spawner_cell = _nearest_spawner_cell(from_cell)
	if spawner_cell == INVALID_CELL or not _spawner_routes.has(spawner_cell):
		return
	var route: Dictionary = _spawner_routes[spawner_cell] as Dictionary
	if not bool(route.get("escape_ready", false)):
		return
	var escape_group: int = int(route.get("escape_group", -1))
	if escape_group <= IDLE_GROUP:
		return
	agent_manager.call("assign_agent", agent, escape_group)
	var nav_id: int = int(agent.get("nav_id"))
	_erase_eating_agent(nav_id)
	if agent_manager.has_method("set_agent_never_rest"):
		agent_manager.call("set_agent_never_rest", nav_id, true)
	agent.set_meta("spawner_cell", spawner_cell)
	_escaping_agents[nav_id] = {
		"node": agent,
		"target_cell": route.get("escape_target_cell", spawner_cell),
		"spawner_cell": spawner_cell
	}
	if agent.has_method("stop_eating"):
		agent.call("stop_eating")
	if agent.has_method("start_escape"):
		agent.call("start_escape")

func _process_escape_arrivals() -> void:
	var arrived: Array[int] = []
	for raw_nav_id in _escaping_agents.keys():
		var nav_id: int = int(raw_nav_id)
		var data: Dictionary = _escaping_agents[nav_id] as Dictionary
		var agent: Node2D = data.get("node", null) as Node2D
		if not is_instance_valid(agent):
			arrived.append(nav_id)
			continue
		var target_cell: Vector2i = data.get("target_cell", INVALID_CELL) as Vector2i
		var spawner_cell: Vector2i = data.get("spawner_cell", INVALID_CELL) as Vector2i
		if _agent_within_tiles(agent, target_cell, 1) or _agent_within_tiles(agent, spawner_cell, 1):
			_remove_escaped_monster(agent)
			arrived.append(nav_id)

	for nav_id in arrived:
		_escaping_agents.erase(nav_id)
		_erase_eating_agent(nav_id)

func _remove_escaped_monster(agent: Node2D) -> void:
	if agent.has_method("stop_escape"):
		agent.call("stop_escape")
	agent.remove_from_group("monsters")
	var parent: Node = agent.get_parent()
	if parent:
		parent.remove_child(agent)
	_removed_monsters.append(agent)

func _nearest_spawner_cell(from_cell: Vector2i) -> Vector2i:
	var best_cell: Vector2i = INVALID_CELL
	var best_dist_sq: int = 2147483647
	for raw_spawner_cell in _spawners.keys():
		var spawner_cell: Vector2i = raw_spawner_cell
		var d: Vector2i = spawner_cell - from_cell
		var dist_sq: int = d.x * d.x + d.y * d.y
		if dist_sq < best_dist_sq:
			best_dist_sq = dist_sq
			best_cell = spawner_cell
	return best_cell

func _agent_reached_cell(agent: Node2D, cell: Vector2i) -> bool:
	var agent_cell: Vector2i = floorz.local_to_map(floorz.to_local(agent.global_position))
	if agent_cell == cell:
		return true
	var tile_size: Vector2 = Vector2(32, 32)
	if floorz and floorz.tile_set:
		var raw_tile_size: Vector2i = floorz.tile_set.get_tile_size()
		tile_size = Vector2(float(raw_tile_size.x), float(raw_tile_size.y))
	return agent.global_position.distance_to(_cell_center(cell)) <= max(tile_size.x, tile_size.y) * 0.5

func _agent_within_tiles(agent: Node2D, cell: Vector2i, tiles: int) -> bool:
	if cell == INVALID_CELL:
		return false
	var agent_cell: Vector2i = floorz.local_to_map(floorz.to_local(agent.global_position))
	var d: Vector2i = agent_cell - cell
	return abs(d.x) <= tiles and abs(d.y) <= tiles

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
				var cell: Vector2i = start_cell + Vector2i(dx, dy)
				if cell not in occupied and _is_walkable(cell):
					return cell
	return INVALID_CELL

func _find_walkable_cell_near(start_cell: Vector2i, max_radius: int = 8) -> Vector2i:
	if _is_walkable(start_cell):
		return start_cell
	for r in range(1, max_radius + 1):
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				var cell: Vector2i = start_cell + Vector2i(dx, dy)
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
	var signature: int = 17
	for raw_cell in layer.get_used_cells():
		var cell: Vector2i = raw_cell
		var atlas: Vector2i = layer.get_cell_atlas_coords(cell)
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

func _log_scan_summary(seen_spawners: Dictionary, migrated: bool, walls_changed: bool) -> void:
	var plant_count: int = int(plant_manager.call("size")) if plant_manager and plant_manager.has_method("size") else 0
	var summary: String = "scan indexed_plants=%d spawners=%d registered_spawners=%d migrated=%s walls_changed=%s" % [
		plant_count,
		seen_spawners.size(),
		_spawners.size(),
		migrated,
		walls_changed
	]
	if summary == _last_scan_summary:
		return
	_last_scan_summary = summary
	_log(summary)
