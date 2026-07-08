extends Control

## The build picker is the building picker for build mode. It is open exactly while a build
## tool (gardening or hammer) is the selected quick slot (see game_ui.get_selected_build_tool_id)
## and during the day; selecting any other quick slot closes it. The active tool decides which
## buildables it lists: gardening offers rose/ronce/pasteque/turrets, hammer offers
## counter/wall/fence. The seed merchant column still takes over while the player is near the
## merchant without a build tool selected.
## It renders as a vertical column
## rising up out of the active tool's quick slot, like a dropdown that opens upward:
## one icon per buildable, with the build price overlaid where the quantity badge would
## be. The rose shop counter uses that same badge for its remaining fixed stock. A single
## floating label sits just to the right of the currently selected icon only, showing that
## buildable's name. The floating label has a transparent background and ignores all mouse
## events. Unaffordable / unavailable buildables are greyed out like disabled quick slots,
## and the floating label turns red when the selected buildable cannot be placed.
## Clicking a slot selects it for placement and closes the quickbar into build preview mode.

const COUNTER_ID: String = "rose_shop_counter"
const ITEMS_TEXTURE: Texture2D = preload("res://assets/sprites/legval/items.png")
const ITEM_FRAME_SIZE: Vector2 = Vector2(32.0, 32.0)
# Currency icon regions inside items.png (match the HUD seed/gem/money icons).
const SEED_ICON_REGION: Rect2 = Rect2(226.0, 0.0, 32.0, 32.0)
const GEM_ICON_REGION: Rect2 = Rect2(256.0, 0.0, 32.0, 32.0)
const MONEY_ICON_REGION: Rect2 = Rect2(416.0, 0.0, 32.0, 32.0)
const SLOT_SIZE: Vector2 = Vector2(56.0, 56.0)
# The merchant column is laid out as an aligned grid: icon | name | price.
const MERCHANT_COLUMNS: int = 3
const DROPUP_GAP: float = 0.0
# Left inset from the panel edge to the first slot (panel border + margin_left), so the
# column's slots can be centred on the toolbuild icon.
const BAR_CONTENT_INSET: float = 10.0
# Y offset (from the top) of the seed-merchant column's top, placing it just below the
# tutorial hint text (GameUI/top anchor/tutorial spans roughly down to y ~240).
const SEED_MERCHANT_BAR_TOP: float = 250.0
const PASTEQUE_ID: String = "pasteque"
# The build picker is opened by one of two quick-bar tools, each offering its own buildables:
# the gardening tool grows plants/turrets, the hammer builds structures. The active tool
# (game_ui.get_selected_build_tool_id) decides which set is shown and anchored to.
const GARDENING_TOOL_ID: String = "gardening"
const HAMMER_TOOL_ID: String = "hammer"
# Slot 0 of the quickbar is the weapons menu; this kind string matches game_ui.WEAPON_SLOT_KIND.
const WEAPON_MENU_KIND: String = "weapon"
const WEAPON_MENU_SLOT_INDEX: int = 0
const SEED_ITEM_ID: String = "seed"
# The seed-merchant column also carries inventory-backed buildables (pasteque),
# which are bought here and later placed from the gardening column above.
const SPECIAL_REWARD_PAD_ID: String = "__special_reward__"
const SPECIAL_REWARD_PAD_PREFIX: String = "__special_reward__:"
const SELECTED_LABEL_COLOR: Color = Color(0.92, 0.88, 0.78)
const SELECTED_DISABLED_LABEL_COLOR: Color = Color(0.85, 0.25, 0.25)

var progression_node: Node
var game_ui: Node
# The buildable currently highlighted in the open picker.
var _selected_item_id: String = ""
# Per build tool (gardening/hammer): the last building the player picked with it, restored
# when that tool's picker reopens if the building still exists.
var _last_picked_by_tool: Dictionary = {}
# The build tool whose column is currently shown, so a tool switch (gardening<->hammer) while
# the picker stays open re-runs the open/default-selection logic for the new tool.
var _shown_build_tool_id: String = ""
var _selected_merchant_item_id: String = ""
# The level must open with the toolbuild showing rose. Consumed on the first toolbuild picker
# open so the counter-preference / last-picked logic resumes on every later open.
var _level_start_default_pending: bool = true
# Affordable count of the selected buildable on the previous refresh. Used to detect the
# moment it runs dry through use (>0 -> 0) so we can auto-switch to the next buildable.
# Deliberately clicking an already-empty slot leaves this at 0, so no auto-switch fires.
var _selected_affordable_prev: int = -1

var _toolbuild_column: VBoxContainer
# The weapons drop-up (slot 0): a vertical menu of possessed weapons, rebuilt when the owned
# set or equipped weapon changes. Selecting one equips it and closes the quickbar.
var _weapon_column: VBoxContainer
var _weapon_items_list: VBoxContainer
var _weapon_rows: Dictionary = {}
var _weapon_buttons: Dictionary = {}
var _weapon_icons: Dictionary = {}
var _weapon_names: Dictionary = {}
var _weapon_signature: String = ""
var _merchant_column: VBoxContainer
# A plain BoxContainer (not VBox/HBox) so its `vertical` axis can be flipped at runtime:
# vertical stack for the toolbuild picker, horizontal bar for the seed-merchant sale.
var _items_list: BoxContainer
var _merchant_items_list: GridContainer
var _seed_icon: AtlasTexture
var _gem_icon: AtlasTexture
var _money_icon: AtlasTexture
# item id -> its row / slot Button / icon TextureRect / affordable-count Label.
var _slot_rows: Dictionary = {}
var _slot_buttons: Dictionary = {}
var _slot_icons: Dictionary = {}
var _slot_counts: Dictionary = {}
# item id -> the small currency icon shown right after the price in each slot's badge.
var _slot_currencies: Dictionary = {}
# item id -> its persistent per-row label group (name + price + currency icon) and its
# parts. Only shown during the seed/weapon merchant column; hidden in build phase, which
# uses the single floating label below instead.
var _row_labels: Dictionary = {}
var _row_names: Dictionary = {}
var _row_prices: Dictionary = {}
var _row_currencies: Dictionary = {}
# The single floating item-name label shown to the right of the slot the mouse is hovering.
# Empty _hovered_item_id hides it.
var _selected_label: HBoxContainer
var _selected_name: Label
var _hovered_item_id: String = ""
# item id -> last applied [selected, disabled] state, so styles are only rebuilt on
# change instead of every frame.
var _slot_state: Dictionary = {}
# Per item id: the four aligned grid cells (icon button, name, quantity, price group) so a
# whole row's visibility can be toggled together, plus the parts refilled each refresh.
var _merchant_row_cells: Dictionary = {}
var _merchant_slot_buttons: Dictionary = {}
var _merchant_slot_icons: Dictionary = {}
var _merchant_row_names: Dictionary = {}
var _merchant_row_prices: Dictionary = {}
var _merchant_row_currencies: Dictionary = {}
var _merchant_slot_state: Dictionary = {}
# The free "special reward" is rendered as one grid row per granted currency, pinned above
# the item rows. These cells are rebuilt whenever the offer changes and moved ahead of the
# item rows; _reward_cells tracks them so they can be removed on the next rebuild.
var _reward_cells: Array[Control] = []
# Signature of the currently rendered reward contents, so they are only rebuilt when
# the offered reward changes instead of every frame.
var _special_reward_signature: String = ""


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
	if not GameState.building_phase_changed.is_connected(_on_building_phase_changed):
		GameState.building_phase_changed.connect(_on_building_phase_changed)
	if not GameState.seed_merchant_phase_changed.is_connected(_on_seed_merchant_phase_changed):
		GameState.seed_merchant_phase_changed.connect(_on_seed_merchant_phase_changed)
	_set_toolbuild_open(false)
	set_process(true)


