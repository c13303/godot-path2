extends RefCounted
class_name BuilderController

signal fundamental_builder_intro_requested(builder_node: Node2D)

const BUILDER_SPOT_CLAIM_RADIUS: int = 6
const FUNDAMENTAL_BUILDER_INTRO_RADIUS_TILES: int = 3
const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)
const AGENT_KIND_BUILDER: StringName = &"builder"
const BUILDER_GROUP: StringName = &"builders"
const VISITOR_CATEGORY: StringName = &"builders"
const FUNDAMENTAL_BUILDER_IN_ID: StringName = &"fundamental_builder_in"
const FUNDAMENTAL_BUILDER_SPOT_ID: StringName = &"fundamental_builder_spot"
const FUNDAMENTAL_BUILDER_OUT_ID: StringName = &"fundamental_builder_out"
const STATE_ENTERING: StringName = &"entering"
const STATE_IDLE: StringName = &"idle"
const STATE_TRAVELLING_TO_WORK: StringName = &"travelling_to_work"
const STATE_WORKING: StringName = &"working"
const STATE_RETURNING_IDLE: StringName = &"returning_idle"
const STATE_RETURNING_HOME: StringName = &"returning_home"
const STATE_EVACUATING: StringName = &"evacuating"
const STATE_LEAVING: StringName = &"leaving"
const STALL_WARNING_SECONDS: float = 4.0
const STALL_WARNING_REPEAT_SECONDS: float = 6.0
const STALL_MOVEMENT_EPSILON_PIXELS: float = 2.0
const LOCAL_WORK_MOVE_MAX_DISTANCE: int = 10
const IDLE_HOME_CHECK_INTERVAL_SECONDS: float = 0.5
const IDLE_HOME_DISPLACEMENT_GRACE_SECONDS: float = 1.0
const IDLE_HOME_RETRY_COOLDOWN_SECONDS: float = 1.0
const IDLE_HOME_DISPLACEMENT_TILE_FACTOR: float = 0.45

var _manager: BuildingManager
var _visitors: Array[DayVisitorMovementController] = []
var _claimed_cells: Dictionary = {}  # Vector2i -> DayVisitorMovementController
var _visitor_ids: Dictionary = {}  # DayVisitorMovementController -> int
var _visitors_by_id: Dictionary = {}  # int -> DayVisitorMovementController
var _state_by_builder_id: Dictionary = {}  # int -> StringName
var _work_house_by_builder_id: Dictionary = {}  # int -> StringName
var _house_id_by_builder_id: Dictionary = {}  # int -> StringName
var _builder_id_by_house_id: Dictionary = {}  # StringName -> int
var _home_cell_by_builder_id: Dictionary = {}  # int -> Vector2i
var _fundamental_builder_id: int = -1
var _next_builder_runtime_id: int = 1
var _last_watch_position_by_builder_id: Dictionary = {}  # int -> Vector2
var _stall_seconds_by_builder_id: Dictionary = {}  # int -> float
var _stall_warning_cooldown_by_builder_id: Dictionary = {}  # int -> float
var _idle_home_check_elapsed: float = 0.0
var _idle_displacement_seconds_by_builder_id: Dictionary = {}  # int -> float
var _idle_return_retry_cooldown_by_builder_id: Dictionary = {}  # int -> float
var _pending_idle_return_by_builder_id: Dictionary = {}  # int -> true
var _fundamental_builder_intro_requested: bool = false


func setup(manager: BuildingManager) -> void:
	_manager = manager


func builder_count() -> int:
	return _builder_id_by_house_id.size()


func active_builder_count() -> int:
	_clean_invalid_visitors()
	return _visitors.size()


func is_any_builder_active() -> bool:
	return active_builder_count() > 0


func set_builder_count(_value: int) -> void:
	pass


func add_builders_for_dev(amount: int = 1) -> bool:
	CppDebugOptions.dlog("dev_keys: Builder roster is house-owned; ignored request for %d extra Builder(s)." % maxi(0, amount))
	return false


func begin_day() -> void:
	clear_active_builders(true)


func on_night_started() -> void:
	for visitor: DayVisitorMovementController in _visitors:
		_release_claim_for(visitor)
		var builder_id: int = _builder_id_for_visitor(visitor)
		if builder_id >= 0:
			_work_house_by_builder_id.erase(builder_id)
			if _house_id_by_builder_id.has(builder_id):
				var home_cell: Vector2i = _builder_home_cell(builder_id)
				if home_cell != INVALID_CELL and visitor.repath_to_target(home_cell):
					_state_by_builder_id[builder_id] = STATE_RETURNING_HOME
					continue
			_state_by_builder_id[builder_id] = STATE_LEAVING
		visitor.mark_leave_pending()


func start_pending_departures() -> void:
	for visitor: DayVisitorMovementController in _visitors.duplicate():
		if visitor == null:
			continue
		visitor.start_pending_leave_if_needed()


