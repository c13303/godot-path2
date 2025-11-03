extends CharacterBody2D

@export var path_manager: Node
@export var max_speed: float = 80.0
@export var max_force: float = 600.0
@export var arrival_threshold: float = 10.0
@export var steering_smooth: float = 0.25  # 0–1, plus haut = plus réactif

var path: PackedVector2Array = PackedVector2Array()
var current_waypoint: int = 0
var is_requesting_path: bool = false
var has_reserved: bool = false
var reserved_cell: Vector2i = Vector2i.ZERO
var myGoal: Vector2
var z_inited: bool = false

var acceleration: Vector2 = Vector2.ZERO




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
		acceleration = Vector2.ZERO
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

	# ---- logique vectorielle amortie ----
	
		# --- perception locale ---
	var avoidance_force: Vector2 = Vector2.ZERO
	var perception_radius: float = 32.0

	# Détection des agents voisins
	for neighbor in get_tree().get_nodes_in_group("main_chars"):
		if neighbor == self:
			continue
		var offset: Vector2 = neighbor.global_position - pos
		var dist: float = offset.length()
		if dist < 0.001 or dist > perception_radius:
			continue
		var repulse: Vector2 = -offset.normalized() * ((perception_radius - dist) / perception_radius)
		avoidance_force += repulse

	# Détection basique des murs via le pathfinder
	var pf = path_manager.pathfinder
	var cell: Vector2i = pf.world_to_cell(pos)
	var dirs: Array[Vector2i] = [
		Vector2i(1, 0), Vector2i(-1, 0),
		Vector2i(0, 1), Vector2i(0, -1)
	]
	for d in dirs:
		var c: Vector2i = cell + d
		if not pf.walkable_cells.has(c):
			var wall_pos: Vector2 = Utils.get_tile_pos_from_cell(pf.floor_layer, c)
			var dir: Vector2 = wall_pos - pos
			var dist: float = dir.length()
			if dist < perception_radius:
				avoidance_force -= dir.normalized() * ((perception_radius - dist) / perception_radius)

	if avoidance_force != Vector2.ZERO:
		avoidance_force = avoidance_force.normalized() * max_force * 0.5
	# --- fin perception locale ---

	
	
	var desired: Vector2 = (target_pos - pos).normalized() * max_speed

	# --- correctif perception locale ---
	var goal_dist: float = pos.distance_to(target_pos)
	var avoid_weight: float = clamp(goal_dist / 128.0, 0.0, 1.0)
	avoidance_force = avoidance_force.lerp(Vector2.ZERO, 0.5)
	desired += avoidance_force * avoid_weight
	# --- fin correctif perception locale ---

	var steering: Vector2 = desired - velocity
	if steering.length() > max_force:
		steering = steering.normalized() * max_force


	# interpolation douce pour éviter les oscillations
	acceleration = acceleration.lerp(steering, steering_smooth)
	velocity += acceleration * delta
	if velocity.length() > max_speed:
		velocity = velocity.normalized() * max_speed

	# simplification : recentrer un peu sur la direction cible
	velocity = velocity.lerp(desired, 0.5)

	move_and_slide()
	z_index = int(global_position.y)
	# -------------------------------------

func _end_of_movement(clear_path: bool = false) -> void:
	if clear_path:
		path.clear()
	velocity = Vector2.ZERO
	acceleration = Vector2.ZERO
	z_index = int(global_position.y)
