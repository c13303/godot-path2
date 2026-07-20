extends RefCounted
class_name HouseBuilderWorkController

## Owns the Builder work queue. New-house construction remains the first priority; when no WIP
## house is available, an idle Builder repairs the nearest reachable damaged player placeable.
## PlayerPlaceableDurabilityService remains the sole owner of building health.

const HOUSE_WORK_CELL_SEARCH_RADIUS: int = 3
const REPAIR_WORK_CELL_SEARCH_RADIUS: int = 3
const WORK_PHASE_TRAVEL: StringName = &"travel"
const WORK_PHASE_PAUSE: StringName = &"pause"
const WORK_PHASE_MOVE: StringName = &"move"
const WORK_PHASE_REPAIR: StringName = &"repair"
const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)
const PAUSE_DURATIONS: Array[float] = [0.8, 1.1, 1.4, 1.0]
const HAMMER_SWING_INTERVAL_SECONDS: float = 1.0
## Constant repair speed expressed as the time needed to restore one complete health bar.
const REPAIR_FULL_SECONDS: float = 2.0

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
var _repair_key_by_builder_id: Dictionary = {}  # int -> String
var _builder_by_repair_key: Dictionary = {}  # String -> int
var _repair_fraction_by_builder_id: Dictionary = {}  # int -> float
var _work_cell_candidates_by_repair_key: Dictionary = {}  # String -> Array[Vector2i]
var _assignment_dirty: bool = false
var _repair_work_was_allowed: bool = false


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
	_work_cell_candidates_by_repair_key.clear()
	_repair_work_was_allowed = _repair_work_allowed()
	var durability: PlayerPlaceableDurabilityService = _durability()
	if durability != null:
		var callback: Callable = Callable(self, "_on_placeable_damaged")
		if not durability.placeable_damaged.is_connected(callback):
			durability.placeable_damaged.connect(callback)


func process(delta: float) -> void:
	if _manager == null or _house_manager == null or _builder == null:
		return
	if GameState.is_night:
		return
	var repair_work_allowed: bool = _repair_work_allowed()
	if repair_work_allowed != _repair_work_was_allowed:
		_repair_work_was_allowed = repair_work_allowed
		if repair_work_allowed:
			_mark_assignment_dirty()
		else:
			_cancel_all_repair_assignments()
	_process_active_assignments(delta)
	_process_active_repairs(delta)
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
	_cancel_repair_assignment(builder_id, false, false)
	_mark_assignment_dirty()


func on_night_started() -> void:
	for raw_builder_id: Variant in _house_by_builder_id.keys():
		_cancel_builder_assignment(int(raw_builder_id), true, false)
	for raw_builder_id: Variant in _repair_key_by_builder_id.keys():
		_cancel_repair_assignment(int(raw_builder_id), true, false)
	_repair_work_was_allowed = false
	if _overlay != null:
		_overlay.clear_all()


func on_topology_changed() -> void:
	_work_cell_candidates_by_house_id.clear()
	_work_cell_candidates_by_repair_key.clear()
	for raw_builder_id: Variant in _house_by_builder_id.keys():
		var builder_id: int = int(raw_builder_id)
		var house_id: StringName = StringName(str(_house_by_builder_id.get(builder_id, &"")))
		if not _assignment_still_valid(builder_id, house_id):
			_cancel_builder_assignment(builder_id, true, true)
			continue
		if not _builder.repath_builder_to_current_target(builder_id):
			_cancel_builder_assignment(builder_id, true, true)
	for raw_builder_id: Variant in _repair_key_by_builder_id.keys():
		var builder_id: int = int(raw_builder_id)
		var repair_key: String = str(_repair_key_by_builder_id.get(builder_id, ""))
		if not _repair_assignment_still_valid(builder_id, repair_key):
			_cancel_repair_assignment(builder_id, true, true)
			continue
		if not _builder.repath_builder_to_current_target(builder_id):
			_cancel_repair_assignment(builder_id, true, true)
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


func _process_active_repairs(delta: float) -> void:
	for raw_builder_id: Variant in _repair_key_by_builder_id.keys():
		var builder_id: int = int(raw_builder_id)
		var repair_key: String = str(_repair_key_by_builder_id.get(builder_id, ""))
		if not _repair_assignment_still_valid(builder_id, repair_key):
			_finish_repair_assignment(builder_id, repair_key)
			continue
		var phase: StringName = StringName(_phase_by_builder_id.get(builder_id, WORK_PHASE_TRAVEL))
		if phase == WORK_PHASE_TRAVEL:
			if not _builder.builder_reached_current_target(builder_id):
				continue
			_phase_by_builder_id[builder_id] = WORK_PHASE_REPAIR
		_advance_repair(builder_id, repair_key, delta)