func spawn_builder_for_house(house_id: StringName, entrance_cell: Vector2i) -> int:
	if GameState.is_night or house_id == &"" or _builder_id_by_house_id.has(house_id):
		return -1
	var source_cell: Vector2i = _named_spot_cell(FUNDAMENTAL_BUILDER_IN_ID)
	if source_cell == INVALID_CELL:
		push_warning("BuilderController: house-bound Builder cannot enter; required marker '%s' is missing." % String(FUNDAMENTAL_BUILDER_IN_ID))
		return -1
	var spawn_cell: Vector2i = _manager.find_free_cell_near_spawner(source_cell, _manager.occupied_cells_for_spawning())
	if spawn_cell == INVALID_CELL:
		push_warning("BuilderController: house-bound Builder cannot enter; no free spawn cell near %s." % str(source_cell))
		return -1
	var target_cell: Vector2i = _find_claim_near_anchor(entrance_cell, null, spawn_cell, false)
	if target_cell == INVALID_CELL:
		push_warning("BuilderController: no idle cell available for house-bound Builder at %s." % str(entrance_cell))
		return -1
	var visitor: DayVisitorMovementController = DayVisitorMovementController.new()
	visitor.setup(_manager, "house Builder")
	_claimed_cells[target_cell] = visitor
	if not visitor.spawn(
			source_cell,
			spawn_cell,
			target_cell,
			AGENT_KIND_BUILDER,
			BUILDER_GROUP,
			VISITOR_CATEGORY,
			Callable(_manager, "apply_builder_data")
	):
		_claimed_cells.erase(target_cell)
		return -1
	_visitors.append(visitor)
	var builder_id: int = _register_visitor_id(visitor)
	_state_by_builder_id[builder_id] = STATE_ENTERING
	_house_id_by_builder_id[builder_id] = house_id
	_builder_id_by_house_id[house_id] = builder_id
	_home_cell_by_builder_id[builder_id] = entrance_cell
	var agent: Node2D = visitor.agent_node()
	if agent != null:
		agent.set_meta("resident_house_id", house_id)
		agent.set_meta("home_entrance_cell", entrance_cell)
	return builder_id


func spawn_fundamental_builder() -> int:
	if GameState.is_night or _fundamental_builder_id >= 0:
		return -1
	var source_cell: Vector2i = _named_spot_cell(FUNDAMENTAL_BUILDER_IN_ID)
	var spot_cell: Vector2i = _named_spot_cell(FUNDAMENTAL_BUILDER_SPOT_ID)
	if source_cell == INVALID_CELL or spot_cell == INVALID_CELL:
		push_warning("BuilderController: fundamental Builder markers are missing.")
		return -1
	var spawn_cell: Vector2i = _manager.find_free_cell_near_spawner(source_cell, _manager.occupied_cells_for_spawning())
	if spawn_cell == INVALID_CELL:
		return -1
	var target_cell: Vector2i = _find_claim_near_anchor(spot_cell, null, spawn_cell)
	if target_cell == INVALID_CELL:
		return -1
	var visitor: DayVisitorMovementController = DayVisitorMovementController.new()
	visitor.setup(_manager, "fundamental Builder")
	_claimed_cells[target_cell] = visitor
	if not visitor.spawn(
			source_cell,
			spawn_cell,
			target_cell,
			AGENT_KIND_BUILDER,
			BUILDER_GROUP,
			VISITOR_CATEGORY,
			Callable(_manager, "apply_fundamental_builder_data")
	):
		_claimed_cells.erase(target_cell)
		return -1
	_visitors.append(visitor)
	var builder_id: int = _register_visitor_id(visitor)
	_state_by_builder_id[builder_id] = STATE_ENTERING
	_fundamental_builder_id = builder_id
	_fundamental_builder_intro_requested = _fundamental_builder_intro_played()
	_home_cell_by_builder_id[builder_id] = spot_cell
	var agent: Node2D = visitor.agent_node()
	if agent != null:
		agent.set_meta("fundamental_builder", true)
	return builder_id


func fundamental_builder_active() -> bool:
	return _fundamental_builder_id >= 0 and is_builder_active(_fundamental_builder_id)


func fundamental_builder_idle_at_spot() -> bool:
	if not fundamental_builder_active():
		return false
	var visitor: DayVisitorMovementController = _visitor_for_id(_fundamental_builder_id)
	return visitor != null and visitor.is_waiting()


func fundamental_builder_world_position() -> Vector2:
	var visitor: DayVisitorMovementController = _visitor_for_id(_fundamental_builder_id)
	return visitor.get_agent_world_position() if visitor != null else Vector2.ZERO


func fundamental_builder_node() -> Node2D:
	return _builder_agent_node(_fundamental_builder_id) if _fundamental_builder_id >= 0 else null


func is_player_near_fundamental_builder(interact_radius_tiles: int) -> bool:
	var agent: Node2D = fundamental_builder_node()
	if agent == null:
		return false
	var player: Node2D = _manager.get_tree().get_first_node_in_group("player") as Node2D
	var floorz: TileMapLayer = _manager.get_floorz()
	if player == null or floorz == null:
		return false
	var player_cell: Vector2i = floorz.local_to_map(floorz.to_local(player.global_position))
	var builder_cell: Vector2i = floorz.local_to_map(floorz.to_local(agent.global_position))
	var delta: Vector2i = player_cell - builder_cell
	return abs(delta.x) <= interact_radius_tiles and abs(delta.y) <= interact_radius_tiles


func retire_fundamental_builder() -> void:
	if _fundamental_builder_id < 0:
		return
	var visitor: DayVisitorMovementController = _visitor_for_id(_fundamental_builder_id)
	if visitor == null:
		_fundamental_builder_id = -1
		_fundamental_builder_intro_requested = _fundamental_builder_intro_played()
		return
	_release_claim_for(visitor)
	_work_house_by_builder_id.erase(_fundamental_builder_id)
	_start_builder_evacuating_to_out(_fundamental_builder_id, visitor)


