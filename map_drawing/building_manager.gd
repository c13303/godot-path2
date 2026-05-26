extends Node
class_name BuildingManager

const AGENT_SCENE: PackedScene = preload("res://sprites/character/character.tscn")
const BUILD_TILES_INDEX_PATH: String = "res://map_drawing/build_tiles_index.tres"
const DEFAULT_SPAWN_COOLDOWN: float = 2.0
const EATING_COOLDOWN: float = 5.0
const IDLE_GROUP: int = 0
const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)
const EXIT_WALL_ATLAS: Vector2i = Vector2i(13, 0)
const PLANT_ZONE_MARGIN: int = 2

@export var floorz: TileMapLayer
@export var wallz: TileMapLayer
@export var plantz: TileMapLayer
@export var buildings: TileMapLayer
@export var plant_manager: Node
@export var flow: Node
@export var agent_manager: Node
@export var pathfinder: Node
@export var parent_for_agents: Node
@export var global_config: Node
@export var debug_logs: bool = false
@export var debug_show_plantzone: bool = false:
	set(value):
		debug_show_plantzone = value
		if _zone_overlay:
			_zone_overlay.visible = value
			_zone_overlay.queue_redraw()

var _tile_defs_by_atlas: Dictionary = {}
var _spawners: Dictionary = {}
var _spawn_timers: Dictionary = {}
var _spawner_routes: Dictionary = {}
var _eating_agents: Dictionary = {}
var _escaping_agents: Dictionary = {}
var _astar_in_agents: Dictionary = {}
var _astar_out_agents: Dictionary = {}
var _removed_monsters: Array[Node2D] = []
var _scan_timer: float = 0.0
var _last_wall_signature: int = 0
var _last_scan_summary: String = ""
var _last_spawn_failure: String = ""
var _flow_ready: bool = false
var _dirty_spawner_escapes: Dictionary = {}

# Plant zone (one-shot at start). Tiles use the floorz tilemap cell space.
var _plant_zone_tiles: Dictionary = {}  # Vector2i -> true
var _plant_zone_margin_tiles: Dictionary = {}  # Vector2i -> true (entry/exit candidates)
var _plant_zone_built: bool = false
var _zone_overlay: Node2D

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
	_setup_zone_overlay()
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
		_build_plant_zone()
		_sync_runtime_state()
		return
	if bool(code_node.get("is_ready")):
		_flow_ready = true
		_build_plant_zone()
		_sync_runtime_state()
		return
	code_node.connect("flow_field_ready", Callable(self, "_on_flow_field_ready"))

func _on_flow_field_ready() -> void:
	_flow_ready = true
	_build_plant_zone()
	_sync_runtime_state()

func _setup_zone_overlay() -> void:
	_zone_overlay = Node2D.new()
	_zone_overlay.name = "PlantZoneOverlay"
	_zone_overlay.z_index = 100
	_zone_overlay.z_as_relative = false
	_zone_overlay.visible = debug_show_plantzone
	_zone_overlay.set_script(load("res://map_drawing/plant_zone_overlay.gd"))
	_zone_overlay.set("building_manager", self)
	var overlay_parent: Node = floorz if floorz else self
	overlay_parent.add_child(_zone_overlay)

func _process(delta: float) -> void:
	if not _flow_ready:
		return
	var frame_start_ms: int = Time.get_ticks_msec()
	_scan_timer -= delta
	if _scan_timer <= 0.0:
		_scan_timer = 0.25
		_scan_buildings()

	if not _dirty_spawner_escapes.is_empty():
		_drain_dirty_routes()

	_process_eating_agents(delta)
	_process_astar_in_arrivals()
	_process_plant_arrivals()
	_process_astar_out_arrivals()
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
			_dirty_spawner_escapes.erase(cell)

	if walls_changed:
		# Walls reshape the FF cost field; rebuild every spawner's plant + escape FFs
		# using their CACHED static goals (no goal re-derivation).
		for raw_spawner_cell in _spawners.keys():
			_rebuild_spawner_plant_ff(raw_spawner_cell)
			_dirty_spawner_escapes[raw_spawner_cell] = true

