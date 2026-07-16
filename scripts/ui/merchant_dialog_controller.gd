extends Node

## Seed-merchant adapter for the generic DialogUI. It owns everything merchant-specific:
## deciding when the shop may open, converting the merchant inventory (and any active night
## reward) into generic dialog choices, purchasing, reward claiming, purchase animations,
## refreshing rows after a purchase, and closing when the merchant phase ends or the player
## leaves interaction range. All economy/inventory logic stays in game_ui.gd; this controller
## only calls it.

const CONTEXT: StringName = &"seed_merchant"
const MERCHANT_TEXTURE: Texture2D = preload("res://assets/sprites/legval/merchent.png")
const ITEMS_TEXTURE: Texture2D = preload("res://assets/sprites/legval/items.png")
const ITEM_FRAME_SIZE: Vector2 = Vector2(32.0, 32.0)
# The merchant sprite sheet holds this many horizontal frames; the first is the portrait.
const MERCHANT_FRAME_COUNT: float = 4.0
const SEED_ITEM_ID: String = "seed"
# Reward choice ids are the shared prefix plus the reward's key, so each granted reward gets
# its own selectable row that _on_choice can route back to a claim.
const REWARD_ID_PREFIX: String = "reward:"

@export var dialog: DialogUI
@export var game_ui: Node
@export var player_controller: PlayerController
@export var building_manager: Node

# Cached portrait (first frame of the merchant sheet) and currency icon atlases.
var _portrait: Texture2D
var _currency_icons: Dictionary = {}
# Signature of the currently rendered offer, so rows are only rebuilt when it actually changes.
var _last_signature: String = ""


func _ready() -> void:
	_portrait = _build_portrait_texture()
	for currency: StringName in CurrencyCatalog.get_currency_ids():
		_currency_icons[currency] = _region_texture(CurrencyCatalog.get_icon_region(currency))
	add_to_group(&"interaction_targets")
	set_process(true)


func _process(_delta: float) -> void:
	if dialog == null or not dialog.is_open_for(CONTEXT):
		return
	if not _is_merchant_active():
		dialog.close_dialog(&"merchant_unavailable")
		return
	var signature: String = _offer_signature()
	if signature != _last_signature:
		_last_signature = signature
		dialog.refresh_choices(_build_choices())


# --- Public API --------------------------------------------------------------

## Interact-button entry point (E / pad Y). Opens the shop when the player stands at the
## merchant during its day phase. Returns true when the press was consumed (at the merchant,
## or the shop already open), so the caller can fall back to another action otherwise (e.g.
## pad Y rotating a build preview when not at the merchant). Closing is owned by the dialog
## (Escape / gamepad B / close cross), so a second interact press while open does nothing.
func request_shop_toggle() -> bool:
	if dialog == null:
		return false
	if dialog.is_open_for(CONTEXT):
		return true
	if not _is_merchant_active():
		return false
	_open_shop()
	return true


func is_shop_open() -> bool:
	return dialog != null and dialog.is_open_for(CONTEXT)


# --- InteractionRouter contract ----------------------------------------------

func can_interact() -> bool:
	return _is_merchant_active()


func get_interaction_world_position() -> Vector2:
	if building_manager != null and building_manager.has_method("get_seed_merchant_world_position"):
		return building_manager.call("get_seed_merchant_world_position") as Vector2
	return Vector2.ZERO


func request_interaction() -> bool:
	return request_shop_toggle()


func is_interaction_open() -> bool:
	return is_shop_open()


# --- Opening -----------------------------------------------------------------

func _open_shop() -> void:
	# Close any open build/weapon quickbar menu so it does not linger under the modal.
	if game_ui != null and game_ui.has_method("deactivate_quickbar"):
		game_ui.call("deactivate_quickbar")
	_last_signature = _offer_signature()
	dialog.open_dialog(
		CONTEXT,
		_speaker_name(),
		_greeting(),
		_portrait,
		_build_choices(),
		_on_choice,
		_on_closed,
		{"blocks_gameplay_input": true}
	)


func _is_merchant_active() -> bool:
	if GameState.is_night or not GameState.is_seed_merchant_phase:
		return false
	if building_manager == null or not building_manager.has_method("is_player_near_seed_merchant"):
		return false
	if building_manager.has_method("has_seed_merchant_reached_spot") and not bool(building_manager.call("has_seed_merchant_reached_spot")):
		return false
	return bool(building_manager.call("is_player_near_seed_merchant"))