func remove_builder_for_house(house_id: StringName) -> void:
	if not _builder_id_by_house_id.has(house_id):
		return
	evacuate_builder(int(_builder_id_by_house_id[house_id]))


func evacuate_builder(builder_id: int) -> void:
	var visitor: DayVisitorMovementController = _visitor_for_id(builder_id)
	if visitor == null:
		return
	_release_claim_for(visitor)
	_work_house_by_builder_id.erase(builder_id)
	_start_builder_evacuating_to_out(builder_id, visitor)


func _start_builder_evacuating_to_out(builder_id: int, visitor: DayVisitorMovementController) -> void:
	var out_cell: Vector2i = _named_spot_cell(FUNDAMENTAL_BUILDER_OUT_ID)
	if out_cell != INVALID_CELL and visitor.repath_to_target(out_cell):
		_state_by_builder_id[builder_id] = STATE_EVACUATING
		return
	_state_by_builder_id[builder_id] = STATE_LEAVING
	visitor.start_leave_for_night()


func active_house_builder_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for raw_house_id: Variant in _builder_id_by_house_id.keys():
		ids.append(StringName(str(raw_house_id)))
	return ids


func process_arrivals() -> void:
	for visitor: DayVisitorMovementController in _visitors.duplicate():
		if visitor == null:
			continue
		if not visitor.is_active():
			_remove_visitor(visitor)
			continue
		if visitor.process_arrival():
			_on_visitor_reached_target(visitor)


func process_active_visitors(delta: float = 0.0) -> void:
	_clean_invalid_visitors()
	_process_fundamental_builder_intro_request()
	_process_idle_home_correction(delta)
	_process_builder_motion_watchdog(delta)


func on_agent_removed(agent: Node2D) -> void:
	for visitor: DayVisitorMovementController in _visitors.duplicate():
		if visitor != null and visitor.owns_agent(agent):
			_remove_visitor(visitor)
			return


func clear_active_builders(free_agents: bool) -> void:
	for visitor: DayVisitorMovementController in _visitors.duplicate():
		if visitor == null:
			continue
		_release_claim_for(visitor)
		visitor.clear(free_agents)
	_visitors.clear()
	_claimed_cells.clear()
	_visitor_ids.clear()
	_visitors_by_id.clear()
	_state_by_builder_id.clear()
	_work_house_by_builder_id.clear()
	_house_id_by_builder_id.clear()
	_builder_id_by_house_id.clear()
	_home_cell_by_builder_id.clear()
	_idle_displacement_seconds_by_builder_id.clear()
	_idle_return_retry_cooldown_by_builder_id.clear()
	_pending_idle_return_by_builder_id.clear()
	_idle_home_check_elapsed = 0.0
	_fundamental_builder_id = -1
	_fundamental_builder_intro_requested = false
	_clear_motion_watch()


func restore_state(_raw_count: Variant) -> void:
	clear_active_builders(true)


func restore_after_load() -> void:
	await _manager.get_tree().process_frame
	await _manager.get_tree().process_frame


func repath_for_walkability_change() -> void:
	_clean_invalid_visitors()
	for visitor: DayVisitorMovementController in _visitors.duplicate():
		if visitor == null or not visitor.is_active() or visitor.is_leaving():
			continue
		var builder_id: int = _builder_id_for_visitor(visitor)
		if builder_id >= 0 and _work_house_by_builder_id.has(builder_id):
			continue
		var target: Vector2i = visitor.target_cell()
		if _claim_still_valid(visitor, target):
			var repathed: bool = visitor.repath_to_current_target()
			if builder_id >= 0:
				_reset_builder_motion_watch(builder_id)
			if repathed:
				continue
		_release_claim_for(visitor)
		var replacement: Vector2i = _find_claim_for_visitor(visitor.source_spawner_cell(), visitor)
		var replacement_builder_id: int = _builder_id_for_visitor(visitor)
		if replacement == INVALID_CELL:
			var home_cell: Vector2i = _home_cell_by_builder_id.get(replacement_builder_id, INVALID_CELL) as Vector2i
			push_warning("BuilderController: no replacement Builder target near %s within radius %d; Builder kept at current safe position when possible." % [home_cell, BUILDER_SPOT_CLAIM_RADIUS])
			if replacement_builder_id >= 0:
				_reset_builder_motion_watch(replacement_builder_id)
			continue
		_claimed_cells[replacement] = visitor
		if not visitor.repath_to_target(replacement):
			_claimed_cells.erase(replacement)
			push_warning("BuilderController: Builder replacement target %s became unreachable during repath." % replacement)
			if replacement_builder_id >= 0:
				_reset_builder_motion_watch(replacement_builder_id)
			continue
		if replacement_builder_id >= 0:
			_reset_builder_motion_watch(replacement_builder_id)


func available_idle_builder_ids() -> Array[int]:
	_clean_invalid_visitors()
	var ids: Array[int] = []
	for visitor: DayVisitorMovementController in _visitors:
		var builder_id: int = _builder_id_for_visitor(visitor)
		if builder_id >= 0 and is_builder_available_for_work(builder_id):
			ids.append(builder_id)
	return ids


