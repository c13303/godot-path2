extends Control

## The shop is the building picker for build mode. It is open exactly while the
## quick-bar Build tool is selected (see game_ui.is_build_tool_selected) and during
## the day; selecting any other quick slot closes it. It renders as a vertical column
## rising up out of the build/shop quick slot, like a dropdown that opens upward:
## one icon per buildable, stacked with no per-row text. A single floating label sits
## just to the right of the currently selected icon only, showing that buildable's name
## plus either its price (with the matching currency icon) or, for limited buildables,
## "remaining : n". The floating label has a transparent background and ignores all mouse
## events. Unaffordable / unavailable buildables are greyed out like disabled quick slots,
## and the floating label turns red when the selected buildable cannot be placed.
## Clicking a slot selects it so the build system places it when affordable; buildables are
## paid for directly from currency and never enter the inventory.

const COUNTER_ID: String = "rose_shop_counter"
const ITEMS_TEXTURE: Texture2D = preload("res://assets/sprites/legval/items.png")
const ITEM_FRAME_SIZE: Vector2 = Vector2(32.0, 32.0)
# Currency icon regions inside items.png (match the HUD seed/gem/money icons).
const SEED_ICON_REGION: Rect2 = Rect2(226.0, 0.0, 32.0, 32.0)
const GEM_ICON_REGION: Rect2 = Rect2(256.0, 0.0, 32.0, 32.0)
const MONEY_ICON_REGION: Rect2 = Rect2(416.0, 0.0, 32.0, 32.0)
const SLOT_SIZE: Vector2 = Vector2(56.0, 56.0)
# The column's bottom sits this many pixels above the screen bottom, clearing the quick
# bar and its "Construction (…)" info label; rows stack upward from there.
const BAR_BOTTOM_OFFSET: float = -134.0
# Left inset from the panel edge to the first slot (panel border + margin_left), so the
# column's slots can be centred on the build/shop icon.
const BAR_CONTENT_INSET: float = 10.0
# Y offset (from the top) of the seed-merchant column's top, placing it just below the
# tutorial hint text (GameUI/top anchor/tutorial spans roughly down to y ~240).
const SEED_MERCHANT_BAR_TOP: float = 250.0
const BUILD_ITEM_IDS: Array[String] = ["rose", "turret1", "wall", COUNTER_ID]
const SEED_ITEM_ID: String = "seed"
const WEAPON_ITEM_IDS: Array[String] = [SEED_ITEM_ID, "sword", "bomb", "spray", "beam"]
const ITEM_IDS: Array[String] = ["rose", "turret1", "wall", COUNTER_ID, SEED_ITEM_ID, "sword", "bomb", "spray", "beam"]
const SELECTED_LABEL_COLOR: Color = Color(0.92, 0.88, 0.78)
const SELECTED_DISABLED_LABEL_COLOR: Color = Color(0.85, 0.25, 0.25)

var progression_node: Node
var game_ui: Node
var _waiting_for_seed_harvest: bool = false
# The building currently picked for placement (drives build mode).
var _selected_item_id: String = ""
# The last building the player picked; restored when the shop reopens if it still exists.
var _last_picked_item_id: String = ""
# Affordable count of the selected buildable on the previous refresh. Used to detect the
# moment it runs dry through use (>0 -> 0) so we can auto-switch to the next buildable.
# Deliberately clicking an already-empty slot leaves this at 0, so no auto-switch fires.
var _selected_affordable_prev: int = -1

var _shop_column: VBoxContainer
# A plain BoxContainer (not VBox/HBox) so its `vertical` axis can be flipped at runtime:
# vertical stack for the build shop, horizontal bar for the seed-merchant sale.
var _items_list: BoxContainer
var _seed_icon: AtlasTexture
var _gem_icon: AtlasTexture
var _money_icon: AtlasTexture
# item id -> its row / slot Button / icon TextureRect / affordable-count Label.
var _slot_rows: Dictionary = {}
var _slot_buttons: Dictionary = {}
var _slot_icons: Dictionary = {}
var _slot_counts: Dictionary = {}
# item id -> its persistent per-row label group (name + price + currency icon) and its
# parts. Only shown during the seed/weapon merchant column; hidden in build phase, which
# uses the single floating label below instead.
var _row_labels: Dictionary = {}
var _row_names: Dictionary = {}
var _row_prices: Dictionary = {}
var _row_currencies: Dictionary = {}
# The single floating label shown to the right of the selected slot only.
var _selected_label: HBoxContainer
var _selected_name: Label
var _selected_price: Label
var _selected_currency: TextureRect
# item id -> last applied [selected, disabled] state, so styles are only rebuilt on
# change instead of every frame.
var _slot_state: Dictionary = {}


