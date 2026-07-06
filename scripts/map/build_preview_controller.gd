extends RefCounted
class_name BuildPreviewController

# Owns build preview rendering, placement cursor targeting, drag-selection visuals,
# and removal progress bar nodes. BuildSystem keeps placement/removal commits.

const REMOVE_PROGRESS_WIDTH: float = 6.0
const REMOVE_PROGRESS_HEIGHT_RATIO: float = 0.8
const PREVIEW_NORMAL_COLOR: Color = Color(0.78, 0.90, 0.98, 0.80)
const PREVIEW_FORBIDDEN_RANGE_COLOR: Color = Color(1.0, 0.18, 0.18, 0.5)
const PREVIEW_Z_INDEX: int = 4095
const DRAG_SELECT_FILL_COLOR: Color = Color(0.20, 1.0, 0.35, 0.10)
const DRAG_SELECT_BORDER_COLOR: Color = Color(0.30, 1.0, 0.45)
const DIRECTION_RIGHT: Vector2i = Vector2i(1, 0)
const DIRECTION_DOWN: Vector2i = Vector2i(0, 1)
const DIRECTION_LEFT: Vector2i = Vector2i(-1, 0)
const DIRECTION_UP: Vector2i = Vector2i(0, -1)
const FENCE_ITEM_ID: String = "fence"
const FENCE_NEIGHBOR_NORTH: int = 1
const FENCE_NEIGHBOR_EAST: int = 2
const FENCE_NEIGHBOR_SOUTH: int = 4
const FENCE_NEIGHBOR_WEST: int = 8

var _manager: Node
var _hover_active: bool = false
var _hover_cell: Vector2i
var _hover_item_id: String = ""
var _hover_atlas_coords: Vector2i = Vector2i(-1, -1)
var _preview_cells: Array[Vector2i] = []
var _pad_cursor_active: bool = false
var _pad_cursor_offset: Vector2i = Vector2i.ZERO
var _cursor_hidden_for_preview: bool = false
var _drag_selection_rect: Panel = null
var _remove_progress_by_cell: Dictionary = {}  # Vector2i -> ProgressBar


func setup(manager: Node) -> void:
	_manager = manager


func configure_layer() -> void:
	var previewbuild: TileMapLayer = _preview_layer()
	if previewbuild == null:
		return
	previewbuild.z_index = PREVIEW_Z_INDEX
	previewbuild.modulate = PREVIEW_NORMAL_COLOR


func draw_preview(cell: Vector2i, atlas_coords: Vector2i, item_id: String, placeable_def: Dictionary) -> void:
	if _atlas_source_id() < 0:
		return
	var previewbuild: TileMapLayer = _preview_layer()
	if previewbuild == null:
		return

	if item_id == FENCE_ITEM_ID:
		var fence_cells: Array[Vector2i] = [cell]
		_preview_cells = _draw_fence_preview_cells(fence_cells)
	else:
		previewbuild.set_cell(
			cell,
			_atlas_source_id(),
			atlas_coords,
			_alternative_from_placeable(placeable_def)
		)
		_preview_cells.append(cell)
	_hover_item_id = item_id
	refresh_preview_visual_state(placeable_def)
	previewbuild.update_internals()
	_set_preview_cursor_hidden(true)


func draw_drag_build_preview(
	start_cell: Vector2i,
	end_cell: Vector2i,
	placeable_def: Dictionary,
	available: int
) -> Array[Vector2i]:
	clear_hover()
	var previewbuild: TileMapLayer = _preview_layer()
	if previewbuild == null:
		return _empty_cells()
	var atlas_coords: Vector2i = _atlas_coords_from_placeable(placeable_def)
	if atlas_coords == Vector2i(-1, -1) or available <= 0:
		return _empty_cells()
	var target_layer: TileMapLayer = _target_tile_layer(str(placeable_def.get("target_layer", "wallz")))
	if not target_layer:
		return _empty_cells()
	var valid_cells: Array[Vector2i] = _drag_build_rectangle_cells(
		start_cell,
		end_cell,
		target_layer,
		placeable_def,
		available
	)
	if str(placeable_def.get("id", "")) == FENCE_ITEM_ID:
		_preview_cells = _draw_fence_preview_cells(valid_cells)
	else:
		for cell: Vector2i in valid_cells:
			previewbuild.set_cell(cell, _atlas_source_id(), atlas_coords, _alternative_from_placeable(placeable_def))
		_preview_cells = valid_cells
	previewbuild.modulate = PREVIEW_NORMAL_COLOR
	_hover_active = not _preview_cells.is_empty()
	_hover_item_id = str(placeable_def.get("id", "")) if _hover_active else ""
	_hover_atlas_coords = atlas_coords
	show_drag_selection_rect(start_cell, end_cell)
	previewbuild.update_internals()
	_set_preview_cursor_hidden(_hover_active)
	return valid_cells