func _sync_runtime_state() -> void:
	_scan_buildings()
	for raw_spawner_cell in _spawners.keys():
		_initialize_spawner_route(raw_spawner_cell)

func _setup_plant_manager() -> void:
	if not plant_manager:
		return
	if plant_manager.has_method("initialize_from_layer"):
		plant_manager.call("initialize_from_layer")
	if plant_manager.has_signal("plant_added") and not plant_manager.is_connected("plant_added", Callable(self, "_on_plant_added")):
		plant_manager.connect("plant_added", Callable(self, "_on_plant_added"))
	if plant_manager.has_signal("plant_removed") and not plant_manager.is_connected("plant_removed", Callable(self, "_on_plant_removed")):
		plant_manager.connect("plant_removed", Callable(self, "_on_plant_removed"))

func _on_plant_added(_cell: Vector2i) -> void:
	# FF goals are static (plant_zone_entry_cell), so plant changes no longer
	# invalidate the FF layer. The plant zone itself is computed once at start
	# and not rebuilt. Plant additions still appear in plant_manager for nearest-
	# plant queries; that is enough.
	pass

func _on_plant_removed(_cell: Vector2i) -> void:
	# See _on_plant_added: no FF dirty flag. Panic escape if zone is now empty.
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
	var is_new: bool = not _spawners.has(cell)
	_spawners[cell] = {
		"cooldown": max(0.05, cooldown)
	}
	if not _spawn_timers.has(cell):
		_spawn_timers[cell] = 0.0
	if is_new and _flow_ready and _plant_zone_built:
		_initialize_spawner_route(cell)

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

	var escape_cells: Array = _dirty_spawner_escapes.keys()
	_dirty_spawner_escapes.clear()

	for raw_cell in escape_cells:
		if _spawners.has(raw_cell):
			_rebuild_spawner_escape_ff(raw_cell)

func _initialize_spawner_route(spawner_cell: Vector2i) -> void:
	# One-shot: compute all 4 static cells (exit_wall, escape_wall_target,
	# plant_zone_entry, plant_zone_exit) and assign plant + escape FFs.
	if not _flow_ready or not _plant_zone_built:
		return
	if not agent_manager or not flow:
		return

	var route: Dictionary = _spawner_routes.get(spawner_cell, {}) as Dictionary

	# Exit wall tile (nearest atlas (13,0) on wallz by Manhattan distance).
	var exit_wall_cell: Vector2i = _nearest_exit_wall_for_spawner(spawner_cell)
	route["exit_wall_cell"] = exit_wall_cell

	# Floor tile adjacent to the exit wall that the FF can target.
	var escape_wall_target_cell: Vector2i = INVALID_CELL
	if exit_wall_cell != INVALID_CELL:
		escape_wall_target_cell = _nearest_walkable_adjacent(exit_wall_cell)
	if escape_wall_target_cell == INVALID_CELL:
		# Fallback to spawner cell if no walkable adjacency to an exit wall.
		escape_wall_target_cell = _resolve_walkable_goal(spawner_cell, "escape@%s" % spawner_cell)
	route["escape_wall_target_cell"] = escape_wall_target_cell

	# Entry into plant zone (nearest margin tile to spawner).
	var entry_cell: Vector2i = _nearest_margin_tile(spawner_cell)
	route["plant_zone_entry_cell"] = entry_cell

	# Exit out of plant zone (nearest margin tile to exit wall).
	var exit_cell: Vector2i = INVALID_CELL
	if exit_wall_cell != INVALID_CELL:
		exit_cell = _nearest_margin_tile(exit_wall_cell)
	if exit_cell == INVALID_CELL:
		exit_cell = entry_cell
	route["plant_zone_exit_cell"] = exit_cell

	# Plant FF: goal = entry margin tile (static).
	if entry_cell != INVALID_CELL:
		var plant_group: int = int(route.get("plant_group", -1))
		if plant_group <= IDLE_GROUP:
			plant_group = int(agent_manager.call("create_group"))
		if plant_group > IDLE_GROUP:
			var entry_world: Vector2 = _cell_center(entry_cell)
			flow.call("assign_flow_to_group", plant_group, entry_world)
			route["plant_group"] = plant_group
			route["plant_world"] = entry_world
			route["plant_ready"] = true
		else:
			push_error("BuildingManager: spawner %s could not allocate plant group" % spawner_cell)
			route["plant_ready"] = false
	else:
		route["plant_ready"] = false

	# Escape FF: goal = floor tile adjacent to exit wall (static).
	if escape_wall_target_cell != INVALID_CELL:
		var escape_group: int = int(route.get("escape_group", -1))
		if escape_group <= IDLE_GROUP:
			escape_group = int(agent_manager.call("create_group"))
		if escape_group > IDLE_GROUP:
			var escape_world: Vector2 = _cell_center(escape_wall_target_cell)
			flow.call("assign_flow_to_group", escape_group, escape_world)
			route["escape_group"] = escape_group
			route["escape_world"] = escape_world
			route["escape_ready"] = true
		else:
			push_error("BuildingManager: spawner %s could not allocate escape group" % spawner_cell)
			route["escape_ready"] = false
	else:
		route["escape_ready"] = false

	_spawner_routes[spawner_cell] = route
	_log("initialized spawner=%s exit_wall=%s escape_target=%s entry=%s exit=%s" % [
		spawner_cell, exit_wall_cell, escape_wall_target_cell, entry_cell, exit_cell
	])