func _ready() -> void:
	var scene: Node = get_tree().current_scene
	progression_node = scene.get_node_or_null("progression") if scene != null else null
	game_ui = scene.get_node_or_null("GameUI") if scene != null else null

	# Root passes the mouse through so only the slot buttons capture clicks.
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_seed_icon = _region_texture(SEED_ICON_REGION)
	_gem_icon = _region_texture(GEM_ICON_REGION)
	_money_icon = _region_texture(MONEY_ICON_REGION)
	_build_ui()

	GameState.mode_changed.connect(_on_game_mode_changed)
	_waiting_for_seed_harvest = false
	if not GameState.building_phase_changed.is_connected(_on_building_phase_changed):
		GameState.building_phase_changed.connect(_on_building_phase_changed)
	if not GameState.morning_phase_changed.is_connected(_on_morning_phase_changed):
		GameState.morning_phase_changed.connect(_on_morning_phase_changed)
	if not GameState.client_phase_changed.is_connected(_on_client_phase_changed):
		GameState.client_phase_changed.connect(_on_client_phase_changed)
	if not GameState.seed_merchant_phase_changed.is_connected(_on_seed_merchant_phase_changed):
		GameState.seed_merchant_phase_changed.connect(_on_seed_merchant_phase_changed)
	_set_shop_open(false)
	set_process(true)


## Shop visibility is derived from the quick-bar selection: open only while the
## Build tool is the selected quick slot (and it is daytime, past the harvest).
func _process(_delta: float) -> void:
	var should_show: bool = (
		game_ui != null
		and game_ui.has_method("is_build_tool_selected")
		and bool(game_ui.call("is_build_tool_selected"))
		and not GameState.is_night
		and (GameState.is_building_phase or GameState.is_morning_phase)
		and not _waiting_for_seed_harvest
	)
	if GameState.is_seed_merchant_phase:
		should_show = _player_near_seed_merchant()
	if should_show and not visible:
		_open_shop()
	elif not should_show and visible:
		_close_shop()
	if visible:
		_refresh_slots()
		if GameState.is_seed_merchant_phase:
			_update_merchant_column_anchor()
		else:
			_update_build_column_anchor()


# --- UI construction ---------------------------------------------------------

func _build_ui() -> void:
	var column: VBoxContainer = VBoxContainer.new()
	_shop_column = column
	column.name = "ShopColumn"
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 6)
	column.alignment = BoxContainer.ALIGNMENT_END
	add_child(column)

	column.add_child(_build_bar())
	_build_selected_label()
	_apply_phase_layout()


## Builds the single floating label (name + price + currency icon) that sits to the
## right of the selected slot. It has no background and ignores all mouse events.
func _build_selected_label() -> void:
	var group: HBoxContainer = HBoxContainer.new()
	_selected_label = group
	group.name = "SelectedItemLabel"
	group.mouse_filter = Control.MOUSE_FILTER_IGNORE
	group.add_theme_constant_override("separation", 8)
	add_child(group)

	var name_label: Label = _make_row_label(18)
	name_label.add_theme_color_override("font_color", SELECTED_LABEL_COLOR)
	group.add_child(name_label)
	_selected_name = name_label

	var price_label: Label = _make_row_label(18)
	price_label.add_theme_color_override("font_color", Color.WHITE)
	group.add_child(price_label)
	_selected_price = price_label

	var currency: TextureRect = TextureRect.new()
	currency.mouse_filter = Control.MOUSE_FILTER_IGNORE
	currency.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	currency.custom_minimum_size = Vector2(20.0, 20.0)
	currency.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	currency.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	currency.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	group.add_child(currency)
	_selected_currency = currency

	group.visible = false


