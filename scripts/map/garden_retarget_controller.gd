extends RefCounted
class_name GardenRetargetController

# Owns runtime garden reassignment: stale target detection, waiting-agent queueing,
# plant-target reverse indexing, local retarget search, and retarget profiling.

const IDLE_GROUP: int = 0
const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)
const SPAWNER_KIND_MONSTER: StringName = &"monster"
const SPAWNER_KIND_CLIENT: StringName = &"client"
const _GARDEN_RETARGET_MAX_RETRIES: int = 30

var _manager: BuildingManager
var _garden_topology: GardenTopologyService = null
var _spawner_route_service: SpawnerRouteService = null
var _building_path_service: BuildingPathService = null
var _debug_telemetry_service: BuildingDebugTelemetry = null
var _agent_navigation_phases: AgentNavigationPhaseController = null
var _astar_in_agents_by_target_plant: Dictionary = {}
var _astar_in_target_by_nav_id: Dictionary = {}
var _debug_check_retarget_index: bool = false
var _last_plant_retarget_astar_in: int = 0
var _last_plant_retarget_bucket: int = 0
var _last_plant_retarget_affected: int = 0
var _last_plant_retarget_queued: int = 0
var _last_plant_retarget_stale: int = 0
var _last_plant_retarget_already_queued: int = 0
var _garden_retarget_queue: Array[Dictionary] = []
var _garden_retarget_queued: Dictionary = {}
var _last_retarget_profile: Dictionary = {}
var _last_local_retarget_profile: Dictionary = {}
var _last_find_local_retarget_profile: Dictionary = {}
var _find_path_in_zone_accum: Dictionary = {}


func setup(manager: BuildingManager) -> void:
	_manager = manager
	_garden_topology = manager.get_garden_topology_service()
	_spawner_route_service = manager.get_spawner_route_service()
	_building_path_service = manager.get_building_path_service()
	_debug_telemetry_service = manager.get_building_debug_telemetry()
	_agent_navigation_phases = manager.get_agent_navigation_phase_controller()


func queue_size() -> int:
	return _garden_retarget_queue.size()


func target_index_size() -> int:
	return _astar_in_agents_by_target_plant.size()


func set_debug_check_retarget_index(value: bool) -> void:
	_debug_check_retarget_index = value


func last_plant_retarget_astar_in() -> int:
	return _last_plant_retarget_astar_in


func last_plant_retarget_bucket() -> int:
	return _last_plant_retarget_bucket


func last_plant_retarget_affected() -> int:
	return _last_plant_retarget_affected


func last_plant_retarget_queued() -> int:
	return _last_plant_retarget_queued


func last_plant_retarget_stale() -> int:
	return _last_plant_retarget_stale


func last_plant_retarget_already_queued() -> int:
	return _last_plant_retarget_already_queued


func register_astar_in_target(nav_id: int, target_cell: Vector2i) -> void:
	unregister_astar_in_target(nav_id)
	if target_cell == INVALID_CELL:
		return
	_astar_in_target_by_nav_id[nav_id] = target_cell
	if not _astar_in_agents_by_target_plant.has(target_cell):
		_astar_in_agents_by_target_plant[target_cell] = {}
	var bucket: Dictionary = _astar_in_agents_by_target_plant[target_cell] as Dictionary
	bucket[nav_id] = true


func unregister_astar_in_target(nav_id: int) -> void:
	if not _astar_in_target_by_nav_id.has(nav_id):
		return
	var target_cell: Vector2i = _astar_in_target_by_nav_id[nav_id] as Vector2i
	_astar_in_target_by_nav_id.erase(nav_id)
	if not _astar_in_agents_by_target_plant.has(target_cell):
		return
	var bucket: Dictionary = _astar_in_agents_by_target_plant[target_cell] as Dictionary
	bucket.erase(nav_id)
	if bucket.is_empty():
		_astar_in_agents_by_target_plant.erase(target_cell)


func remove_queued_agent(nav_id: int) -> void:
	_garden_retarget_queued.erase(nav_id)
	for index: int in range(_garden_retarget_queue.size() - 1, -1, -1):
		var item: Dictionary = _garden_retarget_queue[index]
		if int(item.get("nav_id", -1)) == nav_id:
			_garden_retarget_queue.remove_at(index)


