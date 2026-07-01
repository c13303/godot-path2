extends Control

## The shop is the building picker for build mode. It is open exactly while the
## quick-bar Build tool is selected (see game_ui.is_build_tool_selected) and during
## the day; selecting any other quick slot closes it. It renders as a horizontal bar
## sitting just above the quick-bar's "Construction (…)" label, styled like the quick
## bar: one slot per building showing its icon and the quantity the player can still
## afford. Unaffordable / unavailable buildings are greyed out like disabled quick
## slots. Above the bar a label shows the selected building's name and either its
## price (with the matching currency icon) or, for limited buildings, "remaining : n".
## Clicking an affordable slot selects it so the build system places it; buildings are
## paid for directly from currency and never enter the inventory.

const COUNTER_ID: String = "rose_shop_counter"
const ITEMS_TEXTURE: Texture2D = preload("res://assets/sprites/legval/items.png")
const ITEM_FRAME_SIZE: Vector2 = Vector2(32.0, 32.0)
# Currency icon regions inside items.png (match the HUD seed/gem/money icons).
const SEED_ICON_REGION: Rect2 = Rect2(226.0, 0.0, 32.0, 32.0)
const GEM_ICON_REGION: Rect2 = Rect2(256.0, 0.0, 32.0, 32.0)
const MONEY_ICON_REGION: Rect2 = Rect2(416.0, 0.0, 32.0, 32.0)
const SLOT_SIZE: Vector2 = Vector2(56.0, 56.0)
# The bar sits this many pixels above the screen bottom, clearing the quick bar and
# its "Construction (…)" info label.
const BAR_BOTTOM_OFFSET: float = -134.0
# Building buttons shown in the bar, left to right.
const ITEM_IDS: Array[String] = ["rose", "turret1", "wall", "spray", "beam", "sword", "bomb", COUNTER_ID]

var progression_node: Node
var game_ui: Node
var _waiting_for_seed_harvest: bool = false
# The building currently picked for placement (drives build mode).
var _selected_item_id: String = ""
# The last building the player picked; restored when the shop reopens (if affordable).
var _last_picked_item_id: String = ""
# Until this time (seconds) the selected label shows a red "no <currency>" warning.
var _insufficient_until: float = 0.0
var _insufficient_currency: StringName = &""

var _selected_name: Label
var _selected_price: Label
var _selected_currency: TextureRect
var _seed_icon: AtlasTexture
var _gem_icon: AtlasTexture
var _money_icon: AtlasTexture
# item id -> its slot Button / icon TextureRect / affordable-count Label.
var _slot_buttons: Dictionary = {}
var _slot_icons: Dictionary = {}
var _slot_counts: Dictionary = {}
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
	if should_show and not visible:
		_open_shop()
	elif not should_show and visible:
		_close_shop()
	if visible:
		_refresh_slots()
		_update_selected_label()


# --- UI construction ---------------------------------------------------------

func _build_ui() -> void:
	var column: VBoxContainer = VBoxContainer.new()
	column.name = "ShopColumn"
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 6)
	column.alignment = BoxContainer.ALIGNMENT_END
	# Full-width strip pinned to the bottom, growing upward so the bar hugs the quick
	# bar; its rows shrink-centre to stay horizontally centred on screen.
	column.anchor_left = 0.0
	column.anchor_right = 1.0
	column.anchor_top = 1.0
	column.anchor_bottom = 1.0
	column.grow_vertical = Control.GROW_DIRECTION_BEGIN
	column.offset_left = 0.0
	column.offset_right = 0.0
	column.offset_bottom = BAR_BOTTOM_OFFSET
	add_child(column)

	column.add_child(_build_selected_row())
	column.add_child(_build_bar())


