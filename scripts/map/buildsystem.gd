extends Node

const REMOVE_HOLD_SECONDS: float = 1.0
const REMOVE_PROGRESS_WIDTH: float = 6.0
const REMOVE_PROGRESS_HEIGHT_RATIO: float = 0.8

@export var floorz: TileMapLayer
@export var wallz: TileMapLayer
@export var plantz: TileMapLayer
@export var traversable_buildings: TileMapLayer
@export var blocking_buildings: TileMapLayer
@export var previewbuild: TileMapLayer
@export var plant_manager: Node
@export var building_object_manager: Node
@export var game_ui: CanvasLayer
@export var notif: Node
@export var occupied_groups: Array[String] = ["main_chars", "monsters", "player"]

var _atlas_source_id: int = -1

var _hover_active: bool = false
var _hover_cell: Vector2i
var _hover_atlas_coords: Vector2i = Vector2i(-1, -1)
var _preview_cells: Array[Vector2i] = []
var _rose_drag_active: bool = false
var _rose_drag_start_cell: Vector2i = Vector2i.ZERO
var _rose_drag_end_cell: Vector2i = Vector2i.ZERO
var _rose_drag_preview_limit: int = 0
var _plant_layer_flush_queued: bool = false
var _remove_active: bool = false
var _remove_cell: Vector2i = Vector2i.ZERO
var _remove_item_id: String = ""
var _remove_layer: TileMapLayer
var _remove_elapsed: float = 0.0
var _remove_progress: ProgressBar

func _ready() -> void:
	_resolve_atlas_source_id()
	set_process(true)
	set_process_input(true)

func _process(delta: float) -> void:
	_process_removal(delta)
	if _remove_active:
		_clear_hover()
		return

	var placeable_def: Dictionary = _selected_placeable_def()
	if _rose_drag_active:
		if _placement_disabled() or _is_inventory_open() or str(placeable_def.get("id", "")) != "rose":
			_cancel_rose_drag()
			return
		var drag_cell: Vector2i = _hovered_cell()
		var available_roses: int = _inventory_item_quantity("rose")
		if drag_cell != _rose_drag_end_cell or available_roses != _rose_drag_preview_limit:
			_rose_drag_end_cell = drag_cell
			_draw_rose_drag_preview(placeable_def, available_roses)
		return
	if _placement_disabled() or placeable_def.is_empty() or _is_inventory_open() or get_viewport().gui_get_hovered_control() != null:
		_clear_hover()
		return

	var cell: Vector2i = _hovered_cell()
	var atlas_coords: Vector2i = _atlas_coords_from_placeable(placeable_def)
	if atlas_coords == Vector2i(-1, -1):
		_clear_hover()
		return

	if _hover_active and cell == _hover_cell and atlas_coords == _hover_atlas_coords:
		return

	_clear_hover()
	_hover_cell = cell
	_hover_atlas_coords = atlas_coords
	_hover_active = true
	_draw_preview(cell, atlas_coords)

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var removal_mouse_event: InputEventMouseButton = event as InputEventMouseButton
		if removal_mouse_event.button_index == MOUSE_BUTTON_RIGHT:
			var was_removing: bool = _remove_active
			if removal_mouse_event.pressed:
				_try_start_removal()
			else:
				_cancel_removal()
			if was_removing or _remove_active:
				get_viewport().set_input_as_handled()
			return

	if event is InputEventMouseButton:
		var drag_mouse_event: InputEventMouseButton = event as InputEventMouseButton
		if drag_mouse_event.button_index == MOUSE_BUTTON_LEFT and not drag_mouse_event.pressed and _rose_drag_active:
			_finish_rose_drag()
			get_viewport().set_input_as_handled()
			return

	var placeable_def: Dictionary = _selected_placeable_def()
	if _placement_disabled() or placeable_def.is_empty() or _is_inventory_open() or get_viewport().gui_get_hovered_control() != null:
		return

	if event is InputEventMouseButton and event.pressed:
		var mouse_event: InputEventMouseButton = event
		if mouse_event.button_index == MOUSE_BUTTON_LEFT:
			if str(placeable_def.get("id", "")) == "rose":
				_start_rose_drag(placeable_def)
			else:
				_apply_placeable(placeable_def)
			get_viewport().set_input_as_handled()