func retarget_agents_targeting_removed_plant_only(cell: Vector2i, garden_id: int) -> void:
	_last_plant_retarget_astar_in = _astar_in_agents().size()
	_last_plant_retarget_bucket = 0
	_last_plant_retarget_affected = 0
	_last_plant_retarget_queued = 0
	_last_plant_retarget_stale = 0
	_last_plant_retarget_already_queued = 0
	if garden_id > 0:
		_garden_topology.garden_has_edible_plants(garden_id)
	if _astar_in_agents_by_target_plant.has(cell):
		var bucket: Dictionary = _astar_in_agents_by_target_plant[cell] as Dictionary
		var nav_ids: Array = bucket.keys()
		_last_plant_retarget_bucket = nav_ids.size()
		for raw_nav_id in nav_ids:
			var nav_id: int = int(raw_nav_id)
			if not _astar_in_agents().has(nav_id):
				unregister_astar_in_target(nav_id)
				_last_plant_retarget_stale += 1
				continue
			if (_astar_in_target_by_nav_id.get(nav_id, INVALID_CELL) as Vector2i) != cell:
				bucket.erase(nav_id)
				if bucket.is_empty():
					_astar_in_agents_by_target_plant.erase(cell)
				_last_plant_retarget_stale += 1
				continue
			var data: Dictionary = _astar_in_agents()[nav_id] as Dictionary
			var plant_cell: Vector2i = data.get("plant_cell", INVALID_CELL) as Vector2i
			if plant_cell != cell:
				register_astar_in_target(nav_id, plant_cell)
				_last_plant_retarget_stale += 1
				continue
			var raw_agent: Variant = data.get("node", null)
			if not is_instance_valid(raw_agent):
				_agent_navigation_phases.erase_astar_in_agent(nav_id)
				_last_plant_retarget_stale += 1
				continue
			var agent: Node2D = raw_agent as Node2D
			if agent == null:
				_agent_navigation_phases.erase_astar_in_agent(nav_id)
				_last_plant_retarget_stale += 1
				continue
			_last_plant_retarget_affected += 1
			var spawner_cell: Vector2i = data.get("spawner_cell", INVALID_CELL) as Vector2i
			_manager.detach_agent_path(nav_id)
			_agent_navigation_phases.erase_astar_in_agent(nav_id)
			if agent.has_method("stop_astar_in"):
				agent.call("stop_astar_in")
			if spawner_cell == INVALID_CELL and agent.has_meta("spawner_cell"):
				spawner_cell = agent.get_meta("spawner_cell") as Vector2i
			if queue_agent_for_garden_retarget(nav_id, agent, "retarget", spawner_cell, garden_id):
				_last_plant_retarget_queued += 1
			else:
				_last_plant_retarget_already_queued += 1
	if _debug_check_retarget_index:
		_assert_retarget_index_matches_scan(cell)
	_garden_topology.drain_pending_empty_gardens()


func queue_agents_after_garden_rebuild() -> void:
	for node in _manager.get_tree().get_nodes_in_group("monsters"):
		if not (node is Node2D):
			continue
		var agent: Node2D = node
		var nav_id: int = int(agent.get("nav_id"))
		if nav_id < 0:
			continue
		if _garden_retarget_queued.has(nav_id):
			continue
		var garden_id: int = _agent_referenced_garden_id(nav_id, agent)
		if not _garden_assignment_is_stale(garden_id):
			continue
		var intent: String = "retarget"
		if _eating_agents().has(nav_id):
			intent = "escape"
		var spawner_cell: Vector2i = INVALID_CELL
		if agent.has_meta("spawner_cell"):
			spawner_cell = agent.get_meta("spawner_cell") as Vector2i
		queue_agent_for_garden_retarget(nav_id, agent, intent, spawner_cell, garden_id)
	_garden_topology.drain_pending_empty_gardens()


func handle_garden_became_empty(garden_id: int) -> void:
	if garden_id <= 0:
		return
	for raw_nav_id in _entry_path_agents().keys():
		var nav_id: int = int(raw_nav_id)
		if not _entry_path_agents().has(nav_id):
			continue
		if int((_entry_path_agents()[nav_id] as Dictionary).get("garden_id", 0)) != garden_id:
			continue
		_queue_affected_empty_garden_agent(nav_id, "retarget", garden_id)
	for raw_nav_id in _astar_in_agents().keys():
		var nav_id: int = int(raw_nav_id)
		if not _astar_in_agents().has(nav_id):
			continue
		if int((_astar_in_agents()[nav_id] as Dictionary).get("garden_id", 0)) != garden_id:
			continue
		_queue_affected_empty_garden_agent(nav_id, "retarget", garden_id)
	for node in _manager.get_tree().get_nodes_in_group("monsters"):
		if not (node is Node2D):
			continue
		var agent: Node2D = node
		var nav_id: int = int(agent.get("nav_id"))
		if nav_id < 0 or _garden_retarget_queued.has(nav_id):
			continue
		if _eating_agents().has(nav_id):
			continue
		if not agent.has_meta("garden_id"):
			continue
		if int(agent.get_meta("garden_id")) != garden_id:
			continue
		var spawner_cell: Vector2i = INVALID_CELL
		if agent.has_meta("spawner_cell"):
			spawner_cell = agent.get_meta("spawner_cell") as Vector2i
		queue_agent_for_garden_retarget(nav_id, agent, "retarget", spawner_cell, garden_id)
	_garden_topology.mark_garden_empty(garden_id)


func queue_escape_for_all_monsters_budgeted() -> void:
	for node in _manager.get_tree().get_nodes_in_group("monsters"):
		if not (node is Node2D):
			continue
		var agent: Node2D = node
		var nav_id: int = int(agent.get("nav_id"))
		if nav_id < 0 or _garden_retarget_queued.has(nav_id):
			continue
		if _eating_agents().has(nav_id):
			continue
		if _escaping_agents().has(nav_id):
			continue
		var spawner_cell: Vector2i = INVALID_CELL
		if agent.has_meta("spawner_cell"):
			spawner_cell = agent.get_meta("spawner_cell") as Vector2i
		var garden_id: int = 0
		if agent.has_meta("garden_id"):
			garden_id = int(agent.get_meta("garden_id"))
		queue_agent_for_garden_retarget(nav_id, agent, "escape", spawner_cell, garden_id)


