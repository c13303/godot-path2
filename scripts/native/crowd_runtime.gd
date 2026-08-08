extends Node
class_name CrowdRuntime

## Project-owned gameplay adapter over the generic CPathLib crowd world.
## Mission phases, damage payloads and debug presentation stay in this project.

const INVALID_HANDLE: int = 0
const EFFECT_TICK: int = 1
const GAMEPLAY_IMPULSE_PRIORITY: int = 100

@export var crowd_path: NodePath = NodePath("../CrowdWorld")
@export var registry_path: NodePath = NodePath("../AgentRegistry")
@export var navigation_path: NodePath = NodePath("../NavigationRuntime/World")

var _crowd: Node
var _registry: AgentHandleRegistry
var _navigation: Node
var _obstacle_handles: Dictionary = {}
var _directional_handles: Dictionary = {}
var _directional_field_by_phase: Dictionary = {}
var _effect_configs: Dictionary = {}
var _damage_events: Array = []
var _debug_values: Dictionary = {}


func _ready() -> void:
	_crowd = get_node_or_null(crowd_path)
	_registry = get_node_or_null(registry_path) as AgentHandleRegistry
	_navigation = get_node_or_null(navigation_path)
	var config: NativeSimulationConfig = NativeSimulationConfig.new()
	config.apply_to_crowd(_crowd)
	set_process(true)


func _process(delta: float) -> void:
	if _crowd == null:
		return
	var events: Array = _crowd.call(&"take_effect_events") as Array
	for raw_event: Variant in events:
		var event: Dictionary = raw_event as Dictionary
		if int(event.get("kind", -1)) != EFFECT_TICK:
			continue
		var volume_handle: int = int(event.get("volume_handle", INVALID_HANDLE))
		var config: Dictionary = _effect_configs.get(volume_handle, {}) as Dictionary
		if config.is_empty():
			continue
		var origin: Vector2 = config.get("origin", Vector2.ZERO) as Vector2
		var followed_handle: int = int(config.get("followed_agent_handle", INVALID_HANDLE))
		if followed_handle != INVALID_HANDLE:
			origin = get_agent_position(followed_handle) + (config.get("follow_offset", Vector2.ZERO) as Vector2)
		_apply_gameplay_effect(
			int(event.get("agent_handle", INVALID_HANDLE)),
			origin,
			config
		)
	_age_effect_configs(delta)


func set_agent_control_mode(agent_handle: int, mode: int) -> void:
	if _crowd != null and mode == 1:
		_crowd.call(&"set_manual_direction", agent_handle, Vector2.ZERO)


func set_agent_input(agent_handle: int, direction: Vector2) -> void:
	if _crowd != null:
		_crowd.call(&"set_manual_direction", agent_handle, direction)


func set_agent_manual_motion(agent_handle: int, acceleration: float, deceleration: float) -> void:
	if _crowd == null:
		return
	var node: Node2D = _registry.find_node(agent_handle) if _registry != null else null
	var maximum_speed: float = float(node.get("max_speed")) if node != null and "max_speed" in node else 150.0
	_crowd.call(&"set_agent_motion_limits", agent_handle, maximum_speed, acceleration, deceleration)


