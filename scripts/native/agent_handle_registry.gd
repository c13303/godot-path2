extends Node
class_name AgentHandleRegistry

## Project-owned bridge between scene nodes and CPathLib agent/cohort handles.
## It owns no steering algorithm: all movement, navigation and force state stays in
## CrowdWorld2D. Weak references prevent this registry from extending scene-node life.

signal agent_registered(agent_handle: int, node: Node2D)
signal agent_unregistered(agent_handle: int)
signal agent_event(event_name: StringName, agent_handle: int, payload: Dictionary)

const INVALID_HANDLE: int = 0
const IDLE_COHORT: int = 0
const CATEGORY_PLAYER: int = 1 << 0
const CATEGORY_MAIN_CHARACTER: int = 1 << 1
const CATEGORY_HOSTILE: int = 1 << 2

@export var crowd_path: NodePath = NodePath("../CrowdWorld")
@export var crowd_runtime_path: NodePath = NodePath("../CrowdRuntime")
@export var simulation_config_path: NodePath = NodePath("../SimulationConfig")
@export var flow_coordinator_path: NodePath = NodePath("../NavigationRuntime/FlowCoordinator")

var _crowd: Node
var _nodes_by_handle: Dictionary = {}
var _handles_by_instance_id: Dictionary = {}
var _instance_id_by_handle: Dictionary = {}
var _cohort_by_agent: Dictionary = {}
var _project_state_by_agent: Dictionary = {}
var _automatic_step: bool = true
var _paused: bool = false
var _current_selected_cohort: int = IDLE_COHORT
var _flow_wait_by_cohort: Dictionary = {}
var _known_cohorts: Dictionary = {}
var _cohort_has_order: Dictionary = {}


func _ready() -> void:
	if _crowd == null:
		var candidate: Node = get_node_or_null(crowd_path)
		if candidate != null:
			setup(candidate, true)


## Parameter is not named crowd_world: that is this class's own getter below.
func setup(crowd_node: Node, automatic_step: bool = true) -> bool:
	if crowd_node == null or not crowd_node.has_method(&"add_agent"):
		return false
	_crowd = crowd_node
	_automatic_step = automatic_step
	_crowd.set(&"automatic_step", false)
	# The original project movement owner stepped and synchronized agents during
	# render processing. Keep that presentation contract here; CPathLib itself
	# remains usable with its default fixed-physics stepping in other consumers.
	set_physics_process(false)
	set_process(true)
	return true


func crowd_world() -> Node:
	return _crowd


func register_agent(node: Node2D, profile: Dictionary = {}, cohort_handle: int = 0) -> int:
	if node == null or _crowd == null:
		return INVALID_HANDLE
	var existing: int = handle_for_node(node)
	if existing != INVALID_HANDLE:
		return existing
	var radius: float = maxf(float(profile.get("radius", 14.4)), 0.0)
	var maximum_speed: float = maxf(float(profile.get("maximum_speed", 150.0)), 0.0)
	var separation_radius: float = maxf(float(profile.get("separation_radius", 32.0)), 0.0)
	var separation_weight: float = maxf(float(profile.get("separation_weight", 1.0)), 0.0)
	var profile_handle: int = int(_crowd.call(
		&"create_profile", radius, maximum_speed,
		maxf(float(profile.get("acceleration", 900.0)), 0.0),
		maxf(float(profile.get("deceleration", 1200.0)), 0.0),
		separation_radius, separation_weight,
		maxf(float(profile.get("arrival_radius", 16.0)), 0.0),
		maxi(int(profile.get("terrain_speed_channel", 0)), 0),
		int(profile.get("category_mask", -1))
	))
	if profile_handle == INVALID_HANDLE:
		return INVALID_HANDLE
	var handle: int = int(_crowd.call(
		&"add_agent_with_profile", node.global_position, profile_handle
	))
	_crowd.call(&"remove_profile", profile_handle)
	if handle == INVALID_HANDLE:
		return INVALID_HANDLE
	_nodes_by_handle[handle] = weakref(node)
	var instance_id: int = node.get_instance_id()
	_handles_by_instance_id[instance_id] = handle
	_instance_id_by_handle[handle] = instance_id
	_project_state_by_agent[handle] = {}
	_apply_profile(handle, profile)
	if cohort_handle != INVALID_HANDLE and not assign_agent_to_cohort(handle, cohort_handle):
		unregister_agent(handle)
		return INVALID_HANDLE
	agent_registered.emit(handle, node)
	return handle


