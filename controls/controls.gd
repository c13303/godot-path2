extends Node2D

@onready var floorz: TileMapLayer = $"../MonTilemap/floor"
@onready var wallz: TileMapLayer = $"../MonTilemap/wallz"
@onready var flow: Node = $"../FlowFieldNative"
@onready var steering: Node = $"../SteeringSystemNative"
@onready var marker: Node2D = preload("res://UI_elements/green_circle.tscn").instantiate()

@export var camera: Camera2D
@export var speed: float = 400.0
@export var zoom_speed: float = 0.1
@export var min_zoom: float = 0.5
@export var max_zoom: float = 3.0

var current_flow: Node = null
var dragging: bool = false
var drag_start_pos: Vector2
var camera_start_pos: Vector2
var MainCharScene: PackedScene = preload("res://character/character.tscn")
var spawngrappe: int = 10

signal mouse_goal_set(world_pos: Vector2)

func _ready() -> void:
	add_child(marker)
	marker.visible = false
	marker.z_index = 1
	print("Controls initialized")

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_on_click_set_goal()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed and camera:
			camera.zoom = Vector2(
				clamp(camera.zoom.x - zoom_speed, min_zoom, max_zoom),
				clamp(camera.zoom.y - zoom_speed, min_zoom, max_zoom)
			)
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed and camera:
			camera.zoom = Vector2(
				clamp(camera.zoom.x + zoom_speed, min_zoom, max_zoom),
				clamp(camera.zoom.y + zoom_speed, min_zoom, max_zoom)
			)
		elif event.button_index == MOUSE_BUTTON_RIGHT and camera:
			if event.pressed:
				dragging = true
				drag_start_pos = get_viewport().get_mouse_position()
				camera_start_pos = camera.position
			else:
				dragging = false
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_A:
		_on_key_spawn_chars()
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_Z:
		_on_key_spawn_chars_massive()

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

func _on_click_set_goal() -> void:
	if floorz == null:
		print("Erreur : le TileMapLayer 'floor' est introuvable.")
		return

	var mouse_pos: Vector2 = get_global_mouse_position()
	var local_pos: Vector2 = floorz.to_local(mouse_pos)
	var cell: Vector2i = floorz.local_to_map(local_pos)

	# centre exact de la cellule cliquée
	var cell_center: Vector2 = floorz.to_global(floorz.map_to_local(cell))

	# affiche le marqueur au centre
	marker.global_position = cell_center
	marker.visible = false

	emit_signal("mouse_goal_set", cell_center)

	if flow and flow.has_method("rebuild_async"):
		flow.rebuild_async(cell_center)
		current_flow = flow
	else:
		print("FlowField non trouvé ou inactif.")

func _on_key_spawn_chars() -> void:
	var mouse_pos: Vector2 = get_global_mouse_position()
	_spawn_mainchar(mouse_pos)

func _on_key_spawn_chars_massive() -> void:
	var mouse_pos: Vector2 = get_global_mouse_position()
	for i in range(spawngrappe):
		_spawn_mainchar(mouse_pos)

func _spawn_mainchar(pos: Vector2) -> void:
	if floorz == null:
		print("Erreur : floorz introuvable.")
		return
	var target_cell: Vector2i = floorz.local_to_map(floorz.to_local(pos))
	var occupied: Array[Vector2i] = []
	for node in get_tree().get_nodes_in_group("main_chars"):
		var c: Vector2i = floorz.local_to_map(floorz.to_local(node.global_position))
		occupied.append(c)
	var free_cell: Vector2i = _find_free_cell_near(target_cell, occupied)
	var free_pos: Vector2 = floorz.to_global(floorz.map_to_local(free_cell))
	var agent: Node2D = MainCharScene.instantiate()
	get_parent().add_child(agent)
	agent.global_position = free_pos
	agent.z_index = int(free_pos.y)
	agent.add_to_group("main_chars")

	if steering and steering.has_method("register_agent"):
		var flow_ref = current_flow if current_flow != null else null
		steering.register_agent(agent, 120.0, flow_ref)

func _find_free_cell_near(start_cell: Vector2i, occupied: Array[Vector2i], max_radius: int = 6) -> Vector2i:
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