func set_agent_profile(agent_handle: int, profile: Dictionary) -> void:
	if _crowd == null:
		return
	var node: Node2D = _registry.find_node(agent_handle) if _registry != null else null
	var current: Dictionary = _crowd.call(
		&"get_agent_diagnostics", agent_handle
	) as Dictionary
	if not bool(current.get("valid", false)):
		return
	var fallback_speed: float = float(current.get("maximum_speed", 150.0))
	if fallback_speed <= 0.0 and node != null and "max_speed" in node:
		fallback_speed = float(node.get("max_speed"))
	var maximum_speed: float = maxf(float(profile.get("max_speed", profile.get("maximum_speed", fallback_speed))), 0.0)
	var acceleration: float = maxf(float(profile.get(
		"acceleration", current.get("acceleration", 900.0)
	)), 0.0)
	var deceleration: float = maxf(float(profile.get(
		"deceleration", current.get("deceleration", 1200.0)
	)), 0.0)
	var category_mask: int = int(profile.get(
		"smash_class", profile.get("category_mask", current.get(
			"category_mask", _category_for_node(node)
		))
	))
	var profile_handle: int = int(_crowd.call(
		&"create_profile",
		maxf(float(profile.get("world_radius", profile.get(
			"radius", current.get("radius", 14.4)
		))), 0.0), maximum_speed,
		acceleration, deceleration,
		maxf(float(profile.get(
			"separation_radius", current.get("separation_radius", 32.0)
		)), 0.0),
		maxf(float(profile.get("separation_strength", profile.get(
			"separation_weight", current.get("separation_weight", 600.0)
		))), 0.0),
		maxf(float(profile.get(
			"arrival_radius", current.get("arrival_radius", 16.0)
		)), 0.0),
		maxi(int(profile.get(
			"terrain_speed_channel", current.get("terrain_speed_channel", 0)
		)), 0), category_mask
	))
	if profile_handle != INVALID_HANDLE:
		_crowd.call(&"set_agent_profile", agent_handle, profile_handle)
		_crowd.call(&"remove_profile", profile_handle)
	if _crowd.has_method(&"set_agent_collision_offset"):
		var collision_offset: Vector2 = current.get(
			"collision_offset", Vector2.ZERO
		) as Vector2
		if profile.has("foot_offset_y"):
			collision_offset.y = float(profile["foot_offset_y"])
		_crowd.call(
			&"set_agent_collision_offset", agent_handle,
			collision_offset
		)
	if _crowd.has_method(&"set_agent_avoidance_profile"):
		_crowd.call(
			&"set_agent_avoidance_profile", agent_handle,
			maxf(float(profile.get(
				"crowd_push_strength", current.get("avoidance_push_strength", 1.0)
			)), 0.0),
			maxf(float(profile.get(
				"crowd_resist_strength", current.get("avoidance_resistance", 1.0)
			)), 0.001)
		)
	if _crowd.has_method(&"set_agent_impulse_resistance"):
		_crowd.call(
			&"set_agent_impulse_resistance", agent_handle,
			maxf(float(profile.get(
				"smash_resist", current.get("impulse_resistance", 1.0)
			)), 0.001)
		)
	if _crowd.has_method(&"set_agent_query_shape"):
		var query_offset: Vector2 = current.get(
			"query_shape_offset", Vector2.ZERO
		) as Vector2
		if profile.has("fight_offset_y"):
			query_offset.y = float(profile["fight_offset_y"])
		var query_half_extents: Vector2 = current.get(
			"query_shape_half_extents", Vector2.ZERO
		) as Vector2
		if profile.has("fight_half_w"):
			query_half_extents.x = maxf(float(profile["fight_half_w"]), 0.0)
		if profile.has("fight_half_h"):
			query_half_extents.y = maxf(float(profile["fight_half_h"]), 0.0)
		_crowd.call(
			&"set_agent_query_shape", agent_handle,
			query_offset, query_half_extents
		)
	_crowd.call(
		&"set_agent_contact_profile", agent_handle,
		maxf(float(profile.get(
			"contact_push_power", current.get("contact_push_strength", 0.0)
		)), 0.0),
		maxf(float(profile.get(
			"contact_push_resist", current.get("contact_push_resistance", 1.0)
		)), 0.0001),
		maxf(float(profile.get(
			"contact_push_cooldown", current.get("contact_push_cooldown", 0.2)
		)), 0.0),
		maxf(float(profile.get(
			"contact_push_friction_loss", current.get("contact_impulse_decay", 0.65)
		)), 0.0),
		maxf(float(profile.get(
			"contact_control_suppression_seconds",
			current.get("contact_control_suppression", 0.2)
		)), 0.0),
		bool(profile.get(
			"contact_push_shows_control_impaired_feedback",
			current.get("contact_feedback_enabled", true)
		))
	)


func set_agent_position(agent_handle: int, position: Vector2, clear_velocity: bool = true) -> void:
	if _crowd != null:
		_crowd.call(&"set_agent_position", agent_handle, position, clear_velocity)


func get_agent_position(agent_handle: int) -> Vector2:
	return _crowd.call(&"get_agent_position", agent_handle) as Vector2 if _crowd != null else Vector2.ZERO


func get_agent_velocity(agent_handle: int) -> Vector2:
	return _crowd.call(&"get_agent_velocity", agent_handle) as Vector2 if _crowd != null else Vector2.ZERO


func set_paused(paused: bool) -> void:
	if _crowd != null:
		_crowd.call(&"set_world_paused", paused)


