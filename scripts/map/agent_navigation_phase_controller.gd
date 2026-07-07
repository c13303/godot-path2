extends RefCounted
class_name AgentNavigationPhaseController

# Owns runtime agent movement phases:
# entry flow -> A*-in -> plant/counter/eating/payment -> escape -> despawn.

const IDLE_GROUP: int = 0
const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)
const EATING_COOLDOWN: float = 5.0
const EARLY_COUNTER_FETCH_TILE_FACTOR: float = 1.25
const SPAWNER_KIND_CLIENT: StringName = &"client"

var _manager: BuildingManager
# Manager-owned services that are created once and never reassigned.
# Cached explicitly at setup so the dependency is visible instead of being
# fetched by string name on every access.
var _garden_topology: GardenTopologyService = null
var _spawner_route_service: SpawnerRouteService = null
var _building_path_service: BuildingPathService = null
var _garden_retarget: GardenRetargetController = null
var _debug_telemetry: BuildingDebugTelemetry = null
var _eating_agents: Dictionary = {}
var _escaping_agents: Dictionary = {}
var _entry_path_agents: Dictionary = {}
var _astar_in_agents: Dictionary = {}
var _client_counter_agents: Dictionary = {}


func setup(manager: BuildingManager) -> void:
	_manager = manager
	_garden_topology = manager._garden_topology as GardenTopologyService
	_spawner_route_service = manager._spawner_route_service
	_building_path_service = manager._building_path_service
	_garden_retarget = manager._garden_retarget
	_debug_telemetry = manager._debug_telemetry


func eating_agents() -> Dictionary:
	return _eating_agents


func escaping_agents() -> Dictionary:
	return _escaping_agents


func entry_path_agents() -> Dictionary:
	return _entry_path_agents


func astar_in_agents() -> Dictionary:
	return _astar_in_agents


func client_counter_agents() -> Dictionary:
	return _client_counter_agents


func eating_count() -> int:
	return _eating_agents.size()


func escaping_count() -> int:
	return _escaping_agents.size()


func entry_path_count() -> int:
	return _entry_path_agents.size()


func astar_in_count() -> int:
	return _astar_in_agents.size()


func client_counter_count() -> int:
	return _client_counter_agents.size()


func process_astar_in_arrivals() -> void:
	var finished: Array[int] = []
	var entry_ids: Array = _entry_path_agents.keys()
	for raw_nav_id: Variant in entry_ids:
		var nav_id: int = int(raw_nav_id)
		if not _entry_path_agents.has(nav_id):
			continue
		var data: Dictionary = _entry_path_agents[nav_id] as Dictionary
		var raw_agent: Variant = data.get("node", null)
		if not is_instance_valid(raw_agent):
			finished.append(nav_id)
			continue
		var agent: Node2D = raw_agent as Node2D
		if agent == null:
			finished.append(nav_id)
			continue
		if _eating_agents.has(nav_id) or _escaping_agents.has(nav_id):
			finished.append(nav_id)
			continue
		if _astar_in_agents.has(nav_id):
			continue
		if try_client_early_counter_fetch(agent):
			continue
		var entry_cell: Vector2i = data.get("entry_cell", INVALID_CELL) as Vector2i
		if entry_cell == INVALID_CELL:
			finished.append(nav_id)
			continue
		if not _manager._agent_reached_cell(agent, entry_cell):
			continue
		var spawner_cell: Vector2i = data.get("spawner_cell", INVALID_CELL) as Vector2i
		var garden_id: int = int(data.get("garden_id", 0))
		if not _garden_topology.garden_has_target_for_kind(garden_id, _agent_kind(agent)):
			_entry_path_agents.erase(nav_id)
			_garden_retarget.retarget_agent_or_escape(agent, spawner_cell)
			continue
		_entry_path_agents.erase(nav_id)
		start_astar_in(agent, spawner_cell)
	for nav_id: int in finished:
		_entry_path_agents.erase(nav_id)
	_garden_topology.drain_pending_empty_gardens()


