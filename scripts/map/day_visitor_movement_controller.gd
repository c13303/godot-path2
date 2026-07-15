extends RefCounted
class_name DayVisitorMovementController

const AGENT_SCENE: PackedScene = preload("res://scenes/entities/character.tscn")
const IDLE_GROUP: int = 0
const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)
const REPATH_START_SEARCH_RADIUS: int = 4

var _manager: BuildingManager
var _diagnostic_label: String = "day visitor"
var _agent_kind: StringName = &""
var _scene_group: StringName = &""
var _active: bool = false
var _agent: Node2D
var _nav_id: int = -1
var _source_spawner_cell: Vector2i = INVALID_CELL
var _spawn_cell: Vector2i = INVALID_CELL
var _target_cell: Vector2i = INVALID_CELL
var _waiting: bool = false
var _leaving: bool = false
var _leave_at_night_pending: bool = false


func setup(manager: BuildingManager, diagnostic_label: String) -> void:
	_manager = manager
	_diagnostic_label = diagnostic_label


func spawn(
		spawner_cell: Vector2i,
		spawn_cell: Vector2i,
		destination_cell: Vector2i,
		agent_kind: StringName,
		scene_group: StringName,
		tracking_category: StringName,
		visual_setup: Callable
) -> bool:
	clear(false)
	var agent_manager: Node = _agent_manager()
	if agent_manager == null or not agent_manager.has_method("spawn_agent") or not agent_manager.has_method("assign_agent_path"):
		return false
	if spawn_cell == INVALID_CELL or destination_cell == INVALID_CELL:
		return false
	var starts_at_destination: bool = spawn_cell == destination_cell
	var path_cells: PackedVector2Array = PackedVector2Array()
	if not starts_at_destination:
		path_cells = _manager.find_path_on_walkable_map(spawn_cell, destination_cell)
	if not starts_at_destination and path_cells.is_empty():
		push_warning("BuildingManager: %s cannot path from %s to target %s." % [_diagnostic_label, spawn_cell, destination_cell])
		return false
	var agent: Node2D = AGENT_SCENE.instantiate() as Node2D
	var configured_parent: Node = _parent_for_agents()
	var parent: Node = configured_parent if configured_parent != null else _manager.get_tree().current_scene
	if parent == null:
		agent.queue_free()
		return false
	parent.add_child(agent)
	agent.global_position = _manager.cell_center(spawn_cell)
	agent.z_index = int(agent.global_position.y)
	agent.add_to_group(scene_group)
	_manager.register_runtime_agent(agent, tracking_category)
	agent.set_meta("agent_kind", agent_kind)
	agent.set_meta("spawner_cell", spawner_cell)
	visual_setup.call(agent)
	var agent_nav_id: int = int(agent_manager.call("spawn_agent", agent, IDLE_GROUP))
	agent.set("nav_id", agent_nav_id)
	if agent_manager.has_method("set_agent_never_rest"):
		agent_manager.call("set_agent_never_rest", agent_nav_id, true)
	if not starts_at_destination:
		var path_world: PackedVector2Array = _manager.path_cells_to_world(path_cells, agent_nav_id, true)
		agent_manager.call("assign_agent_path", agent_nav_id, path_world)
	_agent_kind = agent_kind
	_scene_group = scene_group
	_active = true
	_agent = agent
	_nav_id = agent_nav_id
	_source_spawner_cell = spawner_cell
	_spawn_cell = spawn_cell
	_target_cell = destination_cell
	_waiting = starts_at_destination
	_leaving = false
	_leave_at_night_pending = false
	if not starts_at_destination and agent.has_method("start_astar_in"):
		agent.call("start_astar_in")
	return true


func is_active() -> bool:
	return _active and is_instance_valid(_agent)


func is_waiting() -> bool:
	return is_active() and _waiting


func is_leaving() -> bool:
	return is_active() and _leaving


func agent_node() -> Node2D:
	return _agent if is_instance_valid(_agent) else null


func target_cell() -> Vector2i:
	return _target_cell


func source_spawner_cell() -> Vector2i:
	return _source_spawner_cell


func get_agent_world_position() -> Vector2:
	if is_instance_valid(_agent):
		return _agent.global_position
	return Vector2.ZERO


func nav_id() -> int:
	return _nav_id


func owns_agent(agent: Node2D) -> bool:
	return agent != null and agent == _agent