func set_terrain_speed_cell(cell: Vector2i, multiplier: float, channel: int = 0) -> void:
	if _crowd != null:
		_crowd.call(&"set_terrain_speed_cell", cell, multiplier, channel)


func set_terrain_speed_cells(cells: PackedVector2Array, multipliers: Variant, channel: int = 0) -> void:
	if _crowd == null:
		return
	var converted: PackedFloat64Array = PackedFloat64Array()
	for value: Variant in multipliers:
		converted.append(float(value))
	_crowd.call(&"set_terrain_speed_cells", cells, converted, channel)


func clear_terrain_speed_cell(cell: Vector2i, channel: int = 0) -> void:
	if _crowd != null:
		_crowd.call(&"clear_terrain_speed_cell", cell, channel)


func clear_terrain_speed_cells(cells: PackedVector2Array, channel: int = 0) -> void:
	if _crowd != null:
		_crowd.call(&"clear_terrain_speed_cells", cells, channel)


func replace_terrain_speed_channel(cells: PackedVector2Array, multipliers: Variant, channel: int = 0) -> void:
	if _crowd == null:
		return
	var converted: PackedFloat64Array = PackedFloat64Array()
	for value: Variant in multipliers:
		converted.append(float(value))
	_crowd.call(&"replace_terrain_speed_channel", cells, converted, channel)


func clear_terrain_speed_channel(channel: int = 0) -> void:
	if _crowd != null:
		_crowd.call(&"clear_terrain_speed_channel", channel)


func register_static_obstacle(obstacle_id: int, position: Vector2, radius: float, push_strength: float = 1.0) -> void:
	if _crowd == null:
		return
	var handle: int = int(_obstacle_handles.get(obstacle_id, INVALID_HANDLE))
	if handle == INVALID_HANDLE:
		handle = int(_crowd.call(&"create_static_obstacle", position, radius, push_strength))
		_obstacle_handles[obstacle_id] = handle
	else:
		_crowd.call(&"update_static_obstacle", handle, position, radius, push_strength)


func unregister_static_obstacle(obstacle_id: int) -> void:
	var handle: int = int(_obstacle_handles.get(obstacle_id, INVALID_HANDLE))
	if handle != INVALID_HANDLE and _crowd != null:
		_crowd.call(&"remove_static_obstacle", handle)
	_obstacle_handles.erase(obstacle_id)


func clear_static_obstacles() -> void:
	if _crowd != null:
		_crowd.call(&"clear_static_obstacles")
	_obstacle_handles.clear()


func get_static_obstacle_count() -> int:
	return int(_crowd.call(&"get_static_obstacle_count")) if _crowd != null else 0


func set_directional_cell_field(field_id: int, origin: Vector2, cell_size: float, speed: float, cells: PackedVector2Array, directions: PackedVector2Array, sample_offset: Vector2 = Vector2.ZERO, sample_radius: float = 0.0) -> void:
	if _crowd == null:
		return
	var handle: int = int(_directional_handles.get(field_id, INVALID_HANDLE))
	if handle == INVALID_HANDLE:
		handle = int(_crowd.call(&"create_directional_motion_field", origin, cell_size, speed, cells, directions, sample_offset, sample_radius))
		_directional_handles[field_id] = handle
	else:
		_crowd.call(&"update_directional_motion_field", handle, origin, cell_size, speed, cells, directions, sample_offset, sample_radius)


func clear_directional_cell_field(field_id: int) -> void:
	var handle: int = int(_directional_handles.get(field_id, INVALID_HANDLE))
	if handle != INVALID_HANDLE and _crowd != null:
		_crowd.call(&"remove_directional_motion_field", handle)
	_directional_handles.erase(field_id)


func clear_directional_cell_fields() -> void:
	if _crowd != null:
		_crowd.call(&"clear_directional_motion_fields")
	_directional_handles.clear()


func bind_phase_directional_cell_field(phase: int, field_id: int) -> void:
	_directional_field_by_phase[phase] = field_id


func clear_phase_directional_cell_field(phase: int) -> void:
	_directional_field_by_phase.erase(phase)