func spawn_agent(node: Node2D, cohort_handle: int) -> int:
	var profile: Dictionary = _profile_for_scene_node(node)
	var handle: int = register_agent(node, profile, cohort_handle)
	if handle != INVALID_HANDLE:
		node.set("nav_id", handle)
		update_godot_agent(node, handle)
	return handle


func update_godot_agent(node: Node2D, agent_handle: int) -> void:
	if node == null:
		return
	send_agent_event(&"spawned", agent_handle, {
		"node_path": node.get_path(),
		"position": node.global_position,
	})


func unregister_agent(agent_handle: int) -> bool:
	if agent_handle == INVALID_HANDLE or _crowd == null:
		return false
	var instance_id: int = int(_instance_id_by_handle.get(agent_handle, 0))
	if instance_id != 0:
		_handles_by_instance_id.erase(instance_id)
	_instance_id_by_handle.erase(agent_handle)
	_nodes_by_handle.erase(agent_handle)
	_cohort_by_agent.erase(agent_handle)
	_project_state_by_agent.erase(agent_handle)
	var removed: bool = bool(_crowd.call(&"remove_agent", agent_handle))
	if removed:
		agent_unregistered.emit(agent_handle)
	return removed


func find_node(agent_handle: int) -> Node2D:
	var reference: WeakRef = _nodes_by_handle.get(agent_handle) as WeakRef
	if reference == null:
		return null
	var value: Variant = reference.get_ref()
	return value as Node2D


func registered_handles() -> PackedInt64Array:
	var handles: PackedInt64Array = PackedInt64Array()
	for raw_handle: Variant in _nodes_by_handle:
		handles.append(int(raw_handle))
	return handles


func handle_for_node(node: Node) -> int:
	if node == null:
		return INVALID_HANDLE
	return int(_handles_by_instance_id.get(node.get_instance_id(), INVALID_HANDLE))


func create_cohort() -> int:
	if _crowd == null:
		return INVALID_HANDLE
	var cohort_handle: int = int(_crowd.call(&"create_cohort"))
	if cohort_handle != INVALID_HANDLE:
		_known_cohorts[cohort_handle] = true
		_cohort_has_order[cohort_handle] = false
	return cohort_handle


func create_group() -> int:
	return create_cohort()


func remove_cohort(cohort_handle: int) -> bool:
	if _crowd == null or cohort_handle == INVALID_HANDLE:
		return false
	var members: Array = []
	for raw_handle: Variant in _cohort_by_agent:
		var agent_handle: int = int(raw_handle)
		if int(_cohort_by_agent[agent_handle]) == cohort_handle:
			members.append(agent_handle)
	for raw_handle: Variant in members:
		var agent_handle: int = int(raw_handle)
		_crowd.call(&"stop_navigation", agent_handle)
		_cohort_by_agent.erase(agent_handle)
	var coordinator: Node = get_node_or_null(flow_coordinator_path)
	if coordinator != null and coordinator.has_method(&"release_cohort_flow"):
		coordinator.call(&"release_cohort_flow", cohort_handle)
	var removed: bool = bool(_crowd.call(&"remove_cohort", cohort_handle))
	if removed:
		_known_cohorts.erase(cohort_handle)
		_cohort_has_order.erase(cohort_handle)
		_flow_wait_by_cohort.erase(cohort_handle)
		if _current_selected_cohort == cohort_handle:
			_current_selected_cohort = IDLE_COHORT
	return removed


func dissolve_group(cohort_handle: int) -> void:
	remove_cohort(cohort_handle)
	_flow_wait_by_cohort.erase(cohort_handle)


func cleanup_groups() -> void:
	var empty_cohorts: Array[int] = []
	for raw_handle: Variant in _known_cohorts:
		var cohort_handle: int = int(raw_handle)
		if cohort_handle == _current_selected_cohort:
			continue
		if count_group_route_references(cohort_handle) == 0 \
				or not bool(_cohort_has_order.get(cohort_handle, false)) \
				or _cohort_has_arrived(cohort_handle):
			empty_cohorts.append(cohort_handle)
	for cohort_handle: int in empty_cohorts:
		remove_cohort(cohort_handle)


func set_current_selected_group(cohort_handle: int) -> void:
	_current_selected_cohort = cohort_handle


