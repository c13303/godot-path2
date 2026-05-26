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
@export var debug_logs: bool = false

var _tile_defs_by_atlas: Dictionary = {}
var _plants_to_target: Dictionary = {}
var _spawners: Dictionary = {}
var _escape_targets: Dictionary = {}
var _spawn_timers: Dictionary = {}
var _eating_agents: Dictionary = {}
var _escaping_agents: Dictionary = {}
var _removed_monsters: Array[Node2D] = []
var _scan_timer: float = 0.0
var _last_wall_signature: int = 0
var _flow_rebuild_pending: bool = false
var _force_flow_rebuild_all: bool = false
var _last_scan_summary: String = ""
var _last_spawn_failure: String = ""
var _flow_ready: bool = false

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
	_scan_timer -= delta
	if _scan_timer <= 0.0:
		_scan_timer = 0.25
		_scan_buildings()

	_process_eating_agents(delta)
	_process_plant_arrivals()
	_process_escape_arrivals()
	_process_spawners(delta)

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
			_escape_targets.erase(cell)

	if walls_changed:
		_queue_plant_flow_rebuild(true)
	elif _has_pending_plant_flows():
		_queue_plant_flow_rebuild()

func _sync_runtime_state() -> void:
	_sync_plants_from_manager()
	_scan_buildings()
	if _plants_to_target.is_empty():
		_start_escape_for_all_monsters()

func _setup_plant_manager() -> void:
	if not plant_manager:
		return
	if plant_manager.has_method("initialize_from_layer"):
		plant_manager.call("initialize_from_layer")
	if plant_manager.has_signal("plant_added") and not plant_manager.is_connected("plant_added", Callable(self, "_on_plant_added")):
		plant_manager.connect("plant_added", Callable(self, "_on_plant_added"))
	if plant_manager.has_signal("plant_removed") and not plant_manager.is_connected("plant_removed", Callable(self, "_on_plant_removed")):
		plant_manager.connect("plant_removed", Callable(self, "_on_plant_removed"))

func _sync_plants_from_manager() -> void:
	if not plant_manager or not plant_manager.has_method("get_plant_cells"):
		return
	for raw_cell in plant_manager.call("get_plant_cells"):
		var cell: Vector2i = raw_cell
		_register_plant_to_target(cell)

func _on_plant_added(cell: Vector2i) -> void:
	if not _flow_ready:
		return
	_register_plant_to_target(cell)

func _on_plant_removed(cell: Vector2i) -> void:
	_plants_to_target.erase(cell)
	_retarget_monsters_from_plant(cell, null)
	if _plants_to_target.is_empty():
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

func _register_plant_to_target(cell: Vector2i) -> void:
	if _plants_to_target.has(cell):
		var plant_to_target: Dictionary = _plants_to_target[cell] as Dictionary
		if not bool(plant_to_target.get("flow_ready", false)):
			_queue_plant_flow_rebuild()
		return
	if not agent_manager or not agent_manager.has_method("create_group"):
		push_warning("BuildingManager: cannot register plantsToTarget, AgentManager has no create_group().")
		return
	if not flow or not flow.has_method("assign_flow_to_group"):
		push_warning("BuildingManager: cannot register plantsToTarget, FlowFieldNative has no assign_flow_to_group().")
		return

	var group_id: int = int(agent_manager.call("create_group"))
	if group_id <= IDLE_GROUP:
		push_warning("BuildingManager: cannot register plantsToTarget at %s, create_group() returned %d." % [cell, group_id])
		return

	var target_cell: Vector2i = _find_walkable_cell_near(cell)
	if target_cell == INVALID_CELL:
		push_warning("BuildingManager: plantsToTarget at %s has no walkable floor tile within range." % cell)
		return

	_plants_to_target[cell] = {
		"flow_ready": false,
		"group_id": group_id,
		"target_cell": target_cell,
		"world": _cell_center(target_cell)
	}
	_log("registered plantsToTarget cell=%s target=%s world=%s group=%d" % [
		cell,
		target_cell,
		_plants_to_target[cell]["world"],
		group_id
	])
	_queue_plant_flow_rebuild()

func _rebuild_plant_flows() -> void:
	_flow_rebuild_pending = false
	var force_all: bool = _force_flow_rebuild_all
	_force_flow_rebuild_all = false
	for raw_plant_cell in _plants_to_target.keys():
		var cell: Vector2i = raw_plant_cell
		var plant_to_target: Dictionary = _plants_to_target[cell] as Dictionary
		if force_all or not bool(plant_to_target.get("flow_ready", false)):
			_assign_plant_flow(cell)

