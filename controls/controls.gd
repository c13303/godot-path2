extends Node2D

@onready var floorz: TileMapLayer = $"../MonTilemap/floor"
@onready var wallz: TileMapLayer = $"../MonTilemap/wallz"
@onready var flow: FlowField = $"../FlowField"
@onready var marker: Node2D = preload("res://UI_elements/green_circle.tscn").instantiate()

@onready var steering_native: Node = $"../SteeringSystemNative"

@export var camera: Camera2D
@export var speed: float = 400.0
@export var zoom_speed: float = 0.1
@export var min_zoom: float = 0.5
@export var max_zoom: float = 3.0

var lastFPS: float = 0
var MainCharScene: PackedScene = preload("res://character/character.tscn")
var spawngrappe: int = 50

var dragging: bool = false
var drag_start_pos: Vector2
var camera_start_pos: Vector2

signal mouse_goal_set(world_pos: Vector2)

func _ready() -> void:
	add_child(marker)
	marker.visible = false
	marker.z_index = 1

	var s: Node = null
	var g: Node = null

	if has_node("../SteeringSystemNative"):
		s = get_node("../SteeringSystemNative")
	else:
		print("SteeringSystemNative non trouvé.")

	if has_node("../SpatialGridNative"):
		g = get_node("../SpatialGridNative")
	else:
		print("SpatialGridNative non trouvé.")

	if s:
		if g and s.has_method("set_grid"):
			s.set_grid(g)
			print("Grid connectée au steering natif.")
		if s.has_method("set_flowfield_for_group"):
			s.set_flowfield_for_group(0, flow)
			print("FlowField lié au groupe 0.")
		else:
			print("SteeringSystemNative non valide.")

	_start_interval()

func _start_interval() -> void:
	get_tree().create_timer(1.0).timeout.connect(_on_once)

func _on_once() -> void:
	var curFPS: float = Engine.get_frames_per_second()
	if curFPS != lastFPS:
		print("FPS:", curFPS)
		lastFPS = curFPS
	_start_interval()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_on_click_set_goal()

		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			if camera:
				camera.zoom = Vector2(
					clamp(camera.zoom.x - zoom_speed, min_zoom, max_zoom),
					clamp(camera.zoom.y - zoom_speed, min_zoom, max_zoom)
				)
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			if camera:
				camera.zoom = Vector2(
					clamp(camera.zoom.x + zoom_speed, min_zoom, max_zoom),
					clamp(camera.zoom.y + zoom_speed, min_zoom, max_zoom)
				)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				dragging = true
				drag_start_pos = get_viewport().get_mouse_position()
				camera_start_pos = camera.position
			else:
				dragging = false

	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_A:
		_on_key_spawn_chars()
		print("Chars actifs :", get_tree().get_nodes_in_group("main_chars").size())

func _on_click_set_goal() -> void:
	var cell_center: Vector2 = Utils.get_tile_pos_from_mouse(floorz)
	marker.global_position = cell_center + Vector2(-8, -8)
	marker.visible = true
	emit_signal("mouse_goal_set", cell_center)

func _on_key_spawn_chars() -> void:
	var cell_center: Vector2 = Utils.get_tile_pos_from_mouse(floorz)
	for i in range(spawngrappe):
		_spawn_mainchar(cell_center)

func _find_free_cell_near(flow: FlowField, start_cell: Vector2i, occupied: Array[Vector2i], max_radius: int = 6) -> Vector2i:
	if not occupied.has(start_cell) and _is_walkable(start_cell):
		return start_cell
	for r in range(1, max_radius + 1):
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				var c: Vector2i = start_cell + Vector2i(dx, dy)
				if occupied.has(c):
					continue
				if _is_walkable(c):
					return c
	return start_cell

func _is_walkable(cell: Vector2i) -> bool:
	var has_floor := floorz.get_cell_tile_data(cell) != null
	var has_wall := wallz != null and wallz.get_cell_tile_data(cell) != null
	return has_floor and not has_wall

func _spawn_mainchar(pos: Vector2) -> void:
	var flow_ref: FlowField = flow
	var target_cell: Vector2i = flow_ref.world_to_cell(pos)
	var occupied: Array[Vector2i] = []
	for node in get_tree().get_nodes_in_group("main_chars"):
		var oc: Vector2i = flow_ref.world_to_cell(node.global_position)
		occupied.append(oc)

	var free_cell: Vector2i = _find_free_cell_near(flow_ref, target_cell, occupied)
	var free_pos: Vector2 = flow_ref.cell_to_world(free_cell)
	var c: FlowAgent = MainCharScene.instantiate()
	get_parent().add_child(c)
	c.global_position = free_pos
	c.z_index = int(free_pos.y)
	c.add_to_group("main_chars")
	c.set_meta("flow_ref", flow)

	if steering_native and steering_native.has_method("register_agent"):
		steering_native.register_agent(c, 0, c.max_speed)
	else:
		print("SteeringSystemNative introuvable ou non lié")

func _process(delta: float) -> void:
	if camera == null:
		return

	var input := Vector2.ZERO
	if Input.is_action_pressed("ui_right"): input.x += 1.0
	if Input.is_action_pressed("ui_left"):  input.x -= 1.0
	if Input.is_action_pressed("ui_down"):  input.y += 1.0
	if Input.is_action_pressed("ui_up"):    input.y -= 1.0

	if input != Vector2.ZERO:
		camera.position += input.normalized() * speed * delta

	if dragging and camera:
		var mouse_pos := get_viewport().get_mouse_position()
		var offset := (drag_start_pos - mouse_pos) * camera.zoom
		camera.position = camera_start_pos + offset
