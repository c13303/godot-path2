extends CanvasLayer

signal inventory_changed

const ItemSlotScript = preload("res://scripts/ui/item_slot.gd")
const INVENTORY_SLOT_COUNT: int = 32
const INVENTORY_COLUMNS: int = 8
const ITEMS_TEXTURE: Texture2D = preload("res://assets/sprites/legval/items.png")
const ITEM_FRAME_SIZE: Vector2 = Vector2(32.0, 32.0)
const PURCHASE_FLIGHT_SIZE: Vector2 = Vector2(28.0, 28.0)
const PURCHASE_FLIGHT_DURATION: float = 0.72
# Cap on how many currency sprites fly for one night-reward payout; any overflow is
# credited instantly so huge bonuses never spawn thousands of sprites.
const REWARD_ANIM_CAP: int = 15

const SEED_KEY: StringName = &"seeds"
const GEM_KEY: StringName = &"gems"
const MONEY_KEY: StringName = &"money"
# Quick-slot tools that drive build mode rather than acting as weapons. The build picker is
# split into two tools: gardening (rose/ronce/pasteque/turrets) and hammer (counter/wall/fence).
# Both open the same picker; the selected tool decides which buildables it offers.
const GARDENING_ID: String = "gardening"
const HAMMER_ID: String = "hammer"
const BUILD_TOOL_IDS: Array[String] = [GARDENING_ID, HAMMER_ID]
const UNBUILD_TOOL_ID: String = "unbuild_tool"
const ITEM_NAME_KEY_PREFIX: String = "item."
# Slot 0 of the quickbar is the weapons menu (a drop-up over all possessed weapons); the other
# slots are the build-tool menus. The quickbar is a fixed set of drop-up slots and is no longer
# mapped 1:1 to inventory slots.
const WEAPON_SLOT_KIND: String = "weapon"
const QUICK_SLOT_KINDS: Array[String] = [WEAPON_SLOT_KIND, GARDENING_ID, HAMMER_ID]
const QUICK_SLOT_SIZE: Vector2 = Vector2(56.0, 56.0)
const QUICK_SLOT_GAP: float = 6.0
const TOOLBAR_PADDING: Vector2 = Vector2(8.0, 6.0)
@onready var toolbar_slots: HBoxContainer = $"bottom anchor/ToolbarPanel/toolbar"
@onready var toolbar_panel: PanelContainer = $"bottom anchor/ToolbarPanel"
@onready var toolbar_info: RichTextLabel = get_node_or_null("bottom anchor/toolbarInfo") as RichTextLabel
@onready var toolbar_anchor: Control = $"bottom anchor"
@onready var modals_root: Control = $Modals
@onready var inventory_modal: Panel = $Modals/inventoryModal
@onready var close_button: Button = $Modals/inventoryModal/CloseButton
@onready var inventory_content: VBoxContainer = $Modals/inventoryModal/MarginContainer/Content
@onready var tile_hover_info: Node = $"../CPP/TileHoverInfo"
@onready var day_toggle: TextureRect = $"top anchor/dayToggle"
@onready var toolbuild: Control = get_node_or_null("Toolbuild") as Control

const MOONSUN_TEXTURE: Texture2D = preload("res://assets/sprites/legval/moonsun.png")
const MOONSUN_TILE_SIZE: int = 64
var _sun_icon: AtlasTexture
var _moon_icon: AtlasTexture

var inventory_slots: Array[Dictionary] = []
# Quickbar activity. false = play mode: menus closed, no labels, the equipped weapon (or
# equipped buildable preview) is active. true = a slot's drop-up menu is open for selection;
# active_slot_index is that open slot (index into QUICK_SLOT_KINDS), or -1 when inactive.
var quickbar_active: bool = false
var active_slot_index: int = -1
# The persistently equipped weapon, wielded in play mode. Independent of the quickbar slots now
# that every weapon shares the single weapon menu; empty falls back to the first possessed weapon.
var equipped_weapon_id: String = ""
# The active build preview, or "" when the inactive quickbar should use weapon mode.
var selected_build_item_id: String = ""
var _progression_node: Node
var _toolbar_slot_nodes: Array[ItemSlot] = []
var _inventory_slot_nodes: Array[ItemSlot] = []
var _possessed_weapon_ids: Dictionary = {}
var _startup_loading_overlay: Control
var _startup_loading_label: Label
var _startup_loading_bar: ProgressBar
var _startup_loading_value: float = 0.0
var _startup_loading_finished: bool = false

func _ready() -> void:
	layer = 50
	var scene: Node = get_tree().current_scene
	_progression_node = scene.get_node_or_null("progression") if scene != null else null
	_create_startup_loading_overlay()
	_setup_starting_inventory()
	close_button.pressed.connect(_hide_inventory)
	if not Translations.locale_changed.is_connected(_on_locale_changed):
		Translations.locale_changed.connect(_on_locale_changed)
	_setup_day_toggle()
	_build_toolbar()
	_build_inventory()
	_refresh_all_slots()
	_set_inventory_open(false)
	call_deferred("_connect_startup_loading_signals")
	# The quickbar starts inactive (play mode) with the equipped weapon active; the player
	# activates a slot to build. equipped_weapon_id self-heals to the first possessed weapon.
	equipped_weapon_id = _first_possessed_weapon_id()

func _setup_day_toggle() -> void:
	_sun_icon = AtlasTexture.new()
	_sun_icon.atlas = MOONSUN_TEXTURE
	_sun_icon.region = Rect2(0, 0, MOONSUN_TILE_SIZE, MOONSUN_TILE_SIZE)
	_moon_icon = AtlasTexture.new()
	_moon_icon.atlas = MOONSUN_TEXTURE
	_moon_icon.region = Rect2(MOONSUN_TILE_SIZE, 0, MOONSUN_TILE_SIZE, MOONSUN_TILE_SIZE)

	GameState.mode_changed.connect(_on_game_mode_changed)
	_update_day_toggle_icon(GameState.is_night)

func _on_game_mode_changed(is_night: bool) -> void:
	_update_day_toggle_icon(is_night)
	# Night: the build-tool menus are disabled and any equipped buildable is cleared so the
	# player wields their weapon. The quickbar closes either way. Day re-enables the build slots.
	if is_night:
		deactivate_quickbar()
		clear_build_selection()
		if equipped_weapon_id == "":
			equipped_weapon_id = _first_possessed_weapon_id()
	_refresh_all_slots()

func _on_locale_changed(_locale: String) -> void:
	_refresh_toolbar_info()

func _update_day_toggle_icon(is_night: bool) -> void:
	# Icon reflects the current mode: sun during day, moon during night.
	day_toggle.texture = _moon_icon if is_night else _sun_icon

func _input(event: InputEvent) -> void:
	# The mouse wheel is reserved for rotating the buildable during placement
	# (see buildsystem.gd); it no longer steps the toolbuild vertical menu.
	if not (event is InputEventKey):
		return

	var key_event: InputEventKey = event
	if not key_event.pressed or key_event.echo:
		return

	if key_event.keycode == KEY_ESCAPE and inventory_modal.visible:
		_hide_inventory()
		get_viewport().set_input_as_handled()
		return

	# ESC while the quickbar is active closes it back to play mode.
	if key_event.keycode == KEY_ESCAPE and quickbar_active:
		deactivate_quickbar()
		get_viewport().set_input_as_handled()
		return

	if key_event.keycode == KEY_I:
		_set_inventory_open(not inventory_modal.visible)
		if inventory_modal.visible:
			_refresh_all_slots()
		get_viewport().set_input_as_handled()
		return

	# A number key activates the quickbar and opens that slot's drop-up menu. Pressing another
	# number while active simply switches to that slot's menu.
	var slot_index: int = _quick_slot_index_from_event(key_event)
	if slot_index >= 0 and slot_index < QUICK_SLOT_KINDS.size():
		activate_quickbar_slot(slot_index)
		get_viewport().set_input_as_handled()

