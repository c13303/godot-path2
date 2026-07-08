extends PanelContainer
class_name ItemSlot

const ITEM_TEXTURE: Texture2D = preload("res://assets/sprites/legval/items.png")

var game_ui: Node
var slot_type: String = "inventory"
var slot_index: int = -1
var item_data: Dictionary = {}
var quantity: int = 0
var selected: bool = false
var disabled: bool = false

var _icon: TextureRect
var _key_label: Label
var _quantity_label: Label

func setup(owner_ui: Node, type: String, index: int = -1) -> void:
	game_ui = owner_ui
	slot_type = type
	slot_index = index
	_build()
	_refresh()

func set_item(data: Dictionary, item_quantity: int = 0) -> void:
	item_data = data
	quantity = item_quantity
	_refresh()

func set_selected(value: bool) -> void:
	selected = value
	_refresh()

func set_disabled(value: bool) -> void:
	disabled = value
	_refresh()

## White flash + scale punch, played when an item lands in this slot.
func flash() -> void:
	pivot_offset = size * 0.5
	modulate = Color(2.6, 2.6, 2.6, 1.0)
	scale = Vector2(1.25, 1.25)
	var tween: Tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(self, "modulate", Color(1.0, 1.0, 1.0, 1.0), 0.35).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

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

	_quantity_label = Label.new()
	_quantity_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_quantity_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_quantity_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_quantity_label.add_theme_font_size_override("font_size", 14)
	_quantity_label.add_theme_color_override("font_color", Color.WHITE)
	_quantity_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	_quantity_label.add_theme_constant_override("shadow_offset_x", 1)
	_quantity_label.add_theme_constant_override("shadow_offset_y", 1)
	_quantity_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_quantity_label.offset_left = 2.0
	_quantity_label.offset_top = 2.0
	_quantity_label.offset_right = -4.0
	_quantity_label.offset_bottom = -2.0
	stack.add_child(_quantity_label)

func _refresh() -> void:
	if not _icon:
		return

	if item_data.is_empty():
		_icon.texture = null
		tooltip_text = ""
	else:
		_icon.texture = _atlas_for_frame(int(item_data.get("frame", 0)))
		tooltip_text = "%s x%d" % [str(item_data.get("name", "")), quantity]
	_quantity_label.text = str(quantity) if not item_data.is_empty() and quantity > 1 else ""
	_icon.modulate = Color(0.45, 0.45, 0.45, 0.55) if disabled else Color(1.0, 1.0, 1.0, 1.0)

	if slot_index >= 0 and slot_index < 8:
		_key_label.text = str(slot_index + 1)
	else:
		_key_label.text = ""

	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(0.10, 0.11, 0.12, 0.92)
	style.border_color = Color(0.30, 0.33, 0.35)
	style.set_border_width_all(2)
	style.set_corner_radius_all(4)
	if selected:
		style.bg_color = Color(0.16, 0.18, 0.18, 0.96)
		style.set_border_width_all(4)
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
	# Quickbar slots are fixed menu buttons, not inventory contents, so they never drag.
	if slot_type == "quick" or item_data.is_empty() or disabled:
		return null

	var preview := TextureRect.new()
	preview.texture = _atlas_for_frame(int(item_data.get("frame", 0)))
	preview.custom_minimum_size = Vector2(40, 40)
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	set_drag_preview(preview)

	return {
		"item_id": str(item_data.get("id", "")),
		"from_slot": slot_index,
	}

func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	# Only backpack slots accept dropped items; the quickbar menu slots do not.
	if slot_type == "quick" or slot_index < 0 or not (data is Dictionary):
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
			# Clicking a quickbar slot activates the quickbar and opens that slot's drop-up menu.
			if slot_index >= 0 and game_ui and game_ui.has_method("activate_quickbar_slot"):
				game_ui.call("activate_quickbar_slot", slot_index)
				accept_event()
