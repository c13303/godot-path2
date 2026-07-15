extends Node

const CONTEXT: StringName = &"fundamental_builder"
const BUILDER_TEXTURE: Texture2D = preload("res://assets/sprites/legval/fundamental_builder.png")
const BUILDER_FRAME_COUNT: float = 4.0
const CHOICE_OK: String = "ok"
const INTRO_REWARD_GEMS: int = 20
const GEM_CURRENCY: StringName = &"gem"

@export var dialog: DialogUI
@export var game_ui: Node
@export var building_manager: Node

var _portrait: Texture2D


func _ready() -> void:
	_portrait = _build_portrait_texture()


func request_dialog_toggle() -> bool:
	if dialog == null:
		return false
	if dialog.is_open_for(CONTEXT):
		return true
	if dialog.is_open():
		return false
	if not _is_builder_interactable():
		return false
	_open_dialog()
	return true


func is_dialog_open() -> bool:
	return dialog != null and dialog.is_open_for(CONTEXT)


func _open_dialog() -> void:
	if game_ui != null and game_ui.has_method("deactivate_quickbar"):
		game_ui.call("deactivate_quickbar")
	dialog.open_dialog(
		CONTEXT,
		_speaker_name(),
		Translations.t("builder.fundamental.greeting"),
		_portrait,
		[{
			"id": CHOICE_OK,
			"label": Translations.t("ui.ok"),
			"enabled": true,
			"close_on_select": true,
		}],
		_on_choice_selected,
		_on_closed,
		{"blocks_gameplay_input": true}
	)


func _is_builder_interactable() -> bool:
	if GameState.is_night:
		return false
	if building_manager == null:
		return false
	if building_manager.has_method("is_any_reveal_cutscene_active") and bool(building_manager.call("is_any_reveal_cutscene_active")):
		return false
	if building_manager.has_method("is_fundamental_builder_active") and not bool(building_manager.call("is_fundamental_builder_active")):
		return false
	if building_manager.has_method("is_player_near_fundamental_builder") and not bool(building_manager.call("is_player_near_fundamental_builder")):
		return false
	return true


func _on_choice_selected(choice_id: String, source_global_position: Vector2) -> void:
	if choice_id != CHOICE_OK:
		return
	if building_manager == null or not building_manager.has_method("accept_fundamental_builder_dialog"):
		return
	var accepted: bool = bool(building_manager.call("accept_fundamental_builder_dialog"))
	if accepted:
		if game_ui != null and game_ui.has_method("refresh_quickbar_availability"):
			game_ui.call("refresh_quickbar_availability")
		_award_intro_gems(source_global_position)


func _on_closed(_reason: StringName) -> void:
	pass


func _award_intro_gems(source_global_position: Vector2) -> void:
	var world_position: Vector2 = get_viewport().get_canvas_transform().affine_inverse() * source_global_position
	if game_ui != null and game_ui.has_method("collect_currency_from_world"):
		var started: bool = bool(game_ui.call("collect_currency_from_world", GEM_CURRENCY, world_position, INTRO_REWARD_GEMS))
		if started:
			return
	var scene: Node = get_tree().current_scene
	var progression_node: Node = scene.get_node_or_null("progression") if scene != null else null
	if progression_node != null and progression_node.has_method("update_gems"):
		progression_node.call("update_gems", INTRO_REWARD_GEMS)


func _speaker_name() -> String:
	var key: String = "item.house_builder"
	var translated: String = Translations.t(key)
	return translated if translated != key else "Builder House"


func _build_portrait_texture() -> Texture2D:
	var frame_width: float = float(BUILDER_TEXTURE.get_width()) / BUILDER_FRAME_COUNT
	var frame_height: float = float(BUILDER_TEXTURE.get_height())
	var atlas: AtlasTexture = AtlasTexture.new()
	atlas.atlas = BUILDER_TEXTURE
	atlas.region = Rect2(Vector2.ZERO, Vector2(frame_width, frame_height))
	return atlas
