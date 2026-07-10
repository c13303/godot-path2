extends RefCounted
class_name SheepController

const SHEEP_SCENE: PackedScene = preload("res://scenes/entities/sheep.tscn")
const IDLE_GROUP: int = 0
const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)
const EAT_SECONDS: float = 2.0
const DEBRIS_RESCAN_SECONDS: float = 0.5
const SHEEP_SPEED_SCALE: float = 0.5
const SHEEP_CROWD_RESIST: float = 1.0
const SHEEP_SMASH_RESIST: float = 1.0
const MAX_PATH_TARGET_ATTEMPTS: int = 8
const DEBRIS_REWARD_GEMS: int = 1

var _manager: BuildingManager
var _agent: SheepAgent
var _nav_id: int = -1
var _idle_cell: Vector2i = INVALID_CELL
var _target_cell: Vector2i = INVALID_CELL
var _debris_cells: Dictionary = {}
var _unreachable_debris: Dictionary = {}
var _state: StringName = &"unspawned"
var _eat_timer: float = 0.0
var _rescan_timer: float = 0.0
var _spawn_attempted: bool = false


func setup(manager: BuildingManager) -> void:
	_manager = manager
	_connect_plant_manager()


func on_game_mode_changed(is_night: bool) -> void:
	if is_night:
		_cancel_eating()
		_send_to_idle()
	else:
		_unreachable_debris.clear()


func process(delta: float) -> void:
	if _manager == null:
		return
	if not _ensure_spawned():
		return
	_refresh_debris_index_tick(delta)
	if GameState.is_night:
		_process_night()
		return
	_process_day(delta)


func serialize_state() -> Dictionary:
	if not is_instance_valid(_agent):
		return {"spawned": false}
	return {
		"spawned": true,
		"position": {"x": _agent.global_position.x, "y": _agent.global_position.y},
		"idle_cell": _cell_to_dict(_idle_cell),
		"target_cell": _cell_to_dict(_target_cell),
		"state": String(_state),
		"eat_timer": _eat_timer,
	}


func restore_state(data: Dictionary) -> void:
	if not bool(data.get("spawned", false)):
		return
	if not _ensure_spawned():
		return
	var raw_position: Variant = data.get("position", {})
	if raw_position is Dictionary:
		var position_data: Dictionary = raw_position as Dictionary
		_agent.global_position = Vector2(float(position_data.get("x", _agent.global_position.x)), float(position_data.get("y", _agent.global_position.y)))
		_agent.z_index = int(_agent.global_position.y)
		_manager.get_agent_cell_tracker().refresh_agent(_agent)
	_idle_cell = _cell_from_dict(data.get("idle_cell", _cell_to_dict(_idle_cell)))
	_target_cell = _cell_from_dict(data.get("target_cell", _cell_to_dict(INVALID_CELL)))
	_state = StringName(str(data.get("state", "idle")))
	_eat_timer = maxf(0.0, float(data.get("eat_timer", 0.0)))
	_detach_path()
	match _state:
		&"eating":
			_agent.start_eating(_eat_timer)
		&"moving_to_debris", &"returning_idle":
			if _target_cell != INVALID_CELL and _assign_path_to(_target_cell):
				_start_agent_walking_to_target()
			else:
				_stop_at_idle()
		_:
			_stop_at_idle()


func _cell_to_dict(cell: Vector2i) -> Dictionary:
	return {"x": cell.x, "y": cell.y}


func _cell_from_dict(raw_value: Variant) -> Vector2i:
	if raw_value is Dictionary:
		var data: Dictionary = raw_value as Dictionary
		return Vector2i(int(data.get("x", INVALID_CELL.x)), int(data.get("y", INVALID_CELL.y)))
	return INVALID_CELL