func queue_agent_for_garden_retarget(nav_id: int, agent: Node2D, intent: String, spawner_cell: Vector2i, garden_id: int) -> bool:
	if nav_id < 0 or not is_instance_valid(agent):
		return false
	# Tantrum clients are in the "monsters" group but are steered by
	# ClientTantrumController toward a reservoir. Garden retargeting must never
	# grab them: it would detach their reservoir flow and reset their status and
	# tantrum frame (e.g. when a wall built mid-tantrum stales a garden they still
	# reference from their shopping phase).
	if bool(agent.get_meta("hostile_client", false)):
		return false
	if _garden_retarget_queued.has(nav_id):
		return false
	_manager.detach_agent_path(nav_id)
	_manager.detach_agent_flow(nav_id)
	_entry_path_agents().erase(nav_id)
	_agent_navigation_phases.erase_astar_in_agent(nav_id)
	_escaping_agents().erase(nav_id)
	if _eating_agents().has(nav_id):
		_agent_navigation_phases.erase_eating_agent(nav_id)
		if agent.has_method("stop_eating"):
			agent.call("stop_eating")
		_manager.get_agent_cell_tracker().request_recheck(agent)
	if agent.has_method("start_waiting_new_status"):
		agent.call("start_waiting_new_status")
	_garden_retarget_queue.append({
		"nav_id": nav_id,
		"intent": intent,
		"spawner_cell": spawner_cell,
		"garden_id": garden_id
	})
	_garden_retarget_queued[nav_id] = true
	return true


func process_queue() -> int:
	if _garden_retarget_queue.is_empty():
		return 0
	var start_us: int = Time.get_ticks_usec()
	var budget_us: int = int(_manager.garden_retarget_budget_ms * 1000.0)
	var count_cap: int = _manager.garden_retarget_budget_per_frame
	var processed: int = 0
	while not _garden_retarget_queue.is_empty():
		if processed >= count_cap:
			break
		if processed > 0:
			if budget_us <= 0:
				break
			if Time.get_ticks_usec() - start_us >= budget_us:
				break
		var item: Dictionary = _garden_retarget_queue.pop_front() as Dictionary
		var nav_id: int = int(item.get("nav_id", -1))
		_garden_retarget_queued.erase(nav_id)
		if nav_id < 0:
			continue
		var agent: Node2D = _agent_from_nav_id(nav_id)
		if not is_instance_valid(agent):
			continue
		if str(agent.get("status")) != "waiting_new_status":
			continue
		_retarget_single_waiting_agent(nav_id, agent, item)
		processed += 1
	return processed


func retarget_agent_or_escape(agent: Node2D, spawner_cell: Vector2i) -> bool:
	if not is_instance_valid(agent):
		return false
	var retarget_us: int = Time.get_ticks_usec()
	var nav_id_dbg: int = int(agent.get("nav_id"))
	var assigned: bool = _retarget_agent_or_escape_impl(agent, spawner_cell)
	var total_us: int = Time.get_ticks_usec() - retarget_us
	if _debug_telemetry().over_garden_threshold_us(total_us):
		_emit_retarget_breakdown(nav_id_dbg, assigned, total_us)
	return assigned


func accumulate_find_path_in_zone(call_start_us: int, sync_elapsed: int, blocker_elapsed: int, find_elapsed: int, from_tile: Vector2i, to_tile: Vector2i, zone_tiles: int) -> void:
	var call_us: int = Time.get_ticks_usec() - call_start_us
	var a: Dictionary = _find_path_in_zone_accum
	a["call_count"] = int(a.get("call_count", 0)) + 1
	a["total_us"] = int(a.get("total_us", 0)) + call_us
	a["sync_zone_total_us"] = int(a.get("sync_zone_total_us", 0)) + sync_elapsed
	a["blocker_total_us"] = int(a.get("blocker_total_us", 0)) + blocker_elapsed
	a["find_path_total_us"] = int(a.get("find_path_total_us", 0)) + find_elapsed
	if call_us > int(a.get("max_single_call_us", 0)):
		a["max_single_call_us"] = call_us
		a["max_single_call_from"] = from_tile
		a["max_single_call_to"] = to_tile
	if zone_tiles > int(a.get("max_zone_tiles", 0)):
		a["max_zone_tiles"] = zone_tiles


func _assert_retarget_index_matches_scan(cell: Vector2i) -> void:
	var leftover: int = 0
	for raw_nav_id in _astar_in_agents().keys():
		var nav_id: int = int(raw_nav_id)
		var data: Dictionary = _astar_in_agents()[nav_id] as Dictionary
		if (data.get("plant_cell", INVALID_CELL) as Vector2i) == cell:
			leftover += 1
	if leftover > 0:
		push_warning("debug_garden_lag:retarget_index_mismatch plant=%s leftover_astar_in_targeting_cell=%d (index missed them)" % [str(cell), leftover])


func _agent_from_nav_id(nav_id: int) -> Node2D:
	var agent_manager: Node = _agent_manager()
	if agent_manager and agent_manager.has_method("find_node_by_agent"):
		var node: Variant = agent_manager.call("find_node_by_agent", nav_id)
		if is_instance_valid(node) and node is Node2D:
			return node as Node2D
	return null


