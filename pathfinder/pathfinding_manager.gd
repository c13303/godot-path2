extends Node

@export var pathfinder: Pathfinding
var destinations: Array[Vector2i] = []
var occupied: Dictionary = {} # cell -> int

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

func occupy_cell(pos: Vector2i) -> void:
	occupied[pos] = occupied.get(pos, 0) + 1

func free_cell(pos: Vector2i) -> void:
	if not occupied.has(pos):
		return
	var value = occupied[pos]
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		value = 1
	value -= 1
	if value > 0:
		occupied[pos] = value
	else:
		occupied.erase(pos)


func get_density(pos: Vector2i) -> float:
	var value = occupied.get(pos)
	if typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT:
		return float(value)
	return 0.0


func is_cell_occupied(pos: Vector2i) -> bool:
	return occupied.has(pos)
	
func should_yield(a: Node, b: Node) -> bool:
	var a_goal = a.path[a.current_waypoint] if a.current_waypoint < a.path.size() else a.global_position
	var b_goal = b.path[b.current_waypoint] if b.current_waypoint < b.path.size() else b.global_position
	return a.global_position.distance_to(a_goal) > b.global_position.distance_to(b_goal)

	
func try_move(agent: Node, from_cell: Vector2i, to_cell: Vector2i) -> bool:
	if not occupied.has(to_cell):
		occupied[to_cell] = agent
		if from_cell != null:
			occupied.erase(from_cell)
		return true

	var other = occupied[to_cell]
	if should_yield(agent, other):
		return false

	occupied[to_cell] = agent
	if from_cell != null:
		occupied.erase(from_cell)
	return true
