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
		"water_cells": water_cells.size(),
		"pool_count": 0,
		"deep_cells": 0,
	}
	if water_cells.is_empty():
		return field

	var components: Array = _connected_components(water_cells)
	field["pool_count"] = components.size()
	var drift_targets: Array[Vector2i] = []
	var deep_cell_count: int = 0
	for raw_component: Variant in components:
		var component: Array[Vector2i] = raw_component as Array[Vector2i]
		var component_deep_cells: Array[Vector2i] = []
		for cell: Vector2i in component:
			if _is_deep_water_cell(cell, water_cells):
				component_deep_cells.append(cell)
		if component_deep_cells.is_empty():
			# Narrow pools have no tile surrounded by all eight neighbors. Give them
			# one stable inward target instead of disabling drowning drift entirely.
			drift_targets.append(_center_cell(component))
		else:
			deep_cell_count += component_deep_cells.size()
			drift_targets.append_array(component_deep_cells)
	field["deep_cells"] = deep_cell_count

	var next_cell_toward_deep: Dictionary = _build_next_cells(water_cells, drift_targets)
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

static func _connected_components(water_cells: Dictionary) -> Array:
	var visited: Dictionary = {}
	var components: Array = []
	for raw_cell: Variant in water_cells.keys():
		var start: Vector2i = raw_cell as Vector2i
		if visited.has(start):
			continue
		var component: Array[Vector2i] = []
		var queue: Array[Vector2i] = [start]
		visited[start] = true
		var read_index: int = 0
		while read_index < queue.size():
			var current: Vector2i = queue[read_index]
			read_index += 1
			component.append(current)
			for offset: Vector2i in NEIGHBORS_8:
				var neighbor: Vector2i = current + offset
				if visited.has(neighbor) or not water_cells.has(neighbor):
					continue
				visited[neighbor] = true
				queue.append(neighbor)
		components.append(component)
	return components

static func _center_cell(component: Array[Vector2i]) -> Vector2i:
	if component.is_empty():
		return Vector2i.ZERO
	var average: Vector2 = Vector2.ZERO
	for cell: Vector2i in component:
		average += Vector2(float(cell.x), float(cell.y))
	average /= float(component.size())
	var best: Vector2i = component[0]
	var best_distance: float = Vector2(float(best.x), float(best.y)).distance_squared_to(average)
	for cell: Vector2i in component:
		var distance: float = Vector2(float(cell.x), float(cell.y)).distance_squared_to(average)
		if distance < best_distance or (is_equal_approx(distance, best_distance) and _cell_precedes(cell, best)):
			best = cell
			best_distance = distance
	return best

static func _cell_precedes(left: Vector2i, right: Vector2i) -> bool:
	return left.y < right.y or (left.y == right.y and left.x < right.x)

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