func _rebuild_spawner_plant_ff(spawner_cell: Vector2i) -> void:
	# Re-run plant FF after walls change. Goal is the cached entry cell.
	var route: Dictionary = _spawner_routes.get(spawner_cell, {}) as Dictionary
	var entry_cell: Vector2i = route.get("plant_zone_entry_cell", INVALID_CELL) as Vector2i
	if entry_cell == INVALID_CELL:
		return
	var plant_group: int = int(route.get("plant_group", -1))
	if plant_group <= IDLE_GROUP:
		return
	var entry_world: Vector2 = _cell_center(entry_cell)
	flow.call("assign_flow_to_group", plant_group, entry_world)
	route["plant_world"] = entry_world
	_spawner_routes[spawner_cell] = route

func _rebuild_spawner_escape_ff(spawner_cell: Vector2i) -> void:
	# Re-run escape FF after walls change. Goal is the cached escape_wall_target_cell.
	var route: Dictionary = _spawner_routes.get(spawner_cell, {}) as Dictionary
	var target_cell: Vector2i = route.get("escape_wall_target_cell", INVALID_CELL) as Vector2i
	if target_cell == INVALID_CELL:
		return
	var escape_group: int = int(route.get("escape_group", -1))
	if escape_group <= IDLE_GROUP:
		return
	var escape_world: Vector2 = _cell_center(target_cell)
	flow.call("assign_flow_to_group", escape_group, escape_world)
	route["escape_world"] = escape_world
	_spawner_routes[spawner_cell] = route

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
	var entry_cell: Vector2i = route.get("plant_zone_entry_cell", INVALID_CELL) as Vector2i
	if entry_cell == INVALID_CELL:
		_log_spawn_failure("spawner %s has no plant zone entry cell" % spawner_cell)
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
		if agent.has_method("start_flow_in"):
			agent.call("start_flow_in")
		if agent_manager.has_method("set_agent_never_rest"):
			agent_manager.call("set_agent_never_rest", nav_id, true)
		_log("spawned monster nav_id=%d spawn_cell=%s entry=%s spawner=%s" % [
			nav_id, spawn_cell, entry_cell, spawner_cell
		])

	return true

