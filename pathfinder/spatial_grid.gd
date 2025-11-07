#spatial_grid.gd

extends Node
class_name SpatialGrid

@export var cell_size: float = 32.0

var buckets: Dictionary[Vector2i, Array] = {}
var last_cell: Dictionary[int, Vector2i] = {}

func _cell(p: Vector2) -> Vector2i:
	return Vector2i(floor(p.x / cell_size), floor(p.y / cell_size))

func clear() -> void:
	buckets.clear()
	last_cell.clear()

func register(a: Node2D) -> void:
	var id: int = a.get_instance_id()
	var c: Vector2i = _cell(a.global_position)
	last_cell[id] = c
	var arr: Array = buckets.get(c, [])
	arr.append(a)
	buckets[c] = arr

func update(a: Node2D) -> void:
	var id: int = a.get_instance_id()
	var prev: Variant = last_cell.get(id, null)
	var cur: Vector2i = _cell(a.global_position)
	if prev == cur:
		return
	if prev != null and buckets.has(prev):
		var arr: Array = buckets[prev]
		var idx: int = arr.find(a)
		if idx != -1:
			arr.remove_at(idx)
		if arr.is_empty():
			buckets.erase(prev)
		else:
			buckets[prev] = arr
	var arr2: Array = buckets.get(cur, [])
	arr2.append(a)
	buckets[cur] = arr2
	last_cell[id] = cur

func unregister(a: Node2D) -> void:
	var id: int = a.get_instance_id()
	if last_cell.has(id):
		var c: Vector2i = last_cell[id]
		if buckets.has(c):
			var arr: Array = buckets[c]
			var idx: int = arr.find(a)
			if idx != -1:
				arr.remove_at(idx)
			if arr.is_empty():
				buckets.erase(c)
			else:
				buckets[c] = arr
		last_cell.erase(id)

func neighbors_at(pos: Vector2, range_cells: int = 1) -> Array:
	var base: Vector2i = _cell(pos)
	var out: Array = []
	for dx in range(-range_cells, range_cells + 1):
		for dy in range(-range_cells, range_cells + 1):
			var c: Vector2i = base + Vector2i(dx, dy)
			if buckets.has(c):
				out.append_array(buckets[c])
	return out