func _try_start_removal() -> void:
	if GameState.is_night or _is_inventory_open() or get_viewport().gui_get_hovered_control() != null:
		return
	var cell: Vector2i = _hovered_cell()
	var removal: Dictionary = _removable_at_cell(cell)
	if removal.is_empty():
		return
	var item_id: String = str(removal.get("item_id", ""))
	if not _can_return_to_inventory(item_id):
		_notify("inventory full")
		return
	_remove_active = true
	_remove_cell = cell
	_remove_item_id = item_id
	_remove_layer = removal.get("layer") as TileMapLayer
	_remove_elapsed = 0.0
	_clear_hover()
	_create_remove_progress()

func _process_removal(delta: float) -> void:
	if not _remove_active:
		return
	if GameState.is_night or _is_inventory_open() or not Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		_cancel_removal()
		return
	if _hovered_cell() != _remove_cell:
		_cancel_removal()
		return
	var current_removal: Dictionary = _removable_at_cell(_remove_cell)
	if current_removal.is_empty() or str(current_removal.get("item_id", "")) != _remove_item_id:
		_cancel_removal()
		return
	_remove_elapsed = minf(_remove_elapsed + delta, REMOVE_HOLD_SECONDS)
	if _remove_progress:
		_remove_progress.value = (_remove_elapsed / REMOVE_HOLD_SECONDS) * 100.0
	if _remove_elapsed >= REMOVE_HOLD_SECONDS:
		_finish_removal()

func _finish_removal() -> void:
	if not _remove_active or GameState.is_night:
		_cancel_removal()
		return
	var current_removal: Dictionary = _removable_at_cell(_remove_cell)
	if current_removal.is_empty() or str(current_removal.get("item_id", "")) != _remove_item_id:
		_cancel_removal()
		return
	if not _can_return_to_inventory(_remove_item_id):
		_notify("inventory full")
		_cancel_removal()
		return

	var removed_cell: Vector2i = _remove_cell
	var removed_item_id: String = _remove_item_id
	var removed_layer: TileMapLayer = _remove_layer
	_cancel_removal()
	_remove_tile(removed_layer, removed_cell)
	if ItemCatalog.removed_item_returns_to_inventory(removed_item_id):
		game_ui.call("add_inventory", removed_item_id, 1)

func _remove_tile(layer: TileMapLayer, cell: Vector2i) -> void:
	if layer == plantz:
		if plant_manager and plant_manager.has_method("remove_plant"):
			plant_manager.call("remove_plant", cell, true)
		if plantz.get_cell_source_id(cell) >= 0:
			plantz.erase_cell(cell)
			_flush_plant_layer_visuals()
		return
	if layer == traversable_buildings or layer == blocking_buildings:
		if building_object_manager and building_object_manager.has_method("remove_building"):
			building_object_manager.call("remove_building", cell, true)
		if layer.get_cell_source_id(cell) >= 0:
			layer.erase_cell(cell)
			layer.update_internals()
		return
	layer.erase_cell(cell)
	layer.update_internals()

func _removable_at_cell(cell: Vector2i) -> Dictionary:
	var layers: Array[TileMapLayer] = [blocking_buildings, traversable_buildings, plantz, wallz]
	for layer: TileMapLayer in layers:
		if not layer or layer.get_cell_source_id(cell) < 0:
			continue
		var item_id: String = ItemCatalog.get_placeable_id_for_tile(str(layer.name), layer.get_cell_atlas_coords(cell))
		if item_id != "":
			return {"item_id": item_id, "layer": layer}
	return {}

func _can_return_to_inventory(item_id: String) -> bool:
	if not ItemCatalog.removed_item_returns_to_inventory(item_id):
		return item_id != ""
	return item_id != "" and game_ui and game_ui.has_method("can_add_inventory") and bool(game_ui.call("can_add_inventory", item_id, 1))

