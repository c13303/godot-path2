extends Control
class_name DialogUI

## Generic, reusable modal dialog. It owns only presentation and navigation:
## portrait + speaker name, a typewriter-revealed body text, a scrollable list of
## dynamically generated choice rows, and mouse / keyboard / gamepad navigation while open.
## It knows nothing about the seed merchant, items, currencies, inventory, rewards or
## purchases; callers drive it through the public API (open_dialog / refresh_choices /
## close_dialog / finish_typewriter) and receive choice activations through a Callable.
##
## A single instance lives under GameUI/Dialog for the whole scene and is reused for every
## conversation. It is added to the &"dialog_ui" group so unrelated systems can find it.
##
## Choice dictionary fields (all optional except id/label):
##   "id": String                 - stable identifier passed back to the choice handler
##   "label": String              - main row text
##   "icon": Texture2D            - icon shown in the fixed icon column
##   "price_text": String         - text shown in the fixed price column (empty leaves it blank)
##   "currency_icon": Texture2D   - small icon shown right after the price
##   "icon_badge_text": String    - small badge drawn over the icon (e.g. reward amount)
##   "visible": bool              - whether the row is shown at all (default true)
##   "enabled": bool              - whether activating it does anything (default true)
##   "close_on_select": bool      - close the dialog after the handler runs (default false)
##
## Options dictionary fields:
##   "blocks_gameplay_input": bool
##   "body_icons": Dictionary     - text placeholder String -> inline Texture2D

const GROUP_NAME: StringName = &"dialog_ui"

# Layout metrics. Every region has a FIXED size so nothing reflows while the typewriter
# reveals text or when the choice list appears: the modal is fully pre-baked. The dialog is a
# fixed-size box centred in the viewport (a CenterContainer), not a screen-filling panel.
const PANEL_PADDING: int = 24
const COLUMN_SEPARATION: int = 20
const ROOT_SEPARATION: int = 16
const PORTRAIT_SIZE: Vector2 = Vector2(148.0, 148.0)
const LEFT_COLUMN_WIDTH: float = 200.0
const BODY_WIDTH: float = 430.0
const UPPER_HEIGHT: float = 208.0
# Reserved height for the choice list; kept even while the list is hidden so the upper
# section never resizes when choices appear.
const CHOICE_AREA_HEIGHT: float = 250.0
const CHOICE_ROW_HEIGHT: float = 58.0
const CHOICE_ICON_CELL_WIDTH: float = 60.0
const CHOICE_ICON_INSET: float = 7.0
const CHOICE_PRICE_CELL_WIDTH: float = 108.0
const CLOSE_BUTTON_SIZE: float = 42.0

# Font sizes (~1.5x the earlier sizes).
const FONT_BODY: int = 30
const FONT_NAME: int = 29
const FONT_LABEL: int = 27
const FONT_PRICE: int = 27
const FONT_BADGE: int = 22
const FONT_CLOSE: int = 26

# Left-stick navigation threshold and release latch.
const STICK_THRESHOLD: float = 0.5

@export var characters_per_second: float = 45.0


## One parsed, validated choice plus its live row nodes.
class Choice:
	var id: String = ""
	var label: String = ""
	var icon: Texture2D = null
	var price_text: String = ""
	var currency_icon: Texture2D = null
	var icon_badge_text: String = ""
	var visible: bool = true
	var enabled: bool = true
	var close_on_select: bool = false
	var button: Button = null


# --- Public state ------------------------------------------------------------
var _open: bool = false
var _context_id: StringName = &""

# --- Callbacks ---------------------------------------------------------------
var _choice_handler: Callable = Callable()
var _closed_handler: Callable = Callable()

# --- Typewriter --------------------------------------------------------------
var _typing: bool = false
var _typed_chars: float = 0.0
var _total_chars: int = 0
var _choices_revealed: bool = false