func refresh_preview_visual_state(placeable_def: Dictionary) -> void:
	var previewbuild: TileMapLayer = _preview_layer()
	if previewbuild == null:
		return
	var blocker_result: Variant = _manager.call("_turret_range_blocker_for_cell", _hover_cell, placeable_def)
	var blocker: Dictionary = blocker_result as Dictionary
	var blocked: bool = not blocker.is_empty()
	previewbuild.modulate = PREVIEW_FORBIDDEN_RANGE_COLOR if blocked else PREVIEW_NORMAL_COLOR


func clear_hover() -> void:
	var previewbuild: TileMapLayer = _preview_layer()
	_set_preview_cursor_hidden(false)
	if previewbuild == null:
		return
	previewbuild.modulate = PREVIEW_NORMAL_COLOR
	if not _hover_active and _preview_cells.is_empty():
		_hover_item_id = ""
		return
	for cell: Vector2i in _preview_cells:
		previewbuild.erase_cell(cell)
	_preview_cells.clear()
	previewbuild.update_internals()
	_hover_active = false
	_hover_item_id = ""
	_hover_atlas_coords = Vector2i(-1, -1)


func _set_preview_cursor_hidden(hidden: bool) -> void:
	if _pad_cursor_active:
		return
	if hidden == _cursor_hidden_for_preview:
		return
	_cursor_hidden_for_preview = hidden
	Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN if hidden else Input.MOUSE_MODE_VISIBLE)


func hovered_cell() -> Vector2i:
	if _pad_cursor_active:
		return player_cell() + _pad_cursor_offset
	return mouse_hovered_cell()


func mouse_hovered_cell() -> Vector2i:
	var previewbuild: TileMapLayer = _preview_layer()
	if previewbuild == null:
		return Vector2i.ZERO
	var world: Vector2 = previewbuild.get_global_mouse_position()
	return previewbuild.local_to_map(previewbuild.to_local(world))


func player_cell() -> Vector2i:
	var previewbuild: TileMapLayer = _preview_layer()
	if previewbuild == null:
		return mouse_hovered_cell()
	var player: Node2D = _manager.get_tree().get_first_node_in_group("player") as Node2D
	if player == null:
		return mouse_hovered_cell()
	return previewbuild.local_to_map(previewbuild.to_local(player.global_position))


func is_pad_cursor_active() -> bool:
	return _pad_cursor_active


func set_pad_cursor_active(active: bool) -> void:
	_pad_cursor_active = active
	if not active:
		return
	_pad_cursor_offset = mouse_hovered_cell() - player_cell()


func place_cursor_right_of_player() -> void:
	_pad_cursor_offset = Vector2i(1, 0)
	_pad_cursor_active = true


func move_pad_cursor(direction: Vector2i) -> void:
	if direction == Vector2i.ZERO:
		return
	if not _pad_cursor_active:
		_pad_cursor_offset = mouse_hovered_cell() - player_cell()
		_pad_cursor_active = true
	_pad_cursor_offset += direction