func _garden_assignment_is_stale(garden_id: int) -> bool:
	if garden_id <= 0:
		return false
	if not _gardens().has(garden_id):
		return true
	if not bool(_garden_topology.garden_has_edible_plants(garden_id)):
		return true
	return false


func _agent_referenced_garden_id(nav_id: int, agent: Node2D) -> int:
	if _entry_path_agents().has(nav_id):
		return int((_entry_path_agents()[nav_id] as Dictionary).get("garden_id", 0))
	if _astar_in_agents().has(nav_id):
		return int((_astar_in_agents()[nav_id] as Dictionary).get("garden_id", 0))
	if _eating_agents().has(nav_id):
		var eat_garden: int = int((_eating_agents()[nav_id] as Dictionary).get("garden_id", 0))
		if eat_garden > 0:
			return eat_garden
	if is_instance_valid(agent) and agent.has_meta("garden_id"):
		return int(agent.get_meta("garden_id"))
	return 0


func _queue_affected_empty_garden_agent(nav_id: int, intent: String, garden_id: int) -> void:
	if _garden_retarget_queued.has(nav_id):
		return
	var agent: Node2D = _agent_from_nav_id(nav_id)
	if not is_instance_valid(agent):
		_entry_path_agents().erase(nav_id)
		_agent_navigation_phases.erase_astar_in_agent(nav_id)
		_agent_navigation_phases.erase_eating_agent(nav_id)
		return
	var spawner_cell: Vector2i = INVALID_CELL
	if _entry_path_agents().has(nav_id):
		spawner_cell = (_entry_path_agents()[nav_id] as Dictionary).get("spawner_cell", INVALID_CELL) as Vector2i
	elif _astar_in_agents().has(nav_id):
		spawner_cell = (_astar_in_agents()[nav_id] as Dictionary).get("spawner_cell", INVALID_CELL) as Vector2i
	elif _eating_agents().has(nav_id):
		spawner_cell = (_eating_agents()[nav_id] as Dictionary).get("spawner_cell", INVALID_CELL) as Vector2i
	if spawner_cell == INVALID_CELL and agent.has_meta("spawner_cell"):
		spawner_cell = agent.get_meta("spawner_cell") as Vector2i
	queue_agent_for_garden_retarget(nav_id, agent, intent, spawner_cell, garden_id)


func _retarget_single_waiting_agent(nav_id: int, agent: Node2D, item: Dictionary) -> void:
	if not is_instance_valid(agent):
		return
	var single_us: int = Time.get_ticks_usec()
	var intent: String = str(item.get("intent", "retarget"))
	var spawner_cell: Vector2i = item.get("spawner_cell", INVALID_CELL) as Vector2i
	var assigned: bool = false
	if intent == "escape":
		assigned = bool(_agent_navigation_phases.assign_agent_to_escape(agent))
	else:
		assigned = retarget_agent_or_escape(agent, spawner_cell)
	_debug_telemetry().warn_garden_task_lag_us("_retarget_single_waiting_agent", Time.get_ticks_usec() - single_us,
		"nav_id=%d intent=%s assigned=%s" % [nav_id, intent, str(assigned)])
	if assigned:
		if agent.has_method("stop_waiting_new_status"):
			agent.call("stop_waiting_new_status")
		return
	_requeue_waiting_agent(item)


func _requeue_waiting_agent(item: Dictionary) -> void:
	var nav_id: int = int(item.get("nav_id", -1))
	if nav_id < 0:
		return
	var retries: int = int(item.get("retries", 0)) + 1
	if retries > _GARDEN_RETARGET_MAX_RETRIES:
		var agent: Node2D = _agent_from_nav_id(nav_id)
		if is_instance_valid(agent) and agent.has_method("stop_waiting_new_status"):
			agent.call("stop_waiting_new_status")
		return
	if _garden_retarget_queued.has(nav_id):
		return
	item["retries"] = retries
	_garden_retarget_queue.append(item)
	_garden_retarget_queued[nav_id] = true