func start_astar_in(agent: Node2D, spawner_cell: Vector2i) -> void:
	var nav_id: int = int(agent.get("nav_id"))
	var floorz: TileMapLayer = _floorz()
	var agent_cell: Vector2i = floorz.local_to_map(floorz.to_local(agent.global_position))
	var garden_id: int = int(agent.get_meta("garden_id")) if agent.has_meta("garden_id") else 0
	var agent_kind: StringName = _agent_kind(agent)
	if not _garden_topology.garden_has_target_for_kind(garden_id, agent_kind):
		_garden_retarget.retarget_agent_or_escape(agent, spawner_cell)
		return
	var target_plant_cell: Vector2i = _garden_topology.resolve_plant_target_for_agent_in_garden(agent_cell, garden_id, agent_kind)
	if target_plant_cell == INVALID_CELL:
		_garden_retarget.retarget_agent_or_escape(agent, spawner_cell)
		return
	var path_cells: PackedVector2Array = _building_path_service.find_path_in_zone(agent_cell, target_plant_cell, garden_id)
	if path_cells.is_empty():
		_garden_retarget.retarget_agent_or_escape(agent, spawner_cell)
		return
	var agent_manager: Node = _agent_manager()
	if agent_manager and agent_manager.has_method("detach_agent_flow"):
		agent_manager.call("detach_agent_flow", nav_id)
	var path_world: PackedVector2Array = _building_path_service.path_cells_to_world(path_cells, nav_id, true)
	if agent_manager and agent_manager.has_method("assign_agent_path"):
		agent_manager.call("assign_agent_path", nav_id, path_world)
	_entry_path_agents.erase(nav_id)
	set_astar_in_agent(nav_id, {
		"node": agent,
		"plant_cell": target_plant_cell,
		"spawner_cell": spawner_cell,
		"garden_id": garden_id,
		"path_world": path_world
	})
	if agent.has_method("start_astar_in"):
		agent.call("start_astar_in")


func process_plant_arrivals() -> void:
	var finished: Array[int] = []
	var astar_ids: Array = _astar_in_agents.keys()
	for raw_nav_id: Variant in astar_ids:
		var nav_id: int = int(raw_nav_id)
		if not _astar_in_agents.has(nav_id):
			continue
		var data: Dictionary = _astar_in_agents[nav_id] as Dictionary
		var raw_agent: Variant = data.get("node", null)
		if not is_instance_valid(raw_agent):
			finished.append(nav_id)
			continue
		var agent: Node2D = raw_agent as Node2D
		if agent == null:
			finished.append(nav_id)
			continue
		var agent_manager: Node = _agent_manager()
		if not (agent_manager and agent_manager.has_method("agent_path_arrived")):
			continue
		if try_client_early_counter_fetch(agent):
			continue
		if not bool(agent_manager.call("agent_path_arrived", nav_id)):
			continue
		var plant_cell: Vector2i = data.get("plant_cell", INVALID_CELL) as Vector2i
		var spawner_cell: Vector2i = data.get("spawner_cell", INVALID_CELL) as Vector2i
		if agent.has_method("stop_astar_in"):
			agent.call("stop_astar_in")
		if plant_cell == INVALID_CELL:
			finished.append(nav_id)
			continue
		var counter_access_cells: Dictionary = _counter_access_cells()
		if counter_access_cells.has(plant_cell):
			erase_astar_in_agent(nav_id)
			var counter_cell: Vector2i = counter_access_cells[plant_cell] as Vector2i
			if _counter_stock(counter_cell) <= 0:
				_garden_retarget.retarget_agent_or_escape(agent, spawner_cell)
			elif _agent_kind(agent) == SPAWNER_KIND_CLIENT:
				start_client_counter_payment(agent, counter_cell)
			else:
				_manager._consume_counter_rose(agent, spawner_cell, plant_cell)
			continue
		var plant_manager: Node = _plant_manager()
		if plant_manager and plant_manager.has_method("has_plant") and not bool(plant_manager.call("has_plant", plant_cell)):
			erase_astar_in_agent(nav_id)
			_garden_retarget.retarget_agent_or_escape(agent, spawner_cell)
			continue
		erase_astar_in_agent(nav_id)
		consume_plant(agent, spawner_cell, plant_cell)
	for nav_id: int in finished:
		erase_astar_in_agent(nav_id)


func set_astar_in_agent(nav_id: int, data: Dictionary) -> void:
	_astar_in_agents[nav_id] = data
	var target_cell: Vector2i = data.get("plant_cell", INVALID_CELL) as Vector2i
	_garden_retarget.register_astar_in_target(nav_id, target_cell)


