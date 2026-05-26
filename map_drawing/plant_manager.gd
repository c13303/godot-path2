extends Node
class_name PlantManager

signal plant_added(cell: Vector2i)
signal plant_removed(cell: Vector2i)

const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)

@export var plantz: TileMapLayer
@export var bucket_size: int = 16

var _plants: Dictionary = {}
var _buckets: Dictionary = {}
var _initialized: bool = false

func _ready() -> void:
	initialize_from_layer()

func initialize_from_layer() -> void:
	_plants.clear()
	_buckets.clear()
	if not plantz:
		_initialized = true
		return
	for raw_cell in plantz.get_used_cells():
		var cell: Vector2i = raw_cell
		_index_cell(cell)
	_initialized = true

func is_initialized() -> bool:
	return _initialized

func has_plant(cell: Vector2i) -> bool:
	return _plants.has(cell)

func is_empty() -> bool:
	return _plants.is_empty()

func size() -> int:
	return _plants.size()

func get_plant_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for raw_cell in _plants.keys():
		var cell: Vector2i = raw_cell
		cells.append(cell)
	return cells

func add_plant(cell: Vector2i) -> void:
	if _plants.has(cell):
		return
	_index_cell(cell)
	plant_added.emit(cell)

func remove_plant(cell: Vector2i, erase_tile: bool = true) -> void:
	if not _plants.has(cell):
		return
	_unindex_cell(cell)
	if erase_tile and plantz:
		plantz.erase_cell(cell)
		plantz.update_internals()
	plant_removed.emit(cell)

func nearest_plant_cell(from_cell: Vector2i, excluded_cell: Vector2i = INVALID_CELL) -> Vector2i:
	if _plants.is_empty():
		return INVALID_CELL

	var origin_bucket: Vector2i = _bucket_for_cell(from_cell)
	var best_cell: Vector2i = INVALID_CELL
	var best_dist_sq: int = 2147483647
	var max_radius: int = _max_bucket_search_radius(origin_bucket)

	for radius in range(0, max_radius + 1):
		var radius_min_dist_sq: int = _bucket_ring_min_dist_sq(from_cell, origin_bucket, radius)
		if best_cell != INVALID_CELL and radius_min_dist_sq > best_dist_sq:
			break
		for bucket in _bucket_ring(origin_bucket, radius):
			if not _buckets.has(bucket):
				continue
			var bucket_cells: Dictionary = _buckets[bucket] as Dictionary
			for raw_cell in bucket_cells.keys():
				var cell: Vector2i = raw_cell
				if cell == excluded_cell:
					continue
				var d: Vector2i = cell - from_cell
				var dist_sq: int = d.x * d.x + d.y * d.y
				if dist_sq < best_dist_sq:
					best_dist_sq = dist_sq
					best_cell = cell

	return best_cell

func _index_cell(cell: Vector2i) -> void:
	_plants[cell] = true
	var bucket: Vector2i = _bucket_for_cell(cell)
	if not _buckets.has(bucket):
		_buckets[bucket] = {}
	var bucket_cells: Dictionary = _buckets[bucket] as Dictionary
	bucket_cells[cell] = true
	_buckets[bucket] = bucket_cells

func _unindex_cell(cell: Vector2i) -> void:
	_plants.erase(cell)
	var bucket: Vector2i = _bucket_for_cell(cell)
	if not _buckets.has(bucket):
		return
	var bucket_cells: Dictionary = _buckets[bucket] as Dictionary
	bucket_cells.erase(cell)
	if bucket_cells.is_empty():
		_buckets.erase(bucket)
	else:
		_buckets[bucket] = bucket_cells

func _bucket_for_cell(cell: Vector2i) -> Vector2i:
	var size_i: int = max(1, bucket_size)
	return Vector2i(floori(float(cell.x) / float(size_i)), floori(float(cell.y) / float(size_i)))

func _bucket_ring(origin: Vector2i, radius: int) -> Array[Vector2i]:
	var buckets: Array[Vector2i] = []
	if radius == 0:
		buckets.append(origin)
		return buckets
	for x in range(origin.x - radius, origin.x + radius + 1):
		buckets.append(Vector2i(x, origin.y - radius))
		buckets.append(Vector2i(x, origin.y + radius))
	for y in range(origin.y - radius + 1, origin.y + radius):
		buckets.append(Vector2i(origin.x - radius, y))
		buckets.append(Vector2i(origin.x + radius, y))
	return buckets

func _bucket_ring_min_dist_sq(from_cell: Vector2i, origin_bucket: Vector2i, radius: int) -> int:
	if radius == 0:
		return 0
	var size_i: int = max(1, bucket_size)
	var inner_radius: int = radius - 1
	var inner_min_x: int = (origin_bucket.x - inner_radius) * size_i
	var inner_max_x: int = ((origin_bucket.x + inner_radius + 1) * size_i) - 1
	var inner_min_y: int = (origin_bucket.y - inner_radius) * size_i
	var inner_max_y: int = ((origin_bucket.y + inner_radius + 1) * size_i) - 1
	var left_dx: int = from_cell.x - (inner_min_x - 1)
	var right_dx: int = (inner_max_x + 1) - from_cell.x
	var top_dy: int = from_cell.y - (inner_min_y - 1)
	var bottom_dy: int = (inner_max_y + 1) - from_cell.y
	var min_axis_dist: int = min(min(left_dx, right_dx), min(top_dy, bottom_dy))
	return min_axis_dist * min_axis_dist

func _max_bucket_search_radius(origin_bucket: Vector2i) -> int:
	var max_radius: int = 0
	for raw_bucket in _buckets.keys():
		var bucket: Vector2i = raw_bucket
		max_radius = max(max_radius, max(abs(bucket.x - origin_bucket.x), abs(bucket.y - origin_bucket.y)))
	return max_radius