# Phase 1 -> 2: agent reached its plant_zone_entry_cell via FF. Compute A* to a
# plant target, detach FF, attach path.
func _process_astar_in_arrivals() -> void:
	for node in get_tree().get_nodes_in_group("monsters"):
		if not (node is Node2D):
			continue
		var agent: Node2D = node
		var nav_id: int = int(agent.get("nav_id"))
		if _eating_agents.has(nav_id) or _escaping_agents.has(nav_id):
			continue
		if _astar_in_agents.has(nav_id) or _astar_out_agents.has(nav_id):
			continue
		if not agent.has_meta("spawner_cell"):
			continue
		var spawner_cell: Vector2i = agent.get_meta("spawner_cell") as Vector2i
		var route: Dictionary = _spawner_routes.get(spawner_cell, {}) as Dictionary
		var entry_cell: Vector2i = route.get("plant_zone_entry_cell", INVALID_CELL) as Vector2i
		if entry_cell == INVALID_CELL:
			continue
		if not _agent_reached_cell(agent, entry_cell):
			continue
		_start_astar_in(agent, spawner_cell)

func _start_astar_in(agent: Node2D, spawner_cell: Vector2i) -> void:
	var nav_id: int = int(agent.get("nav_id"))
	var agent_cell: Vector2i = floorz.local_to_map(floorz.to_local(agent.global_position))
	var target_plant_cell: Vector2i = _resolve_plant_target_for_agent(agent_cell)
	if target_plant_cell == INVALID_CELL:
		# No reachable plant in the zone; let panic-escape path take over later.
		return
	var path_cells: PackedVector2Array = _find_path_in_zone(agent_cell, target_plant_cell)
	if path_cells.is_empty():
		return
	if agent_manager and agent_manager.has_method("detach_agent_flow"):
		agent_manager.call("detach_agent_flow", nav_id)
	var path_world: PackedVector2Array = _path_cells_to_world(path_cells)
	if agent_manager and agent_manager.has_method("assign_agent_path"):
		agent_manager.call("assign_agent_path", nav_id, path_world)
	_astar_in_agents[nav_id] = {
		"node": agent,
		"plant_cell": target_plant_cell,
		"spawner_cell": spawner_cell
	}
	if agent.has_method("start_astar_in"):
		agent.call("start_astar_in")

# Phase 2 -> 3: astar_in path complete. Verify plant still exists; consume it.
func _process_plant_arrivals() -> void:
	var finished: Array[int] = []
	for raw_nav_id in _astar_in_agents.keys():
		var nav_id: int = int(raw_nav_id)
		var data: Dictionary = _astar_in_agents[nav_id] as Dictionary
		var raw_agent: Variant = data.get("node", null)
		if not is_instance_valid(raw_agent):
			finished.append(nav_id)
			continue
		var agent: Node2D = raw_agent as Node2D
		if agent == null:
			finished.append(nav_id)
			continue
		if not (agent_manager and agent_manager.has_method("agent_path_arrived")):
			continue
		if not bool(agent_manager.call("agent_path_arrived", nav_id)):
			continue
		finished.append(nav_id)
		var plant_cell: Vector2i = data.get("plant_cell", INVALID_CELL) as Vector2i
		var spawner_cell: Vector2i = data.get("spawner_cell", INVALID_CELL) as Vector2i
		if agent.has_method("stop_astar_in"):
			agent.call("stop_astar_in")
		if plant_cell == INVALID_CELL:
			continue
		if plant_manager and plant_manager.has_method("has_plant") and not bool(plant_manager.call("has_plant", plant_cell)):
			# Plant disappeared while in transit; try to start astar_out toward exit.
			_start_astar_out(agent, spawner_cell)
			continue
		_consume_plant(agent, spawner_cell, plant_cell)
	for nav_id in finished:
		_astar_in_agents.erase(nav_id)

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
		var raw_agent: Variant = data.get("node", null)
		if is_instance_valid(raw_agent):
			var agent: Node2D = raw_agent as Node2D
			if agent == null:
				continue
			if agent.has_method("stop_eating"):
				agent.call("stop_eating")
			var spawner_cell: Vector2i = INVALID_CELL
			if agent.has_meta("spawner_cell"):
				spawner_cell = agent.get_meta("spawner_cell") as Vector2i
			_start_astar_out(agent, spawner_cell)

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

