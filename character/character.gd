extends CharacterBody2D

@export var path_manager: Node
@export var offset_y: float = 12.0
@export var speed: float = 140.0
@export var arrival_threshold: float = 10.0

var path: PackedVector2Array = PackedVector2Array()
var current_waypoint: int = 0
var has_reserved: bool = false  #pour destinations
var has_last_cell: bool = false
var reserved_cell: Vector2i = Vector2i.ZERO
var last_cell: Vector2i = Vector2i.ZERO


func _ready() -> void:
	add_to_group("main_chars")
	z_index = int(global_position.y)

func _unhandled_input(event: InputEvent) -> void:
	# Détection du clic gauche de la souris
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		# Vérifie qu’un gestionnaire de chemin existe
		if path_manager == null:
			return

		# Détermine la position de départ (centrée sur le personnage)
		var start: Vector2 = global_position + Vector2(0, offset_y)

		# Détermine la position de destination selon la souris
		var goal: Vector2 = get_global_mouse_position()

		# Récupère le pathfinder et le calque du sol
		var pf = path_manager.pathfinder
		var floor_layer = pf.floor_layer

		# Convertit la position actuelle en coordonnées de cellule
		var current_cell: Vector2i = floor_layer.local_to_map(floor_layer.to_local(start))

		# Libère la cellule précédemment réservée, selon l’état du drapeau
		if has_reserved:
			path_manager.destinations.erase(reserved_cell)
		else:
			path_manager.destinations.erase(current_cell)

		# Convertit la position cible en coordonnées de cellule
		var goal_cell: Vector2i = floor_layer.local_to_map(floor_layer.to_local(goal))

		# Copie des cellules actuellement occupées
		var occupied_cells: Array[Vector2i] = path_manager.destinations.duplicate()

		# Si la cellule visée est déjà occupée, cherche une cellule libre proche
		if goal_cell in occupied_cells:
			var free_cell: Vector2i = pf.find_free_spawn_cell(goal_cell, occupied_cells)
			goal_cell = free_cell

		# Met à jour la liste des cellules réservées
		path_manager.destinations.erase(goal_cell)
		path_manager.destinations.append(goal_cell)

		# Enregistre la cellule de destination et marque la réservation active
		reserved_cell = goal_cell
		has_reserved = true

		# Convertit la cellule de destination en position du monde
		var goal_pos: Vector2 = Utils.get_tile_pos_from_cell(floor_layer, goal_cell)

		# Envoie une requête de calcul de chemin au pathfinder
		path_manager.call("request_path", start, goal_pos, func(p): _on_path_ready(p))


func _on_path_ready(p: PackedVector2Array) -> void:
	path = p
	current_waypoint = 0

func _physics_process(delta: float) -> void:
	if path.is_empty() or current_waypoint >= path.size():
		if has_last_cell:
			path_manager.free_cell(last_cell)
			has_last_cell = false
		velocity = Vector2.ZERO
		move_and_slide()
		z_index = int(global_position.y)
		return

	var pos: Vector2 = global_position + Vector2(0, offset_y)
	var target_pos: Vector2 = path[current_waypoint]

	# Waypoint atteint
	if pos.distance_to(target_pos) <= arrival_threshold:
		current_waypoint += 1
		if current_waypoint >= path.size():
			path.clear()
			if has_last_cell:
				path_manager.free_cell(last_cell, self)
				has_last_cell = false
			velocity = Vector2.ZERO
			move_and_slide()
			z_index = int(global_position.y)
			return
		target_pos = path[current_waypoint]

	var dir: Vector2 = (target_pos - pos).normalized()
	var tile_size: Vector2 = path_manager.pathfinder.floor_layer.tile_set.tile_size
	var next_pos: Vector2 = pos + dir * speed * delta
	var next_cell: Vector2i = path_manager.pathfinder.world_to_cell(next_pos)

	# Feu rouge : s'arrêter seulement si la cellule suivante est occupée par un autre agent
	if path_manager.is_cell_occupied(next_cell, self):
		velocity = Vector2.ZERO
		move_and_slide()
		z_index = int(global_position.y)
		return

	# Mise à jour des cellules
	if has_last_cell and last_cell != next_cell:
		path_manager.free_cell(last_cell, self)
	path_manager.occupy_cell(next_cell, self)
	last_cell = next_cell
	has_last_cell = true

	# Avance normale
	velocity = dir * speed
	move_and_slide()
	z_index = int(global_position.y)
