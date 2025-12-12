extends Node
class_name SelectionController

var ui_layer: CanvasLayer
var agent_manager: Node

var selecting: bool = false
var selection_start: Vector2 = Vector2.ZERO
var selection_rect: ColorRect

var selected_units: Array[Node2D] = []
var preview_units: Array[Node2D] = []

var current_group: int = -1

func setup(layer: CanvasLayer, agent_mgr: Node) -> void:
	ui_layer = layer
	agent_manager = agent_mgr

	selection_rect = ColorRect.new()
	selection_rect.color = Color(0, 1, 0, 0.25)
	selection_rect.visible = false
	selection_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_layer.add_child(selection_rect)

func on_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				selecting = true
				selection_start = get_viewport().get_mouse_position()
				selection_rect.position = selection_start
				selection_rect.size = Vector2.ZERO
				selection_rect.visible = true
				_clear_selection()
			else:
				selecting = false
				selection_rect.visible = false
				_clear_preview()
				var mouse_end: Vector2 = get_viewport().get_mouse_position()
				var rect_pos: Vector2 = Vector2(min(selection_start.x, mouse_end.x), min(selection_start.y, mouse_end.y))
				var rect_size: Vector2 = Vector2(abs(mouse_end.x - selection_start.x), abs(mouse_end.y - selection_start.y))
				_process_selection(Rect2(rect_pos, rect_size))

func process(_delta: float) -> void:
	if selecting:
		var mouse_pos: Vector2 = get_viewport().get_mouse_position()
		selection_rect.position = Vector2(min(selection_start.x, mouse_pos.x), min(selection_start.y, mouse_pos.y))
		selection_rect.size = Vector2(abs(mouse_pos.x - selection_start.x), abs(mouse_pos.y - selection_start.y))
		_preview_selection(selection_rect.get_rect())

func get_current_group() -> int:
	return current_group

func get_selected_units() -> Array[Node2D]:
	return selected_units

func _preview_selection(rect: Rect2) -> void:
	_clear_preview()
	var xform: Transform2D = get_viewport().get_canvas_transform()
	for node in get_tree().get_nodes_in_group("main_chars"):
		if node is Node2D:
			var unit: Node2D = node
			var screen_pos: Vector2 = xform * unit.global_position
			if rect.has_point(screen_pos):
				if unit.has_method("set_previewed"):
					unit.call("set_previewed", true)
				else:
					unit.modulate = Color(1.2, 1.2, 1.2, 1)
				preview_units.append(unit)

func _clear_preview() -> void:
	for unit in preview_units:
		if unit.has_method("set_previewed"):
			unit.call("set_previewed", false)
		else:
			unit.modulate = Color(1, 1, 1, 1)
	preview_units.clear()

func _process_selection(rect: Rect2) -> void:
	if rect.size.x < 3.0 and rect.size.y < 3.0:
		return
	if agent_manager and agent_manager.has_method("cleanup_groups"):
		agent_manager.call("cleanup_groups")
	if agent_manager and agent_manager.has_method("create_group"):
		current_group = int(agent_manager.call("create_group"))
	selected_units.clear()

	var xform: Transform2D = get_viewport().get_canvas_transform()
	for node in get_tree().get_nodes_in_group("main_chars"):
		if node is Node2D:
			var unit: Node2D = node
			var screen_pos: Vector2 = xform * unit.global_position
			if rect.has_point(screen_pos):
				_select_unit(unit)
				if agent_manager and agent_manager.has_method("assign_agent"):
					agent_manager.call("assign_agent", unit, current_group)

	if agent_manager and agent_manager.has_method("set_current_selected_group"):
		agent_manager.call("set_current_selected_group", current_group)

func _select_unit(unit: Node2D) -> void:
	if unit not in selected_units:
		selected_units.append(unit)
		if unit.has_method("set_selected"):
			unit.call("set_selected", true)
		else:
			unit.modulate = Color(0.8, 1.5, 0.8, 1.0)

func _clear_selection() -> void:
	for unit in selected_units:
		if unit.has_method("set_selected"):
			unit.call("set_selected", false)
		else:
			unit.modulate = Color(1, 1, 1, 1)
	selected_units.clear()

