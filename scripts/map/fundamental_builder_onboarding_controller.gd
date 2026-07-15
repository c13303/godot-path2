extends RefCounted
class_name FundamentalBuilderOnboardingController

const CUTSCENE_CONTEXT: StringName = &"fundamental_builder_intro"
const TUTORIAL_KEY_BUILDER_HERE: String = "tutorial.builder_is_here"
const TUTORIAL_NOT_STARTED: int = 0
const TUTORIAL_ACTIVE: int = 1
const TUTORIAL_COMPLETED: int = 2
const HOUSE_BUILDER_ITEM_ID: String = "house_builder"
const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)

var _manager: BuildingManager
var _cutscene: SpawnerRevealCutsceneController
var _intro_cutscene_played: bool = false
var _builder_house_tutorial_state: int = TUTORIAL_NOT_STARTED
var _intro_pending: bool = false


func setup(manager: BuildingManager, cutscene: SpawnerRevealCutsceneController) -> void:
	_manager = manager
	_cutscene = cutscene
	if not _cutscene.reveal_item.is_connected(_on_cutscene_reveal_item):
		_cutscene.reveal_item.connect(_on_cutscene_reveal_item)
	if not _cutscene.completed.is_connected(_on_cutscene_completed):
		_cutscene.completed.connect(_on_cutscene_completed)


func process(_delta: float) -> void:
	_try_start_pending_intro()


## The fundamental Builder's arrival is introduced by a one-shot cutscene played when the
## build phase of the first day it is due (day 2) starts: the camera scrolls to its
## spawner, the Builder walks in, and the camera returns to the player. The arrival itself
## is the cutscene's reveal, so AllyHousingController holds the Builder back until the
## cutscene has been spent (see `has_fundamental_builder_intro_cutscene_played`).
##
## The request is armed here and started from process() so a cutscene that is still
## running is waited out instead of being cut short.
func on_afternoon_started() -> void:
	if _intro_cutscene_played:
		return
	_intro_pending = true
	_try_start_pending_intro()


func intro_cutscene_played() -> bool:
	return _intro_cutscene_played


func builder_house_tutorial_state() -> int:
	return _builder_house_tutorial_state


func is_builder_house_tutorial_active() -> bool:
	return _builder_house_tutorial_state == TUTORIAL_ACTIVE


func activate_builder_house_tutorial_from_dialog() -> void:
	if _builder_house_tutorial_state == TUTORIAL_NOT_STARTED:
		_builder_house_tutorial_state = TUTORIAL_ACTIVE


func notify_player_house_placed(item_id: String) -> void:
	if _builder_house_tutorial_state == TUTORIAL_ACTIVE and item_id == HOUSE_BUILDER_ITEM_ID:
		_builder_house_tutorial_state = TUTORIAL_COMPLETED


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
	_intro_pending = false


func _try_start_pending_intro() -> void:
	if _intro_cutscene_played or not _intro_pending:
		return
	if _cutscene == null or _cutscene.is_active():
		return
	if GameState.is_night or not _manager.is_fundamental_builder_arrival_pending():
		_intro_pending = false
		return
	var spawner_cell: Vector2i = _manager.named_authored_spot_cell(BuilderController.FUNDAMENTAL_BUILDER_IN_ID)
	if spawner_cell == INVALID_CELL:
		push_warning("FundamentalBuilderOnboardingController: intro cutscene skipped; marker '%s' is missing." % String(BuilderController.FUNDAMENTAL_BUILDER_IN_ID))
		_intro_pending = false
		return
	var items: Array[Dictionary] = [{
		"world_position": _manager.cell_center(spawner_cell),
	}]
	if not _cutscene.begin(CUTSCENE_CONTEXT, items, TUTORIAL_KEY_BUILDER_HERE):
		return
	_intro_cutscene_played = true
	_intro_pending = false


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


func _valid_tutorial_state(value: int) -> int:
	if value == TUTORIAL_ACTIVE or value == TUTORIAL_COMPLETED:
		return value
	return TUTORIAL_NOT_STARTED