# --- Choices -----------------------------------------------------------------
var _choices: Array[Choice] = []
var _selected_index: int = -1

# --- Input guards ------------------------------------------------------------
# Frame the dialog opened on, so the very input that opened it cannot also skip the
# typewriter or activate a choice in the same frame.
var _open_frame: int = -1
var _stick_latched: bool = false

# --- Gameplay input lock -----------------------------------------------------
var _input_lock_applied: bool = false
var _input_lock_previous: bool = false
var _player_controller: PlayerController = null

# --- Nodes -------------------------------------------------------------------
var _backdrop: ColorRect
var _panel: PanelContainer
var _portrait: TextureRect
var _name_label: Label
var _body_scroll: ScrollContainer
var _body_label: RichTextLabel
var _choice_scroll: ScrollContainer
var _choice_list: VBoxContainer
var _close_button: Button


func _ready() -> void:
	add_to_group(GROUP_NAME)
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_ui()
	visible = false
	set_process(false)
	set_process_unhandled_input(false)


# --- UI construction ---------------------------------------------------------

func _build_ui() -> void:
	_backdrop = ColorRect.new()
	_backdrop.name = "Backdrop"
	_backdrop.color = Color(0.0, 0.0, 0.0, 0.5)
	_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	# STOP so clicks anywhere behind the panel are swallowed (no world interaction).
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	_backdrop.gui_input.connect(_on_dialog_surface_gui_input)
	add_child(_backdrop)

	# The panel is a fixed-size box centred in the viewport. CenterContainer sizes it to its
	# content's (fixed) minimum size, so the modal stays the same size and position no matter
	# what text or how many choices it holds.
	var center: CenterContainer = CenterContainer.new()
	center.name = "Center"
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.gui_input.connect(_on_dialog_surface_gui_input)
	_panel.add_theme_stylebox_override("panel", _panel_background_style())
	center.add_child(_panel)

	var inner_margin: MarginContainer = MarginContainer.new()
	inner_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner_margin.add_theme_constant_override("margin_left", PANEL_PADDING)
	inner_margin.add_theme_constant_override("margin_top", PANEL_PADDING)
	inner_margin.add_theme_constant_override("margin_right", PANEL_PADDING)
	inner_margin.add_theme_constant_override("margin_bottom", PANEL_PADDING)
	_panel.add_child(inner_margin)

	var root_column: VBoxContainer = VBoxContainer.new()
	root_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_column.add_theme_constant_override("separation", ROOT_SEPARATION)
	inner_margin.add_child(root_column)

	root_column.add_child(_build_upper_section())
	root_column.add_child(_build_choice_section())
	_build_close_button()


func _build_upper_section() -> HBoxContainer:
	var upper: HBoxContainer = HBoxContainer.new()
	upper.name = "Upper"
	upper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Fixed height (no vertical expand) so it never resizes when the choices appear below.
	upper.custom_minimum_size = Vector2(0.0, UPPER_HEIGHT)
	upper.add_theme_constant_override("separation", COLUMN_SEPARATION)

	# Left column: portrait then speaker name, at a fixed width so the body text always
	# starts at the same X regardless of the name's length.
	var left_column: VBoxContainer = VBoxContainer.new()
	left_column.name = "PortraitColumn"
	left_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	left_column.custom_minimum_size = Vector2(LEFT_COLUMN_WIDTH, UPPER_HEIGHT)
	left_column.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	left_column.alignment = BoxContainer.ALIGNMENT_BEGIN
	left_column.add_theme_constant_override("separation", 10)
	upper.add_child(left_column)

	_portrait = TextureRect.new()
	_portrait.name = "Portrait"
	_portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Nearest filtering keeps pixel-art portraits crisp when enlarged; aspect is preserved.
	_portrait.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_portrait.custom_minimum_size = PORTRAIT_SIZE
	_portrait.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_portrait.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	left_column.add_child(_portrait)

	_name_label = Label.new()
	_name_label.name = "SpeakerName"
	_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_name_label.custom_minimum_size = Vector2(LEFT_COLUMN_WIDTH, 0.0)
	_name_label.add_theme_font_size_override("font_size", FONT_NAME)
	_name_label.add_theme_color_override("font_color", Color(0.92, 0.88, 0.78))
	left_column.add_child(_name_label)

	# Right column: fixed-size scrollable body text, no horizontal scrolling, typewriter
	# reveal. fit_content sizes the label to the FULL text from the start, so revealing
	# characters never changes its layout; only long text scrolls inside the fixed box.
	_body_scroll = ScrollContainer.new()
	_body_scroll.name = "BodyScroll"
	_body_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_body_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_body_scroll.custom_minimum_size = Vector2(BODY_WIDTH, UPPER_HEIGHT)
	_body_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body_scroll.gui_input.connect(_on_dialog_surface_gui_input)
	upper.add_child(_body_scroll)

	_body_label = RichTextLabel.new()
	_body_label.name = "BodyText"
	_body_label.bbcode_enabled = true
	_body_label.fit_content = true
	_body_label.scroll_active = false
	_body_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body_label.add_theme_font_size_override("normal_font_size", FONT_BODY)
	_body_scroll.add_child(_body_label)
	return upper


