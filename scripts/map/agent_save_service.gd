extends RefCounted
class_name AgentSaveService

# Owns save/load snapshots for live runtime agents. It deliberately stores
# gameplay intent, not native steering internals: load recreates agents stopped,
# then reattaches them to freshly rebuilt navigation from their saved state.

const AGENT_SCENE: PackedScene = preload("res://scenes/entities/character.tscn")
const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)
const IDLE_GROUP: int = 0
const SPAWNER_KIND_MONSTER: StringName = &"monster"
const SPAWNER_KIND_CLIENT: StringName = &"client"
const SPAWNER_KIND_MERCHANT: StringName = &"merchant"
const SPAWNER_KIND_BUILDER: StringName = &"builder"

var _manager: BuildingManager


func setup(manager: BuildingManager) -> void:
	_manager = manager


func serialize_state() -> Dictionary:
	var agents: Array[Dictionary] = _serialize_live_agents()
	var spawn_tick_state: Dictionary = _manager.get_spawn_tick_controller().serialize_state()
	var spawn_playlist_state: Dictionary = _manager.get_spawn_playlist_controller().serialize_state()
	if not GameState.is_night:
		agents = _discard_day_phase_monster_agent_data(agents, "save")
		if _has_active_day_phase_spawn_state(spawn_tick_state, spawn_playlist_state):
			CppDebugOptions.save_log("[SAVE] AgentSaveService: discarded day-phase night spawn state during save")
		spawn_tick_state = {}
		spawn_playlist_state = {}
	return {
		"agents": agents,
		"sheep": _manager.get_sheep_controller().serialize_state(),
		"client_sale": _manager.get_client_sale_controller().serialize_state(),
		"spawn_tick": spawn_tick_state,
		"spawn_playlist": spawn_playlist_state,
		# Not part of the day-phase spawn-state discard above: the one-shot reveal latches
		# describe the whole run, so they must survive a day save just like a night one.
		"spawner_reveal": _manager.get_spawner_reveal_phase_controller().serialize_state(),
		"fundamental_builder_onboarding": _manager.serialize_fundamental_builder_onboarding(),
		"night_preparation_ready": _manager.is_night_preparation_ready(),
	}


func restore_state(data: Dictionary, navigation_prepared: bool = false) -> void:
	_clear_existing_agents()
	if not navigation_prepared:
		_prepare_navigation_for_restore()
	var spawn_playlist_state: Dictionary = {}
	var spawn_tick_state: Dictionary = {}
	if GameState.is_night:
		spawn_playlist_state = _dict_from_value(data.get("spawn_playlist", {}))
		spawn_tick_state = _dict_from_value(data.get("spawn_tick", {}))
	_manager.get_spawn_playlist_controller().restore_state(spawn_playlist_state)
	_manager.get_spawn_tick_controller().restore_state(spawn_tick_state)
	_manager.get_client_sale_controller().restore_state(_dict_from_value(data.get("client_sale", {})))
	# Restored last-word on the reveal latches: the night/client preparation that ran before
	# this restore may itself have requested (and so consumed) a reveal, and the saved run is
	# what decides whether the one-shot cutscenes are still pending.
	_manager.get_spawner_reveal_phase_controller().restore_state(_dict_from_value(data.get("spawner_reveal", {})))
	_manager.restore_fundamental_builder_onboarding(_dict_from_value(data.get("fundamental_builder_onboarding", {})))
	var restored_agents: Array[Dictionary] = []
	var agents: Array[Dictionary] = _agent_data_array(data.get("agents", []))
	agents = _discard_merchant_agent_data(agents, "load")
	agents = _discard_builder_agent_data(agents, "load")
	if not GameState.is_night:
		agents = _discard_day_phase_monster_agent_data(agents, "load")
	for agent_data: Dictionary in agents:
		var agent: Node2D = _restore_agent_node(agent_data)
		if agent == null:
			continue
		restored_agents.append({
			"node": agent,
			"data": agent_data,
		})
	_manager.get_sheep_controller().restore_state(_dict_from_value(data.get("sheep", {})))
	for restored: Dictionary in restored_agents:
		var agent: Node2D = restored["node"] as Node2D
		var agent_data: Dictionary = restored["data"] as Dictionary
		_restore_agent_navigation(agent, agent_data)


