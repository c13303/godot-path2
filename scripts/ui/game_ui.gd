extends CanvasLayer

const ItemSlotScript = preload("res://scripts/ui/item_slot.gd")
const QUICK_SLOT_COUNT: int = 8
const INVENTORY_SLOT_COUNT: int = 32
const INVENTORY_COLUMNS: int = 8

const SEED_KEY: StringName = &"seeds"
const GEM_KEY: StringName = &"gems"
const MONEY_KEY: StringName = &"money"
# Quick-slot tool that drives build/unbuild mode rather than acting as a weapon.
const BUILD_TOOL_ID: String = "build_tool"
const UNBUILD_TOOL_ID: String = "unbuild_tool"
const ITEM_NAME_KEY_PREFIX: String = "item."

@onready var toolbar_slots: HBoxContainer = $"bottom anchor/toolbar"
@onready var toolbar_info: RichTextLabel = get_node_or_null("bottom anchor/toolbarInfo") as RichTextLabel
@onready var toolbar_anchor: Control = $"bottom anchor"
@onready var modals_root: Control = $Modals
@onready var inventory_modal: Panel = $Modals/inventoryModal
@onready var close_button: Button = $Modals/inventoryModal/CloseButton
@onready var inventory_content: VBoxContainer = $Modals/inventoryModal/MarginContainer/Content
@onready var tile_hover_info: Node = $"../CPP/TileHoverInfo"
@onready var day_toggle: Button = $"top anchor/dayToggle"

const MOONSUN_TEXTURE: Texture2D = preload("res://assets/sprites/legval/moonsun.png")
const MOONSUN_TILE_SIZE: int = 64
var _sun_icon: AtlasTexture
var _moon_icon: AtlasTexture
var _merchant_icon: AtlasTexture

var inventory_slots: Array[Dictionary] = []
var selected_quick_index: int = 0
# The building the shop has selected for placement (rose/wall/turret), or "" when
# nothing is selected. While non-empty the player is in build mode: the build
# system places this item and the player's weapon is suppressed. Buildings are
# paid for directly from currency on placement and never enter the inventory.
var selected_build_item_id: String = ""
var _progression_node: Node
var _toolbar_slot_nodes: Array[ItemSlot] = []
var _inventory_slot_nodes: Array[ItemSlot] = []
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
	# Day 1 starts in build mode (the shop is open). Later days re-select the build
	# tool when the day's seed-harvest finishes (driven from the shop). A loaded save
	# overrides this afterwards via its restored selected_quick_index.
	if not GameState.is_night:
		call_deferred("select_build_tool")

func _setup_day_toggle() -> void:
	_sun_icon = AtlasTexture.new()
	_sun_icon.atlas = MOONSUN_TEXTURE
	_sun_icon.region = Rect2(0, 0, MOONSUN_TILE_SIZE, MOONSUN_TILE_SIZE)
	_moon_icon = AtlasTexture.new()
	_moon_icon.atlas = MOONSUN_TEXTURE
	_moon_icon.region = Rect2(MOONSUN_TILE_SIZE, 0, MOONSUN_TILE_SIZE, MOONSUN_TILE_SIZE)
	_merchant_icon = AtlasTexture.new()
	_merchant_icon.atlas = MOONSUN_TEXTURE
	_merchant_icon.region = Rect2(MOONSUN_TILE_SIZE * 2, 0, MOONSUN_TILE_SIZE, MOONSUN_TILE_SIZE)

	day_toggle.pressed.connect(_on_day_toggle_pressed)
	GameState.mode_changed.connect(_on_game_mode_changed)
	if not GameState.seed_merchant_phase_changed.is_connected(_on_seed_merchant_phase_changed):
		GameState.seed_merchant_phase_changed.connect(_on_seed_merchant_phase_changed)
	_update_day_toggle_icon(GameState.is_night)

func _on_day_toggle_pressed() -> void:
	if GameState.is_seed_merchant_phase:
		var scene: Node = get_tree().current_scene
		var manager: Node = scene.get_node_or_null("Map/BuildingManager") if scene != null else null
		if manager != null and manager.has_method("request_seed_merchant_leave"):
			manager.call("request_seed_merchant_leave")
		return
	GameState.toggle()