func _find_local_retarget_plant(from_cell: Vector2i, agent_kind: StringName = SPAWNER_KIND_MONSTER) -> Dictionary:
	_last_find_local_retarget_profile = {}
	if _manager.empty_garden_local_retarget_radius <= 0:
		return {}
	if not _manager._plant_manager_can_check_plants():
		return {}
	_reset_find_path_in_zone_accum()
	var local_us: int = Time.get_ticks_usec()
	var radius: int = maxi(0, _manager.empty_garden_local_retarget_radius)
	var best_target: Dictionary = {}
	var best_path_len: int = 2147483647
	var best_dist: int = 2147483647
	var cells_scanned: int = 0
	var plant_candidates: int = 0
	var rejected_no_garden: int = 0
	var rejected_not_edible: int = 0
	var path_checks: int = 0
	var path_failures: int = 0
	var path_checks_us: int = 0
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var manhattan: int = abs(dx) + abs(dy)
			if manhattan > radius:
				continue
			cells_scanned += 1
			var plant_cell: Vector2i = from_cell + Vector2i(dx, dy)
			if agent_kind == SPAWNER_KIND_CLIENT:
				if not _manager._is_client_target_cell(plant_cell):
					continue
			elif not _manager._is_eatable_for_monster(plant_cell):
				continue
			plant_candidates += 1
			if not _garden_by_plant_cell().has(plant_cell):
				rejected_no_garden += 1
				continue
			var garden_id: int = int(_garden_by_plant_cell()[plant_cell])
			if not _garden_topology.garden_has_target_for_kind(garden_id, agent_kind):
				rejected_not_edible += 1
				continue
			var check_us: int = Time.get_ticks_usec()
			var path_cells: PackedVector2Array = _building_path_service.find_path_in_zone(from_cell, plant_cell, garden_id)
			var this_check_us: int = Time.get_ticks_usec() - check_us
			path_checks += 1
			path_checks_us += this_check_us
			if _debug_telemetry().over_garden_threshold_us(this_check_us):
				_debug_telemetry().warn_garden_task_lag_us("_find_local_retarget_plant.path_check", this_check_us,
					"from=%s to=%s garden=%d len=%d" % [str(from_cell), str(plant_cell), garden_id, path_cells.size()])
			if path_cells.is_empty():
				path_failures += 1
				continue
			var path_len: int = path_cells.size()
			if path_len < best_path_len or (path_len == best_path_len and manhattan < best_dist):
				best_path_len = path_len
				best_dist = manhattan
				best_target = {
					"plant_cell": plant_cell,
					"garden_id": garden_id,
					"path_cells": path_cells
				}
	_garden_topology.drain_pending_empty_gardens()
	var total_us: int = Time.get_ticks_usec() - local_us
	var found: bool = not best_target.is_empty()
	_last_find_local_retarget_profile = {
		"radius": radius,
		"cells_checked": cells_scanned,
		"candidates_found": plant_candidates,
		"rejected_wrong_garden": rejected_no_garden,
		"rejected_not_edible": rejected_not_edible,
		"path_checks": path_checks,
		"path_failures": path_failures,
		"path_checks_total_us": path_checks_us,
		"total_us": total_us,
		"success": found,
	}
	if _debug_telemetry().over_garden_threshold_us(path_checks_us):
		_debug_telemetry().warn_garden_task_lag_us("_find_local_retarget_plant.path_checks_total", path_checks_us,
			"path_checks=%d failures=%d" % [path_checks, path_failures])
	if _debug_telemetry().over_garden_threshold_us(total_us):
		push_warning("debug_garden_lag_breakdown:_find_local_retarget_plant total=%.1fms threshold=%dms from=%s radius=%d cells_checked=%d candidates=%d wrong_garden=%d not_edible=%d path_checks=%d path_fail=%d path_checks_total=%.1fms success=%s" % [
			float(total_us) / 1000.0, int(_debug_telemetry().garden_lag_threshold_ms()), str(from_cell),
			radius, cells_scanned, plant_candidates,
			rejected_no_garden, rejected_not_edible, path_checks, path_failures,
			float(path_checks_us) / 1000.0, str(found)
		])
	if not best_target.is_empty() and not _gardens().has(int(best_target.get("garden_id", 0))):
		return {}
	return best_target


func _try_local_retarget_agent(agent: Node2D, from_cell: Vector2i, spawner_cell: Vector2i) -> bool:
	var total_us: int = Time.get_ticks_usec()
	var nav_id_dbg: int = int(agent.get("nav_id"))
	_last_local_retarget_profile = {
		"candidates": 0,
		"path_checks": 0,
		"candidate_search_us": 0,
		"path_validation_us": 0,
		"assignment_us": 0,
		"success": false,
	}
	var search_us: int = Time.get_ticks_usec()
	var target: Dictionary = _find_local_retarget_plant(from_cell, _agent_kind(agent))
	var search_elapsed: int = Time.get_ticks_usec() - search_us
	var fl: Dictionary = _last_find_local_retarget_profile
	var path_validation_us: int = int(fl.get("path_checks_total_us", 0))
	_last_local_retarget_profile["candidates"] = int(fl.get("candidates_found", 0))
	_last_local_retarget_profile["path_checks"] = int(fl.get("path_checks", 0))
	_last_local_retarget_profile["path_validation_us"] = path_validation_us
	_last_local_retarget_profile["candidate_search_us"] = maxi(0, search_elapsed - path_validation_us)
	_debug_telemetry().warn_garden_task_lag_us("_try_local_retarget_agent.candidate_search", search_elapsed,
		"nav_id=%d from=%s found=%s" % [nav_id_dbg, str(from_cell), str(not target.is_empty())])
	if target.is_empty():
		_finish_local_retarget_profile(nav_id_dbg, from_cell, total_us, false)
		return false
	var plant_cell: Vector2i = target.get("plant_cell", INVALID_CELL) as Vector2i
	var garden_id: int = int(target.get("garden_id", 0))
	var path_cells: PackedVector2Array = target.get("path_cells", PackedVector2Array()) as PackedVector2Array
	if plant_cell == INVALID_CELL or garden_id <= 0 or path_cells.is_empty():
		_finish_local_retarget_profile(nav_id_dbg, from_cell, total_us, false)
		return false
	var route_spawner_cell: Vector2i = _manager._select_spawner_for_garden_from_cell(garden_id, from_cell, spawner_cell, _agent_kind(agent))
	if route_spawner_cell == INVALID_CELL:
		_finish_local_retarget_profile(nav_id_dbg, from_cell, total_us, false)
		return false
	var assign_us: int = Time.get_ticks_usec()
	var nav_id: int = int(agent.get("nav_id"))
	_manager.detach_agent_flow(nav_id)
	var path_world: PackedVector2Array = _building_path_service.path_cells_to_world(path_cells, nav_id, true)
	_manager.assign_agent_path(nav_id, path_world)
	_entry_path_agents().erase(nav_id)
	_agent_navigation_phases.set_astar_in_agent(nav_id, {
		"node": agent,
		"plant_cell": plant_cell,
		"spawner_cell": route_spawner_cell,
		"garden_id": garden_id,
		"path_world": path_world
	})
	agent.set_meta("spawner_cell", route_spawner_cell)
	agent.set_meta("garden_id", garden_id)
	var in_entry_cell: Vector2i = _manager._nearest_garden_entry(garden_id, route_spawner_cell)
	if in_entry_cell != INVALID_CELL:
		agent.set_meta("garden_entry_cell", in_entry_cell)
	if agent.has_method("start_astar_in"):
		agent.call("start_astar_in")
	var assignment_elapsed: int = Time.get_ticks_usec() - assign_us
	_last_local_retarget_profile["assignment_us"] = assignment_elapsed
	_debug_telemetry().warn_garden_task_lag_us("_try_local_retarget_agent.assignment", assignment_elapsed,
		"nav_id=%d garden=%d plant=%s path_len=%d" % [nav_id, garden_id, str(plant_cell), path_cells.size()])
	_finish_local_retarget_profile(nav_id_dbg, from_cell, total_us, true)
	return true


