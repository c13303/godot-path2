extends RefCounted
class_name AllyHousingController

const HOUSE_BUILDER_ID: StringName = &"house_builder"
const HOUSE_MERCHANT_ID: StringName = &"house_merchant"
const RESIDENT_BUILDER: StringName = &"builder"
const RESIDENT_SEED_MERCHANT: StringName = &"seed_merchant"

var _manager: BuildingManager
var _house_manager: HouseManager
var _builder: BuilderController
var _merchant: SeedMerchantController


func setup(
		manager: BuildingManager,
		house_manager: HouseManager,
		builder: BuilderController,
		merchant: SeedMerchantController
) -> void:
	_manager = manager
	_house_manager = house_manager
	_builder = builder
	_merchant = merchant
	if _house_manager != null:
		var completed_callable: Callable = Callable(self, "_on_house_completed")
		var removing_callable: Callable = Callable(self, "_on_house_removing")
		var restored_callable: Callable = Callable(self, "_on_houses_restored")
		if not _house_manager.house_completed.is_connected(completed_callable):
			_house_manager.house_completed.connect(completed_callable)
		if not _house_manager.house_removing.is_connected(removing_callable):
			_house_manager.house_removing.connect(removing_callable)
		if not _house_manager.houses_restored.is_connected(restored_callable):
			_house_manager.houses_restored.connect(restored_callable)


func begin_day() -> void:
	reconcile_daytime_residents()


func on_night_started() -> void:
	if _merchant != null:
		_merchant.on_night_started()
	if _builder != null:
		_builder.on_night_started()


func start_pending_departures() -> void:
	if _merchant != null:
		_merchant.start_pending_leave_if_needed()
	if _builder != null:
		_builder.start_pending_departures()


func reconcile_daytime_residents() -> void:
	if GameState.is_night or _house_manager == null:
		return
	_spawn_missing_house_builders()
	_spawn_missing_house_merchant()
	_reconcile_fundamental_builder()
	if _manager != null:
		_manager.get_house_builder_work_controller().on_topology_changed()


func is_house_build_item_available(item_id: String) -> bool:
	item_id = ItemCatalog.normalize_house_item_id(item_id)
	if GameState.is_night:
		return false
	if item_id == String(HOUSE_BUILDER_ID):
		return _fundamental_builder_has_arrived() or _completed_builder_house_count() > 0
	if item_id == String(HOUSE_MERCHANT_ID):
		return _completed_builder_house_count() > 0 and _house_manager.count_existing_houses(HOUSE_MERCHANT_ID) == 0
	return true


func should_show_house_quickslot() -> bool:
	if GameState.is_night:
		return false
	if _completed_builder_house_count() > 0:
		return true
	return _fundamental_builder_has_arrived()


func _on_houses_restored() -> void:
	if not GameState.is_night and _manager != null:
		_manager.call_deferred("reconcile_ally_housing_after_scene_ready")


func _on_house_completed(snapshot: HouseManager.HouseSnapshot) -> void:
	if snapshot == null or not snapshot.completed:
		return
	if snapshot.item_id == String(HOUSE_BUILDER_ID):
		_retire_fundamental_builder()
	if GameState.is_night:
		return
	_spawn_resident_for_house(snapshot)
	_reconcile_fundamental_builder()


func _on_house_removing(snapshot: HouseManager.HouseSnapshot) -> void:
	if snapshot == null:
		return
	if snapshot.resident_type == RESIDENT_BUILDER and _builder != null:
		_builder.remove_builder_for_house(snapshot.id)
	elif snapshot.resident_type == RESIDENT_SEED_MERCHANT and _merchant != null:
		if _merchant.resident_house_id() == snapshot.id:
			_merchant.evacuate()
	if not GameState.is_night:
		_manager.call_deferred("reconcile_ally_housing")


func _spawn_missing_house_builders() -> void:
	if _builder == null:
		return
	for house_id: StringName in _house_manager.get_completed_house_ids(HOUSE_BUILDER_ID):
		if _builder.active_house_builder_ids().has(house_id):
			continue
		var snapshot: HouseManager.HouseSnapshot = _house_manager.get_house_snapshot(house_id)
		_spawn_resident_for_house(snapshot)


func _spawn_missing_house_merchant() -> void:
	if _merchant == null or _merchant.is_active():
		return
	var ids: Array[StringName] = _house_manager.get_completed_house_ids(HOUSE_MERCHANT_ID)
	if ids.is_empty():
		return
	var snapshot: HouseManager.HouseSnapshot = _house_manager.get_house_snapshot(ids[0])
	_spawn_resident_for_house(snapshot)


func _spawn_resident_for_house(snapshot: HouseManager.HouseSnapshot) -> void:
	if snapshot == null or not snapshot.completed:
		return
	if snapshot.resident_type == RESIDENT_BUILDER and _builder != null:
		_builder.spawn_builder_for_house(snapshot.id, snapshot.entrance_cell)
	elif snapshot.resident_type == RESIDENT_SEED_MERCHANT and _merchant != null:
		_merchant.spawn_for_house(snapshot.id, snapshot.entrance_cell)


func _reconcile_fundamental_builder() -> void:
	if _builder == null:
		return
	if _fundamental_builder_eligible():
		if not _builder.fundamental_builder_active():
			_builder.spawn_fundamental_builder()
	else:
		_retire_fundamental_builder()


func _retire_fundamental_builder() -> void:
	if _builder != null and _builder.fundamental_builder_active():
		_builder.retire_fundamental_builder()


## True while the fundamental Builder is owed to the player but is not on the map yet.
## Read by the onboarding controller, which owes the player an arrival cutscene the first
## time this is true during a build phase.
func is_fundamental_builder_arrival_pending() -> bool:
	return not GameState.is_night and _fundamental_builder_due() and not _fundamental_builder_has_arrived()


func _fundamental_builder_eligible() -> bool:
	return _fundamental_builder_due() and _intro_cutscene_played()


## The fundamental Builder shows up from day 2 and stays until the player has a Builder
## house of their own to staff.
func _fundamental_builder_due() -> bool:
	return _current_day_number() >= 2 and _completed_builder_house_count() == 0


## Its very first arrival is shown by the day-2 build-phase intro cutscene, which spawns it
## on camera. Until that cutscene has been spent the Builder stays off the map, so it is
## never already standing there when the camera goes to look for it.
func _intro_cutscene_played() -> bool:
	return _manager != null and _manager.has_fundamental_builder_intro_cutscene_played()


func _fundamental_builder_has_arrived() -> bool:
	return _builder != null and _builder.fundamental_builder_active()


func _completed_builder_house_count() -> int:
	if _house_manager == null:
		return 0
	return _house_manager.count_completed_houses(HOUSE_BUILDER_ID)


func _current_day_number() -> int:
	if _manager == null:
		return 1
	return _manager.current_day_number()
