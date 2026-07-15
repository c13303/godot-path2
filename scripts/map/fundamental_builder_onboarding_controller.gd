extends RefCounted
class_name FundamentalBuilderOnboardingController

const CUTSCENE_CONTEXT: StringName = &"fundamental_builder_intro"
const TUTORIAL_NOT_STARTED: int = 0
const TUTORIAL_ACTIVE: int = 1
const TUTORIAL_COMPLETED: int = 2
const HOUSE_BUILDER_ITEM_ID: String = "house_builder"

var _manager: BuildingManager
var _cutscene: SpawnerRevealCutsceneController
var _intro_cutscene_played: bool = false
var _builder_house_tutorial_state: int = TUTORIAL_NOT_STARTED
var _pending_intro_builder: Node2D = null


func setup(manager: BuildingManager, cutscene: SpawnerRevealCutsceneController) -> void:
	_manager = manager
	_cutscene = cutscene


func process(_delta: float) -> void:
	_try_start_pending_intro()


func request_intro_cutscene(builder_node: Node2D) -> void:
	if _intro_cutscene_played or builder_node == null or not is_instance_valid(builder_node):
		return
	_pending_intro_builder = builder_node
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


func serialize_state() -> Dictionary:
	return {
		"intro_cutscene_played": _intro_cutscene_played,
		"builder_house_tutorial_state": _builder_house_tutorial_state,
	}


func restore_state(data: Dictionary) -> void:
	_intro_cutscene_played = bool(data.get("intro_cutscene_played", false))
	_builder_house_tutorial_state = _valid_tutorial_state(int(data.get("builder_house_tutorial_state", TUTORIAL_NOT_STARTED)))
	_pending_intro_builder = null


func _try_start_pending_intro() -> void:
	if _intro_cutscene_played or _pending_intro_builder == null or not is_instance_valid(_pending_intro_builder):
		_pending_intro_builder = null
		return
	if _cutscene == null or _cutscene.is_active():
		return
	var items: Array[Dictionary] = [{
		"target_node": _pending_intro_builder,
	}]
	if not _cutscene.begin(CUTSCENE_CONTEXT, items):
		return
	_intro_cutscene_played = true
	_pending_intro_builder = null


func _valid_tutorial_state(value: int) -> int:
	if value == TUTORIAL_ACTIVE or value == TUTORIAL_COMPLETED:
		return value
	return TUTORIAL_NOT_STARTED