func move_inventory_item(from_slot: int, to_slot: int) -> void:
	if from_slot < 0 or from_slot >= inventory_slots.size():
		return
	if to_slot < 0 or to_slot >= inventory_slots.size():
		return
	if from_slot == to_slot:
		return

	var from_item: Dictionary = inventory_slots[from_slot]
	var to_item: Dictionary = inventory_slots[to_slot]
	var from_item_id: String = _slot_item_id(from_item)
	var to_item_id: String = _slot_item_id(to_item)
	if from_item_id != "" and from_item_id == to_item_id and ItemCatalog.is_stackable(from_item_id):
		var max_stack: int = ItemCatalog.get_max_stack(from_item_id)
		var from_quantity: int = _slot_quantity(from_item)
		var to_quantity: int = _slot_quantity(to_item)
		var moved_quantity: int = mini(from_quantity, max_stack - to_quantity)
		if moved_quantity <= 0:
			return
		inventory_slots[to_slot] = _make_slot(from_item_id, to_quantity + moved_quantity)
		var remaining_quantity: int = from_quantity - moved_quantity
		inventory_slots[from_slot] = _make_slot(from_item_id, remaining_quantity) if remaining_quantity > 0 else _empty_slot()
	else:
		inventory_slots[from_slot] = to_item
		inventory_slots[to_slot] = from_item
	_refresh_all_slots()

# --- Quickbar activation & equip -------------------------------------------------

## Activates the quickbar and opens the given slot's drop-up menu. Pressing another slot while
## active just switches menus. Build-tool slots stay locked out at night (weapon slot only).
func activate_quickbar_slot(index: int) -> void:
	if index < 0 or index >= QUICK_SLOT_KINDS.size():
		return
	if _is_quickbar_slot_disabled(QUICK_SLOT_KINDS[index]):
		return
	quickbar_active = true
	active_slot_index = index
	_refresh_all_slots()

## Closes the quickbar back to play mode (menus closed, no labels).
func deactivate_quickbar() -> void:
	if not quickbar_active and active_slot_index < 0:
		return
	quickbar_active = false
	active_slot_index = -1
	_refresh_all_slots()

func is_quickbar_active() -> bool:
	return quickbar_active

## The kind of the currently open menu (WEAPON_SLOT_KIND / gardening / hammer), or "" when inactive.
func get_active_menu_kind() -> String:
	if not quickbar_active or active_slot_index < 0 or active_slot_index >= QUICK_SLOT_KINDS.size():
		return ""
	return QUICK_SLOT_KINDS[active_slot_index]

func get_active_slot_index() -> int:
	return active_slot_index if quickbar_active else -1

## Equips a possessed weapon from the weapon menu: it becomes the wielded weapon, any build
## preview is cleared, and the quickbar closes to play mode.
func equip_weapon(item_id: String) -> void:
	if not ItemCatalog.is_weapon(item_id) or not _has_inventory_weapon(item_id):
		return
	equipped_weapon_id = item_id
	clear_build_selection()
	deactivate_quickbar()

## The weapon wielded in play mode. Falls back to the first possessed weapon when the stored
## pick is empty or no longer owned, so it is always a currently-owned weapon (or "").
func get_equipped_weapon_id() -> String:
	if equipped_weapon_id != "" and _has_inventory_weapon(equipped_weapon_id):
		return equipped_weapon_id
	return _first_possessed_weapon_id()

## The weapons the player currently owns, in inventory order (drives the weapon menu).
func get_possessed_weapon_ids() -> Array[String]:
	var ids: Array[String] = []
	for slot_data: Dictionary in inventory_slots:
		var item_id: String = _slot_item_id(slot_data)
		if item_id != "" and ItemCatalog.is_weapon(item_id) and not ids.has(item_id):
			ids.append(item_id)
	return ids

func _first_possessed_weapon_id() -> String:
	for slot_data: Dictionary in inventory_slots:
		var item_id: String = _slot_item_id(slot_data)
		if item_id != "" and ItemCatalog.is_weapon(item_id):
			return item_id
	return ""

## A quickbar slot kind is disabled when its menu cannot be opened: build-tool menus are locked
## out at night; the weapon menu is only unusable when the player owns no weapon at all.
func _is_quickbar_slot_disabled(kind: String) -> bool:
	if kind == WEAPON_SLOT_KIND:
		return _first_possessed_weapon_id() == ""
	return GameState.is_night

## The active quick item: explicit build preview first, otherwise the equipped weapon.
func get_selected_quick_item_id() -> String:
	if quickbar_active and get_active_menu_kind() == WEAPON_SLOT_KIND:
		return get_equipped_weapon_id()
	if selected_build_item_id != "":
		return selected_build_item_id
	return get_equipped_weapon_id()

func get_inventory_item_quantity(item_id: String) -> int:
	var total: int = 0
	for slot_data: Dictionary in inventory_slots:
		if _slot_item_id(slot_data) == item_id:
			total += _slot_quantity(slot_data)
	return total

func get_possessed_inventory_item_counts() -> Dictionary:
	var counts: Dictionary = {}
	for slot_data: Dictionary in inventory_slots:
		var item_id: String = _slot_item_id(slot_data)
		var quantity: int = _slot_quantity(slot_data)
		if item_id == "" or quantity <= 0:
			continue
		counts[item_id] = int(counts.get(item_id, 0)) + quantity
	return counts

func consume_inventory_item(item_id: String, quantity: int) -> bool:
	if item_id == "" or quantity <= 0 or get_inventory_item_quantity(item_id) < quantity:
		return false
	var remaining: int = quantity
	for slot_index: int in range(inventory_slots.size()):
		var slot_data: Dictionary = inventory_slots[slot_index]
		if _slot_item_id(slot_data) != item_id:
			continue
		var current_quantity: int = _slot_quantity(slot_data)
		var consumed_quantity: int = mini(current_quantity, remaining)
		var new_quantity: int = current_quantity - consumed_quantity
		inventory_slots[slot_index] = _make_slot(item_id, new_quantity) if new_quantity > 0 else _empty_slot()
		remaining -= consumed_quantity
		if remaining == 0:
			break
	_refresh_all_slots()
	return true

func is_item_disabled_for_placement(item_id: String) -> bool:
	return GameState.is_night and ItemCatalog.is_placeable(item_id)

# --- Build menu state --------------------------------------------------------

func get_selected_build_item_id() -> String:
	if quickbar_active and not is_build_menu_open():
		return ""
	return selected_build_item_id

func set_selected_build_item(item_id: String) -> void:
	selected_build_item_id = item_id

func clear_build_selection() -> void:
	selected_build_item_id = ""

func is_build_mode_active() -> bool:
	return get_selected_build_item_id() != ""

## True while a build-tool menu is open or an explicit build preview is active.
func is_build_tool_selected() -> bool:
	return is_build_menu_open() or is_build_mode_active()

## True while one of the build-tool drop-up menus (gardening/hammer) is open.
func is_build_menu_open() -> bool:
	var kind: String = get_active_menu_kind()
	return kind == GARDENING_ID or kind == HAMMER_ID

## The open build-tool menu's id (gardening/hammer), or "" when no build menu is open. The
## picker uses this to decide which buildables to offer and which quick slot to anchor to.
func get_selected_build_tool_id() -> String:
	var kind: String = get_active_menu_kind()
	return kind if (kind == GARDENING_ID or kind == HAMMER_ID) else ""

## True while the gardening menu is open or a gardening buildable is active for placement.
func is_gardening_selected() -> bool:
	if get_active_menu_kind() == GARDENING_ID:
		return true
	var build_item_id: String = get_selected_build_item_id()
	return build_item_id != "" and build_item_id in _gardening_buildable_ids()

func is_unbuild_tool_selected() -> bool:
	return false

## Opens the given build tool's drop-up menu (activating the quickbar). No-op if the tool id is
## not a quickbar slot kind. Kept for callers like the morning harvest's auto-open-hammer prompt.
func select_build_tool(tool_id: String) -> void:
	var index: int = QUICK_SLOT_KINDS.find(tool_id)
	if index >= 0:
		activate_quickbar_slot(index)

## Scripted helper for tutorial/objective nudges: equips a concrete buildable directly, bypassing
## the picker highlight step while preserving the same availability/affordability gates.
func select_build_item_for_tool(tool_id: String, item_id: String) -> bool:
	var index: int = QUICK_SLOT_KINDS.find(tool_id)
	if index < 0 or _is_quickbar_slot_disabled(tool_id):
		return false
	if not _tool_offers_build_item(tool_id, item_id):
		return false
	if not is_build_item_available(item_id) or not can_afford_build(item_id, 1):
		return false
	selected_build_item_id = item_id
	quickbar_active = false
	active_slot_index = -1
	_refresh_all_slots()
	return true

