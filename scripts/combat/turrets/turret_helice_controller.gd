extends RefCounted
class_name TurretHeliceController

enum State {
	READY,
	ACTIVE,
	COOLDOWN,
}

var _tracker: AgentCellTracker
var _building_manager: BuildingManager
var _building_objects: BuildingObjectManager
var _fight_system: FightSystem
var _turret_system: TurretSystem
var _states: Dictionary = {}


func setup(
	tracker: AgentCellTracker,
	building_manager: BuildingManager,
	building_objects: BuildingObjectManager,
	fight_system: FightSystem,
	turret_system: TurretSystem
) -> void:
	_tracker = tracker
	_building_manager = building_manager
	_building_objects = building_objects
	_fight_system = fight_system
	_turret_system = turret_system


func register_turret(cell: Vector2i, data: TurretData, direction: Vector2i, acquisition_wait: float) -> void:
	_states[cell] = {
		"data": data,
		"direction": direction,
		"state": State.READY,
		"active_time_left": 0.0,
		"cooldown_time_left": 0.0,
		"acquisition_wait": acquisition_wait,
		"query_wait": 0.0,
		"repulse_wait_by_agent": {},
	}
	_building_objects.set_turret_activity_active(cell, false)
	_building_objects.set_turret_refractory_active(cell, false)


func unregister_turret(cell: Vector2i) -> void:
	_states.erase(cell)


func process(delta: float) -> void:
	if _tracker == null or _fight_system == null or _turret_system == null:
		return
	var steering: Node = _fight_system.get_steering_system()
	if steering == null:
		return
	for raw_cell: Variant in _states.keys():
		var cell: Vector2i = raw_cell as Vector2i
		if not _states.has(cell):
			continue
		var state: Dictionary = _states[cell] as Dictionary
		var data: TurretData = state.get("data", null) as TurretData
		if data == null:
			continue
		var current_state: int = int(state.get("state", State.READY))
		if current_state == State.COOLDOWN:
			var cooldown_left: float = float(state.get("cooldown_time_left", 0.0)) - delta
			state["cooldown_time_left"] = cooldown_left
			if cooldown_left <= 0.0:
				state["state"] = State.READY
				_building_objects.set_turret_refractory_active(cell, false)
			continue
		if current_state == State.ACTIVE:
			_process_active(cell, state, data, steering, delta)
			continue
		var acquisition_wait: float = maxf(0.0, float(state.get("acquisition_wait", 0.0)) - delta)
		state["acquisition_wait"] = acquisition_wait
		if acquisition_wait > 0.0:
			continue
		state["acquisition_wait"] = maxf(0.02, _turret_system.target_acquisition_interval)
		if _has_eligible_agent(cell, state, data):
			state["state"] = State.ACTIVE
			state["active_time_left"] = data.wind_active_duration
			state["query_wait"] = 0.0
			_building_objects.set_turret_activity_active(cell, true)
			_process_active_query(cell, state, data, steering)


func _process_active(cell: Vector2i, state: Dictionary, data: TurretData, steering: Node, delta: float) -> void:
	var active_left: float = float(state.get("active_time_left", 0.0)) - delta
	state["active_time_left"] = active_left
	_decrement_repulse_waits(state, delta)
	if active_left <= 0.0:
		state["state"] = State.COOLDOWN
		state["cooldown_time_left"] = data.wind_cooldown_duration
		_building_objects.set_turret_activity_active(cell, false)
		_building_objects.set_turret_refractory_active(cell, true)
		return
	var query_wait: float = float(state.get("query_wait", 0.0)) - delta
	state["query_wait"] = query_wait
	if query_wait <= 0.0:
		state["query_wait"] = data.wind_query_interval
		_process_active_query(cell, state, data, steering)


func _has_eligible_agent(cell: Vector2i, state: Dictionary, data: TurretData) -> bool:
	var origin: Vector2 = _turret_system.get_turret_world_position(cell)
	for agent: Node2D in _tracker.get_all_agents_in_world_radius(origin, data.shooting_range):
		if _is_eligible(agent, cell, state, data, origin):
			return true
	return false


func _process_active_query(cell: Vector2i, state: Dictionary, data: TurretData, steering: Node) -> void:
	var origin: Vector2 = _turret_system.get_turret_world_position(cell)
	var direction: Vector2i = state.get("direction", Vector2i.RIGHT) as Vector2i
	var impulse_direction: Vector2 = Vector2(float(direction.x), float(direction.y)).normalized()
	if impulse_direction.is_zero_approx():
		return
	var repulse_wait_by_agent: Dictionary = state.get("repulse_wait_by_agent", {}) as Dictionary
	var eligible_ids: Dictionary = {}
	for agent: Node2D in _tracker.get_all_agents_in_world_radius(origin, data.shooting_range):
		if not _is_eligible(agent, cell, state, data, origin):
			continue
		var instance_id: int = agent.get_instance_id()
		eligible_ids[instance_id] = true
		if float(repulse_wait_by_agent.get(instance_id, 0.0)) > 0.0:
			continue
		var nav_id: int = int(agent.get("nav_id"))
		steering.call("apply_navigation_preserving_impulse", nav_id, impulse_direction, data.wind_force, data.wind_friction_loss)
		repulse_wait_by_agent[instance_id] = data.wind_repulse_frequency
	for raw_instance_id: Variant in repulse_wait_by_agent.keys():
		if not eligible_ids.has(int(raw_instance_id)):
			repulse_wait_by_agent.erase(raw_instance_id)
	state["repulse_wait_by_agent"] = repulse_wait_by_agent


func _decrement_repulse_waits(state: Dictionary, delta: float) -> void:
	var repulse_wait_by_agent: Dictionary = state.get("repulse_wait_by_agent", {}) as Dictionary
	for raw_instance_id: Variant in repulse_wait_by_agent.keys():
		var instance_id: int = int(raw_instance_id)
		repulse_wait_by_agent[instance_id] = maxf(0.0, float(repulse_wait_by_agent[instance_id]) - delta)
	state["repulse_wait_by_agent"] = repulse_wait_by_agent


func _is_eligible(agent: Node2D, cell: Vector2i, state: Dictionary, data: TurretData, origin: Vector2) -> bool:
	if agent == null or not is_instance_valid(agent) or agent.is_queued_for_deletion() or not agent.visible:
		return false
	if agent.is_in_group(&"player") or agent.is_in_group(&"players"):
		return false
	if agent.has_meta("monster_type"):
		var monster_type: StringName = StringName(str(agent.get_meta("monster_type")))
		if monster_type == MonsterCatalog.BIG_MONSTER_ID:
			return false
	if _tracker.is_agent_suspended(agent):
		return false
	if agent.has_method("is_external_capture_active") and bool(agent.call("is_external_capture_active")):
		return false
	var nav_id: int = int(agent.get("nav_id"))
	if nav_id < 0 or _building_manager == null or _building_manager.get_drowning_controller().is_drowning(nav_id):
		return false
	if _building_manager.is_agent_eating_plant(nav_id):
		return false
	if origin.distance_squared_to(agent.global_position) > data.shooting_range * data.shooting_range:
		return false
	var direction: Vector2i = state.get("direction", Vector2i.RIGHT) as Vector2i
	if data.straight_line_detection:
		if not _turret_system.is_world_position_in_straight_line(cell, agent.global_position, direction, data.shooting_range):
			return false
	elif not TurretGeometry.is_within_directional_angle(origin, agent.global_position, direction, data.activation_angle_degrees):
		return false
	return _turret_system.turret_can_see_world_position(cell, agent.global_position)