## Repair is gradual so the shared health overlay visibly fills, and interrupted work keeps the
## health already restored. Fractional points are retained per Builder until a whole point can be
## handed to the durability owner.
func _advance_repair(builder_id: int, repair_key: String, delta: float) -> void:
	var record: Dictionary = _repair_record(repair_key)
	if record.is_empty():
		_finish_repair_assignment(builder_id, repair_key)
		return
	var max_health: int = int(record.get("max_health", 0))
	var repair_rate: float = float(max_health) / REPAIR_FULL_SECONDS
	var repair_fraction: float = float(_repair_fraction_by_builder_id.get(builder_id, 0.0))
	repair_fraction += maxf(0.0, delta) * repair_rate
	var repair_points: int = int(floor(repair_fraction))
	if repair_points > 0:
		repair_fraction -= float(repair_points)
		var durability: PlayerPlaceableDurabilityService = _durability()
		if durability == null or durability.apply_repair(repair_key, repair_points) <= 0:
			_finish_repair_assignment(builder_id, repair_key)
			return
	_repair_fraction_by_builder_id[builder_id] = repair_fraction
	_process_repair_hammer_swing(builder_id, repair_key, delta)
	if not _is_repairable_key(repair_key):
		_finish_repair_assignment(builder_id, repair_key)


func _process_repair_hammer_swing(builder_id: int, repair_key: String, delta: float) -> void:
	var remaining: float = float(_hammer_swing_remaining_by_builder_id.get(builder_id, 0.0))
	remaining -= maxf(0.0, delta)
	if remaining <= 0.0:
		var durability: PlayerPlaceableDurabilityService = _durability()
		if durability != null:
			_builder.play_builder_hammer_swing(builder_id, durability.target_world_position(repair_key))
		while remaining <= 0.0:
			remaining += HAMMER_SWING_INTERVAL_SECONDS
	_hammer_swing_remaining_by_builder_id[builder_id] = remaining


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