func set_agent_phase(agent_handle: int, phase: int, eating_seconds: float = 0.0) -> void:
	if _registry != null:
		var state: Dictionary = _registry.get_project_state(agent_handle)
		state["phase"] = phase
		state["eating_seconds"] = eating_seconds
		_registry.set_project_state(agent_handle, state)
	if _crowd == null:
		return
	if _crowd.has_method(&"set_agent_forces_enabled"):
		_crowd.call(&"set_agent_forces_enabled", agent_handle, phase != 7)
	if not _directional_field_by_phase.has(phase):
		var diagnostics: Dictionary = _crowd.call(&"get_agent_diagnostics", agent_handle) as Dictionary
		if int(diagnostics.get("navigation_source", 0)) == 4:
			_crowd.call(&"stop_navigation", agent_handle)
		return
	var field_id: int = int(_directional_field_by_phase[phase])
	var handle: int = int(_directional_handles.get(field_id, INVALID_HANDLE))
	if handle != INVALID_HANDLE:
		_crowd.call(&"follow_directional_motion_field", agent_handle, handle)


func create_external_velocity_source() -> int:
	return int(_crowd.call(&"create_external_velocity_source")) if _crowd != null else INVALID_HANDLE


func set_agent_external_velocity(agent_handle: int, source_handle: int, velocity: Vector2, response_seconds: float, expiry_seconds: float) -> void:
	if _crowd != null:
		_crowd.call(&"refresh_external_velocity", agent_handle, source_handle, velocity, response_seconds, expiry_seconds)


func release_agent_external_velocity(agent_handle: int, source_handle: int) -> void:
	if _crowd != null:
		_crowd.call(&"release_external_velocity", agent_handle, source_handle)


func spawn_aoe_zone(position: Vector2, direction: Vector2, radius: float, angle_degrees: float, duration: float, force: float, friction: float, falloff: float, detach_flow: bool, control_suppression: float, control_suppression_duration: float, ignored_agent_handle: int, category_mask: int, follow_offset: Vector2, damage: int) -> int:
	if _crowd == null:
		return INVALID_HANDLE
	var config: Dictionary = {
		"position": position,
		"direction": direction,
		"radius": radius,
		"angle_degrees": angle_degrees,
		"duration": duration,
		"tick_interval": 0.0,
		"category_mask": category_mask,
		"ignored_agent_handle": ignored_agent_handle,
		"followed_agent_handle": ignored_agent_handle,
		"follow_offset": follow_offset,
		"caller_token": 0,
	}
	var handle: int = int(_crowd.call(&"create_effect_volume", config))
	if handle != INVALID_HANDLE:
		_effect_configs[handle] = {
			"origin": position, "radius": radius,
			"remaining": duration,
			"followed_agent_handle": ignored_agent_handle,
			"follow_offset": follow_offset,
			"direction": direction.normalized(),
			"radial": angle_degrees >= 359.9,
			"force": force, "decay": maxf(friction, 0.0),
			"falloff": falloff, "preserve_navigation": not detach_flow,
			"control_suppression": control_suppression_duration if control_suppression > 0.0 else 0.0,
			"damage": damage,
		}
	return handle


func apply_projectile_effect(impact: Dictionary, config: Dictionary) -> void:
	var hit_handle: int = int(impact.get("hit_agent_handle", INVALID_HANDLE))
	var position: Vector2 = impact.get("position", Vector2.ZERO) as Vector2
	var handles: PackedInt64Array = PackedInt64Array()
	var radius: float = float(config.get("aoe_radius", config.get("radius", 0.0)))
	var direct_hit_only: bool = bool(config.get("direct_hit_only", false))
	if direct_hit_only and hit_handle != INVALID_HANDLE:
		handles.append(hit_handle)
	elif radius > 0.0 and _crowd != null:
		handles = _crowd.call(&"query_agents_in_circle", position, radius, int(config.get("target_category_mask", -1)), int(impact.get("owner_agent_handle", INVALID_HANDLE))) as PackedInt64Array
	var effect: Dictionary = {
			"origin": position,
			"direction": impact.get("direction", Vector2.RIGHT),
			"radial": false,
			"force": float(config.get("smash_force", 0.0)),
			"decay": float(config.get("smash_friction_loss", 0.0)),
			"falloff": float(config.get("smash_falloff", 0.0)),
			"preserve_navigation": not bool(config.get("smash_detach_flow", false)),
			"control_suppression": float(config.get("smash_control_suppression_duration", 0.0)) if float(config.get("smash_control_suppression", 0.0)) > 0.0 else 0.0,
			"damage": int(config.get("damage", 0)),
			"radius": radius,
		}
	if direct_hit_only:
		effect["falloff"] = 0.0
	if bool(config.get("smash_budget_enabled", false)) and not direct_hit_only:
		_apply_budgeted_projectile_effect(handles, hit_handle, position, effect)
		return
	for agent_handle: int in handles:
		_apply_gameplay_effect(agent_handle, position, effect)


