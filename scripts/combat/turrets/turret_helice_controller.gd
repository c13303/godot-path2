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
		"external_velocity_source_id": -1,
		"affected_nav_ids": {},
	}
	_building_objects.set_turret_activity_active(cell, false)
	_building_objects.set_turret_refractory_active(cell, false)


func unregister_turret(cell: Vector2i) -> void:
	if _states.has(cell):
		var state: Dictionary = _states[cell] as Dictionary
		_release_external_velocity_source(state)
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
		_ensure_external_velocity_source(state, steering)
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
	if active_left <= 0.0:
		_release_external_velocity_source(state, steering)
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
	var wind_direction: Vector2 = Vector2(float(direction.x), float(direction.y)).normalized()
	if wind_direction.is_zero_approx():
		return
	var source_id: int = int(state.get("external_velocity_source_id", -1))
	if source_id < 0:
		return
	var affected_nav_ids: Dictionary = state.get("affected_nav_ids", {}) as Dictionary
	var current_nav_ids: Dictionary = {}
	for agent: Node2D in _tracker.get_all_agents_in_world_radius(origin, data.shooting_range):
		if not _is_eligible(agent, cell, state, data, origin):
			continue
		if not _can_be_pushed(agent):
			continue
		var nav_id: int = int(agent.get("nav_id"))
		current_nav_ids[nav_id] = true
		steering.call(
			"set_agent_external_velocity",
			nav_id,
			source_id,
			wind_direction * data.wind_speed,
			data.wind_response_seconds,
			data.wind_expiry_seconds
		)
	for raw_nav_id: Variant in affected_nav_ids.keys():
		var previous_nav_id: int = int(raw_nav_id)
		if not current_nav_ids.has(previous_nav_id):
			steering.call("release_agent_external_velocity", previous_nav_id, source_id)
	state["affected_nav_ids"] = current_nav_ids


func _ensure_external_velocity_source(state: Dictionary, steering: Node) -> void:
	if int(state.get("external_velocity_source_id", -1)) >= 0:
		return
	state["external_velocity_source_id"] = int(steering.call("create_external_velocity_source"))


func _release_external_velocity_source(state: Dictionary, steering: Node = null) -> void:
	var resolved_steering: Node = steering
	if resolved_steering == null and _fight_system != null:
		resolved_steering = _fight_system.get_steering_system()
	var source_id: int = int(state.get("external_velocity_source_id", -1))
	if resolved_steering != null and source_id >= 0:
		var affected_nav_ids: Dictionary = state.get("affected_nav_ids", {}) as Dictionary
		for raw_nav_id: Variant in affected_nav_ids.keys():
			resolved_steering.call("release_agent_external_velocity", int(raw_nav_id), source_id)
	state["affected_nav_ids"] = {}


# Big monsters trigger the turret (detection) but are too heavy to be blown away.
func _can_be_pushed(agent: Node2D) -> bool:
	if not agent.has_meta("monster_type"):
		return true
	var monster_type: StringName = StringName(str(agent.get_meta("monster_type")))
	return monster_type != MonsterCatalog.BIG_MONSTER_ID


func _is_eligible(agent: Node2D, cell: Vector2i, state: Dictionary, data: TurretData, origin: Vector2) -> bool:
	if agent == null or not is_instance_valid(agent) or agent.is_queued_for_deletion() or not agent.visible:
		return false
	if agent.is_in_group(&"player") or agent.is_in_group(&"players"):
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