func _finish_local_retarget_profile(nav_id: int, from_cell: Vector2i, total_start_us: int, success: bool) -> void:
	var total_us: int = Time.get_ticks_usec() - total_start_us
	_last_local_retarget_profile["success"] = success
	_last_local_retarget_profile["total_us"] = total_us
	if not _debug_telemetry().over_garden_threshold_us(total_us):
		return
	var p: Dictionary = _last_local_retarget_profile
	push_warning("debug_garden_lag_breakdown:_try_local_retarget_agent total=%.1fms nav_id=%d from=%s success=%s candidates=%d path_checks=%d candidate_search=%.1fms path_validation=%.1fms assign=%.1fms" % [
		float(total_us) / 1000.0, nav_id, str(from_cell), str(success),
		int(p.get("candidates", 0)), int(p.get("path_checks", 0)),
		float(p.get("candidate_search_us", 0)) / 1000.0,
		float(p.get("path_validation_us", 0)) / 1000.0,
		float(p.get("assignment_us", 0)) / 1000.0,
	])


func _emit_retarget_breakdown(nav_id: int, assigned: bool, total_us: int) -> void:
	var p: Dictionary = _last_retarget_profile
	var lr: Dictionary = _last_local_retarget_profile
	var fpz: Dictionary = _find_path_in_zone_accum
	var entry_cache_misses: int = int(p.get("entry_cache_misses", 0))
	var msg: String = "nav_id=%d assigned=%s reason=%s lookup=%.1fms resolve=%.1fms local_retarget=%.1fms escape=%.1fms assign=%.1fms entry_cache_hit=%s entry_cache_hits=%d entry_cache_misses=%d entry_cache_size=%d" % [
		nav_id, str(assigned), str(p.get("reason", "")),
		float(p.get("lookup_us", 0)) / 1000.0,
		float(p.get("resolve_us", 0)) / 1000.0,
		float(p.get("local_retarget_us", 0)) / 1000.0,
		float(p.get("escape_us", 0)) / 1000.0,
		float(p.get("assign_us", 0)) / 1000.0,
		str(entry_cache_misses == 0),
		int(p.get("entry_cache_hits", 0)),
		entry_cache_misses,
		int(p.get("entry_cache_size", 0)),
	]
	if not lr.is_empty():
		msg += " local_candidates=%d local_path_checks=%d local_search=%.1fms local_path_validation=%.1fms local_assign=%.1fms local_success=%s" % [
			int(lr.get("candidates", 0)), int(lr.get("path_checks", 0)),
			float(lr.get("candidate_search_us", 0)) / 1000.0,
			float(lr.get("path_validation_us", 0)) / 1000.0,
			float(lr.get("assignment_us", 0)) / 1000.0,
			str(lr.get("success", false)),
		]
	if int(fpz.get("call_count", 0)) > 0:
		msg += " path_calls=%d path_total=%.1fms path_sync=%.1fms path_blockers=%.1fms path_find=%.1fms max_path=%.1fms max_path_from=%s max_path_to=%s max_zone_tiles=%d" % [
			int(fpz.get("call_count", 0)),
			float(fpz.get("total_us", 0)) / 1000.0,
			float(fpz.get("sync_zone_total_us", 0)) / 1000.0,
			float(fpz.get("blocker_total_us", 0)) / 1000.0,
			float(fpz.get("find_path_total_us", 0)) / 1000.0,
			float(fpz.get("max_single_call_us", 0)) / 1000.0,
			str(fpz.get("max_single_call_from", INVALID_CELL)),
			str(fpz.get("max_single_call_to", INVALID_CELL)),
			int(fpz.get("max_zone_tiles", 0)),
		]
	var threshold_ms: float = _debug_telemetry().garden_lag_threshold_ms()
	push_warning("debug_garden_lag_breakdown:_retarget_agent_or_escape total=%.1fms threshold=%dms %s" % [
		float(total_us) / 1000.0, int(threshold_ms), msg
	])


