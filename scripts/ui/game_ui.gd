extends CanvasLayer

const ItemSlotScript = preload("res://scripts/ui/item_slot.gd")
const ITEM_TEXTURE: Texture2D = preload("res://assets/sprites/legval/items.png")
const QUICK_SLOT_COUNT: int = 8
const INVENTORY_SLOT_COUNT: int = 32
const INVENTORY_COLUMNS: int = 8

const PURCHASE_FLIGHT_SIZE: Vector2 = Vector2(40.0, 40.0)
const PURCHASE_FLIGHT_DURATION: float = 0.55

@onready var toolbar_slots: HBoxContainer = $"bottom anchor/toolbar"
@onready var toolbar_anchor: Control = $"bottom anchor"
@onready var inventory_modal: Panel = $Modals/inventoryModal
@onready var close_button: Button = $Modals/inventoryModal/CloseButton
@onready var inventory_content: VBoxContainer = $Modals/inventoryModal/MarginContainer/Content
@onready var tile_hover_info: Node = $"../CPP/TileHoverInfo"
@onready var day_toggle: Button = $"top anchor/dayToggle"

const MOONSUN_TEXTURE: Texture2D = preload("res://assets/sprites/legval/moonsun.png")
const MOONSUN_TILE_SIZE: int = 64
var _sun_icon: AtlasTexture
var _moon_icon: AtlasTexture

var inventory_slots: Array[Dictionary] = []
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
	_setup_day_toggle()
	_build_toolbar()
	_build_inventory()
	_refresh_all_slots()
	_set_inventory_open(false)
	call_deferred("_connect_startup_loading_signals")

func _setup_day_toggle() -> void:
	_sun_icon = AtlasTexture.new()
	_sun_icon.atlas = MOONSUN_TEXTURE
	_sun_icon.region = Rect2(0, 0, MOONSUN_TILE_SIZE, MOONSUN_TILE_SIZE)
	_moon_icon = AtlasTexture.new()
	_moon_icon.atlas = MOONSUN_TEXTURE
	_moon_icon.region = Rect2(MOONSUN_TILE_SIZE, 0, MOONSUN_TILE_SIZE, MOONSUN_TILE_SIZE)

	day_toggle.pressed.connect(_on_day_toggle_pressed)
	GameState.mode_changed.connect(_on_game_mode_changed)
	_update_day_toggle_icon(GameState.is_night)

func _on_day_toggle_pressed() -> void:
	GameState.toggle()

func _on_game_mode_changed(is_night: bool) -> void:
	_update_day_toggle_icon(is_night)
	_refresh_all_slots()

func _update_day_toggle_icon(is_night: bool) -> void:
	# Icon reflects the current mode: sun during day, moon during night.
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
	selected_quick_index = index
	_refresh_all_slots()

func get_selected_quick_item_id() -> String:
	if selected_quick_index < 0 or selected_quick_index >= inventory_slots.size():
		return ""
	return _slot_item_id(inventory_slots[selected_quick_index])

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
	_refresh_all_slots()
	return true

func get_selected_quick_item_def() -> Dictionary:
	return ItemCatalog.get_item_def(get_selected_quick_item_id())

func selected_quick_item_places_tile() -> bool:
	var item_id: String = get_selected_quick_item_id()
	return ItemCatalog.is_placeable(item_id) and not is_item_disabled_for_placement(item_id)

func is_item_disabled_for_placement(item_id: String) -> bool:
	return GameState.is_night and ItemCatalog.is_placeable(item_id)

func _setup_starting_inventory() -> void:
	inventory_slots.resize(INVENTORY_SLOT_COUNT)
	for i in range(INVENTORY_SLOT_COUNT):
		inventory_slots[i] = _empty_slot()
	#add_inventory("sword", 1)
	add_inventory("spray", 1)
	#add_inventory("rose", 5)
	#add_inventory("turret1", 1)

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

# Like add_inventory, but the item visually flies from source_global_position
# (e.g. the clicked shop icon) along a curve to its visible quick-slot. Items
# landing outside the visible quick-slots use the toolbar center as a fallback.
# The actual increment + a white slot flash happen on arrival.
# Capacity is validated up front so the deferred add cannot silently fail.
func add_inventory_animated(item_id: String, quantity: int, source_global_position: Vector2) -> bool:
	if item_id == "" or quantity <= 0:
		return false
	if not can_add_inventory(item_id, quantity):
		return false
	var item_def: Dictionary = ItemCatalog.get_item_def(item_id)
	if item_def.is_empty():
		# No icon to fly with; fall back to an instant add.
		return add_inventory(item_id, quantity)
	var start_position: Vector2 = source_global_position
	var end_position: Vector2 = _purchase_flight_target(item_id)
	_spawn_purchase_flight(int(item_def.get("frame", 0)), start_position, end_position, item_id, quantity)
	return true

