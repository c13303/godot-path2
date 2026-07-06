extends RefCounted
class_name BuildDragController

# Owns drag-build and drag-remove gesture state. BuildSystem keeps input routing,
# selected tool state, preview ownership, and placement/removal rules.

const REMOVE_HOLD_SECONDS: float = 0.2

var _manager: Node

var _drag_build_active: bool = false
var _drag_build_item_id: String = ""
var _drag_build_start_cell: Vector2i = Vector2i.ZERO
var _drag_build_end_cell: Vector2i = Vector2i.ZERO
var _drag_build_preview_limit: int = 0

var _remove_active: bool = false
var _remove_elapsed: float = 0.0
var _remove_queue: Array[Dictionary] = []
var _remove_drag_active: bool = false
var _remove_drag_start_cell: Vector2i = Vector2i.ZERO
var _remove_drag_end_cell: Vector2i = Vector2i.ZERO
var _keyboard_unbuild_held: bool = false
var _keyboard_unbuild_cell: Vector2i = Vector2i.ZERO


func setup(manager: Node) -> void:
	_manager = manager


func process(delta: float) -> void:
	update_keyboard_unbuild()
	process_removal(delta)


func is_build_drag_active() -> bool:
	return _drag_build_active


func is_remove_drag_active() -> bool:
	return _remove_drag_active


func set_keyboard_unbuild_held(held: bool) -> void:
	_keyboard_unbuild_held = held


func update_build_drag(placeable_def: Dictionary) -> void:
	if not _drag_build_active:
		return
	if _placement_disabled() or _is_inventory_open() or str(placeable_def.get("id", "")) != _drag_build_item_id:
		cancel_drag_build()
		return
	var drag_cell: Vector2i = _hovered_cell()
	var available: int = _affordable_quantity(_drag_build_item_id)
	if drag_cell != _drag_build_end_cell or available != _drag_build_preview_limit:
		_drag_build_end_cell = drag_cell
		draw_drag_build_preview(placeable_def, available)


func start_drag_build(placeable_def: Dictionary) -> void:
	var item_id: String = str(placeable_def.get("id", ""))
	if _affordable_quantity(item_id) <= 0:
		return
	set_drag_build_active(true)
	_drag_build_item_id = item_id
	_drag_build_start_cell = _hovered_cell()
	_drag_build_end_cell = _drag_build_start_cell
	draw_drag_build_preview(placeable_def, _affordable_quantity(item_id))


func draw_drag_build_preview(placeable_def: Dictionary, available: int) -> void:
	_drag_build_preview_limit = available
	_manager.call(
		"_draw_drag_build_preview",
		_drag_build_start_cell,
		_drag_build_end_cell,
		placeable_def,
		available
	)


func finish_drag_build() -> void:
	var placeable_def: Dictionary = _selected_placeable_def()
	var item_id: String = _drag_build_item_id
	if _placement_disabled() or str(placeable_def.get("id", "")) != item_id:
		cancel_drag_build()
		return
	_drag_build_end_cell = _hovered_cell()
	var start_cell: Vector2i = _drag_build_start_cell
	var end_cell: Vector2i = _drag_build_end_cell
	_clear_hover()
	_hide_drag_selection_rect()
	set_drag_build_active(false)
	_drag_build_item_id = ""
	_manager.call("_commit_drag_build", placeable_def, item_id, start_cell, end_cell)


func cancel_drag_build() -> void:
	cancel_drag_build_preserving_selection()
	_clear_build_selection()


func cancel_drag_build_preserving_selection() -> void:
	set_drag_build_active(false)
	_drag_build_item_id = ""
	_hide_drag_selection_rect()
	_clear_hover()


func start_remove_drag() -> void:
	if GameState.is_night or _is_inventory_open() or _gui_hovered_control() != null:
		return
	if _placement_disabled() or not _build_tool_selected():
		return
	# A new drag stacks onto any in-progress removal instead of cancelling it, so
	# only clear leftover preview bars here (committed queue bars are preserved).
	clear_preview_remove_progress_bars()
	_remove_drag_active = true
	_remove_drag_start_cell = _hovered_cell()
	_remove_drag_end_cell = _remove_drag_start_cell
	preview_remove_drag()


