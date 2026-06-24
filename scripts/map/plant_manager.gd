extends Node
class_name PlantManager

signal plant_added(cell: Vector2i)
signal plant_removed(cell: Vector2i)
signal plant_state_changed(cell: Vector2i, atlas_coords: Vector2i)

const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)
const ROSE_DRY_ATLAS: Vector2i = Vector2i(0, 0)
const ROSE_WET_ATLAS: Vector2i = Vector2i(0, 1)

@export var plantz: TileMapLayer
@export var bucket_size: int = 16

var _plants: Dictionary = {}
var _plant_tiles: Dictionary = {}
var _buckets: Dictionary = {}
var _initialized: bool = false
var _plant_layer_flush_queued: bool = false

func _ready() -> void:
	initialize_from_layer()
	_connect_day_started()

func _connect_day_started() -> void:
	var scene: Node = get_tree().current_scene
	var progression_node: Node = scene.get_node_or_null("progression") if scene else null
	if progression_node and progression_node.has_signal("day_started"):
		var callback: Callable = Callable(self, "_on_day_started")
		if not progression_node.is_connected("day_started", callback):
			progression_node.connect("day_started", callback)

func _on_day_started(_day_number: int) -> void:
	dry_all_roses()

func initialize_from_layer() -> void:
	_plants.clear()
	_plant_tiles.clear()
	_buckets.clear()
	if not plantz:
		_initialized = true
		return
	for raw_cell in plantz.get_used_cells():
		var cell: Vector2i = raw_cell
		_capture_tile_metadata(cell)
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

func is_rose_cell(cell: Vector2i) -> bool:
	if not plantz or not _plants.has(cell):
		return false
	var atlas_coords: Vector2i = plantz.get_cell_atlas_coords(cell)
	return atlas_coords == ROSE_DRY_ATLAS or atlas_coords == ROSE_WET_ATLAS

func wet_rose(cell: Vector2i) -> bool:
	if not plantz or not _plants.has(cell):
		return false
	if plantz.get_cell_atlas_coords(cell) != ROSE_DRY_ATLAS:
		return false
	_set_rose_atlas(cell, ROSE_WET_ATLAS)
	return true

func dry_all_roses() -> int:
	if not plantz:
		return 0
	var dried_count: int = 0
	for raw_cell: Variant in _plants.keys():
		var cell: Vector2i = raw_cell as Vector2i
		if plantz.get_cell_atlas_coords(cell) != ROSE_WET_ATLAS:
			continue
		_set_rose_atlas(cell, ROSE_DRY_ATLAS, false)
		dried_count += 1
	if dried_count > 0:
		_flush_plant_layer_now()
		_queue_plant_layer_flush()
	return dried_count

func _set_rose_atlas(cell: Vector2i, atlas_coords: Vector2i, flush_visuals: bool = true) -> void:
	var source_id: int = plantz.get_cell_source_id(cell)
	if source_id < 0:
		return
	var alternative_tile: int = plantz.get_cell_alternative_tile(cell)
	plantz.set_cell(cell, source_id, atlas_coords, alternative_tile)
	_capture_tile_metadata(cell)
	if flush_visuals:
		_flush_plant_layer_now()
		_queue_plant_layer_flush()
	plant_state_changed.emit(cell, atlas_coords)

func get_plant_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for raw_cell in _plants.keys():
		var cell: Vector2i = raw_cell
		cells.append(cell)
	return cells

func add_plant(cell: Vector2i) -> void:
	if _plants.has(cell):
		return
	_capture_tile_metadata(cell)
	_index_cell(cell)
	plant_added.emit(cell)

func remove_plant(cell: Vector2i, erase_tile: bool = true) -> void:
	if not _plants.has(cell):
		return
	_unindex_cell(cell)
	if erase_tile and plantz:
		plantz.erase_cell(cell)
		_queue_plant_layer_flush()
	plant_removed.emit(cell)

func _capture_tile_metadata(cell: Vector2i) -> void:
	if not plantz:
		return
	var source_id: int = plantz.get_cell_source_id(cell)
	if source_id < 0:
		_plant_tiles.erase(cell)
		return
	_plant_tiles[cell] = {
		"source_id": source_id,
		"atlas_coords": plantz.get_cell_atlas_coords(cell),
		"alternative_tile": plantz.get_cell_alternative_tile(cell)
	}

func _rebuild_plant_layer_from_index() -> void:
	if not plantz:
		return
	plantz.clear()
	for raw_cell in _plants.keys():
		var cell: Vector2i = raw_cell
		var tile_data: Dictionary = _plant_tiles.get(cell, {}) as Dictionary
		if tile_data.is_empty():
			continue
		var source_id: int = int(tile_data.get("source_id", -1))
		var atlas_coords: Vector2i = tile_data.get("atlas_coords", Vector2i(-1, -1)) as Vector2i
		var alternative_tile: int = int(tile_data.get("alternative_tile", 0))
		if source_id >= 0:
			plantz.set_cell(cell, source_id, atlas_coords, alternative_tile)
	_flush_plant_layer_now()
	_queue_plant_layer_flush()

func _flush_plant_layer_now() -> void:
	if not plantz:
		return
	plantz.update_internals()
	plantz.queue_redraw()

func _queue_plant_layer_flush() -> void:
	if _plant_layer_flush_queued:
		return
	_plant_layer_flush_queued = true
	call_deferred("_flush_plant_layer_deferred")

func _flush_plant_layer_deferred() -> void:
	_plant_layer_flush_queued = false
	_flush_plant_layer_now()

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
	_plant_tiles.erase(cell)
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