func process_arrival() -> bool:
	if not _active or _waiting or _leaving:
		return false
	if not is_instance_valid(_agent):
		clear(false)
		return false
	var agent_manager: Node = _agent_manager()
	if _nav_id < 0 or not (agent_manager != null and agent_manager.has_method("agent_path_arrived")):
		return false
	if not bool(agent_manager.call("agent_path_arrived", _nav_id)):
		return false
	if agent_manager.has_method("detach_agent_path"):
		agent_manager.call("detach_agent_path", _nav_id)
	if _agent.has_method("stop_astar_in"):
		_agent.call("stop_astar_in")
	_waiting = true
	return true


func mark_leave_pending() -> void:
	_leave_at_night_pending = _active and is_instance_valid(_agent)


func start_pending_leave_if_needed() -> void:
	if _leave_at_night_pending:
		start_leave_for_night()


func request_leave() -> void:
	if not _active or not is_instance_valid(_agent):
		clear(false)
		return
	if not GameState.is_night:
		return
	start_leave_for_night()


func start_leave_for_night() -> void:
	if not _active:
		_leave_at_night_pending = false
		return
	if not is_instance_valid(_agent):
		_leave_at_night_pending = false
		clear(false)
		return
	if GameState.is_night and not _manager.is_night_preparation_ready():
		_leave_at_night_pending = true
		return
	_leave_at_night_pending = false
	_leaving = true
	_waiting = false
	if not _manager.assign_agent_to_escape(_agent):
		_manager.remove_dead_monster(_agent, false)


func repath_to_current_target() -> bool:
	return repath_to_target(_target_cell)


func repath_to_target(destination_cell: Vector2i) -> bool:
	if not _active or _leaving:
		return false
	if not is_instance_valid(_agent):
		return false
	var agent_manager: Node = _agent_manager()
	if _nav_id < 0 or agent_manager == null or not agent_manager.has_method("assign_agent_path"):
		return false
	var floorz: TileMapLayer = _floorz()
	if floorz == null or destination_cell == INVALID_CELL or not _manager.is_walkable_cell(destination_cell):
		return false
	var current_cell: Vector2i = floorz.local_to_map(floorz.to_local(_agent.global_position))
	if not _manager.is_walkable_cell(current_cell):
		current_cell = _nearest_walkable_cell(current_cell, REPATH_START_SEARCH_RADIUS)
		if current_cell == INVALID_CELL:
			return false
	var path_cells: PackedVector2Array = _manager.find_path_on_walkable_map(current_cell, destination_cell)
	if path_cells.is_empty():
		return false
	var path_world: PackedVector2Array = _manager.path_cells_to_world(path_cells, _nav_id, true)
	agent_manager.call("assign_agent_path", _nav_id, path_world)
	_target_cell = destination_cell
	_waiting = false
	if _agent.has_method("start_astar_in"):
		_agent.call("start_astar_in")
	return true


func clear(free_agent: bool) -> void:
	if free_agent and is_instance_valid(_agent):
		_manager.remove_dead_monster(_agent, false)
	_reset_state()


func forget_agent() -> void:
	_reset_state()


func _nearest_walkable_cell(start_cell: Vector2i, max_radius: int) -> Vector2i:
	if _manager.is_walkable_cell(start_cell):
		return start_cell
	for radius: int in range(1, max_radius + 1):
		for y: int in range(start_cell.y - radius, start_cell.y + radius + 1):
			for x: int in range(start_cell.x - radius, start_cell.x + radius + 1):
				if abs(x - start_cell.x) != radius and abs(y - start_cell.y) != radius:
					continue
				var candidate: Vector2i = Vector2i(x, y)
				if _manager.is_walkable_cell(candidate):
					return candidate
	return INVALID_CELL


func _reset_state() -> void:
	_active = false
	_agent = null
	_nav_id = -1
	_source_spawner_cell = INVALID_CELL
	_spawn_cell = INVALID_CELL
	_target_cell = INVALID_CELL
	_waiting = false
	_leaving = false
	_leave_at_night_pending = false


func _agent_manager() -> Node:
	return _manager.get_agent_manager() if _manager != null else null


func _floorz() -> TileMapLayer:
	return _manager.get_floorz() if _manager != null else null


func _parent_for_agents() -> Node:
	return _manager.get_parent_for_agents() if _manager != null else null