func _tool_offers_build_item(tool_id: String, item_id: String) -> bool:
	if tool_id == GARDENING_ID:
		return item_id in _gardening_buildable_ids()
	if tool_id == HAMMER_ID:
		return item_id in _hammer_buildable_ids()
	return false


func _gardening_buildable_ids() -> Array[String]:
	return _string_names_to_strings(ItemCatalog.get_gardening_shop_item_ids())


func _hammer_buildable_ids() -> Array[String]:
	return _string_names_to_strings(ItemCatalog.get_hammer_shop_item_ids())


func _string_names_to_strings(item_ids: Array[StringName]) -> Array[String]:
	var ids: Array[String] = []
	for item_id: StringName in item_ids:
		ids.append(String(item_id))
	return ids

## Global-space center X of a quick slot's icon, or -1 if that slot has not been built yet.
func get_quick_slot_center_x(index: int) -> float:
	if index < 0 or index >= _toolbar_slot_nodes.size():
		return -1.0
	var rect: Rect2 = _toolbar_slot_nodes[index].get_global_rect()
	return rect.position.x + rect.size.x * 0.5

## Global-space center X of the quick slot for the currently open build-tool menu, or -1 when
## no build menu is open. The picker uses this to anchor its column above the active tool's icon.
func get_build_tool_slot_center_x() -> float:
	var tool_id: String = get_selected_build_tool_id()
	if tool_id == "":
		return -1.0
	return get_quick_slot_center_x(QUICK_SLOT_KINDS.find(tool_id))

## Global-space left X of the leftmost quick slot, or -1 if the quick bar has no
## slots yet. The seed/weapon merchant column left-aligns its rows to this.
func get_quick_bar_left_x() -> float:
	if _toolbar_slot_nodes.is_empty():
		return -1.0
	return _toolbar_slot_nodes[0].get_global_rect().position.x


## Global-space left X of a quick slot, or -1 if that slot has not been built yet.
func get_quick_slot_left_x(index: int) -> float:
	if index < 0 or index >= _toolbar_slot_nodes.size():
		return -1.0
	return _toolbar_slot_nodes[index].get_global_rect().position.x


func animate_inventory_item_to_slot(
	item_id: String,
	start_global_position: Vector2,
	sequence_index: int = 0,
	stagger_seconds: float = 0.0
) -> bool:
	var target_slot: Control = _find_inventory_item_slot(item_id)
	if target_slot == null or not is_instance_valid(target_slot):
		return false
	return _animate_inventory_item_to_position(
		item_id,
		start_global_position,
		target_slot.get_global_rect().get_center(),
		sequence_index,
		stagger_seconds
	)


func _animate_inventory_item_to_position(
	item_id: String,
	start_global_position: Vector2,
	end_global_position: Vector2,
	sequence_index: int = 0,
	stagger_seconds: float = 0.0
) -> bool:
	var texture: AtlasTexture = _inventory_item_texture(item_id)
	if texture == null:
		return false
	var start_delay: float = float(sequence_index) * maxf(0.0, stagger_seconds)
	if start_delay <= 0.0:
		return _start_inventory_item_flight(item_id, start_global_position, end_global_position)
	var delay_tween: Tween = create_tween()
	delay_tween.tween_interval(start_delay)
	delay_tween.tween_callback(Callable(self, "_start_inventory_item_flight").bind(item_id, start_global_position, end_global_position))
	return true


func _start_inventory_item_flight(item_id: String, start_global_position: Vector2, end_global_position: Vector2) -> bool:
	var texture: AtlasTexture = _inventory_item_texture(item_id)
	if texture == null:
		return false
	var item_sprite: TextureRect = TextureRect.new()
	item_sprite.texture = texture
	item_sprite.custom_minimum_size = PURCHASE_FLIGHT_SIZE
	item_sprite.size = PURCHASE_FLIGHT_SIZE
	item_sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	item_sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	item_sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
	item_sprite.pivot_offset = PURCHASE_FLIGHT_SIZE * 0.5
	add_child(item_sprite)

	var distance: float = start_global_position.distance_to(end_global_position)
	var arc_height: float = clampf(distance * 0.22, 70.0, 180.0)
	var curve_position: Vector2 = (start_global_position + end_global_position) * 0.5 + Vector2(0.0, -arc_height)
	item_sprite.position = start_global_position - PURCHASE_FLIGHT_SIZE * 0.5
	item_sprite.scale = Vector2(0.45, 0.45)

	var flight_tween: Tween = create_tween()
	flight_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	flight_tween.tween_method(
		Callable(self, "_update_purchase_flight").bind(item_sprite, start_global_position, curve_position, end_global_position),
		0.0,
		1.0,
		PURCHASE_FLIGHT_DURATION
	)
	flight_tween.parallel().tween_property(item_sprite, "scale", Vector2.ONE, 0.18)
	flight_tween.parallel().tween_property(item_sprite, "rotation", TAU, PURCHASE_FLIGHT_DURATION)
	flight_tween.tween_callback(Callable(self, "_finish_purchase_flight").bind(item_sprite))
	return true


func _find_inventory_item_slot(item_id: String) -> Control:
	# Weapons are represented by the single weapon quick slot; everything else flies to its
	# backpack slot.
	if ItemCatalog.is_weapon(item_id) and not _toolbar_slot_nodes.is_empty():
		return _toolbar_slot_nodes[0]
	for i: int in range(inventory_slots.size()):
		if _slot_item_id(inventory_slots[i]) == item_id and i < _inventory_slot_nodes.size():
			return _inventory_slot_nodes[i]
	return null


func _inventory_backed_refund_target_position(item_id: String) -> Vector2:
	var possessed_hud: Node = get_node_or_null("currenciesUI")
	if possessed_hud != null and possessed_hud.has_method("get_item_flight_target_global_position"):
		return possessed_hud.call("get_item_flight_target_global_position", item_id) as Vector2
	var target_slot: Control = _find_inventory_item_slot(item_id)
	if target_slot != null and is_instance_valid(target_slot):
		return target_slot.get_global_rect().get_center()
	return Vector2.ZERO


func _inventory_item_texture(item_id: String) -> AtlasTexture:
	var item_def: Dictionary = ItemCatalog.get_item_def(item_id)
	var frame: int = int(item_def.get("frame", -1))
	if frame < 0:
		return null
	var atlas_texture: AtlasTexture = AtlasTexture.new()
	atlas_texture.atlas = ITEMS_TEXTURE
	atlas_texture.region = Rect2(Vector2(float(frame) * ITEM_FRAME_SIZE.x, 0.0), ITEM_FRAME_SIZE)
	return atlas_texture


func _update_purchase_flight(
	progress: float,
	item_sprite: TextureRect,
	start_position: Vector2,
	curve_position: Vector2,
	end_position: Vector2
) -> void:
	if not is_instance_valid(item_sprite):
		return
	var inverse_progress: float = 1.0 - progress
	var curved_position: Vector2 = (
		inverse_progress * inverse_progress * start_position
		+ 2.0 * inverse_progress * progress * curve_position
		+ progress * progress * end_position
	)
	item_sprite.position = curved_position - PURCHASE_FLIGHT_SIZE * 0.5


func _finish_purchase_flight(item_sprite: TextureRect) -> void:
	if is_instance_valid(item_sprite):
		item_sprite.queue_free()

## Maps an item's catalog currency (&"seed"/&"gem") to its progression prop key.
func _build_currency_prog_key(item_id: String) -> StringName:
	var currency: StringName = ItemCatalog.get_currency(item_id)
	if currency == &"seed":
		return SEED_KEY
	if currency == &"gem":
		return GEM_KEY
	if currency == &"money":
		return MONEY_KEY
	return &""