func _build_choice_section() -> ScrollContainer:
	# Fixed-height scroll area, reserved even while empty so the upper section never moves.
	# A long list scrolls inside it rather than growing the modal. The scroll container stays
	# visible; only its inner list is hidden until the typewriter finishes, so the reserved
	# space is kept the whole time.
	_choice_scroll = ScrollContainer.new()
	_choice_scroll.name = "ChoiceScroll"
	_choice_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_choice_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_choice_scroll.custom_minimum_size = Vector2(0.0, CHOICE_AREA_HEIGHT)
	_choice_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_choice_scroll.gui_input.connect(_on_dialog_surface_gui_input)

	_choice_list = VBoxContainer.new()
	_choice_list.name = "ChoiceList"
	_choice_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_choice_list.add_theme_constant_override("separation", 8)
	_choice_list.visible = false
	_choice_scroll.add_child(_choice_list)
	return _choice_scroll


func _build_close_button() -> void:
	# Overlaps the panel's upper-right corner. It lives on the root (not inside the panel's
	# container, which would stretch it) and is repositioned each frame onto the centred
	# panel's corner (see _update_close_button_position). Its own pressed signal closes the
	# dialog, so its click never falls through to the typewriter-skip path.
	_close_button = Button.new()
	_close_button.name = "CloseButton"
	_close_button.text = "X"
	_close_button.focus_mode = Control.FOCUS_NONE
	_close_button.size = Vector2(CLOSE_BUTTON_SIZE, CLOSE_BUTTON_SIZE)
	_close_button.custom_minimum_size = Vector2(CLOSE_BUTTON_SIZE, CLOSE_BUTTON_SIZE)
	_close_button.add_theme_font_size_override("font_size", FONT_CLOSE)
	_apply_close_button_style()
	_close_button.pressed.connect(_on_close_button_pressed)
	_close_button.gui_input.connect(_on_dialog_surface_gui_input)
	# Added last to the root so it renders above the panel in its corner.
	add_child(_close_button)


## Pins the close cross onto the centred panel's upper-right corner (slightly overlapping).
func _update_close_button_position() -> void:
	if _close_button == null or _panel == null:
		return
	var corner: Vector2 = _panel.global_position + Vector2(_panel.size.x, 0.0)
	_close_button.global_position = corner - _close_button.size * 0.5


# --- Public API --------------------------------------------------------------

