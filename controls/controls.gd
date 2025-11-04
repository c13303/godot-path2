extends Node2D

@onready var floorz: TileMapLayer = $"../MonTilemap/floor"
@onready var path_manager: PathManager = $"../PathfindingManager"
@onready var marker: Node2D = preload("res://UI_elements/green_circle.tscn").instantiate()

@export var camera: Camera2D
@export var speed: float = 400.0

var MainCharScene: PackedScene = preload("res://character/character.tscn")

# -----------------------------------------------------
# INITIALISATION
# -----------------------------------------------------

func _ready() -> void:
	add_child(marker)
	marker.visible = false
	marker.z_index = 1
	#print("Flow system ready.")
	_start_interval()

# -----------------------------------------------------
# INTERVAL DE DEBUG (facultatif)
# -----------------------------------------------------

func _start_interval() -> void:
	get_tree().create_timer(1.0).timeout.connect(_on_once)

func _on_once() -> void:
	#debug every 1s
	print("FPS:", Engine.get_frames_per_second())
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
	marker.global_position = cell_center
	marker.visible = true
	if path_manager != null:
		path_manager.set_goal(cell_center)
	

func _on_key_spawn_chars() -> void:
	var cell_center: Vector2 = Utils.get_tile_pos_from_mouse(floorz)
	for i in range(50):
		_spawn_mainchar(cell_center)

# -----------------------------------------------------
# FONCTION UTILITAIRE : TROUVER UNE CELLULE LIBRE
# -----------------------------------------------------
func _find_free_cell_near(flow: FlowField, start_cell: Vector2i, occupied: Array[Vector2i], max_radius: int = 6) -> Vector2i:
	var walkable: Array[Vector2i] = flow._walkable
	if not occupied.has(start_cell) and walkable.has(start_cell):
		return start_cell

	for r in range(1, max_radius + 1):
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				var c: Vector2i = start_cell + Vector2i(dx, dy)
				if not walkable.has(c) or occupied.has(c):
					continue
				return c
	return start_cell


# -----------------------------------------------------
# SPAWN D'UN AGENT
# -----------------------------------------------------
func _spawn_mainchar(pos: Vector2) -> void:
	if path_manager == null or path_manager.flow == null:
		return

	var flow: FlowField = path_manager.flow
	var target_cell: Vector2i = flow.world_to_cell(pos)

	# --- sélection d'une cellule libre ---
	var occupied: Array[Vector2i] = []
	for node in get_tree().get_nodes_in_group("main_chars"):
		var oc: Vector2i = flow.world_to_cell(node.global_position)
		occupied.append(oc)

	var free_cell: Vector2i = _find_free_cell_near(flow, target_cell, occupied)
	var free_pos: Vector2 = flow.cell_to_world(free_cell)

	# --- instanciation ---
	var c: CharacterBody2D = MainCharScene.instantiate()
	get_parent().add_child(c)
	c.global_position = free_pos
	c.path_manager = path_manager
	c.add_to_group("main_chars")
	
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