func is_build_item_available(item_id: String) -> bool:
	var scene: Node = get_tree().current_scene
	var loader: Node = scene.get_node_or_null("LevelLoader") if scene != null else null
	# The level author can uncheck a buildable's "Available" box in the Rose Level editor;
	# that hides it from the toolbuild picker entirely, ahead of every always-shown rule
	# below (rose_shop_counter, inventory-backed buildables like pasteque).
	if loader != null and loader.has_method("is_starting_item_toolbuild_hidden") and bool(loader.call("is_starting_item_toolbuild_hidden", item_id)):
		return false
	if item_id == "rose_shop_counter":
		return true
	# Inventory-backed buildables are always offered in the toolbuild picker; their
	# affordability is the owned count, so an empty stack simply greys the slot.
	if ItemCatalog.is_inventory_backed(item_id):
		return true
	if loader != null and loader.has_method("get_loaded_tool_shop_available_items"):
		var raw_tool_item_ids: Variant = loader.call("get_loaded_tool_shop_available_items")
		if raw_tool_item_ids is Array:
			for raw_item_id: Variant in raw_tool_item_ids:
				if str(raw_item_id) == item_id:
					return _shop_item_unlock_day_reached(loader, "get_loaded_tool_shop_days", item_id)
			return false
	if loader != null and loader.has_method("get_loaded_shop_available_items"):
		var raw_item_ids: Variant = loader.call("get_loaded_shop_available_items")
		if raw_item_ids is Array:
			for raw_item_id: Variant in raw_item_ids:
				if str(raw_item_id) == item_id:
					return true
			return false
	return item_id == "rose" or item_id == "turret1" or item_id == "wall" or item_id == "ronce" or item_id == "fence"


func get_build_price(item_id: String) -> int:
	var base_price: int = _base_build_price(item_id)
	var factor: float = _build_growth_price_factor(item_id)
	if factor <= 1.0:
		return base_price
	var placed_count: int = _placed_build_count(item_id)
	return _growth_build_price(base_price, factor, placed_count)


func _base_build_price(item_id: String) -> int:
	var scene: Node = get_tree().current_scene
	var loader: Node = scene.get_node_or_null("LevelLoader") if scene != null else null
	if loader != null and loader.has_method("get_loaded_tool_shop_prices"):
		var raw_tool_prices: Variant = loader.call("get_loaded_tool_shop_prices")
		if raw_tool_prices is Dictionary:
			var tool_prices: Dictionary = raw_tool_prices as Dictionary
			if tool_prices.has(StringName(item_id)):
				return maxi(0, int(tool_prices[StringName(item_id)]))
			if tool_prices.has(item_id):
				return maxi(0, int(tool_prices[item_id]))
	if loader != null and loader.has_method("get_loaded_shop_prices"):
		var raw_prices: Variant = loader.call("get_loaded_shop_prices")
		if raw_prices is Dictionary:
			var prices: Dictionary = raw_prices as Dictionary
			if prices.has(StringName(item_id)):
				return maxi(0, int(prices[StringName(item_id)]))
			if prices.has(item_id):
				return maxi(0, int(prices[item_id]))
	return ItemCatalog.get_price(item_id)


func _build_growth_price_factor(item_id: String) -> float:
	var scene: Node = get_tree().current_scene
	var loader: Node = scene.get_node_or_null("LevelLoader") if scene != null else null
	if loader != null and loader.has_method("get_loaded_tool_shop_growth_price_factors"):
		var raw_factors: Variant = loader.call("get_loaded_tool_shop_growth_price_factors")
		if raw_factors is Dictionary:
			var factors: Dictionary = raw_factors as Dictionary
			if factors.has(StringName(item_id)):
				return maxf(1.0, float(factors[StringName(item_id)]))
			if factors.has(item_id):
				return maxf(1.0, float(factors[item_id]))
	return 1.0


func _growth_build_price(base_price: int, factor: float, placed_count: int) -> int:
	if base_price <= 0:
		return 0
	var grown_price: float = float(base_price) * pow(factor, float(maxi(0, placed_count)))
	return maxi(0, int(ceil(grown_price)))


func _build_price_for_placed_count(item_id: String, placed_count: int) -> int:
	var base_price: int = _base_build_price(item_id)
	var factor: float = _build_growth_price_factor(item_id)
	if factor <= 1.0:
		return base_price
	return _growth_build_price(base_price, factor, placed_count)


func _build_price_total_for_next(item_id: String, count: int) -> int:
	if count <= 0:
		return 0
	var total: int = 0
	var placed_count: int = _placed_build_count(item_id)
	for i: int in range(count):
		total += _build_price_for_placed_count(item_id, placed_count + i)
	return total


func is_merchant_item_available(item_id: String) -> bool:
	if ItemCatalog.is_weapon(item_id) and _has_possessed_weapon(item_id):
		return false
	var scene: Node = get_tree().current_scene
	var loader: Node = scene.get_node_or_null("LevelLoader") if scene != null else null
	if loader != null and loader.has_method("get_loaded_merchant_available_items"):
		var raw_item_ids: Variant = loader.call("get_loaded_merchant_available_items")
		if raw_item_ids is Array:
			for raw_item_id: Variant in raw_item_ids:
				if str(raw_item_id) == item_id:
					return _shop_item_unlock_day_reached(loader, "get_loaded_merchant_days", item_id)
			return false
	if loader != null and loader.has_method("get_loaded_shop_available_items"):
		var raw_legacy_item_ids: Variant = loader.call("get_loaded_shop_available_items")
		if raw_legacy_item_ids is Array:
			for raw_item_id: Variant in raw_legacy_item_ids:
				if str(raw_item_id) == item_id:
					return true
			return false
	return item_id == "seed" or item_id == "spray" or item_id == "beam" or item_id == "sword" or item_id == "bomb"


func _shop_item_unlock_day_reached(loader: Node, getter_name: String, item_id: String) -> bool:
	if loader == null or not loader.has_method(getter_name):
		return true
	var raw_days: Variant = loader.call(getter_name)
	if not (raw_days is Dictionary):
		return true
	var days: Dictionary = raw_days as Dictionary
	var raw_day: Variant = days.get(StringName(item_id), days.get(item_id, 1))
	var unlock_day: int = maxi(1, int(raw_day))
	return _current_day_number() >= unlock_day


func _current_day_number() -> int:
	if _progression_node == null or not _progression_node.has_method("get_value"):
		return 1
	return maxi(1, int(_progression_node.call("get_value", &"nDays")))


func get_merchant_price(item_id: String) -> int:
	var base_price: int = _base_merchant_price(item_id)
	var factor: float = _merchant_growth_price_factor(item_id)
	if factor <= 1.0:
		return base_price
	var owned_count: int = _merchant_owned_count(item_id)
	return _growth_build_price(base_price, factor, owned_count)


func _base_merchant_price(item_id: String) -> int:
	var scene: Node = get_tree().current_scene
	var loader: Node = scene.get_node_or_null("LevelLoader") if scene != null else null
	if loader != null and loader.has_method("get_loaded_merchant_prices"):
		var raw_prices: Variant = loader.call("get_loaded_merchant_prices")
		if raw_prices is Dictionary:
			var prices: Dictionary = raw_prices as Dictionary
			if prices.has(StringName(item_id)):
				return maxi(0, int(prices[StringName(item_id)]))
			if prices.has(item_id):
				return maxi(0, int(prices[item_id]))
	if loader != null and loader.has_method("get_loaded_shop_prices"):
		var raw_legacy_prices: Variant = loader.call("get_loaded_shop_prices")
		if raw_legacy_prices is Dictionary:
			var legacy_prices: Dictionary = raw_legacy_prices as Dictionary
			if legacy_prices.has(StringName(item_id)):
				return maxi(0, int(legacy_prices[StringName(item_id)]))
			if legacy_prices.has(item_id):
				return maxi(0, int(legacy_prices[item_id]))
	return ItemCatalog.get_price(item_id)


func _merchant_growth_price_factor(item_id: String) -> float:
	var scene: Node = get_tree().current_scene
	var loader: Node = scene.get_node_or_null("LevelLoader") if scene != null else null
	if loader != null and loader.has_method("get_loaded_merchant_growth_price_factors"):
		var raw_factors: Variant = loader.call("get_loaded_merchant_growth_price_factors")
		if raw_factors is Dictionary:
			var factors: Dictionary = raw_factors as Dictionary
			if factors.has(StringName(item_id)):
				return maxf(1.0, float(factors[StringName(item_id)]))
			if factors.has(item_id):
				return maxf(1.0, float(factors[item_id]))
	return 1.0


func _merchant_owned_count(item_id: String) -> int:
	if item_id == "seed" and _progression_node != null and _progression_node.has_method("get_value"):
		return maxi(0, int(_progression_node.call("get_value", SEED_KEY)))
	return get_inventory_item_quantity(item_id)


