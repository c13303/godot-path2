extends Node

## Inventor adapter for the generic DialogUI. It renders purchasable blueprint rows and delegates
## all currency, prerequisite and persistent unlock behavior to progression's blueprint service.
## Everything else — spawn, arrival, night return, evacuation, repath, removal, identity — is the
## shared HouseResidentController lifecycle registered in BuildingManager.
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
const ITEM_FRAME_SIZE: Vector2 = Vector2(32.0, 32.0)
# Inline placeholder substituted with the money currency icon inside the greeting text.
const MONEY_ICON_PLACEHOLDER: String = "{money_icon}"
const MONEY_CURRENCY: StringName = &"money"
const CHOICE_OK: String = "ok"
const BLUEPRINT_CHOICE_PREFIX: String = "blueprint:"

@export var dialog: DialogUI
@export var game_ui: Node
@export var building_manager: Node
@export var progression: Node

var _portrait: Texture2D
var _money_icon: Texture2D


func _ready() -> void:
	_portrait = _build_portrait_texture()
	_money_icon = _build_money_icon_texture()
	add_to_group(&"interaction_targets")


# --- InteractionRouter contract ----------------------------------------------

func can_interact() -> bool:
	return _is_inventor_active()


func get_interaction_world_position() -> Vector2:
	if building_manager != null and building_manager.has_method("get_house_resident_world_position"):
		return building_manager.call("get_house_resident_world_position", RESIDENT_TYPE) as Vector2
	return Vector2.ZERO


func get_interaction_radius_tiles() -> int:
	return INTERACT_RADIUS_TILES


func set_interaction_selected(value: bool) -> void:
	if building_manager != null and building_manager.has_method("set_house_resident_interaction_selected"):
		building_manager.call("set_house_resident_interaction_selected", RESIDENT_TYPE, value)


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
		_build_choices(),
		_on_choice,
		Callable(),
		{
			"blocks_gameplay_input": true,
			"body_icons": {MONEY_ICON_PLACEHOLDER: _money_icon},
		}
	)


func _build_choices() -> Array[Dictionary]:
	var choices: Array[Dictionary] = []
	if progression != null and progression.has_method("get_purchasable_blueprint_ids"):
		var raw_ids: Variant = progression.call("get_purchasable_blueprint_ids")
		if raw_ids is Array:
			for raw_id: Variant in (raw_ids as Array):
				var blueprint_id: StringName = StringName(str(raw_id))
				var item_id: String = String(blueprint_id)
				var raw_price: Variant = progression.call("get_blueprint_price", blueprint_id)
				var price: int = int(raw_price)
				var raw_currency: Variant = progression.call("get_blueprint_currency", blueprint_id)
				var currency: StringName = StringName(str(raw_currency))
				var raw_enabled: Variant = progression.call("can_purchase_blueprint", blueprint_id)
				choices.append({
					"id": BLUEPRINT_CHOICE_PREFIX + item_id,
					"label": _display_name(item_id),
					"icon": _item_frame_texture(ItemCatalog.get_item_def(item_id)),
					"price_text": str(price),
					"currency_icon": _currency_icon(currency),
					"enabled": bool(raw_enabled),
					"close_on_select": false,
				})
	choices.append({
		"id": CHOICE_OK,
		"label": Translations.t("ui.ok"),
		"enabled": true,
		"close_on_select": true,
	})
	return choices


func _on_choice(choice_id: String, _source_global_position: Vector2) -> void:
	if not choice_id.begins_with(BLUEPRINT_CHOICE_PREFIX) or progression == null:
		return
	var blueprint_id: StringName = StringName(choice_id.substr(BLUEPRINT_CHOICE_PREFIX.length()))
	if not progression.has_method("try_purchase_blueprint") or not bool(progression.call("try_purchase_blueprint", blueprint_id)):
		return
	Sfx.play_sound(&"buy")
	dialog.refresh_choices(_build_choices())


func _is_inventor_active() -> bool:
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


func _display_name(item_id: String) -> String:
	var key: String = "item." + item_id
	var translated: String = Translations.t(key)
	if translated != key:
		return translated
	return str(ItemCatalog.get_item_def(item_id).get("name", item_id))


func _item_frame_texture(item_def: Dictionary) -> Texture2D:
	var frame: int = int(item_def.get("frame", 0))
	var atlas: AtlasTexture = AtlasTexture.new()
	atlas.atlas = ITEMS_TEXTURE
	atlas.region = Rect2(Vector2(float(frame) * ITEM_FRAME_SIZE.x, 0.0), ITEM_FRAME_SIZE)
	return atlas


func _currency_icon(currency: StringName) -> Texture2D:
	var atlas: AtlasTexture = AtlasTexture.new()
	atlas.atlas = ITEMS_TEXTURE
	atlas.region = CurrencyCatalog.get_icon_region(currency)
	return atlas