func is_builder_available_for_work(builder_id: int) -> bool:
	var visitor: DayVisitorMovementController = _visitor_for_id(builder_id)
	if visitor == null or not visitor.is_active() or is_builder_leaving(builder_id):
		return false
	var state: StringName = StringName(_state_by_builder_id.get(builder_id, &""))
	if state == STATE_IDLE and visitor.is_waiting():
		return true
	return state == STATE_RETURNING_IDLE


func is_builder_active(builder_id: int) -> bool:
	var visitor: DayVisitorMovementController = _visitor_for_id(builder_id)
	return visitor != null and visitor.is_active()


func is_builder_leaving(builder_id: int) -> bool:
	var visitor: DayVisitorMovementController = _visitor_for_id(builder_id)
	if visitor == null or visitor.is_leaving():
		return true
	var state: StringName = StringName(_state_by_builder_id.get(builder_id, &""))
	return state == STATE_LEAVING or state == STATE_RETURNING_HOME or state == STATE_EVACUATING


func builder_current_cell(builder_id: int) -> Vector2i:
	var visitor: DayVisitorMovementController = _visitor_for_id(builder_id)
	if visitor == null or not visitor.is_active():
		return INVALID_CELL
	var floorz: TileMapLayer = _manager.get_floorz()
	if floorz == null:
		return INVALID_CELL
	return floorz.local_to_map(floorz.to_local(visitor.get_agent_world_position()))


func builder_reached_current_target(builder_id: int) -> bool:
	var visitor: DayVisitorMovementController = _visitor_for_id(builder_id)
	return visitor != null and visitor.is_active() and visitor.is_waiting()


func builder_claimed_cell(builder_id: int) -> Vector2i:
	var visitor: DayVisitorMovementController = _visitor_for_id(builder_id)
	return visitor.target_cell() if visitor != null else INVALID_CELL


func repath_builder_to_current_target(builder_id: int) -> bool:
	var visitor: DayVisitorMovementController = _visitor_for_id(builder_id)
	if visitor == null or not visitor.is_active() or visitor.is_leaving():
		return false
	var repathed: bool = visitor.repath_to_current_target()
	_reset_builder_motion_watch(builder_id)
	return repathed


func assign_builder_to_work_cell(builder_id: int, house_id: StringName, target_cell: Vector2i) -> bool:
	var visitor: DayVisitorMovementController = _visitor_for_id(builder_id)
	if visitor == null or not visitor.is_active() or visitor.is_leaving():
		return false
	if not _is_candidate_available(target_cell, visitor):
		return false
	var previous_target: Vector2i = visitor.target_cell()
	_release_claim_for(visitor)
	_claimed_cells[target_cell] = visitor
	if not visitor.repath_to_target(target_cell):
		_claimed_cells.erase(target_cell)
		if previous_target != INVALID_CELL and _is_candidate_available(previous_target, visitor):
			_claimed_cells[previous_target] = visitor
		_reset_builder_motion_watch(builder_id)
		return false
	_state_by_builder_id[builder_id] = STATE_TRAVELLING_TO_WORK
	_work_house_by_builder_id[builder_id] = house_id
	_clear_idle_return_state(builder_id)
	_reset_builder_motion_watch(builder_id)
	return true


func request_builder_local_work_move(builder_id: int, target_cell: Vector2i) -> bool:
	var visitor: DayVisitorMovementController = _visitor_for_id(builder_id)
	if visitor == null or not visitor.is_active() or visitor.is_leaving():
		return false
	if not _work_house_by_builder_id.has(builder_id):
		return false
	if not _is_candidate_available(target_cell, visitor):
		return false
	var current_cell: Vector2i = builder_current_cell(builder_id)
	var path_cells: PackedVector2Array = _find_bounded_local_work_path(current_cell, target_cell)
	if path_cells.is_empty():
		return false
	var previous_target: Vector2i = visitor.target_cell()
	_release_claim_for(visitor)
	_claimed_cells[target_cell] = visitor
	if not visitor.assign_cell_path(target_cell, path_cells):
		_claimed_cells.erase(target_cell)
		if previous_target != INVALID_CELL and _is_candidate_available(previous_target, visitor):
			_claimed_cells[previous_target] = visitor
		_reset_builder_motion_watch(builder_id)
		return false
	_state_by_builder_id[builder_id] = STATE_WORKING
	_reset_builder_motion_watch(builder_id)
	return true


func _find_bounded_local_work_path(from_cell: Vector2i, to_cell: Vector2i) -> PackedVector2Array:
	var empty_path: PackedVector2Array = PackedVector2Array()
	if from_cell == INVALID_CELL or to_cell == INVALID_CELL:
		return empty_path
	if not _manager.is_walkable_cell(from_cell) or not _manager.is_walkable_cell(to_cell):
		return empty_path
	if abs(from_cell.x - to_cell.x) > LOCAL_WORK_MOVE_MAX_DISTANCE or abs(from_cell.y - to_cell.y) > LOCAL_WORK_MOVE_MAX_DISTANCE:
		return empty_path
	var queue: Array[Vector2i] = [from_cell]
	var visited: Dictionary = {from_cell: true}
	var came_from: Dictionary = {}
	var directions: Array[Vector2i] = [
		Vector2i.RIGHT,
		Vector2i.LEFT,
		Vector2i.DOWN,
		Vector2i.UP,
	]
	var head: int = 0
	while head < queue.size():
		var cell: Vector2i = queue[head]
		head += 1
		if cell == to_cell:
			return _reconstruct_local_work_path(from_cell, to_cell, came_from)
		for direction: Vector2i in directions:
			var next_cell: Vector2i = cell + direction
			if visited.has(next_cell):
				continue
			if abs(next_cell.x - from_cell.x) > LOCAL_WORK_MOVE_MAX_DISTANCE or abs(next_cell.y - from_cell.y) > LOCAL_WORK_MOVE_MAX_DISTANCE:
				continue
			if not _manager.is_walkable_cell(next_cell):
				continue
			visited[next_cell] = true
			came_from[next_cell] = cell
			queue.append(next_cell)
	return empty_path