func _merchant_price_for_owned_count(item_id: String, owned_count: int) -> int:
	var base_price: int = _base_merchant_price(item_id)
	var factor: float = _merchant_growth_price_factor(item_id)
	if factor <= 1.0:
		return base_price
	return _growth_build_price(base_price, factor, owned_count)


func _merchant_price_total_for_next(item_id: String, count: int) -> int:
	if count <= 0:
		return 0
	var total: int = 0
	var owned_count: int = _merchant_owned_count(item_id)
	for i: int in range(count):
		total += _merchant_price_for_owned_count(item_id, owned_count + i)
	return total


## How many of item_id the player can currently afford (floor(currency / price)).
func get_build_affordable_quantity(item_id: String) -> int:
	if not is_build_item_available(item_id):
		return 0
	# Inventory-backed buildables are gated by how many the player owns, not currency.
	if ItemCatalog.is_inventory_backed(item_id):
		return get_inventory_item_quantity(item_id)
	var limit_remaining: int = _build_limit_remaining(item_id)
	var key: StringName = _build_currency_prog_key(item_id)
	var next_price: int = get_build_price(item_id)
	if next_price <= 0:
		return max(0, limit_remaining) if limit_remaining >= 0 else 0
	if key == &"" or _progression_node == null:
		return 0
	var owned: int = int(_progression_node.call("get_value", key))
	var factor: float = _build_growth_price_factor(item_id)
	if factor <= 1.0:
		@warning_ignore("integer_division")
		var flat_affordable: int = owned / next_price
		if limit_remaining >= 0:
			return mini(flat_affordable, limit_remaining)
		return flat_affordable
	var affordable: int = 0
	var total: int = 0
	var placed_count: int = _placed_build_count(item_id)
	while limit_remaining < 0 or affordable < limit_remaining:
		var price: int = _build_price_for_placed_count(item_id, placed_count + affordable)
		if price <= 0:
			break
		if total + price > owned:
			break
		total += price
		affordable += 1
	return affordable


func get_merchant_affordable_quantity(item_id: String) -> int:
	if not is_merchant_item_available(item_id):
		return 0
	var price: int = get_merchant_price(item_id)
	var key: StringName = _build_currency_prog_key(item_id)
	if price <= 0 or key == &"" or _progression_node == null:
		return 0
	var owned: int = int(_progression_node.call("get_value", key))
	var factor: float = _merchant_growth_price_factor(item_id)
	if factor <= 1.0:
		@warning_ignore("integer_division")
		var flat_affordable: int = owned / price
		return flat_affordable
	var affordable: int = 0
	var total: int = 0
	var owned_count: int = _merchant_owned_count(item_id)
	while true:
		var next_price: int = _merchant_price_for_owned_count(item_id, owned_count + affordable)
		if next_price <= 0:
			break
		if total + next_price > owned:
			break
		total += next_price
		affordable += 1
	return affordable


func can_afford_build(item_id: String, count: int = 1) -> bool:
	return count > 0 and get_build_affordable_quantity(item_id) >= count


func can_afford_merchant_item(item_id: String, count: int = 1) -> bool:
	return count > 0 and get_merchant_affordable_quantity(item_id) >= count

## Spend the cost of `count` units of item_id. Returns false (spending nothing)
## when unaffordable, so callers can place only what was actually paid for.
func try_purchase_build(item_id: String, count: int) -> bool:
	if count <= 0:
		return false
	if not is_build_item_available(item_id):
		return false
	# Inventory-backed buildables were already paid for at the merchant; placing one
	# just consumes it from the inventory.
	if ItemCatalog.is_inventory_backed(item_id):
		return consume_inventory_item(item_id, count)
	var price: int = _build_price_total_for_next(item_id, count)
	var key: StringName = _build_currency_prog_key(item_id)
	if price <= 0:
		return true
	if key == &"" or _progression_node == null:
		return false
	return bool(_progression_node.call("spend", key, price))


func try_purchase_merchant_item(item_id: String, count: int = 1) -> bool:
	if count <= 0:
		return false
	if not is_merchant_item_available(item_id):
		return false
	var price: int = _merchant_price_total_for_next(item_id, count)
	var key: StringName = _build_currency_prog_key(item_id)
	if price <= 0 or key == &"" or _progression_node == null:
		return false
	return bool(_progression_node.call("spend", key, price))


func try_purchase_shop_inventory_item(item_id: String, count: int = 1) -> bool:
	if count != 1 or not ItemCatalog.is_weapon(item_id) or _has_possessed_weapon(item_id):
		return false
	if not can_add_inventory(item_id, count):
		return false
	if not try_purchase_merchant_item(item_id, count):
		return false
	return add_inventory(item_id, count)


## Buy an inventory-backed placeable (e.g. pasteque) at the seed merchant: spend
## its money price and stock the unit(s) in the inventory, all-or-nothing. The building
## is later placed from the toolbuild picker, which consumes it from the inventory.
func try_purchase_placeable_merchant_item(item_id: String, count: int = 1) -> bool:
	if count <= 0 or not ItemCatalog.is_inventory_backed(item_id):
		return false
	if not is_merchant_item_available(item_id):
		return false
	if not can_add_inventory(item_id, count):
		return false
	if not try_purchase_merchant_item(item_id, count):
		return false
	return add_inventory(item_id, count)


func try_purchase_seed_merchant_item(item_id: String, count: int = 1) -> bool:
	if item_id != "seed" or count <= 0:
		return false
	if _progression_node == null or not _progression_node.has_method("update_seeds"):
		return false
	if not try_purchase_merchant_item(item_id, count):
		return false
	return bool(_progression_node.call("update_seeds", count))


## Describes the special reward the merchant should offer right now, or {} when the
## row must stay hidden (no survived-night reward, or already collected). Returned dict:
## { "rewards": [{ "currency": String, "amount": int, "key": String }, ...], "night_index": int,
##   "day": int, "one_time": bool }. Drives the merchant's top "special reward" row.
func get_active_night_reward() -> Dictionary:
	var scene: Node = get_tree().current_scene
	if scene == null or _progression_node == null:
		return {}
	var loader: Node = scene.get_node_or_null("LevelLoader")
	if loader == null or not loader.has_method("get_loaded_spawn_playlist"):
		return {}
	var playlist: LevelSpawnPlaylist = loader.call("get_loaded_spawn_playlist") as LevelSpawnPlaylist
	if playlist == null:
		return {}
	var total_nights: int = playlist.get_night_count()
	if total_nights <= 0:
		return {}
	var day: int = int(_progression_node.call("get_value", &"nDays"))
	# Rewards are paid by the merchant after a night is survived. nDays has already
	# advanced on the night->day transition, so Day 2 pays playlist Night 1.
	var completed_night_index: int = day - 2
	if completed_night_index < 0:
		return {}
	var night_index: int = completed_night_index % total_nights
	var night: NightSpawnPlaylist = playlist.nights[night_index]
	if night == null:
		return {}
	var rewards: Array[Dictionary] = []
	var one_time: bool = bool(night.special_reward_one_time)
	var reward_index: int = 0
	for reward: NightReward in night.special_rewards:
		var reward_key: String = str(reward_index)
		reward_index += 1
		if reward == null or reward.amount <= 0:
			continue
		if not GameState.is_special_reward_available(night_index, day, one_time, reward_key):
			continue
		rewards.append({"currency": String(reward.currency), "amount": int(reward.amount), "key": reward_key})
	if rewards.is_empty():
		return {}
	return {"rewards": rewards, "night_index": night_index, "day": day, "one_time": one_time}


## Collect one current-night special reward row: records the claim (so that row hides) and
## grants its currency with a fly-to-HUD animation. Returns false when nothing is claimable.
## `start_global_position` is where the reward sprites launch from.
func claim_active_night_reward(start_global_position: Vector2, reward_key: String = "") -> bool:
	var info: Dictionary = get_active_night_reward()
	if info.is_empty():
		return false
	for raw_reward: Variant in info["rewards"] as Array:
		var reward: Dictionary = raw_reward as Dictionary
		var current_key: String = str(reward.get("key", ""))
		if reward_key != "" and current_key != reward_key:
			continue
		GameState.record_special_reward_claim(
			int(info["night_index"]), int(info["day"]), bool(info["one_time"]), current_key
		)
		_award_reward_currency(String(reward["currency"]), int(reward["amount"]), start_global_position)
		return true
	return false