func update_remove_drag() -> void:
	if not _remove_drag_active:
		return
	var current_cell: Vector2i = _hovered_cell()
	if current_cell != _remove_drag_end_cell:
		_remove_drag_end_cell = current_cell
		preview_remove_drag()


func preview_remove_drag() -> void:
	clear_preview_remove_progress_bars()
	_show_drag_selection_rect(_remove_drag_start_cell, _remove_drag_end_cell)
	var committed: Dictionary = committed_cell_set()
	var removals: Array[Dictionary] = _remove_rectangle_cells(_remove_drag_start_cell, _remove_drag_end_cell)
	for removal: Dictionary in removals:
		var cell: Vector2i = removal.get("cell", Vector2i.ZERO) as Vector2i
		# Cells already queued keep their committed bar; don't preview over them.
		if committed.has(cell):
			continue
		_create_remove_progress(cell, 0.0)


func finish_remove_drag() -> void:
	if not _remove_drag_active:
		return
	_remove_drag_active = false
	_hide_drag_selection_rect()
	var was_active: bool = _remove_active
	var new_removals: Array[Dictionary] = _remove_rectangle_cells(_remove_drag_start_cell, _hovered_cell())
	clear_preview_remove_progress_bars()
	# Stack the new selection behind whatever is already being removed instead of
	# replacing it: append to the queue so removals run one after another (a waiting
	# line), each keeping its own progress bar.
	var committed: Dictionary = committed_cell_set()
	for removal: Dictionary in new_removals:
		var cell: Vector2i = removal.get("cell", Vector2i.ZERO) as Vector2i
		if committed.has(cell):
			continue
		committed[cell] = true
		_remove_queue.append(removal)
		_create_remove_progress(cell, 0.0)
	if _remove_queue.is_empty():
		cancel_removal()
		return
	_remove_active = true
	# Preserve the in-progress head's elapsed time when stacking; only reset for a
	# brand-new removal run.
	if not was_active:
		_remove_elapsed = 0.0
	_clear_hover()


func process_removal(delta: float) -> void:
	if not _remove_active:
		return
	if GameState.is_night or _is_inventory_open() or not _keyboard_unbuild_held:
		cancel_removal()
		return
	if _remove_queue.is_empty():
		cancel_removal()
		return
	var active_removal: Dictionary = _remove_queue[0] as Dictionary
	var active_cell: Vector2i = active_removal.get("cell", Vector2i.ZERO) as Vector2i
	var active_item_id: String = str(active_removal.get("item_id", ""))
	var current_removal: Dictionary = _removable_at_cell(active_cell)
	if current_removal.is_empty() or str(current_removal.get("item_id", "")) != active_item_id:
		cancel_removal()
		return
	_remove_elapsed = minf(_remove_elapsed + delta, REMOVE_HOLD_SECONDS)
	_set_remove_progress_value(active_cell, (_remove_elapsed / REMOVE_HOLD_SECONDS) * 100.0)
	if _remove_elapsed >= REMOVE_HOLD_SECONDS:
		finish_removal()


func finish_removal() -> void:
	if not _remove_active or GameState.is_night:
		cancel_removal()
		return
	if _remove_queue.is_empty():
		cancel_removal()
		return
	var removal: Dictionary = _remove_queue.pop_front() as Dictionary
	var removed_cell: Vector2i = removal.get("cell", Vector2i.ZERO) as Vector2i
	var removed_item_id: String = str(removal.get("item_id", ""))
	var current_removal: Dictionary = _removable_at_cell(removed_cell)
	if current_removal.is_empty() or str(current_removal.get("item_id", "")) != removed_item_id:
		cancel_removal()
		return

	_free_remove_progress_for_cell(removed_cell)
	if not bool(_manager.call("_commit_removal", removal)):
		cancel_removal()
		return
	_remove_elapsed = 0.0
	if _remove_queue.is_empty():
		cancel_removal()


func update_keyboard_unbuild() -> void:
	if not _keyboard_unbuild_held:
		return
	if GameState.is_night or _is_inventory_open() or _gui_hovered_control() != null:
		cancel_removal()
		return
	var cell: Vector2i = _hovered_cell()
	if _remove_active and cell == _keyboard_unbuild_cell:
		return
	if _remove_active:
		cancel_removal()
	_keyboard_unbuild_cell = cell
	start_keyboard_unbuild_at_hover()


