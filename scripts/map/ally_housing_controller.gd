extends RefCounted
class_name AllyHousingController

# Villager (house-resident) orchestrator and handler registry.
#
# A villager is an ally agent that lives in a house, reconstructed from the completed-house
# records rather than serialized independently. This controller reconciles which villagers
# should exist and drives their whole lifecycle (day arrival, night return, house-destruction
# evacuation, repath, removal) WITHOUT knowing individual role names: it fans every lifecycle
# operation out to a list of registered HouseResidentHandler instances through a narrow contract.
#
# Two handler flavours exist:
#   * HouseResidentController — the reusable ordinary one-house/one-resident lifecycle. The seed
#     merchant uses it today; a future ordinary villager (e.g. the Inventor) registers another
#     instance with its own HouseResidentConfig and NO changes here.
#   * BuilderResidentHandler — a specialized adapter over BuilderController. Builders stay special
#     because they build houses, own work queues, and carry the fundamental-Builder onboarding /
#     cutscene / first-house ownership. Only Builder-specific availability is asked of it below.
#
# Registering a future ordinary villager touches exactly one place: BuildingManager builds its
# role + HouseResidentController and passes it into setup(); everything here already handles it.
#
# Terminology note: AgentTileInteractionController's crush classification is a *behavior* rule
# (people/monsters that crush placeables by walking), driven by the per-agent `crushes_placeables`
# meta — it is unrelated to house residency and intentionally includes clients.

const HOUSE_BUILDER_ID: StringName = &"house_builder"
const HOUSE_MERCHANT_ID: StringName = &"house_merchant"

var _manager: BuildingManager = null
var _house_manager: HouseManager = null
var _builder_handler: BuilderResidentHandler = null
var _handlers: Array[HouseResidentHandler] = []


func setup(
		manager: BuildingManager,
		house_manager: HouseManager,
		builder: BuilderController,
		ordinary_residents: Array[HouseResidentController]
) -> void:
	_manager = manager
	_house_manager = house_manager
	_builder_handler = BuilderResidentHandler.new()
	_builder_handler.setup(manager, house_manager, builder)
	# Builders reconcile first so the fundamental-Builder pass runs before ordinary residents;
	# the shared work-controller topology refresh then runs once after all reconciles.
	_handlers.clear()
	_handlers.append(_builder_handler)
	for resident: HouseResidentController in ordinary_residents:
		_handlers.append(resident)
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


# ---------------------------------------------------------------------------
# Lifecycle fan-out.
# ---------------------------------------------------------------------------

func begin_day() -> void:
	reconcile_daytime_residents()


func on_night_started() -> void:
	for handler: HouseResidentHandler in _handlers:
		handler.on_night_started()


func start_pending_departures() -> void:
	for handler: HouseResidentHandler in _handlers:
		handler.start_pending_departures()


func reconcile_daytime_residents() -> void:
	if GameState.is_night or _house_manager == null:
		return
	for handler: HouseResidentHandler in _handlers:
		handler.reconcile_houses()
	# House-builder work is recomputed once, after every resident has been reconciled, so it sees
	# the final villager roster this frame (unchanged ordering from the pre-registry code).
	if _manager != null:
		_manager.get_house_builder_work_controller().on_topology_changed()


## Per-frame agent-pass update for all residents (arrival + interaction proximity).
func process(delta: float) -> void:
	for handler: HouseResidentHandler in _handlers:
		handler.process(delta)


## Per-frame phase-pass update for all residents (role phase state).
func process_phase(delta: float) -> void:
	for handler: HouseResidentHandler in _handlers:
		handler.process_phase(delta)


## Repath every active resident after a walkability change (never a synchronous nav rebuild).
func repath_residents() -> void:
	for handler: HouseResidentHandler in _handlers:
		handler.repath_for_walkability_change()


## Route a removed resident agent to the handler that owns it, so its state/mappings are cleared.
func on_agent_removed(agent: Node2D) -> void:
	for handler: HouseResidentHandler in _handlers:
		if handler.owns_agent(agent):
			handler.on_agent_removed(agent)
			return


func owns_agent(agent: Node2D) -> bool:
	for handler: HouseResidentHandler in _handlers:
		if handler.owns_agent(agent):
			return true
	return false


# ---------------------------------------------------------------------------
# House build-menu availability (generic catalog rules + Builder-house special case).
# ---------------------------------------------------------------------------

func is_house_build_item_available(item_id: String) -> bool:
	item_id = ItemCatalog.normalize_house_item_id(item_id)
	if GameState.is_night:
		return false
	# The first Builder House unlock depends on the fundamental-Builder/tutorial flow, so it stays
	# specialized rather than expressed through a catalog prerequisite field.
	if item_id == String(HOUSE_BUILDER_ID):
		return _builder_handler.is_builder_house_available()
	if _house_manager == null:
		return false
	# Generic rules: a unique house type cannot be duplicated, and a house may require another
	# completed house type first (see ItemCatalog "requires_completed_house_type").
	if ItemCatalog.is_unique_house_type(item_id) and _house_manager.count_existing_houses(StringName(item_id)) > 0:
		return false
	var prerequisite: StringName = ItemCatalog.get_required_completed_house_type(item_id)
	if prerequisite != &"" and _house_manager.count_completed_houses(prerequisite) == 0:
		return false
	return true


func should_show_house_quickslot() -> bool:
	if GameState.is_night:
		return false
	return _builder_handler.should_show_house_quickslot()


func is_fundamental_builder_arrival_pending() -> bool:
	return _builder_handler.fundamental_builder_arrival_pending()


# ---------------------------------------------------------------------------
# HouseManager signal handlers (general house-event work + handler fan-out).
# ---------------------------------------------------------------------------

func _on_houses_restored() -> void:
	if not GameState.is_night and _manager != null:
		_manager.call_deferred("reconcile_ally_housing_after_scene_ready")


func _on_house_completed(snapshot: HouseManager.HouseSnapshot) -> void:
	if snapshot == null or not snapshot.completed:
		return
	if _manager != null and _manager.has_method("notify_player_house_completed"):
		_manager.call("notify_player_house_completed", snapshot.item_id)
	if GameState.is_night:
		return
	for handler: HouseResidentHandler in _handlers:
		handler.on_house_completed(snapshot)


func _on_house_removing(snapshot: HouseManager.HouseSnapshot) -> void:
	if snapshot == null:
		return
	for handler: HouseResidentHandler in _handlers:
		handler.on_house_removing(snapshot)
	if not GameState.is_night and _manager != null:
		_manager.call_deferred("reconcile_ally_housing")
