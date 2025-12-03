extends Node2D

@onready var floorz: TileMapLayer = $"../MonTilemap/floor"
@onready var wallz: TileMapLayer = $"../MonTilemap/wallz"
@onready var flow: Node = $"../FlowFieldNative"
@onready var steering: Node = $"../SteeringSystemNative"
@onready var agent_manager: Node = $"../AgentManagerNative"
@onready var marker: Node2D = preload("res://UI_elements/green_circle.tscn").instantiate()
@onready var ui_layer: CanvasLayer = $"../CanvasLayer"
const EXPLOSION_DEBUG_SCENE := preload("res://sprites/bomb/bomb.tscn")

@export var explosion_radius: float = 96.0
@export var explosion_intensity: float = 100.0
@export var explosion_debug_duration: float = 1.0

@export var camera: Camera2D
@export var speed: float = 400.0
@export var zoom_speed: float = 0.1
@export var min_zoom: float = 0.5
@export var max_zoom: float = 3.0

var current_flow: Node = null
var current_group: int = -1

var selecting: bool = false
var selection_start: Vector2
var selection_rect: ColorRect

var selected_units: Array[Node2D] = []
var preview_units: Array[Node2D] = []

#signal mouse_goal_set(world_pos: Vector2)

func _ready() -> void:
	add_child(marker)
	marker.visible = false

	if ui_layer:
		selection_rect = ColorRect.new()
		selection_rect.color = Color(0, 1, 0, 0.25)
		selection_rect.visible = false
		selection_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ui_layer.add_child(selection_rect)
	else:
		var canvas := CanvasLayer.new()
		canvas.layer = 100
		add_child(canvas)
		selection_rect = ColorRect.new()
		selection_rect.color = Color(0, 1, 0, 0.25)
		selection_rect.visible = false
		selection_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		canvas.add_child(selection_rect)

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_A:
			_on_key_spawn_chars()
		elif event.keycode == KEY_Z:
			_on_key_spawn_chars_massive(10)
		elif event.keycode == KEY_E:
			_on_key_spawn_chars_massive(50)
		elif event.keycode == KEY_B:
			_on_key_trig_bomb()
			
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
				var mouse_end := get_viewport().get_mouse_position()
				var rect_pos := Vector2(min(selection_start.x, mouse_end.x), min(selection_start.y, mouse_end.y))
				var rect_size := Vector2(abs(mouse_end.x - selection_start.x), abs(mouse_end.y - selection_start.y))
				_process_selection(Rect2(rect_pos, rect_size))

		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			_on_click_set_goal()

		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_towards_mouse(zoom_speed)

		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_towards_mouse(-zoom_speed)

func _process(delta: float) -> void:
	if selecting:
		var mouse_pos := get_viewport().get_mouse_position()
		selection_rect.position = Vector2(min(selection_start.x, mouse_pos.x), min(selection_start.y, mouse_pos.y))
		selection_rect.size = Vector2(abs(mouse_pos.x - selection_start.x), abs(mouse_pos.y - selection_start.y))
		_preview_selection(selection_rect.get_rect())

	var mov := Vector2.ZERO
	if Input.is_key_pressed(KEY_UP):
		mov.y -= 1
	if Input.is_key_pressed(KEY_DOWN):
		mov.y += 1
	if Input.is_key_pressed(KEY_LEFT):
		mov.x -= 1
	if Input.is_key_pressed(KEY_RIGHT):
		mov.x += 1
	if mov != Vector2.ZERO:
		camera.position += mov.normalized() * speed * delta

func _zoom_towards_mouse(amount: float) -> void:
	var mouse_screen: Vector2 = get_viewport().get_mouse_position()

	var xform_before: Transform2D = get_viewport().get_canvas_transform()
	var world_before: Vector2 = xform_before.affine_inverse() * mouse_screen

	var old_zoom: Vector2 = camera.zoom
	var new_zoom: Vector2 = Vector2(
		clamp(old_zoom.x + amount, min_zoom, max_zoom),
		clamp(old_zoom.y + amount, min_zoom, max_zoom)
	)
	camera.zoom = new_zoom

	var xform_after: Transform2D = get_viewport().get_canvas_transform()
	var world_after: Vector2 = xform_after.affine_inverse() * mouse_screen

	camera.position += world_before - world_after








func _preview_selection(rect: Rect2) -> void:
	_clear_preview()
	var xform = get_viewport().get_canvas_transform()
	for node in get_tree().get_nodes_in_group("main_chars"):
		if node is Node2D:
			var screen_pos: Vector2 = xform * node.global_position
			if rect.has_point(screen_pos):
				if node.has_method("set_previewed"):
					node.set_previewed(true)
				else:
					node.modulate = Color(1.2, 1.2, 1.2, 1)
				preview_units.append(node)