func _ensure_spawned() -> bool:
	if is_instance_valid(_agent):
		return true
	if _spawn_attempted:
		return false
	_spawn_attempted = true
	_idle_cell = _resolve_idle_cell()
	if _idle_cell == INVALID_CELL:
		push_warning("SheepController: no sheep idle marker found; sheep not spawned.")
		return false
	if not _manager.is_sheep_walkable_cell(_idle_cell):
		push_warning("SheepController: sheep idle cell %s is not walkable; sheep not spawned." % str(_idle_cell))
		return false
	var agent_manager: Node = _manager.get_agent_manager()
	if agent_manager == null or not agent_manager.has_method("spawn_agent"):
		return false
	_upload_water_speed_multipliers()
	var parent: Node = _manager.get_parent_for_agents()
	if parent == null:
		parent = _manager.get_tree().current_scene
	if parent == null:
		return false
	var agent: SheepAgent = SHEEP_SCENE.instantiate() as SheepAgent
	if agent == null:
		return false
	parent.add_child(agent)
	agent.global_position = _manager.cell_center(_idle_cell)
	agent.z_index = int(agent.global_position.y)
	agent.add_to_group("sheep")
	# Sheep don't use the desire ground-marker system, so register them with the cell
	# tracker directly (the desire wrapper handles monsters/clients/merchants). Sheep
	# live for the level's lifetime, so there's no runtime unregister path.
	_manager.register_tracked_agent(agent, &"sheep")
	agent.set_meta("agent_kind", &"sheep")
	agent.set_meta("monster_speed_scale", SHEEP_SPEED_SCALE)
	agent.set_meta("monster_crowd_resist", SHEEP_CROWD_RESIST)
	agent.set_meta("monster_smash_resist", SHEEP_SMASH_RESIST)
	var nav_id: int = int(agent_manager.call("spawn_agent", agent, IDLE_GROUP))
	agent.nav_id = nav_id
	if agent_manager.has_method("set_agent_never_rest"):
		agent_manager.call("set_agent_never_rest", nav_id, true)
	_agent = agent
	_nav_id = nav_id
	_state = &"idle"
	agent.start_idle()
	_rebuild_debris_index()
	return true


func _process_day(delta: float) -> void:
	if _state == &"eating":
		_eat_timer -= delta
		if _eat_timer <= 0.0:
			_finish_eating()
		return
	if _state == &"moving_to_debris":
		if not _is_debris_cell(_target_cell):
			_pick_next_day_target()
			return
		_sync_agent_walk_direction_to_target()
		if _agent_path_arrived():
			_start_eating_target()
		return
	if _state == &"returning_idle":
		_sync_agent_walk_direction_to_target()
		if _agent_path_arrived():
			_stop_at_idle()
		return
	_pick_next_day_target()


func _process_night() -> void:
	if _state == &"returning_idle":
		_sync_agent_walk_direction_to_target()
		if _agent_path_arrived():
			_stop_at_idle()
		return
	if _state == &"idle" and _agent_cell() != _idle_cell:
		_send_to_idle()
		return
	if _state != &"idle":
		_send_to_idle()


func _pick_next_day_target() -> void:
	var from_cell: Vector2i = _agent_cell()
	var candidates: Array[Vector2i] = _nearest_debris_candidates(from_cell)
	for debris_cell: Vector2i in candidates:
		if _assign_path_to(debris_cell):
			_target_cell = debris_cell
			_state = &"moving_to_debris"
			_start_agent_walking_to_target()
			return
		_unreachable_debris[debris_cell] = true
	_send_to_idle()


func _send_to_idle() -> void:
	if _idle_cell == INVALID_CELL or not is_instance_valid(_agent):
		return
	if _agent_cell() == _idle_cell:
		_stop_at_idle()
		return
	if _assign_path_to(_idle_cell):
		_target_cell = _idle_cell
		_state = &"returning_idle"
		_start_agent_walking_to_target()


func _stop_at_idle() -> void:
	_detach_path()
	_state = &"idle"
	_target_cell = INVALID_CELL
	if is_instance_valid(_agent):
		_agent.start_idle()