func _reconstruct_local_work_path(from_cell: Vector2i, to_cell: Vector2i, came_from: Dictionary) -> PackedVector2Array:
	var reversed_cells: Array[Vector2i] = [to_cell]
	var cell: Vector2i = to_cell
	while cell != from_cell:
		if not came_from.has(cell):
			return PackedVector2Array()
		cell = came_from[cell] as Vector2i
		reversed_cells.append(cell)
	var path: PackedVector2Array = PackedVector2Array()
	for index: int in range(reversed_cells.size() - 1, -1, -1):
		var path_cell: Vector2i = reversed_cells[index]
		path.append(Vector2(float(path_cell.x), float(path_cell.y)))
	return path


func release_builder_from_work(builder_id: int) -> void:
	var visitor: DayVisitorMovementController = _visitor_for_id(builder_id)
	if visitor != null:
		_release_claim_for(visitor)
	_work_house_by_builder_id.erase(builder_id)
	if visitor != null and visitor.is_active() and not visitor.is_leaving():
		var current_state: StringName = StringName(_state_by_builder_id.get(builder_id, &""))
		if current_state != STATE_LEAVING and current_state != STATE_RETURNING_HOME and current_state != STATE_EVACUATING:
			_state_by_builder_id[builder_id] = STATE_IDLE if visitor.is_waiting() else STATE_RETURNING_IDLE
	_reset_builder_motion_watch(builder_id)


# Visual-only delegation to the Builder agent's generic held-object API. Construction
# timing stays with HouseBuilderWorkController; this only resolves the agent node.
func play_builder_hammer_swing(builder_id: int, duration: float, swing_target_global: Vector2) -> void:
	var agent: Node2D = _builder_agent_node(builder_id)
	if agent == null or not agent.has_method("animate_held_object_full_rotation"):
		return
	agent.call("animate_held_object_full_rotation", duration, swing_target_global)


func stop_builder_hammer_swing(builder_id: int) -> void:
	var agent: Node2D = _builder_agent_node(builder_id)
	if agent == null or not agent.has_method("stop_held_object_animation"):
		return
	agent.call("stop_held_object_animation")


func _builder_agent_node(builder_id: int) -> Node2D:
	var visitor: DayVisitorMovementController = _visitor_for_id(builder_id)
	return visitor.agent_node() if visitor != null else null


func _process_fundamental_builder_intro_request() -> void:
	if _fundamental_builder_intro_requested or _fundamental_builder_id < 0:
		return
	if _fundamental_builder_intro_played():
		_fundamental_builder_intro_requested = true
		return
	if StringName(_state_by_builder_id.get(_fundamental_builder_id, &"")) != STATE_ENTERING:
		return
	var agent: Node2D = fundamental_builder_node()
	var floorz: TileMapLayer = _manager.get_floorz()
	if agent == null or floorz == null:
		return
	var current_cell: Vector2i = floorz.local_to_map(floorz.to_local(agent.global_position))
	var spot_cell: Vector2i = _named_spot_cell(FUNDAMENTAL_BUILDER_SPOT_ID)
	if spot_cell == INVALID_CELL:
		return
	var delta: Vector2i = current_cell - spot_cell
	if abs(delta.x) > FUNDAMENTAL_BUILDER_INTRO_RADIUS_TILES or abs(delta.y) > FUNDAMENTAL_BUILDER_INTRO_RADIUS_TILES:
		return
	_fundamental_builder_intro_requested = true
	fundamental_builder_intro_requested.emit(agent)


func _fundamental_builder_intro_played() -> bool:
	return _manager != null \
		and _manager.has_method("has_fundamental_builder_intro_cutscene_played") \
		and bool(_manager.call("has_fundamental_builder_intro_cutscene_played"))


func return_builder_to_idle_area(builder_id: int) -> bool:
	var visitor: DayVisitorMovementController = _visitor_for_id(builder_id)
	if visitor == null or not visitor.is_active() or is_builder_leaving(builder_id):
		return false
	var target_cell: Vector2i = _find_claim_for_visitor(visitor.source_spawner_cell(), visitor)
	if target_cell == INVALID_CELL:
		_mark_idle_return_pending(builder_id)
		_park_builder_at_current_cell(builder_id, visitor)
		return false
	_release_claim_for(visitor)
	_claimed_cells[target_cell] = visitor
	if not visitor.repath_to_target(target_cell):
		_claimed_cells.erase(target_cell)
		_mark_idle_return_pending(builder_id)
		_park_builder_at_current_cell(builder_id, visitor)
		_reset_builder_motion_watch(builder_id)
		return false
	_work_house_by_builder_id.erase(builder_id)
	_state_by_builder_id[builder_id] = STATE_RETURNING_IDLE
	_clear_idle_return_state(builder_id)
	_reset_builder_motion_watch(builder_id)
	return true


