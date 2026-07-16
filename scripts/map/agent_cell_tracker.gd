extends RefCounted
class_name AgentCellTracker

# Centralized tracked-agent owner for tile interactions. The general interaction pass
# remains transition-driven and deduplicated, while drowning/splash continuity is
# restricted to the small subset of tracked agents whose footprint can change water
# coverage without crossing into another floor cell.

const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)
const INVALID_WATER_STATE: int = DrowningController.WaterTrackResult.INVALID
const OUTSIDE_WATER_STATE: int = DrowningController.WaterTrackResult.OUTSIDE_CANDIDATE
const RECHECK_CELL_ENTERED: int = 1
const RECHECK_WORLD_CHANGED: int = 2
const RECHECK_STATE_CHANGED: int = 4

var _manager: BuildingManager = null
var _interactions: AgentTileInteractionController = AgentTileInteractionController.new()

# instance_id -> { "ref": WeakRef, "category": StringName, "cell": Vector2i }.
var _agents: Dictionary = {}
# Vector2i cell -> Dictionary(instance_id -> true). Only agents with a known cell.
var _cell_to_agents: Dictionary = {}
# instance_id -> true for agents that need continuous water reevaluation.
var _water_candidates: Dictionary = {}
# instance_id -> true while an external gameplay owner controls the agent transform.
var _suspended: Dictionary = {}
# FIFO dedup queue of instance_ids pending an interaction check.
var _queue: Array[int] = []
var _queued: Dictionary = {}
var _queued_reasons: Dictionary = {}
var _general_checked_this_frame: Dictionary = {}

# Per-frame debug counters, only maintained when debug logs are enabled.
var _debug_transitions: int = 0
var _debug_general_checks: int = 0
var _debug_drowning_checks: int = 0
var _debug_invalidations: int = 0
var _debug_continuous_water_checks: int = 0
var _debug_state_exit_rechecks: int = 0
var _debug_removed_water_candidates: int = 0
var _pending_debug_invalidations: int = 0
var _pending_debug_state_exit_rechecks: int = 0


func setup(manager: BuildingManager) -> void:
	_manager = manager
	_interactions.setup(manager)


func register(agent: Node2D, category: StringName) -> void:
	if agent == null or not is_instance_valid(agent):
		return
	var id: int = agent.get_instance_id()
	if _agents.has(id):
		return
	_agents[id] = {
		"ref": weakref(agent),
		"category": category,
		"cell": INVALID_CELL,
	}
	refresh_agent(agent)


func unregister(agent: Node2D) -> void:
	if agent == null:
		return
	_remove_id(agent.get_instance_id())


func suspend_agent(agent: Node2D) -> void:
	if agent == null or not is_instance_valid(agent):
		return
	var id: int = agent.get_instance_id()
	if not _agents.has(id):
		return
	var record: Dictionary = _agents[id] as Dictionary
	var cell: Vector2i = record["cell"] as Vector2i
	if cell != INVALID_CELL:
		_reindex(id, cell, INVALID_CELL)
		record["cell"] = INVALID_CELL
	_suspended[id] = true
	_water_candidates.erase(id)
	_queued.erase(id)
	_queued_reasons.erase(id)
	_general_checked_this_frame.erase(id)
	_erase_from_queue(id)
	_interactions.clear_agent_contact(id)


func resume_agent(agent: Node2D) -> void:
	if agent == null or not is_instance_valid(agent):
		return
	var id: int = agent.get_instance_id()
	if not _agents.has(id):
		return
	_suspended.erase(id)
	refresh_agent(agent)


func is_agent_suspended(agent: Node2D) -> bool:
	if agent == null or not is_instance_valid(agent):
		return false
	return _suspended.has(agent.get_instance_id())


func request_recheck(agent: Node2D) -> void:
	if agent == null or not is_instance_valid(agent):
		return
	var id: int = agent.get_instance_id()
	if not _agents.has(id):
		return
	_enqueue(id, RECHECK_STATE_CHANGED)
	if CppDebugOptions.logs_enabled:
		_pending_debug_state_exit_rechecks += 1