## Toolbuild picker visibility is derived from the quick-bar selection: open only while the
## Build tool is the selected quick slot and it is daytime.
func _process(_delta: float) -> void:
	var merchant_should_show: bool = _is_seed_merchant_shop_active()
	var menu_kind: String = _active_menu_kind()
	var build_tool_id: String = _selected_build_tool_id()
	var build_should_show: bool = (
		build_tool_id != ""
		and not GameState.is_night
		and not merchant_should_show
	)
	# The weapons menu is available day and night (weapons are wielded at night); it only yields
	# to the seed-merchant column.
	var weapon_should_show: bool = (
		menu_kind == WEAPON_MENU_KIND
		and not merchant_should_show
	)
	visible = build_should_show or merchant_should_show or weapon_should_show
	# Open on first show, and re-open when the active tool changes while already open so the
	# column re-anchors and picks a valid default for the newly selected tool.
	if build_should_show and _toolbuild_column != null and (not _toolbuild_column.visible or build_tool_id != _shown_build_tool_id):
		_shown_build_tool_id = build_tool_id
		_open_build_picker()
	elif not build_should_show and _toolbuild_column != null and _toolbuild_column.visible:
		_close_toolbuild()
	if weapon_should_show and _weapon_column != null and not _weapon_column.visible:
		_weapon_column.visible = true
	elif not weapon_should_show and _weapon_column != null and _weapon_column.visible:
		_weapon_column.visible = false
		_reset_hover_label()
	if merchant_should_show:
		_open_merchant_shop()
	elif _merchant_column != null and _merchant_column.visible:
		_close_merchant_shop()
	if _toolbuild_column != null and _toolbuild_column.visible:
		_apply_phase_layout()
		_refresh_slots()
		_update_build_column_anchor()
	if _weapon_column != null and _weapon_column.visible:
		_apply_weapon_layout()
		_refresh_weapon_menu()
		_update_weapon_column_anchor()
		_update_hover_label()
	if _merchant_column != null and _merchant_column.visible:
		_apply_merchant_layout()
		_refresh_merchant_slots()
		_update_hover_label()


## The kind of quickbar menu game_ui currently has open ("weapon"/gardening/hammer), or "".
func _active_menu_kind() -> String:
	if game_ui != null and game_ui.has_method("get_active_menu_kind"):
		return str(game_ui.call("get_active_menu_kind"))
	return ""


# --- UI construction ---------------------------------------------------------

func _build_ui() -> void:
	var column: VBoxContainer = VBoxContainer.new()
	_toolbuild_column = column
	column.name = "ToolbuildColumn"
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 6)
	column.alignment = BoxContainer.ALIGNMENT_END
	add_child(column)

	column.add_child(_build_bar())
	_build_selected_label()
	_build_weapon_ui()
	_build_merchant_ui()
	move_child(_selected_label, get_child_count() - 1)
	_apply_phase_layout()


# --- Weapons menu (slot 0) ---------------------------------------------------

func _build_weapon_ui() -> void:
	var column: VBoxContainer = VBoxContainer.new()
	_weapon_column = column
	column.name = "WeaponColumn"
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 6)
	column.alignment = BoxContainer.ALIGNMENT_END
	add_child(column)

	var panel: PanelContainer = PanelContainer.new()
	panel.name = "WeaponBarPanel"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	panel.add_theme_stylebox_override("panel", _bar_background_style())
	column.add_child(panel)

	var margin: MarginContainer = MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_bottom", 6)
	panel.add_child(margin)

	var list: VBoxContainer = VBoxContainer.new()
	_weapon_items_list = list
	list.name = "WeaponItemsList"
	list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	list.add_theme_constant_override("separation", 6)
	margin.add_child(list)
	column.visible = false


## Rebuilds the weapon rows when the owned set changes, then highlights the hovered weapon.
func _refresh_weapon_menu() -> void:
	var ids: Array[String] = _possessed_weapon_ids()
	var equipped: String = _equipped_weapon_id()
	var signature: String = "|".join(PackedStringArray(ids)) + "#" + equipped
	if signature != _weapon_signature:
		_weapon_signature = signature
		_rebuild_weapon_rows(ids)
	for id: String in ids:
		var button: Button = _weapon_buttons.get(id) as Button
		if button == null:
			continue
		_apply_slot_style(button, id == _hovered_item_id, false)


func _rebuild_weapon_rows(ids: Array[String]) -> void:
	for child: Node in _weapon_items_list.get_children():
		_weapon_items_list.remove_child(child)
		child.queue_free()
	_weapon_rows.clear()
	_weapon_buttons.clear()
	_weapon_icons.clear()
	_weapon_names.clear()
	# Icons only; the hovered weapon's name is shown by the shared floating label.
	for id: String in ids:
		var button: Button = _build_weapon_slot(id)
		_weapon_items_list.add_child(button)
		_weapon_rows[id] = button


func _build_weapon_slot(item_id: String) -> Button:
	var item_def: Dictionary = ItemCatalog.get_item_def(item_id)
	var button: Button = Button.new()
	button.name = item_id
	button.custom_minimum_size = SLOT_SIZE
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(_on_weapon_pressed.bind(item_id))
	_connect_hover_label(button, item_id)

	var icon: TextureRect = TextureRect.new()
	icon.texture = _item_frame_texture(item_def)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon.offset_left = 8.0
	icon.offset_top = 8.0
	icon.offset_right = -8.0
	icon.offset_bottom = -8.0
	button.add_child(icon)
	_apply_slot_style(button, false, false)

	_weapon_buttons[item_id] = button
	_weapon_icons[item_id] = icon
	return button


func _on_weapon_pressed(item_id: String) -> void:
	if _weapon_column == null or not _weapon_column.visible:
		return
	if game_ui != null and game_ui.has_method("equip_weapon"):
		game_ui.call("equip_weapon", item_id)
		Sfx.play_sound(&"buy")