func mark_group_has_order(cohort_handle: int) -> void:
	if _known_cohorts.has(cohort_handle):
		_cohort_has_order[cohort_handle] = true


func count_group_members(cohort_handle: int) -> int:
	return cohort_member_count(cohort_handle)


func count_group_route_references(cohort_handle: int) -> int:
	var count: int = cohort_member_count(cohort_handle)
	for raw_handle: Variant in _project_state_by_agent:
		var state: Dictionary = _project_state_by_agent[raw_handle] as Dictionary
		if int(state.get("waiting_flow_cohort", IDLE_COHORT)) == cohort_handle:
			count += 1
	return count


func get_group_flow_wait(cohort_handle: int) -> int:
	return int(_flow_wait_by_cohort.get(cohort_handle, 0))


func set_group_flow_wait(cohort_handle: int, state: int) -> void:
	if cohort_handle != IDLE_COHORT:
		_flow_wait_by_cohort[cohort_handle] = state
		if state != 0:
			mark_group_has_order(cohort_handle)
		_set_cohort_flow_navigation_suspended(cohort_handle, state != 0)


func _cohort_has_arrived(cohort_handle: int) -> bool:
	var found_member: bool = false
	for raw_handle: Variant in _cohort_by_agent:
		var agent_handle: int = int(raw_handle)
		if int(_cohort_by_agent[agent_handle]) != cohort_handle:
			continue
		found_member = true
		var diagnostics: Dictionary = _crowd.call(
			&"get_agent_diagnostics", agent_handle
		) as Dictionary
		if int(diagnostics.get("navigation_source", 0)) != 1 \
				or int(diagnostics.get("route_progress", 0)) != 2:
			return false
	return found_member


func assign_agent_to_cohort(agent_handle: int, cohort_handle: int) -> bool:
	if _crowd == null:
		return false
	if cohort_handle == INVALID_HANDLE:
		var detached: bool = bool(_crowd.call(&"remove_agent_from_cohort", agent_handle))
		_cohort_by_agent.erase(agent_handle)
		return detached
	var assigned: bool = bool(_crowd.call(
		&"assign_agent_to_cohort", agent_handle, cohort_handle
	))
	if assigned:
		_cohort_by_agent[agent_handle] = cohort_handle
		if int(_flow_wait_by_cohort.get(cohort_handle, 0)) != 0 \
				and _crowd.has_method(&"set_agent_navigation_suspended"):
			_crowd.call(&"set_agent_navigation_suspended", agent_handle, true)
	return assigned


func assign_agent(node: Node2D, cohort_handle: int) -> void:
	var agent_handle: int = handle_for_node(node)
	if agent_handle == INVALID_HANDLE and node != null:
		agent_handle = int(node.get("nav_id"))
	if agent_handle != INVALID_HANDLE:
		assign_agent_to_cohort(agent_handle, cohort_handle)


func cohort_for_agent(agent_handle: int) -> int:
	return int(_cohort_by_agent.get(agent_handle, INVALID_HANDLE))


func cohort_member_count(cohort_handle: int) -> int:
	if _crowd == null:
		return 0
	return int(_crowd.call(&"get_cohort_member_count", cohort_handle))


func follow_path(agent_handle: int, world_points: PackedVector2Array) -> bool:
	return _crowd != null and bool(_crowd.call(&"follow_path", agent_handle, world_points))


func follow_flow(agent_handle: int, flow_handle: int) -> bool:
	return _crowd != null and bool(_crowd.call(
		&"follow_flow_handle", agent_handle, flow_handle
	))


func stop_navigation(agent_handle: int) -> bool:
	return _crowd != null and bool(_crowd.call(&"stop_navigation", agent_handle))


func path_arrived(agent_handle: int) -> bool:
	return _crowd != null and int(_crowd.call(
		&"get_agent_route_progress", agent_handle
	)) == 2


func assign_agent_path(agent_handle: int, world_points: PackedVector2Array) -> void:
	follow_path(agent_handle, world_points)


func detach_agent_path(agent_handle: int) -> void:
	if _crowd == null:
		return
	var diagnostics: Dictionary = _crowd.call(
		&"get_agent_diagnostics", agent_handle
	) as Dictionary
	if int(diagnostics.get("navigation_source", 0)) == 2:
		_crowd.call(&"stop_navigation", agent_handle)


func agent_path_arrived(agent_handle: int) -> bool:
	return path_arrived(agent_handle)