func erase_astar_in_agent(nav_id: int) -> void:
	_astar_in_agents.erase(nav_id)
	_garden_retarget.unregister_astar_in_target(nav_id)


func consume_plant(eater: Node2D, _spawner_cell: Vector2i, plant_cell: Vector2i) -> void:
	var consume_us: int = Time.get_ticks_usec()
	if _agent_kind(eater) == SPAWNER_KIND_CLIENT:
		start_client_payment(eater, plant_cell)
		_debug_telemetry.warn_garden_task_lag_us("_consume_plant", Time.get_ticks_usec() - consume_us,
			"client plant=%s" % str(plant_cell))
		return
	start_agent_eating(eater, _manager._eating_time, plant_cell)
	Sfx.play_sound(&"crunsh")
	var plant_manager: Node = _plant_manager()
	if plant_manager and plant_manager.has_method("consume_plant"):
		var remove_us: int = Time.get_ticks_usec()
		plant_manager.call("consume_plant", plant_cell)
		_debug_telemetry.warn_garden_task_lag_us("_consume_plant.remove_plant", Time.get_ticks_usec() - remove_us,
			"plant=%s" % str(plant_cell))
	else:
		var plantz: TileMapLayer = _plantz()
		if plantz:
			var source_id: int = plantz.get_cell_source_id(plant_cell)
			var alternative_tile: int = plantz.get_cell_alternative_tile(plant_cell)
			plantz.set_cell(plant_cell, source_id, PlantManager.DEBRIS_ATLAS, alternative_tile)
			_manager._flush_plant_layer_visuals()
	_debug_telemetry.warn_garden_task_lag_us("_consume_plant", Time.get_ticks_usec() - consume_us,
		"plant=%s" % str(plant_cell))


func start_client_payment(agent: Node2D, plant_cell: Vector2i) -> void:
	_manager._start_client_payment(agent, plant_cell)


func process_client_counter_arrivals() -> void:
	for raw_nav_id: Variant in _client_counter_agents.keys():
		var nav_id: int = int(raw_nav_id)
		if not _client_counter_agents.has(nav_id):
			continue
		var data: Dictionary = _client_counter_agents[nav_id] as Dictionary
		var raw_agent: Variant = data.get("node", null)
		if not is_instance_valid(raw_agent):
			_client_counter_agents.erase(nav_id)
			continue
		var agent_manager: Node = _agent_manager()
		if not (agent_manager and agent_manager.has_method("agent_path_arrived")):
			continue
		if not bool(agent_manager.call("agent_path_arrived", nav_id)):
			continue
		var agent: Node2D = raw_agent as Node2D
		if agent == null:
			_client_counter_agents.erase(nav_id)
			continue
		var counter_cell: Vector2i = data.get("counter_cell", INVALID_CELL) as Vector2i
		_client_counter_agents.erase(nav_id)
		if agent.has_method("stop_astar_in"):
			agent.call("stop_astar_in")
		if _counter_stock(counter_cell) <= 0:
			_manager._begin_client_tantrum()
			continue
		start_client_counter_payment(agent, counter_cell)


func start_client_counter_payment(agent: Node2D, counter_cell: Vector2i) -> void:
	_manager._start_client_counter_payment(agent, counter_cell)


func finish_client_purchase(agent: Node2D) -> void:
	var nav_id: int = int(agent.get("nav_id"))
	_client_counter_agents.erase(nav_id)
	assign_agent_to_escape(agent)


func try_client_early_counter_fetch(agent: Node2D) -> bool:
	if _agent_kind(agent) != SPAWNER_KIND_CLIENT:
		return false
	if _manager._total_counter_stock() <= 0:
		return false
	var floorz: TileMapLayer = _floorz()
	var agent_cell: Vector2i = floorz.local_to_map(floorz.to_local(agent.global_position))
	var target: Dictionary = _manager._select_stocked_counter_target(agent_cell)
	if target.is_empty():
		return false
	var access_cell: Vector2i = target.get("target_cell", INVALID_CELL) as Vector2i
	var counter_cell: Vector2i = target.get("counter_cell", INVALID_CELL) as Vector2i
	if access_cell == INVALID_CELL or counter_cell == INVALID_CELL:
		return false
	var tile_dimensions: Vector2 = _manager._tile_size()
	var reach: float = maxf(tile_dimensions.x, tile_dimensions.y) * EARLY_COUNTER_FETCH_TILE_FACTOR
	var access_world: Vector2 = _manager._cell_center(access_cell)
	if agent.global_position.distance_to(access_world) > reach:
		return false
	start_client_counter_payment(agent, counter_cell)
	return true


