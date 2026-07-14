extends RefCounted
class_name BuilderController

const DEFAULT_BUILDER_COUNT: int = 1
const BUILDER_SPOT_CLAIM_RADIUS: int = 6
const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)
const AGENT_KIND_BUILDER: StringName = &"builder"
const BUILDER_GROUP: StringName = &"builders"
const VISITOR_CATEGORY: StringName = &"builders"
const SOURCE_SPAWNER_ID: StringName = &"seedmerchent"
const BUILDER_SPOT_ID: StringName = &"builder_spot"

var _manager: BuildingManager
var _desired_count: int = DEFAULT_BUILDER_COUNT
var _visitors: Array[DayVisitorMovementController] = []
var _claimed_cells: Dictionary = {}  # Vector2i -> DayVisitorMovementController


func setup(manager: BuildingManager) -> void:
	_manager = manager


func builder_count() -> int:
	return _desired_count


func active_builder_count() -> int:
	_clean_invalid_visitors()
	return _visitors.size()


func is_any_builder_active() -> bool:
	return active_builder_count() > 0


func set_builder_count(value: int) -> void:
	_desired_count = maxi(0, value)


func add_builders_for_dev(amount: int = 1) -> bool:
	var old_count: int = _desired_count
	_desired_count = maxi(0, _desired_count + maxi(0, amount))
	if _desired_count == old_count:
		return false
	if GameState.is_night:
		CppDebugOptions.dlog("dev_keys: Builder roster %d -> %d; spawn deferred until next day" % [old_count, _desired_count])
		return true
	var spawned: int = _spawn_missing_builders()
	if spawned <= 0 and active_builder_count() < _desired_count:
		CppDebugOptions.dlog("dev_keys: Builder roster %d -> %d; spawn deferred until next day" % [old_count, _desired_count])
	else:
		CppDebugOptions.dlog("dev_keys: Builder roster %d -> %d; active Builders: %d" % [old_count, _desired_count, active_builder_count()])
	return true


func begin_day() -> void:
	clear_active_builders(true)
	if GameState.is_night:
		return
	_spawn_missing_builders()


func on_night_started() -> void:
	for visitor: DayVisitorMovementController in _visitors:
		_release_claim_for(visitor)
		visitor.mark_leave_pending()


func start_pending_departures() -> void:
	for visitor: DayVisitorMovementController in _visitors.duplicate():
		if visitor == null:
			continue
		visitor.start_pending_leave_if_needed()


func process_arrivals() -> void:
	for visitor: DayVisitorMovementController in _visitors.duplicate():
		if visitor == null:
			continue
		if not visitor.is_active():
			_remove_visitor(visitor)
			continue
		visitor.process_arrival()


func process_active_visitors() -> void:
	_clean_invalid_visitors()


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


func restore_state(raw_count: Variant) -> void:
	clear_active_builders(true)
	_desired_count = DEFAULT_BUILDER_COUNT
	if raw_count is int or raw_count is float:
		_desired_count = maxi(0, int(raw_count))
	elif raw_count is String and str(raw_count).is_valid_int():
		_desired_count = maxi(0, int(str(raw_count)))
	if not GameState.is_night:
		_manager.call_deferred("_restore_builders_after_load")


func restore_after_load() -> void:
	await _manager.get_tree().process_frame
	await _manager.get_tree().process_frame
	if not GameState.is_night:
		_spawn_missing_builders()


func repath_for_walkability_change() -> void:
	_clean_invalid_visitors()
	for visitor: DayVisitorMovementController in _visitors.duplicate():
		if visitor == null or not visitor.is_active() or visitor.is_leaving():
			continue
		var target: Vector2i = visitor.target_cell()
		if _claim_still_valid(visitor, target) and visitor.repath_to_current_target():
			continue
		_release_claim_for(visitor)
		var replacement: Vector2i = _find_claim_for_visitor(visitor.source_spawner_cell(), visitor)
		if replacement == INVALID_CELL:
			push_warning("BuilderController: no replacement Builder target near %s within radius %d; Builder kept at current safe position when possible." % [_builder_spot_cell(), BUILDER_SPOT_CLAIM_RADIUS])
			continue
		_claimed_cells[replacement] = visitor
		if not visitor.repath_to_target(replacement):
			_claimed_cells.erase(replacement)
			push_warning("BuilderController: Builder replacement target %s became unreachable during repath." % replacement)


