#controls.gd
extends Node2D

@onready var floorz: TileMapLayer = $"../MonTilemap/floor"
@onready var wallz: TileMapLayer = $"../MonTilemap/wallz"
@onready var flow: FlowField = $"../FlowField"
@onready var marker: Node2D = preload("res://UI_elements/green_circle.tscn").instantiate()

@export var camera: Camera2D
@export var speed: float = 400.0

var lastFPS: float = 0
var MainCharScene: PackedScene = preload("res://character/character.tscn")
var spawngrappe: int = 100
# -----------------------------------------------------
# INITIALISATION
# -----------------------------------------------------

func _ready() -> void:
	add_child(marker)
	marker.visible = false
	marker.z_index = 1
	_start_interval()

# -----------------------------------------------------
# INTERVAL DE DEBUG (facultatif)
# -----------------------------------------------------

func _start_interval() -> void:
	get_tree().create_timer(1.0).timeout.connect(_on_once)

func _on_once() -> void:
	var curFPS = Engine.get_frames_per_second()
	if curFPS != lastFPS:
		print("FPS:", curFPS)
		lastFPS = curFPS
	_start_interval()

# -----------------------------------------------------
# INPUTS UTILISATEUR
# -----------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_on_click_set_goal()
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_A:
		_on_key_spawn_chars()
		var nb_chars: int = get_tree().get_nodes_in_group("main_chars").size()
		print("Chars actifs :", nb_chars)

# -----------------------------------------------------
# ACTIONS
# -----------------------------------------------------

func _on_click_set_goal() -> void:
	var cell_center: Vector2 = Utils.get_tile_pos_from_mouse(floorz)
	marker.global_position = cell_center + Vector2(-8, -8)
	marker.visible = true
	
	# TEMPORAIRE - pour tester :
	# if flow != null:
	#     flow.rebuild_async(cell_center)
	
	emit_signal("mouse_goal_set", cell_center)

func _on_key_spawn_chars() -> void:
	var cell_center: Vector2 = Utils.get_tile_pos_from_mouse(floorz)
	for i in range(spawngrappe):
		_spawn_mainchar(cell_center)

# -----------------------------------------------------
# FONCTION UTILITAIRE : TROUVER UNE CELLULE LIBRE
# -----------------------------------------------------

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
	# Walkable si un tile existe dans floor et aucun tile dans wall
	var has_floor := floorz.get_cell_tile_data(cell) != null
	var has_wall := wallz != null and wallz.get_cell_tile_data(cell) != null
	return has_floor and not has_wall


# -----------------------------------------------------
# SPAWN D'UN AGENT
# -----------------------------------------------------

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
	c.add_to_group("main_chars")
	c.set_meta("flow_ref", flow)

	if has_node("../SteeringSystem"):
		c.steering_system = get_node("../SteeringSystem")
		# Enregistre immédiatement l’agent dans la grille
		if c.steering_system.grid != null:
			c.steering_system.grid.register(c)
	else:
		print("Steering System Not Found")

# -----------------------------------------------------
# CAMERA
# -----------------------------------------------------

func _process(delta: float) -> void:
	if camera == null:
		return
	var input: Vector2 = Vector2.ZERO
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

signal mouse_goal_set(world_pos: Vector2)
