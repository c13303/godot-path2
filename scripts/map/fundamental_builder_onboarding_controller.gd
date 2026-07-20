extends RefCounted
class_name FundamentalBuilderOnboardingController

const CUTSCENE_CONTEXT: StringName = &"fundamental_builder_intro"
const TUTORIAL_KEY_BUILDER_HERE: String = "tutorial.builder_is_here"
const TUTORIAL_NOT_STARTED: int = 0
const TUTORIAL_ACTIVE: int = 1
const TUTORIAL_WAITING_HOUSE_COMPLETION: int = 2
const TUTORIAL_MERCHANT_HOUSE_ACTIVE: int = 3
const TUTORIAL_COMPLETED: int = 4
const TUTORIAL_WAITING_MERCHANT_HOUSE_COMPLETION: int = 5
const HOUSE_BUILDER_ITEM_ID: String = "house_builder"
const HOUSE_MERCHANT_ITEM_ID: String = "house_merchant"
const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)

var _manager: BuildingManager
var _cutscene: SpawnerRevealCutsceneController
var _intro_cutscene_played: bool = false
var _builder_house_tutorial_state: int = TUTORIAL_NOT_STARTED
var _intro_start_requested: bool = false


func setup(manager: BuildingManager, cutscene: SpawnerRevealCutsceneController) -> void:
	_manager = manager
	_cutscene = cutscene
	if not _cutscene.reveal_item.is_connected(_on_cutscene_reveal_item):
		_cutscene.reveal_item.connect(_on_cutscene_reveal_item)
	if not _cutscene.completed.is_connected(_on_cutscene_completed):
		_cutscene.completed.connect(_on_cutscene_completed)


func process(_delta: float) -> void:
	_try_start_requested_intro()


## The fundamental Builder's arrival is introduced by a one-shot cutscene played when the
## build phase of the first day it is due (day 2) starts: the camera scrolls to its
## spawner, the Builder walks in, and the camera returns to the player. The arrival itself
## is the cutscene's reveal, so AllyHousingController holds the Builder back until the
## cutscene has been spent (see `has_fundamental_builder_intro_cutscene_played`).
##
## The request is armed here, but the cutscene does not start until the player confirms
## the tutorial prompt. This keeps day-2 afternoon under player control.
func on_afternoon_started() -> void:
	if _intro_cutscene_played:
		return
	_intro_start_requested = false


func intro_cutscene_played() -> bool:
	return _intro_cutscene_played


func builder_house_tutorial_state() -> int:
	return _builder_house_tutorial_state


func is_builder_house_tutorial_active() -> bool:
	return _builder_house_tutorial_state == TUTORIAL_ACTIVE


func should_suppress_normal_tutorials() -> bool:
	return (
		_builder_house_tutorial_state == TUTORIAL_WAITING_HOUSE_COMPLETION
		or _builder_house_tutorial_state == TUTORIAL_MERCHANT_HOUSE_ACTIVE
		or _builder_house_tutorial_state == TUTORIAL_WAITING_MERCHANT_HOUSE_COMPLETION
	)


## Drives the "let the Builder build" hint, which is onboarding for the very first house only:
## it plays while the first builder house is under construction and never again. The merchant
## house that follows is waited out silently — by then the player has seen a Builder work once.
## should_suppress_normal_tutorials() still covers that wait, so no other hint fills the gap.
func is_waiting_house_completion() -> bool:
	return _builder_house_tutorial_state == TUTORIAL_WAITING_HOUSE_COMPLETION


func is_merchant_house_tutorial_active() -> bool:
	return _builder_house_tutorial_state == TUTORIAL_MERCHANT_HOUSE_ACTIVE


func is_intro_prompt_active() -> bool:
	return (
		not _intro_cutscene_played
		and not _intro_start_requested
		and not GameState.is_night
		and GameState.is_afternoon_phase
		and _manager != null
		and _manager.is_fundamental_builder_arrival_pending()
	)


func request_intro_cutscene() -> bool:
	if _intro_cutscene_played or GameState.is_night:
		return false
	if _manager == null or not _manager.is_fundamental_builder_arrival_pending():
		return false
	_intro_start_requested = true
	_try_start_requested_intro()
	return true


func is_fundamental_builder_dialog_pending() -> bool:
	return _intro_cutscene_played and _builder_house_tutorial_state == TUTORIAL_NOT_STARTED