func _build_selected_row() -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.name = "SelectedRow"
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 6)

	_selected_name = Label.new()
	_selected_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_selected_name.add_theme_font_size_override("font_size", 20)
	_selected_name.add_theme_color_override("font_color", Color(0.92, 0.88, 0.78))
	_selected_name.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_selected_name.add_theme_constant_override("shadow_offset_x", 1)
	_selected_name.add_theme_constant_override("shadow_offset_y", 1)
	row.add_child(_selected_name)

	_selected_price = Label.new()
	_selected_price.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_selected_price.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_selected_price.add_theme_font_size_override("font_size", 20)
	_selected_price.add_theme_color_override("font_color", Color.WHITE)
	_selected_price.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_selected_price.add_theme_constant_override("shadow_offset_x", 1)
	_selected_price.add_theme_constant_override("shadow_offset_y", 1)
	row.add_child(_selected_price)

	_selected_currency = TextureRect.new()
	_selected_currency.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_selected_currency.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_selected_currency.custom_minimum_size = Vector2(20.0, 20.0)
	_selected_currency.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_selected_currency.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_selected_currency.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_selected_currency)
	return row


func _build_bar() -> Control:
	var panel: PanelContainer = PanelContainer.new()
	panel.name = "BarPanel"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	panel.add_theme_stylebox_override("panel", _bar_background_style())

	var margin: MarginContainer = MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_bottom", 6)
	panel.add_child(margin)

	var items_row: HBoxContainer = HBoxContainer.new()
	items_row.name = "ItemsRow"
	items_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	items_row.add_theme_constant_override("separation", 6)
	margin.add_child(items_row)

	for item_id: String in ITEM_IDS:
		items_row.add_child(_build_slot(item_id))
	return panel


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
	_set_shop_open(true)
	_refresh_slots()
	# During the morning sale only the counter can be picked; leave it at that.
	if GameState.is_morning_phase:
		if _can_afford(COUNTER_ID):
			_select_item(COUNTER_ID)
		else:
			_deselect_active()
		return
	# Resume placing the building we were last on, if we can still afford it.
	if _last_picked_item_id != "" and _can_afford(_last_picked_item_id):
		_select_item(_last_picked_item_id)
		return
	for item_id: String in ITEM_IDS:
		if item_id != COUNTER_ID and not ItemCatalog.is_weapon(item_id) and _is_item_available(item_id) and _can_afford(item_id):
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


# --- Selection ---------------------------------------------------------------

func _on_item_pressed(item_id: String) -> void:
	if not visible or GameState.is_night:
		return
	if _is_item_locked(item_id) or not _is_item_available(item_id):
		return
	# Clicking the already-selected item toggles it back off and forgets it.
	if _selected_item_id == item_id:
		_deselect_active()
		_last_picked_item_id = ""
		return
	# Build placement is only armed when the player can afford at least one.
	if not _can_afford(item_id):
		_show_insufficient_currency(ItemCatalog.get_currency(item_id))
		return
	if ItemCatalog.is_weapon(item_id):
		_purchase_weapon(item_id)
		return
	_select_item(item_id)


func _select_item(item_id: String) -> void:
	_selected_item_id = item_id
	_last_picked_item_id = item_id
	_insufficient_until = 0.0
	if game_ui != null and game_ui.has_method("set_selected_build_item"):
		game_ui.call("set_selected_build_item", item_id)
	Sfx.play_sound(&"buy")
	_refresh_slots()
	_update_selected_label()


## Clears the active build pick (build mode) but remembers it for the next time the
## shop opens.
func _deselect_active() -> void:
	_selected_item_id = ""
	if game_ui != null and game_ui.has_method("clear_build_selection"):
		game_ui.call("clear_build_selection")
	_refresh_slots()
	_update_selected_label()


func _can_afford(item_id: String) -> bool:
	return game_ui != null and game_ui.has_method("can_afford_build") and bool(game_ui.call("can_afford_build", item_id, 1))


func _purchase_weapon(item_id: String) -> void:
	if game_ui == null or not game_ui.has_method("try_purchase_shop_inventory_item"):
		return
	var purchased: bool = bool(game_ui.call("try_purchase_shop_inventory_item", item_id, 1))
	if not purchased:
		return
	_insufficient_until = 0.0
	_refresh_slots()
	_update_selected_label()


