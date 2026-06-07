extends PanelContainer
class_name ItemSlot

const ITEM_TEXTURE: Texture2D = preload("res://assets/sprites/legval/items.png")

var game_ui: Node
var slot_type: String = "inventory"
var slot_index: int = -1
var item_data: Dictionary = {}
var selected: bool = false
var disabled: bool = false

var _icon: TextureRect
var _key_label: Label

func setup(owner_ui: Node, type: String, index: int = -1) -> void:
	game_ui = owner_ui
	slot_type = type
	slot_index = index
	_build()
	_refresh()

func set_item(data: Dictionary) -> void:
	item_data = data
	_refresh()

func set_selected(value: bool) -> void:
	selected = value
	_refresh()

func set_disabled(value: bool) -> void:
	disabled = value
	_refresh()

func _build() -> void:
	custom_minimum_size = Vector2(56, 56)
	size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mouse_filter = Control.MOUSE_FILTER_STOP
	theme_type_variation = &"ItemSlot"

	if _icon:
		return

	var stack := Control.new()
	stack.custom_minimum_size = Vector2(56, 56)
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(stack)

	_icon = TextureRect.new()
	_icon.custom_minimum_size = Vector2(40, 40)
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	_icon.offset_left = 8.0
	_icon.offset_top = 8.0
	_icon.offset_right = -8.0
	_icon.offset_bottom = -8.0
	stack.add_child(_icon)

	_key_label = Label.new()
	_key_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_key_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_key_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_key_label.add_theme_font_size_override("font_size", 11)
	_key_label.add_theme_color_override("font_color", Color(0.86, 0.89, 0.92))
	_key_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_key_label.offset_left = 3.0
	_key_label.offset_top = 2.0
	_key_label.offset_right = 16.0
	_key_label.offset_bottom = 16.0
	stack.add_child(_key_label)

func _refresh() -> void:
	if not _icon:
		return

	if item_data.is_empty():
		_icon.texture = null
		tooltip_text = ""
	else:
		_icon.texture = _atlas_for_frame(int(item_data.get("frame", 0)))
		tooltip_text = str(item_data.get("name", ""))
	_icon.modulate = Color(0.45, 0.45, 0.45, 0.55) if disabled else Color(1.0, 1.0, 1.0, 1.0)

	if slot_index >= 0 and slot_index < 8:
		_key_label.text = str(slot_index + 1)
	else:
		_key_label.text = ""

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.10, 0.11, 0.12, 0.92)
	style.border_width_left = 2
	style.border_width_top = 2
	style.border_width_right = 2
	style.border_width_bottom = 2
	style.border_color = Color(0.30, 0.33, 0.35)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	if selected:
		style.bg_color = Color(0.16, 0.18, 0.18, 0.96)
		style.border_width_left = 4
		style.border_width_top = 4
		style.border_width_right = 4
		style.border_width_bottom = 4
		style.border_color = Color(0.92, 0.78, 0.34)
	if disabled:
		style.bg_color = Color(0.055, 0.06, 0.065, 0.88)
		style.border_color = Color(0.15, 0.16, 0.17, 0.9)
	add_theme_stylebox_override("panel", style)

func _atlas_for_frame(frame: int) -> AtlasTexture:
	var atlas := AtlasTexture.new()
	atlas.atlas = ITEM_TEXTURE
	atlas.region = Rect2(frame * 32, 0, 32, 32)
	return atlas

func _get_drag_data(_at_position: Vector2) -> Variant:
	if item_data.is_empty() or disabled:
		return null

	var preview := TextureRect.new()
	preview.texture = _atlas_for_frame(int(item_data.get("frame", 0)))
	preview.custom_minimum_size = Vector2(40, 40)
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	set_drag_preview(preview)

	return {
		"item_id": str(item_data.get("id", "")),
		"from_slot": slot_index,
	}

func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if slot_index < 0 or not (data is Dictionary):
		return false
	var drop_data: Dictionary = data
	return drop_data.has("from_slot")

func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if not (data is Dictionary):
		return
	var drop_data: Dictionary = data
	if game_ui and game_ui.has_method("move_inventory_item"):
		game_ui.call("move_inventory_item", int(drop_data.get("from_slot", -1)), slot_index)

func _gui_input(event: InputEvent) -> void:
	if slot_type != "quick":
		return
	if event is InputEventMouseButton:
		var mouse_event: InputEventMouseButton = event
		if mouse_event.button_index == MOUSE_BUTTON_LEFT and mouse_event.pressed:
			if disabled:
				accept_event()
				return
			if slot_index >= 0 and slot_index < 8 and game_ui and game_ui.has_method("select_quick_slot"):
				game_ui.call("select_quick_slot", slot_index)
				accept_event()
