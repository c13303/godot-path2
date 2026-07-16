extends RefCounted
class_name RuntimeSimulationSaveService

# Owns semantic runtime simulation checkpoints. It stores domain resume intent
# only; live agents, native navigation IDs, paths, flow groups, and movement
# timers are deliberately excluded from version-9 saves.

const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)

var _manager: BuildingManager


func setup(manager: BuildingManager) -> void:
	_manager = manager


func capture_state() -> Dictionary:
	var client_result: Dictionary = _manager.get_client_sale_controller().capture_checkpoint()
	if not bool(client_result.get("ok", false)):
		return _failure(str(client_result.get("error", "client-sale checkpoint failed")))
	var spawn_playlist_state: Dictionary = {}
	var spawn_tick_state: Dictionary = {}
	if GameState.is_night:
		var monster_result: Dictionary = _manager.get_agent_navigation_phase_controller().capture_monster_resume_tokens()
		if not bool(monster_result.get("ok", false)):
			return _failure(str(monster_result.get("error", "monster resume checkpoint failed")))
		spawn_playlist_state = _manager.get_spawn_playlist_controller().serialize_state()
		spawn_tick_state = _manager.get_spawn_tick_controller().serialize_state(monster_result.get("tokens", []) as Array)
	else:
		var active_spawn_state: Dictionary = _manager.get_spawn_tick_controller().serialize_state()
		var active_playlist_state: Dictionary = _manager.get_spawn_playlist_controller().serialize_state()
		if _has_active_day_phase_spawn_state(active_spawn_state, active_playlist_state):
			CppDebugOptions.save_log("[SAVE] RuntimeSimulationSaveService: discarded day-phase night spawn state during save")
	return {
		"ok": true,
		"error": "",
		"state": {
			"client_sale": client_result.get("state", {}),
			"night": {
				"spawn_playlist": spawn_playlist_state,
				"spawn_tick": spawn_tick_state,
			},
			"sheep": _manager.get_sheep_controller().serialize_state(),
			"spawner_reveal": _manager.get_spawner_reveal_phase_controller().serialize_state(),
			"fundamental_builder_onboarding": _manager.serialize_fundamental_builder_onboarding(),
		},
	}


func restore_state(data: Dictionary) -> void:
	clear_transient_runtime_agents()
	var night: Dictionary = _dict_from_value(data.get("night", {}))
	var spawn_playlist_state: Dictionary = {}
	var spawn_tick_state: Dictionary = {}
	if GameState.is_night:
		spawn_playlist_state = _dict_from_value(night.get("spawn_playlist", {}))
		spawn_tick_state = _dict_from_value(night.get("spawn_tick", {}))
	_manager.get_spawner_reveal_phase_controller().restore_state(_dict_from_value(data.get("spawner_reveal", {})))
	_manager.get_spawn_playlist_controller().restore_state(spawn_playlist_state)
	_manager.get_spawn_tick_controller().restore_state(spawn_tick_state)
	_manager.get_client_sale_controller().restore_state(_dict_from_value(data.get("client_sale", {})))
	_manager.restore_fundamental_builder_onboarding(_dict_from_value(data.get("fundamental_builder_onboarding", {})))
	_manager.get_sheep_controller().restore_state(_dict_from_value(data.get("sheep", {})))


func clear_transient_runtime_agents() -> void:
	_manager.get_agent_cell_tracker().clear()
	var seen_ids: Dictionary = {}
	for group_name: StringName in [&"monsters", &"clients", AgentDefinitionService.VILLAGERS_GROUP]:
		for raw_node: Node in _manager.get_tree().get_nodes_in_group(group_name):
			var agent: Node2D = raw_node as Node2D
			if agent == null:
				continue
			var nav_id: int = int(agent.get("nav_id"))
			if nav_id >= 0 and not seen_ids.has(nav_id):
				_manager.clear_removed_agent_state(nav_id)
				_manager.unregister_nav_agent(nav_id)
				seen_ids[nav_id] = true
			_manager.unregister_runtime_agent_for_save(agent)
			if agent.is_in_group(&"house_residents"):
				_manager.on_removed_house_resident_agent(agent)
			agent.queue_free()


func purge_day_phase_monsters() -> int:
	var removed: int = 0
	for raw_node: Node in _manager.get_tree().get_nodes_in_group(&"monsters"):
		var agent: Node2D = raw_node as Node2D
		if agent == null or not is_instance_valid(agent):
			continue
		var nav_id: int = int(agent.get("nav_id"))
		if nav_id >= 0:
			_manager.clear_removed_agent_state(nav_id)
			_manager.unregister_nav_agent(nav_id)
		_manager.unregister_runtime_agent_for_save(agent)
		agent.queue_free()
		removed += 1
	return removed


func _has_active_day_phase_spawn_state(spawn_tick_state: Dictionary, spawn_playlist_state: Dictionary) -> bool:
	if int(spawn_playlist_state.get("current_night_index", -1)) >= 0:
		return true
	var raw_tracks: Variant = spawn_playlist_state.get("tracks", [])
	if raw_tracks is Array and not (raw_tracks as Array).is_empty():
		return true
	var raw_ready_queue: Variant = spawn_tick_state.get("ready_queue", [])
	if raw_ready_queue is Array and not (raw_ready_queue as Array).is_empty():
		return true
	var raw_resume: Variant = spawn_tick_state.get("resume_monsters", [])
	if raw_resume is Array and not (raw_resume as Array).is_empty():
		return true
	return false


func _dict_from_value(raw_value: Variant) -> Dictionary:
	if raw_value is Dictionary:
		return raw_value as Dictionary
	return {}


func _failure(error: String) -> Dictionary:
	CppDebugOptions.save_log("[SAVE] RuntimeSimulationSaveService: " + error)
	return {"ok": false, "error": error, "state": {}}