func _serialize_live_agents() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var seen_ids: Dictionary = {}
	for group_name: StringName in [&"monsters", &"clients"]:
		for raw_node: Node in _manager.get_tree().get_nodes_in_group(group_name):
			var agent: Node2D = raw_node as Node2D
			if agent == null or not is_instance_valid(agent):
				continue
			var nav_id: int = int(agent.get("nav_id"))
			if nav_id < 0 or seen_ids.has(nav_id):
				continue
			seen_ids[nav_id] = true
			result.append(_serialize_agent(agent, nav_id))
	return result


func _agent_data_array(raw_agents: Variant) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not (raw_agents is Array):
		return result
	for raw_agent_data: Variant in raw_agents as Array:
		if raw_agent_data is Dictionary:
			result.append(raw_agent_data as Dictionary)
	return result


func _discard_day_phase_monster_agent_data(agents: Array[Dictionary], context: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var removed: int = 0
	for agent_data: Dictionary in agents:
		if _agent_data_kind(agent_data) == SPAWNER_KIND_MONSTER:
			removed += 1
			continue
		result.append(agent_data)
	if removed > 0:
		push_error("[%s GAME ERROR] Monster when its day." % context.to_upper())
		CppDebugOptions.save_log("[SAVE] AgentSaveService: discarded %d day-phase monster agent(s) during %s" % [removed, context])
	return result


func _discard_merchant_agent_data(agents: Array[Dictionary], context: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var removed: int = 0
	for agent_data: Dictionary in agents:
		if _agent_data_kind(agent_data) == SPAWNER_KIND_MERCHANT:
			removed += 1
			continue
		result.append(agent_data)
	if removed > 0:
		CppDebugOptions.save_log("[SAVE] AgentSaveService: skipped %d merchant agent(s) during %s" % [removed, context])
	return result


func _discard_builder_agent_data(agents: Array[Dictionary], context: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var removed: int = 0
	for agent_data: Dictionary in agents:
		if _agent_data_kind(agent_data) == SPAWNER_KIND_BUILDER:
			removed += 1
			continue
		result.append(agent_data)
	if removed > 0:
		CppDebugOptions.save_log("[SAVE] AgentSaveService: skipped %d builder agent(s) during %s" % [removed, context])
	return result


func _agent_data_kind(agent_data: Dictionary) -> StringName:
	var kind: StringName = StringName(str(agent_data.get("kind", "")))
	if kind != &"":
		return kind
	var metadata: Dictionary = _dict_from_value(agent_data.get("metadata", {}))
	if metadata.has("agent_kind"):
		return StringName(str(metadata["agent_kind"]))
	return SPAWNER_KIND_MONSTER


func _has_active_day_phase_spawn_state(spawn_tick_state: Dictionary, spawn_playlist_state: Dictionary) -> bool:
	if int(spawn_playlist_state.get("current_night_index", -1)) >= 0:
		return true
	var raw_tracks: Variant = spawn_playlist_state.get("tracks", [])
	if raw_tracks is Array and not (raw_tracks as Array).is_empty():
		return true
	var raw_ready_queue: Variant = spawn_tick_state.get("ready_queue", [])
	if raw_ready_queue is Array and not (raw_ready_queue as Array).is_empty():
		return true
	var raw_legacy_timers: Variant = spawn_tick_state.get("legacy_spawn_timers", [])
	if raw_legacy_timers is Array and not (raw_legacy_timers as Array).is_empty():
		return true
	if int(spawn_tick_state.get("legacy_spawn_limit_this_night", 0)) > 0:
		return true
	if int(spawn_tick_state.get("legacy_spawned_this_night", 0)) > 0:
		return true
	return false


func _serialize_agent(agent: Node2D, nav_id: int) -> Dictionary:
	var position: Vector2 = _agent_position(agent, nav_id)
	var kind: StringName = _agent_kind(agent)
	var data: Dictionary = {
		"kind": String(kind),
		"position": _vector2_to_dict(position),
		"health": int(agent.get("health")),
		"max_health": int(agent.get("max_health")),
		"status": str(agent.get("status")),
		"metadata": _serialize_agent_metadata(agent),
		"phase": _serialize_agent_phase(nav_id),
	}
	if kind == SPAWNER_KIND_MONSTER:
		data["monster_type"] = String(agent.get_meta("monster_type", &"basic")) if agent.has_meta("monster_type") else "basic"
	return data


func _agent_position(agent: Node2D, nav_id: int) -> Vector2:
	var scene: Node = _manager.get_tree().current_scene
	var steering: Node = scene.get_node_or_null("CPP/SteeringSystemNative") if scene != null else null
	if nav_id >= 0 and steering != null and steering.has_method("get_agent_position"):
		var native_position: Vector2 = steering.call("get_agent_position", nav_id) as Vector2
		if _manager._is_finite_world(native_position) and native_position != Vector2.ZERO:
			return native_position
	return agent.global_position


func _serialize_agent_metadata(agent: Node2D) -> Dictionary:
	var result: Dictionary = {}
	var keys: Array[StringName] = [
		&"agent_kind",
		&"monster_type",
		&"spawner_cell",
		&"garden_id",
		&"garden_entry_cell",
		&"roses_eaten",
		&"client_has_rose",
		&"client_rose_visible",
	]
	for key: StringName in keys:
		if not agent.has_meta(key):
			continue
		result[String(key)] = _json_value(agent.get_meta(key))
	return result


func _serialize_agent_phase(nav_id: int) -> Dictionary:
	if _manager._eating_agents.has(nav_id):
		var eating: Dictionary = _manager._eating_agents[nav_id] as Dictionary
		return {
			"kind": "eating",
			"timer": float(eating.get("timer", 0.0)),
			"plant_cell": _cell_to_dict(eating.get("plant_cell", INVALID_CELL) as Vector2i),
			"roses_eaten": int(eating.get("roses_eaten", 0)),
			"held_rose_frame": int(eating.get("held_rose_frame", 0)),
		}
	if _manager._escaping_agents.has(nav_id):
		var escaping: Dictionary = _manager._escaping_agents[nav_id] as Dictionary
		return {
			"kind": "escape",
			"target_cell": _cell_to_dict(escaping.get("target_cell", INVALID_CELL) as Vector2i),
			"spawner_cell": _cell_to_dict(escaping.get("spawner_cell", INVALID_CELL) as Vector2i),
		}
	if _manager._client_counter_agents.has(nav_id):
		var counter: Dictionary = _manager._client_counter_agents[nav_id] as Dictionary
		return {
			"kind": "client_counter",
			"counter_cell": _cell_to_dict(counter.get("counter_cell", INVALID_CELL) as Vector2i),
		}
	if _manager._astar_in_agents.has(nav_id):
		var astar: Dictionary = _manager._astar_in_agents[nav_id] as Dictionary
		return {
			"kind": "astar",
			"plant_cell": _cell_to_dict(astar.get("plant_cell", INVALID_CELL) as Vector2i),
			"spawner_cell": _cell_to_dict(astar.get("spawner_cell", INVALID_CELL) as Vector2i),
			"garden_id": int(astar.get("garden_id", 0)),
		}
	if _manager._entry_path_agents.has(nav_id):
		var entry: Dictionary = _manager._entry_path_agents[nav_id] as Dictionary
		return {
			"kind": "entry",
			"spawner_cell": _cell_to_dict(entry.get("spawner_cell", INVALID_CELL) as Vector2i),
			"garden_id": int(entry.get("garden_id", 0)),
			"entry_cell": _cell_to_dict(entry.get("entry_cell", INVALID_CELL) as Vector2i),
		}
	return {"kind": "retarget"}


# Despawn every monster still on the map, reusing the same native/tracker cleanup as
# the normal agent teardown. Used by BuildingManager's day-phase load safety net;
# monsters must never survive into a day. Returns how many were removed.
func purge_day_phase_monsters() -> int:
	var removed: int = 0
	for raw_node: Node in _manager.get_tree().get_nodes_in_group(&"monsters"):
		var agent: Node2D = raw_node as Node2D
		if agent == null or not is_instance_valid(agent):
			continue
		var nav_id: int = int(agent.get("nav_id"))
		if nav_id >= 0:
			_manager._clear_removed_agent_state(nav_id)
			_manager._unregister_nav_agent(nav_id)
		_manager._unregister_runtime_agent(agent)
		agent.queue_free()
		removed += 1
	return removed


func _clear_existing_agents() -> void:
	# Reset the cell tracker up front so no stale index/queue/over-water state from the
	# pre-load agents survives; the restored agents re-register as they are recreated.
	_manager.get_agent_cell_tracker().clear()
	var seen_ids: Dictionary = {}
	# Villagers covers ordinary residents and the fundamental Builder before it has a house.
	# House-owned villagers still route through the generic removal handler.
	for group_name: StringName in [&"monsters", &"clients", AgentDefinitionService.VILLAGERS_GROUP]:
		for raw_node: Node in _manager.get_tree().get_nodes_in_group(group_name):
			var agent: Node2D = raw_node as Node2D
			if agent == null:
				continue
			var nav_id: int = int(agent.get("nav_id"))
			if nav_id >= 0 and not seen_ids.has(nav_id):
				_manager._clear_removed_agent_state(nav_id)
				_manager._unregister_nav_agent(nav_id)
				seen_ids[nav_id] = true
			_manager._unregister_runtime_agent(agent)
			if agent.is_in_group(&"house_residents"):
				_manager.on_removed_house_resident_agent(agent)
			agent.queue_free()


func _prepare_navigation_for_restore() -> void:
	_manager._scan_buildings()
	_manager._validate_playlist_after_spawner_scan()
	_manager._apply_navigation_topology_rebuild()
	_manager._sync_player_blocking_cells()
	if GameState.is_night or GameState.is_client_phase:
		_manager._rebuild_plant_zone_from_layer()
		_manager._rebuild_exit_wall_escapes()


func _restore_agent_node(data: Dictionary) -> Node2D:
	var kind: StringName = StringName(str(data.get("kind", "monster")))
	var agent: Node2D = AGENT_SCENE.instantiate() as Node2D
	if agent == null:
		return null
	var parent: Node = _manager.parent_for_agents if _manager.parent_for_agents != null else _manager.get_tree().current_scene
	if parent == null:
		agent.queue_free()
		return null
	parent.add_child(agent)
	agent.global_position = _vector2_from_dict(data.get("position", {}))
	agent.z_index = int(agent.global_position.y)
	if kind == SPAWNER_KIND_CLIENT:
		agent.add_to_group("clients")
		_manager._register_runtime_agent(agent, &"clients")
		_manager._apply_client_data(agent)
	else:
		agent.add_to_group("monsters")
		_manager._register_runtime_agent(agent, &"monsters")
		var monster_type: StringName = StringName(str(data.get("monster_type", "basic")))
		_manager._apply_monster_data(agent, monster_type)
	_restore_metadata(agent, _dict_from_value(data.get("metadata", {})))
	agent.set_meta("agent_kind", kind)
	var agent_manager: Node = _manager.get_agent_manager()
	if agent_manager == null or not agent_manager.has_method("spawn_agent"):
		agent.queue_free()
		return null
	var nav_id: int = int(agent_manager.call("spawn_agent", agent, IDLE_GROUP))
	agent.set("nav_id", nav_id)
	if agent_manager.has_method("set_agent_never_rest"):
		agent_manager.call("set_agent_never_rest", nav_id, true)
	if int(data.get("max_health", 0)) > 0:
		agent.set("max_health", int(data.get("max_health", 0)))
	if int(data.get("health", 0)) > 0:
		agent.set("health", int(data.get("health", 0)))
	_manager.get_agent_cell_tracker().refresh_agent(agent)
	return agent


func _restore_agent_navigation(agent: Node2D, data: Dictionary) -> void:
	if agent == null or not is_instance_valid(agent):
		return
	var phase: Dictionary = _dict_from_value(data.get("phase", {}))
	var phase_kind: String = str(phase.get("kind", "retarget"))
	var nav_id: int = int(agent.get("nav_id"))
	var spawner_cell: Vector2i = _cell_from_dict(phase.get("spawner_cell", agent.get_meta("spawner_cell") if agent.has_meta("spawner_cell") else {}))
	match phase_kind:
		"eating":
			_manager.get_agent_navigation_phase_controller().restore_agent_eating(
				agent,
				float(phase.get("timer", 0.0)),
				_cell_from_dict(phase.get("plant_cell", {})),
				int(phase.get("roses_eaten", agent.get_meta("roses_eaten") if agent.has_meta("roses_eaten") else 0)),
				int(phase.get("held_rose_frame", 0))
			)
		"escape":
			if not _manager._assign_agent_to_escape(agent) and agent.has_method("start_waiting_new_status"):
				agent.call("start_waiting_new_status")
		"entry":
			var garden_id: int = int(phase.get("garden_id", agent.get_meta("garden_id") if agent.has_meta("garden_id") else 0))
			var entry_cell: Vector2i = _cell_from_dict(phase.get("entry_cell", {}))
			if not _manager._assign_agent_to_garden_entry_flow(agent, spawner_cell, garden_id, entry_cell):
				_retarget_or_wait(agent, spawner_cell)
		"astar", "client_counter":
			if bool(agent.get_meta("client_has_rose", false)):
				if not _manager._assign_agent_to_escape(agent):
					_retarget_or_wait(agent, spawner_cell)
			elif not _manager._retarget_agent_or_escape(agent, spawner_cell):
				_retarget_or_wait(agent, spawner_cell)
		_:
			_retarget_or_wait(agent, spawner_cell)
	if nav_id >= 0:
		_manager.set_agent_never_rest(nav_id, true)


func _retarget_or_wait(agent: Node2D, spawner_cell: Vector2i) -> void:
	if _manager._retarget_agent_or_escape(agent, spawner_cell):
		return
	if agent.has_method("start_waiting_new_status"):
		agent.call("start_waiting_new_status")


func _restore_metadata(agent: Node2D, metadata: Dictionary) -> void:
	for raw_key: Variant in metadata.keys():
		var key: StringName = StringName(str(raw_key))
		agent.set_meta(key, _restore_json_value(metadata[raw_key]))


func _dict_from_value(raw_value: Variant) -> Dictionary:
	if raw_value is Dictionary:
		return raw_value as Dictionary
	return {}


func _agent_kind(agent: Node2D) -> StringName:
	if agent.has_meta("agent_kind"):
		return StringName(str(agent.get_meta("agent_kind")))
	if agent.is_in_group("clients"):
		return SPAWNER_KIND_CLIENT
	if agent.is_in_group("merchants"):
		return SPAWNER_KIND_MERCHANT
	return SPAWNER_KIND_MONSTER


func _json_value(value: Variant) -> Variant:
	if value is Vector2i:
		return {"__type": "Vector2i", "x": (value as Vector2i).x, "y": (value as Vector2i).y}
	if value is Vector2:
		return {"__type": "Vector2", "x": (value as Vector2).x, "y": (value as Vector2).y}
	if value is StringName:
		return String(value)
	return value


func _restore_json_value(value: Variant) -> Variant:
	if value is Dictionary:
		var data: Dictionary = value as Dictionary
		var type_name: String = str(data.get("__type", ""))
		if type_name == "Vector2i":
			return Vector2i(int(data.get("x", 0)), int(data.get("y", 0)))
		if type_name == "Vector2":
			return Vector2(float(data.get("x", 0.0)), float(data.get("y", 0.0)))
	return value


func _vector2_to_dict(value: Vector2) -> Dictionary:
	return {"x": value.x, "y": value.y}


func _vector2_from_dict(raw_value: Variant) -> Vector2:
	if raw_value is Dictionary:
		var data: Dictionary = raw_value as Dictionary
		return Vector2(float(data.get("x", 0.0)), float(data.get("y", 0.0)))
	return Vector2.ZERO


func _cell_to_dict(cell: Vector2i) -> Dictionary:
	return {"x": cell.x, "y": cell.y}


func _cell_from_dict(raw_value: Variant) -> Vector2i:
	if raw_value is Vector2i:
		return raw_value as Vector2i
	if raw_value is Dictionary:
		var data: Dictionary = raw_value as Dictionary
		if str(data.get("__type", "")) == "Vector2i":
			return Vector2i(int(data.get("x", INVALID_CELL.x)), int(data.get("y", INVALID_CELL.y)))
		return Vector2i(int(data.get("x", INVALID_CELL.x)), int(data.get("y", INVALID_CELL.y)))
	return INVALID_CELL