func _build_bar() -> Control:
	var panel: PanelContainer = PanelContainer.new()
	panel.name = "BarPanel"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	panel.add_theme_stylebox_override("panel", _bar_background_style())

	var margin: MarginContainer = MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_bottom", 6)
	panel.add_child(margin)

	var items_list: BoxContainer = BoxContainer.new()
	_items_list = items_list
	items_list.name = "ItemsList"
	items_list.vertical = true
	items_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	items_list.add_theme_constant_override("separation", 6)
	margin.add_child(items_list)

	for item_id: String in ITEM_IDS:
		items_list.add_child(_build_slot_row(item_id))
	return panel


## One row of the column: the slot button plus a persistent name / price / currency-icon
## label group. In build phase the label group is hidden and the shared floating label
## next to the selected slot is used instead (see _build_selected_label); in the seed/weapon
## merchant column the per-row label group is shown for every item.
func _build_slot_row(item_id: String) -> HBoxContainer:
	var row: HBoxContainer = HBoxContainer.new()
	row.name = item_id + "Row"
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.alignment = BoxContainer.ALIGNMENT_BEGIN
	row.add_theme_constant_override("separation", 8)
	row.add_child(_build_slot(item_id))
	row.add_child(_build_row_label(item_id))
	_slot_rows[item_id] = row
	return row


## Builds the persistent per-row label group (name + price + currency icon) shown beside the
## slot in the seed/weapon merchant column. Hidden by default; _refresh_slots reveals and
## fills it during the merchant phase.
func _build_row_label(item_id: String) -> HBoxContainer:
	var group: HBoxContainer = HBoxContainer.new()
	group.name = item_id + "Label"
	group.mouse_filter = Control.MOUSE_FILTER_IGNORE
	group.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	group.add_theme_constant_override("separation", 8)

	var name_label: Label = _make_row_label(18)
	name_label.add_theme_color_override("font_color", SELECTED_LABEL_COLOR)
	group.add_child(name_label)

	var price_label: Label = _make_row_label(18)
	price_label.add_theme_color_override("font_color", Color.WHITE)
	group.add_child(price_label)

	var currency: TextureRect = TextureRect.new()
	currency.mouse_filter = Control.MOUSE_FILTER_IGNORE
	currency.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	currency.custom_minimum_size = Vector2(20.0, 20.0)
	currency.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	currency.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	currency.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	group.add_child(currency)

	group.visible = false
	_row_labels[item_id] = group
	_row_names[item_id] = name_label
	_row_prices[item_id] = price_label
	_row_currencies[item_id] = currency
	return group


func _make_row_label(font_size: int) -> Label:
	var label: Label = Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	return label


func _build_slot(item_id: String) -> Button:
	var item_def: Dictionary = ItemCatalog.get_item_def(item_id)
	var button: Button = Button.new()
	button.name = item_id
	button.custom_minimum_size = SLOT_SIZE
	button.tooltip_text = _display_name(item_id)
	# Mouse-only: keyboard/gamepad focus would let the GUI layer swallow game input.
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(_on_item_pressed.bind(item_id))

	var icon: TextureRect = TextureRect.new()
	icon.texture = _item_frame_texture(item_def)
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon.offset_left = 8.0
	icon.offset_top = 8.0
	icon.offset_right = -8.0
	icon.offset_bottom = -8.0
	button.add_child(icon)

	var count: Label = Label.new()
	count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	count.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	count.add_theme_font_size_override("font_size", 14)
	count.add_theme_color_override("font_color", Color.WHITE)
	count.add_theme_color_override("font_shadow_color", Color.BLACK)
	count.add_theme_constant_override("shadow_offset_x", 1)
	count.add_theme_constant_override("shadow_offset_y", 1)
	count.set_anchors_preset(Control.PRESET_FULL_RECT)
	count.offset_left = 2.0
	count.offset_top = 2.0
	count.offset_right = -4.0
	count.offset_bottom = -2.0
	button.add_child(count)

	_slot_buttons[item_id] = button
	_slot_icons[item_id] = icon
	_slot_counts[item_id] = count
	return button


# --- Open / close ------------------------------------------------------------

