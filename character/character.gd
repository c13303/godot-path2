extends CharacterBody2D

@export var path_manager: Node
@export var speed: float = 8.0 # px/s
@export var arrival_threshold: float = 10.0
@export var decal_delay_ms: float = 100.0

var path: PackedVector2Array = PackedVector2Array()
var current_waypoint: int = 0
var is_requesting_path: bool = false
var has_reserved: bool = false
var has_last_cell: bool = false
var reserved_cell: Vector2i = Vector2i.ZERO
var last_cell: Vector2i = Vector2i.ZERO
var myGoal: Vector2
var myDecalGoal: Vector2 = Vector2.ZERO
var current_dir: Vector2i = Vector2i.ZERO
var is_waiting_decal: bool = false
var is_decaltarget: bool = false
var decal_timer: float = 0.0
var distance_to_accept_goal_while_decaling = 2 #en tiles


func _ready() -> void:
	add_to_group("main_chars")
	z_index = int(global_position.y)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		myGoal = get_global_mouse_position()
		_calcule_chemin(myGoal)


func _calcule_chemin(goal: Vector2) -> void:
	var start: Vector2 = global_position

	if goal == Vector2.ZERO:
		return

	var pf = path_manager.pathfinder
	var floor_layer = pf.floor_layer
	var goal_cell: Vector2i = floor_layer.local_to_map(floor_layer.to_local(goal))
	var current_cell: Vector2i = floor_layer.local_to_map(floor_layer.to_local(start))

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
	path_manager.call("request_path", start, goal_pos, func(p): _on_path_ready(p))


func _on_path_ready(p: PackedVector2Array) -> void:
	path = p
	current_waypoint = 0
	is_requesting_path = false


func _end_of_movement(clear_path: bool = false) -> void:
	if clear_path:
		path.clear()
	velocity = Vector2.ZERO
	z_index = int(global_position.y)


func _physics_process(delta: float) -> void:
	# Attente de calcul de chemin
	if is_requesting_path:
		return
	
	# phase 1 — attente avant de tenter un décalage
	if is_waiting_decal:
		decal_timer -= delta * 1000.0
		if decal_timer <= 0.0:
			_try_decal()
		return

	# phase 2 — déplacement vers case de décalage
	if is_decaltarget:
		_process_path(delta)
		return

	# phase 3 — déplacement normal
	_process_path(delta)


func _process_path(delta: float) -> void:
	if path.is_empty():
		_end_of_movement(true)
		return

	if current_waypoint >= path.size():
		_end_of_movement(true)
		return

	var pos: Vector2 = global_position
	var target_pos: Vector2 = path[current_waypoint]

	if pos.distance_to(target_pos) <= arrival_threshold:
		current_waypoint += 1

		if current_waypoint >= path.size():
			var final_cell: Vector2i = path_manager.pathfinder.world_to_cell(global_position)
			path_manager.occupy_cell(final_cell, self)
			last_cell = final_cell
			has_last_cell = true
			_end_of_movement(true)

			if is_decaltarget:
				is_decaltarget = false
				_calcule_chemin(myGoal)
			return

		target_pos = path[current_waypoint]

	var dir: Vector2 = (target_pos - pos).normalized()
	if dir.length() > 0.01:
		current_dir = Vector2i(sign(dir.x), sign(dir.y))

	# Calculer la prochaine position AVEC move_and_slide
	velocity = dir * speed
	
	move_and_slide()
	
	var next_cell: Vector2i = path_manager.pathfinder.world_to_cell(global_position + velocity * delta)

	if path_manager.is_cell_occupied(next_cell, self):
		# bloque → on lance un délai de décalage
		is_waiting_decal = true
		decal_timer = decal_delay_ms
		_end_of_movement(false)
		return

	if has_last_cell and last_cell != next_cell:
		path_manager.free_cell(last_cell, self)

	path_manager.occupy_cell(next_cell, self)
	last_cell = next_cell
	has_last_cell = true

	

	z_index = int(global_position.y)


func _try_decal() -> void:
	var pos: Vector2 = global_position
	var free = path_manager.find_nearest_free_cell(pos, 1, current_dir, self)

	if free != null and typeof(free) == TYPE_VECTOR2:
		# print("Décalage vers", free)
		is_waiting_decal = false
		is_decaltarget = true
		myDecalGoal = free
		_calcule_chemin(free)
	else:
		# print("Aucune case libre trouvée :", pos)
		is_waiting_decal = true
		decal_timer = decal_delay_ms