func _award_reward_currency(currency: String, amount: int, start_global_position: Vector2) -> void:
	if amount <= 0:
		return
	var icon: Node = _reward_icon_node(currency)
	var animated: int = mini(amount, REWARD_ANIM_CAP) if icon != null else 0
	# Overflow past the animation cap (and everything when the icon is missing) is
	# credited straight away; each flying sprite credits one unit as it lands.
	var immediate: int = amount - animated
	if immediate > 0:
		_credit_reward_currency(currency, immediate)
	if animated <= 0:
		return
	var world_position: Vector2 = get_viewport().get_canvas_transform().affine_inverse() * start_global_position
	for i: int in range(animated):
		match currency:
			"seed":
				icon.call("animate_seed_harvest", world_position, i, Callable(), true)
			"gem":
				icon.call("animate_gem_harvest", world_position, i)
			"money":
				icon.call("animate_money_harvest", world_position, i)


func _credit_reward_currency(currency: String, amount: int) -> void:
	if _progression_node == null or amount <= 0:
		return
	match currency:
		"seed":
			_progression_node.call("update_seeds", amount)
		"gem":
			_progression_node.call("update_gems", amount)
		"money":
			_progression_node.call("update_money", amount)


func _reward_icon_node(currency: String) -> Node:
	match currency:
		"seed":
			return get_node_or_null("currenciesUI/seedIcon")
		"gem":
			return get_node_or_null("currenciesUI/gemIcon")
		"money":
			return get_node_or_null("currenciesUI/moneyIcon")
	return null


## Public: how many more of item_id may still be placed given its per-world build
## limit, or -1 when the item has no limit. Used by the toolbuild picker to show "remaining : x".
func get_build_limit_remaining(item_id: String) -> int:
	return _build_limit_remaining(item_id)


func _build_limit_remaining(item_id: String) -> int:
	var limit: int = _build_limit_for_item(item_id)
	if limit < 0:
		return -1
	var built_count: int = _placed_build_count(item_id)
	return maxi(0, limit - built_count)


func _build_limit_for_item(item_id: String) -> int:
	if item_id != "rose_shop_counter":
		return -1
	var scene: Node = get_tree().current_scene
	var loader: Node = scene.get_node_or_null("LevelLoader") if scene != null else null
	if loader != null and loader.has_method("get_loaded_rose_shop_counter_limit"):
		return clampi(int(loader.call("get_loaded_rose_shop_counter_limit")), 1, 99)
	return 2


func _placed_build_count(item_id: String) -> int:
	var scene: Node = get_tree().current_scene
	var manager: Node = scene.get_node_or_null("Map/BuildingObjectManager") if scene != null else null
	var managed_count: int = 0
	if manager != null and manager.has_method("count_buildings_by_item_id"):
		managed_count = int(manager.call("count_buildings_by_item_id", item_id))
	var tile_count: int = _placed_build_tile_count(item_id)
	return maxi(managed_count, tile_count)


func _placed_build_tile_count(item_id: String) -> int:
	var item_def: Dictionary = ItemCatalog.get_placeable_def(item_id)
	if item_def.is_empty():
		return 0
	var tile_layer: TileMapLayer = _build_tile_layer_for_item_def(item_def)
	if tile_layer == null:
		return 0
	var count: int = 0
	for raw_cell: Variant in tile_layer.get_used_cells():
		var cell: Vector2i = raw_cell as Vector2i
		var placed_item_id: String = ItemCatalog.get_placeable_id_for_tile(str(tile_layer.name), tile_layer.get_cell_atlas_coords(cell))
		if placed_item_id == item_id:
			count += 1
	return count


func _build_tile_layer_for_item_def(item_def: Dictionary) -> TileMapLayer:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return null
	var target_layer: String = str(item_def.get("target_layer", "wallz"))
	if target_layer == "buildings":
		target_layer = "traversable_buildings"
	var map_root: Node = scene.get_node_or_null("Map")
	match target_layer:
		"plantz", "traversable_buildings", "blocking_buildings", "fences":
			return scene.get_node_or_null("Map/MonTilemap/%s" % target_layer) as TileMapLayer
		"wallz":
			if map_root != null:
				var level_wallz: TileMapLayer = map_root.get_node_or_null("wallz") as TileMapLayer
				if level_wallz != null:
					return level_wallz
			return scene.get_node_or_null("Map/MonTilemap/wallz") as TileMapLayer
	return null

## Refund the full price of `count` removed units back to the matching currency,
## flying one currency icon per unit from `world_position` to the HUD and crediting
## on arrival — exactly like the seed/gem/money harvest. Falls back to an instant credit
## if the HUD icon is unavailable so a refund is never lost.
func refund_build(item_id: String, world_position: Vector2, count: int = 1) -> void:
	if count <= 0:
		return
	# Inventory-backed buildables are returned to the inventory rather than refunded as
	# currency (their stored contents, e.g. a tank's water, are discarded).
	if ItemCatalog.is_inventory_backed(item_id):
		_refund_inventory_backed_build(item_id, world_position, count)
		return
	var price: int = get_build_price(item_id)
	var units: int = price * count
	if units <= 0:
		return
	var currency: StringName = ItemCatalog.get_currency(item_id)
	var icon: Node = null
	var animate_method: String = ""
	if currency == &"seed":
		icon = get_node_or_null("currenciesUI/seedIcon")
		animate_method = "animate_seed_harvest"
	elif currency == &"gem":
		icon = get_node_or_null("currenciesUI/gemIcon")
		animate_method = "animate_gem_harvest"
	elif currency == &"money":
		icon = get_node_or_null("currenciesUI/moneyIcon")
		animate_method = "animate_money_harvest"
	if icon != null and icon.has_method(animate_method):
		# Deconstruct refunds fly the whole building's worth of currency within ~1s
		# regardless of the amount, by compressing the per-icon stagger delay.
		var stagger: float = minf(0.06, 1.0 / float(maxi(units - 1, 1)))
		for i: int in range(units):
			if animate_method == "animate_seed_harvest":
				icon.call(animate_method, world_position, i, Callable(), true, stagger)
			else:
				icon.call(animate_method, world_position, i, stagger)
		return
	# Fallback: no HUD icon to animate, so credit immediately.
	var key: StringName = _build_currency_prog_key(item_id)
	if key != &"" and _progression_node != null:
		_progression_node.call("update_value", key, units)


func _refund_inventory_backed_build(item_id: String, world_position: Vector2, count: int) -> void:
	var target_position: Vector2 = _inventory_backed_refund_target_position(item_id)
	if not add_inventory(item_id, count):
		return
	var start_global_position: Vector2 = get_viewport().get_canvas_transform() * world_position
	var stagger: float = minf(0.06, 1.0 / float(maxi(count - 1, 1)))
	for i: int in range(count):
		_animate_inventory_item_to_position(item_id, start_global_position, target_position, i, stagger)

func _setup_starting_inventory() -> void:
	inventory_slots.resize(INVENTORY_SLOT_COUNT)
	for i in range(INVENTORY_SLOT_COUNT):
		inventory_slots[i] = _empty_slot()
	for weapon_id: StringName in _get_level_starting_weapons():
		add_inventory(String(weapon_id), 1)
	# The gardening/hammer tools are no longer inventory items; they are fixed quickbar menu
	# slots shown unconditionally (see QUICK_SLOT_KINDS / _build_toolbar).
	# Any non-weapon items the level grants at start (e.g. pasteque x10).
	var starting_items: Dictionary = _get_level_starting_items()
	for raw_item_id: Variant in starting_items:
		var item_id: String = str(raw_item_id)
		var quantity: int = int(starting_items[raw_item_id])
		if item_id != "" and quantity > 0:
			add_inventory(item_id, quantity)


func _get_level_starting_weapons() -> Array[StringName]:
	var scene: Node = get_tree().current_scene
	var loader: Node = scene.get_node_or_null("LevelLoader") if scene != null else null
	if loader != null and loader.has_method("get_loaded_starting_weapons"):
		var raw_weapons: Variant = loader.call("get_loaded_starting_weapons")
		if raw_weapons is Array:
			var weapons: Array[StringName] = []
			for raw_weapon: Variant in raw_weapons:
				var weapon_id: StringName = StringName(str(raw_weapon))
				if weapon_id != &"" and ItemCatalog.is_weapon(String(weapon_id)):
					weapons.append(weapon_id)
			return weapons
	return [&"spray"]