func _reset_retarget_profile() -> void:
	_last_retarget_profile = {
		"reason": "",
		"lookup_us": 0,
		"resolve_us": 0,
		"local_retarget_us": 0,
		"escape_us": 0,
		"assign_us": 0,
		"entry_cache_hits": 0,
		"entry_cache_misses": 0,
		"entry_cache_size": 0,
	}
	_last_local_retarget_profile = {}
	_last_find_local_retarget_profile = {}
	_reset_find_path_in_zone_accum()


func _reset_find_path_in_zone_accum() -> void:
	_find_path_in_zone_accum = {
		"call_count": 0,
		"total_us": 0,
		"sync_zone_total_us": 0,
		"blocker_total_us": 0,
		"find_path_total_us": 0,
		"max_single_call_us": 0,
		"max_single_call_from": INVALID_CELL,
		"max_single_call_to": INVALID_CELL,
		"max_zone_tiles": 0,
	}


func _retarget_agent_or_escape_impl(agent: Node2D, spawner_cell: Vector2i) -> bool:
	_reset_retarget_profile()
	var t_val: int = Time.get_ticks_usec()
	if not is_instance_valid(agent):
		return false
	var nav_id_dbg: int = int(agent.get("nav_id"))
	var agent_kind: StringName = _agent_kind(agent)
	var no_plants: bool = _manager._no_targets_remaining_for_kind(agent_kind)
	var from_cell: Vector2i = INVALID_CELL
	if not no_plants:
		var floorz: TileMapLayer = _floorz()
		from_cell = floorz.local_to_map(floorz.to_local(agent.global_position))
	var lookup_us: int = Time.get_ticks_usec() - t_val
	_last_retarget_profile["lookup_us"] = lookup_us
	_debug_telemetry().warn_garden_task_lag_us("_retarget_agent_or_escape.validity", lookup_us,
		"nav_id=%d no_plants=%s" % [nav_id_dbg, str(no_plants)])
	if no_plants:
		_last_retarget_profile["reason"] = "no_plants"
		if agent_kind == SPAWNER_KIND_CLIENT:
			if _manager.total_counter_stock() <= 0 and _manager.grownup_rose_count() <= 0:
				if not bool(agent.get_meta("client_has_rose", false)):
					_manager.get_client_tantrum_controller().start_all_clients_without_rose()
					return bool(agent.get_meta("hostile_client", false))
		var t_esc0: int = Time.get_ticks_usec()
		var esc0: bool = bool(_agent_navigation_phases.assign_agent_to_escape(agent))
		var esc0_us: int = Time.get_ticks_usec() - t_esc0
		_last_retarget_profile["escape_us"] = esc0_us
		_debug_telemetry().warn_garden_task_lag_us("_retarget_agent_or_escape.escape", esc0_us,
			"nav_id=%d reason=no_plants assigned=%s" % [nav_id_dbg, str(esc0)])
		return esc0
	var local_us: int = Time.get_ticks_usec()
	var local_ok: bool = _try_local_retarget_agent(agent, from_cell, spawner_cell)
	var local_retarget_us: int = Time.get_ticks_usec() - local_us
	_last_retarget_profile["local_retarget_us"] = local_retarget_us
	_debug_telemetry().warn_garden_task_lag_us("_retarget_agent_or_escape.local_retarget", local_retarget_us,
		"nav_id=%d from=%s ok=%s" % [nav_id_dbg, str(from_cell), str(local_ok)])
	if local_ok:
		_last_retarget_profile["reason"] = "local_retarget"
		return true
	var t_res: int = Time.get_ticks_usec()
	var pair: Dictionary = _manager._select_spawner_garden_for_agent(from_cell, agent_kind)
	_last_retarget_profile["entry_cache_hits"] = _manager._garden_entry_resolve_hits()
	_last_retarget_profile["entry_cache_misses"] = _manager._garden_entry_resolve_misses()
	_last_retarget_profile["entry_cache_size"] = _manager._garden_entry_resolve_cache_size()
	if (pair.get("status", &"") as StringName) == SpawnerRouteService.APPROACH_STATUS_PENDING:
		# A spawner approach field is still computing, so no garden entry can be resolved
		# yet. This is a wait, not a dead end: returning false leaves the agent queued as
		# "waiting_new_status" and it retargets once the field lands. Escaping it here
		# would throw monsters off the map every time a wall is built.
		_last_retarget_profile["resolve_us"] = Time.get_ticks_usec() - t_res
		_last_retarget_profile["reason"] = "approach_pending"
		return false
	if pair.is_empty():
		if spawner_cell == INVALID_CELL:
			spawner_cell = _manager._nearest_spawner_cell(from_cell)
		if spawner_cell != INVALID_CELL and _spawner_route_service.has_spawner_route(spawner_cell):
			agent.set_meta("spawner_cell", spawner_cell)
		_last_retarget_profile["resolve_us"] = Time.get_ticks_usec() - t_res
		_debug_telemetry().warn_garden_task_lag_us("_retarget_agent_or_escape.target_resolve", int(_last_retarget_profile["resolve_us"]),
			"nav_id=%d pair=empty" % nav_id_dbg)
		return _escape_with_detector(agent, nav_id_dbg, "no_pair")
	spawner_cell = pair.get("spawner_cell", INVALID_CELL) as Vector2i
	var garden_id: int = int(pair.get("garden_id", 0))
	if garden_id <= 0:
		_last_retarget_profile["resolve_us"] = Time.get_ticks_usec() - t_res
		_debug_telemetry().warn_garden_task_lag_us("_retarget_agent_or_escape.target_resolve", int(_last_retarget_profile["resolve_us"]),
			"nav_id=%d garden=0" % nav_id_dbg)
		return _escape_with_detector(agent, nav_id_dbg, "garden<=0")
	var route: Dictionary = _manager._get_or_create_spawner_garden_route(spawner_cell, garden_id)
	# Lazy flow fields: a route with a flow group is usable even while its field is
	# still computing — the final assign below parks the agent as "ff wait" instead
	# of escaping it. Only a missing group means the route is genuinely unusable.
	if int(route.get("plant_group", -1)) <= IDLE_GROUP:
		_last_retarget_profile["resolve_us"] = Time.get_ticks_usec() - t_res
		_debug_telemetry().warn_garden_task_lag_us("_retarget_agent_or_escape.target_resolve", int(_last_retarget_profile["resolve_us"]),
			"nav_id=%d garden=%d no_flow_group" % [nav_id_dbg, garden_id])
		return _escape_with_detector(agent, nav_id_dbg, "no_flow_group")
	var entry_cell: Vector2i = route.get("entry_cell", INVALID_CELL) as Vector2i
	if entry_cell == INVALID_CELL:
		_last_retarget_profile["resolve_us"] = Time.get_ticks_usec() - t_res
		_debug_telemetry().warn_garden_task_lag_us("_retarget_agent_or_escape.target_resolve", int(_last_retarget_profile["resolve_us"]),
			"nav_id=%d garden=%d no_entry" % [nav_id_dbg, garden_id])
		return _escape_with_detector(agent, nav_id_dbg, "no_entry")
	var resolve_us: int = Time.get_ticks_usec() - t_res
	_last_retarget_profile["resolve_us"] = resolve_us
	_debug_telemetry().warn_garden_task_lag_us("_retarget_agent_or_escape.target_resolve", resolve_us,
		"nav_id=%d garden=%d entry=%s" % [nav_id_dbg, garden_id, str(entry_cell)])
	var t_fin: int = Time.get_ticks_usec()
	var assigned: bool = _agent_navigation_phases.assign_agent_to_garden_entry_flow(agent, spawner_cell, garden_id, entry_cell)
	var fin_us: int = Time.get_ticks_usec() - t_fin
	_last_retarget_profile["assign_us"] = fin_us
	_debug_telemetry().warn_garden_task_lag_us("_retarget_agent_or_escape.final_assign", fin_us,
		"nav_id=%d garden=%d entry=%s assigned=%s" % [nav_id_dbg, garden_id, str(entry_cell), str(assigned)])
	if not assigned:
		return _escape_with_detector(agent, nav_id_dbg, "entry_flow_failed")
	_last_retarget_profile["reason"] = "garden_entry"
	var nav_id: int = int(agent.get("nav_id"))
	_manager.set_agent_never_rest(nav_id, true)
	return true