func refresh_agent(agent: Node2D) -> void:
	if agent == null or not is_instance_valid(agent):
		return
	var id: int = agent.get_instance_id()
	if not _agents.has(id):
		return
	if _suspended.has(id):
		return
	var record: Dictionary = _agents[id] as Dictionary
	var cell: Vector2i = _current_floor_cell(agent)
	var last_cell: Vector2i = record["cell"] as Vector2i
	var reason: int = RECHECK_STATE_CHANGED
	if cell != last_cell:
		_interactions.clear_agent_contact(id)
		_reindex(id, last_cell, cell)
		record["cell"] = cell
		reason = RECHECK_CELL_ENTERED
	_enqueue(id, reason)
	_refresh_water_candidate_membership(id, agent, cell)


func registered_count() -> int:
	return _agents.size()


func is_cell_occupied(cell: Vector2i, excluded_agent: Node2D = null) -> bool:
	if cell == INVALID_CELL or not _cell_to_agents.has(cell):
		return false
	var excluded_id: int = excluded_agent.get_instance_id() if excluded_agent != null and is_instance_valid(excluded_agent) else -1
	var dead: Array[int] = []
	var bucket: Dictionary = _cell_to_agents[cell] as Dictionary
	for raw_id: Variant in bucket.keys():
		var id: int = int(raw_id)
		if id == excluded_id:
			continue
		if _suspended.has(id):
			continue
		var record: Dictionary = _agents.get(id, {}) as Dictionary
		if record.is_empty():
			dead.append(id)
			continue
		var agent: Node2D = (record["ref"] as WeakRef).get_ref() as Node2D
		if agent == null or not is_instance_valid(agent) or agent.is_queued_for_deletion():
			dead.append(id)
			continue
		return true
	for id: int in dead:
		_remove_id(id)
	return false


func process(delta: float) -> void:
	if _manager == null:
		return
	_interactions.reset_debug_counters()
	if CppDebugOptions.logs_enabled:
		_debug_transitions = 0
		_debug_general_checks = 0
		_debug_drowning_checks = 0
		_debug_invalidations = _pending_debug_invalidations
		_debug_continuous_water_checks = 0
		_debug_state_exit_rechecks = _pending_debug_state_exit_rechecks
		_debug_removed_water_candidates = 0
		_pending_debug_invalidations = 0
		_pending_debug_state_exit_rechecks = 0
	else:
		_pending_debug_invalidations = 0
		_pending_debug_state_exit_rechecks = 0
	_general_checked_this_frame.clear()
	_poll_transitions()
	_drain_queue(delta)
	_interactions.process_active_contacts(delta)
	_tick_water_candidates(delta)


func invalidate_cell(cell: Vector2i) -> void:
	if not _cell_to_agents.has(cell):
		return
	var bucket: Dictionary = _cell_to_agents[cell] as Dictionary
	for raw_id: Variant in bucket.keys():
		_enqueue(int(raw_id), RECHECK_WORLD_CHANGED)
		if CppDebugOptions.logs_enabled:
			_pending_debug_invalidations += 1


func invalidate_cells(cells: Array[Vector2i]) -> void:
	for cell: Vector2i in cells:
		invalidate_cell(cell)


# Wipe all state on level unload / bulk agent clear (e.g. save load).
func clear() -> void:
	_agents.clear()
	_cell_to_agents.clear()
	_water_candidates.clear()
	_suspended.clear()
	_queue.clear()
	_queued.clear()
	_queued_reasons.clear()
	_general_checked_this_frame.clear()
	_interactions.clear()
	_pending_debug_invalidations = 0
	_pending_debug_state_exit_rechecks = 0


func debug_stats() -> Dictionary:
	var stats: Dictionary = {
		"registered": _agents.size(),
		"pending_general_checks": _queue.size(),
		"transitions": _debug_transitions,
		"checked": _debug_general_checks,
		"invalidations": _debug_invalidations,
		"water_candidates": _water_candidates.size(),
		"continuous_water_checks": _debug_continuous_water_checks,
		"state_exit_rechecks": _debug_state_exit_rechecks,
		"stale_water_candidates_removed": _debug_removed_water_candidates,
		"drowning": _debug_drowning_checks,
	}
	var by_type: Dictionary = _interactions.debug_stats()
	for key: Variant in by_type.keys():
		stats[key] = by_type[key]
	return stats


# --- internals -----------------------------------------------------------------