func create_remove_progress(cell: Vector2i, value: float) -> void:
	var previewbuild: TileMapLayer = _preview_layer()
	if not previewbuild or not previewbuild.tile_set:
		return
	var tile_size: Vector2i = previewbuild.tile_set.tile_size
	var progress_height: float = float(tile_size.y) * REMOVE_PROGRESS_HEIGHT_RATIO
	var remove_progress: ProgressBar = ProgressBar.new()
	remove_progress.name = "BuildingRemovalProgress"
	remove_progress.min_value = 0.0
	remove_progress.max_value = 100.0
	remove_progress.value = value
	remove_progress.show_percentage = false
	remove_progress.fill_mode = ProgressBar.FILL_BOTTOM_TO_TOP
	remove_progress.mouse_filter = Control.MOUSE_FILTER_IGNORE
	remove_progress.z_index = 100
	remove_progress.size = Vector2(REMOVE_PROGRESS_WIDTH, progress_height)
	var cell_center: Vector2 = previewbuild.map_to_local(cell)
	remove_progress.position = cell_center - Vector2(REMOVE_PROGRESS_WIDTH * 0.5, progress_height * 0.5)
	var background: StyleBoxFlat = StyleBoxFlat.new()
	background.bg_color = Color(0.05, 0.05, 0.05, 0.8)
	background.border_width_left = 1
	background.border_width_top = 1
	background.border_width_right = 1
	background.border_width_bottom = 1
	background.border_color = Color(0.9, 0.9, 0.9, 0.9)
	var fill: StyleBoxFlat = StyleBoxFlat.new()
	fill.bg_color = Color(0.85, 0.75, 0.25, 1.0)
	remove_progress.add_theme_stylebox_override("background", background)
	remove_progress.add_theme_stylebox_override("fill", fill)
	previewbuild.add_child(remove_progress)
	_remove_progress_by_cell[cell] = remove_progress


func set_remove_progress_value(cell: Vector2i, value: float) -> void:
	var active_progress: ProgressBar = _remove_progress_by_cell.get(cell, null) as ProgressBar
	if active_progress != null:
		active_progress.value = value


func clear_remove_progress_bars() -> void:
	for raw_progress: Variant in _remove_progress_by_cell.values():
		var progress: ProgressBar = raw_progress as ProgressBar
		if progress != null and is_instance_valid(progress):
			progress.queue_free()
	_remove_progress_by_cell.clear()


func clear_preview_remove_progress_bars(committed: Dictionary) -> void:
	for cell: Variant in _remove_progress_by_cell.keys():
		if committed.has(cell):
			continue
		var progress: ProgressBar = _remove_progress_by_cell[cell] as ProgressBar
		if progress != null and is_instance_valid(progress):
			progress.queue_free()
		_remove_progress_by_cell.erase(cell)


func free_remove_progress_for_cell(cell: Vector2i) -> void:
	var progress: ProgressBar = _remove_progress_by_cell.get(cell, null) as ProgressBar
	if progress != null and is_instance_valid(progress):
		progress.queue_free()
	_remove_progress_by_cell.erase(cell)


func show_drag_selection_rect(start_cell: Vector2i, end_cell: Vector2i) -> void:
	var previewbuild: TileMapLayer = _preview_layer()
	if previewbuild == null or previewbuild.tile_set == null:
		return
	_ensure_drag_selection_rect()
	var tile_size: Vector2 = Vector2(previewbuild.tile_set.tile_size)
	var min_cell: Vector2i = Vector2i(mini(start_cell.x, end_cell.x), mini(start_cell.y, end_cell.y))
	var max_cell: Vector2i = Vector2i(maxi(start_cell.x, end_cell.x), maxi(start_cell.y, end_cell.y))
	var top_left: Vector2 = previewbuild.map_to_local(min_cell) - tile_size * 0.5
	var bottom_right: Vector2 = previewbuild.map_to_local(max_cell) + tile_size * 0.5
	_drag_selection_rect.position = top_left
	_drag_selection_rect.size = bottom_right - top_left
	_drag_selection_rect.visible = true


func hide_drag_selection_rect() -> void:
	if _drag_selection_rect != null and is_instance_valid(_drag_selection_rect):
		_drag_selection_rect.visible = false


func has_single_tile_preview() -> bool:
	return _hover_active and _preview_cells.size() == 1


func get_preview_item_id() -> String:
	return _hover_item_id


func get_preview_cell() -> Vector2i:
	return _hover_cell


func set_hover(cell: Vector2i, atlas_coords: Vector2i) -> void:
	_hover_cell = cell
	_hover_atlas_coords = atlas_coords
	_hover_active = true


func matches_hover(cell: Vector2i, atlas_coords: Vector2i, item_id: String) -> bool:
	return _hover_active and cell == _hover_cell and atlas_coords == _hover_atlas_coords and item_id == _hover_item_id


