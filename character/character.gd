extends CharacterBody2D

@export var path_manager: Node
@export var speed: float = 8.0
@export var arrival_threshold: float = 10.0

var path: PackedVector2Array = PackedVector2Array()
var current_waypoint: int = 0
var is_requesting_path: bool = false
var has_reserved: bool = false
var reserved_cell: Vector2i = Vector2i.ZERO
var myGoal: Vector2
var z_inited: bool = false

func _ready() -> void:
	add_to_group("main_chars")

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		myGoal = get_global_mouse_position()
		_calcule_chemin(myGoal)

func _calcule_chemin(goal: Vector2) -> void:
	if goal == Vector2.ZERO:
		return

	var start: Vector2 = global_position
	var pf = path_manager.pathfinder
	var floor_layer: TileMapLayer = pf.floor_layer
	var goal_cell: Vector2i = floor_layer.local_to_map(floor_layer.to_local(goal))
	var current_cell: Vector2i = floor_layer.local_to_map(floor_layer.to_local(start))

	# Gestion des destinations réservées (mais pas d’occupation)
	if has_reserved:
		path_manager.destinations.erase(reserved_cell)
	else:
		path_manager.destinations.erase(current_cell)

	var occupied_cells: Array[Vector2i] = path_manager.destinations.duplicate()
	if goal_cell in occupied_cells:
		var free_cell: Vector2i = pf.find_free_spawn_cell(goal_cell, occupied_cells)
		goal_cell = free_cell

	path_manager.destinations.erase(goal_cell)
	path_manager.destinations.append(goal_cell)
	reserved_cell = goal_cell
	has_reserved = true

	var goal_pos: Vector2 = Utils.get_tile_pos_from_cell(floor_layer, goal_cell)
	is_requesting_path = true
	path_manager.request_path(start, goal_pos, Callable(self, "_on_path_ready"))

func _on_path_ready(p: PackedVector2Array) -> void:
	path = p
	current_waypoint = 0
	is_requesting_path = false

func _physics_process(delta: float) -> void:
	if not z_inited:
		z_index = int(global_position.y)
		z_inited = true
	
	if is_requesting_path or path.is_empty():
		velocity = Vector2.ZERO
		move_and_slide()
		return

	if current_waypoint >= path.size():
		_end_of_movement(true)
		return

	var pos: Vector2 = global_position
	var target_pos: Vector2 = path[current_waypoint]

	if pos.distance_to(target_pos) <= arrival_threshold:
		current_waypoint += 1
		if current_waypoint >= path.size():
			_end_of_movement(true)
			return
		target_pos = path[current_waypoint]

	var dir: Vector2 = (target_pos - pos).normalized()
	velocity = dir * speed
	move_and_slide()
	z_index = int(global_position.y)

func _end_of_movement(clear_path: bool = false) -> void:
	if clear_path:
		path.clear()
	velocity = Vector2.ZERO
	z_index = int(global_position.y)