func clear_client_counter_agents() -> void:
	_client_counter_agents.clear()


func clear_agent_navigation_records(nav_id: int) -> void:
	_entry_path_agents.erase(nav_id)
	erase_astar_in_agent(nav_id)
	_escaping_agents.erase(nav_id)
	_client_counter_agents.erase(nav_id)


func process_eating_agents(delta: float) -> void:
	var finished: Array[int] = []
	var eating_ids: Array = _eating_agents.keys()
	for raw_nav_id: Variant in eating_ids:
		var nav_id: int = int(raw_nav_id)
		if not _eating_agents.has(nav_id):
			continue
		var data: Dictionary = _eating_agents[nav_id] as Dictionary
		var timer: float = float(data.get("timer", 0.0)) - delta
		data["timer"] = timer
		_eating_agents[nav_id] = data
		if timer <= 0.0:
			finished.append(nav_id)

	for nav_id: int in finished:
		var data: Dictionary = _eating_agents.get(nav_id, {}) as Dictionary
		erase_eating_agent(nav_id)
		var raw_agent: Variant = data.get("node", null)
		if is_instance_valid(raw_agent):
			var agent: Node2D = raw_agent as Node2D
			if agent == null:
				continue
			if agent.has_method("stop_eating"):
				agent.call("stop_eating")
			decide_after_eating(nav_id, agent, data)


func decide_after_eating(nav_id: int, agent: Node2D, data: Dictionary) -> void:
	if not is_instance_valid(agent):
		return
	var roses_eaten: int = int(data.get("roses_eaten", 1))
	var garden_id: int = int(data.get("garden_id", 0))
	var spawner_cell: Vector2i = data.get("spawner_cell", INVALID_CELL) as Vector2i
	if spawner_cell == INVALID_CELL and agent.has_meta("spawner_cell"):
		spawner_cell = agent.get_meta("spawner_cell") as Vector2i
	if garden_id <= 0 and agent.has_meta("garden_id"):
		garden_id = int(agent.get_meta("garden_id"))

	if roses_eaten >= _manager._number_of_roses_before_satiety:
		escape_finished_eater(nav_id, agent)
		return

	if garden_id > 0 and _garden_topology.garden_has_target_for_kind(garden_id, _agent_kind(agent)):
		agent.set_meta("garden_id", garden_id)
		if spawner_cell != INVALID_CELL:
			agent.set_meta("spawner_cell", spawner_cell)
		start_astar_in(agent, spawner_cell)
		_garden_topology.drain_pending_empty_gardens()
		return
	_garden_topology.drain_pending_empty_gardens()

	if _manager._same_garden_only:
		escape_finished_eater(nav_id, agent)
		return

	var retarget_garden_id: int = int(agent.get_meta("garden_id")) if agent.has_meta("garden_id") else garden_id
	if _garden_retarget.queue_agent_for_garden_retarget(nav_id, agent, "retarget", spawner_cell, retarget_garden_id):
		return
	escape_finished_eater(nav_id, agent)


func escape_finished_eater(nav_id: int, agent: Node2D) -> void:
	if assign_agent_to_escape(agent):
		_manager.note_eat_exit_direct_ff(true)
		return
	_manager.note_eat_exit_direct_ff(false)
	var floorz: TileMapLayer = _floorz()
	var fb_cell: Vector2i = floorz.local_to_map(floorz.to_local(agent.global_position)) if floorz else INVALID_CELL
	push_warning("direct_wallexit_ff_escape_failed nav_id=%d cell=%s" % [nav_id, fb_cell])
	var fb_spawner: Vector2i = agent.get_meta("spawner_cell") as Vector2i if agent.has_meta("spawner_cell") else INVALID_CELL
	var fb_garden: int = int(agent.get_meta("garden_id")) if agent.has_meta("garden_id") else 0
	_garden_retarget.queue_agent_for_garden_retarget(nav_id, agent, "escape", fb_spawner, fb_garden)


func erase_eating_agent(nav_id: int) -> void:
	_eating_agents.erase(nav_id)