func _possessed_weapon_ids() -> Array[String]:
	var ids: Array[String] = []
	if game_ui != null and game_ui.has_method("get_possessed_weapon_ids"):
		var raw: Variant = game_ui.call("get_possessed_weapon_ids")
		if raw is Array:
			for value: Variant in raw:
				ids.append(str(value))
	return ids


func _equipped_weapon_id() -> String:
	if game_ui != null and game_ui.has_method("get_equipped_weapon_id"):
		return str(game_ui.call("get_equipped_weapon_id"))
	return ""


func _apply_weapon_layout() -> void:
	if _weapon_column == null:
		return
	# Drop-up column pinned to the bottom, rising out of the weapon quick slot (slot 0).
	_weapon_column.anchor_left = 0.0
	_weapon_column.anchor_right = 0.0
	_weapon_column.anchor_top = 1.0
	_weapon_column.anchor_bottom = 1.0
	_weapon_column.grow_horizontal = Control.GROW_DIRECTION_END
	_weapon_column.grow_vertical = Control.GROW_DIRECTION_BEGIN
	var bottom_offset: float = _dropup_bottom_offset()
	_weapon_column.offset_top = bottom_offset
	_weapon_column.offset_bottom = bottom_offset
	_weapon_column.alignment = BoxContainer.ALIGNMENT_END
	_update_weapon_column_anchor()


## Aligns the weapon column's slots over the weapon quick slot's icon.
func _update_weapon_column_anchor() -> void:
	if _weapon_column == null or game_ui == null or not game_ui.has_method("get_quick_slot_center_x"):
		return
	var center_x: float = float(game_ui.call("get_quick_slot_center_x", WEAPON_MENU_SLOT_INDEX))
	if center_x < 0.0:
		return
	var left: float = center_x - SLOT_SIZE.x * 0.5 - BAR_CONTENT_INSET
	_weapon_column.offset_left = left
	_weapon_column.offset_right = left


func _build_merchant_ui() -> void:
	var column: VBoxContainer = VBoxContainer.new()
	_merchant_column = column
	column.name = "MerchantColumn"
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 6)
	column.alignment = BoxContainer.ALIGNMENT_BEGIN
	add_child(column)

	var panel: PanelContainer = PanelContainer.new()
	panel.name = "MerchantBarPanel"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	panel.add_theme_stylebox_override("panel", _bar_background_style())
	column.add_child(panel)

	var margin: MarginContainer = MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_bottom", 6)
	panel.add_child(margin)

	var grid: GridContainer = GridContainer.new()
	_merchant_items_list = grid
	grid.name = "MerchantItemsGrid"
	grid.columns = MERCHANT_COLUMNS
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 6)
	margin.add_child(grid)

	for item_id: String in _merchant_item_ids():
		_build_merchant_item_cells(grid, item_id)
	column.visible = false


func _special_reward_label() -> String:
	var key: String = "merchant.special_reward"
	var translated: String = Translations.t(key)
	return "Special reward" if translated == key else translated


## Appends one item's three aligned grid cells (icon button, name, price group) to the
## merchant grid. All three cells are tracked together so the whole row is shown or hidden
## as one, keeping every visible row an exact multiple of the column count so the grid stays
## aligned.
func _build_merchant_item_cells(grid: GridContainer, item_id: String) -> void:
	var button: Button = _build_merchant_slot(item_id)
	grid.add_child(button)

	var name_label: Label = _make_row_label(18)
	name_label.add_theme_color_override("font_color", SELECTED_LABEL_COLOR)
	name_label.text = _display_name(item_id)
	grid.add_child(name_label)

	var price_group: HBoxContainer = _build_price_group()
	grid.add_child(price_group)

	_merchant_row_names[item_id] = name_label
	_merchant_row_prices[item_id] = price_group.get_child(0)
	_merchant_row_currencies[item_id] = price_group.get_child(2)
	_merchant_row_cells[item_id] = [button, name_label, price_group] as Array[Control]


## A price-column cell rendering "<price> x <currency icon>". The children are ordered
## [price label, "x" label, currency icon] so callers can address them by index.
func _build_price_group() -> HBoxContainer:
	var group: HBoxContainer = HBoxContainer.new()
	group.mouse_filter = Control.MOUSE_FILTER_IGNORE
	group.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	group.add_theme_constant_override("separation", 4)

	var price_label: Label = _make_row_label(18)
	price_label.add_theme_color_override("font_color", Color.WHITE)
	group.add_child(price_label)

	var x_label: Label = _make_row_label(18)
	x_label.add_theme_color_override("font_color", Color.WHITE)
	x_label.text = "x"
	group.add_child(x_label)

	var currency: TextureRect = TextureRect.new()
	currency.mouse_filter = Control.MOUSE_FILTER_IGNORE
	currency.custom_minimum_size = Vector2(20.0, 20.0)
	currency.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	currency.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	currency.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	group.add_child(currency)
	return group


func _build_merchant_slot(item_id: String) -> Button:
	var item_def: Dictionary = ItemCatalog.get_item_def(item_id)
	var button: Button = Button.new()
	button.name = item_id
	button.custom_minimum_size = SLOT_SIZE
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(_on_merchant_item_pressed.bind(item_id))
	_connect_hover_label(button, item_id)

	var icon: TextureRect = TextureRect.new()
	icon.texture = _item_frame_texture(item_def)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon.offset_left = 8.0
	icon.offset_top = 8.0
	icon.offset_right = -8.0
	icon.offset_bottom = -8.0
	button.add_child(icon)

	_merchant_slot_buttons[item_id] = button
	_merchant_slot_icons[item_id] = icon
	return button


## A small number badge overlaid on the bottom-right of a slot icon.
func _make_icon_count_label(text: String) -> Label:
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
	count.text = text
	return count


