extends Node

const CONTEXT: StringName = &"fundamental_builder"
const BUILDER_TEXTURE: Texture2D = preload("res://assets/sprites/legval/fundamental_builder.png")
const BUILDER_FRAME_COUNT: float = 4.0
const CHOICE_OK: String = "ok"

@export var dialog: DialogUI
@export var game_ui: Node
@export var building_manager: Node

var _portrait: Texture2D


func _ready() -> void:
	_portrait = _build_portrait_texture()
	set_process(true)


func _process(_delta: float) -> void:
	if dialog == null or not dialog.is_open_for(CONTEXT):
		return
	if not _is_builder_interactable():
		dialog.close_dialog(&"builder_unavailable")


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
		Callable(),
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
	if building_manager.has_method("has_fundamental_builder_reached_spot") and not bool(building_manager.call("has_fundamental_builder_reached_spot")):
		return false
	if building_manager.has_method("is_player_near_fundamental_builder") and not bool(building_manager.call("is_player_near_fundamental_builder")):
		return false
	return true


func _on_closed(_reason: StringName) -> void:
	if building_manager != null and building_manager.has_method("activate_builder_house_tutorial_from_dialog"):
		building_manager.call("activate_builder_house_tutorial_from_dialog")


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