func _create_remove_progress() -> void:
	_free_remove_progress()
	if not previewbuild or not previewbuild.tile_set:
		return
	var tile_size: Vector2i = previewbuild.tile_set.tile_size
	var progress_height: float = float(tile_size.y) * REMOVE_PROGRESS_HEIGHT_RATIO
	_remove_progress = ProgressBar.new()
	_remove_progress.name = "BuildingRemovalProgress"
	_remove_progress.min_value = 0.0
	_remove_progress.max_value = 100.0
	_remove_progress.value = 0.0
	_remove_progress.show_percentage = false
	_remove_progress.fill_mode = ProgressBar.FILL_BOTTOM_TO_TOP
	_remove_progress.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_remove_progress.z_index = 100
	_remove_progress.size = Vector2(REMOVE_PROGRESS_WIDTH, progress_height)
	var cell_center: Vector2 = previewbuild.map_to_local(_remove_cell)
	_remove_progress.position = cell_center - Vector2(REMOVE_PROGRESS_WIDTH * 0.5, progress_height * 0.5)

	var background: StyleBoxFlat = StyleBoxFlat.new()
	background.bg_color = Color(0.05, 0.05, 0.05, 0.8)
	background.border_width_left = 1
	background.border_width_top = 1
	background.border_width_right = 1
	background.border_width_bottom = 1
	background.border_color = Color(0.9, 0.9, 0.9, 0.9)
	var fill: StyleBoxFlat = StyleBoxFlat.new()
	fill.bg_color = Color(0.85, 0.75, 0.25, 1.0)
	_remove_progress.add_theme_stylebox_override("background", background)
	_remove_progress.add_theme_stylebox_override("fill", fill)
	previewbuild.add_child(_remove_progress)

func _cancel_removal() -> void:
	_remove_active = false
	_remove_elapsed = 0.0
	_remove_item_id = ""
	_remove_layer = null
	_free_remove_progress()

func _free_remove_progress() -> void:
	if _remove_progress:
		_remove_progress.queue_free()
		_remove_progress = null

func _resolve_atlas_source_id() -> void:
	var ref: TileMapLayer = previewbuild if previewbuild else wallz
	if not ref or not ref.tile_set:
		return

	var ts: TileSet = ref.tile_set
	for i in range(ts.get_source_count()):
		var sid: int = ts.get_source_id(i)
		if ts.get_source(sid) is TileSetAtlasSource:
			_atlas_source_id = sid
			return

func _draw_preview(cell: Vector2i, atlas_coords: Vector2i) -> void:
	if _atlas_source_id < 0:
		return

	previewbuild.set_cell(
		cell,
		_atlas_source_id,
		atlas_coords,
		0
	)
	_preview_cells.append(cell)
	previewbuild.update_internals()

func _start_rose_drag(placeable_def: Dictionary) -> void:
	if _inventory_item_quantity("rose") <= 0:
		return
	_rose_drag_active = true
	_rose_drag_start_cell = _hovered_cell()
	_rose_drag_end_cell = _rose_drag_start_cell
	_draw_rose_drag_preview(placeable_def, _inventory_item_quantity("rose"))

func _draw_rose_drag_preview(placeable_def: Dictionary, available_roses: int) -> void:
	_clear_hover()
	_rose_drag_preview_limit = available_roses
	var atlas_coords: Vector2i = _atlas_coords_from_placeable(placeable_def)
	if atlas_coords == Vector2i(-1, -1) or available_roses <= 0:
		return
	var target_layer: TileMapLayer = _target_tile_layer(str(placeable_def.get("target_layer", "plantz")))
	if not target_layer:
		return
	var valid_cells: Array[Vector2i] = _rose_rectangle_cells(
		_rose_drag_start_cell,
		_rose_drag_end_cell,
		target_layer,
		placeable_def,
		available_roses
	)
	for cell: Vector2i in valid_cells:
		previewbuild.set_cell(cell, _atlas_source_id, atlas_coords, 0)
	_preview_cells = valid_cells
	_hover_active = not _preview_cells.is_empty()
	_hover_atlas_coords = atlas_coords
	previewbuild.update_internals()

func _rose_rectangle_cells(
	start_cell: Vector2i,
	end_cell: Vector2i,
	target_layer: TileMapLayer,
	placeable_def: Dictionary,
	limit: int
) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	if limit <= 0:
		return cells
	var x_step: int = 1 if end_cell.x >= start_cell.x else -1
	var y_step: int = 1 if end_cell.y >= start_cell.y else -1
	var y: int = start_cell.y
	while true:
		var x: int = start_cell.x
		while true:
			var cell: Vector2i = Vector2i(x, y)
			if _is_valid_placeable_cell(cell, target_layer, placeable_def):
				cells.append(cell)
				if cells.size() >= limit:
					return cells
			if x == end_cell.x:
				break
			x += x_step
		if y == end_cell.y:
			break
		y += y_step
	return cells

