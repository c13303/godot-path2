extends RefCounted
class_name HouseBuilderWorkController

const HOUSE_WORK_CELL_SEARCH_RADIUS: int = 3
const WORK_PHASE_TRAVEL: StringName = &"travel"
const WORK_PHASE_PAUSE: StringName = &"pause"
const WORK_PHASE_MOVE: StringName = &"move"
const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)
const PAUSE_DURATIONS: Array[float] = [0.8, 1.1, 1.4, 1.0]
const HAMMER_SWING_INTERVAL_SECONDS: float = 1.0
const HAMMER_SWING_DURATION_SECONDS: float = 0.3

var _manager: BuildingManager = null
var _house_manager: HouseManager = null
var _builder: BuilderController = null
var _overlay: HouseWorkProgressOverlay = null

var _work_seconds_by_house_id: Dictionary = {}  # StringName -> float
var _house_by_builder_id: Dictionary = {}  # int -> StringName
var _builder_by_house_id: Dictionary = {}  # StringName -> int
var _phase_by_builder_id: Dictionary = {}  # int -> StringName
var _pause_remaining_by_builder_id: Dictionary = {}  # int -> float
var _pause_index_by_builder_id: Dictionary = {}  # int -> int
var _hammer_swing_remaining_by_builder_id: Dictionary = {}  # int -> float
var _work_cell_candidates_by_house_id: Dictionary = {}  # StringName -> Array[Vector2i]
var _assignment_dirty: bool = false


func setup(
		manager: BuildingManager,
		house_manager: HouseManager,
		builder: BuilderController,
		overlay: HouseWorkProgressOverlay
) -> void:
	_manager = manager
	_house_manager = house_manager
	_builder = builder
	_overlay = overlay
	_work_cell_candidates_by_house_id.clear()


func process(delta: float) -> void:
	if _manager == null or _house_manager == null or _builder == null:
		return
	if GameState.is_night:
		return
	_process_active_assignments(delta)
	if _assignment_dirty:
		_assignment_dirty = false
		_assign_available_builders()


func on_wip_house_added(house_id: StringName) -> void:
	_work_cell_candidates_by_house_id.erase(house_id)
	if not _work_seconds_by_house_id.has(house_id):
		_work_seconds_by_house_id[house_id] = 0.0
	_mark_assignment_dirty()


func on_wip_house_removed(house_id: StringName) -> void:
	_cancel_house_assignment(house_id, true)
	_work_seconds_by_house_id.erase(house_id)
	_work_cell_candidates_by_house_id.erase(house_id)
	if _overlay != null:
		_overlay.remove_progress(house_id)
	_mark_assignment_dirty()


func on_builder_became_idle(_builder_id: int) -> void:
	_mark_assignment_dirty()


func on_builder_removed(builder_id: int) -> void:
	_cancel_builder_assignment(builder_id, false, false)
	_mark_assignment_dirty()


func on_night_started() -> void:
	for raw_builder_id: Variant in _house_by_builder_id.keys():
		_cancel_builder_assignment(int(raw_builder_id), true, false)
	if _overlay != null:
		_overlay.clear_all()


func on_topology_changed() -> void:
	_work_cell_candidates_by_house_id.clear()
	for raw_builder_id: Variant in _house_by_builder_id.keys():
		var builder_id: int = int(raw_builder_id)
		var house_id: StringName = StringName(str(_house_by_builder_id.get(builder_id, &"")))
		if not _assignment_still_valid(builder_id, house_id):
			_cancel_builder_assignment(builder_id, true, true)
			continue
		if not _builder.repath_builder_to_current_target(builder_id):
			_cancel_builder_assignment(builder_id, true, true)
	_mark_assignment_dirty()


func _process_active_assignments(delta: float) -> void:
	for raw_builder_id: Variant in _house_by_builder_id.keys():
		var builder_id: int = int(raw_builder_id)
		var house_id: StringName = StringName(str(_house_by_builder_id.get(builder_id, &"")))
		if not _assignment_still_valid(builder_id, house_id):
			_cancel_builder_assignment(builder_id, true, true)
			continue
		var phase: StringName = StringName(_phase_by_builder_id.get(builder_id, WORK_PHASE_TRAVEL))
		if phase == WORK_PHASE_TRAVEL:
			if _builder.builder_reached_current_target(builder_id):
				_begin_pause(builder_id, house_id)
			continue
		if phase == WORK_PHASE_MOVE and _builder.builder_reached_current_target(builder_id):
			_begin_pause(builder_id, house_id)
			phase = WORK_PHASE_PAUSE
		_advance_work(builder_id, house_id, delta)
		if not _house_by_builder_id.has(builder_id):
			continue
		if phase == WORK_PHASE_PAUSE:
			var remaining: float = float(_pause_remaining_by_builder_id.get(builder_id, 0.0)) - delta
			_pause_remaining_by_builder_id[builder_id] = remaining
			if remaining <= 0.0:
				_try_start_local_move(builder_id, house_id)


