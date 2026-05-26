extends CanvasLayer

const ItemSlotScript = preload("res://ui/item_slot.gd")
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

func _ready() -> void:
	layer = 50
	_setup_starting_inventory()
	close_button.pressed.connect(_hide_inventory)
	_build_toolbar()
	_build_inventory()
	_refresh_all_slots()
	_set_inventory_open(false)

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

func _set_inventory_open(is_open: bool) -> void:
	inventory_modal.visible = is_open
	toolbar_anchor.visible = not is_open
	if tile_hover_info and tile_hover_info.has_method("set_enabled"):
		tile_hover_info.call("set_enabled", not is_open)

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