func _open_shop() -> void:
	_apply_phase_layout()
	_set_shop_open(true)
	_refresh_slots()
	if GameState.is_seed_merchant_phase:
		_deselect_active()
		return
	# During the morning sale only the counter can be picked; leave it at that.
	if GameState.is_morning_phase:
		if _is_item_available(COUNTER_ID):
			_select_item(COUNTER_ID)
		else:
			_deselect_active()
		return
	# Resume placing the building we were last on, even if it is currently too
	# expensive; the selected row makes that unaffordable state explicit.
	if _last_picked_item_id != "" and _is_item_available(_last_picked_item_id) and not _is_item_locked(_last_picked_item_id):
		_select_item(_last_picked_item_id)
		return
	for item_id: String in ITEM_IDS:
		if item_id != COUNTER_ID and _is_item_available(item_id) and not _is_item_locked(item_id):
			_select_item(item_id)
			return
	_deselect_active()


func _close_shop() -> void:
	_set_shop_open(false)
	_deselect_active()


func _set_shop_open(is_open: bool) -> void:
	visible = is_open


# --- Phase handling ----------------------------------------------------------

## At night and during morning sale the shop is closed. Once building phase starts,
## the build tool is auto-selected to reopen it.
func _on_game_mode_changed(is_night: bool) -> void:
	_waiting_for_seed_harvest = not is_night


func _on_building_phase_changed(is_building_phase: bool) -> void:
	_waiting_for_seed_harvest = not is_building_phase
	if is_building_phase and not GameState.is_night and game_ui != null and game_ui.has_method("select_build_tool"):
		game_ui.call("select_build_tool")


func _on_morning_phase_changed(is_morning_phase: bool) -> void:
	if is_morning_phase:
		_waiting_for_seed_harvest = false


func _on_client_phase_changed(is_client_phase: bool) -> void:
	if is_client_phase:
		_waiting_for_seed_harvest = true


func _on_seed_merchant_phase_changed(is_seed_merchant_phase: bool) -> void:
	_waiting_for_seed_harvest = is_seed_merchant_phase
	_apply_phase_layout()
	if not is_seed_merchant_phase:
		_close_shop()


# --- Selection ---------------------------------------------------------------

func _on_item_pressed(item_id: String) -> void:
	if not visible or GameState.is_night:
		return
	if GameState.is_seed_merchant_phase:
		if not _is_merchant_item(item_id) or not _is_item_available(item_id):
			return
		var purchased: bool = false
		if item_id == SEED_ITEM_ID and game_ui != null and game_ui.has_method("try_purchase_seed_merchant_item"):
			purchased = bool(game_ui.call("try_purchase_seed_merchant_item", item_id, 1))
		elif ItemCatalog.is_weapon(item_id) and game_ui != null and game_ui.has_method("try_purchase_shop_inventory_item"):
			purchased = bool(game_ui.call("try_purchase_shop_inventory_item", item_id, 1))
		if purchased:
			GameState.seed_merchant_purchase_made = true
			Sfx.play_sound(&"buy")
			_refresh_slots()
		return
	if _is_item_locked(item_id) or not _is_item_available(item_id):
		return
	# Clicking the already-selected item toggles it back off and forgets it.
	if _selected_item_id == item_id:
		_deselect_active()
		_last_picked_item_id = ""
		return
	_select_item(item_id)


func _select_item(item_id: String) -> void:
	_selected_item_id = item_id
	_last_picked_item_id = item_id
	# Seed the run-dry tracker with the new pick's current count, so the recursive
	# refresh below (and a deliberately-empty pick) never mis-fires an auto-switch.
	_selected_affordable_prev = _affordable_quantity(item_id)
	if game_ui != null and game_ui.has_method("set_selected_build_item"):
		game_ui.call("set_selected_build_item", item_id)
	Sfx.play_sound(&"buy")
	_refresh_slots()


## Clears the active build pick (build mode) but remembers it for the next time the
## shop opens.
func _deselect_active() -> void:
	_selected_item_id = ""
	if game_ui != null and game_ui.has_method("clear_build_selection"):
		game_ui.call("clear_build_selection")
	_refresh_slots()


func _can_afford(item_id: String) -> bool:
	return game_ui != null and game_ui.has_method("can_afford_build") and bool(game_ui.call("can_afford_build", item_id, 1))


func _affordable_quantity(item_id: String) -> int:
	if game_ui != null and game_ui.has_method("get_build_affordable_quantity"):
		return int(game_ui.call("get_build_affordable_quantity", item_id))
	return 0