## Builds the single floating label (name only) that sits to the right of the selected
## slot. It has no background and ignores all mouse events.
func _build_selected_label() -> void:
	var group: HBoxContainer = HBoxContainer.new()
	_selected_label = group
	group.name = "SelectedItemLabel"
	group.mouse_filter = Control.MOUSE_FILTER_IGNORE
	group.z_index = 100
	group.add_theme_constant_override("separation", 8)
	add_child(group)

	var name_label: Label = _make_row_label(18)
	name_label.add_theme_color_override("font_color", SELECTED_LABEL_COLOR)
	group.add_child(name_label)
	_selected_name = name_label

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

	for item_id: String in _all_item_ids():
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
	# Mouse-only: keyboard/gamepad focus would let the GUI layer swallow game input.
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(_on_item_pressed.bind(item_id))
	_connect_hover_label(button, item_id)

	var icon: TextureRect = TextureRect.new()
	icon.texture = _item_frame_texture(item_def)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon.offset_left = 8.0
	icon.offset_top = 8.0
	icon.offset_right = -8.0
	icon.offset_bottom = -8.0
	button.add_child(icon)

	# Price badge pinned to the slot's bottom-right, laid out as "<price> <currency icon>"
	# so the icon sits right after the number and both grow up-left from the corner.
	var badge: HBoxContainer = HBoxContainer.new()
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.add_theme_constant_override("separation", 1)
	badge.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	badge.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	badge.grow_vertical = Control.GROW_DIRECTION_BEGIN
	badge.offset_right = -4.0
	badge.offset_bottom = -2.0
	button.add_child(badge)

	var count: Label = Label.new()
	count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	count.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	count.add_theme_font_size_override("font_size", 14)
	count.add_theme_color_override("font_color", Color.WHITE)
	count.add_theme_color_override("font_shadow_color", Color.BLACK)
	count.add_theme_constant_override("shadow_offset_x", 1)
	count.add_theme_constant_override("shadow_offset_y", 1)
	badge.add_child(count)

	var currency: TextureRect = TextureRect.new()
	currency.mouse_filter = Control.MOUSE_FILTER_IGNORE
	currency.custom_minimum_size = Vector2(14.0, 14.0)
	currency.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	currency.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	currency.size_flags_vertical = Control.SIZE_SHRINK_END
	badge.add_child(currency)

	_slot_buttons[item_id] = button
	_slot_icons[item_id] = icon
	_slot_counts[item_id] = count
	_slot_currencies[item_id] = currency
	return button


# --- Open / close ------------------------------------------------------------

func _open_build_picker() -> void:
	_apply_phase_layout()
	_set_toolbuild_open(true)
	_refresh_slots()
	var tool_id: String = _selected_build_tool_id()
	# At level start the gardening tool must come up with rose equipped, ahead of every
	# other resume rule. Consumed on the first gardening open so later opens fall through
	# to the usual last-picked logic.
	# Opening only highlights a default buildable. Clicking a slot commits that item for
	# placement and closes the quickbar.
	if _level_start_default_pending and tool_id == GARDENING_TOOL_ID:
		_level_start_default_pending = false
		if _should_show_item("rose") and not _is_item_locked("rose"):
			_highlight_item("rose")
			return
	# Hammer with no counters placed yet: the shop can't do anything until the player builds
	# them (roses are harvested onto counters, clients buy from them). Pre-highlight the counter
	# so the "place the shop counters" prompt is immediately actionable, ahead of the usual
	# last-picked / first-available resume below.
	if tool_id == HAMMER_TOOL_ID and _should_prefer_counter():
		_highlight_item(COUNTER_ID)
		return
	# Resume this tool's last buildable. If it ran out while the player was away from the
	# tool, move to another currently usable buildable; otherwise leave the empty one
	# highlighted so its price/remaining label stays visible.
	var last_picked: String = str(_last_picked_by_tool.get(tool_id, ""))
	if last_picked != "" and _should_show_item(last_picked) and not _is_item_locked(last_picked):
		if _affordable_quantity(last_picked) <= 0:
			var next_id: String = _next_available_buildable(last_picked)
			if next_id != "":
				_highlight_item(next_id)
				return
		_highlight_item(last_picked)
		return
	for item_id: String in _active_build_item_ids():
		if item_id != COUNTER_ID and _is_item_available(item_id) and not _is_item_locked(item_id):
			_highlight_item(item_id)
			return
	_clear_highlight()


func _close_all() -> void:
	_close_toolbuild()
	_close_merchant_shop()


## Hides the build column. The caller decides whether build preview remains active.
func _close_toolbuild() -> void:
	_set_toolbuild_open(false)
	_shown_build_tool_id = ""
	_reset_hover_label()


## Clears the hover state and hides the floating item-name label (on menu close).
func _reset_hover_label() -> void:
	_hovered_item_id = ""
	if _selected_label != null:
		_selected_label.visible = false


func _set_toolbuild_open(is_open: bool) -> void:
	if _toolbuild_column != null:
		_toolbuild_column.visible = is_open
	visible = is_open or _other_columns_visible()


## True when the merchant or weapon columns are showing, so the root stays visible while only the
## build column closes (e.g. switching from a build menu to the weapon menu).
func _other_columns_visible() -> bool:
	if _merchant_column != null and _merchant_column.visible:
		return true
	if _weapon_column != null and _weapon_column.visible:
		return true
	return false


func _open_merchant_shop() -> void:
	if _merchant_column == null:
		return
	if _toolbuild_column != null and _toolbuild_column.visible:
		_close_toolbuild()
	_merchant_column.visible = true
	visible = true
	_apply_merchant_layout()
	_refresh_merchant_slots()
	_ensure_merchant_pad_selection()


func _close_merchant_shop() -> void:
	if _merchant_column != null:
		_merchant_column.visible = false
	_selected_merchant_item_id = ""
	_reset_hover_label()
	visible = (_toolbuild_column != null and _toolbuild_column.visible) or (_weapon_column != null and _weapon_column.visible)


# --- Phase handling ----------------------------------------------------------

## Night closes the toolbuild picker. Day/building phase no longer changes the selected quick slot.
func _on_game_mode_changed(is_night: bool) -> void:
	if is_night:
		_close_all()


func _on_building_phase_changed(is_building_phase: bool) -> void:
	if not is_building_phase:
		_close_toolbuild()


func _on_seed_merchant_phase_changed(is_seed_merchant_phase: bool) -> void:
	_apply_phase_layout()
	if not is_seed_merchant_phase:
		_close_merchant_shop()


# --- Selection ---------------------------------------------------------------

func _on_item_pressed(item_id: String) -> void:
	if _toolbuild_column == null or not _toolbuild_column.visible or GameState.is_night:
		return
	if _is_item_locked(item_id) or not _should_show_item(item_id):
		return
	# Clicking a buildable commits it for placement and closes the quickbar.
	_commit_item(item_id)


func _on_merchant_item_pressed(item_id: String) -> void:
	if _merchant_column == null or not _merchant_column.visible or GameState.is_night:
		return
	if not _is_merchant_item(item_id) or not _is_merchant_item_available(item_id):
		return
	var purchased: bool = false
	var button: Button = _merchant_slot_buttons.get(item_id) as Button
	var start_position: Vector2 = button.get_global_rect().get_center() if button != null else Vector2.ZERO
	if item_id == SEED_ITEM_ID and game_ui != null and game_ui.has_method("try_purchase_seed_merchant_item"):
		purchased = bool(game_ui.call("try_purchase_seed_merchant_item", item_id, 1))
	elif ItemCatalog.is_inventory_backed(item_id) and game_ui != null and game_ui.has_method("try_purchase_placeable_merchant_item"):
		purchased = bool(game_ui.call("try_purchase_placeable_merchant_item", item_id, 1))
	elif ItemCatalog.is_weapon(item_id) and game_ui != null and game_ui.has_method("try_purchase_shop_inventory_item"):
		purchased = bool(game_ui.call("try_purchase_shop_inventory_item", item_id, 1))
	if purchased:
		GameState.seed_merchant_purchase_made = true
		Sfx.play_sound(&"buy")
		_animate_purchase_to_ui(item_id, start_position)
		_refresh_merchant_slots()
		_refresh_slots()