func _get_level_starting_items() -> Dictionary:
	var scene: Node = get_tree().current_scene
	var loader: Node = scene.get_node_or_null("LevelLoader") if scene != null else null
	if loader != null and loader.has_method("get_loaded_starting_items"):
		var raw_items: Variant = loader.call("get_loaded_starting_items")
		if raw_items is Dictionary:
			return raw_items as Dictionary
	return {}


# Generic inventory add, reusable for purchases, pickups, and rewards.
# Existing stacks are filled before new slots are used. The operation is
# all-or-nothing when there is insufficient inventory capacity.
func add_inventory(item_id: String, quantity: int = 1) -> bool:
	if item_id == "" or quantity <= 0:
		return false
	if not can_add_inventory(item_id, quantity):
		return false

	var remaining: int = quantity
	var max_stack: int = ItemCatalog.get_max_stack(item_id)
	for i: int in range(inventory_slots.size()):
		var slot_data: Dictionary = inventory_slots[i]
		if _slot_item_id(slot_data) != item_id:
			continue
		var current_quantity: int = _slot_quantity(slot_data)
		var added_quantity: int = mini(remaining, max_stack - current_quantity)
		if added_quantity <= 0:
			continue
		inventory_slots[i] = _make_slot(item_id, current_quantity + added_quantity)
		remaining -= added_quantity
		if remaining == 0:
			break

	# The quickbar is a fixed set of menu slots now, so the backpack is a plain flat store:
	# new stacks simply take the first free slot.
	while remaining > 0:
		var free_index: int = _first_free_slot(0)
		if free_index < 0:
			break
		var new_stack_quantity: int = mini(remaining, max_stack)
		inventory_slots[free_index] = _make_slot(item_id, new_stack_quantity)
		remaining -= new_stack_quantity

	_refresh_all_slots()
	Sfx.play_sound(&"bag")
	return true

func can_add_inventory(item_id: String, quantity: int = 1) -> bool:
	if item_id == "" or quantity <= 0:
		return false
	if ItemCatalog.is_weapon(item_id):
		return quantity == 1 and not _has_possessed_weapon(item_id) and _first_free_slot() >= 0
	var capacity: int = 0
	var max_stack: int = ItemCatalog.get_max_stack(item_id)
	for slot_data: Dictionary in inventory_slots:
		var slotted_item_id: String = _slot_item_id(slot_data)
		if slotted_item_id == item_id:
			capacity += max_stack - _slot_quantity(slot_data)
		elif slotted_item_id == "":
			capacity += max_stack
		if capacity >= quantity:
			return true
	return false

func _first_free_slot(start_index: int = 0) -> int:
	for i in range(maxi(0, start_index), inventory_slots.size()):
		if _slot_item_id(inventory_slots[i]) == "":
			return i
	return -1

func _make_slot(item_id: String, quantity: int) -> Dictionary:
	if item_id == "" or quantity <= 0:
		return _empty_slot()
	return {
		"item_id": item_id,
		"quantity": mini(quantity, ItemCatalog.get_max_stack(item_id)),
	}

func _empty_slot() -> Dictionary:
	return {
		"item_id": "",
		"quantity": 0,
	}

func _slot_item_id(slot_data: Dictionary) -> String:
	return str(slot_data.get("item_id", ""))

func _slot_quantity(slot_data: Dictionary) -> int:
	return int(slot_data.get("quantity", 0))

func _has_inventory_weapon(item_id: String) -> bool:
	return ItemCatalog.is_weapon(item_id) and get_inventory_item_quantity(item_id) > 0

func _has_possessed_weapon(item_id: String) -> bool:
	return ItemCatalog.is_weapon(item_id) and (_possessed_weapon_ids.has(item_id) or _has_inventory_weapon(item_id))

func reset_possessed_weapons_from_inventory() -> void:
	_possessed_weapon_ids.clear()
	for slot_data: Dictionary in inventory_slots:
		var item_id: String = _slot_item_id(slot_data)
		if item_id != "" and ItemCatalog.is_weapon(item_id):
			_possessed_weapon_ids[item_id] = true

func _show_inventory() -> void:
	_set_inventory_open(true)
	_refresh_all_slots()

func _hide_inventory() -> void:
	_set_inventory_open(false)

func is_inventory_open() -> bool:
	return inventory_modal.visible

func is_startup_loading() -> bool:
	return _startup_loading_overlay != null

func _set_inventory_open(is_open: bool) -> void:
	# The modal lives under the Modals Control, which is hidden by default; a child
	# only renders when every ancestor is visible, so the parent must toggle too.
	modals_root.visible = is_open
	inventory_modal.visible = is_open
	# Quick slots stay visible at all times so they are always available.
	toolbar_anchor.visible = true
	if tile_hover_info and tile_hover_info.has_method("set_enabled"):
		tile_hover_info.call("set_enabled", not is_open)

func _create_startup_loading_overlay() -> void:
	_startup_loading_overlay = Control.new()
	_startup_loading_overlay.name = "StartupLoadingOverlay"
	_startup_loading_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_startup_loading_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_startup_loading_overlay.z_index = 200
	add_child(_startup_loading_overlay)

	var background: ColorRect = ColorRect.new()
	background.color = Color(0.05, 0.055, 0.045, 0.88)
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	_startup_loading_overlay.add_child(background)

	var panel: PanelContainer = PanelContainer.new()
	panel.custom_minimum_size = Vector2(360.0, 86.0)
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -180.0
	panel.offset_top = -43.0
	panel.offset_right = 180.0
	panel.offset_bottom = 43.0
	var panel_style: StyleBoxFlat = StyleBoxFlat.new()
	panel_style.bg_color = Color(0.12, 0.14, 0.105, 0.96)
	panel_style.border_color = Color(0.42, 0.48, 0.25, 1.0)
	panel_style.border_width_left = 2
	panel_style.border_width_top = 2
	panel_style.border_width_right = 2
	panel_style.border_width_bottom = 2
	panel_style.corner_radius_top_left = 6
	panel_style.corner_radius_top_right = 6
	panel_style.corner_radius_bottom_left = 6
	panel_style.corner_radius_bottom_right = 6
	panel.add_theme_stylebox_override("panel", panel_style)
	_startup_loading_overlay.add_child(panel)

	var margin: MarginContainer = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_bottom", 14)
	panel.add_child(margin)

	var content: VBoxContainer = VBoxContainer.new()
	content.add_theme_constant_override("separation", 10)
	margin.add_child(content)

	_startup_loading_label = Label.new()
	_startup_loading_label.text = "Loading"
	_startup_loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_startup_loading_label.add_theme_font_size_override("font_size", 16)
	_startup_loading_label.add_theme_color_override("font_color", Color(0.92, 0.88, 0.78, 1.0))
	content.add_child(_startup_loading_label)

	_startup_loading_bar = ProgressBar.new()
	_startup_loading_bar.min_value = 0.0
	_startup_loading_bar.max_value = 100.0
	_startup_loading_bar.value = 0.0
	_startup_loading_bar.show_percentage = false
	_startup_loading_bar.custom_minimum_size = Vector2(320.0, 16.0)
	var bar_background: StyleBoxFlat = StyleBoxFlat.new()
	bar_background.bg_color = Color(0.04, 0.045, 0.035, 1.0)
	bar_background.corner_radius_top_left = 4
	bar_background.corner_radius_top_right = 4
	bar_background.corner_radius_bottom_left = 4
	bar_background.corner_radius_bottom_right = 4
	_startup_loading_bar.add_theme_stylebox_override("background", bar_background)
	var bar_fill: StyleBoxFlat = StyleBoxFlat.new()
	bar_fill.bg_color = Color(0.54, 0.68, 0.24, 1.0)
	bar_fill.corner_radius_top_left = 4
	bar_fill.corner_radius_top_right = 4
	bar_fill.corner_radius_bottom_left = 4
	bar_fill.corner_radius_bottom_right = 4
	_startup_loading_bar.add_theme_stylebox_override("fill", bar_fill)
	content.add_child(_startup_loading_bar)