func _on_game_mode_changed(is_night: bool) -> void:
	_update_day_toggle_icon(is_night)
	# Night: non-weapon quick items (build/unbuild tools, placeables) are disabled
	# and the player is auto-armed with their first weapon. Day re-enables them; the
	# shop re-selects the build tool once the seed harvest finishes.
	if is_night:
		select_first_weapon()
	_refresh_all_slots()

func _on_seed_merchant_phase_changed(_is_seed_merchant_phase: bool) -> void:
	_update_day_toggle_icon(GameState.is_night)
	_refresh_all_slots()

func _on_locale_changed(_locale: String) -> void:
	_refresh_toolbar_info()

func _update_day_toggle_icon(is_night: bool) -> void:
	# Icon reflects the current mode: sun during day, moon during night.
	if GameState.is_seed_merchant_phase:
		day_toggle.icon = _merchant_icon
	else:
		day_toggle.icon = _moon_icon if is_night else _sun_icon

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mouse_event: InputEventMouseButton = event
		if not inventory_modal.visible and mouse_event.pressed and not mouse_event.ctrl_pressed:
			if mouse_event.button_index == MOUSE_BUTTON_WHEEL_UP:
				step_selected_quick_slot(-1)
				get_viewport().set_input_as_handled()
			elif mouse_event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				step_selected_quick_slot(1)
				get_viewport().set_input_as_handled()
		return

	if not (event is InputEventKey):
		return

	var key_event: InputEventKey = event
	if not key_event.pressed or key_event.echo:
		return

	if key_event.keycode == KEY_ESCAPE and inventory_modal.visible:
		_hide_inventory()
		get_viewport().set_input_as_handled()
		return

	if key_event.keycode == KEY_I:
		_set_inventory_open(not inventory_modal.visible)
		if inventory_modal.visible:
			_refresh_all_slots()
		get_viewport().set_input_as_handled()
		return

	var slot_index := _quick_slot_index_from_event(key_event)
	if slot_index >= 0:
		select_quick_slot(slot_index)
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

func select_quick_slot(index: int) -> void:
	if index < 0 or index >= QUICK_SLOT_COUNT:
		return
	# If the chosen quick slot can't be selected (empty, or a non-weapon disabled
	# during the night), fall back to the nearest selectable slot. If none qualify
	# (shouldn't happen, "spray" is non-removable), leave the requested slot.
	if not _is_quick_slot_selectable(index):
		var fallback: int = _nearest_valid_quick_slot(index)
		if fallback >= 0:
			index = fallback
	selected_quick_index = index
	_refresh_all_slots()

# Re-selects the nearest selectable quick slot when the current selection is no
# longer valid (emptied by consuming its last item, or disabled at nightfall).
# Leaves the selection untouched if no quick slot is selectable.
func _ensure_valid_quick_selection() -> void:
	if _is_quick_slot_selectable(selected_quick_index):
		return
	var fallback: int = _nearest_valid_quick_slot(selected_quick_index)
	if fallback >= 0:
		selected_quick_index = fallback

# A quick slot can be selected when it holds an item that isn't currently disabled
# (non-weapon tools/placeables are disabled during the night).
func _is_quick_slot_selectable(index: int) -> bool:
	if index < 0 or index >= inventory_slots.size():
		return false
	var item_id: String = _slot_item_id(inventory_slots[index])
	return item_id != "" and not is_quick_item_disabled(item_id)

func _nearest_valid_quick_slot(index: int) -> int:
	var limit: int = mini(QUICK_SLOT_COUNT, inventory_slots.size())
	for distance: int in range(1, limit):
		var left: int = index - distance
		if left >= 0 and _is_quick_slot_selectable(left):
			return left
		var right: int = index + distance
		if right < limit and _is_quick_slot_selectable(right):
			return right
	return -1

func get_selected_quick_item_id() -> String:
	if selected_quick_index < 0 or selected_quick_index >= inventory_slots.size():
		return ""
	return _slot_item_id(inventory_slots[selected_quick_index])

func get_inventory_item_quantity(item_id: String) -> int:
	var total: int = 0
	for slot_data: Dictionary in inventory_slots:
		if _slot_item_id(slot_data) == item_id:
			total += _slot_quantity(slot_data)
	return total

