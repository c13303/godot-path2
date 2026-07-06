extends RefCounted
class_name BuildInputController

# Reads raw mouse/keyboard build input, interprets it in the current build mode, and
# dispatches to BuildSystem's preview, drag, placement, and removal wrappers.
#
# BuildSystem keeps build-mode state, tool/item selection, the preview/drag/placement/
# removal owners, and the gamepad (pad_*) public API. This controller owns no gameplay
# state - only input routing - and reaches everything through narrow BuildSystem wrappers.

var _manager: Node


func setup(manager: Node) -> void:
	_manager = manager


func process(delta: float) -> void:
	_tick_drag(delta)
	if _is_remove_drag_active():
		_clear_hover()
		return

	var placeable_def: Dictionary = _selected_placeable_def()
	if _is_build_drag_active():
		_update_build_drag(placeable_def)
		return
	if _placement_disabled() or placeable_def.is_empty() or _is_inventory_open() or _gui_hovered_control() != null:
		_clear_hover()
		return

	var cell: Vector2i = _hovered_cell()
	var atlas_coords: Vector2i = _atlas_coords_from_placeable(placeable_def)
	var item_id: String = str(placeable_def.get("id", ""))
	if atlas_coords == Vector2i(-1, -1) or not _can_afford(item_id):
		_clear_hover()
		return

	if _preview_matches_hover(cell, atlas_coords, item_id):
		_refresh_preview_visual_state(placeable_def)
		return

	_clear_hover()
	_set_preview_hover(cell, atlas_coords)
	_draw_preview(cell, atlas_coords, item_id, placeable_def)


func input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key_event: InputEventKey = event as InputEventKey
		if key_event.physical_keycode == KEY_X:
			if key_event.pressed and not key_event.echo:
				_set_keyboard_unbuild_held(true)
				_start_keyboard_unbuild_at_hover()
				_set_input_handled()
				return
			if not key_event.pressed:
				_set_keyboard_unbuild_held(false)
				_cancel_removal()
				_set_input_handled()
				return
		if key_event.pressed and not key_event.echo and key_event.physical_keycode == KEY_R:
			if _rotate_selected_build_direction():
				_set_input_handled()
				return

	# Mouse wheel rotates the buildable during placement (keyboard+mouse controls).
	# Only consumes the event when a rotatable buildable is selected, so the wheel is
	# free otherwise. Wheel up / down rotate in opposite directions.
	if event is InputEventMouseButton:
		var wheel_event: InputEventMouseButton = event as InputEventMouseButton
		if wheel_event.pressed and not wheel_event.ctrl_pressed:
			if wheel_event.button_index == MOUSE_BUTTON_WHEEL_UP:
				if _rotate_selected_build_direction(false):
					_set_input_handled()
					return
			elif wheel_event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				if _rotate_selected_build_direction(true):
					_set_input_handled()
					return

	if event is InputEventMouseMotion and _is_remove_drag_active():
		_update_remove_drag()
		_set_input_handled()
		return

	if event is InputEventMouseButton:
		var drag_mouse_event: InputEventMouseButton = event as InputEventMouseButton
		if drag_mouse_event.button_index == MOUSE_BUTTON_LEFT and not drag_mouse_event.pressed and _is_build_drag_active():
			_finish_drag_build()
			_set_input_handled()
			return

	var placeable_def: Dictionary = _selected_placeable_def()
	if _placement_disabled() or placeable_def.is_empty() or _is_inventory_open() or _gui_hovered_control() != null:
		return

	if event is InputEventMouseButton and event.pressed:
		var mouse_event: InputEventMouseButton = event
		if mouse_event.button_index == MOUSE_BUTTON_LEFT:
			if _is_drag_buildable(placeable_def):
				_start_drag_build(placeable_def)
			else:
				_apply_placeable(placeable_def)
			_set_input_handled()


# --- Viewport helpers ---------------------------------------------------------

func _gui_hovered_control() -> Control:
	var viewport: Viewport = _viewport()
	if viewport == null:
		return null
	return viewport.gui_get_hovered_control()


func _set_input_handled() -> void:
	var viewport: Viewport = _viewport()
	if viewport != null:
		viewport.set_input_as_handled()


func _viewport() -> Viewport:
	if _manager == null:
		return null
	return _manager.get_viewport()


# --- BuildSystem wrappers -----------------------------------------------------

func _tick_drag(delta: float) -> void:
	_manager.call("_tick_drag", delta)


func _is_remove_drag_active() -> bool:
	return bool(_manager.call("_is_remove_drag_active"))


func _is_build_drag_active() -> bool:
	return bool(_manager.call("_is_build_drag_active"))


func _update_build_drag(placeable_def: Dictionary) -> void:
	_manager.call("_update_build_drag", placeable_def)


func _update_remove_drag() -> void:
	_manager.call("_update_remove_drag")


func _set_keyboard_unbuild_held(held: bool) -> void:
	_manager.call("_set_keyboard_unbuild_held", held)


func _start_keyboard_unbuild_at_hover() -> void:
	_manager.call("_start_keyboard_unbuild_at_hover")


func _cancel_removal() -> void:
	_manager.call("_cancel_removal")


func _selected_placeable_def() -> Dictionary:
	return _manager.call("_selected_placeable_def") as Dictionary


func _placement_disabled() -> bool:
	return bool(_manager.call("_placement_disabled"))


func _is_inventory_open() -> bool:
	return bool(_manager.call("_is_inventory_open"))


func _hovered_cell() -> Vector2i:
	return _manager.call("_hovered_cell") as Vector2i


func _atlas_coords_from_placeable(placeable_def: Dictionary) -> Vector2i:
	return _manager.call("_atlas_coords_from_placeable", placeable_def) as Vector2i


func _can_afford(item_id: String) -> bool:
	return bool(_manager.call("_can_afford", item_id))


func _preview_matches_hover(cell: Vector2i, atlas_coords: Vector2i, item_id: String) -> bool:
	return bool(_manager.call("_preview_matches_hover", cell, atlas_coords, item_id))


func _refresh_preview_visual_state(placeable_def: Dictionary) -> void:
	_manager.call("_refresh_preview_visual_state", placeable_def)


func _clear_hover() -> void:
	_manager.call("_clear_hover")


func _set_preview_hover(cell: Vector2i, atlas_coords: Vector2i) -> void:
	_manager.call("_set_preview_hover", cell, atlas_coords)


func _draw_preview(cell: Vector2i, atlas_coords: Vector2i, item_id: String, placeable_def: Dictionary) -> void:
	_manager.call("_draw_preview", cell, atlas_coords, item_id, placeable_def)


func _rotate_selected_build_direction(reverse: bool = false) -> bool:
	return bool(_manager.call("rotate_selected_build_direction", reverse))


func _finish_drag_build() -> void:
	_manager.call("_finish_drag_build")


func _is_drag_buildable(placeable_def: Dictionary) -> bool:
	return bool(_manager.call("_is_drag_buildable", placeable_def))


func _start_drag_build(placeable_def: Dictionary) -> void:
	_manager.call("_start_drag_build", placeable_def)


func _apply_placeable(placeable_def: Dictionary) -> void:
	_manager.call("_apply_placeable", placeable_def)