func _start_astar_out(agent: Node2D, spawner_cell: Vector2i) -> void:
	if not is_instance_valid(agent):
		return
	if spawner_cell == INVALID_CELL or not _spawner_routes.has(spawner_cell):
		var from_cell: Vector2i = floorz.local_to_map(floorz.to_local(agent.global_position))
		spawner_cell = _nearest_spawner_cell(from_cell)
	if spawner_cell == INVALID_CELL or not _spawner_routes.has(spawner_cell):
		return
	var route: Dictionary = _spawner_routes[spawner_cell] as Dictionary
	var exit_cell: Vector2i = route.get("plant_zone_exit_cell", INVALID_CELL) as Vector2i
	if exit_cell == INVALID_CELL:
		_assign_agent_to_escape(agent)
		return
	var agent_cell: Vector2i = floorz.local_to_map(floorz.to_local(agent.global_position))
	var path_cells: PackedVector2Array = _find_path_in_zone(agent_cell, exit_cell)
	if path_cells.is_empty():
		_assign_agent_to_escape(agent)
		return
	var nav_id: int = int(agent.get("nav_id"))
	if agent_manager and agent_manager.has_method("detach_agent_flow"):
		agent_manager.call("detach_agent_flow", nav_id)
	var path_world: PackedVector2Array = _path_cells_to_world(path_cells)
	if agent_manager and agent_manager.has_method("assign_agent_path"):
		agent_manager.call("assign_agent_path", nav_id, path_world)
	_astar_out_agents[nav_id] = {
		"node": agent,
		"spawner_cell": spawner_cell,
		"exit_cell": exit_cell
	}
	if agent.has_method("start_astar_out"):
		agent.call("start_astar_out")