## During the morning sale only the counter may be placed; everything else is locked.
func _is_item_locked(item_id: String) -> bool:
	if GameState.is_seed_merchant_phase:
		return not _is_merchant_item(item_id)
	return GameState.is_morning_phase and item_id != COUNTER_ID


func _is_item_available(item_id: String) -> bool:
	return game_ui == null or not game_ui.has_method("is_build_item_available") or bool(game_ui.call("is_build_item_available", item_id))


# --- Per-frame refresh -------------------------------------------------------

func _refresh_slots() -> void:
	for item_id: String in ITEM_IDS:
		var row: Control = _slot_rows.get(item_id) as Control
		if row == null:
			continue
		row.visible = _should_show_item(item_id)
		if not row.visible:
			continue
		var button: Button = _slot_buttons[item_id] as Button
		var affordable: int = _affordable_quantity(item_id)
		var disabled: bool = affordable <= 0 or _is_item_locked(item_id)
		var selected: bool = item_id == _selected_item_id
		var count_label: Label = _slot_counts[item_id] as Label
		count_label.text = str(affordable)
		# The merchant column signals unaffordability through the per-row label colour, so its
		# slots stay at full colour; the build column greys unaffordable/locked slots.
		var visual_disabled: bool = disabled and not GameState.is_seed_merchant_phase
		var state: Array[bool] = [selected, visual_disabled]
		if _slot_state.get(item_id) != state:
			_slot_state[item_id] = state
			_apply_slot_style(button, selected, visual_disabled)
			(_slot_icons[item_id] as TextureRect).modulate = (
				Color(0.45, 0.45, 0.45, 0.55) if visual_disabled else Color.WHITE
			)
	_update_selected_label()
	_update_row_labels()
	_maybe_auto_switch_from_empty()


## When the selected buildable runs dry through use (its affordable/limit count drops from
## >0 to 0), hop to the next available buildable in the vertical bar. Does nothing when the
## player deliberately selected an already-empty slot (the count never transitioned from >0),
## and stays put when no other buildable is available.
func _maybe_auto_switch_from_empty() -> void:
	if GameState.is_seed_merchant_phase:
		return
	if _selected_item_id == "":
		_selected_affordable_prev = -1
		return
	var current: int = _affordable_quantity(_selected_item_id)
	if _selected_affordable_prev > 0 and current <= 0 and not _is_item_locked(_selected_item_id):
		var next_id: String = _next_available_buildable(_selected_item_id)
		if next_id != "":
			_select_item(next_id)
			return
	_selected_affordable_prev = current


## The next buildable after `from_id` in the vertical bar (wrapping) that is shown, unlocked
## and affordable, or "" if none. Skips the shop counter, mirroring _open_shop's auto-select.
func _next_available_buildable(from_id: String) -> String:
	var n: int = BUILD_ITEM_IDS.size()
	var start: int = BUILD_ITEM_IDS.find(from_id)
	for offset: int in range(1, n + 1):
		var idx: int = ((start if start >= 0 else -1) + offset) % n
		var candidate: String = BUILD_ITEM_IDS[idx]
		if candidate == from_id or candidate == COUNTER_ID:
			continue
		if _should_show_item(candidate) and not _is_item_locked(candidate) and _affordable_quantity(candidate) > 0:
			return candidate
	return ""


## Fills in and positions the floating label for the selected slot only. It shows the
## buildable's name, price and currency icon, turning red when it cannot be placed.
## During the merchant phase (no build pick) the label stays hidden — icons only.
func _update_selected_label() -> void:
	if _selected_label == null:
		return
	var item_id: String = _selected_item_id
	if GameState.is_seed_merchant_phase or item_id == "" or not _slot_buttons.has(item_id):
		_selected_label.visible = false
		return
	var button: Button = _slot_buttons[item_id] as Button
	if not button.visible:
		_selected_label.visible = false
		return
	_selected_label.visible = true
	var can_place: bool = _can_afford(item_id) and not _is_item_locked(item_id)
	var color: Color = SELECTED_LABEL_COLOR if can_place else SELECTED_DISABLED_LABEL_COLOR
	_selected_name.add_theme_color_override("font_color", color)
	_selected_price.add_theme_color_override("font_color", color)
	_selected_currency.modulate = color
	_selected_name.text = _display_name(item_id)
	var remaining: int = _limit_remaining(item_id)
	if remaining >= 0:
		_selected_price.text = "%s : %d" % [Translations.t("ui.remaining"), remaining]
		_selected_currency.visible = false
	else:
		_selected_price.text = str(_build_price(item_id))
		var currency_texture: AtlasTexture = _currency_texture(item_id)
		_selected_currency.texture = currency_texture
		_selected_currency.visible = currency_texture != null
	_position_selected_label(button)