func _finish_rose_drag() -> void:
	var placeable_def: Dictionary = _selected_placeable_def()
	if _placement_disabled() or str(placeable_def.get("id", "")) != "rose":
		_cancel_rose_drag()
		return
	var target_layer: TileMapLayer = _target_tile_layer(str(placeable_def.get("target_layer", "plantz")))
	var atlas_coords: Vector2i = _atlas_coords_from_placeable(placeable_def)
	var available_roses: int = _inventory_item_quantity("rose")
	var cells: Array[Vector2i] = []
	_rose_drag_end_cell = _hovered_cell()
	if target_layer and atlas_coords != Vector2i(-1, -1):
		cells = _rose_rectangle_cells(_rose_drag_start_cell, _rose_drag_end_cell, target_layer, placeable_def, available_roses)
	_clear_hover()
	_rose_drag_active = false
	if cells.is_empty():
		return
	if not game_ui or not game_ui.has_method("consume_inventory_item"):
		return
	if not bool(game_ui.call("consume_inventory_item", "rose", cells.size())):
		return
	for cell: Vector2i in cells:
		target_layer.set_cell(cell, _atlas_source_id, atlas_coords, 0)
		_after_placeable_placed(cell, placeable_def, false)
	target_layer.update_internals()
	_flush_plant_layer_visuals()
	Sfx.play_sound(&"plant")

func _cancel_rose_drag() -> void:
	_rose_drag_active = false
	_clear_hover()

func _inventory_item_quantity(item_id: String) -> int:
	if not game_ui or not game_ui.has_method("get_inventory_item_quantity"):
		return 0
	return int(game_ui.call("get_inventory_item_quantity", item_id))

func _apply_placeable(placeable_def: Dictionary) -> void:
	if _atlas_source_id < 0:
		return
	var atlas_coords: Vector2i = _atlas_coords_from_placeable(placeable_def)
	if atlas_coords == Vector2i(-1, -1):
		return

	var target_layer: TileMapLayer = _target_tile_layer(str(placeable_def.get("target_layer", "wallz")))
	if not target_layer:
		return

	_hover_cell = _hovered_cell()
	if not _is_valid_placeable_cell(_hover_cell, target_layer, placeable_def):
		_notify("invalid construction")
		return

	_clear_other_build_layer(target_layer, _hover_cell)
	target_layer.set_cell(
		_hover_cell,
		_atlas_source_id,
		atlas_coords,
		0
	)
	target_layer.update_internals()
	_after_placeable_placed(_hover_cell, placeable_def)
	_consume_placed_item(str(placeable_def.get("id", "")))

func _consume_placed_item(item_id: String) -> void:
	if item_id == "" or not game_ui or not game_ui.has_method("consume_selected_quick_item"):
		return
	game_ui.call("consume_selected_quick_item", item_id)

func _target_tile_layer(layer_name: String) -> TileMapLayer:
	if layer_name == "plantz":
		return plantz
	if layer_name == "traversable_buildings":
		return traversable_buildings
	if layer_name == "blocking_buildings":
		return blocking_buildings
	# Backward compatibility: old "buildings" target maps to traversable_buildings.
	if layer_name == "buildings":
		return traversable_buildings
	return wallz

func _clear_other_build_layer(target_layer: TileMapLayer, cell: Vector2i) -> void:
	if target_layer != wallz and wallz:
		wallz.erase_cell(cell)
		wallz.update_internals()
	if target_layer != plantz and plantz:
		plantz.erase_cell(cell)
		_flush_plant_layer_visuals()
		if plant_manager and plant_manager.has_method("remove_plant"):
			plant_manager.call("remove_plant", cell, false)
	if target_layer != traversable_buildings and traversable_buildings:
		traversable_buildings.erase_cell(cell)
		traversable_buildings.update_internals()
		if building_object_manager and building_object_manager.has_method("remove_building"):
			building_object_manager.call("remove_building", cell, false)
	if target_layer != blocking_buildings and blocking_buildings:
		blocking_buildings.erase_cell(cell)
		blocking_buildings.update_internals()
		if building_object_manager and building_object_manager.has_method("remove_building"):
			building_object_manager.call("remove_building", cell, false)

# True only when `cell` is a real floor tile with no blocking wall on it. Used by
# placeables (e.g. turret1) that may only be built on free walkable ground. This is
# a placement-time guard; it does not affect navigation/flowfields.
func _is_free_walkable_cell(cell: Vector2i) -> bool:
	if floorz and floorz.get_cell_source_id(cell) < 0:
		return false
	if wallz and wallz.get_cell_source_id(cell) >= 0:
		return false
	return true