func _park_builder_at_current_cell(builder_id: int, visitor: DayVisitorMovementController) -> void:
	var current_cell: Vector2i = builder_current_cell(builder_id)
	if current_cell == INVALID_CELL or not _manager.is_walkable_cell(current_cell):
		return
	_release_claim_for(visitor)
	_claimed_cells[current_cell] = visitor
	_work_house_by_builder_id.erase(builder_id)
	_state_by_builder_id[builder_id] = STATE_IDLE
	visitor.park_at_current_cell(current_cell)
	_reset_builder_motion_watch(builder_id)


func _find_claim_for_visitor(source_cell: Vector2i, visitor: DayVisitorMovementController) -> Vector2i:
	var agent: Node2D = visitor.agent_node() if visitor != null else null
	if agent == null:
		return INVALID_CELL
	var floorz: TileMapLayer = _manager.get_floorz()
	if floorz == null:
		return INVALID_CELL
	var from_cell: Vector2i = floorz.local_to_map(floorz.to_local(agent.global_position))
	if not _manager.is_walkable_cell(from_cell):
		from_cell = source_cell
	return _find_claim_from_spawn(from_cell, visitor)


# The cell a Builder idles on when it has nothing to do. House-bound Builders anchor on
# their house entrance, the fundamental Builder on its authored spot. Any Builder with an
# anchor is walked back to it after being pushed off.
func _builder_home_cell(builder_id: int) -> Vector2i:
	return _home_cell_by_builder_id.get(builder_id, INVALID_CELL) as Vector2i


func _find_claim_from_spawn(spawn_cell: Vector2i, visitor: DayVisitorMovementController) -> Vector2i:
	var builder_id: int = _builder_id_for_visitor(visitor)
	var anchor: Vector2i = _home_cell_by_builder_id.get(builder_id, _named_spot_cell(FUNDAMENTAL_BUILDER_SPOT_ID)) as Vector2i
	# A house entrance is a doorway the Builder waits next to; an authored spot is meant to
	# be stood on.
	var include_anchor: bool = builder_id < 0 or not _house_id_by_builder_id.has(builder_id)
	return _find_claim_near_anchor(anchor, visitor, spawn_cell, include_anchor)


func _find_claim_near_anchor(anchor: Vector2i, visitor: DayVisitorMovementController, spawn_cell: Vector2i, include_anchor: bool = true) -> Vector2i:
	for candidate: Vector2i in _target_candidates(anchor, include_anchor):
		if not _is_candidate_available(candidate, visitor):
			continue
		var path_cells: PackedVector2Array = _manager.find_path_on_walkable_map(spawn_cell, candidate)
		if path_cells.is_empty():
			continue
		return candidate
	return INVALID_CELL


func _target_candidates(anchor: Vector2i, include_anchor: bool = true) -> Array[Vector2i]:
	var candidates: Array[Vector2i] = []
	if include_anchor:
		candidates.append(anchor)
	for radius: int in range(1, BUILDER_SPOT_CLAIM_RADIUS + 1):
		for y: int in range(anchor.y - radius, anchor.y + radius + 1):
			for x: int in range(anchor.x - radius, anchor.x + radius + 1):
				if abs(x - anchor.x) != radius and abs(y - anchor.y) != radius:
					continue
				candidates.append(Vector2i(x, y))
	return candidates


func _is_candidate_available(cell: Vector2i, visitor: DayVisitorMovementController) -> bool:
	if cell == INVALID_CELL or not _manager.is_walkable_cell(cell):
		return false
	if _claimed_cells.has(cell) and _claimed_cells[cell] != visitor:
		return false
	if visitor != null and visitor.target_cell() == cell:
		return true
	var excluded_agent: Node2D = visitor.agent_node() if visitor != null else null
	return not _manager.get_agent_cell_tracker().is_cell_occupied(cell, excluded_agent)


func _claim_still_valid(visitor: DayVisitorMovementController, cell: Vector2i) -> bool:
	return _is_candidate_available(cell, visitor)


func _process_idle_home_correction(delta: float) -> void:
	if delta <= 0.0 or GameState.is_night:
		return
	_idle_home_check_elapsed += delta
	if _idle_home_check_elapsed < IDLE_HOME_CHECK_INTERVAL_SECONDS:
		return
	var elapsed: float = _idle_home_check_elapsed
	_idle_home_check_elapsed = 0.0
	for raw_builder_id: Variant in _idle_return_retry_cooldown_by_builder_id.keys():
		var cooldown_builder_id: int = int(raw_builder_id)
		var cooldown: float = maxf(0.0, float(_idle_return_retry_cooldown_by_builder_id.get(cooldown_builder_id, 0.0)) - elapsed)
		if cooldown <= 0.0:
			_idle_return_retry_cooldown_by_builder_id.erase(cooldown_builder_id)
		else:
			_idle_return_retry_cooldown_by_builder_id[cooldown_builder_id] = cooldown
	for visitor: DayVisitorMovementController in _visitors:
		var builder_id: int = _builder_id_for_visitor(visitor)
		if builder_id < 0 or _builder_home_cell(builder_id) == INVALID_CELL:
			if builder_id >= 0:
				_clear_idle_return_state(builder_id)
			continue
		if not _eligible_for_idle_home_correction(builder_id, visitor):
			_idle_displacement_seconds_by_builder_id.erase(builder_id)
			continue
		if _idle_return_retry_cooldown_by_builder_id.has(builder_id):
			continue
		if _pending_idle_return_by_builder_id.has(builder_id):
			_request_idle_home_return(builder_id)
			continue
		if not _is_idle_builder_meaningfully_displaced(visitor):
			_idle_displacement_seconds_by_builder_id.erase(builder_id)
			continue
		var displaced_for: float = float(_idle_displacement_seconds_by_builder_id.get(builder_id, 0.0)) + elapsed
		_idle_displacement_seconds_by_builder_id[builder_id] = displaced_for
		if displaced_for >= IDLE_HOME_DISPLACEMENT_GRACE_SECONDS:
			_request_idle_home_return(builder_id)