func consume_inventory_item(item_id: String, quantity: int) -> bool:
	if item_id == "" or quantity <= 0 or get_inventory_item_quantity(item_id) < quantity:
		return false
	var remaining: int = quantity
	# Empty the selected stack first so bulk placement behaves consistently with
	# normal single-item placement, then continue through any other stacks.
	var slot_order: Array[int] = []
	if selected_quick_index >= 0 and selected_quick_index < inventory_slots.size():
		slot_order.append(selected_quick_index)
	for i: int in range(inventory_slots.size()):
		if i != selected_quick_index:
			slot_order.append(i)
	for slot_index: int in slot_order:
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
	_ensure_valid_quick_selection()
	_refresh_all_slots()
	return true

func consume_selected_quick_item(expected_item_id: String) -> bool:
	if selected_quick_index < 0 or selected_quick_index >= inventory_slots.size():
		return false
	var slot_data: Dictionary = inventory_slots[selected_quick_index]
	if _slot_item_id(slot_data) != expected_item_id:
		return false
	var quantity: int = _slot_quantity(slot_data)
	if quantity <= 0:
		return false
	quantity -= 1
	inventory_slots[selected_quick_index] = _make_slot(expected_item_id, quantity) if quantity > 0 else _empty_slot()
	_ensure_valid_quick_selection()
	_refresh_all_slots()
	return true

func get_selected_quick_item_def() -> Dictionary:
	return ItemCatalog.get_item_def(get_selected_quick_item_id())

func selected_quick_item_places_tile() -> bool:
	var item_id: String = get_selected_quick_item_id()
	return ItemCatalog.is_placeable(item_id) and not is_item_disabled_for_placement(item_id)

func is_item_disabled_for_placement(item_id: String) -> bool:
	if GameState.is_morning_phase and item_id == "rose_shop_counter":
		return false
	return (GameState.is_night or not GameState.is_building_phase) and ItemCatalog.is_placeable(item_id)

## Whether a quick-bar item is disabled for selection/use. At night every
## non-weapon (build/unbuild tools, placeables) is locked out so the player can
## only wield weapons; during the day nothing is locked. Generalizes to any new
## weapon (selectable at night) or non-weapon (locked at night) item.
func is_quick_item_disabled(item_id: String) -> bool:
	if GameState.is_morning_phase and item_id == BUILD_TOOL_ID:
		return false
	return item_id != "" and (GameState.is_night or not GameState.is_building_phase) and not ItemCatalog.is_weapon(item_id)

## Selects the first quick-slot weapon, used to auto-arm the player when night
## falls. No-op if the quick bar holds no weapon.
func select_first_weapon() -> void:
	for i: int in range(mini(QUICK_SLOT_COUNT, inventory_slots.size())):
		if ItemCatalog.is_weapon(_slot_item_id(inventory_slots[i])):
			select_quick_slot(i)
			return

# --- Build mode (shop-driven placement, paid directly from currency) ---------

func get_selected_build_item_id() -> String:
	return selected_build_item_id

func set_selected_build_item(item_id: String) -> void:
	selected_build_item_id = item_id

func clear_build_selection() -> void:
	selected_build_item_id = ""

func is_build_mode_active() -> bool:
	return selected_build_item_id != ""

func is_build_tool_selected() -> bool:
	return get_selected_quick_item_id() == BUILD_TOOL_ID

func is_unbuild_tool_selected() -> bool:
	return get_selected_quick_item_id() == UNBUILD_TOOL_ID

## Select the quick slot holding the build tool (opens the shop). No-op if the
## build tool is not in the quick bar.
func select_build_tool() -> void:
	for i: int in range(mini(QUICK_SLOT_COUNT, inventory_slots.size())):
		if _slot_item_id(inventory_slots[i]) == BUILD_TOOL_ID:
			select_quick_slot(i)
			return

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
	if item_id == "rose_shop_counter":
		return true
	var scene: Node = get_tree().current_scene
	var loader: Node = scene.get_node_or_null("LevelLoader") if scene != null else null
	if loader != null and loader.has_method("get_loaded_shop_available_items"):
		var raw_item_ids: Variant = loader.call("get_loaded_shop_available_items")
		if raw_item_ids is Array:
			for raw_item_id: Variant in raw_item_ids:
				if str(raw_item_id) == item_id:
					return true
			return false
	return item_id == "rose" or item_id == "turret1" or item_id == "wall" or item_id == "seed" or item_id == "spray" or item_id == "beam" or item_id == "sword" or item_id == "bomb"