func _affordable_quantity(item_id: String) -> int:
	if game_ui != null and game_ui.has_method("get_build_affordable_quantity"):
		return int(game_ui.call("get_build_affordable_quantity", item_id))
	return 0


## During the morning sale only the counter may be placed; everything else is locked.
func _is_item_locked(item_id: String) -> bool:
	return GameState.is_morning_phase and item_id != COUNTER_ID


func _is_item_available(item_id: String) -> bool:
	return game_ui == null or not game_ui.has_method("is_build_item_available") or bool(game_ui.call("is_build_item_available", item_id))


func _show_insufficient_currency(currency: StringName) -> void:
	_insufficient_currency = currency
	_insufficient_until = Time.get_ticks_msec() / 1000.0 + 1.2


# --- Per-frame refresh -------------------------------------------------------

func _refresh_slots() -> void:
	for item_id: String in ITEM_IDS:
		var button: Button = _slot_buttons.get(item_id)
		if button == null:
			continue
		button.visible = _is_item_available(item_id)
		if not button.visible:
			continue
		var affordable: int = _affordable_quantity(item_id)
		var disabled: bool = affordable <= 0 or _is_item_locked(item_id)
		var selected: bool = item_id == _selected_item_id
		var count_label: Label = _slot_counts[item_id]
		count_label.text = str(affordable)
		var state: Array = [selected, disabled]
		if _slot_state.get(item_id) != state:
			_slot_state[item_id] = state
			_apply_slot_style(button, selected, disabled)
			(_slot_icons[item_id] as TextureRect).modulate = (
				Color(0.45, 0.45, 0.45, 0.55) if disabled else Color.WHITE
			)


func _update_selected_label() -> void:
	if _selected_name == null:
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	if now < _insufficient_until:
		_selected_name.text = "no %s" % String(_insufficient_currency)
		_selected_name.add_theme_color_override("font_color", Color(0.85, 0.25, 0.25))
		_selected_price.text = ""
		_selected_currency.visible = false
		return
	_selected_name.remove_theme_color_override("font_color")
	_selected_name.add_theme_color_override("font_color", Color(0.92, 0.88, 0.78))
	if _selected_item_id == "":
		_selected_name.text = ""
		_selected_price.text = ""
		_selected_currency.visible = false
		return
	_selected_name.text = _display_name(_selected_item_id)
	var remaining: int = _limit_remaining(_selected_item_id)
	if remaining >= 0:
		_selected_price.text = "%s : %d" % [Translations.t("ui.remaining"), remaining]
		_selected_currency.visible = false
		return
	_selected_price.text = str(_build_price(_selected_item_id))
	var currency: StringName = ItemCatalog.get_currency(_selected_item_id)
	if currency == &"gem":
		_selected_currency.texture = _gem_icon
		_selected_currency.visible = true
	elif currency == &"seed":
		_selected_currency.texture = _seed_icon
		_selected_currency.visible = true
	elif currency == &"money":
		_selected_currency.texture = _money_icon
		_selected_currency.visible = true
	else:
		_selected_currency.visible = false


func _limit_remaining(item_id: String) -> int:
	if game_ui != null and game_ui.has_method("get_build_limit_remaining"):
		return int(game_ui.call("get_build_limit_remaining", item_id))
	return -1


func _build_price(item_id: String) -> int:
	if game_ui != null and game_ui.has_method("get_build_price"):
		return int(game_ui.call("get_build_price", item_id))
	return ItemCatalog.get_price(item_id)


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
	var frame: int = int(item_def.get("frame", 0))
	return _region_texture(Rect2(Vector2(float(frame) * ITEM_FRAME_SIZE.x, 0.0), ITEM_FRAME_SIZE))


func _region_texture(region: Rect2) -> AtlasTexture:
	var atlas_texture: AtlasTexture = AtlasTexture.new()
	atlas_texture.atlas = ITEMS_TEXTURE
	atlas_texture.region = region
	return atlas_texture