func detach_agent_flow(agent_handle: int) -> void:
	if _crowd == null:
		return
	var diagnostics: Dictionary = _crowd.call(
		&"get_agent_diagnostics", agent_handle
	) as Dictionary
	if int(diagnostics.get("navigation_source", 0)) == 1:
		_crowd.call(&"stop_navigation", agent_handle)
	assign_agent_to_cohort(agent_handle, IDLE_COHORT)


func set_agent_waiting_flow_group(agent_handle: int, cohort_handle: int) -> void:
	var state: Dictionary = get_project_state(agent_handle)
	state["waiting_flow_cohort"] = cohort_handle
	set_project_state(agent_handle, state)
	if _crowd != null and _crowd.has_method(&"set_agent_navigation_suspended"):
		_crowd.call(&"set_agent_navigation_suspended", agent_handle, cohort_handle != IDLE_COHORT)


func set_agent_never_rest(agent_handle: int, value: bool) -> void:
	var state: Dictionary = get_project_state(agent_handle)
	state["never_rest"] = value
	set_project_state(agent_handle, state)
	if _crowd != null and _crowd.has_method(&"set_agent_continue_at_flow_goal"):
		_crowd.call(&"set_agent_continue_at_flow_goal", agent_handle, value)


func set_agent_phase(agent_handle: int, phase: int, eating_seconds: float = 0.0) -> void:
	var runtime: Node = get_node_or_null(crowd_runtime_path)
	if runtime != null:
		runtime.call(&"set_agent_phase", agent_handle, phase, eating_seconds)
		return
	var state: Dictionary = get_project_state(agent_handle)
	state["phase"] = phase
	state["eating_seconds"] = eating_seconds
	set_project_state(agent_handle, state)


func set_agent_paused(agent_handle: int, paused: bool) -> bool:
	if _crowd == null:
		return false
	if _crowd.has_method(&"set_agent_pause_allows_impulses"):
		_crowd.call(&"set_agent_pause_allows_impulses", agent_handle, true)
	return bool(_crowd.call(&"set_agent_paused", agent_handle, paused))


func set_agent_traffic_state(agent_handle: int, group_token: int, priority: int) -> bool:
	return _crowd != null and bool(_crowd.call(
		&"set_agent_traffic_state", agent_handle, group_token, priority
	))


func set_project_state(agent_handle: int, state: Dictionary) -> bool:
	if not _nodes_by_handle.has(agent_handle):
		return false
	_project_state_by_agent[agent_handle] = state.duplicate(true)
	return true


func get_project_state(agent_handle: int) -> Dictionary:
	var state: Dictionary = _project_state_by_agent.get(agent_handle, {}) as Dictionary
	return state.duplicate(true)


func send_agent_event(event_name: StringName, agent_handle: int, payload: Dictionary) -> void:
	agent_event.emit(event_name, agent_handle, payload)


func find_node_by_agent(agent_handle: int) -> Node2D:
	return find_node(agent_handle)


func set_world_paused(paused: bool) -> void:
	_paused = paused
	if _crowd != null:
		_crowd.call(&"set_world_paused", paused)


func get_registration_debug_snapshot() -> Dictionary:
	var handles: PackedInt64Array = PackedInt64Array()
	if _crowd != null:
		handles = _crowd.call(&"get_agent_handles") as PackedInt64Array
	var mapped: PackedInt64Array = PackedInt64Array()
	for raw_handle: Variant in _nodes_by_handle:
		mapped.append(int(raw_handle))
	mapped.sort()
	return {
		"crowd_agent_handles": handles,
		"agent_node_mapping_handles": mapped,
	}


func _process(delta: float) -> void:
	if _crowd == null:
		return
	_cleanup_stale_nodes()
	if _automatic_step and not _paused:
		_crowd.call(&"step", delta)
	_sync_nodes_from_crowd()