func _advance_work(builder_id: int, house_id: StringName, delta: float) -> void:
	var required: float = _house_manager.house_work_seconds(house_id)
	if required <= 0.0:
		_complete_assignment(builder_id, house_id)
		return
	var current: float = float(_work_seconds_by_house_id.get(house_id, 0.0))
	current = clampf(current + maxf(0.0, delta), 0.0, required)
	_work_seconds_by_house_id[house_id] = current
	var sprite: Sprite2D = _house_manager.get_house_sprite(house_id)
	if _overlay != null:
		_overlay.show_progress(house_id, sprite, current / required)
	if current >= required:
		_complete_assignment(builder_id, house_id)
		return
	_process_builder_hammer_swing(builder_id, house_id, delta)


# Visual cadence only: one full hammer turn per second of actual house progress, each turn
# swinging out to the worked house and back so the target is unambiguous.
func _process_builder_hammer_swing(builder_id: int, house_id: StringName, delta: float) -> void:
	var remaining: float = float(
		_hammer_swing_remaining_by_builder_id.get(builder_id, HAMMER_SWING_INTERVAL_SECONDS)
	)
	remaining -= maxf(0.0, delta)
	if remaining <= 0.0:
		_builder.play_builder_hammer_swing(
			builder_id,
			HAMMER_SWING_DURATION_SECONDS,
			_house_manager.get_house_center_world(house_id)
		)
		# A large frame delta is normalized without queuing several swings.
		while remaining <= 0.0:
			remaining += HAMMER_SWING_INTERVAL_SECONDS
	_hammer_swing_remaining_by_builder_id[builder_id] = remaining


func _complete_assignment(builder_id: int, house_id: StringName) -> void:
	if not _house_manager.complete_house(house_id):
		_cancel_builder_assignment(builder_id, true, true)
		return
	_work_seconds_by_house_id.erase(house_id)
	if _overlay != null:
		_overlay.remove_progress(house_id)
	_clear_assignment_state(builder_id, house_id)
	_builder.release_builder_from_work(builder_id)
	if _builder.is_builder_leaving(builder_id):
		_mark_assignment_dirty()
		return
	if not _assign_builder_to_next_task(builder_id):
		_builder.return_builder_to_idle_area(builder_id)
	_mark_assignment_dirty()


func _assign_available_builders() -> void:
	if GameState.is_night:
		return
	for builder_id: int in _builder.available_idle_builder_ids():
		if _house_by_builder_id.has(builder_id):
			continue
		_assign_builder_to_next_task(builder_id)


func _assign_builder_to_next_task(builder_id: int) -> bool:
	if GameState.is_night or not _builder.is_builder_active(builder_id) or _builder.is_builder_leaving(builder_id):
		return false
	for house_id: StringName in _house_manager.get_wip_house_ids_in_build_order():
		if _builder_by_house_id.has(house_id):
			continue
		if not _house_manager.is_house_navigation_ready(house_id):
			continue
		if _try_assign_builder_to_house(builder_id, house_id):
			return true
	return false


func _try_assign_builder_to_house(builder_id: int, house_id: StringName) -> bool:
	for target_cell: Vector2i in _work_cell_candidates(house_id):
		if _builder.assign_builder_to_work_cell(builder_id, house_id, target_cell):
			_house_by_builder_id[builder_id] = house_id
			_builder_by_house_id[house_id] = builder_id
			_phase_by_builder_id[builder_id] = WORK_PHASE_TRAVEL
			# Counts down only from _advance_work(), so travel to the house never swings.
			_hammer_swing_remaining_by_builder_id[builder_id] = HAMMER_SWING_INTERVAL_SECONDS
			if not _work_seconds_by_house_id.has(house_id):
				_work_seconds_by_house_id[house_id] = 0.0
			return true
	push_warning("HouseBuilderWorkController: no reachable Builder work cell for WIP house '%s'." % String(house_id))
	return false