func _eligible_for_idle_home_correction(builder_id: int, visitor: DayVisitorMovementController) -> bool:
	if visitor == null or not visitor.is_active() or visitor.is_leaving():
		return false
	if GameState.is_night or is_builder_leaving(builder_id):
		return false
	if _work_house_by_builder_id.has(builder_id):
		return false
	if StringName(_state_by_builder_id.get(builder_id, &"")) != STATE_IDLE:
		return false
	return visitor.is_waiting()


func _is_idle_builder_meaningfully_displaced(visitor: DayVisitorMovementController) -> bool:
	if visitor.target_cell() == INVALID_CELL:
		return false
	var tile_size: Vector2 = _manager.tile_size()
	var threshold: float = maxf(tile_size.x, tile_size.y) * IDLE_HOME_DISPLACEMENT_TILE_FACTOR
	return visitor.get_agent_world_position().distance_to(visitor.target_world_position()) > threshold


func _request_idle_home_return(builder_id: int) -> void:
	_idle_displacement_seconds_by_builder_id.erase(builder_id)
	if return_builder_to_idle_area(builder_id):
		_clear_idle_return_state(builder_id)
		return
	_mark_idle_return_pending(builder_id)


func _mark_idle_return_pending(builder_id: int) -> void:
	_pending_idle_return_by_builder_id[builder_id] = true
	_idle_return_retry_cooldown_by_builder_id[builder_id] = IDLE_HOME_RETRY_COOLDOWN_SECONDS


func _clear_idle_return_state(builder_id: int) -> void:
	_idle_displacement_seconds_by_builder_id.erase(builder_id)
	_idle_return_retry_cooldown_by_builder_id.erase(builder_id)
	_pending_idle_return_by_builder_id.erase(builder_id)


func _process_builder_motion_watchdog(delta: float) -> void:
	if not CppDebugOptions.logs_enabled:
		if not _last_watch_position_by_builder_id.is_empty() or not _stall_seconds_by_builder_id.is_empty() or not _stall_warning_cooldown_by_builder_id.is_empty():
			_clear_motion_watch()
		return
	if delta <= 0.0:
		return
	var active_ids: Dictionary = {}
	for visitor: DayVisitorMovementController in _visitors:
		var builder_id: int = _builder_id_for_visitor(visitor)
		if builder_id < 0:
			continue
		active_ids[builder_id] = true
		if not _should_watch_builder_motion(builder_id, visitor):
			_clear_builder_motion_watch(builder_id)
			continue
		_update_builder_motion_watch(builder_id, visitor, delta)
	for raw_builder_id: Variant in _stall_seconds_by_builder_id.keys():
		var watched_builder_id: int = int(raw_builder_id)
		if not active_ids.has(watched_builder_id):
			_clear_builder_motion_watch(watched_builder_id)


func _should_watch_builder_motion(builder_id: int, visitor: DayVisitorMovementController) -> bool:
	if visitor == null or not visitor.is_active() or visitor.is_leaving() or visitor.is_waiting():
		return false
	var state: StringName = StringName(_state_by_builder_id.get(builder_id, &""))
	return state == STATE_ENTERING or state == STATE_TRAVELLING_TO_WORK or state == STATE_WORKING or state == STATE_RETURNING_IDLE or state == STATE_RETURNING_HOME or state == STATE_EVACUATING


func _update_builder_motion_watch(builder_id: int, visitor: DayVisitorMovementController, delta: float) -> void:
	var current_position: Vector2 = visitor.get_agent_world_position()
	if not _last_watch_position_by_builder_id.has(builder_id):
		_last_watch_position_by_builder_id[builder_id] = current_position
		_stall_seconds_by_builder_id[builder_id] = 0.0
		_stall_warning_cooldown_by_builder_id[builder_id] = 0.0
		return
	var last_position: Vector2 = _last_watch_position_by_builder_id[builder_id] as Vector2
	if last_position.distance_to(current_position) > STALL_MOVEMENT_EPSILON_PIXELS:
		_last_watch_position_by_builder_id[builder_id] = current_position
		_stall_seconds_by_builder_id[builder_id] = 0.0
		_stall_warning_cooldown_by_builder_id[builder_id] = 0.0
		return
	var stalled_for: float = float(_stall_seconds_by_builder_id.get(builder_id, 0.0)) + delta
	_stall_seconds_by_builder_id[builder_id] = stalled_for
	var cooldown: float = maxf(0.0, float(_stall_warning_cooldown_by_builder_id.get(builder_id, 0.0)) - delta)
	_stall_warning_cooldown_by_builder_id[builder_id] = cooldown
	if stalled_for < STALL_WARNING_SECONDS or cooldown > 0.0:
		return
	push_warning(_builder_stall_warning(builder_id, visitor, current_position, stalled_for))
	_stall_warning_cooldown_by_builder_id[builder_id] = STALL_WARNING_REPEAT_SECONDS