func is_followup_dialog_pending() -> bool:
	return false


func should_show_followup_dialog_text() -> bool:
	return (
		_builder_house_tutorial_state == TUTORIAL_MERCHANT_HOUSE_ACTIVE
		or _builder_house_tutorial_state == TUTORIAL_WAITING_MERCHANT_HOUSE_COMPLETION
		or _builder_house_tutorial_state == TUTORIAL_COMPLETED
	)


func accept_fundamental_builder_dialog() -> bool:
	if _builder_house_tutorial_state != TUTORIAL_NOT_STARTED:
		return false
	_builder_house_tutorial_state = TUTORIAL_ACTIVE
	# The player may already own the houses these steps ask for (e.g. built on day 1, before the
	# Builder arrived), so start from the first step that still has something to do.
	_skip_steps_for_standing_houses()
	_debug_trace("accept_dialog")
	return true


func accept_followup_dialog() -> bool:
	return false


func activate_builder_house_tutorial_from_dialog() -> void:
	accept_fundamental_builder_dialog()


func notify_player_house_placed(item_id: String) -> void:
	if _builder_house_tutorial_state == TUTORIAL_ACTIVE and item_id == HOUSE_BUILDER_ITEM_ID:
		_builder_house_tutorial_state = TUTORIAL_WAITING_HOUSE_COMPLETION
	elif _builder_house_tutorial_state == TUTORIAL_MERCHANT_HOUSE_ACTIVE and item_id == HOUSE_MERCHANT_ITEM_ID:
		_builder_house_tutorial_state = TUTORIAL_WAITING_MERCHANT_HOUSE_COMPLETION
	_debug_trace("house_placed '%s'" % item_id)


func notify_house_completed(item_id: String) -> void:
	if _builder_house_tutorial_state == TUTORIAL_WAITING_HOUSE_COMPLETION and item_id == HOUSE_BUILDER_ITEM_ID:
		_builder_house_tutorial_state = TUTORIAL_MERCHANT_HOUSE_ACTIVE
	elif item_id == HOUSE_MERCHANT_ITEM_ID \
			and (
				_builder_house_tutorial_state == TUTORIAL_MERCHANT_HOUSE_ACTIVE
				or _builder_house_tutorial_state == TUTORIAL_WAITING_MERCHANT_HOUSE_COMPLETION
			):
		_builder_house_tutorial_state = TUTORIAL_COMPLETED
	_debug_trace("house_completed '%s'" % item_id)


## Only the one-shot latch is saved; the pending flag is deliberately left out. A cutscene
## is not resumable across a save, and the latch is spent the moment the cutscene starts,
## so a save taken while it plays reloads with the Builder simply already on its way.
func serialize_state() -> Dictionary:
	return {
		"intro_cutscene_played": _intro_cutscene_played,
		"builder_house_tutorial_state": _builder_house_tutorial_state,
	}


func restore_state(data: Dictionary) -> void:
	_intro_cutscene_played = bool(data.get("intro_cutscene_played", false))
	_builder_house_tutorial_state = _valid_tutorial_state(int(data.get("builder_house_tutorial_state", TUTORIAL_NOT_STARTED)))
	_intro_start_requested = false
	# Player-built houses are restored before this (see Progression's deferred runtime-simulation
	# restore), so the world is already authoritative about what is standing.
	_skip_steps_for_standing_houses()


func _try_start_requested_intro() -> void:
	if _intro_cutscene_played or not _intro_start_requested:
		return
	if _cutscene == null or _cutscene.is_active():
		return
	if GameState.is_night or not _manager.is_fundamental_builder_arrival_pending():
		_intro_start_requested = false
		return
	var spawner_cell: Vector2i = _manager.named_authored_spot_cell(BuilderController.FUNDAMENTAL_BUILDER_IN_ID)
	if spawner_cell == INVALID_CELL:
		push_warning("FundamentalBuilderOnboardingController: intro cutscene skipped; marker '%s' is missing." % String(BuilderController.FUNDAMENTAL_BUILDER_IN_ID))
		_intro_start_requested = false
		return
	var items: Array[Dictionary] = [{
		"world_position": _manager.cell_center(spawner_cell),
	}]
	if not _cutscene.begin(CUTSCENE_CONTEXT, items, TUTORIAL_KEY_BUILDER_HERE):
		return
	_intro_cutscene_played = true
	_intro_start_requested = false


