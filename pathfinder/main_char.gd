extends CharacterBody2D

@export var path_manager: Node
@export var offset_y: float = 12.0
@export var speed: float = 140.0
@export var arrival_threshold: float = 10.0

var path: PackedVector2Array = PackedVector2Array()
var current_waypoint: int = 0
var reserved_cell: Vector2i
var has_reserved: bool = false

func _ready() -> void:
	add_to_group("main_chars")
	z_index = int(global_position.y)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if path_manager == null:
			return
		var start: Vector2 = global_position + Vector2(0, offset_y)
		var goal: Vector2 = get_global_mouse_position()
		var pf = path_manager.pathfinder
		var floor_layer = pf.floor_layer

		var current_cell: Vector2i = floor_layer.local_to_map(floor_layer.to_local(start))

		if has_reserved:
			path_manager.destinations.erase(reserved_cell)
		else:
			path_manager.destinations.erase(current_cell)

		var goal_cell: Vector2i = floor_layer.local_to_map(floor_layer.to_local(goal))
		var occupied_cells: Array[Vector2i] = path_manager.destinations.duplicate()

		if goal_cell in occupied_cells:
			var free_cell: Vector2i = pf.find_free_spawn_cell(goal_cell, occupied_cells)
			goal_cell = free_cell

		path_manager.destinations.erase(goal_cell)
		path_manager.destinations.append(goal_cell)

		reserved_cell = goal_cell
		has_reserved = true

		var goal_pos: Vector2 = Utils.get_tile_pos_from_cell(floor_layer, goal_cell)
		path_manager.call("request_path", start, goal_pos, func(p): _on_path_ready(p))

func _on_path_ready(p: PackedVector2Array) -> void:
	path = p
	current_waypoint = 0

func _physics_process(_delta: float) -> void:
	if path.is_empty() or current_waypoint >= path.size():
		velocity = Vector2.ZERO
		move_and_slide()
		z_index = int(global_position.y)
		return
	var pos_center: Vector2 = global_position + Vector2(0, offset_y)
	var target: Vector2 = path[current_waypoint]
	if pos_center.distance_to(target) <= arrival_threshold:
		current_waypoint += 1
		if current_waypoint >= path.size():
			path.clear()
			velocity = Vector2.ZERO
			move_and_slide()
			z_index = int(global_position.y)
			return
		target = path[current_waypoint]
	var direction: Vector2 = (target - pos_center).normalized()
	velocity = direction * speed
	move_and_slide()
	z_index = int(global_position.y)