## Opens (or replaces) a dialog. `context_id` identifies the conversation so callers can
## check is_open_for(). `choices` are parsed defensively (see the class comment). The choice
## handler is invoked as choice_handler.call(choice_id, source_global_position). The closed
## handler is invoked as closed_handler.call(reason) exactly once when the dialog closes.
func open_dialog(
	context_id: StringName,
	speaker_name: String,
	body_text: String,
	portrait: Texture2D,
	choices: Array[Dictionary],
	choice_handler: Callable = Callable(),
	closed_handler: Callable = Callable(),
	options: Dictionary = {}
) -> void:
	var blocks_input: bool = bool(options.get("blocks_gameplay_input", true))
	# Replacing an existing context: let the previous owner clean up, but keep any input lock
	# and reference so nothing leaks.
	if _open:
		_invoke_closed_handler(&"replaced")
	else:
		_apply_input_lock(blocks_input)

	_context_id = context_id
	_choice_handler = choice_handler
	_closed_handler = closed_handler
	_open = true
	_open_frame = Engine.get_frames_drawn()
	_stick_latched = false

	_portrait.texture = portrait
	_name_label.text = speaker_name
	_set_body_content(body_text, options.get("body_icons", {}) as Dictionary)
	_total_chars = _body_label.get_total_character_count()
	_body_label.visible_characters = 0

	_set_choices(choices)
	_start_typewriter()

	visible = true
	set_process(true)
	set_process_unhandled_input(true)
	# Position the close cross once layout of the freshly-shown panel is settled, so it does
	# not flash at the corner for a frame before _process takes over.
	_update_close_button_position.call_deferred()


## Rebuilds the choice rows without touching the typewriter. Selection is preserved by id
## (preferred_choice_id wins if given); if that row is gone the nearest remaining row is
## selected, otherwise the first.
func refresh_choices(choices: Array[Dictionary], preferred_choice_id: String = "") -> void:
	if not _open:
		return
	var keep_id: String = preferred_choice_id
	if keep_id == "" and _selected_index >= 0 and _selected_index < _choices.size():
		keep_id = _choices[_selected_index].id
	var previous_index: int = _selected_index

	_set_choices(choices)

	if not _choices_revealed:
		return
	_choice_list.visible = true
	var target: int = _index_of_choice(keep_id)
	if target < 0:
		target = _nearest_selectable_index(previous_index)
	_set_selection(target)


func close_dialog(reason: StringName = &"closed") -> void:
	if not _open:
		return
	_open = false
	_typing = false
	visible = false
	set_process(false)
	set_process_unhandled_input(false)
	_release_input_lock()
	_invoke_closed_handler(reason)
	_context_id = &""


func is_open() -> bool:
	return _open


func is_open_for(context_id: StringName) -> bool:
	return _open and _context_id == context_id


## Reveals the whole body immediately, then shows the choices.
func finish_typewriter() -> void:
	if not _open or not _typing:
		return
	_typing = false
	_body_label.visible_characters = -1
	_reveal_choices()


func _set_body_content(body_text: String, body_icons: Dictionary) -> void:
	if body_icons.is_empty():
		_body_label.text = body_text
		return
	_body_label.clear()
	var remaining: String = body_text
	while remaining != "":
		var match_key: String = ""
		var match_index: int = -1
		for raw_key: Variant in body_icons.keys():
			var key: String = str(raw_key)
			if key == "":
				continue
			var index: int = remaining.find(key)
			if index >= 0 and (match_index < 0 or index < match_index):
				match_index = index
				match_key = key
		if match_index < 0:
			_body_label.append_text(remaining)
			break
		if match_index > 0:
			_body_label.append_text(remaining.substr(0, match_index))
		var texture: Texture2D = body_icons.get(match_key, null) as Texture2D
		if texture != null:
			_body_label.add_image(texture, 32, 32)
		remaining = remaining.substr(match_index + match_key.length())


# --- Typewriter --------------------------------------------------------------

func _start_typewriter() -> void:
	_choices_revealed = false
	_choice_list.visible = false
	_selected_index = -1
	_typed_chars = 0.0
	if _total_chars <= 0:
		_typing = false
		_body_label.visible_characters = -1
		_reveal_choices()
		return
	_typing = true
	_body_label.visible_characters = 0


