extends Node

@export var pathfinder: Pathfinding
var destinations: Array[Vector2i] = []
var future_reservations: Dictionary = {}


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

func count_people() -> void:
	var person_count: int = get_tree().get_nodes_in_group("main_chars").size()
	print("Path calculé (", person_count, " personnages actifs)")


func try_reserve_future(cell: Vector2i, agent: Node) -> bool:
	var id: int = agent.get_instance_id()
	if not future_reservations.has(cell):
		future_reservations[cell] = id
		return true
	var current_id: int = int(future_reservations[cell])
	if id < current_id:
		future_reservations[cell] = id
		return true
	return current_id == id

func release_future(cell: Vector2i, agent: Node) -> void:
	var id: int = agent.get_instance_id()
	if future_reservations.has(cell) and int(future_reservations[cell]) == id:
		future_reservations.erase(cell)

func is_future_reserved_by_other(cell: Vector2i, agent: Node) -> bool:
	var id: int = agent.get_instance_id()
	if not future_reservations.has(cell):
		return false
	return int(future_reservations[cell]) != id
