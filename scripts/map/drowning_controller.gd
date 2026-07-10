extends RefCounted
class_name DrowningController

enum WaterTrackResult {
	INVALID = -1,
	OUTSIDE_CANDIDATE = 0,
	CANDIDATE = 1,
	DROWNING = 2,
}

# Owns the "agent drowns in deep water" hazard: per-frame water sensing, pooled
# splash playback, and the drowning damage timeline. Follows the same
# manager-owned controller pattern as SeedMerchantController/MorningHarvestController:
# it holds a back-reference to BuildingManager and delegates the shared agent
# suspend/capture/resume machinery (also used by turret-eating) back to the
# manager rather than duplicating it.

const DEFAULT_AGENT_WORLD_RADIUS: float = 12.0

var _manager: BuildingManager
# nav_id -> drowning timeline state (node, duration, timers, damage, resume_state).
var _drowning_agents: Dictionary = {}


func setup(manager: BuildingManager) -> void:
	_manager = manager


func is_drowning(nav_id: int) -> bool:
	return _drowning_agents.has(nav_id)


func clear_agent(nav_id: int) -> void:
	_drowning_agents.erase(nav_id)


func drowning_count() -> int:
	return _drowning_agents.size()


func classify_water_candidate(agent: Node2D, floor_cell: Vector2i = Vector2i(2147483647, 2147483647)) -> int:
	if agent == null or not is_instance_valid(agent):
		return WaterTrackResult.INVALID
	var watersources: WaterSources = _watersources()
	if watersources == null:
		return WaterTrackResult.OUTSIDE_CANDIDATE
	if is_over_water(agent):
		return WaterTrackResult.CANDIDATE
	if watersources.water_coverage_of_world_rect(_agent_candidate_water_rect(agent, floor_cell)) > 0.0:
		return WaterTrackResult.CANDIDATE
	if watersources.water_coverage_of_world_rect(_foot_candidate_rect(floor_cell, agent)) > 0.0:
		return WaterTrackResult.CANDIDATE
	return WaterTrackResult.OUTSIDE_CANDIDATE


func reevaluate_water_candidate(agent: Node2D, delta: float, floor_cell: Vector2i = Vector2i(2147483647, 2147483647)) -> int:
	if agent == null or not is_instance_valid(agent):
		return WaterTrackResult.INVALID
	var candidate_state: int = classify_water_candidate(agent, floor_cell)
	if candidate_state == WaterTrackResult.INVALID or candidate_state == WaterTrackResult.OUTSIDE_CANDIDATE:
		stop_splash(agent)
		return candidate_state
	if is_over_water(agent):
		tick_splash(agent, delta)
	else:
		stop_splash(agent)
	var nav_id: int = int(agent.get("nav_id"))
	if nav_id < 0:
		return WaterTrackResult.CANDIDATE
	var turret_eating: TurretEatingController = _manager._turret_eating_controller
	if turret_eating.is_eating(nav_id):
		return WaterTrackResult.CANDIDATE
	if _drowning_agents.has(nav_id):
		return WaterTrackResult.DROWNING
	var water_coverage: float = _agent_water_coverage(agent)
	var in_water: bool = _agent_over_drowning_water_with_coverage(agent, water_coverage)
	if in_water and _agent_can_drown(agent):
		_start_agent_drowning(nav_id, agent)
		return WaterTrackResult.DROWNING
	return WaterTrackResult.CANDIDATE


# Single-agent drowning-start check, invoked by AgentCellTracker after the other
# tile interactions so the original priority/exclusivity order is preserved.
func evaluate_agent(agent: Node2D, floor_cell: Vector2i = Vector2i(2147483647, 2147483647)) -> void:
	reevaluate_water_candidate(agent, -1.0, floor_cell)


# True when the agent's foot position is over a water tile. Used as the exact
# current-water probe inside the tracker-managed water-candidate pass.
func is_over_water(agent: Node2D) -> bool:
	var watersources: WaterSources = _watersources()
	if watersources == null:
		return false
	return watersources.has_water_at_foot_position(agent.global_position)