# --- Choice building ---------------------------------------------------------

func _build_choices() -> Array[Dictionary]:
	var choices: Array[Dictionary] = []
	# Active night rewards are pinned before the normal shop items.
	for reward: Dictionary in _active_reward_list():
		var item_id: String = str(reward.get("item_id", ""))
		var currency: String = str(reward.get("currency", ""))
		choices.append({
			"id": REWARD_ID_PREFIX + str(reward.get("key", "")),
			"label": _display_name(item_id) if item_id != "" else _special_reward_label(),
			"icon": _reward_icon(item_id, currency),
			"price_text": "",
			"icon_badge_text": str(int(reward.get("amount", 0))),
			"enabled": true,
			"close_on_select": false,
		})
	for item_id_sn: StringName in ItemCatalog.get_merchant_shop_item_ids():
		var item_id: String = String(item_id_sn)
		if not _is_merchant_item_available(item_id):
			continue
		choices.append({
			"id": item_id,
			"label": _display_name(item_id),
			"icon": _item_frame_texture(ItemCatalog.get_item_def(item_id)),
			"price_text": str(_merchant_price(item_id)),
			"currency_icon": _currency_icon(String(ItemCatalog.get_currency(item_id))),
			"enabled": _merchant_affordable_quantity(item_id) > 0,
			"close_on_select": false,
		})
	return choices


## A stable string describing the current offer (visible items, their prices/affordability,
## and any reward rows) so the per-frame refresh only rebuilds rows when something changed.
func _offer_signature() -> String:
	var parts: PackedStringArray = PackedStringArray()
	for reward: Dictionary in _active_reward_list():
		parts.append("r:%s:%s:%s:%d" % [
			str(reward.get("key", "")), str(reward.get("currency", "")),
			str(reward.get("item_id", "")), int(reward.get("amount", 0))
		])
	for item_id_sn: StringName in ItemCatalog.get_merchant_shop_item_ids():
		var item_id: String = String(item_id_sn)
		if not _is_merchant_item_available(item_id):
			continue
		parts.append("i:%s:%d:%d" % [
			item_id, _merchant_price(item_id), _merchant_affordable_quantity(item_id)
		])
	return "|".join(parts)


# --- Choice activation -------------------------------------------------------

func _on_choice(choice_id: String, source_global_position: Vector2) -> void:
	if choice_id.begins_with(REWARD_ID_PREFIX):
		_claim_reward(choice_id.substr(REWARD_ID_PREFIX.length()), source_global_position)
		return
	_purchase_item(choice_id, source_global_position)


func _purchase_item(item_id: String, source_global_position: Vector2) -> void:
	if GameState.is_night or game_ui == null:
		return
	var purchased: bool = false
	if item_id == SEED_ITEM_ID and game_ui.has_method("try_purchase_seed_merchant_item"):
		purchased = bool(game_ui.call("try_purchase_seed_merchant_item", item_id, 1))
	elif ItemCatalog.is_inventory_backed(item_id) and game_ui.has_method("try_purchase_placeable_merchant_item"):
		purchased = bool(game_ui.call("try_purchase_placeable_merchant_item", item_id, 1))
	elif ItemCatalog.is_weapon(item_id) and game_ui.has_method("try_purchase_shop_inventory_item"):
		purchased = bool(game_ui.call("try_purchase_shop_inventory_item", item_id, 1))
	if not purchased:
		# Failed purchase: keep the dialog open, no sound; _process refreshes if anything changed.
		return
	GameState.seed_merchant_purchase_made = true
	Sfx.play_sound(&"buy")
	_animate_purchase_to_ui(item_id, source_global_position)
	# Rebuild rows, preferring to keep the purchased item selected. If it vanished (a weapon the
	# player now owns), DialogUI moves the selection to the nearest remaining row.
	_last_signature = _offer_signature()
	dialog.refresh_choices(_build_choices(), item_id)


func _claim_reward(reward_key: String, source_global_position: Vector2) -> void:
	if GameState.is_night or game_ui == null or not game_ui.has_method("claim_active_night_reward"):
		return
	# A full inventory makes an item reward fail; it then stays claimable (get_active_night_reward
	# still returns it, so _build_choices keeps the row).
	if bool(game_ui.call("claim_active_night_reward", source_global_position, reward_key)):
		Sfx.play_sound(&"buy")
		_last_signature = _offer_signature()
		dialog.refresh_choices(_build_choices())


