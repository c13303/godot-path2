extends RefCounted
class_name Waterpools

const NEIGHBORS_8: Array[Vector2i] = [
	Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
	Vector2i(-1, 0),                    Vector2i(1, 0),
	Vector2i(-1, 1),  Vector2i(0, 1),  Vector2i(1, 1),
]

static func build_directional_field(used_cells: Array[Vector2i]) -> Dictionary:
	var water_cells: Dictionary = {}
	for cell: Vector2i in used_cells:
		water_cells[cell] = true

	var field: Dictionary = {
		"cells": PackedVector2Array(),
		"directions": PackedVector2Array(),
	}
	if water_cells.is_empty():
		return field

	var deep_cells: Array[Vector2i] = []
	for raw_cell: Variant in water_cells.keys():
		var cell: Vector2i = raw_cell as Vector2i
		if _is_deep_water_cell(cell, water_cells):
			deep_cells.append(cell)

	if deep_cells.is_empty():
		return field

	var next_cell_toward_deep: Dictionary = _build_next_cells(water_cells, deep_cells)
	var field_cells: PackedVector2Array = PackedVector2Array()
	var field_directions: PackedVector2Array = PackedVector2Array()

	for raw_cell: Variant in next_cell_toward_deep.keys():
		var cell: Vector2i = raw_cell as Vector2i
		var next_cell: Vector2i = next_cell_toward_deep[cell] as Vector2i
		if cell == next_cell:
			continue
		var delta: Vector2i = next_cell - cell
		var direction: Vector2 = Vector2(float(delta.x), float(delta.y)).normalized()
		if direction == Vector2.ZERO:
			continue
		field_cells.append(Vector2(float(cell.x), float(cell.y)))
		field_directions.append(direction)

	field["cells"] = field_cells
	field["directions"] = field_directions
	return field

static func _is_deep_water_cell(cell: Vector2i, water_cells: Dictionary) -> bool:
	for offset: Vector2i in NEIGHBORS_8:
		if not water_cells.has(cell + offset):
			return false
	return true

static func _build_next_cells(water_cells: Dictionary, deep_cells: Array[Vector2i]) -> Dictionary:
	var next_cell_toward_deep: Dictionary = {}
	var queue: Array[Vector2i] = []
	for deep_cell: Vector2i in deep_cells:
		next_cell_toward_deep[deep_cell] = deep_cell
		queue.append(deep_cell)

	var read_index: int = 0
	while read_index < queue.size():
		var current: Vector2i = queue[read_index]
		read_index += 1
		for offset: Vector2i in NEIGHBORS_8:
			var neighbor: Vector2i = current + offset
			if not water_cells.has(neighbor):
				continue
			if next_cell_toward_deep.has(neighbor):
				continue
			next_cell_toward_deep[neighbor] = current
			queue.append(neighbor)

	return next_cell_toward_deep