func start_agent_eating(agent: Node2D, seconds: float, plant_cell: Vector2i = INVALID_CELL) -> void:
	var nav_id: int = int(agent.get("nav_id"))
	var garden_id: int = int(agent.get_meta("garden_id")) if agent.has_meta("garden_id") else 0
	var spawner_cell: Vector2i = agent.get_meta("spawner_cell") as Vector2i if agent.has_meta("spawner_cell") else INVALID_CELL
	var roses_eaten: int = int(agent.get_meta("roses_eaten")) if agent.has_meta("roses_eaten") else 0
	roses_eaten += 1
	agent.set_meta("roses_eaten", roses_eaten)
	_eating_agents[nav_id] = {
		"node": agent,
		"timer": seconds,
		"garden_id": garden_id,
		"spawner_cell": spawner_cell,
		"plant_cell": plant_cell,
		"roses_eaten": roses_eaten
	}
	var agent_manager: Node = _agent_manager()
	if agent_manager and agent_manager.has_method("detach_agent_flow"):
		agent_manager.call("detach_agent_flow", nav_id)
	if agent_manager and agent_manager.has_method("detach_agent_path"):
		agent_manager.call("detach_agent_path", nav_id)
	_entry_path_agents.erase(nav_id)
	erase_astar_in_agent(nav_id)
	if agent.has_method("start_eating"):
		agent.call("start_eating", seconds)


func assign_agent_to_escape(agent: Node2D) -> bool:
	var agent_manager: Node = _agent_manager()
	if not agent_manager or not agent_manager.has_method("assign_agent"):
		return false
	var linked_spawner_cell: Vector2i = INVALID_CELL
	if agent.has_meta("spawner_cell"):
		linked_spawner_cell = agent.get_meta("spawner_cell") as Vector2i
	var route_service: SpawnerRouteService = _spawner_route_service
	if linked_spawner_cell != INVALID_CELL and route_service.has_spawner_route(linked_spawner_cell):
		var linked_route: Dictionary = route_service.get_spawner_route(linked_spawner_cell)
		if bool(linked_route.get("has_bound_exit", false)) and bool(linked_route.get("escape_ready", false)):
			var linked_group: int = int(linked_route.get("escape_group", -1))
			var linked_target: Vector2i = linked_route.get("escape_wall_target_cell", linked_spawner_cell) as Vector2i
			if linked_group > IDLE_GROUP and linked_target != INVALID_CELL:
				return attach_agent_to_escape(agent, linked_group, linked_target, linked_spawner_cell)
	var exit_escape: Dictionary = route_service.nearest_reachable_exit_escape(agent.global_position)
	if not exit_escape.is_empty():
		var exit_group: int = int(exit_escape.get("escape_group", -1))
		var exit_target: Vector2i = exit_escape.get("escape_target_cell", INVALID_CELL) as Vector2i
		if exit_group > IDLE_GROUP and exit_target != INVALID_CELL:
			return attach_agent_to_escape(agent, exit_group, exit_target)

	var spawner_cell: Vector2i = INVALID_CELL
	if agent.has_meta("spawner_cell"):
		var pre_linked: Vector2i = agent.get_meta("spawner_cell") as Vector2i
		if route_service.has_spawner_route(pre_linked):
			spawner_cell = pre_linked
	if spawner_cell == INVALID_CELL:
		var floorz: TileMapLayer = _floorz()
		var from_cell: Vector2i = floorz.local_to_map(floorz.to_local(agent.global_position))
		spawner_cell = _manager._nearest_spawner_cell(from_cell)
	if spawner_cell == INVALID_CELL or not route_service.has_spawner_route(spawner_cell):
		return false
	var route: Dictionary = route_service.get_spawner_route(spawner_cell)
	if not bool(route.get("escape_ready", false)):
		return false
	var escape_group: int = int(route.get("escape_group", -1))
	if escape_group <= IDLE_GROUP:
		return false
	var escape_target_cell: Vector2i = route.get("escape_wall_target_cell", spawner_cell) as Vector2i
	return attach_agent_to_escape(agent, escape_group, escape_target_cell, spawner_cell)


