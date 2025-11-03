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
var stuck_timer: float = 0.0

var arrival_threshold_sq: float
var separation_radius_sq: float
var perception_radius_sq: float
var frame_counter: int = 0



func _ready() -> void:
	add_to_group("main_chars")
	SpatialGrid.register(self)
	arrival_threshold_sq = arrival_threshold * arrival_threshold
	separation_radius_sq = 24.0 * 24.0
	perception_radius_sq = 48.0 * 48.0

	# Poids de priorité par défaut basé sur instance_id pour unicité
	priority_weight = float(get_instance_id() % 1000) / 1000.0

func _exit_tree() -> void:
	SpatialGrid.unregister(self)


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
	
	# Cadence de mise à jour de la grille (toutes les 2 frames)
	if Engine.get_frames_drawn() % 2 == 0:
		SpatialGrid.update(self)

	frame_counter += 1
	if frame_counter % 10 == 0:
		var local_density: int = path_manager.get_local_density(self)
		# print(local_density)  # facultatif pour observation

	
	if not z_inited:
		z_index = int(global_position.y)
		z_inited = true

	if is_requesting_path or path.is_empty():
		velocity = Vector2.ZERO
		acceleration = Vector2.ZERO
		move_and_slide()
		return
	
		# --- relocalisation automatique si bloqué ---
	if not is_requesting_path and not path.is_empty():
		if velocity.length() < 2.0:
			stuck_timer += delta
			if stuck_timer > 2.0:
				var pf = path_manager.pathfinder
				var goal_cell: Vector2i = pf.world_to_cell(myGoal)
				var occupied_cells: Array[Vector2i] = path_manager.destinations.duplicate()
				var new_goal: Vector2i = pf.find_free_spawn_cell(goal_cell, occupied_cells)
				var goal_pos: Vector2 = Utils.get_tile_pos_from_cell(pf.floor_layer, new_goal)
				_calcule_chemin(goal_pos)
				stuck_timer = 0.0
		else:
			stuck_timer = 0.0
	# --- fin relocalisation automatique ---


	if current_waypoint >= path.size():
		_end_of_movement(true)
		return

	var pos: Vector2 = global_position
	var target_pos: Vector2 = path[current_waypoint]

	var dist_to_target_sq: float = pos.distance_squared_to(target_pos)
	if dist_to_target_sq <= arrival_threshold_sq or (dist_to_target_sq < arrival_threshold_sq * 4.0 and velocity.length() < 3.0):
		current_waypoint += 1
		if current_waypoint >= path.size():
			_end_of_movement(true)
			return
		target_pos = path[current_waypoint]

	# ---- logique vectorielle amortie ----

	# Prépare les voisins locaux via la grille spatiale
	var separation_radius: float = 24.0
	var perception_radius: float = 48.0
	var cell_size_local: float = SpatialGrid.cell_size
	var max_radius: float = max(separation_radius, perception_radius)
	var range_cells: int = int(ceil(max_radius / cell_size_local))
	var neighbors: Array = SpatialGrid.neighbors_at(global_position, range_cells)


	# --- séparation continue amortie ---
	var separation_force: Vector2 = Vector2.ZERO
	for n in neighbors:
		var neighbor: CharacterBody2D = n as CharacterBody2D
		if neighbor == null or neighbor == self:
			continue
		var offset: Vector2 = global_position - neighbor.global_position
		var dist_sq: float = offset.length_squared()
		if dist_sq > 0.001 and dist_sq < separation_radius_sq:
			var strength: float = (separation_radius - sqrt(dist_sq)) / separation_radius
			separation_force += offset.normalized() * strength


	if separation_force != Vector2.ZERO:
		separation_force = separation_force.normalized() * max_force * 0.3
		# amortissement pour éviter le jitter
		separation_force = separation_force.lerp(Vector2.ZERO, 0.7)
	# --- fin séparation continue amortie ---

	
	# variables déjà présentes avant ce bloc :
	var avoidance_force: Vector2 = Vector2.ZERO
	# var perception_radius: float = 48.0        # défini en Bloc 2.1 (ne pas redéclarer ici)
	# var neighbors: Array = SpatialGrid.neighbors_at(...)  # défini en Bloc 2.1
	var prediction_time: float = 0.5

	for n in neighbors:
		var neighbor: CharacterBody2D = n as CharacterBody2D
		if neighbor == null or neighbor == self:
			continue
		var offset: Vector2 = neighbor.global_position - global_position
		var dist_sq: float = offset.length_squared()
		if dist_sq <= 0.001 or dist_sq > perception_radius_sq:
			continue

		var predicted_pos: Vector2 = neighbor.global_position + neighbor.velocity * prediction_time
		var future_offset: Vector2 = predicted_pos - (global_position + velocity * prediction_time)
		var future_dist_sq: float = future_offset.length_squared()
		if future_dist_sq < perception_radius_sq:
			var repulse: Vector2 = -future_offset.normalized() * ((perception_radius - sqrt(future_dist_sq)) / perception_radius)
			avoidance_force += repulse





	# (boucle globale supprimée — remplacée par la version SpatialGrid ci-dessus)


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
			for n in neighbors:
				var neighbor: CharacterBody2D = n as CharacterBody2D
				if neighbor == null or neighbor == self:
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
	var contenders: Array[CharacterBody2D] = []
	for n in neighbors:
		var neighbor: CharacterBody2D = n as CharacterBody2D
		if neighbor == null or neighbor == self:
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
	
	# --- stabilisation à l'arrêt ---
	if path.is_empty() and velocity.length() < 2.0:
		velocity = Vector2.ZERO
		acceleration = Vector2.ZERO

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