func _clear_preview() -> void:
	for unit in preview_units:
		if unit.has_method("set_previewed"):
			unit.set_previewed(false)
		else:
			unit.modulate = Color(1, 1, 1, 1)
	preview_units.clear()

func _process_selection(rect: Rect2) -> void:
	if rect.size.x < 3 and rect.size.y < 3:
		return

	agent_manager.cleanup_groups()
	current_group = agent_manager.create_group()
	selected_units.clear()

	var xform = get_viewport().get_canvas_transform()
	for node in get_tree().get_nodes_in_group("main_chars"):
		if node is Node2D:
			var screen_pos: Vector2 = xform * node.global_position
			if rect.has_point(screen_pos):
				_select_unit(node)
				agent_manager.assign_agent(node, current_group)

	agent_manager.set_current_selected_group(current_group)

func _select_unit(unit: Node2D) -> void:
	if unit not in selected_units:
		selected_units.append(unit)
		if unit.has_method("set_selected"):
			unit.set_selected(true)
		else:
			unit.modulate = Color(0.8, 1.5, 0.8, 1.0)

func _clear_selection() -> void:
	for unit in selected_units:
		if unit.has_method("set_selected"):
			unit.set_selected(false)
		else:
			unit.modulate = Color(1, 1, 1, 1)
	selected_units.clear()

func _on_click_set_goal() -> void:
	if current_group < 0:
		return
	agent_manager.mark_group_has_order(current_group)
	var mouse_pos := get_global_mouse_position()
	var local_pos := floorz.to_local(mouse_pos)
	var cell := floorz.local_to_map(local_pos)
	var center := floorz.to_global(floorz.map_to_local(cell))
	marker.global_position = center
	marker.visible = false
	if flow and flow.has_method("rebuild_async"):
		flow.rebuild_async(center)
		flow.assign_flow_to_group(current_group, center)
		current_flow = flow

func _on_key_spawn_chars() -> void:
	var mouse_pos := get_global_mouse_position()
	_spawn_mainchar(mouse_pos)

func _on_key_spawn_chars_massive(grappe: int) -> void:
	var mouse_pos := get_global_mouse_position()
	for i in range(grappe):
		_spawn_mainchar(mouse_pos)

func _spawn_mainchar(pos: Vector2) -> void:
	if current_group < 1:
		current_group = agent_manager.create_group()
	var target_cell := floorz.local_to_map(floorz.to_local(pos))
	var occupied: Array[Vector2i] = []
	for node in get_tree().get_nodes_in_group("main_chars"):
		occupied.append(floorz.local_to_map(floorz.to_local(node.global_position)))
	var free_cell := _find_free_cell_near(target_cell, occupied)
	var free_pos := floorz.to_global(floorz.map_to_local(free_cell))
	var agent := preload("res://sprites/character/character.tscn").instantiate()
	get_parent().add_child(agent)
	agent.global_position = free_pos
	agent.z_index = int(free_pos.y)
	agent.add_to_group("main_chars")
	var nav_id = agent_manager.spawn_agent(agent, 0)
	agent.nav_id = nav_id

func _find_free_cell_near(start_cell: Vector2i, occupied: Array[Vector2i], max_radius: int = 6) -> Vector2i:
	if start_cell not in occupied and _is_walkable(start_cell):
		return start_cell
	for r in range(1, max_radius + 1):
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				var c := start_cell + Vector2i(dx, dy)
				if c not in occupied and _is_walkable(c):
					return c
	return start_cell

func _is_walkable(cell: Vector2i) -> bool:
	var has_floor := floorz.get_cell_tile_data(cell) != null
	var has_wall := wallz and wallz.get_cell_tile_data(cell) != null
	return has_floor and not has_wall

func _on_key_trig_bomb() -> void:
	var mouse_pos := get_global_mouse_position()
	print("bomb!", mouse_pos)
	if steering and steering.has_method("apply_explosion"):
		steering.apply_explosion(mouse_pos, explosion_radius, explosion_intensity)
	_spawn_explosion_effect(mouse_pos)

func _spawn_explosion_effect(position: Vector2) -> void:
	var circle = EXPLOSION_DEBUG_SCENE.instantiate()
	get_tree().current_scene.add_child(circle)
	circle.global_position = position
	circle.z_index = 99
	var timer = get_tree().create_timer(explosion_debug_duration)
	await timer.timeout
	var scale = explosion_radius / 16
	circle.scale = Vector2(scale, scale)
	if circle.is_inside_tree():
		circle.queue_free()