func _has_pending_plant_flows() -> bool:
	for raw_plant_cell in _plants_to_target.keys():
		var cell: Vector2i = raw_plant_cell
		var plant_to_target: Dictionary = _plants_to_target[cell] as Dictionary
		if not bool(plant_to_target.get("flow_ready", false)):
			return true
	return false

func _queue_plant_flow_rebuild(force_all: bool = false) -> void:
	_force_flow_rebuild_all = _force_flow_rebuild_all or force_all
	if _flow_rebuild_pending:
		return
	_flow_rebuild_pending = true
	call_deferred("_rebuild_plant_flows")

func _assign_plant_flow(cell: Vector2i) -> void:
	if not _plants_to_target.has(cell):
		return
	if not flow or not flow.has_method("assign_flow_to_group"):
		push_warning("BuildingManager: cannot assign plantsToTarget flow, FlowFieldNative missing assign_flow_to_group().")
		return
	var plant_to_target: Dictionary = _plants_to_target[cell] as Dictionary
	var group_id: int = int(plant_to_target.get("group_id", -1))
	if group_id <= IDLE_GROUP:
		push_warning("BuildingManager: cannot assign plantsToTarget flow for %s, invalid group %d." % [cell, group_id])
		return
	var world: Vector2 = plant_to_target.get("world", _cell_center(cell)) as Vector2
	flow.call("assign_flow_to_group", group_id, world)
	plant_to_target["flow_ready"] = true
	_plants_to_target[cell] = plant_to_target
	_log("plantsToTarget flow ready cell=%s group=%d world=%s" % [cell, group_id, world])

func _register_spawner(cell: Vector2i, cooldown: float) -> void:
	_spawners[cell] = {
		"cooldown": max(0.05, cooldown)
	}
	if not _spawn_timers.has(cell):
		_spawn_timers[cell] = 0.0

func _register_escape_target(cell: Vector2i) -> void:
	if _escape_targets.has(cell):
		return
	if not agent_manager or not agent_manager.has_method("create_group"):
		return
	var target_cell: Vector2i = _find_walkable_cell_near(cell)
	if target_cell == INVALID_CELL:
		return
	var group_id: int = int(agent_manager.call("create_group"))
	if group_id <= IDLE_GROUP:
		return
	_escape_targets[cell] = {
		"group_id": group_id,
		"target_cell": target_cell,
		"world": _cell_center(target_cell),
		"flow_ready": false
	}
	_assign_escape_flow(cell)

func _register_escape_target_from_agent_group(cell: Vector2i, agent: Node2D) -> void:
	if _escape_targets.has(cell):
		return
	if not agent.has_meta("target_group_id"):
		return
	var group_id: int = int(agent.get_meta("target_group_id"))
	if group_id <= IDLE_GROUP:
		return
	var target_cell: Vector2i = _find_walkable_cell_near(cell)
	if target_cell == INVALID_CELL:
		return
	_escape_targets[cell] = {
		"group_id": group_id,
		"target_cell": target_cell,
		"world": _cell_center(target_cell),
		"flow_ready": false
	}
	_assign_escape_flow(cell)

func _assign_escape_flow(cell: Vector2i) -> void:
	if not _escape_targets.has(cell):
		return
	if not flow or not flow.has_method("assign_flow_to_group"):
		return
	var escape_target: Dictionary = _escape_targets[cell] as Dictionary
	var group_id: int = int(escape_target.get("group_id", -1))
	if group_id <= IDLE_GROUP:
		return
	var world: Vector2 = escape_target.get("world", _cell_center(cell)) as Vector2
	flow.call("assign_flow_to_group", group_id, world)
	escape_target["flow_ready"] = true
	_escape_targets[cell] = escape_target

func _process_spawners(delta: float) -> void:
	if _plants_to_target.is_empty():
		if not _spawners.is_empty():
			_log_spawn_failure("no valid plantsToTarget found for %d spawner(s)" % _spawners.size())
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
	var plant_cell: Vector2i = _nearest_plant_to_target_cell(spawner_cell)
	if plant_cell == INVALID_CELL:
		_log_spawn_failure("spawner %s has no nearest plantsToTarget" % spawner_cell)
		return false

	var plant_to_target: Dictionary = _plants_to_target[plant_cell] as Dictionary
	if not bool(plant_to_target.get("flow_ready", false)):
		_log_spawn_failure("spawner %s nearest plantsToTarget %s exists but flow is not ready" % [spawner_cell, plant_cell])
		return false
	var group_id: int = int(plant_to_target.get("group_id", -1))
	if group_id <= IDLE_GROUP:
		_log_spawn_failure("spawner %s nearest plantsToTarget %s has invalid group %d" % [spawner_cell, plant_cell, group_id])
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
		var nav_id: int = int(agent_manager.call("spawn_agent", agent, group_id))
		agent.set("nav_id", nav_id)
		agent.set_meta("target_plant_cell", plant_cell)
		agent.set_meta("target_group_id", group_id)
		if agent_manager.has_method("set_agent_never_rest"):
			agent_manager.call("set_agent_never_rest", nav_id, true)
		_log("spawned monster nav_id=%d spawn_cell=%s target_plantsToTarget=%s group=%d" % [
			nav_id,
			spawn_cell,
			plant_cell,
			group_id
		])

	return true

