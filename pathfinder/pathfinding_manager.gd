extends Node

@export var pathfinder: Pathfinding
var destinations: Array[Vector2] = []

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
	#var person_count: int = get_tree().get_nodes_in_group("main_chars").size()
	#print("Path calculé (", person_count, " personnages actifs)")