func _start_eating_target() -> void:
	_detach_path()
	_state = &"eating"
	_eat_timer = EAT_SECONDS
	if is_instance_valid(_agent):
		_agent.start_eating(EAT_SECONDS)


func _finish_eating() -> void:
	var eaten_cell: Vector2i = _target_cell
	_cancel_eating()
	if _is_debris_cell(eaten_cell):
		var reward_position: Vector2 = _manager.cell_center(eaten_cell)
		var plantz: TileMapLayer = _manager.get_plantz()
		if plantz != null:
			plantz.erase_cell(eaten_cell)
			plantz.update_internals()
			plantz.queue_redraw()
		_manager.refresh_runtime_cell_speed(eaten_cell)
		_debris_cells.erase(eaten_cell)
		_unreachable_debris.erase(eaten_cell)
		Sfx.play_sound(&"crunsh")
		_spawn_debris_reward_gems(reward_position)
	_pick_next_day_target()


func _start_agent_walking_to_target() -> void:
	if not is_instance_valid(_agent) or _target_cell == INVALID_CELL:
		return
	_agent.start_walking_to(_manager.cell_center(_target_cell) - _agent.global_position)


func _sync_agent_walk_direction_to_target() -> void:
	if not is_instance_valid(_agent) or _target_cell == INVALID_CELL:
		return
	_agent.set_walk_direction(_manager.cell_center(_target_cell) - _agent.global_position)


func _spawn_debris_reward_gems(world_position: Vector2) -> void:
	var scene: Node = _manager.get_tree().current_scene
	var gem_icon: Node = scene.get_node_or_null("GameUI/currenciesUI/gemIcon") if scene != null else null
	if gem_icon != null and gem_icon.has_method("animate_gem_harvest"):
		for i: int in range(DEBRIS_REWARD_GEMS):
			var started: bool = bool(gem_icon.call("animate_gem_harvest", world_position, i))
			if not started:
				_credit_debris_reward_gem()
		return
	for i: int in range(DEBRIS_REWARD_GEMS):
		_credit_debris_reward_gem()


func _credit_debris_reward_gem() -> void:
	var scene: Node = _manager.get_tree().current_scene
	var progression_node: Node = scene.get_node_or_null("progression") if scene != null else null
	if progression_node != null and progression_node.has_method("update_gems"):
		progression_node.call("update_gems", 1)


func _cancel_eating() -> void:
	if _state == &"eating" and is_instance_valid(_agent):
		_agent.stop_eating()
	_state = &"idle" if _state == &"eating" else _state
	_eat_timer = 0.0


func _assign_path_to(cell: Vector2i) -> bool:
	if _nav_id < 0:
		return false
	var from_cell: Vector2i = _agent_cell()
	if from_cell == INVALID_CELL or cell == INVALID_CELL:
		return false
	var path_cells: PackedVector2Array = _manager.find_sheep_path(from_cell, cell)
	if path_cells.is_empty():
		return false
	var path_world: PackedVector2Array = _manager.path_cells_to_world(path_cells, _nav_id, false)
	_manager.detach_agent_flow(_nav_id)
	_manager.assign_agent_path(_nav_id, path_world)
	return true


func _agent_path_arrived() -> bool:
	return _nav_id >= 0 and _manager.agent_path_arrived(_nav_id)


func _detach_path() -> void:
	if _nav_id >= 0:
		_manager.detach_agent_path(_nav_id)


func _agent_cell() -> Vector2i:
	var floorz: TileMapLayer = _manager.get_floorz()
	if floorz == null or not is_instance_valid(_agent):
		return INVALID_CELL
	return floorz.local_to_map(floorz.to_local(_agent.global_position))


func _refresh_debris_index_tick(delta: float) -> void:
	_rescan_timer -= delta
	if _rescan_timer > 0.0:
		return
	_rescan_timer = DEBRIS_RESCAN_SECONDS
	_rebuild_debris_index()