func _nearest_plant_to_target_cell(from_cell: Vector2i, excluded_cell: Vector2i = INVALID_CELL) -> Vector2i:
	if plant_manager and plant_manager.has_method("nearest_plant_cell"):
		var indexed_cell: Vector2i = plant_manager.call("nearest_plant_cell", from_cell, excluded_cell) as Vector2i
		if indexed_cell == INVALID_CELL:
			return INVALID_CELL
		if not _plants_to_target.has(indexed_cell):
			_register_plant_to_target(indexed_cell)
		if _plants_to_target.has(indexed_cell):
			return indexed_cell

	var best_cell: Vector2i = INVALID_CELL
	var best_dist_sq: int = 2147483647
	for raw_plant_cell in _plants_to_target.keys():
		var plant_cell: Vector2i = raw_plant_cell
		if plant_cell == excluded_cell:
			continue
		var d: Vector2i = plant_cell - from_cell
		var dist_sq: int = d.x * d.x + d.y * d.y
		if dist_sq < best_dist_sq:
			best_dist_sq = dist_sq
			best_cell = plant_cell
	return best_cell

func _process_plant_arrivals() -> void:
	if _plants_to_target.is_empty():
		return
	for node in get_tree().get_nodes_in_group("monsters"):
		if not (node is Node2D):
			continue
		var agent: Node2D = node
		var nav_id: int = int(agent.get("nav_id"))
		if _eating_agents.has(nav_id) or _escaping_agents.has(nav_id):
			continue
		if not agent.has_meta("target_plant_cell"):
			continue
		var plant_cell: Vector2i = agent.get_meta("target_plant_cell") as Vector2i
		if not _plants_to_target.has(plant_cell):
			_assign_agent_to_nearest_plant(agent)
			continue
		var plant_to_target: Dictionary = _plants_to_target[plant_cell] as Dictionary
		var target_cell: Vector2i = plant_to_target.get("target_cell", plant_cell) as Vector2i
		if _agent_reached_cell(agent, target_cell):
			_consume_plant_to_target(agent, plant_cell)

func _consume_plant_to_target(eater: Node2D, plant_cell: Vector2i) -> void:
	var plant_to_target: Dictionary = _plants_to_target.get(plant_cell, {}) as Dictionary
	var hold_group: int = int(plant_to_target.get("group_id", -1))
	_assign_agent_to_idle(eater, hold_group)
	_start_agent_eating(eater, EATING_COOLDOWN)
	if plant_manager and plant_manager.has_method("remove_plant"):
		plant_manager.call("remove_plant", plant_cell, true)
	else:
		if plantz:
			plantz.erase_cell(plant_cell)
			plantz.update_internals()
		_plants_to_target.erase(plant_cell)
		_retarget_monsters_from_plant(plant_cell, eater)
	if plantz and plantz.get_cell_source_id(plant_cell) >= 0:
		plantz.erase_cell(plant_cell)
		plantz.update_internals()

func _retarget_monsters_from_plant(old_plant_cell: Vector2i, eater: Node2D = null) -> void:
	for node in get_tree().get_nodes_in_group("monsters"):
		if not (node is Node2D) or (eater and node == eater):
			continue
		var agent: Node2D = node
		var nav_id: int = int(agent.get("nav_id"))
		if _eating_agents.has(nav_id) or _escaping_agents.has(nav_id):
			continue
		if not agent.has_meta("target_plant_cell"):
			continue
		var target_cell: Vector2i = agent.get_meta("target_plant_cell") as Vector2i
		if target_cell == old_plant_cell:
			_assign_agent_to_nearest_plant(agent)

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
		_eating_agents.erase(nav_id)
		var agent: Node2D = data.get("node", null) as Node2D
		if is_instance_valid(agent):
			if agent.has_method("stop_eating"):
				agent.call("stop_eating")
			if _plants_to_target.is_empty():
				_assign_agent_to_escape(agent)
			else:
				_assign_agent_to_nearest_plant(agent)

func _start_agent_eating(agent: Node2D, seconds: float) -> void:
	var nav_id: int = int(agent.get("nav_id"))
	_eating_agents[nav_id] = {
		"node": agent,
		"timer": seconds
	}
	if agent.has_method("start_eating"):
		agent.call("start_eating", seconds)