## Camera has reached the spawner: release the arrival. The latch above is already set, so
## the reconcile that owns Builder spawning now finds the fundamental Builder eligible.
func _on_cutscene_reveal_item(context: StringName, _item_index: int, _item: Dictionary) -> void:
	if context != CUTSCENE_CONTEXT:
		return
	_manager.reconcile_ally_housing()


## The "Builder is here" line belongs to the cutscene only; the contextual hint takes the
## label back the moment the player has control again.
func _on_cutscene_completed(context: StringName, _release_spawning: bool) -> void:
	if context != CUTSCENE_CONTEXT:
		return
	_manager.clear_tutorial_alert(TUTORIAL_KEY_BUILDER_HERE)


## Advances past every house step whose house is already standing, so a step never nags for a
## second, pointless house. This matters because completion is a live signal that fires once:
## a step left waiting on a house that is already up would wait forever, and while it waits
## should_suppress_normal_tutorials() keeps every other hint off. A house still under
## construction is not skipped — it lands on that house's wait step instead.
func _skip_steps_for_standing_houses() -> void:
	if _builder_house_tutorial_state == TUTORIAL_ACTIVE \
			or _builder_house_tutorial_state == TUTORIAL_WAITING_HOUSE_COMPLETION:
		if _completed_house_count(HOUSE_BUILDER_ITEM_ID) > 0:
			_builder_house_tutorial_state = TUTORIAL_MERCHANT_HOUSE_ACTIVE
		elif _standing_house_count(HOUSE_BUILDER_ITEM_ID) > 0:
			_builder_house_tutorial_state = TUTORIAL_WAITING_HOUSE_COMPLETION
	# Not `elif`: when the builder house above was already done, the merchant step it just
	# advanced to may be done too, and both must be skipped in one pass.
	if _builder_house_tutorial_state == TUTORIAL_MERCHANT_HOUSE_ACTIVE \
			or _builder_house_tutorial_state == TUTORIAL_WAITING_MERCHANT_HOUSE_COMPLETION:
		if _completed_house_count(HOUSE_MERCHANT_ITEM_ID) > 0:
			_builder_house_tutorial_state = TUTORIAL_COMPLETED
		elif _standing_house_count(HOUSE_MERCHANT_ITEM_ID) > 0:
			_builder_house_tutorial_state = TUTORIAL_WAITING_MERCHANT_HOUSE_COMPLETION


## Player-built houses of `item_id` that are finished. Read live off HouseManager, the only owner
## of houses: they are never registered as building objects. Authored level houses do not count —
## these steps ask the player to build one themselves.
func _completed_house_count(item_id: String) -> int:
	var houses: HouseManager = _house_manager()
	if houses == null:
		return 0
	return houses.count_completed_player_built_houses(StringName(item_id))


## Player-built houses of `item_id` standing, whether finished or still under construction.
func _standing_house_count(item_id: String) -> int:
	var houses: HouseManager = _house_manager()
	if houses == null:
		return 0
	return houses.count_player_built_houses(StringName(item_id))


func _house_manager() -> HouseManager:
	if _manager == null:
		return null
	return _manager.get_house_manager()


## TEMPORARY onboarding-step trace. Gated behind Debug Enabled, no gameplay effect.
## Remove once the "build a builder house" step stops re-showing.
func _debug_trace(tag: String) -> void:
	if not CppDebugOptions.logs_enabled:
		return
	CppDebugOptions.dlog("[BUILDER-ONBOARDING] %s -> state=%d builder(done=%d standing=%d) merchant(done=%d standing=%d)" % [
		tag,
		_builder_house_tutorial_state,
		_completed_house_count(HOUSE_BUILDER_ITEM_ID),
		_standing_house_count(HOUSE_BUILDER_ITEM_ID),
		_completed_house_count(HOUSE_MERCHANT_ITEM_ID),
		_standing_house_count(HOUSE_MERCHANT_ITEM_ID),
	])


func _valid_tutorial_state(value: int) -> int:
	if value == TUTORIAL_WAITING_HOUSE_COMPLETION \
			or value == TUTORIAL_ACTIVE \
			or value == TUTORIAL_MERCHANT_HOUSE_ACTIVE \
			or value == TUTORIAL_COMPLETED \
			or value == TUTORIAL_WAITING_MERCHANT_HOUSE_COMPLETION:
		return value
	return TUTORIAL_NOT_STARTED
