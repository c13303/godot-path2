extends Node

@export var pathfinder: Pathfinding
var destinations: Array[Vector2i] = []
var occupied: Dictionary = {} # cell -> Array[Node]


func _ready() -> void:
	if pathfinder != null:
		pathfinder.build()
	else:
		push_error("Pathfinder non assigné")

func request_path(start: Vector2, goal: Vector2, callback: Callable) -> void:
	if pathfinder == null:
		push_warning("Pathfinder non initialisé")
		return
	var path: PackedVector2Array = pathfinder.find_path(start, goal)
	callback.call(path)
	

func count_people():
	var person_count: int = get_tree().get_nodes_in_group("main_chars").size()
	print("Path calculé (", person_count, " personnages actifs)")

func occupy_cell(pos: Vector2i, agent: Node) -> void:
	if not occupied.has(pos):
		occupied[pos] = []
	var list: Array = occupied[pos]
	if agent not in list:
		list.append(agent)

func free_cell(pos: Vector2i, agent: Node) -> void:
	if not occupied.has(pos):
		return
	var list: Array = occupied[pos]
	list.erase(agent)
	if list.is_empty():
		occupied.erase(pos)

func is_cell_occupied(pos: Vector2i, ignore: Node = null) -> bool:
	if not occupied.has(pos):
		return false
	var list: Array = occupied[pos]
	return list.any(func(a): return a != ignore)

func get_density(pos: Vector2i) -> float:
	if not occupied.has(pos):
		return 0.0
	return float(occupied[pos].size())

	
func should_yield(a: Node, b: Node) -> bool:
	var a_goal = a.path[a.current_waypoint] if a.current_waypoint < a.path.size() else a.global_position
	var b_goal = b.path[b.current_waypoint] if b.current_waypoint < b.path.size() else b.global_position
	return a.global_position.distance_to(a_goal) > b.global_position.distance_to(b_goal)

	
func try_move(agent: Node, from_cell: Vector2i, to_cell: Vector2i) -> bool:
	if not occupied.has(to_cell):
		occupied[to_cell] = [agent]
		if from_cell != to_cell and from_cell != Vector2i.ZERO:
			free_cell(from_cell, agent)
		return true

	# Si la cellule contient déjà l’agent, c’est bon
	if agent in occupied[to_cell]:
		return true

	# Si déjà prise par un autre, refuser
	return false


func count_occupied_cells() -> int:
	return occupied.size()
	
func count_total_agents() -> int:
	var total := 0
	for list in occupied.values():
		total += list.size()
	return total