func attach_agent_to_escape(agent: Node2D, escape_group: int, escape_target_cell: Vector2i, spawner_cell: Vector2i = INVALID_CELL) -> bool:
	var agent_manager: Node = _agent_manager()
	if not agent_manager or not agent_manager.has_method("assign_agent"):
		return false
	var nav_id: int = int(agent.get("nav_id"))
	if agent_manager.has_method("detach_agent_path"):
		agent_manager.call("detach_agent_path", nav_id)
	agent_manager.call("assign_agent", agent, escape_group)
	_entry_path_agents.erase(nav_id)
	erase_astar_in_agent(nav_id)
	erase_eating_agent(nav_id)
	if agent_manager.has_method("set_agent_never_rest"):
		agent_manager.call("set_agent_never_rest", nav_id, true)
	if spawner_cell != INVALID_CELL:
		agent.set_meta("spawner_cell", spawner_cell)
	_escaping_agents[nav_id] = {
		"node": agent,
		"target_cell": escape_target_cell,
		"spawner_cell": spawner_cell
	}
	if agent.has_method("stop_eating"):
		agent.call("stop_eating")
	if agent.has_method("start_escape"):
		agent.call("start_escape")
	return true


func process_escape_arrivals() -> void:
	var arrived: Array[int] = []
	var escaping_ids: Array = _escaping_agents.keys()
	for raw_nav_id: Variant in escaping_ids:
		var nav_id: int = int(raw_nav_id)
		if not _escaping_agents.has(nav_id):
			continue
		var data: Dictionary = _escaping_agents[nav_id] as Dictionary
		var raw_agent: Variant = data.get("node", null)
		if not is_instance_valid(raw_agent):
			arrived.append(nav_id)
			continue
		var agent: Node2D = raw_agent as Node2D
		if agent == null:
			arrived.append(nav_id)
			continue
		if _manager._is_seed_merchant_paused_agent(agent):
			continue
		var target_cell: Vector2i = data.get("target_cell", INVALID_CELL) as Vector2i
		if target_cell != INVALID_CELL and _manager._agent_within_tiles(agent, target_cell, 1):
			_manager._remove_escaped_monster(agent)
			arrived.append(nav_id)

	for nav_id: int in arrived:
		_escaping_agents.erase(nav_id)
		erase_eating_agent(nav_id)


func assign_agent_to_garden_entry_flow(agent: Node2D, spawner_cell: Vector2i, garden_id: int, entry_cell: Vector2i) -> bool:
	if not is_instance_valid(agent):
		return false
	if entry_cell == INVALID_CELL or not _manager._is_sane_cell(entry_cell):
		return false
	var agent_manager: Node = _agent_manager()
	if agent_manager == null or not agent_manager.has_method("assign_agent"):
		return false
	var nav_id: int = int(agent.get("nav_id"))
	var route: Dictionary = _spawner_route_service.get_or_create_spawner_garden_route(spawner_cell, garden_id)
	if not bool(route.get("ready", false)):
		return false
	var plant_group: int = int(route.get("plant_group", -1))
	if plant_group <= IDLE_GROUP:
		return false
	if agent_manager.has_method("detach_agent_flow"):
		agent_manager.call("detach_agent_flow", nav_id)
	if agent_manager.has_method("detach_agent_path"):
		agent_manager.call("detach_agent_path", nav_id)
	agent_manager.call("assign_agent", agent, plant_group)
	_entry_path_agents[nav_id] = {
		"node": agent,
		"spawner_cell": spawner_cell,
		"garden_id": garden_id,
		"entry_cell": entry_cell,
		"plant_group": plant_group
	}
	erase_astar_in_agent(nav_id)
	_escaping_agents.erase(nav_id)
	agent.set_meta("spawner_cell", spawner_cell)
	agent.set_meta("garden_id", garden_id)
	agent.set_meta("garden_entry_cell", entry_cell)
	if agent.has_method("start_flow_in"):
		agent.call("start_flow_in")
	return true


func _counter_stock(counter_cell: Vector2i) -> int:
	return _manager._counter_stock(counter_cell)


func _agent_kind(agent: Node2D) -> StringName:
	return _manager._agent_kind(agent)


func _agent_manager() -> Node:
	return _manager.agent_manager


func _plant_manager() -> Node:
	return _manager.plant_manager


func _floorz() -> TileMapLayer:
	return _manager.floorz


func _plantz() -> TileMapLayer:
	return _manager.plantz


func _counter_access_cells() -> Dictionary:
	return _garden_topology.counter_access_cells()