func start_keyboard_unbuild_at_hover() -> void:
	if GameState.is_night or _is_inventory_open() or _gui_hovered_control() != null:
		return
	if _placement_disabled():
		return
	cancel_drag_build_preserving_selection()
	clear_preview_remove_progress_bars()
	var cell: Vector2i = _hovered_cell()
	var removal: Dictionary = _removable_at_cell(cell)
	if removal.is_empty():
		cancel_removal()
		return
	_keyboard_unbuild_cell = cell
	_remove_queue.clear()
	_remove_queue.append(removal)
	_remove_elapsed = 0.0
	_remove_active = true
	_create_remove_progress(cell, 0.0)
	_clear_hover()


func cancel_removal() -> void:
	_remove_active = false
	_remove_drag_active = false
	_remove_elapsed = 0.0
	_remove_queue.clear()
	_hide_drag_selection_rect()
	_clear_remove_progress_bars()


# Cells committed to the active removal queue (drives dedup + bar preservation when
# a fresh drag stacks onto an in-progress removal).
func committed_cell_set() -> Dictionary:
	var cells: Dictionary = {}
	for removal: Dictionary in _remove_queue:
		cells[removal.get("cell", Vector2i.ZERO) as Vector2i] = true
	return cells


# Free only transient drag-preview bars, keeping the bars for cells already
# committed to the active removal queue.
func clear_preview_remove_progress_bars() -> void:
	_manager.call("_clear_preview_remove_progress_bars", committed_cell_set())


func set_drag_build_active(active: bool) -> void:
	if _drag_build_active == active:
		return
	_drag_build_active = active
	_manager.call("_emit_build_preview_changed", _drag_build_active)


func _selected_placeable_def() -> Dictionary:
	return _manager.call("_selected_placeable_def") as Dictionary


func _placement_disabled() -> bool:
	return bool(_manager.call("_placement_disabled"))


func _is_inventory_open() -> bool:
	return bool(_manager.call("_is_inventory_open"))


func _gui_hovered_control() -> Control:
	if _manager == null:
		return null
	var viewport: Viewport = _manager.get_viewport()
	if viewport == null:
		return null
	return viewport.gui_get_hovered_control()


func _build_tool_selected() -> bool:
	return bool(_manager.call("_build_tool_selected"))


func _hovered_cell() -> Vector2i:
	return _manager.call("_hovered_cell") as Vector2i


func _affordable_quantity(item_id: String) -> int:
	return int(_manager.call("_affordable_quantity", item_id))


func _clear_hover() -> void:
	_manager.call("_clear_hover")


func _clear_build_selection() -> void:
	_manager.call("_clear_build_selection")


func _hide_drag_selection_rect() -> void:
	_manager.call("_hide_drag_selection_rect")


func _show_drag_selection_rect(start_cell: Vector2i, end_cell: Vector2i) -> void:
	_manager.call("_show_drag_selection_rect", start_cell, end_cell)


func _remove_rectangle_cells(start_cell: Vector2i, end_cell: Vector2i) -> Array[Dictionary]:
	var result: Variant = _manager.call("_remove_rectangle_cells", start_cell, end_cell)
	var raw_removals: Array = result as Array
	var removals: Array[Dictionary] = []
	for raw_removal: Variant in raw_removals:
		removals.append(raw_removal as Dictionary)
	return removals


func _removable_at_cell(cell: Vector2i) -> Dictionary:
	return _manager.call("_removable_at_cell", cell) as Dictionary


func _create_remove_progress(cell: Vector2i, value: float) -> void:
	_manager.call("_create_remove_progress", cell, value)


func _set_remove_progress_value(cell: Vector2i, value: float) -> void:
	_manager.call("_set_remove_progress_value", cell, value)


func _free_remove_progress_for_cell(cell: Vector2i) -> void:
	_manager.call("_free_remove_progress_for_cell", cell)


func _clear_remove_progress_bars() -> void:
	_manager.call("_clear_remove_progress_bars")