func _reveal_choices() -> void:
	if _choices_revealed:
		return
	_choices_revealed = true
	_choice_list.visible = true
	_set_selection(_first_selectable_index())


func _process(delta: float) -> void:
	if not _open:
		return
	_update_close_button_position()
	if _typing:
		_typed_chars += characters_per_second * delta
		var shown: int = int(_typed_chars)
		if shown >= _total_chars:
			_typing = false
			_body_label.visible_characters = -1
			_reveal_choices()
		else:
			_body_label.visible_characters = shown
		return
	_poll_stick_navigation()


func _poll_stick_navigation() -> void:
	if not _choices_revealed:
		return
	var axis: float = _strongest_left_stick_y()
	if absf(axis) < STICK_THRESHOLD:
		_stick_latched = false
		return
	if _stick_latched:
		return
	_stick_latched = true
	_move_selection(1 if axis > 0.0 else -1)


func _strongest_left_stick_y() -> float:
	var strongest: float = 0.0
	for device: int in Input.get_connected_joypads():
		var value: float = Input.get_joy_axis(device, JOY_AXIS_LEFT_Y)
		if absf(value) > absf(strongest):
			strongest = value
	return strongest


# --- Choice rows -------------------------------------------------------------

func _set_choices(choices: Array[Dictionary]) -> void:
	for child: Node in _choice_list.get_children():
		_choice_list.remove_child(child)
		child.queue_free()
	_choices.clear()
	# All rows are rebuilt unselected, so the old index no longer maps to a styled button.
	# Callers re-apply the selection afterwards (this also forces a fresh highlight when the
	# preserved selection lands on the same index number).
	_selected_index = -1
	for raw_choice: Dictionary in choices:
		var choice: Choice = _parse_choice(raw_choice)
		if choice == null:
			continue
		_choices.append(choice)
		var button: Button = _build_choice_row(choice)
		choice.button = button
		_choice_list.add_child(button)
		button.visible = choice.visible


## Parses a raw choice dictionary into a validated Choice, or null when it is malformed
## (no usable id). Centralises all untyped dictionary access in one place.
func _parse_choice(raw: Dictionary) -> Choice:
	var id: String = str(raw.get("id", ""))
	if id == "":
		return null
	var choice: Choice = Choice.new()
	choice.id = id
	choice.label = str(raw.get("label", ""))
	choice.icon = raw.get("icon", null) as Texture2D
	choice.price_text = str(raw.get("price_text", ""))
	choice.currency_icon = raw.get("currency_icon", null) as Texture2D
	choice.icon_badge_text = str(raw.get("icon_badge_text", ""))
	choice.visible = bool(raw.get("visible", true))
	choice.enabled = bool(raw.get("enabled", true))
	choice.close_on_select = bool(raw.get("close_on_select", false))
	return choice


func _build_choice_row(choice: Choice) -> Button:
	var button: Button = Button.new()
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(0.0, CHOICE_ROW_HEIGHT)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_apply_choice_row_style(button, false, choice.enabled)
	button.pressed.connect(_on_choice_button_pressed.bind(choice.id))
	button.mouse_entered.connect(_on_choice_button_hovered.bind(choice.id))
	button.gui_input.connect(_on_dialog_surface_gui_input)

	var row: HBoxContainer = HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 8.0
	row.offset_right = -8.0
	row.add_theme_constant_override("separation", 10)
	button.add_child(row)

	row.add_child(_build_icon_cell(choice))
	row.add_child(_build_price_cell(choice))

	var label: Label = Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.text = choice.label
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.size_flags_vertical = Control.SIZE_FILL
	label.add_theme_font_size_override("font_size", FONT_LABEL)
	label.modulate = Color.WHITE if choice.enabled else Color(0.6, 0.6, 0.62)
	row.add_child(label)
	return button