func _builder_stall_warning(builder_id: int, visitor: DayVisitorMovementController, current_position: Vector2, stalled_for: float) -> String:
	var current_cell: Vector2i = builder_current_cell(builder_id)
	var target_cell: Vector2i = visitor.target_cell()
	var house_id: StringName = StringName(_work_house_by_builder_id.get(builder_id, &""))
	var state: StringName = StringName(_state_by_builder_id.get(builder_id, &""))
	var nav_id: int = visitor.nav_id()
	var home_cell: Vector2i = _builder_home_cell(builder_id)
	return "BuilderController: Builder appears stalled; id=%d nav_id=%d state=%s house=%s current_cell=%s target_cell=%s home=%s current_world=%s target_world=%s stalled_for=%.1fs." % [
		builder_id,
		nav_id,
		String(state),
		String(house_id),
		current_cell,
		target_cell,
		home_cell,
		current_position,
		_manager.cell_center(target_cell) if target_cell != INVALID_CELL else Vector2.ZERO,
		stalled_for,
	]


func _reset_builder_motion_watch(builder_id: int) -> void:
	var visitor: DayVisitorMovementController = _visitor_for_id(builder_id)
	if visitor == null or not visitor.is_active():
		_clear_builder_motion_watch(builder_id)
		return
	_last_watch_position_by_builder_id[builder_id] = visitor.get_agent_world_position()
	_stall_seconds_by_builder_id[builder_id] = 0.0
	_stall_warning_cooldown_by_builder_id[builder_id] = 0.0


func _clear_builder_motion_watch(builder_id: int) -> void:
	_last_watch_position_by_builder_id.erase(builder_id)
	_stall_seconds_by_builder_id.erase(builder_id)
	_stall_warning_cooldown_by_builder_id.erase(builder_id)


func _clear_motion_watch() -> void:
	_last_watch_position_by_builder_id.clear()
	_stall_seconds_by_builder_id.clear()
	_stall_warning_cooldown_by_builder_id.clear()


func _named_spot_cell(spot_id: StringName) -> Vector2i:
	return _manager.named_authored_spot_cell(spot_id)


func _remove_visitor(visitor: DayVisitorMovementController) -> void:
	_release_claim_for(visitor)
	var builder_id: int = _builder_id_for_visitor(visitor)
	_visitors.erase(visitor)
	if builder_id >= 0:
		_visitor_ids.erase(visitor)
		_visitors_by_id.erase(builder_id)
		_state_by_builder_id.erase(builder_id)
		_work_house_by_builder_id.erase(builder_id)
		var house_id: StringName = StringName(_house_id_by_builder_id.get(builder_id, &""))
		if house_id != &"":
			_builder_id_by_house_id.erase(house_id)
		_house_id_by_builder_id.erase(builder_id)
		_home_cell_by_builder_id.erase(builder_id)
		if _fundamental_builder_id == builder_id:
			_fundamental_builder_id = -1
			_fundamental_builder_intro_requested = _fundamental_builder_intro_played()
		_clear_idle_return_state(builder_id)
		_clear_builder_motion_watch(builder_id)
		if _manager != null:
			_manager.get_house_builder_work_controller().on_builder_removed(builder_id)
	visitor.forget_agent()


func _release_claim_for(visitor: DayVisitorMovementController) -> void:
	var remove_cells: Array[Vector2i] = []
	for raw_cell: Variant in _claimed_cells.keys():
		var cell: Vector2i = raw_cell as Vector2i
		if _claimed_cells[cell] == visitor:
			remove_cells.append(cell)
	for cell: Vector2i in remove_cells:
		_claimed_cells.erase(cell)


func _clean_invalid_visitors() -> void:
	for visitor: DayVisitorMovementController in _visitors.duplicate():
		if visitor == null or not visitor.is_active():
			_remove_visitor(visitor)


func _register_visitor_id(visitor: DayVisitorMovementController) -> int:
	var builder_id: int = _next_builder_runtime_id
	_next_builder_runtime_id += 1
	_visitor_ids[visitor] = builder_id
	_visitors_by_id[builder_id] = visitor
	return builder_id


func _builder_id_for_visitor(visitor: DayVisitorMovementController) -> int:
	if visitor == null or not _visitor_ids.has(visitor):
		return -1
	return int(_visitor_ids[visitor])


func _visitor_for_id(builder_id: int) -> DayVisitorMovementController:
	return _visitors_by_id.get(builder_id, null) as DayVisitorMovementController


func _on_visitor_reached_target(visitor: DayVisitorMovementController) -> void:
	var builder_id: int = _builder_id_for_visitor(visitor)
	if builder_id < 0:
		return
	var state: StringName = StringName(_state_by_builder_id.get(builder_id, STATE_ENTERING))
	if state == STATE_ENTERING or state == STATE_RETURNING_IDLE:
		_state_by_builder_id[builder_id] = STATE_IDLE
		_clear_idle_return_state(builder_id)
		_reset_builder_motion_watch(builder_id)
		_manager.get_house_builder_work_controller().on_builder_became_idle(builder_id)
	elif state == STATE_TRAVELLING_TO_WORK:
		_state_by_builder_id[builder_id] = STATE_WORKING
		_reset_builder_motion_watch(builder_id)
	elif state == STATE_RETURNING_HOME or state == STATE_EVACUATING:
		visitor.clear(true)
		_remove_visitor(visitor)