func _purchase_flight_target(item_id: String) -> Vector2:
	var landing_slot: int = _predict_landing_slot(item_id)
	if (
		toolbar_anchor.visible
		and landing_slot >= 0
		and landing_slot < QUICK_SLOT_COUNT
		and landing_slot < _toolbar_slot_nodes.size()
	):
		var slot_node: ItemSlot = _toolbar_slot_nodes[landing_slot]
		if is_instance_valid(slot_node) and slot_node.is_visible_in_tree():
			return slot_node.get_global_rect().get_center()
	return toolbar_slots.get_global_rect().get_center()

# Predicts which slot add_inventory would fill first: an existing stack with
# room, otherwise the first free slot. Used to flash the landing slot.
func _predict_landing_slot(item_id: String) -> int:
	var max_stack: int = ItemCatalog.get_max_stack(item_id)
	for i in range(inventory_slots.size()):
		var slot_data: Dictionary = inventory_slots[i]
		if _slot_item_id(slot_data) == item_id and _slot_quantity(slot_data) < max_stack:
			return i
	return _first_free_slot()

func _spawn_purchase_flight(frame: int, start_position: Vector2, end_position: Vector2, item_id: String, quantity: int) -> void:
	var sprite: TextureRect = TextureRect.new()
	sprite.texture = _atlas_for_frame(frame)
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.custom_minimum_size = PURCHASE_FLIGHT_SIZE
	sprite.size = PURCHASE_FLIGHT_SIZE
	sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sprite.pivot_offset = PURCHASE_FLIGHT_SIZE * 0.5
	sprite.z_index = 100
	add_child(sprite)
	sprite.position = start_position - PURCHASE_FLIGHT_SIZE * 0.5
	sprite.scale = Vector2(0.6, 0.6)

	var distance: float = start_position.distance_to(end_position)
	var arc_height: float = clampf(distance * 0.3, 80.0, 220.0)
	var curve_position: Vector2 = (start_position + end_position) * 0.5 + Vector2(0.0, -arc_height)

	var tween: Tween = create_tween()
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tween.tween_method(
		Callable(self, "_update_purchase_flight").bind(sprite, start_position, curve_position, end_position),
		0.0,
		1.0,
		PURCHASE_FLIGHT_DURATION
	)
	tween.parallel().tween_property(sprite, "scale", Vector2.ONE, PURCHASE_FLIGHT_DURATION * 0.5).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(sprite, "rotation", TAU, PURCHASE_FLIGHT_DURATION)
	tween.tween_callback(Callable(self, "_finish_purchase_flight").bind(sprite, item_id, quantity))

func _update_purchase_flight(
	progress: float,
	sprite: TextureRect,
	start_position: Vector2,
	curve_position: Vector2,
	end_position: Vector2
) -> void:
	if not is_instance_valid(sprite):
		return
	var inverse_progress: float = 1.0 - progress
	var curved_position: Vector2 = (
		inverse_progress * inverse_progress * start_position
		+ 2.0 * inverse_progress * progress * curve_position
		+ progress * progress * end_position
	)
	sprite.position = curved_position - PURCHASE_FLIGHT_SIZE * 0.5

func _finish_purchase_flight(sprite: TextureRect, item_id: String, quantity: int) -> void:
	if is_instance_valid(sprite):
		sprite.queue_free()
	# Resolve the landing slot before mutating, then add and flash it.
	var target_index: int = _predict_landing_slot(item_id)
	add_inventory(item_id, quantity)
	_flash_slot(target_index)

# Flashes the slot at slot_index, but only if it is currently on-screen: a
# quick slot when the toolbar is shown, or a grid slot when the modal is open.
func _flash_slot(slot_index: int) -> void:
	if slot_index < 0:
		return
	var slot_node: ItemSlot = null
	if slot_index < QUICK_SLOT_COUNT:
		if toolbar_anchor.visible and slot_index < _toolbar_slot_nodes.size():
			slot_node = _toolbar_slot_nodes[slot_index]
	elif inventory_modal.visible and slot_index < _inventory_slot_nodes.size():
		slot_node = _inventory_slot_nodes[slot_index]
	if slot_node != null and is_instance_valid(slot_node):
		slot_node.flash()

func _atlas_for_frame(frame: int) -> AtlasTexture:
	var atlas: AtlasTexture = AtlasTexture.new()
	atlas.atlas = ITEM_TEXTURE
	atlas.region = Rect2(frame * 32, 0, 32, 32)
	return atlas


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
	var slot_data: Dictionary = inventory_slots[slot_index]
	var item_id: String = _slot_item_id(slot_data)
	var quantity: int = _slot_quantity(slot_data)
	var item_def: Dictionary = ItemCatalog.get_item_def(item_id)
	if not item_def.is_empty():
		slot.set_item(item_def, quantity)
	else:
		slot.set_item({}, 0)
	slot.set_disabled(is_item_disabled_for_placement(item_id))
	slot.set_selected(slot_index == selected_quick_index)

func _clear_container(container: Container) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()

func step_selected_quick_slot(direction: int) -> void:
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
