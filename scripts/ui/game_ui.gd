extends CanvasLayer

const ItemSlotScript = preload("res://scripts/ui/item_slot.gd")
const QUICK_SLOT_COUNT: int = 8
const INVENTORY_SLOT_COUNT: int = 32
const INVENTORY_COLUMNS: int = 8

@onready var toolbar_slots: HBoxContainer = $"bottom anchor/toolbar"
@onready var toolbar_anchor: Control = $"bottom anchor"
@onready var inventory_modal: Panel = $Modals/inventoryModal
@onready var close_button: Button = $Modals/inventoryModal/CloseButton
@onready var inventory_content: VBoxContainer = $Modals/inventoryModal/MarginContainer/Content
@onready var tile_hover_info: Node = $"../Controls/TileHoverInfo"

var inventory_slots: Array[String] = []
var selected_quick_index: int = 0
var _toolbar_slot_nodes: Array[ItemSlot] = []
var _inventory_slot_nodes: Array[ItemSlot] = []
var _startup_loading_overlay: Control
var _startup_loading_label: Label
var _startup_loading_bar: ProgressBar
var _startup_loading_value: float = 0.0
var _startup_loading_finished: bool = false

func _ready() -> void:
	layer = 50
	_create_startup_loading_overlay()
	_setup_starting_inventory()
	close_button.pressed.connect(_hide_inventory)
	_build_toolbar()
	_build_inventory()
	_refresh_all_slots()
	_set_inventory_open(false)
	call_deferred("_connect_startup_loading_signals")

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mouse_event: InputEventMouseButton = event
		if not inventory_modal.visible and mouse_event.pressed and not mouse_event.ctrl_pressed:
			if mouse_event.button_index == MOUSE_BUTTON_WHEEL_UP:
				_step_selected_quick_slot(-1)
				get_viewport().set_input_as_handled()
			elif mouse_event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_step_selected_quick_slot(1)
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

	if key_event.keycode == KEY_I or key_event.keycode == KEY_E:
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

	var from_item := inventory_slots[from_slot]
	inventory_slots[from_slot] = inventory_slots[to_slot]
	inventory_slots[to_slot] = from_item
	_refresh_all_slots()

func select_quick_slot(index: int) -> void:
	if index < 0 or index >= QUICK_SLOT_COUNT:
		return
	selected_quick_index = index
	_refresh_all_slots()

func get_selected_quick_item_id() -> String:
	if selected_quick_index < 0 or selected_quick_index >= inventory_slots.size():
		return ""
	return inventory_slots[selected_quick_index]

func get_selected_quick_item_def() -> Dictionary:
	return ItemCatalog.get_item_def(get_selected_quick_item_id())

func selected_quick_item_places_tile() -> bool:
	return ItemCatalog.item_places_tile(get_selected_quick_item_id())

func _setup_starting_inventory() -> void:
	inventory_slots.resize(INVENTORY_SLOT_COUNT)
	for i in range(INVENTORY_SLOT_COUNT):
		inventory_slots[i] = ""
	inventory_slots[0] = "sword"
	inventory_slots[1] = "bomb"
	inventory_slots[2] = "water"
	inventory_slots[3] = "wall"

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
	inventory_modal.visible = is_open
	toolbar_anchor.visible = not is_open
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
			_on_startup_loading_progress(0.45, "Flow field ready")

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
	for i in range(_toolbar_slot_nodes.size()):
		_apply_slot_item(_toolbar_slot_nodes[i], i)

	for i in range(_inventory_slot_nodes.size()):
		_apply_slot_item(_inventory_slot_nodes[i], i)

func _apply_slot_item(slot: ItemSlot, slot_index: int) -> void:
	var item_id := inventory_slots[slot_index]
	var item_def := ItemCatalog.get_item_def(item_id)
	if not item_def.is_empty():
		slot.set_item(item_def)
	else:
		slot.set_item({})
	slot.set_selected(slot_index == selected_quick_index)

func _clear_container(container: Container) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()

func _step_selected_quick_slot(direction: int) -> void:
	var next_index := selected_quick_index + direction
	if next_index < 0:
		next_index = QUICK_SLOT_COUNT - 1
	elif next_index >= QUICK_SLOT_COUNT:
		next_index = 0
	select_quick_slot(next_index)

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
