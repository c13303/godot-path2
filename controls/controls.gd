extends Node2D

@onready var floorz: TileMapLayer = $"../MonTilemap/floor"
@onready var wallz: TileMapLayer = $"../MonTilemap/wallz"
@onready var flow: Node = $"../FlowFieldNative"
@onready var steering: Node = $"../SteeringSystemNative"
@onready var agent_manager: Node = $"../AgentManagerNative"
@onready var marker: Node2D = preload("res://UI_elements/green_circle.tscn").instantiate()
@onready var ui_layer: CanvasLayer = $"../CanvasLayer"

@export var camera: Camera2D
@export var speed: float = 400.0
@export var zoom_speed: float = 0.1
@export var min_zoom: float = 0.5
@export var max_zoom: float = 3.0

var current_flow: Node = null
var current_group: int = -1

var dragging: bool = false
var drag_start_pos: Vector2
var camera_start_pos: Vector2
var MainCharScene: PackedScene = preload("res://character/character.tscn")

var selecting: bool = false
var selection_start: Vector2 = Vector2.ZERO
var selection_rect: ColorRect
var selected_units: Array[Node2D] = []
var preview_units: Array[Node2D] = []

signal mouse_goal_set(world_pos: Vector2)

func _ready() -> void:
	add_child(marker)
	marker.visible = false
	marker.z_index = 1
	if ui_layer:
		selection_rect = ColorRect.new()
		selection_rect.color = Color(0, 1, 0, 0.25)
		selection_rect.visible = false
		selection_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ui_layer.add_child(selection_rect)

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
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
				var rect_pos := Vector2(min(selection_start.x, mouse_end.x), min(selection_start.y, mouse_end.y))
				var rect_size := Vector2(abs(mouse_end.x - selection_start.x), abs(mouse_end.y - selection_start.y))
				_process_selection(Rect2(rect_pos, rect_size))
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			_on_click_set_goal()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed and camera:
			camera.zoom = Vector2(clamp(camera.zoom.x - zoom_speed, min_zoom, max_zoom), clamp(camera.zoom.y - zoom_speed, min_zoom, max_zoom))
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed and camera:
			camera.zoom = Vector2(clamp(camera.zoom.x + zoom_speed, min_zoom, max_zoom), clamp(camera.zoom.y + zoom_speed, min_zoom, max_zoom))

	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_A:
			_on_key_spawn_chars()
		elif event.keycode == KEY_Z:
			_on_key_spawn_chars_massive(10)
		elif event.keycode == KEY_E:
			_on_key_spawn_chars_massive(50)

func _process(delta: float) -> void:
	if camera == null:
		return
	var input := Vector2.ZERO
	if Input.is_action_pressed("ui_right"):
		input.x += 1.0
	if Input.is_action_pressed("ui_left"):
		input.x -= 1.0
	if Input.is_action_pressed("ui_down"):
		input.y += 1.0
	if Input.is_action_pressed("ui_up"):
		input.y -= 1.0
	if input != Vector2.ZERO:
		camera.position += input.normalized() * speed * delta
	if dragging and camera:
		var mouse_pos := get_viewport().get_mouse_position()
		var offset := (drag_start_pos - mouse_pos) * camera.zoom
		camera.position = camera_start_pos + offset
	if selecting:
		var mouse_pos := get_viewport().get_mouse_position()
		var rect_pos := Vector2(min(selection_start.x, mouse_pos.x), min(selection_start.y, mouse_pos.y))
		var rect_size := Vector2(abs(mouse_pos.x - selection_start.x), abs(mouse_pos.y - selection_start.y))
		selection_rect.position = rect_pos
		selection_rect.size = rect_size
		_preview_selection(Rect2(rect_pos, rect_size))

