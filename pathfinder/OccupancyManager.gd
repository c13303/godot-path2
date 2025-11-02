extends Node
class_name OccupancyManager

var occupied: Dictionary = {} # Vector2i -> Node

func is_occupied(cell: Vector2i) -> bool:
	return occupied.has(cell)

func reserve(cell: Vector2i, who: Node) -> void:
	var prev = occupied.get(cell, null)
	if prev == null or prev == who:
		occupied[cell] = who

func release(cell: Vector2i) -> void:
	if occupied.has(cell):
		occupied.erase(cell)

func find_nearest_free(cell: Vector2i, walkable: Array[Vector2i]) -> Vector2i:
	if walkable.is_empty():
		return cell
	if walkable.has(cell) and not is_occupied(cell):
		return cell

	var best: Vector2i = cell
	var best_dist: float = INF

	for c in walkable:
		if not is_occupied(c):
			var d: float = (Vector2(c) - Vector2(cell)).length()
			if d < best_dist:
				best_dist = d
				best = c

	if best_dist == INF:
		return cell
	return best