func _spawn_missing_builders() -> int:
	_clean_invalid_visitors()
	if GameState.is_night:
		return 0
	var source_binding: SpawnerBinding = _source_binding()
	if source_binding == null:
		push_warning("BuilderController: Builder day skipped; required spawner '%s' was not registered." % String(SOURCE_SPAWNER_ID))
		return 0
	var spot_cell: Vector2i = _builder_spot_cell()
	if spot_cell == INVALID_CELL:
		push_warning("BuilderController: Builder day skipped; required spot '%s' was not registered." % String(BUILDER_SPOT_ID))
		return 0
	var spawned: int = 0
	var reserved_spawn_cells: Array[Vector2i] = []
	while active_builder_count() < _desired_count:
		var occupied: Array[Vector2i] = _manager.occupied_cells_for_spawning()
		for reserved: Vector2i in reserved_spawn_cells:
			occupied.append(reserved)
		var spawn_cell: Vector2i = _manager.find_free_cell_near_spawner(source_binding.cell, occupied)
		if spawn_cell == INVALID_CELL:
			_warn_missing_builder(spot_cell)
			break
		var target_cell: Vector2i = _find_claim_from_spawn(spawn_cell, null)
		if target_cell == INVALID_CELL:
			_warn_missing_builder(spot_cell)
			break
		var visitor: DayVisitorMovementController = DayVisitorMovementController.new()
		visitor.setup(_manager, "Builder")
		_claimed_cells[target_cell] = visitor
		if not visitor.spawn(
				source_binding.cell,
				spawn_cell,
				target_cell,
				AGENT_KIND_BUILDER,
				BUILDER_GROUP,
				VISITOR_CATEGORY,
				Callable(_manager, "apply_builder_data")
		):
			_claimed_cells.erase(target_cell)
			break
		_visitors.append(visitor)
		reserved_spawn_cells.append(spawn_cell)
		spawned += 1
	return spawned


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


func _find_claim_from_spawn(spawn_cell: Vector2i, visitor: DayVisitorMovementController) -> Vector2i:
	var anchor: Vector2i = _builder_spot_cell()
	for candidate: Vector2i in _target_candidates(anchor):
		if not _is_candidate_available(candidate, visitor):
			continue
		var path_cells: PackedVector2Array = _manager.find_path_on_walkable_map(spawn_cell, candidate)
		if path_cells.is_empty():
			continue
		return candidate
	return INVALID_CELL


func _target_candidates(anchor: Vector2i) -> Array[Vector2i]:
	var candidates: Array[Vector2i] = [anchor]
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
	if cell == _manager.seed_merchant_spot_cell_for_exact_spawner(SOURCE_SPAWNER_ID):
		return false
	if visitor != null and visitor.target_cell() == cell:
		return true
	var occupied: Array[Vector2i] = _manager.occupied_cells_for_spawning()
	return not occupied.has(cell)


func _claim_still_valid(visitor: DayVisitorMovementController, cell: Vector2i) -> bool:
	return _is_candidate_available(cell, visitor)


func _source_binding() -> SpawnerBinding:
	return _manager.level_spawner_binding(SOURCE_SPAWNER_ID)


func _builder_spot_cell() -> Vector2i:
	return _manager.named_authored_spot_cell(BUILDER_SPOT_ID)


func _warn_missing_builder(spot_cell: Vector2i) -> void:
	push_warning("BuilderController: unable to spawn full Builder roster; desired=%d active=%d anchor=%s radius=%d." % [
		_desired_count,
		active_builder_count(),
		spot_cell,
		BUILDER_SPOT_CLAIM_RADIUS,
	])


func _remove_visitor(visitor: DayVisitorMovementController) -> void:
	_release_claim_for(visitor)
	_visitors.erase(visitor)
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