func _connect_startup_loading_signals() -> void:
	var scene: Node = get_tree().get_current_scene()
	if not scene:
		return

	var flow_code: Node = scene.get_node_or_null("CPP/FlowFieldNative/FlowFieldCode")
	if flow_code:
		if flow_code.has_signal("loading_progress"):
			flow_code.connect("loading_progress", Callable(self, "_on_startup_loading_progress"))
		if bool(flow_code.get("is_ready")):
			_on_startup_loading_progress(0.45, "Navigation service ready")

	var building_manager: Node = scene.get_node_or_null("Map/BuildingManager")
	if building_manager:
		if building_manager.has_signal("startup_loading_progress"):
			building_manager.connect("startup_loading_progress", Callable(self, "_on_startup_loading_progress"))
		if building_manager.has_signal("startup_loading_finished"):
			building_manager.connect("startup_loading_finished", Callable(self, "_on_startup_loading_finished"))
		if bool(building_manager.get("_startup_ready")):
			_on_startup_loading_finished()

func _on_startup_loading_progress(progress: float, label: String) -> void:
	if _startup_loading_finished:
		return
	var clamped_progress: float = clampf(progress, 0.0, 1.0)
	_startup_loading_value = maxf(_startup_loading_value, clamped_progress)
	if _startup_loading_bar:
		_startup_loading_bar.value = _startup_loading_value * 100.0
	if _startup_loading_label:
		_startup_loading_label.text = label

func _on_startup_loading_finished() -> void:
	if _startup_loading_finished:
		return
	_on_startup_loading_progress(1.0, "Ready")
	_startup_loading_finished = true
	await get_tree().create_timer(0.12).timeout
	if _startup_loading_overlay:
		_startup_loading_overlay.queue_free()
		_startup_loading_overlay = null

func _build_toolbar() -> void:
	_clear_container(toolbar_slots)
	_toolbar_slot_nodes.clear()

	for i in range(QUICK_SLOT_KINDS.size()):
		var slot: ItemSlot = ItemSlotScript.new()
		toolbar_slots.add_child(slot)
		slot.setup(self, "quick", i)
		_toolbar_slot_nodes.append(slot)
	call_deferred("_fit_toolbar_panel_to_slots")

func _fit_toolbar_panel_to_slots() -> void:
	if toolbar_panel == null:
		return
	var slot_count: int = _toolbar_slot_nodes.size()
	var gaps: int = maxi(slot_count - 1, 0)
	var panel_size: Vector2 = Vector2(
		QUICK_SLOT_SIZE.x * float(slot_count) + QUICK_SLOT_GAP * float(gaps) + TOOLBAR_PADDING.x * 2.0,
		QUICK_SLOT_SIZE.y + TOOLBAR_PADDING.y * 2.0
	)
	toolbar_panel.custom_minimum_size = panel_size
	toolbar_panel.offset_left = -panel_size.x * 0.5
	toolbar_panel.offset_right = panel_size.x * 0.5
	toolbar_panel.offset_top = -panel_size.y
	toolbar_panel.offset_bottom = 0.0

func get_quick_bar_top_y() -> float:
	if toolbar_panel == null:
		return -1.0
	return toolbar_panel.get_global_rect().position.y

func _build_inventory() -> void:
	_clear_container(inventory_content)
	_inventory_slot_nodes.clear()

	var title := Label.new()
	title.text = "Inventory"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(0.92, 0.88, 0.78))
	inventory_content.add_child(title)

	@warning_ignore("integer_division")
	for row_index in range(INVENTORY_SLOT_COUNT / INVENTORY_COLUMNS):
		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.add_theme_constant_override("separation", 6)
		inventory_content.add_child(row)

		for column_index in range(INVENTORY_COLUMNS):
			var slot_index := row_index * INVENTORY_COLUMNS + column_index
			var slot: ItemSlot = ItemSlotScript.new()
			row.add_child(slot)
			slot.setup(self, "inventory", slot_index)
			_inventory_slot_nodes.append(slot)

func _refresh_all_slots() -> void:
	_normalize_unique_weapons()
	_strip_non_backpack_items_from_inventory()
	# Keep the equipped weapon pointing at a weapon the player still owns.
	if equipped_weapon_id != "" and not _has_inventory_weapon(equipped_weapon_id):
		equipped_weapon_id = _first_possessed_weapon_id()
	for i in range(_toolbar_slot_nodes.size()):
		_apply_toolbar_slot(_toolbar_slot_nodes[i], i)

	for i in range(_inventory_slot_nodes.size()):
		_apply_inventory_slot(_inventory_slot_nodes[i], i)

	_refresh_toolbar_info()
	inventory_changed.emit()

## Strips items that are not real backpack contents (the build tools and the ephemeral unbuild
## tool) from the inventory — e.g. when loading an older save that stored them as inventory items.
func _strip_non_backpack_items_from_inventory() -> void:
	for i: int in range(inventory_slots.size()):
		var item_id: String = _slot_item_id(inventory_slots[i])
		if item_id == GARDENING_ID or item_id == HAMMER_ID or item_id == UNBUILD_TOOL_ID:
			inventory_slots[i] = _empty_slot()

func _normalize_unique_weapons() -> void:
	var seen: Dictionary = {}
	for i: int in range(inventory_slots.size()):
		var slot_data: Dictionary = inventory_slots[i]
		var item_id: String = _slot_item_id(slot_data)
		if item_id == "" or not ItemCatalog.is_weapon(item_id):
			continue
		_possessed_weapon_ids[item_id] = true
		if seen.has(item_id):
			inventory_slots[i] = _empty_slot()
			continue
		seen[item_id] = true
		if _slot_quantity(slot_data) != 1:
			inventory_slots[i] = _make_slot(item_id, 1)

func _refresh_toolbar_info() -> void:
	if toolbar_info == null:
		return
	# Play mode shows no labels; while a menu is open it renders its own item labels, so the
	# toolbar info line stays empty in both states.
	toolbar_info.text = ""

## Renders a fixed quickbar slot: the weapon slot shows the equipped weapon, the others show
## their build tool. Selected only while its menu is the open one; disabled when its menu is locked.
func _apply_toolbar_slot(slot: ItemSlot, index: int) -> void:
	var kind: String = QUICK_SLOT_KINDS[index]
	var item_id: String = get_equipped_weapon_id() if kind == WEAPON_SLOT_KIND else kind
	var item_def: Dictionary = ItemCatalog.get_item_def(item_id)
	slot.set_item(item_def if not item_def.is_empty() else {}, 0)
	slot.set_disabled(_is_quickbar_slot_disabled(kind))
	slot.set_selected(quickbar_active and index == active_slot_index)

## Renders a backpack slot straight from its inventory contents (never selected/disabled).
func _apply_inventory_slot(slot: ItemSlot, slot_index: int) -> void:
	var slot_data: Dictionary = inventory_slots[slot_index]
	var item_def: Dictionary = ItemCatalog.get_item_def(_slot_item_id(slot_data))
	slot.set_item(item_def if not item_def.is_empty() else {}, _slot_quantity(slot_data))
	slot.set_disabled(false)
	slot.set_selected(false)

func _clear_container(container: Container) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()

## Gamepad: steps the open menu to the next non-disabled quickbar slot (wrapping). Only meaningful
## while the quickbar is active; no-op otherwise.
func step_selected_quick_slot(direction: int) -> void:
	if direction == 0 or not quickbar_active:
		return
	var count: int = QUICK_SLOT_KINDS.size()
	var next_index: int = active_slot_index
	for _step: int in range(count):
		next_index = wrapi(next_index + direction, 0, count)
		if not _is_quickbar_slot_disabled(QUICK_SLOT_KINDS[next_index]):
			activate_quickbar_slot(next_index)
			return

func _quick_slot_index_from_event(event: InputEventKey) -> int:
	if event.physical_keycode >= KEY_1 and event.physical_keycode <= KEY_8:
		return int(event.physical_keycode - KEY_1)
	if event.keycode >= KEY_1 and event.keycode <= KEY_8:
		return int(event.keycode - KEY_1)
	if event.unicode >= 49 and event.unicode <= 56:
		return int(event.unicode - 49)

	var azerty_top_row: Array[int] = [38, 233, 34, 39, 40, 45, 232, 95]
	for i in range(azerty_top_row.size()):
		if event.unicode == azerty_top_row[i]:
			return i

	return -1