# Advances the per-agent damage timeline for agents already drowning. This part is
# bounded by _drowning_agents (not a full-agent scan), so it stays per-frame.
func process_drowning_timeline(delta: float) -> void:
	var watersources: WaterSources = _watersources()
	if watersources == null:
		return

	var dead_agents: Array[Node2D] = []
	var drowning_ids: Array = _drowning_agents.keys()
	for raw_nav_id: Variant in drowning_ids:
		var nav_id: int = int(raw_nav_id)
		if not _drowning_agents.has(nav_id):
			continue
		var data: Dictionary = _drowning_agents[nav_id] as Dictionary
		var raw_agent: Variant = data.get("node", null)
		if not is_instance_valid(raw_agent):
			_drowning_agents.erase(nav_id)
			continue
		var agent: Node2D = raw_agent as Node2D
		if agent == null:
			_drowning_agents.erase(nav_id)
			continue
		var duration: float = maxf(float(data.get("duration", 0.0)), 0.001)
		var update_freq: float = maxf(float(data.get("update_freq", 0.1)), 0.01)
		var tick_timer: float = float(data.get("tick_timer", update_freq)) - delta
		var elapsed: float = minf(float(data.get("elapsed", 0.0)) + delta, duration)
		var dealt_damage: int = int(data.get("dealt_damage", 0))
		var total_damage: int = int(data.get("total_damage", 0))
		var damage_target: int = int(floor((elapsed / duration) * float(total_damage)))
		if tick_timer <= 0.0 or elapsed >= duration:
			var damage: int = maxi(0, damage_target - dealt_damage)
			if damage > 0 and agent.has_method("take_damage"):
				var died: bool = bool(agent.call("take_damage", damage))
				dealt_damage += damage
				if died:
					dead_agents.append(agent)
			tick_timer = update_freq
		data["elapsed"] = elapsed
		data["tick_timer"] = tick_timer
		data["dealt_damage"] = dealt_damage
		_drowning_agents[nav_id] = data

	for agent: Node2D in dead_agents:
		_manager.remove_dead_monster(agent, false)


# Emits the throttled pooled splash for one agent standing over water. Driven each
# frame by AgentCellTracker only for the active water-candidate subset. Keeps its
# own foot-water guard so a sub-cell move off water stops splashing cleanly.
func tick_splash(agent: Node2D, delta: float) -> void:
	# Any monster over the water emits a pooled splash, throttled per-monster.
	# The timer lives on the node itself (meta) so it is freed with the monster
	# and never accumulates stale entries.
	var watersources: WaterSources = _watersources()
	if watersources == null:
		return
	if not watersources.has_water_at_foot_position(agent.global_position):
		if agent.has_meta(&"water_splash_timer"):
			agent.remove_meta(&"water_splash_timer")
		return
	var time_left: float = float(agent.get_meta(&"water_splash_timer", 0.0)) - delta
	if time_left <= 0.0:
		watersources.play_splash_at(agent.global_position)
		time_left = maxf(watersources.splash_repeat_seconds, 0.0)
	agent.set_meta(&"water_splash_timer", time_left)


func stop_splash(agent: Node2D) -> void:
	if agent != null and is_instance_valid(agent) and agent.has_meta(&"water_splash_timer"):
		agent.remove_meta(&"water_splash_timer")


func _agent_can_drown(agent: Node2D) -> bool:
	var drownable_value: Variant = agent.get("drownable")
	var duration_value: Variant = agent.get("drowning")
	return drownable_value is bool and bool(drownable_value) and duration_value != null and float(duration_value) > 0.0


func _agent_over_drowning_water(agent: Node2D) -> bool:
	var watersources: WaterSources = _watersources()
	if watersources == null:
		return false
	return _agent_over_drowning_water_with_coverage(agent, _agent_water_coverage(agent))


func _agent_over_drowning_water_with_coverage(agent: Node2D, water_coverage: float) -> bool:
	var watersources: WaterSources = _watersources()
	if watersources == null:
		return false
	var threshold: float = clampf(watersources.drowning_coverage_threshold, 0.0, 1.0)
	if threshold <= 0.0:
		return watersources.has_water_at_foot_position(agent.global_position)
	return water_coverage >= threshold