func _poll_transitions() -> void:
	var debug: bool = CppDebugOptions.logs_enabled
	var dead: Array[int] = []
	for raw_id: Variant in _agents:
		var id: int = int(raw_id)
		if _suspended.has(id):
			continue
		var record: Dictionary = _agents[id] as Dictionary
		var agent: Node2D = (record["ref"] as WeakRef).get_ref() as Node2D
		if agent == null or not is_instance_valid(agent) or agent.is_queued_for_deletion():
			dead.append(id)
			continue
		var cell: Vector2i = _current_floor_cell(agent)
		var last_cell: Vector2i = record["cell"] as Vector2i
		var category: StringName = record["category"] as StringName
		if cell != last_cell:
			_interactions.clear_agent_contact(id)
			_reindex(id, last_cell, cell)
			record["cell"] = cell
			_enqueue(id, RECHECK_CELL_ENTERED)
			_refresh_water_candidate_membership(id, agent, cell)
			if debug:
				_debug_transitions += 1
		else:
			_interactions.refresh_contact_dance(agent, category)
	for id: int in dead:
		_remove_id(id)


func _drain_queue(delta: float) -> void:
	var debug: bool = CppDebugOptions.logs_enabled
	var count: int = _queue.size()
	for i: int in range(count):
		var id: int = _queue[i]
		if not _queued.has(id):
			continue
		if _suspended.has(id):
			continue
		var record: Dictionary = _agents.get(id, {}) as Dictionary
		if record.is_empty():
			continue
		var agent: Node2D = (record["ref"] as WeakRef).get_ref() as Node2D
		if agent == null or not is_instance_valid(agent) or agent.is_queued_for_deletion():
			_remove_id(id)
			continue
		var category: StringName = record["category"] as StringName
		var cell: Vector2i = record["cell"] as Vector2i
		var reasons: int = int(_queued_reasons.get(id, RECHECK_STATE_CHANGED))
		_interactions.evaluate(agent, category, cell, reasons)
		_general_checked_this_frame[id] = true
		_apply_water_result(id, agent, _evaluate_water_state(agent, cell, delta))
		if debug:
			_debug_general_checks += 1
	_queue.clear()
	_queued.clear()
	_queued_reasons.clear()


func _tick_water_candidates(delta: float) -> void:
	if _water_candidates.is_empty():
		return
	var dead: Array[int] = []
	var invalid_seen: bool = false
	for raw_id: Variant in _water_candidates.keys():
		var id: int = int(raw_id)
		if _suspended.has(id):
			dead.append(id)
			continue
		if _general_checked_this_frame.has(id):
			continue
		var record: Dictionary = _agents.get(id, {}) as Dictionary
		if record.is_empty():
			dead.append(id)
			continue
		var agent: Node2D = (record["ref"] as WeakRef).get_ref() as Node2D
		if agent == null or not is_instance_valid(agent) or agent.is_queued_for_deletion():
			dead.append(id)
			invalid_seen = true
			continue
		var record_cell: Vector2i = record["cell"] as Vector2i
		var result: int = _evaluate_water_state(agent, record_cell, delta)
		_apply_water_result(id, agent, result)
		if CppDebugOptions.logs_enabled:
			_debug_continuous_water_checks += 1
	for id: int in dead:
		_water_candidates.erase(id)
		if CppDebugOptions.logs_enabled:
			_debug_removed_water_candidates += 1
	if invalid_seen and CppDebugOptions.logs_enabled and not dead.is_empty():
		push_error("AgentCellTracker: invalid agent found in water-candidate set; removed during cleanup pass.")


func _refresh_water_candidate_membership(id: int, agent: Node2D, cell: Vector2i) -> void:
	var drowning: DrowningController = _manager.get_drowning_controller()
	if drowning == null:
		_water_candidates.erase(id)
		return
	var result: int = drowning.classify_water_candidate(agent, cell)
	_apply_water_result(id, agent, result)


func _evaluate_water_state(agent: Node2D, cell: Vector2i, delta: float) -> int:
	var drowning: DrowningController = _manager.get_drowning_controller()
	if drowning == null:
		return OUTSIDE_WATER_STATE
	if CppDebugOptions.logs_enabled:
		_debug_drowning_checks += 1
	return drowning.reevaluate_water_candidate(agent, delta, cell)


