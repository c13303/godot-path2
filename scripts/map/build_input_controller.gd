extends RefCounted
class_name BuildInputController

# Reads raw mouse/keyboard build input, interprets it in the current build mode, and
# dispatches to the preview, drag, placement, and removal owners.
#
# BuildSystem keeps build-mode state, tool/item selection, the preview/drag/placement/
# removal owners, and the gamepad (pad_*) public API. This controller owns no gameplay
# state - only input routing - and uses explicit collaborators for the actions it routes.

var _manager: BuildSystem
var _drag_controller: BuildDragController
var _build_preview: BuildPreviewController
var _placement_service: BuildPlacementService
var _build_mode_state: BuildModeStateController
var _game_ui: CanvasLayer


func setup(
	manager: BuildSystem,
	drag_controller: BuildDragController,
	build_preview: BuildPreviewController,
	placement_service: BuildPlacementService,
	build_mode_state: BuildModeStateController,
	game_ui: CanvasLayer
) -> void:
	_manager = manager
	_drag_controller = drag_controller
	_build_preview = build_preview
	_placement_service = placement_service
	_build_mode_state = build_mode_state
	_game_ui = game_ui


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


# --- Routed actions / state queries -------------------------------------------

func _tick_drag(delta: float) -> void:
	_drag_controller.process(delta)


func _is_remove_drag_active() -> bool:
	return _drag_controller.is_remove_drag_active()


func _is_build_drag_active() -> bool:
	return _drag_controller.is_build_drag_active()


func _update_build_drag(placeable_def: Dictionary) -> void:
	_drag_controller.update_build_drag(placeable_def)


func _update_remove_drag() -> void:
	_drag_controller.update_remove_drag()


func _set_keyboard_unbuild_held(held: bool) -> void:
	_drag_controller.set_keyboard_unbuild_held(held)


func _start_keyboard_unbuild_at_hover() -> void:
	_drag_controller.start_keyboard_unbuild_at_hover()


func _cancel_removal() -> void:
	_drag_controller.cancel_removal()


func _selected_placeable_def() -> Dictionary:
	return _build_mode_state.selected_placeable_def()


func _placement_disabled() -> bool:
	return _manager._placement_disabled()


func _is_inventory_open() -> bool:
	return _game_ui and _game_ui.has_method("is_inventory_open") and bool(_game_ui.call("is_inventory_open"))


func _hovered_cell() -> Vector2i:
	return _build_preview.hovered_cell()


func _atlas_coords_from_placeable(placeable_def: Dictionary) -> Vector2i:
	return _placement_service.atlas_coords_from_placeable(placeable_def)


func _can_afford(item_id: String) -> bool:
	return _placement_service.can_afford(item_id)


func _preview_matches_hover(cell: Vector2i, atlas_coords: Vector2i, item_id: String) -> bool:
	return _build_preview.matches_hover(cell, atlas_coords, item_id)


func _refresh_preview_visual_state(placeable_def: Dictionary) -> void:
	_build_preview.refresh_preview_visual_state(placeable_def)


func _clear_hover() -> void:
	_build_preview.clear_hover()


func _set_preview_hover(cell: Vector2i, atlas_coords: Vector2i) -> void:
	_build_preview.set_hover(cell, atlas_coords)


func _draw_preview(cell: Vector2i, atlas_coords: Vector2i, item_id: String, placeable_def: Dictionary) -> void:
	_build_preview.draw_preview(cell, atlas_coords, item_id, placeable_def)


func _rotate_selected_build_direction(reverse: bool = false) -> bool:
	return _build_mode_state.rotate_selected_build_direction(reverse)


func _finish_drag_build() -> void:
	_drag_controller.finish_drag_build()


func _is_drag_buildable(placeable_def: Dictionary) -> bool:
	return bool(placeable_def.get("drag_buildable", true))


func _start_drag_build(placeable_def: Dictionary) -> void:
	_drag_controller.start_drag_build(placeable_def)


func _apply_placeable(placeable_def: Dictionary) -> void:
	_placement_service.try_apply_placeable(placeable_def, _hovered_cell())
