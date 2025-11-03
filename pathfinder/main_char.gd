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

func _physics_process(_delta: float) -> void:
	# Si aucun chemin n’est défini ou que tous les points ont été atteints, le mouvement s’arrête
	if path.is_empty() or current_waypoint >= path.size():
		velocity = Vector2.ZERO
		move_and_slide()
		z_index = int(global_position.y)
		return

	# Position centrale du personnage, ajustée verticalement pour un meilleur alignement visuel
	var pos_center: Vector2 = global_position + Vector2(0, offset_y)

	# Cible actuelle correspondant au point du chemin à atteindre
	var target: Vector2 = path[current_waypoint]

	# Vérifie si la position actuelle est suffisamment proche du point cible
	if pos_center.distance_to(target) <= arrival_threshold:
		# Passe au point suivant du chemin
		current_waypoint += 1

		# Si tous les points sont atteints, le mouvement s’arrête
		if current_waypoint >= path.size():
			path.clear()
			velocity = Vector2.ZERO
			move_and_slide()
			z_index = int(global_position.y)
			return

		# Sinon, met à jour la nouvelle cible
		target = path[current_waypoint]

	# Calcule la direction normalisée vers la cible
	var direction: Vector2 = (target - pos_center).normalized()

	# Applique la vitesse dans la direction calculée
	velocity = direction * speed

	# Déplace le personnage selon la vélocité et gère les collisions
	move_and_slide()

	# Met à jour la profondeur d’affichage en fonction de la position verticale
	z_index = int(global_position.y)