func _build_icon_cell(choice: Choice) -> Control:
	var cell: Control = Control.new()
	cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.custom_minimum_size = Vector2(CHOICE_ICON_CELL_WIDTH, CHOICE_ROW_HEIGHT)
	cell.size_flags_vertical = Control.SIZE_FILL

	var icon: TextureRect = TextureRect.new()
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.texture = choice.icon
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon.offset_left = CHOICE_ICON_INSET
	icon.offset_top = CHOICE_ICON_INSET
	icon.offset_right = -CHOICE_ICON_INSET
	icon.offset_bottom = -CHOICE_ICON_INSET
	icon.modulate = Color.WHITE if choice.enabled else Color(0.55, 0.55, 0.58)
	cell.add_child(icon)

	if choice.icon_badge_text != "":
		var badge: Label = Label.new()
		badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		badge.text = choice.icon_badge_text
		badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		badge.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		badge.add_theme_font_size_override("font_size", FONT_BADGE)
		badge.add_theme_color_override("font_color", Color.WHITE)
		badge.add_theme_color_override("font_shadow_color", Color.BLACK)
		badge.add_theme_constant_override("shadow_offset_x", 1)
		badge.add_theme_constant_override("shadow_offset_y", 1)
		badge.set_anchors_preset(Control.PRESET_FULL_RECT)
		badge.offset_right = -2.0
		badge.offset_bottom = -1.0
		cell.add_child(badge)
	return cell


## Fixed-width price cell. An empty price leaves the cell blank without collapsing the
## column, so every label starts at the same X.
func _build_price_cell(choice: Choice) -> Control:
	var cell: HBoxContainer = HBoxContainer.new()
	cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.custom_minimum_size = Vector2(CHOICE_PRICE_CELL_WIDTH, CHOICE_ROW_HEIGHT)
	cell.alignment = BoxContainer.ALIGNMENT_END
	cell.add_theme_constant_override("separation", 4)

	var price: Label = Label.new()
	price.mouse_filter = Control.MOUSE_FILTER_IGNORE
	price.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	price.text = choice.price_text
	price.add_theme_font_size_override("font_size", FONT_PRICE)
	price.modulate = Color.WHITE if choice.enabled else Color(0.6, 0.6, 0.62)
	cell.add_child(price)

	if choice.price_text != "" and choice.currency_icon != null:
		var currency: TextureRect = TextureRect.new()
		currency.mouse_filter = Control.MOUSE_FILTER_IGNORE
		currency.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		currency.texture = choice.currency_icon
		currency.custom_minimum_size = Vector2(30.0, 30.0)
		currency.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		currency.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		currency.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		currency.modulate = Color.WHITE if choice.enabled else Color(0.6, 0.6, 0.62)
		cell.add_child(currency)
	return cell


# --- Selection ---------------------------------------------------------------

func _set_selection(index: int) -> void:
	if index == _selected_index:
		if index >= 0:
			_ensure_selected_visible()
		return
	if _selected_index >= 0 and _selected_index < _choices.size():
		var previous: Choice = _choices[_selected_index]
		if previous.button != null:
			_apply_choice_row_style(previous.button, false, previous.enabled)
	_selected_index = index
	if index >= 0 and index < _choices.size():
		var current: Choice = _choices[index]
		if current.button != null:
			_apply_choice_row_style(current.button, true, current.enabled)
		_ensure_selected_visible()


func _ensure_selected_visible() -> void:
	if _selected_index < 0 or _selected_index >= _choices.size():
		return
	var button: Button = _choices[_selected_index].button
	if button != null:
		_choice_scroll.ensure_control_visible(button)


func _move_selection(step: int) -> void:
	if _choices.is_empty():
		return
	var count: int = _choices.size()
	var start: int = _selected_index
	if start < 0:
		start = -1 if step > 0 else count
	var index: int = start
	for _i: int in range(count):
		index = wrapi(index + step, 0, count)
		if _choices[index].visible:
			_set_selection(index)
			return