func _assign_agent_to_idle(agent: Node2D, hold_group: int = -1) -> void:
	if not agent_manager or not agent_manager.has_method("assign_agent"):
		return
	if hold_group < 0 and agent_manager.has_method("create_group"):
		hold_group = int(agent_manager.call("create_group"))
	if hold_group > IDLE_GROUP and flow and flow.has_method("assign_flow_to_group"):
		agent_manager.call("assign_agent", agent, hold_group)
		flow.call("assign_flow_to_group", hold_group, agent.global_position)
		agent.set_meta("target_group_id", hold_group)
	else:
		agent_manager.call("assign_agent", agent, IDLE_GROUP)
	var nav_id: int = int(agent.get("nav_id"))
	if agent_manager.has_method("set_agent_never_rest"):
		agent_manager.call("set_agent_never_rest", nav_id, false)

func _assign_agent_to_nearest_plant(agent: Node2D) -> void:
	if not agent_manager or not agent_manager.has_method("assign_agent"):
		return
	var from_cell: Vector2i = floorz.local_to_map(floorz.to_local(agent.global_position))
	var plant_cell: Vector2i = _nearest_plant_to_target_cell(from_cell)
	if plant_cell == INVALID_CELL:
		_assign_agent_to_escape(agent)
		return
	var plant_to_target: Dictionary = _plants_to_target[plant_cell] as Dictionary
	var group_id: int = int(plant_to_target.get("group_id", -1))
	if group_id <= IDLE_GROUP:
		_assign_agent_to_idle(agent)
		return
	agent_manager.call("assign_agent", agent, group_id)
	agent.set_meta("target_plant_cell", plant_cell)
	agent.set_meta("target_group_id", group_id)
	var nav_id: int = int(agent.get("nav_id"))
	if agent_manager.has_method("set_agent_never_rest"):
		agent_manager.call("set_agent_never_rest", nav_id, true)

func _start_escape_for_all_monsters() -> void:
	for node in get_tree().get_nodes_in_group("monsters"):
		if node is Node2D:
			var agent: Node2D = node
			var nav_id: int = int(agent.get("nav_id"))
			if _escaping_agents.has(nav_id):
				continue
			_assign_agent_to_escape(agent)

func _assign_agent_to_escape(agent: Node2D) -> void:
	if not agent_manager or not agent_manager.has_method("assign_agent"):
		return
	var from_cell: Vector2i = floorz.local_to_map(floorz.to_local(agent.global_position))
	var spawner_cell: Vector2i = _nearest_spawner_cell(from_cell)
	if spawner_cell == INVALID_CELL:
		_assign_agent_to_idle(agent)
		return
	if not _escape_targets.has(spawner_cell):
		_register_escape_target(spawner_cell)
	if not _escape_targets.has(spawner_cell):
		_register_escape_target_from_agent_group(spawner_cell, agent)
		if not _escape_targets.has(spawner_cell):
			_assign_agent_to_idle(agent)
			return
	var escape_target: Dictionary = _escape_targets[spawner_cell] as Dictionary
	if not bool(escape_target.get("flow_ready", false)):
		_assign_escape_flow(spawner_cell)
	var group_id: int = int(escape_target.get("group_id", -1))
	if group_id <= IDLE_GROUP:
		_assign_agent_to_idle(agent)
		return
	agent_manager.call("assign_agent", agent, group_id)
	var nav_id: int = int(agent.get("nav_id"))
	_eating_agents.erase(nav_id)
	if agent_manager.has_method("set_agent_never_rest"):
		agent_manager.call("set_agent_never_rest", nav_id, true)
	if agent.has_meta("target_plant_cell"):
		agent.remove_meta("target_plant_cell")
	agent.set_meta("escape_spawner_cell", spawner_cell)
	_escaping_agents[nav_id] = {
		"node": agent,
		"target_cell": escape_target.get("target_cell", spawner_cell)
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
		if target_cell != INVALID_CELL and _agent_reached_cell(agent, target_cell):
			_remove_escaped_monster(agent)
			arrived.append(nav_id)

	for nav_id in arrived:
		_escaping_agents.erase(nav_id)
		_eating_agents.erase(nav_id)

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
	var plant_count: int = int(plant_manager.call("size")) if plant_manager and plant_manager.has_method("size") else _plants_to_target.size()
	var summary: String = "scan indexed_plants=%d spawners=%d registered_plantsToTarget=%d registered_spawners=%d migrated=%s walls_changed=%s" % [
		plant_count,
		seen_spawners.size(),
		_plants_to_target.size(),
		_spawners.size(),
		migrated,
		walls_changed
	]
	if summary == _last_scan_summary:
		return
	_last_scan_summary = summary
	_log(summary)