func step_pad_selection(direction: int) -> void:
	if direction == 0 or GameState.is_night:
		return
	if _merchant_column != null and _merchant_column.visible:
		_step_merchant_pad_selection(direction)
		return
	if _toolbuild_column != null and _toolbuild_column.visible:
		_step_build_pad_selection(direction)


func activate_pad_selection() -> bool:
	if GameState.is_night:
		return false
	if _merchant_column != null and _merchant_column.visible:
		_ensure_merchant_pad_selection()
		if _is_special_reward_pad_id(_selected_merchant_item_id):
			_on_special_reward_pressed(null, _special_reward_key_from_pad_id(_selected_merchant_item_id))
			return true
		if _selected_merchant_item_id != "":
			_on_merchant_item_pressed(_selected_merchant_item_id)
			return true
	# Gamepad: confirming while the build menu is open commits the highlighted buildable.
	if _toolbuild_column != null and _toolbuild_column.visible and _selected_item_id != "":
		_commit_item(_selected_item_id)
		return true
	return false


func is_merchant_shop_open() -> bool:
	return _merchant_column != null and _merchant_column.visible


func _step_build_pad_selection(direction: int) -> void:
	var ids: Array[String] = _visible_build_item_ids()
	if ids.is_empty():
		_clear_highlight()
		return
	var index: int = ids.find(_selected_item_id)
	if index < 0:
		index = 0 if direction >= 0 else ids.size() - 1
	else:
		index = (index + direction) % ids.size()
		if index < 0:
			index += ids.size()
	_highlight_item(ids[index])


func _visible_build_item_ids() -> Array[String]:
	var ids: Array[String] = []
	for item_id: String in _active_build_item_ids():
		if _should_show_item(item_id) and not _is_item_locked(item_id):
			ids.append(item_id)
	return ids


func _step_merchant_pad_selection(direction: int) -> void:
	var ids: Array[String] = _visible_merchant_pad_item_ids()
	if ids.is_empty():
		_selected_merchant_item_id = ""
		return
	var index: int = ids.find(_selected_merchant_item_id)
	if index < 0:
		index = 0 if direction >= 0 else ids.size() - 1
	else:
		index = (index + direction) % ids.size()
		if index < 0:
			index += ids.size()
	_selected_merchant_item_id = ids[index]
	_refresh_merchant_slots()


func _ensure_merchant_pad_selection() -> void:
	var ids: Array[String] = _visible_merchant_pad_item_ids()
	if ids.is_empty():
		_selected_merchant_item_id = ""
		return
	if not ids.has(_selected_merchant_item_id):
		_selected_merchant_item_id = ids[0]
	_refresh_merchant_slots()


func _visible_merchant_pad_item_ids() -> Array[String]:
	var ids: Array[String] = []
	var reward_keys: Array[String] = _active_special_reward_keys()
	for reward_key: String in reward_keys:
		ids.append(_special_reward_pad_id(reward_key))
	for item_id: String in _merchant_item_ids():
		if _should_show_merchant_item(item_id):
			ids.append(item_id)
	return ids


## Highlights a buildable in the open menu without equipping it (no build preview, quickbar
## stays open). Used for the menu's default/browse selection.
func _highlight_item(item_id: String) -> void:
	_selected_item_id = item_id
	# Seed the run-dry tracker with the highlight's current count so the refresh below (and a
	# deliberately-empty highlight) never mis-fires an auto-switch.
	_selected_affordable_prev = _affordable_quantity(item_id)
	_refresh_slots()


## Commits a buildable: it becomes the active build preview and closes the quickbar for placement.
func _commit_item(item_id: String) -> void:
	_selected_item_id = item_id
	var tool_id: String = _selected_build_tool_id()
	if tool_id != "":
		_last_picked_by_tool[tool_id] = item_id
	_selected_affordable_prev = _affordable_quantity(item_id)
	if game_ui != null and game_ui.has_method("set_selected_build_item"):
		game_ui.call("set_selected_build_item", item_id)
	Sfx.play_sound(&"buy")
	if game_ui != null and game_ui.has_method("deactivate_quickbar"):
		game_ui.call("deactivate_quickbar")
	_refresh_slots()


## Clears the menu highlight.
func _clear_highlight() -> void:
	_selected_item_id = ""
	_refresh_slots()


func _can_afford(item_id: String) -> bool:
	return game_ui != null and game_ui.has_method("can_afford_build") and bool(game_ui.call("can_afford_build", item_id, 1))


func _affordable_quantity(item_id: String) -> int:
	if game_ui != null and game_ui.has_method("get_build_affordable_quantity"):
		return int(game_ui.call("get_build_affordable_quantity", item_id))
	return 0


func _merchant_affordable_quantity(item_id: String) -> int:
	if game_ui != null and game_ui.has_method("get_merchant_affordable_quantity"):
		return int(game_ui.call("get_merchant_affordable_quantity", item_id))
	return 0


func _is_item_locked(_item_id: String) -> bool:
	return false


## True while the shop should force the counter to the front of the selection: the
## counter is buildable and affordable, and none have been placed yet. This is exactly
## the state that drives the tutorial's "place the shop counters" prompt.
func _should_prefer_counter() -> bool:
	if not _should_show_item(COUNTER_ID) or _is_item_locked(COUNTER_ID):
		return false
	if _affordable_quantity(COUNTER_ID) <= 0:
		return false
	return _placed_counter_count() == 0


func _placed_counter_count() -> int:
	var scene: Node = get_tree().current_scene
	var manager: Node = scene.get_node_or_null("Map/BuildingObjectManager") if scene != null else null
	if manager != null and manager.has_method("count_buildings_by_item_id"):
		return int(manager.call("count_buildings_by_item_id", COUNTER_ID))
	return 0


func _is_item_available(item_id: String) -> bool:
	return game_ui == null or not game_ui.has_method("is_build_item_available") or bool(game_ui.call("is_build_item_available", item_id))


func _is_merchant_item_available(item_id: String) -> bool:
	return game_ui == null or not game_ui.has_method("is_merchant_item_available") or bool(game_ui.call("is_merchant_item_available", item_id))


# --- Per-frame refresh -------------------------------------------------------