## Maps an item's catalog currency to its HUD icon texture, or null if it has none.
func _currency_texture(item_id: String) -> AtlasTexture:
	match ItemCatalog.get_currency(item_id):
		&"gem":
			return _gem_icon
		&"seed":
			return _seed_icon
		&"money":
			return _money_icon
	return null


## Fills and colours the persistent per-row label groups for the seed/weapon merchant column
## (name + price + currency icon), reddening items the player cannot currently afford. In build
## phase every row label stays hidden (the floating selected label is used instead).
func _update_row_labels() -> void:
	var show_rows: bool = GameState.is_seed_merchant_phase
	for item_id: String in ITEM_IDS:
		var group: HBoxContainer = _row_labels.get(item_id) as HBoxContainer
		if group == null:
			continue
		var row: Control = _slot_rows.get(item_id) as Control
		var row_visible: bool = show_rows and row != null and row.visible
		group.visible = row_visible
		if not row_visible:
			continue
		var can_buy: bool = _can_afford(item_id) and not _is_item_locked(item_id)
		var color: Color = SELECTED_LABEL_COLOR if can_buy else SELECTED_DISABLED_LABEL_COLOR
		var name_label: Label = _row_names[item_id] as Label
		var price_label: Label = _row_prices[item_id] as Label
		var currency: TextureRect = _row_currencies[item_id] as TextureRect
		name_label.add_theme_color_override("font_color", color)
		price_label.add_theme_color_override("font_color", color)
		currency.modulate = color
		name_label.text = _display_name(item_id)
		price_label.text = str(_build_price(item_id))
		var currency_texture: AtlasTexture = _currency_texture(item_id)
		currency.texture = currency_texture
		currency.visible = currency_texture != null


## Places the floating label just to the right of the selected slot, vertically centred.
func _position_selected_label(button: Control) -> void:
	const GAP: float = 12.0
	var pos_x: float = button.global_position.x + button.size.x + GAP
	var pos_y: float = button.global_position.y + (button.size.y - _selected_label.size.y) * 0.5
	_selected_label.global_position = Vector2(pos_x, pos_y)


func _limit_remaining(item_id: String) -> int:
	if game_ui != null and game_ui.has_method("get_build_limit_remaining"):
		return int(game_ui.call("get_build_limit_remaining", item_id))
	return -1


func _build_price(item_id: String) -> int:
	if game_ui != null and game_ui.has_method("get_build_price"):
		return int(game_ui.call("get_build_price", item_id))
	return ItemCatalog.get_price(item_id)


func _should_show_item(item_id: String) -> bool:
	if GameState.is_seed_merchant_phase:
		return item_id in WEAPON_ITEM_IDS and _is_merchant_item(item_id) and _is_item_available(item_id)
	return item_id in BUILD_ITEM_IDS and _is_item_available(item_id)


func _is_merchant_item(item_id: String) -> bool:
	return item_id == SEED_ITEM_ID or ItemCatalog.is_weapon(item_id)


func _player_near_seed_merchant() -> bool:
	var scene: Node = get_tree().current_scene
	var manager: Node = scene.get_node_or_null("Map/BuildingManager") if scene != null else null
	return manager != null and manager.has_method("is_player_near_seed_merchant") and bool(manager.call("is_player_near_seed_merchant"))


