extends RefCounted
class_name DrowningController

# Owns the "agent drowns in deep water" hazard: per-frame water sensing, pooled
# splash playback, and the drowning damage timeline. Follows the same
# manager-owned controller pattern as SeedMerchantController/MorningHarvestController:
# it holds a back-reference to BuildingManager and delegates the shared agent
# suspend/capture/resume machinery (also used by turret-eating) back to the
# manager rather than duplicating it.

const DEFAULT_AGENT_WORLD_RADIUS: float = 12.0

var _manager: Node
# nav_id -> drowning timeline state (node, duration, timers, damage, resume_state).
var _drowning_agents: Dictionary = {}


func setup(manager: Node) -> void:
	_manager = manager


func is_drowning(nav_id: int) -> bool:
	return _drowning_agents.has(nav_id)


func clear_agent(nav_id: int) -> void:
	_drowning_agents.erase(nav_id)


func drowning_count() -> int:
	return _drowning_agents.size()


func process_drowning_agents(delta: float) -> void:
	var watersources: WaterSources = _watersources()
	if watersources == null:
		return

	var turret_eating: Dictionary = _manager.get("_turret_eating_agents") as Dictionary
	for group_name: String in ["monsters", "clients", "merchants"]:
		for raw_node: Node in _manager.get_tree().get_nodes_in_group(group_name):
			var agent: Node2D = raw_node as Node2D
			if agent == null or not is_instance_valid(agent):
				continue
			var nav_id: int = int(agent.get("nav_id"))
			if nav_id < 0:
				continue
			_update_monster_splash(agent, delta)
			if turret_eating.has(nav_id):
				continue
			if _drowning_agents.has(nav_id):
				continue
			var water_coverage: float = _agent_water_coverage(agent)
			var in_water: bool = _agent_over_drowning_water_with_coverage(agent, water_coverage)
			if in_water and _agent_can_drown(agent):
				_start_agent_drowning(nav_id, agent)

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
		_manager.call("remove_dead_monster", agent, false)


func _update_monster_splash(agent: Node2D, delta: float) -> void:
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


func _agent_world_radius() -> float:
	var global_config: Node = _manager.get("global_config") as Node
	if global_config and global_config.has_method("get_agent_world_radius"):
		return float(global_config.call("get_agent_world_radius"))
	return DEFAULT_AGENT_WORLD_RADIUS


func _start_agent_drowning(nav_id: int, agent: Node2D) -> void:
	var duration: float = maxf(float(agent.get("drowning")), 0.001)
	var raw_update_freq: Variant = agent.get("drowning_update_freq")
	var update_freq: float = maxf(float(raw_update_freq) if raw_update_freq != null else 0.1, 0.01)
	var resume_state: Dictionary = _manager.call("_capture_agent_resume_state", nav_id, agent) as Dictionary
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
	_manager.call("_suspend_agent_for_drowning", nav_id)
	if agent.has_method("start_drowning"):
		agent.call("start_drowning", duration)


func _stop_agent_drowning(nav_id: int, agent: Node2D) -> void:
	var data: Dictionary = _drowning_agents.get(nav_id, {}) as Dictionary
	_drowning_agents.erase(nav_id)
	if agent.has_method("stop_drowning"):
		agent.call("stop_drowning")
	var resume_state: Dictionary = data.get("resume_state", {}) as Dictionary
	_manager.call("_resume_agent_after_drowning", nav_id, agent, resume_state)


func _watersources() -> WaterSources:
	return (_manager.get("watersources") as WaterSources) if _manager != null else null
