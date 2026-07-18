extends Node

## Sheep adapter for the generic DialogUI. The sheep just introduces itself — it has nothing to
## sell, so the dialog is a greeting and an OK. Everything else — spawn, arrival, night return,
## evacuation, repath, removal, identity — is the shared HouseResidentController lifecycle
## registered in BuildingManager, and the debris-eating it talks about is SheepGardenRole.
##
## It plugs into the generic nearest-interaction router by joining the &"interaction_targets" group
## and implementing the small duck-typed contract (can_interact / get_interaction_world_position /
## request_interaction / is_interaction_open); PlayerController is untouched.

const CONTEXT: StringName = &"sheep"
const RESIDENT_TYPE: StringName = &"sheep"
const INTERACTION_BUBBLE_REASON: StringName = &"sheep_interaction"
const INTERACT_RADIUS_TILES: int = 2
const SHEEP_TEXTURE: Texture2D = preload("res://assets/sprites/legval/sheep_villager.png")
const ITEMS_TEXTURE: Texture2D = preload("res://assets/sprites/legval/items.png")
# The sheep sprite sheet holds this many horizontal frames; the first is the portrait.
const SHEEP_FRAME_COUNT: float = 4.0
# Inline placeholder substituted with the gem currency icon inside the greeting text.
const GEM_ICON_PLACEHOLDER: String = "{gem_icon}"
const GEM_CURRENCY: StringName = &"gem"
const CHOICE_OK: String = "ok"

@export var dialog: DialogUI
@export var game_ui: Node
@export var building_manager: Node

var _portrait: Texture2D
var _gem_icon: Texture2D


func _ready() -> void:
	_portrait = _build_portrait_texture()
	_gem_icon = _build_gem_icon_texture()
	add_to_group(&"interaction_targets")


# --- InteractionRouter contract ----------------------------------------------

func can_interact() -> bool:
	return _is_sheep_active()


func get_interaction_world_position() -> Vector2:
	if building_manager != null and building_manager.has_method("get_house_resident_world_position"):
		return building_manager.call("get_house_resident_world_position", RESIDENT_TYPE) as Vector2
	return Vector2.ZERO


func get_interaction_radius_tiles() -> int:
	return INTERACT_RADIUS_TILES


func set_interaction_selected(value: bool) -> void:
	if building_manager != null and building_manager.has_method("set_house_resident_interaction_selected"):
		building_manager.call("set_house_resident_interaction_selected", RESIDENT_TYPE, value)
	_set_interaction_bubble(value, false)


func set_interaction_input_mode(is_gamepad: bool) -> void:
	_set_interaction_bubble(true, is_gamepad)


func request_interaction() -> bool:
	return _request_dialog_toggle()


func is_interaction_open() -> bool:
	return dialog != null and dialog.is_open_for(CONTEXT)


func _set_interaction_bubble(active: bool, is_gamepad: bool) -> void:
	if building_manager == null or not building_manager.has_method("get_house_resident_agent"):
		return
	var agent: Node2D = building_manager.call("get_house_resident_agent", RESIDENT_TYPE) as Node2D
	if agent != null and agent.has_method("set_bubble_notification_frame"):
		var frame: int = 2 if is_gamepad else 1
		agent.call("set_bubble_notification_frame", INTERACTION_BUBBLE_REASON, active, frame)


# --- Opening -----------------------------------------------------------------

func _request_dialog_toggle() -> bool:
	if dialog == null:
		return false
	if dialog.is_open_for(CONTEXT):
		return true
	if dialog.is_open():
		return false
	if not _is_sheep_active():
		return false
	_open_dialog()
	return true


func _open_dialog() -> void:
	# Close any open build/weapon quickbar menu so it does not linger under the modal.
	if game_ui != null and game_ui.has_method("deactivate_quickbar"):
		game_ui.call("deactivate_quickbar")
	dialog.open_dialog(
		CONTEXT,
		Translations.t("sheep.name"),
		Translations.t("sheep.greeting"),
		_portrait,
		[{
			"id": CHOICE_OK,
			"label": Translations.t("ui.ok"),
			"enabled": true,
			"close_on_select": true,
		}],
		Callable(),
		Callable(),
		{
			"blocks_gameplay_input": true,
			"body_icons": {GEM_ICON_PLACEHOLDER: _gem_icon},
		}
	)


func _is_sheep_active() -> bool:
	if GameState.is_night:
		return false
	if building_manager == null:
		return false
	if building_manager.has_method("has_house_resident_reached_spot") and not bool(building_manager.call("has_house_resident_reached_spot", RESIDENT_TYPE)):
		return false
	return true


# --- Icons -------------------------------------------------------------------

func _build_portrait_texture() -> Texture2D:
	# Build the region from the actual texture dimensions instead of assuming a fixed size, so the
	# first (portrait) frame is extracted the same way as the other villager dialogs.
	var frame_width: float = float(SHEEP_TEXTURE.get_width()) / SHEEP_FRAME_COUNT
	var frame_height: float = float(SHEEP_TEXTURE.get_height())
	var atlas: AtlasTexture = AtlasTexture.new()
	atlas.atlas = SHEEP_TEXTURE
	atlas.region = Rect2(Vector2.ZERO, Vector2(frame_width, frame_height))
	return atlas


func _build_gem_icon_texture() -> Texture2D:
	var atlas: AtlasTexture = AtlasTexture.new()
	atlas.atlas = ITEMS_TEXTURE
	atlas.region = CurrencyCatalog.get_icon_region(GEM_CURRENCY)
	return atlas