func _apply_profile(agent_handle: int, profile: Dictionary) -> void:
	var maximum_speed: float = maxf(float(profile.get("maximum_speed", 150.0)), 0.0)
	var acceleration: float = maxf(float(profile.get("acceleration", 900.0)), 0.0)
	var deceleration: float = maxf(float(profile.get("deceleration", 1200.0)), 0.0)
	_crowd.call(
		&"set_agent_motion_limits", agent_handle, maximum_speed, acceleration, deceleration
	)
	if _crowd.has_method(&"set_agent_collision_offset"):
		_crowd.call(
			&"set_agent_collision_offset", agent_handle,
			profile.get("collision_offset", Vector2.ZERO) as Vector2
		)
	if _crowd.has_method(&"set_agent_avoidance_profile"):
		_crowd.call(
			&"set_agent_avoidance_profile", agent_handle,
			maxf(float(profile.get("crowd_push_strength", 1.0)), 0.0),
			maxf(float(profile.get("crowd_resist_strength", 1.0)), 0.001)
		)
	if _crowd.has_method(&"set_agent_impulse_resistance"):
		_crowd.call(
			&"set_agent_impulse_resistance", agent_handle,
			maxf(float(profile.get("smash_resist", 1.0)), 0.001)
		)
	if _crowd.has_method(&"set_agent_query_shape"):
		_crowd.call(
			&"set_agent_query_shape", agent_handle,
			profile.get("query_shape_offset", Vector2.ZERO) as Vector2,
			profile.get("query_shape_half_extents", Vector2.ZERO) as Vector2
		)
	_crowd.call(
		&"set_agent_contact_profile", agent_handle,
		maxf(float(profile.get("contact_push_strength", 0.0)), 0.0),
		maxf(float(profile.get("contact_push_resistance", 1.0)), 0.0001),
		maxf(float(profile.get("contact_push_cooldown", 0.2)), 0.0),
		maxf(float(profile.get("contact_impulse_decay", 0.65)), 0.0),
		maxf(float(profile.get("contact_control_suppression", 0.2)), 0.0),
		bool(profile.get("contact_feedback_enabled", true))
	)


func _maximum_speed_for_node(node: Node2D) -> float:
	var config: SimulationConfigService = get_node_or_null(
		simulation_config_path
	) as SimulationConfigService
	var maximum_speed: float = config.get_agent_max_speed() if config != null else 150.0
	if node.is_in_group(&"player") and "max_speed" in node:
		var requested_speed: float = float(node.get("max_speed"))
		if requested_speed > 0.0:
			maximum_speed = requested_speed
	return maximum_speed * maxf(float(node.get_meta("monster_speed_scale", 1.0)), 0.001)


## Re-pushes every live agent's maximum speed from SimulationConfigService. The debug
## speed multiplier writes that value, and without this only agents registered after
## the change would pick it up.
func refresh_agent_speeds() -> void:
	if _crowd == null:
		return
	for raw_handle: Variant in _nodes_by_handle:
		var agent_handle: int = int(raw_handle)
		var node: Node2D = find_node(agent_handle)
		if node == null:
			continue
		var diagnostics: Dictionary = _crowd.call(
			&"get_agent_diagnostics", agent_handle
		) as Dictionary
		if not bool(diagnostics.get("valid", false)):
			continue
		_crowd.call(
			&"set_agent_motion_limits", agent_handle,
			_maximum_speed_for_node(node),
			float(diagnostics.get("acceleration", 900.0)),
			float(diagnostics.get("deceleration", 1200.0))
		)


func _profile_for_scene_node(node: Node2D) -> Dictionary:
	var category_mask: int = CATEGORY_MAIN_CHARACTER
	if node.is_in_group(&"player"):
		category_mask = CATEGORY_PLAYER
	elif node.is_in_group(&"monsters") or node.is_in_group(&"clients") \
			or node.is_in_group(&"villagers"):
		category_mask = CATEGORY_HOSTILE
	var config: SimulationConfigService = get_node_or_null(simulation_config_path) as SimulationConfigService
	var query_shape: Dictionary = _query_shape_for_scene_node(node)
	return {
		"radius": config.get_agent_world_radius() if config != null else 14.4,
		"maximum_speed": _maximum_speed_for_node(node),
		"acceleration": 900.0,
		"deceleration": 1200.0,
		"separation_radius": 32.0,
		"separation_weight": 600.0,
		"crowd_push_strength": 1.0,
		"crowd_resist_strength": float(node.get_meta("monster_crowd_resist", 1.0)),
		"smash_resist": float(node.get_meta("monster_smash_resist", 1.0)),
		"query_shape_offset": query_shape["offset"],
		"query_shape_half_extents": query_shape["half_extents"],
		"arrival_radius": 16.0,
		"terrain_speed_channel": int(node.get_meta("terrain_speed_channel", 0)),
		"category_mask": category_mask,
		"contact_push_strength": float(node.get_meta("agent_contact_push_power", 0.0)),
		"contact_push_resistance": float(node.get_meta("agent_contact_push_resist", 1.0)),
		"contact_push_cooldown": float(node.get_meta("agent_contact_push_cooldown", 0.2)),
		"contact_impulse_decay": float(node.get_meta("agent_contact_push_friction_loss", 0.65)),
		"contact_control_suppression": float(node.get_meta(
			"agent_contact_control_suppression_seconds", 0.2
		)),
		"contact_feedback_enabled": bool(node.get_meta(
			"agent_contact_push_shows_control_impaired_feedback", true
		)),
	}