# Visual cadence only: one hammer strike per second of actual house progress, each strike
# aimed at the worked house so the target is unambiguous.
func _process_builder_hammer_swing(builder_id: int, house_id: StringName, delta: float) -> void:
	var remaining: float = float(_hammer_swing_remaining_by_builder_id.get(builder_id, 0.0))
	remaining -= maxf(0.0, delta)
	if remaining <= 0.0:
		_builder.play_builder_hammer_swing(
			builder_id,
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
		if _house_by_builder_id.has(builder_id) or _repair_key_by_builder_id.has(builder_id):
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
	if not _repair_work_allowed():
		return false
	for record: Dictionary in _repairable_records_nearest_to(builder_id):
		var repair_key: String = str(record.get("key", ""))
		if _builder_by_repair_key.has(repair_key):
			continue
		if _try_assign_builder_to_repair(builder_id, repair_key):
			return true
	return false


func _try_assign_builder_to_house(builder_id: int, house_id: StringName) -> bool:
	for target_cell: Vector2i in _work_cell_candidates(house_id):
		if _builder.assign_builder_to_work_cell(builder_id, house_id, target_cell):
			_house_by_builder_id[builder_id] = house_id
			_builder_by_house_id[house_id] = builder_id
			_phase_by_builder_id[builder_id] = WORK_PHASE_TRAVEL
			# Counts down only from _advance_work(), so travel to the house never swings and
			# the first strike lands on the first frame of real work.
			_hammer_swing_remaining_by_builder_id[builder_id] = 0.0
			if not _work_seconds_by_house_id.has(house_id):
				_work_seconds_by_house_id[house_id] = 0.0
			return true
	push_warning("HouseBuilderWorkController: no reachable Builder work cell for WIP house '%s'." % String(house_id))
	return false


func _try_assign_builder_to_repair(builder_id: int, repair_key: String) -> bool:
	for target_cell: Vector2i in _repair_work_cell_candidates(repair_key):
		if not _builder.assign_builder_to_work_cell(builder_id, StringName(repair_key), target_cell):
			continue
		_repair_key_by_builder_id[builder_id] = repair_key
		_builder_by_repair_key[repair_key] = builder_id
		_phase_by_builder_id[builder_id] = WORK_PHASE_TRAVEL
		_repair_fraction_by_builder_id[builder_id] = 0.0
		_hammer_swing_remaining_by_builder_id[builder_id] = 0.0
		return true
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


func _repair_assignment_still_valid(builder_id: int, repair_key: String) -> bool:
	return (
		_repair_work_allowed()
		and _builder.is_builder_active(builder_id)
		and not _builder.is_builder_leaving(builder_id)
		and _is_repairable_key(repair_key)
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


func _finish_repair_assignment(builder_id: int, repair_key: String) -> void:
	_clear_repair_assignment_state(builder_id, repair_key)
	_builder.release_builder_from_work(builder_id)
	if _builder.is_builder_leaving(builder_id):
		_mark_assignment_dirty()
		return
	if not _assign_builder_to_next_task(builder_id):
		_builder.return_builder_to_idle_area(builder_id)
	_mark_assignment_dirty()


func _cancel_all_repair_assignments() -> void:
	for raw_builder_id: Variant in _repair_key_by_builder_id.keys():
		_cancel_repair_assignment(int(raw_builder_id), true, true)


func _cancel_repair_assignment(builder_id: int, release_builder: bool, return_to_idle: bool) -> void:
	if not _repair_key_by_builder_id.has(builder_id):
		return
	var repair_key: String = str(_repair_key_by_builder_id.get(builder_id, ""))
	_clear_repair_assignment_state(builder_id, repair_key)
	if release_builder:
		_builder.release_builder_from_work(builder_id)
		if return_to_idle and not GameState.is_night:
			_builder.return_builder_to_idle_area(builder_id)


func _clear_repair_assignment_state(builder_id: int, repair_key: String) -> void:
	_repair_key_by_builder_id.erase(builder_id)
	_builder_by_repair_key.erase(repair_key)
	_phase_by_builder_id.erase(builder_id)
	_repair_fraction_by_builder_id.erase(builder_id)
	_builder.stop_builder_hammer_swing(builder_id)
	_hammer_swing_remaining_by_builder_id.erase(builder_id)


func _clear_assignment_state(builder_id: int, house_id: StringName) -> void:
	_house_by_builder_id.erase(builder_id)
	_builder_by_house_id.erase(house_id)
	_phase_by_builder_id.erase(builder_id)
	_pause_remaining_by_builder_id.erase(builder_id)
	# The hammer stays visible; only its swing stops and resets to the normal held pose.
	_builder.stop_builder_hammer_swing(builder_id)
	_hammer_swing_remaining_by_builder_id.erase(builder_id)


func _mark_assignment_dirty() -> void:
	if not GameState.is_night:
		_assignment_dirty = true


func _repair_work_allowed() -> bool:
	if GameState.is_night or _manager == null:
		return false
	return not _manager.is_client_tantrum_active()


func _repairable_records_nearest_to(builder_id: int) -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	var durability: PlayerPlaceableDurabilityService = _durability()
	if durability == null:
		return records
	for raw_record: Variant in durability.damaged_records():
		var record: Dictionary = raw_record as Dictionary
		if _is_repairable_record(record):
			records.append(record)
	var from_cell: Vector2i = _builder.builder_current_cell(builder_id)
	records.sort_custom(Callable(self, "_sort_repair_records").bind(from_cell))
	return records


func _sort_repair_records(a: Dictionary, b: Dictionary, from_cell: Vector2i) -> bool:
	var a_cell: Vector2i = a.get("cell", INVALID_CELL) as Vector2i
	var b_cell: Vector2i = b.get("cell", INVALID_CELL) as Vector2i
	var a_distance: int = _cell_distance_squared(a_cell, from_cell)
	var b_distance: int = _cell_distance_squared(b_cell, from_cell)
	if a_distance == b_distance:
		return str(a.get("key", "")) < str(b.get("key", ""))
	return a_distance < b_distance


func _repair_record(repair_key: String) -> Dictionary:
	var durability: PlayerPlaceableDurabilityService = _durability()
	if durability == null or repair_key == "" or not durability.is_target_valid(repair_key):
		return {}
	return durability.target_record(repair_key)


func _is_repairable_key(repair_key: String) -> bool:
	return _is_repairable_record(_repair_record(repair_key))


func _is_repairable_record(record: Dictionary) -> bool:
	if record.is_empty():
		return false
	var health: int = int(record.get("health", 0))
	var max_health: int = int(record.get("max_health", 0))
	return health > 0 and health < max_health


func _durability() -> PlayerPlaceableDurabilityService:
	return _manager.get_player_placeable_durability_service() if _manager != null else null


func _on_placeable_damaged(
		_cell: Vector2i,
		_layer_name: StringName,
		_item_id: String,
		_remaining_health: int,
		_max_health: int
) -> void:
	_mark_assignment_dirty()


func _repair_work_cell_candidates(repair_key: String) -> Array[Vector2i]:
	if _work_cell_candidates_by_repair_key.has(repair_key):
		return _work_cell_candidates_by_repair_key[repair_key] as Array[Vector2i]
	var record: Dictionary = _repair_record(repair_key)
	var target: Vector2i = record.get("cell", INVALID_CELL) as Vector2i
	if target == INVALID_CELL:
		return []
	var candidates: Array[Vector2i] = []
	for ring: int in range(1, REPAIR_WORK_CELL_SEARCH_RADIUS + 1):
		for y: int in range(target.y - ring, target.y + ring + 1):
			for x: int in range(target.x - ring, target.x + ring + 1):
				if abs(x - target.x) != ring and abs(y - target.y) != ring:
					continue
				var candidate: Vector2i = Vector2i(x, y)
				if not _manager.has_floor_cell(candidate) or not _manager.is_walkable_cell(candidate):
					continue
				candidates.append(candidate)
	_work_cell_candidates_by_repair_key[repair_key] = candidates
	return candidates


func _cell_distance_squared(a: Vector2i, b: Vector2i) -> int:
	var offset: Vector2i = a - b
	return offset.x * offset.x + offset.y * offset.y


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
