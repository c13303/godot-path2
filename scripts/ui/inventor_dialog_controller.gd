extends Node

## Inventor adapter for the generic DialogUI. The Inventor's ONLY role-specific behavior is this
## conversation: a greeting mentioning an inline money icon and a single OK choice that closes.
## Everything else — spawn, arrival, night return, evacuation, repath, removal, identity — is the
## shared HouseResidentController lifecycle registered in BuildingManager. There is deliberately no
## economy, currency check, reward, unlock, or persistent state here.
##
## It plugs into the generic nearest-interaction router by joining the &"interaction_targets" group
## and implementing the small duck-typed contract (can_interact / get_interaction_world_position /
## request_interaction / is_interaction_open); PlayerController is untouched.

const CONTEXT: StringName = &"inventor"
const RESIDENT_TYPE: StringName = &"inventor"
const INTERACT_RADIUS_TILES: int = 2
const INVENTOR_TEXTURE: Texture2D = preload("res://assets/sprites/legval/inventor.png")
const ITEMS_TEXTURE: Texture2D = preload("res://assets/sprites/legval/items.png")
# The inventor sprite sheet holds this many horizontal frames; the first is the portrait.
const INVENTOR_FRAME_COUNT: float = 4.0
# Inline placeholder substituted with the money currency icon inside the greeting text.
const MONEY_ICON_PLACEHOLDER: String = "{money_icon}"
const MONEY_CURRENCY: StringName = &"money"
const CHOICE_OK: String = "ok"

@export var dialog: DialogUI
@export var game_ui: Node
@export var building_manager: Node

var _portrait: Texture2D
var _money_icon: Texture2D


func _ready() -> void:
	_portrait = _build_portrait_texture()
	_money_icon = _build_money_icon_texture()
	add_to_group(&"interaction_targets")
	set_process(true)


func _process(_delta: float) -> void:
	# Close the conversation if the Inventor stops being interactable while it is open (night falls
	# and it walks home, or the house is destroyed and it is removed). The player is input-locked
	# while the dialog is open, so this never fires merely because the player moved.
	if dialog == null or not dialog.is_open_for(CONTEXT):
		return
	if not _is_inventor_active():
		dialog.close_dialog(&"inventor_unavailable")


# --- InteractionRouter contract ----------------------------------------------

func can_interact() -> bool:
	return _is_inventor_active()


func get_interaction_world_position() -> Vector2:
	if building_manager != null and building_manager.has_method("get_house_resident_world_position"):
		return building_manager.call("get_house_resident_world_position", RESIDENT_TYPE) as Vector2
	return Vector2.ZERO


func request_interaction() -> bool:
	return _request_dialog_toggle()


func is_interaction_open() -> bool:
	return dialog != null and dialog.is_open_for(CONTEXT)


# --- Opening -----------------------------------------------------------------

func _request_dialog_toggle() -> bool:
	if dialog == null:
		return false
	if dialog.is_open_for(CONTEXT):
		return true
	if dialog.is_open():
		return false
	if not _is_inventor_active():
		return false
	_open_dialog()
	return true


func _open_dialog() -> void:
	# Close any open build/weapon quickbar menu so it does not linger under the modal.
	if game_ui != null and game_ui.has_method("deactivate_quickbar"):
		game_ui.call("deactivate_quickbar")
	dialog.open_dialog(
		CONTEXT,
		Translations.t("inventor.name"),
		Translations.t("inventor.greeting"),
		_portrait,
		[{
			"id": CHOICE_OK,
			"label": Translations.t("ui.ok"),
			"enabled": true,
			"close_on_select": true,
		}],
		Callable(),  # OK just closes (close_on_select); no side effects, no reward, no deduction.
		Callable(),
		{
			"blocks_gameplay_input": true,
			"body_icons": {MONEY_ICON_PLACEHOLDER: _money_icon},
		}
	)


func _is_inventor_active() -> bool:
	if GameState.is_night:
		return false
	if building_manager == null or not building_manager.has_method("is_player_near_house_resident"):
		return false
	return bool(building_manager.call("is_player_near_house_resident", RESIDENT_TYPE, INTERACT_RADIUS_TILES))


# --- Icons -------------------------------------------------------------------

func _build_portrait_texture() -> Texture2D:
	# Build the region from the actual texture dimensions instead of assuming a fixed size, so the
	# first (portrait) frame is extracted the same way as the other villager dialogs.
	var frame_width: float = float(INVENTOR_TEXTURE.get_width()) / INVENTOR_FRAME_COUNT
	var frame_height: float = float(INVENTOR_TEXTURE.get_height())
	var atlas: AtlasTexture = AtlasTexture.new()
	atlas.atlas = INVENTOR_TEXTURE
	atlas.region = Rect2(Vector2.ZERO, Vector2(frame_width, frame_height))
	return atlas


func _build_money_icon_texture() -> Texture2D:
	var atlas: AtlasTexture = AtlasTexture.new()
	atlas.atlas = ITEMS_TEXTURE
	atlas.region = CurrencyCatalog.get_icon_region(MONEY_CURRENCY)
	return atlas