func _refresh_slots() -> void:
	for item_id: String in _all_item_ids():
		var row: Control = _slot_rows.get(item_id) as Control
		if row == null:
			continue
		row.visible = _should_show_item(item_id)
		if not row.visible:
			continue
		var button: Button = _slot_buttons[item_id] as Button
		var affordable: int = _affordable_quantity(item_id)
		var disabled: bool = affordable <= 0 or _is_item_locked(item_id)
		var highlighted: bool = item_id == _hovered_item_id
		var count_label: Label = _slot_counts[item_id] as Label
		count_label.text = _slot_badge_text(item_id)
		# Inventory-backed buildables (pasteque, the rose shop counter) show an owned count
		# rather than a placement price, so they carry no currency icon; every other buildable
		# shows the icon for the currency it costs.
		var slot_currency: TextureRect = _slot_currencies[item_id] as TextureRect
		var slot_currency_texture: AtlasTexture = null if ItemCatalog.is_inventory_backed(item_id) else _currency_texture(item_id)
		slot_currency.texture = slot_currency_texture
		slot_currency.visible = slot_currency_texture != null
		# The merchant column signals unaffordability through the per-row label colour, so its
		# slots stay at full colour; the build column greys unaffordable/locked slots.
		var visual_disabled: bool = disabled
		var state: Array[bool] = [highlighted, visual_disabled]
		if _slot_state.get(item_id) != state:
			_slot_state[item_id] = state
			_apply_slot_style(button, highlighted, visual_disabled)
			(_slot_icons[item_id] as TextureRect).modulate = (
				Color(0.45, 0.45, 0.45, 0.55) if visual_disabled else Color.WHITE
			)
	_update_hover_label()
	_update_row_labels()
	_maybe_auto_switch_from_empty()


## When the selected buildable runs dry through use (its affordable/limit count drops from
## >0 to 0), hop to the next available buildable in the vertical bar. Does nothing when the
## player deliberately selected an already-empty slot (the count never transitioned from >0),
## and stays put when no other buildable is available.
func _maybe_auto_switch_from_empty() -> void:
	if _selected_item_id == "":
		_selected_affordable_prev = -1
		return
	var current: int = _affordable_quantity(_selected_item_id)
	if _selected_affordable_prev > 0 and current <= 0 and not _is_item_locked(_selected_item_id):
		var next_id: String = _next_available_buildable(_selected_item_id)
		if next_id != "":
			_highlight_item(next_id)
			return
	_selected_affordable_prev = current


## The next buildable after `from_id` in the active tool's bar (wrapping) that is shown,
## unlocked and affordable, or "" if none.
func _next_available_buildable(from_id: String) -> String:
	var ids: Array[String] = _active_build_item_ids()
	var n: int = ids.size()
	if n == 0:
		return ""
	var start: int = ids.find(from_id)
	for offset: int in range(1, n + 1):
		var idx: int = ((start if start >= 0 else -1) + offset) % n
		var candidate: String = ids[idx]
		if candidate == from_id:
			continue
		if _should_show_item(candidate) and not _is_item_locked(candidate) and _affordable_quantity(candidate) > 0:
			return candidate
	return ""


## Connects a menu slot button so hovering it shows the shared floating item-name label.
func _connect_hover_label(button: Button, item_id: String) -> void:
	button.mouse_entered.connect(_on_slot_hover.bind(item_id, true))
	button.mouse_exited.connect(_on_slot_hover.bind(item_id, false))


func _on_slot_hover(item_id: String, entered: bool) -> void:
	if entered:
		_hovered_item_id = item_id
	elif _hovered_item_id == item_id:
		_hovered_item_id = ""
	_update_hover_label()


func _button_for_item(item_id: String) -> Button:
	if _slot_buttons.has(item_id):
		return _slot_buttons[item_id] as Button
	if _weapon_buttons.has(item_id):
		return _weapon_buttons[item_id] as Button
	if _merchant_slot_buttons.has(item_id):
		return _merchant_slot_buttons[item_id] as Button
	if item_id.begins_with(SPECIAL_REWARD_PAD_PREFIX):
		for cell: Control in _reward_cells:
			var button: Button = cell as Button
			if button != null and str(button.get_meta(&"reward_pad_id", "")) == item_id:
				return button
	return null


## Fills in and positions the floating label next to the slot the mouse is hovering. Build and
## merchant items that cannot be used turn the label red. Hidden when nothing is hovered.
func _update_hover_label() -> void:
	if _selected_label == null:
		return
	var item_id: String = _hovered_item_id
	var button: Button = _button_for_item(item_id) if item_id != "" else null
	if button == null or not button.visible:
		_selected_label.visible = false
		return
	_selected_label.visible = true
	var color: Color = SELECTED_LABEL_COLOR
	# Build slots redden when the buildable cannot be placed; weapon slots are always plain.
	if _slot_buttons.has(item_id):
		var can_place: bool = _can_afford(item_id) and not _is_item_locked(item_id)
		color = SELECTED_LABEL_COLOR if can_place else SELECTED_DISABLED_LABEL_COLOR
	elif _merchant_slot_buttons.has(item_id):
		var can_buy: bool = _can_afford(item_id) and not _is_item_locked(item_id)
		color = SELECTED_LABEL_COLOR if can_buy else SELECTED_DISABLED_LABEL_COLOR
	_selected_name.add_theme_color_override("font_color", color)
	_selected_name.text = _special_reward_label() if item_id.begins_with(SPECIAL_REWARD_PAD_PREFIX) else _display_name(item_id)
	_position_selected_label(button)


func _slot_badge_text(item_id: String) -> String:
	# Inventory-backed buildables show how many the player currently owns (already paid
	# for at the merchant), not a placement price.
	if ItemCatalog.is_inventory_backed(item_id):
		return str(maxi(_affordable_quantity(item_id), 0))
	return str(_build_price(item_id))


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
	var show_rows: bool = false
	for item_id: String in _all_item_ids():
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


func _build_price(item_id: String) -> int:
	if game_ui != null and game_ui.has_method("get_build_price"):
		return int(game_ui.call("get_build_price", item_id))
	return ItemCatalog.get_price(item_id)


func _merchant_price(item_id: String) -> int:
	if game_ui != null and game_ui.has_method("get_merchant_price"):
		return int(game_ui.call("get_merchant_price", item_id))
	return ItemCatalog.get_price(item_id)


## The build tool currently selected in the quick bar (gardening/hammer), or "" if none.
func _selected_build_tool_id() -> String:
	if game_ui != null and game_ui.has_method("get_selected_build_tool_id"):
		return str(game_ui.call("get_selected_build_tool_id"))
	return ""


## The buildables offered by the currently selected build tool, in column order. Empty when
## no build tool is selected.
func _active_build_item_ids() -> Array[String]:
	match _selected_build_tool_id():
		GARDENING_TOOL_ID:
			return _string_names_to_strings(ItemCatalog.get_gardening_shop_item_ids())
		HAMMER_TOOL_ID:
			return _string_names_to_strings(ItemCatalog.get_hammer_shop_item_ids())
	return []