func _on_closed(_reason: StringName) -> void:
	# DialogUI restores the gameplay input lock itself; nothing merchant-specific to undo.
	_last_signature = ""


## Replays the existing fly-to-HUD / fly-to-inventory purchase feedback from the row's origin.
func _animate_purchase_to_ui(item_id: String, start_global_position: Vector2) -> void:
	if game_ui == null:
		return
	if item_id == SEED_ITEM_ID:
		var world_position: Vector2 = get_viewport().get_canvas_transform().affine_inverse() * start_global_position
		var seed_icon: Node = game_ui.get_node_or_null("currenciesUI/seedIcon")
		if seed_icon != null and seed_icon.has_method("animate_seed_harvest"):
			seed_icon.call("animate_seed_harvest", world_position, 0, Callable(), false)
		return
	if game_ui.has_method("animate_inventory_item_to_slot"):
		game_ui.call("animate_inventory_item_to_slot", item_id, start_global_position)


# --- game_ui queries ---------------------------------------------------------

func _is_merchant_item_available(item_id: String) -> bool:
	return game_ui == null or not game_ui.has_method("is_merchant_item_available") or bool(game_ui.call("is_merchant_item_available", item_id))


func _merchant_price(item_id: String) -> int:
	if game_ui != null and game_ui.has_method("get_merchant_price"):
		return int(game_ui.call("get_merchant_price", item_id))
	return ItemCatalog.get_price(item_id)


func _merchant_affordable_quantity(item_id: String) -> int:
	if game_ui != null and game_ui.has_method("get_merchant_affordable_quantity"):
		return int(game_ui.call("get_merchant_affordable_quantity", item_id))
	return 0


func _active_reward_list() -> Array[Dictionary]:
	var rewards: Array[Dictionary] = []
	if game_ui == null or not game_ui.has_method("get_active_night_reward"):
		return rewards
	var info: Dictionary = game_ui.call("get_active_night_reward")
	if info.is_empty():
		return rewards
	for raw_reward: Variant in info.get("rewards", []) as Array:
		rewards.append(raw_reward as Dictionary)
	return rewards


# --- Text --------------------------------------------------------------------

func _speaker_name() -> String:
	return Translations.t("merchant.seed.name")


func _greeting() -> String:
	return Translations.t("merchant.seed.greeting")


func _special_reward_label() -> String:
	var key: String = "merchant.special_reward"
	var translated: String = Translations.t(key)
	return "Special reward" if translated == key else translated


func _display_name(item_id: String) -> String:
	if item_id == "":
		return ""
	var key: String = "item." + item_id
	var translated: String = Translations.t(key)
	if translated != key:
		return translated
	return str(ItemCatalog.get_item_def(item_id).get("name", item_id))


# --- Icons -------------------------------------------------------------------

func _build_portrait_texture() -> Texture2D:
	# Build the region from the actual texture dimensions instead of assuming a fixed size.
	var frame_width: float = float(MERCHANT_TEXTURE.get_width()) / MERCHANT_FRAME_COUNT
	var frame_height: float = float(MERCHANT_TEXTURE.get_height())
	var atlas: AtlasTexture = AtlasTexture.new()
	atlas.atlas = MERCHANT_TEXTURE
	atlas.region = Rect2(Vector2.ZERO, Vector2(frame_width, frame_height))
	return atlas


func _reward_icon(item_id: String, currency: String) -> Texture2D:
	if item_id != "":
		return _item_frame_texture(ItemCatalog.get_item_def(item_id))
	return _currency_icon(currency)


func _item_frame_texture(item_def: Dictionary) -> Texture2D:
	if str(item_def.get("id", "")) == SEED_ITEM_ID:
		return _currency_icon("seed")
	var frame: int = int(item_def.get("frame", 0))
	return _region_texture(Rect2(Vector2(float(frame) * ITEM_FRAME_SIZE.x, 0.0), ITEM_FRAME_SIZE))


func _currency_icon(currency: String) -> Texture2D:
	return _currency_icons.get(StringName(currency), null) as Texture2D


func _region_texture(region: Rect2) -> AtlasTexture:
	var atlas: AtlasTexture = AtlasTexture.new()
	atlas.atlas = ITEMS_TEXTURE
	atlas.region = region
	return atlas