func _apply_budgeted_projectile_effect(
	handles: PackedInt64Array, direct_hit_handle: int,
	origin: Vector2, effect: Dictionary
) -> void:
	var direction: Vector2 = (effect.get("direction", Vector2.RIGHT) as Vector2).normalized()
	if direction == Vector2.ZERO:
		direction = Vector2.RIGHT
	var candidates: Array[Dictionary] = []
	for agent_handle: int in handles:
		var metrics: Dictionary = _query_shape_metrics(agent_handle, origin, direction)
		if metrics.is_empty():
			continue
		metrics["agent_handle"] = agent_handle
		metrics["direct_hit"] = agent_handle == direct_hit_handle
		candidates.append(metrics)
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if bool(a["direct_hit"]) != bool(b["direct_hit"]):
			return bool(a["direct_hit"])
		if float(a["leading_edge"]) != float(b["leading_edge"]):
			return float(a["leading_edge"]) < float(b["leading_edge"])
		if float(a["lateral_distance"]) != float(b["lateral_distance"]):
			return float(a["lateral_distance"]) < float(b["lateral_distance"])
		return int(a["agent_handle"]) < int(b["agent_handle"])
	)
	var total_force: float = maxf(float(effect.get("force", 0.0)), 0.0)
	var remaining_force: float = total_force
	var radius: float = maxf(float(effect.get("radius", 0.0)), 0.001)
	var falloff: float = maxf(float(effect.get("falloff", 0.0)), 0.0)
	for candidate: Dictionary in candidates:
		var distance: float = float(candidate["distance"])
		var attenuation: float = pow(maxf(0.0, 1.0 - distance / radius), falloff)
		var allocated_force: float = minf(total_force * attenuation, remaining_force)
		var allocated_effect: Dictionary = effect.duplicate()
		allocated_effect["force"] = maxf(allocated_force, 0.0)
		allocated_effect["falloff"] = 0.0
		_apply_gameplay_effect(int(candidate["agent_handle"]), origin, allocated_effect)
		remaining_force = maxf(remaining_force - allocated_force, 0.0)


func _query_shape_metrics(
	agent_handle: int, origin: Vector2, direction: Vector2
) -> Dictionary:
	if _crowd == null:
		return {}
	var diagnostics: Dictionary = _crowd.call(
		&"get_agent_diagnostics", agent_handle
	) as Dictionary
	if not bool(diagnostics.get("valid", false)) \
			or not bool(diagnostics.get("forces_enabled", true)):
		return {}
	var center: Vector2 = (diagnostics.get("position", Vector2.ZERO) as Vector2) \
		+ (diagnostics.get("query_shape_offset", Vector2.ZERO) as Vector2)
	var half_extents: Vector2 = diagnostics.get(
		"query_shape_half_extents", Vector2.ZERO
	) as Vector2
	if half_extents == Vector2.ZERO:
		half_extents = Vector2.ONE * float(diagnostics.get("radius", 0.0))
	var offset: Vector2 = center - origin
	var outside: Vector2 = Vector2(
		maxf(absf(offset.x) - half_extents.x, 0.0),
		maxf(absf(offset.y) - half_extents.y, 0.0)
	)
	return {
		"distance": outside.length(),
		"leading_edge": offset.dot(direction) \
			- absf(direction.x) * half_extents.x \
			- absf(direction.y) * half_extents.y,
		"lateral_distance": absf(offset.x * direction.y - offset.y * direction.x),
	}


func take_damage_events() -> Array:
	var result: Array = _damage_events
	_damage_events = []
	return result


func get_agents_in_map_cell(cell: Vector2i) -> Array:
	var result: Array = []
	if _crowd == null or _navigation == null:
		return result
	var handles: PackedInt64Array = _crowd.call(&"get_agents_in_navigation_cell", _navigation, cell) as PackedInt64Array
	for agent_handle: int in handles:
		var velocity: Vector2 = get_agent_velocity(agent_handle)
		result.append({"id": agent_handle, "dir_code": _direction_code(velocity), "is_moving": velocity.length_squared() > 0.01, "velocity_len": velocity.length()})
	return result


