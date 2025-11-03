extends CharacterBody2D

@export var path_manager: Node
@export var max_speed: float = 80.0
@export var max_force: float = 600.0
@export var arrival_threshold: float = 10.0
@export var steering_smooth: float = 0.25  # 0–1, plus haut = plus réactif
@export var priority_weight: float = 1.0

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
	# Poids de priorité par défaut basé sur instance_id pour unicité
	priority_weight = float(get_instance_id() % 1000) / 1000.0

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

	# --- séparation continue amortie ---
	var separation_force: Vector2 = Vector2.ZERO
	var separation_radius: float = 24.0

	for neighbor in get_tree().get_nodes_in_group("main_chars"):
		if neighbor == self:
			continue
		var offset: Vector2 = global_position - neighbor.global_position
		var dist: float = offset.length()
		if dist > 0.001 and dist < separation_radius:
			var strength: float = (separation_radius - dist) / separation_radius
			separation_force += offset.normalized() * strength

	if separation_force != Vector2.ZERO:
		separation_force = separation_force.normalized() * max_force * 0.3
		# amortissement pour éviter le jitter
		separation_force = separation_force.lerp(Vector2.ZERO, 0.7)
	# --- fin séparation continue amortie ---

	
	# --- perception anticipée (pré-flux) ---
	var avoidance_force: Vector2 = Vector2.ZERO
	var perception_radius: float = 48.0
	var prediction_time: float = 0.5

	for neighbor in get_tree().get_nodes_in_group("main_chars"):
		if neighbor == self:
			continue
		var offset: Vector2 = neighbor.global_position - global_position
		var dist: float = offset.length()
		if dist <= 0.001 or dist > perception_radius:
			continue

		# position future prédite
		var predicted_pos: Vector2 = neighbor.global_position + neighbor.velocity * prediction_time
		var future_offset: Vector2 = predicted_pos - (global_position + velocity * prediction_time)
		var future_dist: float = future_offset.length()
		if future_dist < perception_radius:
			var repulse: Vector2 = -future_offset.normalized() * ((perception_radius - future_dist) / perception_radius)
			avoidance_force += repulse

	# amortissement de la force
	if avoidance_force != Vector2.ZERO:
		avoidance_force = avoidance_force.normalized() * max_force * 0.6
	# --- fin perception anticipée ---


	
	
	var desired: Vector2 = (target_pos - pos).normalized() * max_speed
	desired += separation_force


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

	
	# --- pré-réservation dynamique ---
	var next_pos: Vector2 = global_position + velocity * delta
	var next_cell: Vector2i = path_manager.pathfinder.world_to_cell(next_pos)

	# --- cession selon priorité ---
	var can_move: bool = path_manager.try_reserve_future(next_cell, self)
	var reserved_by_other: bool = path_manager.is_future_reserved_by_other(next_cell, self)

	if reserved_by_other:
		var winner_id: int = int(path_manager.future_reservations[next_cell])
		if winner_id != get_instance_id():
			for neighbor in get_tree().get_nodes_in_group("main_chars"):
				if neighbor == self:
					continue
				if neighbor.get_instance_id() == winner_id:
					if neighbor.priority_weight >= priority_weight:
						velocity *= 0.2
					break
	elif not can_move:
		velocity *= 0.5
	# --- fin cession selon priorité ---


	if not can_move or path_manager.is_future_reserved_by_other(next_cell, self):
		velocity *= 0.5
	# --- fin pré-réservation dynamique ---


	# --- résolution déterministe de conflits multiples ---
	var current_cell: Vector2i = path_manager.pathfinder.world_to_cell(global_position)
	var contenders: Array = []
	for neighbor in get_tree().get_nodes_in_group("main_chars"):
		if neighbor == self:
			continue
		var n_cell: Vector2i = path_manager.pathfinder.world_to_cell(neighbor.global_position)
		if n_cell == current_cell:
			contenders.append(neighbor)

	if contenders.size() > 1:
		contenders.append(self)
		contenders.sort_custom(func(a, b): return a.priority_weight > b.priority_weight)
		var top: CharacterBody2D = contenders[0]
		if top != self:
			var rank: int = contenders.find(self)
			var factor: float = clamp(1.0 - float(rank) / contenders.size(), 0.1, 1.0)
			velocity *= factor
	# --- fin résolution déterministe ---


	move_and_slide()
	
	path_manager.release_future(next_cell, self)

	
	z_index = int(global_position.y)
	# -------------------------------------

func _end_of_movement(clear_path: bool = false) -> void:
	if clear_path:
		path.clear()
	velocity = Vector2.ZERO
	acceleration = Vector2.ZERO
	z_index = int(global_position.y)