func _apply_phase_layout() -> void:
	if _shop_column == null:
		return
	if GameState.is_seed_merchant_phase:
		# Vertical column sitting just under the tutorial hint text (see GameUI/top
		# anchor/tutorial) and left-aligned to the leftmost quick slot; each row carries
		# its own name/price/currency label (see _update_row_labels). Grows down and right.
		if _items_list != null:
			_items_list.vertical = true
		_shop_column.anchor_left = 0.0
		_shop_column.anchor_right = 0.0
		_shop_column.anchor_top = 0.0
		_shop_column.anchor_bottom = 0.0
		_shop_column.grow_horizontal = Control.GROW_DIRECTION_END
		_shop_column.grow_vertical = Control.GROW_DIRECTION_END
		_shop_column.offset_top = SEED_MERCHANT_BAR_TOP
		_shop_column.offset_bottom = SEED_MERCHANT_BAR_TOP
		_shop_column.alignment = BoxContainer.ALIGNMENT_BEGIN
		_update_merchant_column_anchor()
		return
	# Build phase: vertical column pinned to the bottom, rising up out of the build/shop
	# quick slot; grows rightward so the name/price labels extend past the slots.
	if _items_list != null:
		_items_list.vertical = true
	_shop_column.anchor_left = 0.0
	_shop_column.anchor_right = 0.0
	_shop_column.anchor_top = 1.0
	_shop_column.anchor_bottom = 1.0
	_shop_column.grow_horizontal = Control.GROW_DIRECTION_END
	_shop_column.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_shop_column.offset_top = BAR_BOTTOM_OFFSET
	_shop_column.offset_bottom = BAR_BOTTOM_OFFSET
	_shop_column.alignment = BoxContainer.ALIGNMENT_END
	_update_build_column_anchor()


## Aligns the merchant column's slots to the left edge of the leftmost quick slot, so the
## column sits flush with the start of the quick bar.
func _update_merchant_column_anchor() -> void:
	if _shop_column == null or game_ui == null or not game_ui.has_method("get_quick_bar_left_x"):
		return
	var left_x: float = float(game_ui.call("get_quick_bar_left_x"))
	if left_x < 0.0:
		return
	var left: float = left_x - BAR_CONTENT_INSET
	_shop_column.offset_left = left
	_shop_column.offset_right = left


## Aligns the build-phase column's slots horizontally over the build/shop quick slot.
func _update_build_column_anchor() -> void:
	if _shop_column == null or game_ui == null or not game_ui.has_method("get_build_tool_slot_center_x"):
		return
	var center_x: float = float(game_ui.call("get_build_tool_slot_center_x"))
	if center_x < 0.0:
		return
	var left: float = center_x - SLOT_SIZE.x * 0.5 - BAR_CONTENT_INSET
	_shop_column.offset_left = left
	_shop_column.offset_right = left


# --- Styling / textures ------------------------------------------------------

func _apply_slot_style(button: Button, selected: bool, disabled: bool) -> void:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(0.10, 0.11, 0.12, 0.92)
	style.set_border_width_all(2)
	style.border_color = Color(0.30, 0.33, 0.35)
	style.set_corner_radius_all(4)
	if selected:
		style.bg_color = Color(0.16, 0.18, 0.18, 0.96)
		style.set_border_width_all(4)
		style.border_color = Color(0.92, 0.78, 0.34)
	if disabled:
		style.bg_color = Color(0.055, 0.06, 0.065, 0.88)
		style.border_color = Color(0.15, 0.16, 0.17, 0.9)
		if selected:
			style.set_border_width_all(4)
			style.border_color = SELECTED_DISABLED_LABEL_COLOR
	for state_name: String in ["normal", "hover", "pressed", "focus", "disabled"]:
		button.add_theme_stylebox_override(state_name, style)


func _bar_background_style() -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(0.055, 0.058, 0.06, 0.86)
	style.set_border_width_all(2)
	style.border_color = Color(0.22, 0.24, 0.25)
	style.set_corner_radius_all(6)
	return style


func _display_name(item_id: String) -> String:
	var key: String = "item." + item_id
	var translated: String = Translations.t(key)
	if translated != key:
		return translated
	return str(ItemCatalog.get_item_def(item_id).get("name", item_id))


func _item_frame_texture(item_def: Dictionary) -> AtlasTexture:
	if str(item_def.get("id", "")) == SEED_ITEM_ID:
		return _seed_icon
	var frame: int = int(item_def.get("frame", 0))
	return _region_texture(Rect2(Vector2(float(frame) * ITEM_FRAME_SIZE.x, 0.0), ITEM_FRAME_SIZE))


func _region_texture(region: Rect2) -> AtlasTexture:
	var atlas_texture: AtlasTexture = AtlasTexture.new()
	atlas_texture.atlas = ITEMS_TEXTURE
	atlas_texture.region = region
	return atlas_texture