func _escape_with_detector(agent: Node2D, nav_id_dbg: int, reason: String) -> bool:
	var t_esc: int = Time.get_ticks_usec()
	var esc: bool = bool(_agent_navigation_phases.assign_agent_to_escape(agent))
	var esc_us: int = Time.get_ticks_usec() - t_esc
	_last_retarget_profile["escape_us"] = esc_us
	_last_retarget_profile["reason"] = "escape:" + reason
	_debug_telemetry().warn_garden_task_lag_us("_retarget_agent_or_escape.escape", esc_us,
		"nav_id=%d reason=%s assigned=%s" % [nav_id_dbg, reason, str(esc)])
	return esc


func _entry_path_agents() -> Dictionary:
	return _agent_navigation_phases.entry_path_agents()


func _astar_in_agents() -> Dictionary:
	return _agent_navigation_phases.astar_in_agents()


func _eating_agents() -> Dictionary:
	return _agent_navigation_phases.eating_agents()


func _escaping_agents() -> Dictionary:
	return _agent_navigation_phases.escaping_agents()


func _gardens() -> Dictionary:
	return _garden_topology.gardens()


func _garden_by_plant_cell() -> Dictionary:
	return _garden_topology.garden_by_plant_cell()


func _agent_manager() -> Node:
	return _manager.agent_manager


func _floorz() -> TileMapLayer:
	return _manager.floorz


func _debug_telemetry():
	return _debug_telemetry_service


func _agent_kind(agent: Node2D) -> StringName:
	return _manager._agent_kind(agent)
