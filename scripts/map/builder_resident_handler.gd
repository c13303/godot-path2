extends HouseResidentHandler
class_name BuilderResidentHandler

## Specialized HouseResidentHandler for Builders. Builders stay special because they construct
## houses, own work queues and hammer visuals, and — for the fundamental Builder — carry
## onboarding, the intro cutscene, first-house ownership, idle-return and fallback behavior.
## None of that fits the ordinary one-house/one-resident lifecycle, so this adapter keeps all
## Builder reconcile/night/removal logic here (delegating to BuilderController) while presenting
## the same narrow contract AllyHousingController uses for every resident type.
##
## The fundamental Builder is due from day 2, persists independently once its intro cutscene has
## been spent, and (once a Builder House exists) becomes that house's resident.

const RESIDENT_BUILDER: StringName = &"builder"
const FUNDAMENTAL_BUILDER_DUE_DAY: int = 2

var _manager: BuildingManager = null
var _house_manager: HouseManager = null
var _builder: BuilderController = null


func setup(manager: BuildingManager, house_manager: HouseManager, builder: BuilderController) -> void:
	_manager = manager
	_house_manager = house_manager
	_builder = builder


# ---------------------------------------------------------------------------
# HouseResidentHandler contract.
# ---------------------------------------------------------------------------

func reconcile_houses() -> void:
	if _builder == null or _house_manager == null:
		return
	_reconcile_fundamental_builder()
	_spawn_missing_house_builders()


func process(delta: float) -> void:
	if _builder == null:
		return
	_builder.process_fundamental_builder_proximity(
		_manager.is_fundamental_builder_dialog_pending(),
		SeedMerchantController.INTERACT_RADIUS_TILES
	)
	_builder.process_arrivals()
	_builder.process_active_visitors(delta)


func on_night_started() -> void:
	if _builder != null:
		_builder.on_night_started()


func start_pending_departures() -> void:
	if _builder != null:
		_builder.start_pending_departures()


func repath_for_walkability_change() -> void:
	if _builder != null:
		_builder.repath_for_walkability_change()


func on_house_completed(snapshot: HouseManager.HouseSnapshot) -> void:
	if _builder == null or snapshot == null or not snapshot.completed or GameState.is_night:
		return
	# Any house completing may make the fundamental Builder due / assign it a house.
	_reconcile_fundamental_builder()
	if snapshot.resident_type == RESIDENT_BUILDER and snapshot.resident_role == HouseManager.RESIDENT_ROLE_NONE:
		_builder.spawn_builder_for_house(snapshot.id, snapshot.entrance_cell)


func on_house_removing(snapshot: HouseManager.HouseSnapshot) -> void:
	if _builder == null or snapshot == null:
		return
	if snapshot.resident_role == HouseManager.RESIDENT_ROLE_FUNDAMENTAL_BUILDER:
		_builder.clear_fundamental_builder_house_assignment()
	elif snapshot.resident_type == RESIDENT_BUILDER:
		_builder.remove_builder_for_house(snapshot.id)


func on_agent_removed(agent: Node2D) -> void:
	if _builder != null:
		_builder.on_agent_removed(agent)


func owns_agent(agent: Node2D) -> bool:
	return _builder != null and _builder.owns_agent(agent)


# ---------------------------------------------------------------------------
# Builder-house availability (queried by AllyHousingController).
# ---------------------------------------------------------------------------

## The Builder House unlocks the moment the fundamental Builder has arrived (its first house) or
## any Builder House is already completed. This first-house onboarding rule stays specialized
## because it depends on the fundamental-Builder/tutorial flow, not on a generic catalog field.
func is_builder_house_available() -> bool:
	return fundamental_builder_has_arrived() or completed_builder_house_count() > 0


func should_show_house_quickslot() -> bool:
	return completed_builder_house_count() > 0 or fundamental_builder_has_arrived()


func completed_builder_house_count() -> int:
	if _house_manager == null:
		return 0
	return _house_manager.count_completed_houses(AllyHousingController.HOUSE_BUILDER_ID)


func fundamental_builder_has_arrived() -> bool:
	return _builder != null and _builder.fundamental_builder_active()


## True while the fundamental Builder is owed to the player but is not on the map yet. Read by the
## onboarding controller, which owes the player an arrival cutscene the first time this is true
## during a build phase.
func fundamental_builder_arrival_pending() -> bool:
	if _house_manager != null and _house_manager.fundamental_builder_house_id() != &"":
		return false
	return not GameState.is_night and _fundamental_builder_due() and not fundamental_builder_has_arrived()


# ---------------------------------------------------------------------------
# Fundamental / normal Builder reconciliation (moved out of AllyHousingController).
# ---------------------------------------------------------------------------

func _spawn_missing_house_builders() -> void:
	var expected_house_ids: Array[StringName] = _house_manager.get_completed_normal_resident_house_ids(AllyHousingController.HOUSE_BUILDER_ID)
	for active_house_id: StringName in _builder.active_house_builder_ids():
		if active_house_id == _house_manager.fundamental_builder_house_id():
			continue
		if not expected_house_ids.has(active_house_id):
			_builder.remove_builder_for_house(active_house_id)
	for house_id: StringName in expected_house_ids:
		if _builder.active_house_builder_ids().has(house_id):
			continue
		var snapshot: HouseManager.HouseSnapshot = _house_manager.get_house_snapshot(house_id)
		if snapshot != null and snapshot.completed:
			_builder.spawn_builder_for_house(snapshot.id, snapshot.entrance_cell)


func _reconcile_fundamental_builder() -> void:
	var house_id: StringName = _house_manager.fundamental_builder_house_id()
	if house_id != &"":
		var snapshot: HouseManager.HouseSnapshot = _house_manager.get_house_snapshot(house_id)
		if snapshot == null or not snapshot.completed:
			_builder.clear_fundamental_builder_house_assignment()
			return
		if _builder.fundamental_builder_active():
			_builder.assign_fundamental_builder_to_house(snapshot.id, snapshot.entrance_cell)
		elif _fundamental_builder_due():
			_builder.spawn_fundamental_builder_for_house(snapshot.id, snapshot.entrance_cell)
		return
	if _fundamental_builder_eligible():
		if not _builder.fundamental_builder_active():
			_builder.spawn_fundamental_builder()
		else:
			_builder.clear_fundamental_builder_house_assignment()
	else:
		_retire_fundamental_builder()


func _retire_fundamental_builder() -> void:
	if _builder.fundamental_builder_active():
		_builder.retire_fundamental_builder()


func _fundamental_builder_eligible() -> bool:
	return _fundamental_builder_due() and _intro_cutscene_played()


## The fundamental Builder shows up from day 2 and persists independently of normal builder-house
## residents once the intro cutscene has been spent.
func _fundamental_builder_due() -> bool:
	return _current_day_number() >= FUNDAMENTAL_BUILDER_DUE_DAY


## Its very first arrival is shown by the day-2 build-phase intro cutscene, which spawns it on
## camera. Until that cutscene has been spent the Builder stays off the map.
func _intro_cutscene_played() -> bool:
	return _manager != null and _manager.has_fundamental_builder_intro_cutscene_played()


func _current_day_number() -> int:
	if _manager == null:
		return 1
	return _manager.current_day_number()