func get_build_price(item_id: String) -> int:
	var scene: Node = get_tree().current_scene
	var loader: Node = scene.get_node_or_null("LevelLoader") if scene != null else null
	if loader != null and loader.has_method("get_loaded_shop_prices"):
		var raw_prices: Variant = loader.call("get_loaded_shop_prices")
		if raw_prices is Dictionary:
			var prices: Dictionary = raw_prices as Dictionary
			if prices.has(StringName(item_id)):
				return maxi(0, int(prices[StringName(item_id)]))
			if prices.has(item_id):
				return maxi(0, int(prices[item_id]))
	return ItemCatalog.get_price(item_id)


## How many of item_id the player can currently afford (floor(currency / price)).
func get_build_affordable_quantity(item_id: String) -> int:
	if not is_build_item_available(item_id):
		return 0
	var limit_remaining: int = _build_limit_remaining(item_id)
	var price: int = get_build_price(item_id)
	var key: StringName = _build_currency_prog_key(item_id)
	if price <= 0:
		return max(0, limit_remaining) if limit_remaining >= 0 else 0
	if key == &"" or _progression_node == null:
		return 0
	var owned: int = int(_progression_node.call("get_value", key))
	@warning_ignore("integer_division")
	var affordable: int = owned / price
	if limit_remaining >= 0:
		return mini(affordable, limit_remaining)
	return affordable

func can_afford_build(item_id: String, count: int = 1) -> bool:
	return count > 0 and get_build_affordable_quantity(item_id) >= count

## Spend the cost of `count` units of item_id. Returns false (spending nothing)
## when unaffordable, so callers can place only what was actually paid for.
func try_purchase_build(item_id: String, count: int) -> bool:
	if count <= 0:
		return false
	if not is_build_item_available(item_id):
		return false
	var price: int = get_build_price(item_id)
	var key: StringName = _build_currency_prog_key(item_id)
	if price <= 0:
		return true
	if key == &"" or _progression_node == null:
		return false
	return bool(_progression_node.call("spend", key, price * count))


func try_purchase_shop_inventory_item(item_id: String, count: int = 1) -> bool:
	if count <= 0 or not ItemCatalog.is_weapon(item_id):
		return false
	if not can_add_inventory(item_id, count):
		return false
	if not try_purchase_build(item_id, count):
		return false
	return add_inventory(item_id, count)


func try_purchase_seed_merchant_item(item_id: String, count: int = 1) -> bool:
	if item_id != "seed" or count <= 0:
		return false
	if _progression_node == null or not _progression_node.has_method("update_seeds"):
		return false
	if not try_purchase_build(item_id, count):
		return false
	return bool(_progression_node.call("update_seeds", count))


## Public: how many more of item_id may still be placed given its per-world build
## limit, or -1 when the item has no limit. Used by the shop to show "remaining : x".
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
	if manager != null and manager.has_method("count_buildings_by_item_id"):
		return int(manager.call("count_buildings_by_item_id", item_id))
	return 0

## Refund the full price of `count` removed units back to the matching currency,
## flying one currency icon per unit from `world_position` to the HUD and crediting
## on arrival — exactly like the seed/gem/money harvest. Falls back to an instant credit
## if the HUD icon is unavailable so a refund is never lost.
func refund_build(item_id: String, world_position: Vector2, count: int = 1) -> void:
	if count <= 0:
		return
	var price: int = get_build_price(item_id)
	var units: int = price * count
	if units <= 0:
		return
	var currency: StringName = ItemCatalog.get_currency(item_id)
	var icon: Node = null
	var animate_method: String = ""
	if currency == &"seed":
		icon = get_node_or_null("top right/seedIcon")
		animate_method = "animate_seed_harvest"
	elif currency == &"gem":
		icon = get_node_or_null("top right/gemIcon")
		animate_method = "animate_gem_harvest"
	elif currency == &"money":
		icon = get_node_or_null("top right/moneyIcon")
		animate_method = "animate_money_harvest"
	if icon != null and icon.has_method(animate_method):
		for i: int in range(units):
			icon.call(animate_method, world_position, i)
		return
	# Fallback: no HUD icon to animate, so credit immediately.
	var key: StringName = _build_currency_prog_key(item_id)
	if key != &"" and _progression_node != null:
		_progression_node.call("update_value", key, units)