func _apply_water_result(id: int, agent: Node2D, result: int) -> void:
	if result == INVALID_WATER_STATE or result == OUTSIDE_WATER_STATE:
		var was_candidate: bool = _water_candidates.has(id)
		_water_candidates.erase(id)
		if agent != null and is_instance_valid(agent):
			var drowning: DrowningController = _manager.get_drowning_controller()
			if drowning != null:
				drowning.stop_splash(agent)
		if was_candidate and CppDebugOptions.logs_enabled:
			_debug_removed_water_candidates += 1
		return
	_water_candidates[id] = true


func _reindex(id: int, old_cell: Vector2i, new_cell: Vector2i) -> void:
	if old_cell != INVALID_CELL and _cell_to_agents.has(old_cell):
		var old_bucket: Dictionary = _cell_to_agents[old_cell] as Dictionary
		old_bucket.erase(id)
		if old_bucket.is_empty():
			_cell_to_agents.erase(old_cell)
	if new_cell != INVALID_CELL:
		var new_bucket: Dictionary = _cell_to_agents.get(new_cell, {}) as Dictionary
		new_bucket[id] = true
		_cell_to_agents[new_cell] = new_bucket


func _enqueue(id: int, reason: int) -> void:
	_queued_reasons[id] = int(_queued_reasons.get(id, 0)) | reason
	if not _queued.has(id):
		_queue.append(id)
		_queued[id] = true


func _remove_id(id: int) -> void:
	var record: Dictionary = _agents.get(id, {}) as Dictionary
	if not record.is_empty():
		var cell: Vector2i = record["cell"] as Vector2i
		if cell != INVALID_CELL and _cell_to_agents.has(cell):
			var bucket: Dictionary = _cell_to_agents[cell] as Dictionary
			bucket.erase(id)
			if bucket.is_empty():
				_cell_to_agents.erase(cell)
	_agents.erase(id)
	_water_candidates.erase(id)
	_suspended.erase(id)
	_queued.erase(id)
	_queued_reasons.erase(id)
	_general_checked_this_frame.erase(id)
	_erase_from_queue(id)
	_interactions.clear_agent_contact(id)


func _erase_from_queue(id: int) -> void:
	for index: int in range(_queue.size() - 1, -1, -1):
		if _queue[index] == id:
			_queue.remove_at(index)


func _current_floor_cell(agent: Node2D) -> Vector2i:
	var floor_layer: TileMapLayer = _manager.floorz
	if floor_layer == null:
		return INVALID_CELL
	return floor_layer.local_to_map(floor_layer.to_local(agent.global_position))


func get_agents_in_world_radius(center: Vector2, radius: float, category: StringName) -> Array[Node2D]:
	var result: Array[Node2D] = []
	if _manager == null or _manager.floorz == null or radius <= 0.0:
		return result
	var floor_layer: TileMapLayer = _manager.floorz
	var tile_size: Vector2i = floor_layer.tile_set.tile_size if floor_layer.tile_set != null else Vector2i(32, 32)
	var cell_radius: int = ceili(radius / maxf(1.0, float(maxi(tile_size.x, tile_size.y))))
	var center_cell: Vector2i = floor_layer.local_to_map(floor_layer.to_local(center))
	var radius_squared: float = radius * radius
	for y: int in range(center_cell.y - cell_radius, center_cell.y + cell_radius + 1):
		for x: int in range(center_cell.x - cell_radius, center_cell.x + cell_radius + 1):
			var cell: Vector2i = Vector2i(x, y)
			var bucket: Dictionary = _cell_to_agents.get(cell, {}) as Dictionary
			if bucket.is_empty():
				continue
			for raw_id: Variant in bucket.keys():
				var id: int = int(raw_id)
				if _suspended.has(id):
					continue
				var record: Dictionary = _agents.get(id, {}) as Dictionary
				if record.is_empty() or (record["category"] as StringName) != category:
					continue
				var agent: Node2D = (record["ref"] as WeakRef).get_ref() as Node2D
				if agent == null or not is_instance_valid(agent) or agent.is_queued_for_deletion():
					continue
				if agent.global_position.distance_squared_to(center) <= radius_squared:
					result.append(agent)
	return result