func _should_show_item(item_id: String) -> bool:
	return item_id in _active_build_item_ids() and _is_item_available(item_id)


func _should_show_merchant_item(item_id: String) -> bool:
	return item_id in _merchant_item_ids() and _is_merchant_item(item_id) and _is_merchant_item_available(item_id)


func _is_merchant_item(item_id: String) -> bool:
	return item_id == SEED_ITEM_ID or ItemCatalog.is_weapon(item_id) or ItemCatalog.is_inventory_backed(item_id)


func _all_item_ids() -> Array[String]:
	var ids: Array[String] = _active_candidate_item_ids()
	for item_id: String in _merchant_item_ids():
		if not ids.has(item_id):
			ids.append(item_id)
	return ids


func _active_candidate_item_ids() -> Array[String]:
	var ids: Array[String] = _string_names_to_strings(ItemCatalog.get_tool_shop_item_ids())
	for item_id: String in _merchant_item_ids():
		if ItemCatalog.is_inventory_backed(item_id) and not ids.has(item_id):
			ids.append(item_id)
	return ids


func _merchant_item_ids() -> Array[String]:
	return _string_names_to_strings(ItemCatalog.get_merchant_shop_item_ids())


func _string_names_to_strings(item_ids: Array[StringName]) -> Array[String]:
	var ids: Array[String] = []
	for item_id: StringName in item_ids:
		ids.append(String(item_id))
	return ids


func _player_near_seed_merchant() -> bool:
	var scene: Node = get_tree().current_scene
	var manager: Node = scene.get_node_or_null("Map/BuildingManager") if scene != null else null
	return manager != null and manager.has_method("is_player_near_seed_merchant") and bool(manager.call("is_player_near_seed_merchant"))


func _is_seed_merchant_shop_active() -> bool:
	return GameState.is_seed_merchant_phase and _player_near_seed_merchant()


func _refresh_merchant_slots() -> void:
	_refresh_special_reward_row()
	_refresh_special_reward_selection_style()
	for item_id: String in _merchant_item_ids():
		var cells: Array = _merchant_row_cells.get(item_id, []) as Array
		if cells.is_empty():
			continue
		var should_show: bool = _should_show_merchant_item(item_id)
		for cell: Control in cells:
			cell.visible = should_show
		if not should_show:
			continue
		var button: Button = _merchant_slot_buttons[item_id] as Button
		var affordable: int = _merchant_affordable_quantity(item_id)
		var disabled: bool = affordable <= 0
		var highlighted: bool = _hovered_item_id == item_id
		var state: Array[bool] = [highlighted, false]
		if _merchant_slot_state.get(item_id) != state:
			_merchant_slot_state[item_id] = state
			_apply_slot_style(button, highlighted, false)
			(_merchant_slot_icons[item_id] as TextureRect).modulate = Color.WHITE
		var color: Color = SELECTED_DISABLED_LABEL_COLOR if disabled else SELECTED_LABEL_COLOR
		var name_label: Label = _merchant_row_names[item_id] as Label
		var price_label: Label = _merchant_row_prices[item_id] as Label
		var currency: TextureRect = _merchant_row_currencies[item_id] as TextureRect
		var x_label: Label = (cells[2] as HBoxContainer).get_child(1) as Label
		name_label.add_theme_color_override("font_color", color)
		price_label.add_theme_color_override("font_color", color)
		x_label.add_theme_color_override("font_color", color)
		currency.modulate = color
		name_label.text = _display_name(item_id)
		price_label.text = str(_merchant_price(item_id))
		var currency_texture: AtlasTexture = _currency_texture(item_id)
		currency.texture = currency_texture
		currency.visible = currency_texture != null
		x_label.visible = currency_texture != null


func _has_active_special_reward() -> bool:
	if game_ui == null or not game_ui.has_method("get_active_night_reward"):
		return false
	var info: Dictionary = game_ui.call("get_active_night_reward") as Dictionary
	return not info.is_empty()


func _active_special_reward_keys() -> Array[String]:
	var keys: Array[String] = []
	if game_ui == null or not game_ui.has_method("get_active_night_reward"):
		return keys
	var info: Dictionary = game_ui.call("get_active_night_reward") as Dictionary
	if info.is_empty():
		return keys
	var rewards: Array = info.get("rewards", []) as Array
	for raw_reward: Variant in rewards:
		var reward: Dictionary = raw_reward as Dictionary
		keys.append(str(reward.get("key", "")))
	return keys


## The pad-selection id for a single special reward: the shared prefix plus the reward's
## key, so each granted reward row gets its own selectable pad id.
func _special_reward_pad_id(reward_key: String) -> String:
	return SPECIAL_REWARD_PAD_PREFIX + reward_key


## True when a merchant pad id refers to a special-reward row (rather than a weapon/seed item).
func _is_special_reward_pad_id(pad_id: String) -> bool:
	return pad_id.begins_with(SPECIAL_REWARD_PAD_PREFIX)


## The reward key encoded in a special-reward pad id (inverse of _special_reward_pad_id).
func _special_reward_key_from_pad_id(pad_id: String) -> String:
	return pad_id.substr(SPECIAL_REWARD_PAD_PREFIX.length())


func _refresh_special_reward_selection_style() -> void:
	var index: int = 0
	while index < _reward_cells.size():
		var button: Button = _reward_cells[index] as Button
		if button != null:
			var pad_id: String = str(button.get_meta(&"reward_pad_id", ""))
			var highlighted: bool = _hovered_item_id == pad_id
			_apply_slot_style(button, highlighted, false)
		index += MERCHANT_COLUMNS


## Rebuilds the free reward rows pinned to the top of the merchant grid from game_ui's current
## offer as one grid row per granted currency, then moves them ahead of the item rows.
## Only rebuilds when the offered payout changes.
func _refresh_special_reward_row() -> void:
	if _merchant_items_list == null:
		return
	var info: Dictionary = {}
	if game_ui != null and game_ui.has_method("get_active_night_reward"):
		info = game_ui.call("get_active_night_reward")
	var rewards: Array = (info.get("rewards", []) as Array) if not info.is_empty() else []
	var signature: String = ""
	for raw_reward: Variant in rewards:
		var reward: Dictionary = raw_reward as Dictionary
		signature += "%s:%s:%d|" % [
			str(reward.get("key", "")), str(reward.get("currency", "")), int(reward.get("amount", 0))
		]
	if signature == _special_reward_signature:
		return
	_special_reward_signature = signature
	for cell: Control in _reward_cells:
		_merchant_items_list.remove_child(cell)
		cell.queue_free()
	_reward_cells.clear()
	var insert_index: int = 0
	for raw_reward: Variant in rewards:
		var reward: Dictionary = raw_reward as Dictionary
		var reward_cells: Array[Control] = _build_reward_row_cells(
			str(reward.get("currency", "")), int(reward.get("amount", 0)), str(reward.get("key", ""))
		)
		for cell: Control in reward_cells:
			_merchant_items_list.add_child(cell)
			_merchant_items_list.move_child(cell, insert_index)
			insert_index += 1
			_reward_cells.append(cell)