func _try_start_local_move(builder_id: int, house_id: StringName) -> void:
	var current_cell: Vector2i = _builder.builder_claimed_cell(builder_id)
	for target_cell: Vector2i in _work_cell_candidates(house_id):
		if target_cell == current_cell:
			continue
		if _builder.request_builder_local_work_move(builder_id, target_cell):
			_phase_by_builder_id[builder_id] = WORK_PHASE_MOVE
			return
	_begin_pause(builder_id, house_id)


func _begin_pause(builder_id: int, house_id: StringName) -> void:
	_phase_by_builder_id[builder_id] = WORK_PHASE_PAUSE
	var pause_index: int = int(_pause_index_by_builder_id.get(builder_id, 0))
	_pause_remaining_by_builder_id[builder_id] = PAUSE_DURATIONS[pause_index % PAUSE_DURATIONS.size()]
	_pause_index_by_builder_id[builder_id] = pause_index + 1
	var required: float = maxf(0.001, _house_manager.house_work_seconds(house_id))
	var current: float = float(_work_seconds_by_house_id.get(house_id, 0.0))
	if _overlay != null:
		_overlay.show_progress(house_id, _house_manager.get_house_sprite(house_id), current / required)


func _assignment_still_valid(builder_id: int, house_id: StringName) -> bool:
	return (
		house_id != &""
		and _builder.is_builder_active(builder_id)
		and not _builder.is_builder_leaving(builder_id)
		and _house_manager.is_house_wip(house_id)
	)


func _cancel_house_assignment(house_id: StringName, release_builder: bool) -> void:
	if not _builder_by_house_id.has(house_id):
		return
	var builder_id: int = int(_builder_by_house_id[house_id])
	_cancel_builder_assignment(builder_id, release_builder, true)


func _cancel_builder_assignment(builder_id: int, release_builder: bool, return_to_idle: bool) -> void:
	if not _house_by_builder_id.has(builder_id):
		return
	var house_id: StringName = StringName(str(_house_by_builder_id.get(builder_id, &"")))
	if _overlay != null:
		_overlay.hide_progress(house_id)
	_clear_assignment_state(builder_id, house_id)
	if release_builder:
		_builder.release_builder_from_work(builder_id)
		if return_to_idle and not GameState.is_night:
			_builder.return_builder_to_idle_area(builder_id)


func _clear_assignment_state(builder_id: int, house_id: StringName) -> void:
	_house_by_builder_id.erase(builder_id)
	_builder_by_house_id.erase(house_id)
	_phase_by_builder_id.erase(builder_id)
	_pause_remaining_by_builder_id.erase(builder_id)
	# The hammer stays visible; only its rotation stops and resets.
	_builder.stop_builder_hammer_swing(builder_id)
	_hammer_swing_remaining_by_builder_id.erase(builder_id)


func _mark_assignment_dirty() -> void:
	if not GameState.is_night:
		_assignment_dirty = true


func _work_cell_candidates(house_id: StringName) -> Array[Vector2i]:
	if _work_cell_candidates_by_house_id.has(house_id):
		return _work_cell_candidates_by_house_id[house_id] as Array[Vector2i]
	var entrance: Vector2i = _house_manager.get_house_entrance(house_id)
	if entrance == INVALID_CELL:
		_work_cell_candidates_by_house_id.erase(house_id)
		return []
	var presence: Array[Vector2i] = _house_manager.get_presence_cells(entrance)
	var presence_set: Dictionary = {}
	var min_x: int = entrance.x
	var max_x: int = entrance.x
	var min_y: int = entrance.y
	var max_y: int = entrance.y
	for cell: Vector2i in presence:
		presence_set[cell] = true
		min_x = mini(min_x, cell.x)
		max_x = maxi(max_x, cell.x)
		min_y = mini(min_y, cell.y)
		max_y = maxi(max_y, cell.y)
	var candidates: Array[Vector2i] = []
	var seen: Dictionary = {}
	for ring: int in range(1, HOUSE_WORK_CELL_SEARCH_RADIUS + 1):
		for y: int in range(min_y - ring, max_y + ring + 1):
			for x: int in range(min_x - ring, max_x + ring + 1):
				if x > min_x - ring and x < max_x + ring and y > min_y - ring and y < max_y + ring:
					continue
				var candidate: Vector2i = Vector2i(x, y)
				if seen.has(candidate) or presence_set.has(candidate):
					continue
				seen[candidate] = true
				if not _manager.has_floor_cell(candidate) or not _manager.is_walkable_cell(candidate):
					continue
				candidates.append(candidate)
	_work_cell_candidates_by_house_id[house_id] = candidates
	return candidates