func _ensure_drag_selection_rect() -> void:
	if _drag_selection_rect != null and is_instance_valid(_drag_selection_rect):
		return
	var previewbuild: TileMapLayer = _preview_layer()
	if previewbuild == null:
		return
	_drag_selection_rect = Panel.new()
	_drag_selection_rect.name = "DragSelectionRect"
	_drag_selection_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_drag_selection_rect.z_index = 60
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = DRAG_SELECT_FILL_COLOR
	style.set_border_width_all(2)
	style.border_color = DRAG_SELECT_BORDER_COLOR
	style.set_corner_radius_all(2)
	_drag_selection_rect.add_theme_stylebox_override("panel", style)
	previewbuild.add_child(_drag_selection_rect)


func _draw_fence_preview_cells(candidate_cells: Array[Vector2i]) -> Array[Vector2i]:
	var previewbuild: TileMapLayer = _preview_layer()
	if previewbuild == null:
		return _empty_cells()
	var candidate_set: Dictionary = {}
	for cell: Vector2i in candidate_cells:
		candidate_set[cell] = true
	var touched: Dictionary = {}
	for cell: Vector2i in candidate_cells:
		var refresh_result: Variant = _manager.call("_fence_refresh_cells", cell)
		var refresh_cells: Array[Vector2i] = refresh_result as Array[Vector2i]
		for refresh_cell: Vector2i in refresh_cells:
			if candidate_set.has(refresh_cell) or _has_fence_cell(refresh_cell):
				touched[refresh_cell] = true
	var preview_cells: Array[Vector2i] = []
	for raw_cell: Variant in touched.keys():
		var preview_cell: Vector2i = raw_cell as Vector2i
		var atlas_coords: Vector2i = _fence_preview_atlas(preview_cell, candidate_set)
		previewbuild.set_cell(preview_cell, _atlas_source_id(), atlas_coords)
		preview_cells.append(preview_cell)
	return preview_cells


func _fence_preview_atlas(cell: Vector2i, candidate_set: Dictionary) -> Vector2i:
	var mask: int = _fence_preview_neighbor_mask(cell, candidate_set)
	var result: Variant = _manager.call("_fence_atlas_by_mask", mask)
	return result as Vector2i


func _fence_preview_neighbor_mask(cell: Vector2i, candidate_set: Dictionary) -> int:
	var mask: int = 0
	if _has_preview_fence_cell(cell + DIRECTION_UP, candidate_set):
		mask |= FENCE_NEIGHBOR_NORTH
	if _has_preview_fence_cell(cell + DIRECTION_RIGHT, candidate_set):
		mask |= FENCE_NEIGHBOR_EAST
	if _has_preview_fence_cell(cell + DIRECTION_DOWN, candidate_set):
		mask |= FENCE_NEIGHBOR_SOUTH
	if _has_preview_fence_cell(cell + DIRECTION_LEFT, candidate_set):
		mask |= FENCE_NEIGHBOR_WEST
	return mask


func _has_preview_fence_cell(cell: Vector2i, candidate_set: Dictionary) -> bool:
	return candidate_set.has(cell) or _has_fence_cell(cell)


func _has_fence_cell(cell: Vector2i) -> bool:
	return bool(_manager.call("_has_fence_cell", cell))


func _preview_layer() -> TileMapLayer:
	return _manager.get("previewbuild") as TileMapLayer


func _atlas_source_id() -> int:
	return int(_manager.get("_atlas_source_id"))


func _alternative_from_placeable(placeable_def: Dictionary) -> int:
	return int(_manager.call("_alternative_from_placeable", placeable_def))


func _atlas_coords_from_placeable(placeable_def: Dictionary) -> Vector2i:
	var result: Variant = _manager.call("_atlas_coords_from_placeable", placeable_def)
	return result as Vector2i


func _target_tile_layer(layer_name: String) -> TileMapLayer:
	var result: Variant = _manager.call("_target_tile_layer", layer_name)
	return result as TileMapLayer


func _drag_build_rectangle_cells(
	start_cell: Vector2i,
	end_cell: Vector2i,
	target_layer: TileMapLayer,
	placeable_def: Dictionary,
	limit: int
) -> Array[Vector2i]:
	var result: Variant = _manager.call("_drag_build_rectangle_cells", start_cell, end_cell, target_layer, placeable_def, limit)
	return result as Array[Vector2i]


func _empty_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	return cells