## The three cells for one free-reward currency payout: the currency icon (a claim button)
## with the granted amount overlaid as a count badge, the reward name, and an empty price
## column.
func _build_reward_row_cells(currency: String, amount: int, reward_key: String) -> Array[Control]:
	var button: Button = Button.new()
	button.custom_minimum_size = SLOT_SIZE
	button.focus_mode = Control.FOCUS_NONE
	var reward_pad_id: String = _special_reward_pad_id(reward_key)
	button.set_meta(&"reward_pad_id", reward_pad_id)
	button.pressed.connect(_on_special_reward_pressed.bind(button, reward_key))
	_connect_hover_label(button, reward_pad_id)
	_apply_slot_style(button, false, false)

	var icon: TextureRect = TextureRect.new()
	icon.texture = _currency_icon_for(currency)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon.offset_left = 8.0
	icon.offset_top = 8.0
	icon.offset_right = -8.0
	icon.offset_bottom = -8.0
	button.add_child(icon)
	button.add_child(_make_icon_count_label(str(amount)))

	var name_label: Label = _make_row_label(18)
	name_label.add_theme_color_override("font_color", SELECTED_LABEL_COLOR)
	name_label.text = _special_reward_label()

	var free_label: Label = _make_row_label(18)
	free_label.add_theme_color_override("font_color", SELECTED_LABEL_COLOR)
	free_label.text = ""

	return [button, name_label, free_label] as Array[Control]


## Maps a currency id ("seed"/"gem"/"money") straight to its HUD icon texture. Unlike
## _currency_texture (which takes an item id), this takes the currency itself.
func _currency_icon_for(currency: String) -> AtlasTexture:
	match currency:
		"gem":
			return _gem_icon
		"seed":
			return _seed_icon
		"money":
			return _money_icon
	return null


func _on_special_reward_pressed(source: Button = null, reward_key: String = "") -> void:
	if _merchant_column == null or not _merchant_column.visible or GameState.is_night:
		return
	if game_ui == null or not game_ui.has_method("claim_active_night_reward"):
		return
	var reward_source: Button = source if source != null else _first_reward_button()
	var start_position: Vector2 = reward_source.get_global_rect().get_center() if reward_source != null else Vector2.ZERO
	if bool(game_ui.call("claim_active_night_reward", start_position, reward_key)):
		Sfx.play_sound(&"buy")
		_refresh_special_reward_row()


func _first_reward_button() -> Button:
	var index: int = 0
	while index < _reward_cells.size():
		var button: Button = _reward_cells[index] as Button
		if button != null:
			return button
		index += MERCHANT_COLUMNS
	return null


func _animate_purchase_to_ui(item_id: String, start_global_position: Vector2) -> void:
	if game_ui == null:
		return
	var world_position: Vector2 = get_viewport().get_canvas_transform().affine_inverse() * start_global_position
	if item_id == SEED_ITEM_ID:
		var seed_icon_node: Node = game_ui.get_node_or_null("currenciesUI/seedIcon")
		if seed_icon_node != null and seed_icon_node.has_method("animate_seed_harvest"):
			seed_icon_node.call("animate_seed_harvest", world_position, 0, Callable(), false)
		return
	if game_ui.has_method("animate_inventory_item_to_slot"):
		game_ui.call("animate_inventory_item_to_slot", item_id, start_global_position)


func _apply_phase_layout() -> void:
	if _toolbuild_column == null:
		return
	# Build phase: vertical column pinned to the bottom, rising up out of the toolbuild
	# quick slot; grows rightward so the name/price labels extend past the slots.
	if _items_list != null:
		_items_list.vertical = true
	_toolbuild_column.anchor_left = 0.0
	_toolbuild_column.anchor_right = 0.0
	_toolbuild_column.anchor_top = 1.0
	_toolbuild_column.anchor_bottom = 1.0
	_toolbuild_column.grow_horizontal = Control.GROW_DIRECTION_END
	_toolbuild_column.grow_vertical = Control.GROW_DIRECTION_BEGIN
	var bottom_offset: float = _dropup_bottom_offset()
	_toolbuild_column.offset_top = bottom_offset
	_toolbuild_column.offset_bottom = bottom_offset
	_toolbuild_column.alignment = BoxContainer.ALIGNMENT_END
	_update_build_column_anchor()


func _dropup_bottom_offset() -> float:
	if game_ui != null and game_ui.has_method("get_quick_bar_top_y"):
		var toolbar_top_y: float = float(game_ui.call("get_quick_bar_top_y"))
		if toolbar_top_y >= 0.0:
			var parent_bottom_y: float = global_position.y + size.y
			return toolbar_top_y - parent_bottom_y - DROPUP_GAP
	return -84.0


func _apply_merchant_layout() -> void:
	if _merchant_column == null:
		return
	_merchant_column.anchor_left = 0.0
	_merchant_column.anchor_right = 0.0
	_merchant_column.anchor_top = 0.0
	_merchant_column.anchor_bottom = 0.0
	_merchant_column.grow_horizontal = Control.GROW_DIRECTION_END
	_merchant_column.grow_vertical = Control.GROW_DIRECTION_END
	_merchant_column.offset_top = SEED_MERCHANT_BAR_TOP
	_merchant_column.offset_bottom = SEED_MERCHANT_BAR_TOP
	_merchant_column.alignment = BoxContainer.ALIGNMENT_BEGIN
	_update_merchant_column_anchor()


## Aligns the merchant column's slots to the quickbar's left edge.
func _update_merchant_column_anchor() -> void:
	if _merchant_column == null or game_ui == null or not game_ui.has_method("get_quick_bar_left_x"):
		return
	var left_x: float = float(game_ui.call("get_quick_bar_left_x"))
	if left_x < 0.0:
		return
	var left: float = left_x - BAR_CONTENT_INSET
	_merchant_column.offset_left = left
	_merchant_column.offset_right = left


## Aligns the build-phase column's slots horizontally over the active build tool's quick slot.
func _update_build_column_anchor() -> void:
	if _toolbuild_column == null or game_ui == null or not game_ui.has_method("get_build_tool_slot_center_x"):
		return
	var center_x: float = float(game_ui.call("get_build_tool_slot_center_x"))
	if center_x < 0.0:
		return
	var left: float = center_x - SLOT_SIZE.x * 0.5 - BAR_CONTENT_INSET
	_toolbuild_column.offset_left = left
	_toolbuild_column.offset_right = left


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
			style.border_color = Color(0.92, 0.78, 0.34)
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