func _agent_water_coverage(agent: Node2D) -> float:
	var watersources: WaterSources = _watersources()
	if watersources == null:
		return 0.0
	var footprint: Rect2 = _agent_water_footprint_rect(agent)
	return watersources.water_coverage_of_world_rect(footprint)


func _agent_water_footprint_rect(agent: Node2D) -> Rect2:
	var radius: float = maxf(1.0, _agent_world_radius())
	var size: Vector2 = Vector2(radius * 2.0, radius * 2.0)
	return Rect2(agent.global_position - size * 0.5, size)


func _agent_candidate_water_rect(agent: Node2D, floor_cell: Vector2i) -> Rect2:
	var footprint: Rect2 = _agent_water_footprint_rect(agent)
	var candidate_size: Vector2 = footprint.size + _tile_size()
	var center: Vector2 = _floor_cell_center(floor_cell, agent)
	return Rect2(center - candidate_size * 0.5, candidate_size)


func _foot_candidate_rect(floor_cell: Vector2i, agent: Node2D) -> Rect2:
	var center: Vector2 = _floor_cell_center(floor_cell, agent) + _foot_sample_offset()
	var size: Vector2 = _tile_size()
	return Rect2(center - size * 0.5, size)


func _agent_world_radius() -> float:
	var global_config: Node = _manager.global_config
	if global_config and global_config.has_method("get_agent_world_radius"):
		return float(global_config.call("get_agent_world_radius"))
	return DEFAULT_AGENT_WORLD_RADIUS


func _tile_size() -> Vector2:
	if _manager == null:
		return Vector2(32.0, 32.0)
	return _manager.tile_size()


func _floor_cell_center(floor_cell: Vector2i, agent: Node2D) -> Vector2:
	if _manager == null or _manager.floorz == null:
		return agent.global_position if agent != null else Vector2.ZERO
	var resolved_cell: Vector2i = floor_cell
	if resolved_cell == Vector2i(2147483647, 2147483647):
		if agent == null:
			return Vector2.ZERO
		resolved_cell = _manager.floorz.local_to_map(_manager.floorz.to_local(agent.global_position))
	return _manager.cell_center(resolved_cell)


func _foot_sample_offset() -> Vector2:
	var watersources: WaterSources = _watersources()
	if watersources == null:
		return Vector2.ZERO
	return watersources.foot_sample_offset


func _start_agent_drowning(nav_id: int, agent: Node2D) -> void:
	var duration: float = maxf(float(agent.get("drowning")), 0.001)
	var raw_update_freq: Variant = agent.get("drowning_update_freq")
	var update_freq: float = maxf(float(raw_update_freq) if raw_update_freq != null else 0.1, 0.01)
	var resume_state: Dictionary = _manager._capture_agent_resume_state(nav_id, agent)
	_drowning_agents[nav_id] = {
		"node": agent,
		"duration": duration,
		"update_freq": update_freq,
		"tick_timer": update_freq,
		"elapsed": 0.0,
		"total_damage": maxi(1, int(agent.get("health"))),
		"dealt_damage": 0,
		"resume_state": resume_state,
	}
	_manager._suspend_agent_for_drowning(nav_id)
	if agent.has_method("start_drowning"):
		agent.call("start_drowning", duration)


func _stop_agent_drowning(nav_id: int, agent: Node2D) -> void:
	var data: Dictionary = _drowning_agents.get(nav_id, {}) as Dictionary
	_drowning_agents.erase(nav_id)
	if agent.has_method("stop_drowning"):
		agent.call("stop_drowning")
	_manager.get_agent_cell_tracker().request_recheck(agent)
	var resume_state: Dictionary = data.get("resume_state", {}) as Dictionary
	_manager._resume_agent_after_drowning(nav_id, agent, resume_state)


func _watersources() -> WaterSources:
	return _manager.watersources if _manager != null else null