func _activate_selected() -> void:
	if _selected_index < 0 or _selected_index >= _choices.size():
		return
	_activate_choice(_choices[_selected_index])


func _activate_choice(choice: Choice) -> void:
	if not choice.visible or not choice.enabled:
		return
	var center: Vector2 = Vector2.ZERO
	if choice.button != null:
		center = choice.button.get_global_rect().get_center()
	if _choice_handler.is_valid():
		_choice_handler.call(choice.id, center)
	if choice.close_on_select:
		close_dialog(&"selected")


func _first_selectable_index() -> int:
	# Prefer the first enabled row; fall back to the first visible row.
	var first_visible: int = -1
	for i: int in range(_choices.size()):
		if not _choices[i].visible:
			continue
		if first_visible < 0:
			first_visible = i
		if _choices[i].enabled:
			return i
	return first_visible


func _nearest_selectable_index(around: int) -> int:
	if _choices.is_empty():
		return -1
	var count: int = _choices.size()
	var clamped: int = clampi(around, 0, count - 1)
	for offset: int in range(count):
		var down: int = clamped + offset
		if down < count and _choices[down].visible:
			return down
		var up: int = clamped - offset
		if up >= 0 and _choices[up].visible:
			return up
	return _first_selectable_index()


func _index_of_choice(id: String) -> int:
	if id == "":
		return -1
	for i: int in range(_choices.size()):
		if _choices[i].id == id and _choices[i].visible:
			return i
	return -1


# --- Input -------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not _open:
		return
	# The input that opened the dialog must not also skip it or activate a choice.
	if Engine.get_frames_drawn() == _open_frame:
		return

	if event is InputEventKey:
		var key_event: InputEventKey = event
		if key_event.pressed and not key_event.echo:
			_handle_key(key_event)
		return

	if event is InputEventJoypadButton:
		var pad_event: InputEventJoypadButton = event
		if pad_event.pressed:
			_handle_pad_button(pad_event.button_index)
		return


func _handle_key(event: InputEventKey) -> void:
	var keycode: int = event.physical_keycode
	if keycode == KEY_ESCAPE:
		close_dialog(&"escape")
		get_viewport().set_input_as_handled()
		return
	if _typing:
		finish_typewriter()
		get_viewport().set_input_as_handled()
		return
	if keycode == KEY_UP:
		_move_selection(-1)
		get_viewport().set_input_as_handled()
	elif keycode == KEY_DOWN:
		_move_selection(1)
		get_viewport().set_input_as_handled()
	elif keycode == KEY_ENTER or keycode == KEY_KP_ENTER or keycode == KEY_SPACE:
		_activate_selected()
		get_viewport().set_input_as_handled()


func _handle_pad_button(button_index: int) -> void:
	if button_index == JOY_BUTTON_B:
		close_dialog(&"cancel")
		get_viewport().set_input_as_handled()
		return
	if _typing:
		# Any pressed button other than B completes the text.
		finish_typewriter()
		get_viewport().set_input_as_handled()
		return
	if button_index == JOY_BUTTON_DPAD_UP:
		_move_selection(-1)
		get_viewport().set_input_as_handled()
	elif button_index == JOY_BUTTON_DPAD_DOWN:
		_move_selection(1)
		get_viewport().set_input_as_handled()
	elif button_index == JOY_BUTTON_A:
		_activate_selected()
		get_viewport().set_input_as_handled()