func _is_placeable_occupied(cell: Vector2i, target_layer: TileMapLayer, placeable_def: Dictionary) -> bool:
	if bool(placeable_def.get("occupies_cell", true)) and target_layer.get_cell_source_id(cell) >= 0:
		return true
	if wallz and wallz != target_layer and wallz.get_cell_source_id(cell) >= 0:
		return true
	if plantz and plantz != target_layer and plantz.get_cell_source_id(cell) >= 0:
		return true
	if traversable_buildings and traversable_buildings != target_layer and traversable_buildings.get_cell_source_id(cell) >= 0:
		return true
	if blocking_buildings and blocking_buildings != target_layer and blocking_buildings.get_cell_source_id(cell) >= 0:
		return true
	return _is_occupied_by_group_node(cell)

func _is_valid_placeable_cell(cell: Vector2i, target_layer: TileMapLayer, placeable_def: Dictionary) -> bool:
	if bool(placeable_def.get("requires_walkable_floor", false)) and not _is_free_walkable_cell(cell):
		return false
	return not _is_placeable_occupied(cell, target_layer, placeable_def)

func _after_placeable_placed(cell: Vector2i, placeable_def: Dictionary, play_placement_sound: bool = true) -> void:
	var placeable_category: String = str(placeable_def.get("category", ""))
	if placeable_category == "plant" and plant_manager and plant_manager.has_method("add_plant"):
		plant_manager.call("add_plant", cell)
	var placeable_id: String = str(placeable_def.get("id", ""))
	if placeable_id == "rose" and play_placement_sound:
		Sfx.play_sound(&"plant")
	if _uses_building_object_manager(placeable_def) and building_object_manager and building_object_manager.has_method("add_building"):
		building_object_manager.call("add_building", cell, placeable_def)

func _uses_building_object_manager(placeable_def: Dictionary) -> bool:
	var placeable_category: String = str(placeable_def.get("category", ""))
	var light_source: float = float(placeable_def.get("light_source", 0.0))
	if light_source > 0.0:
		return true
	return placeable_category == "furniture" or placeable_category == "turret" or placeable_category == "trap"

func _is_occupied_by_group_node(cell: Vector2i) -> bool:
	var map_layer: TileMapLayer = previewbuild if previewbuild else wallz
	if not map_layer:
		return false
	for group_name in occupied_groups:
		var nodes: Array[Node] = get_tree().get_nodes_in_group(group_name)
		for node in nodes:
			if node is Node2D:
				var occupant: Node2D = node as Node2D
				var occupant_cell: Vector2i = map_layer.local_to_map(map_layer.to_local(occupant.global_position))
				if occupant_cell == cell:
					return true
	return false

func _notify(message: String) -> void:
	if not notif:
		return
	if notif.has_method("show_notif"):
		notif.call("show_notif", message)

func _clear_hover() -> void:
	if not _hover_active and _preview_cells.is_empty():
		return
	for cell: Vector2i in _preview_cells:
		previewbuild.erase_cell(cell)
	_preview_cells.clear()
	previewbuild.update_internals()
	_hover_active = false
	_hover_atlas_coords = Vector2i(-1, -1)

func _hovered_cell() -> Vector2i:
	var world: Vector2 = previewbuild.get_global_mouse_position()
	return previewbuild.local_to_map(previewbuild.to_local(world))

func _flush_plant_layer_visuals() -> void:
	if not plantz:
		return
	plantz.update_internals()
	plantz.queue_redraw()
	if _plant_layer_flush_queued:
		return
	_plant_layer_flush_queued = true
	call_deferred("_flush_plant_layer_visuals_deferred")

func _flush_plant_layer_visuals_deferred() -> void:
	_plant_layer_flush_queued = false
	if not plantz:
		return
	plantz.update_internals()
	plantz.queue_redraw()

func _selected_placeable_def() -> Dictionary:
	if not game_ui or not game_ui.has_method("get_selected_quick_item_id"):
		return {}
	if _placement_disabled():
		return {}
	return ItemCatalog.get_placeable_def(String(game_ui.call("get_selected_quick_item_id")))

func _is_inventory_open() -> bool:
	return game_ui and game_ui.has_method("is_inventory_open") and bool(game_ui.call("is_inventory_open"))

func _placement_disabled() -> bool:
	return GameState.is_night

func _atlas_coords_from_placeable(placeable_def: Dictionary) -> Vector2i:
	var raw: Variant = placeable_def.get("atlas", Vector2i(-1, -1))
	if raw is Vector2i:
		return raw
	if raw is Vector2:
		return Vector2i(int(raw.x), int(raw.y))
	if raw is Array and raw.size() == 2:
		return Vector2i(int(raw[0]), int(raw[1]))
	return Vector2i(-1, -1)