func _query_shape_for_scene_node(node: Node2D) -> Dictionary:
	var offset: Vector2 = Vector2(0.0, -32.0) if node.is_in_group(&"player") \
		else Vector2.ZERO
	var half_extents: Vector2 = Vector2(32.0, 32.0)
	for child: Node in node.get_children():
		var sprite: Sprite2D = child as Sprite2D
		if sprite == null or sprite.texture == null:
			continue
		var frame_size: Vector2 = sprite.texture.get_size()
		if sprite.hframes > 1:
			frame_size.x /= float(sprite.hframes)
		if sprite.vframes > 1:
			frame_size.y /= float(sprite.vframes)
		half_extents = frame_size * sprite.scale.abs() * 0.5
		offset = sprite.position
		if not sprite.centered:
			offset += half_extents
		break
	return {"offset": offset, "half_extents": half_extents}


func _set_cohort_flow_navigation_suspended(cohort_handle: int, suspended: bool) -> void:
	if _crowd == null or not _crowd.has_method(&"set_agent_navigation_suspended"):
		return
	for raw_handle: Variant in _cohort_by_agent:
		var agent_handle: int = int(raw_handle)
		if int(_cohort_by_agent[agent_handle]) != cohort_handle:
			continue
		var diagnostics: Dictionary = _crowd.call(
			&"get_agent_diagnostics", agent_handle
		) as Dictionary
		if suspended and int(diagnostics.get("navigation_source", 0)) != 1:
			continue
		_crowd.call(&"set_agent_navigation_suspended", agent_handle, suspended)


func _cleanup_stale_nodes() -> void:
	var stale_handles: Array = []
	for raw_handle: Variant in _nodes_by_handle:
		var agent_handle: int = int(raw_handle)
		if find_node(agent_handle) == null:
			stale_handles.append(agent_handle)
	for raw_handle: Variant in stale_handles:
		unregister_agent(int(raw_handle))


func _sync_nodes_from_crowd() -> void:
	var handles: PackedInt64Array = _crowd.call(&"get_agent_handles") as PackedInt64Array
	var positions: PackedVector2Array = _crowd.call(&"get_agent_positions") as PackedVector2Array
	var velocities: PackedVector2Array = _crowd.call(&"get_agent_velocities") as PackedVector2Array
	var impulse_states: Dictionary = {}
	if _crowd.has_method(&"get_active_impulse_states"):
		impulse_states = _crowd.call(&"get_active_impulse_states") as Dictionary
	var count: int = mini(handles.size(), mini(positions.size(), velocities.size()))
	for index: int in range(count):
		var agent_handle: int = int(handles[index])
		var node: Node2D = find_node(agent_handle)
		if node == null:
			continue
		node.global_position = positions[index]
		if node.has_method(&"set_velocity_len"):
			node.call(&"set_velocity_len", velocities[index].length())
		var project_state: Dictionary = get_project_state(agent_handle)
		var impulse_state: Dictionary = impulse_states.get(agent_handle, {}) as Dictionary
		var feedback_enabled: bool = bool(impulse_state.get("feedback_enabled", true))
		var propelled: bool = not impulse_state.is_empty() and feedback_enabled
		var controls_impaired: bool = feedback_enabled and float(impulse_state.get(
			"control_suppression_remaining", 0.0
		)) > 0.0
		var was_propelled: bool = bool(project_state.get("propelled", false))
		var was_controls_impaired: bool = bool(project_state.get(
			"controls_impaired", false
		))
		if propelled != was_propelled or controls_impaired != was_controls_impaired:
			project_state["propelled"] = propelled
			project_state["controls_impaired"] = controls_impaired
			set_project_state(agent_handle, project_state)
			send_agent_event(&"propelled_state_update", agent_handle, {
				"is_propelled": propelled,
				"controls_impaired": controls_impaired,
				"velocity_len": velocities[index].length(),
			})