func get_agent_debug_snapshot(agent_handle: int) -> Dictionary:
	if _crowd == null:
		return {}
	var result: Dictionary = _crowd.call(&"get_agent_diagnostics", agent_handle) as Dictionary
	if not bool(result.get("valid", false)):
		return {}
	var state: Dictionary = _registry.get_project_state(agent_handle) if _registry != null else {}
	result.merge(state, true)
	result["group"] = _registry.cohort_for_agent(agent_handle) if _registry != null else 0
	result["waiting_flow_group"] = int(state.get("waiting_flow_cohort", 0))
	result["path_active"] = int(result.get("navigation_source", 0)) == 2
	result["path_arrived"] = int(result.get("route_progress", 0)) == 2
	return result


func _apply_gameplay_effect(agent_handle: int, origin: Vector2, config: Dictionary) -> void:
	if agent_handle == INVALID_HANDLE or _crowd == null:
		return
	if _registry != null and int(_registry.get_project_state(agent_handle).get(
		"phase", 0
	)) == 7:
		return
	var position: Vector2 = get_agent_position(agent_handle)
	var radius: float = maxf(float(config.get("radius", 1.0)), 1.0)
	var direction: Vector2 = (position - origin).normalized() if bool(config.get("radial", true)) else (config.get("direction", Vector2.RIGHT) as Vector2).normalized()
	if direction == Vector2.ZERO:
		direction = Vector2.RIGHT
	var metrics: Dictionary = _query_shape_metrics(agent_handle, origin, direction)
	if metrics.is_empty():
		return
	var distance: float = float(metrics.get("distance", position.distance_to(origin)))
	var attenuation: float = pow(maxf(0.0, 1.0 - distance / radius), maxf(float(config.get("falloff", 0.0)), 0.0))
	var force: float = maxf(float(config.get("force", 0.0)), 0.0) * attenuation
	if force > 0.0:
		_crowd.call(&"apply_impulse", agent_handle, direction * force, 0.0, maxf(float(config.get("decay", 0.0)), 0.0), maxf(float(config.get("control_suppression", 0.0)), 0.0), bool(config.get("preserve_navigation", true)), GAMEPLAY_IMPULSE_PRIORITY, true)
	var damage: int = int(config.get("damage", 0))
	if damage > 0:
		_damage_events.append({"agent_id": agent_handle, "damage": damage, "position": position})


func _age_effect_configs(delta: float) -> void:
	var expired: Array[int] = []
	for raw_handle: Variant in _effect_configs:
		var handle: int = int(raw_handle)
		var config: Dictionary = _effect_configs[handle] as Dictionary
		config["remaining"] = float(config.get("remaining", 0.0)) - maxf(delta, 0.0)
		_effect_configs[handle] = config
		if float(config["remaining"]) <= -0.1:
			expired.append(handle)
	for handle: int in expired:
		_effect_configs.erase(handle)


func _direction_code(velocity: Vector2) -> int:
	if velocity.length_squared() <= 0.01:
		return -1
	if absf(velocity.x) > absf(velocity.y):
		return 1 if velocity.x > 0.0 else 3
	return 2 if velocity.y > 0.0 else 0


func _category_for_node(node: Node2D) -> int:
	if node == null:
		return 2
	if node.is_in_group(&"player"):
		return 1
	if node.is_in_group(&"monsters") or node.is_in_group(&"clients") or node.is_in_group(&"villagers"):
		return 4
	return 2


func _set_debug_value(key: StringName, value: Variant) -> void:
	_debug_values[key] = value


func set_debug_disable_all_debug(value: bool) -> void: _set_debug_value(&"disable_all", value)
func set_debug_draw_world_hitbox(value: bool) -> void: _set_debug_value(&"world_hitbox", value)
func set_debug_draw_fight_hitbox(value: bool) -> void: _set_debug_value(&"fight_hitbox", value)
func set_debug_draw_bottleneck_zones(value: bool) -> void: _set_debug_value(&"bottleneck_zones", value)
func set_debug_disable_bottlenecks(value: bool) -> void: _set_debug_value(&"disable_bottlenecks", value)
func set_debug_show_agent_state_labels(value: bool) -> void: _set_debug_value(&"agent_labels", value)
func set_debug_redraw_interval(value: float) -> void: _set_debug_value(&"redraw_interval", value)
func set_debug_static_obstacles(value: bool) -> void: _set_debug_value(&"static_obstacles", value)