func _setup_starting_inventory() -> void:
	inventory_slots.resize(INVENTORY_SLOT_COUNT)
	for i in range(INVENTORY_SLOT_COUNT):
		inventory_slots[i] = _empty_slot()
	for weapon_id: StringName in _get_level_starting_weapons():
		add_inventory(String(weapon_id), 1)
	add_inventory(BUILD_TOOL_ID, 1)


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

	while remaining > 0:
		var free_index: int = _first_free_slot()
		var new_stack_quantity: int = mini(remaining, max_stack)
		inventory_slots[free_index] = _make_slot(item_id, new_stack_quantity)
		remaining -= new_stack_quantity

	_refresh_all_slots()
	Sfx.play_sound(&"bag")
	return true

func can_add_inventory(item_id: String, quantity: int = 1) -> bool:
	if item_id == "" or quantity <= 0:
		return false
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

func _first_free_slot() -> int:
	for i in range(inventory_slots.size()):
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

	for i in range(QUICK_SLOT_COUNT):
		var slot: ItemSlot = ItemSlotScript.new()
		toolbar_slots.add_child(slot)
		slot.setup(self, "quick", i)
		_toolbar_slot_nodes.append(slot)

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
	_remove_unbuild_tool_from_inventory()
	for i in range(_toolbar_slot_nodes.size()):
		_apply_slot_item(_toolbar_slot_nodes[i], i)

	for i in range(_inventory_slot_nodes.size()):
		_apply_slot_item(_inventory_slot_nodes[i], i)

	_refresh_toolbar_info()

func _remove_unbuild_tool_from_inventory() -> void:
	var changed: bool = false
	for i: int in range(inventory_slots.size()):
		if _slot_item_id(inventory_slots[i]) == UNBUILD_TOOL_ID:
			inventory_slots[i] = _empty_slot()
			changed = true
	if changed:
		_ensure_valid_quick_selection()

func _refresh_toolbar_info() -> void:
	if toolbar_info == null:
		return
	var item_id: String = get_selected_quick_item_id()
	if item_id == "":
		toolbar_info.text = ""
		return
	toolbar_info.text = _get_item_display_name(item_id)

func _get_item_display_name(item_id: String) -> String:
	var key: String = ITEM_NAME_KEY_PREFIX + item_id
	var translated: String = Translations.t(key)
	if translated != key:
		return translated
	var item_def: Dictionary = ItemCatalog.get_item_def(item_id)
	return str(item_def.get("name", item_id))

func _apply_slot_item(slot: ItemSlot, slot_index: int) -> void:
	var slot_data: Dictionary = inventory_slots[slot_index]
	var item_id: String = _slot_item_id(slot_data)
	var quantity: int = _slot_quantity(slot_data)
	var item_def: Dictionary = ItemCatalog.get_item_def(item_id)
	if not item_def.is_empty():
		slot.set_item(item_def, quantity)
	else:
		slot.set_item({}, 0)
	slot.set_disabled(is_quick_item_disabled(item_id))
	slot.set_selected(slot_index == selected_quick_index)

func _clear_container(container: Container) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()

func step_selected_quick_slot(direction: int) -> void:
	if direction == 0:
		return
	# Walk in the scroll direction to the next selectable slot, skipping empty and
	# disabled (non-weapon at night) ones and wrapping around. Keeps the current
	# selection if no other slot can be selected.
	var next_index := selected_quick_index
	for _step: int in range(QUICK_SLOT_COUNT):
		next_index += direction
		if next_index < 0:
			next_index = QUICK_SLOT_COUNT - 1
		elif next_index >= QUICK_SLOT_COUNT:
			next_index = 0
		if _is_quick_slot_selectable(next_index):
			select_quick_slot(next_index)
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