## Mouse handling shared by every surface of the modal (backdrop, panel, body, choice rows,
## close cross): right-click always closes, left-click completes the typewriter while typing.
## It is connected to all of them because each one stops mouse events, so a surface without
## it would silently swallow the right-click instead of closing. Clicks never reach the world.
func _on_dialog_surface_gui_input(event: InputEvent) -> void:
	if not _open or Engine.get_frames_drawn() == _open_frame:
		return
	if not (event is InputEventMouseButton):
		return
	var mb: InputEventMouseButton = event
	if not mb.pressed:
		return
	if mb.button_index == MOUSE_BUTTON_RIGHT:
		accept_event()
		close_dialog(&"cancel")
		return
	if mb.button_index == MOUSE_BUTTON_LEFT and _typing:
		finish_typewriter()
		accept_event()


func _on_choice_button_pressed(id: String) -> void:
	if not _open:
		return
	if _typing:
		# A click while typing completes the text instead of selecting.
		finish_typewriter()
		return
	var index: int = _index_of_choice(id)
	if index < 0:
		return
	_set_selection(index)
	_activate_choice(_choices[index])


func _on_choice_button_hovered(id: String) -> void:
	if not _open or _typing or not _choices_revealed:
		return
	var index: int = _index_of_choice(id)
	if index >= 0:
		_set_selection(index)


func _on_close_button_pressed() -> void:
	close_dialog(&"close_button")


# --- Gameplay input lock -----------------------------------------------------

func _resolve_player_controller() -> PlayerController:
	if _player_controller == null or not is_instance_valid(_player_controller):
		var scene: Node = get_tree().current_scene
		var node: Node = scene.get_node_or_null("Player/PlayerController") if scene != null else null
		_player_controller = node as PlayerController
	return _player_controller


func _apply_input_lock(blocks_input: bool) -> void:
	if not blocks_input:
		return
	var controller: PlayerController = _resolve_player_controller()
	if controller == null:
		return
	# Remember whether input was already locked, so closing restores the prior state instead
	# of blindly unlocking a lock that existed before this dialog.
	_input_lock_previous = controller.is_cutscene_input_locked()
	controller.set_cutscene_input_locked(true)
	_input_lock_applied = true


func _release_input_lock() -> void:
	if not _input_lock_applied:
		return
	_input_lock_applied = false
	var controller: PlayerController = _resolve_player_controller()
	if controller == null:
		return
	controller.set_cutscene_input_locked(_input_lock_previous)


func _invoke_closed_handler(reason: StringName) -> void:
	var handler: Callable = _closed_handler
	_choice_handler = Callable()
	_closed_handler = Callable()
	if handler.is_valid():
		handler.call(reason)


# --- Styling -----------------------------------------------------------------

func _panel_background_style() -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.075, 0.08, 0.97)
	style.set_border_width_all(3)
	style.border_color = Color(0.24, 0.26, 0.27)
	style.set_corner_radius_all(8)
	return style


func _apply_choice_row_style(button: Button, selected: bool, enabled: bool) -> void:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(0.11, 0.12, 0.13, 0.92)
	style.set_border_width_all(2)
	style.border_color = Color(0.26, 0.29, 0.31)
	style.set_corner_radius_all(4)
	if not enabled:
		style.bg_color = Color(0.06, 0.065, 0.07, 0.85)
		style.border_color = Color(0.16, 0.17, 0.18, 0.9)
	if selected:
		style.bg_color = Color(0.17, 0.19, 0.19, 0.96)
		style.set_border_width_all(4)
		style.border_color = Color(0.92, 0.78, 0.34)
	for state_name: String in ["normal", "hover", "pressed", "focus", "disabled"]:
		button.add_theme_stylebox_override(state_name, style)


func _apply_close_button_style() -> void:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	# Warm brown, matching the mockup's close cross.
	style.bg_color = Color(0.42, 0.24, 0.12, 0.98)
	style.set_border_width_all(2)
	style.border_color = Color(0.62, 0.4, 0.22)
	style.set_corner_radius_all(6)
	_close_button.add_theme_color_override("font_color", Color(0.96, 0.92, 0.84))
	for state_name: String in ["normal", "hover", "pressed", "focus", "disabled"]:
		_close_button.add_theme_stylebox_override(state_name, style)