func _rebuild_debris_index() -> void:
	_debris_cells.clear()
	var plantz: TileMapLayer = _manager.get_plantz()
	if plantz == null:
		return
	for raw_cell: Variant in plantz.get_used_cells():
		var cell: Vector2i = raw_cell as Vector2i
		if plantz.get_cell_atlas_coords(cell) == PlantManager.DEBRIS_ATLAS:
			_debris_cells[cell] = true


func _nearest_debris_candidates(from_cell: Vector2i) -> Array[Vector2i]:
	var candidates: Array[Vector2i] = []
	for raw_cell: Variant in _debris_cells.keys():
		var cell: Vector2i = raw_cell as Vector2i
		if _unreachable_debris.has(cell):
			continue
		if not _is_debris_cell(cell):
			continue
		candidates.append(cell)
	candidates.sort_custom(Callable(self, "_sort_debris_by_distance").bind(from_cell))
	if candidates.size() > MAX_PATH_TARGET_ATTEMPTS:
		candidates.resize(MAX_PATH_TARGET_ATTEMPTS)
	return candidates


func _sort_debris_by_distance(a: Vector2i, b: Vector2i, from_cell: Vector2i) -> bool:
	var da: Vector2i = a - from_cell
	var db: Vector2i = b - from_cell
	var da_length_sq: int = da.x * da.x + da.y * da.y
	var db_length_sq: int = db.x * db.x + db.y * db.y
	return da_length_sq < db_length_sq


func _is_debris_cell(cell: Vector2i) -> bool:
	if cell == INVALID_CELL:
		return false
	var plantz: TileMapLayer = _manager.get_plantz()
	return plantz != null and plantz.get_cell_source_id(cell) >= 0 and plantz.get_cell_atlas_coords(cell) == PlantManager.DEBRIS_ATLAS


func _connect_plant_manager() -> void:
	var plant_manager: Node = _manager.get_plant_manager() if _manager != null else null
	if plant_manager == null or not plant_manager.has_signal("plant_removed"):
		return
	var callback: Callable = Callable(self, "_on_plant_removed")
	if not plant_manager.is_connected("plant_removed", callback):
		plant_manager.connect("plant_removed", callback)


func _on_plant_removed(cell: Vector2i) -> void:
	if _is_debris_cell(cell):
		_debris_cells[cell] = true
	else:
		_debris_cells.erase(cell)
		_unreachable_debris.erase(cell)


func _resolve_idle_cell() -> Vector2i:
	var marker: Node2D = _find_sheep_marker()
	if marker == null:
		return INVALID_CELL
	marker.visible = false
	var floorz: TileMapLayer = _manager.get_floorz()
	if floorz == null:
		return INVALID_CELL
	return floorz.local_to_map(floorz.to_local(marker.global_position))


func _upload_water_speed_multipliers() -> void:
	var watersources: WaterSources = _manager.watersources
	var flow: Node = _manager.get_flow()
	if watersources == null or flow == null or not flow.has_method("set_cell_speed_multiplier"):
		return
	var multiplier: float = clampf(watersources.player_slowdown, 0.01, 1.0)
	for raw_cell: Variant in watersources.get_used_cells():
		var cell: Vector2i = raw_cell as Vector2i
		flow.call("set_cell_speed_multiplier", cell, multiplier)


func _find_sheep_marker() -> Node2D:
	var scene: Node = _manager.get_tree().current_scene
	if scene == null:
		return null
	return _find_sheep_marker_recursive(scene)


func _find_sheep_marker_recursive(node: Node) -> Node2D:
	if String(node.name).to_lower() == "sheep" and node is Node2D:
		return node as Node2D
	for child: Node in node.get_children():
		var found: Node2D = _find_sheep_marker_recursive(child)
		if found != null:
			return found
	return null