func _preview_selection(rect: Rect2) -> void:
	if camera == null:
		return
	var units_in_rect: Array[Node2D] = []
	for node in get_tree().get_nodes_in_group("main_chars"):
		var n2d := node as Node2D
		var screen_pos := get_viewport().get_canvas_transform() * n2d.global_position
		if rect.has_point(screen_pos):
			units_in_rect.append(n2d)
	for unit in preview_units:
		if is_instance_valid(unit) and not units_in_rect.has(unit):
			if unit.has_method("set_previewed"):
				unit.set_previewed(false)
			else:
				unit.modulate = Color(1, 1, 1, 1)
	for unit in units_in_rect:
		if not preview_units.has(unit):
			if unit.has_method("set_previewed"):
				unit.set_previewed(true)
			else:
				unit.modulate = Color(1.3, 1.3, 0.8, 1)
	preview_units = units_in_rect

func _clear_preview() -> void:
	for unit in preview_units:
		if is_instance_valid(unit):
			if unit.has_method("set_previewed"):
				unit.set_previewed(false)
			else:
				unit.modulate = Color(1, 1, 1, 1)
	preview_units.clear()

func _process_selection(rect: Rect2) -> void:
	if camera == null:
		return
	if rect.size.x < 3 and rect.size.y < 3:
		return
	for node in get_tree().get_nodes_in_group("main_chars"):
		var n2d := node as Node2D
		var screen_pos := get_viewport().get_canvas_transform() * n2d.global_position
		if rect.has_point(screen_pos):
			_select_unit(n2d)
	if selected_units.size() > 0:
		current_group = agent_manager.create_group()
		for unit in selected_units:
			steering.set_agent_group(unit, current_group)

func _select_unit(unit: Node2D) -> void:
	if not selected_units.has(unit):
		selected_units.append(unit)
		if unit.has_method("set_selected"):
			unit.set_selected(true)
		else:
			unit.modulate = Color(0.8, 1.5, 0.8, 1)

func _clear_selection() -> void:
	for unit in selected_units:
		if is_instance_valid(unit):
			if unit.has_method("set_selected"):
				unit.set_selected(false)
			else:
				unit.modulate = Color(1, 1, 1, 1)
	selected_units.clear()

func _on_click_set_goal() -> void:
	if floorz == null:
		return
	var mouse_pos := get_global_mouse_position()
	var cell := floorz.local_to_map(floorz.to_local(mouse_pos))
	var cell_center := floorz.to_global(floorz.map_to_local(cell))
	marker.global_position = cell_center
	marker.visible = false
	emit_signal("mouse_goal_set", cell_center)
	if flow and flow.has_method("rebuild_async"):
		flow.rebuild_async(cell_center)
		current_flow = flow
	if current_group != -1:
		agent_manager.set_group_flow(current_group, flow.get_id())

func _on_key_spawn_chars() -> void:
	_spawn_mainchar(get_global_mouse_position())

func _on_key_spawn_chars_massive(grappe: int) -> void:
	var pos := get_global_mouse_position()
	for i in range(grappe):
		_spawn_mainchar(pos)

func _spawn_mainchar(pos: Vector2) -> void:
	if floorz == null:
		return
	var target_cell := floorz.local_to_map(floorz.to_local(pos))
	var occupied: Array[Vector2i] = []
	for node in get_tree().get_nodes_in_group("main_chars"):
		occupied.append(floorz.local_to_map(floorz.to_local(node.global_position)))
	var free_cell := _find_free_cell_near(target_cell, occupied)
	var free_pos := floorz.to_global(floorz.map_to_local(free_cell))
	var agent := MainCharScene.instantiate()
	get_parent().add_child(agent)
	agent.global_position = free_pos
	agent.z_index = int(free_pos.y)
	agent.add_to_group("main_chars")
	if steering:
		steering.register_agent(agent, 120.0)

func _find_free_cell_near(start_cell: Vector2i, occupied: Array[Vector2i], max_radius:int=6) -> Vector2i:
	if not occupied.has(start_cell) and _is_walkable(start_cell):
		return start_cell
	for r in range(1, max_radius + 1):
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				var c := start_cell + Vector2i(dx, dy)
				if occupied.has(c):
					continue
				if _is_walkable(c):
					return c
	return start_cell

func _is_walkable(cell: Vector2i) -> bool:
	var has_floor := floorz.get_cell_tile_data(cell) != null
	var has_wall := wallz != null and wallz.get_cell_tile_data(cell) != null
	return has_floor and not has_wall