func _process_astar_out_arrivals() -> void:
	var finished: Array[int] = []
	for raw_nav_id in _astar_out_agents.keys():
		var nav_id: int = int(raw_nav_id)
		var data: Dictionary = _astar_out_agents[nav_id] as Dictionary
		var raw_agent: Variant = data.get("node", null)
		if not is_instance_valid(raw_agent):
			finished.append(nav_id)
			continue
		var agent: Node2D = raw_agent as Node2D
		if agent == null:
			finished.append(nav_id)
			continue
		if not (agent_manager and agent_manager.has_method("agent_path_arrived")):
			continue
		if not bool(agent_manager.call("agent_path_arrived", nav_id)):
			continue
		finished.append(nav_id)
		if agent.has_method("stop_astar_out"):
			agent.call("stop_astar_out")
		_assign_agent_to_escape(agent)
	for nav_id in finished:
		_astar_out_agents.erase(nav_id)

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
	var nav_id: int = int(agent.get("nav_id"))
	# Ensure path-follow is cleared before switching to FF group.
	if agent_manager.has_method("detach_agent_path"):
		agent_manager.call("detach_agent_path", nav_id)
	agent_manager.call("assign_agent", agent, escape_group)
	_erase_eating_agent(nav_id)
	if agent_manager.has_method("set_agent_never_rest"):
		agent_manager.call("set_agent_never_rest", nav_id, true)
	agent.set_meta("spawner_cell", spawner_cell)
	var escape_target_cell: Vector2i = route.get("escape_wall_target_cell", spawner_cell) as Vector2i
	_escaping_agents[nav_id] = {
		"node": agent,
		"target_cell": escape_target_cell,
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
		var raw_agent: Variant = data.get("node", null)
		if not is_instance_valid(raw_agent):
			arrived.append(nav_id)
			continue
		var agent: Node2D = raw_agent as Node2D
		if agent == null:
			arrived.append(nav_id)
			continue
		var target_cell: Vector2i = data.get("target_cell", INVALID_CELL) as Vector2i
		if target_cell != INVALID_CELL and _agent_within_tiles(agent, target_cell, 1):
			_remove_escaped_monster(agent)
			arrived.append(nav_id)

	for nav_id in arrived:
		_escaping_agents.erase(nav_id)
		_erase_eating_agent(nav_id)

func _remove_escaped_monster(agent: Node2D) -> void:
	var nav_id: int = int(agent.get("nav_id"))
	if agent_manager and agent_manager.has_method("unregister_agent"):
		agent_manager.call("unregister_agent", nav_id)
	if agent.has_method("stop_escape"):
		agent.call("stop_escape")
	agent.remove_from_group("monsters")
	agent.queue_free()

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

# ---------------------------------------------------------------------------
# Plant zone (computed ONCE at start; never rebuilt).
# ---------------------------------------------------------------------------
func _build_plant_zone() -> void:
	if _plant_zone_built:
		return
	_plant_zone_tiles.clear()
	_plant_zone_margin_tiles.clear()

	if not plantz:
		_plant_zone_built = true
		return

	# Seed = used cells on plantz.
	var seed: Dictionary = {}
	for raw_cell in plantz.get_used_cells():
		var c: Vector2i = raw_cell
		seed[c] = true

	# Dilate by PLANT_ZONE_MARGIN (Chebyshev), exclude wall tiles.
	var dilated: Dictionary = {}
	for raw_cell in seed.keys():
		var c: Vector2i = raw_cell
		for dy in range(-PLANT_ZONE_MARGIN, PLANT_ZONE_MARGIN + 1):
			for dx in range(-PLANT_ZONE_MARGIN, PLANT_ZONE_MARGIN + 1):
				var n: Vector2i = c + Vector2i(dx, dy)
				if _has_wall(n):
					continue
				dilated[n] = true

	# zone_tiles = (seed ∪ dilated) − walls.
	for raw_cell in seed.keys():
		var c: Vector2i = raw_cell
		if _has_wall(c):
			continue
		_plant_zone_tiles[c] = true
	for raw_cell in dilated.keys():
		var c: Vector2i = raw_cell
		_plant_zone_tiles[c] = true

	# margin_tiles = dilated − seed (entry/exit candidates).
	for raw_cell in dilated.keys():
		var c: Vector2i = raw_cell
		if seed.has(c):
			continue
		_plant_zone_margin_tiles[c] = true

	# Push to native pathfinder.
	if pathfinder:
		var zone_arr: PackedVector2Array = PackedVector2Array()
		zone_arr.resize(_plant_zone_tiles.size())
		var i: int = 0
		for raw_cell in _plant_zone_tiles.keys():
			var c: Vector2i = raw_cell
			zone_arr[i] = Vector2(float(c.x), float(c.y))
			i += 1
		if pathfinder.has_method("set_walkable_tiles"):
			pathfinder.call("set_walkable_tiles", zone_arr)
		if pathfinder.has_method("set_blockers"):
			pathfinder.call("set_blockers", _wall_blockers_for_zone_bounds())

	_plant_zone_built = true
	if _zone_overlay:
		_zone_overlay.queue_redraw()
	_log("plant zone built: zone_tiles=%d margin_tiles=%d" % [_plant_zone_tiles.size(), _plant_zone_margin_tiles.size()])

func get_plant_zone_tiles() -> Array:
	return _plant_zone_tiles.keys()

func get_plant_zone_margin_tiles() -> Array:
	return _plant_zone_margin_tiles.keys()

func get_floorz() -> TileMapLayer:
	return floorz

func _wall_blockers_for_zone_bounds() -> PackedVector2Array:
	var blockers: PackedVector2Array = PackedVector2Array()
	if not wallz or _plant_zone_tiles.is_empty():
		return blockers

	var min_cell: Vector2i = INVALID_CELL
	var max_cell: Vector2i = Vector2i(-2147483648, -2147483648)
	for raw_cell in _plant_zone_tiles.keys():
		var c: Vector2i = raw_cell
		if min_cell == INVALID_CELL:
			min_cell = c
			max_cell = c
		else:
			min_cell.x = mini(min_cell.x, c.x)
			min_cell.y = mini(min_cell.y, c.y)
			max_cell.x = maxi(max_cell.x, c.x)
			max_cell.y = maxi(max_cell.y, c.y)

	for raw_cell in wallz.get_used_cells():
		var c: Vector2i = raw_cell
		if c.x < min_cell.x or c.x > max_cell.x or c.y < min_cell.y or c.y > max_cell.y:
			continue
		blockers.append(Vector2(float(c.x), float(c.y)))
	return blockers

# ---------------------------------------------------------------------------
# Exit-wall & adjacency helpers.
# ---------------------------------------------------------------------------
func _nearest_exit_wall_for_spawner(spawner_cell: Vector2i) -> Vector2i:
	if not wallz:
		return INVALID_CELL
	var best_cell: Vector2i = INVALID_CELL
	var best_dist: int = 2147483647
	for raw_cell in wallz.get_used_cells():
		var c: Vector2i = raw_cell
		if wallz.get_cell_atlas_coords(c) != EXIT_WALL_ATLAS:
			continue
		var d: Vector2i = c - spawner_cell
		var manhattan: int = abs(d.x) + abs(d.y)
		if manhattan < best_dist:
			best_dist = manhattan
			best_cell = c
	return best_cell

func _nearest_walkable_adjacent(cell: Vector2i) -> Vector2i:
	var best_cell: Vector2i = INVALID_CELL
	var best_dist: int = 2147483647
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			var n: Vector2i = cell + Vector2i(dx, dy)
			if not _is_walkable(n):
				continue
			var manhattan: int = abs(dx) + abs(dy)
			if manhattan < best_dist:
				best_dist = manhattan
				best_cell = n
	return best_cell

func _nearest_margin_tile(from_cell: Vector2i) -> Vector2i:
	var best_cell: Vector2i = INVALID_CELL
	var best_dist: int = 2147483647
	for raw_cell in _plant_zone_margin_tiles.keys():
		var c: Vector2i = raw_cell
		var d: Vector2i = c - from_cell
		var manhattan: int = abs(d.x) + abs(d.y)
		if manhattan < best_dist:
			best_dist = manhattan
			best_cell = c
	return best_cell

# ---------------------------------------------------------------------------
# A* glue: find a path inside the plant zone via PathfinderNative.
# ---------------------------------------------------------------------------
func _find_path_in_zone(from_tile: Vector2i, to_tile: Vector2i) -> PackedVector2Array:
	if pathfinder == null or not pathfinder.has_method("find_path"):
		return PackedVector2Array()
	# Snap endpoints to zone tiles if needed.
	var start_tile: Vector2i = from_tile if _plant_zone_tiles.has(from_tile) else _nearest_zone_tile_to(from_tile)
	var end_tile: Vector2i = to_tile if _plant_zone_tiles.has(to_tile) else _nearest_zone_tile_to(to_tile)
	if start_tile == INVALID_CELL or end_tile == INVALID_CELL:
		return PackedVector2Array()
	return pathfinder.call("find_path", start_tile, end_tile)

func _nearest_zone_tile_to(cell: Vector2i) -> Vector2i:
	var best_cell: Vector2i = INVALID_CELL
	var best_dist: int = 2147483647
	for raw_cell in _plant_zone_tiles.keys():
		var c: Vector2i = raw_cell
		var d: Vector2i = c - cell
		var manhattan: int = abs(d.x) + abs(d.y)
		if manhattan < best_dist:
			best_dist = manhattan
			best_cell = c
	return best_cell

func _path_cells_to_world(path_cells: PackedVector2Array) -> PackedVector2Array:
	var out: PackedVector2Array = PackedVector2Array()
	out.resize(path_cells.size())
	for i in range(path_cells.size()):
		var v: Vector2 = path_cells[i]
		out[i] = _cell_center(Vector2i(int(v.x), int(v.y)))
	return out

func _resolve_plant_target_for_agent(from_cell: Vector2i) -> Vector2i:
	# Nearest plant cell to the agent's current cell, restricted to plants
	# present inside the (static) plant zone. Plants outside the zone are
	# ignored because we cannot A* to them.
	if plant_manager == null or not plant_manager.has_method("get_plant_cells"):
		return INVALID_CELL
	var best_cell: Vector2i = INVALID_CELL
	var best_dist: int = 2147483647
	for raw_cell in plant_manager.call("get_plant_cells"):
		var c: Vector2i = raw_cell
		if not _plant_zone_tiles.has(c):
			continue
		var d: Vector2i = c - from_cell
		var manhattan: int = abs(d.x) + abs(d.y)
		if manhattan < best_dist:
			best_dist = manhattan
			best_cell = c
	return best_cell

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
