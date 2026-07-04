extends Node

const GRASS_GREEN_FLOOR_ATLAS: Vector2i = Vector2i(11, 6)
const RESERVOIR_GROUP: StringName = &"reservoirs"
const RESERVOIR_ITEM_ID: String = "reservoir"

@export var floorz: TileMapLayer
@export var watersources: TileMapLayer
@export var building_object_manager: Node
@export var irrigation_radius_tiles: int = 8
@export var max_cells_per_frame: int = 24

var _irrigation_queue: Array[Vector2i] = []
var _queued_cells: Dictionary = {}

func _ready() -> void:
	_resolve_level_nodes()
	set_process(false)
	call_deferred("irrigate_all_reservoirs")

func _process(_delta: float) -> void:
	if _irrigation_queue.is_empty():
		set_process(false)
		return
	var processed: int = 0
	var changed: bool = false
	var budget: int = maxi(1, max_cells_per_frame)
	while processed < budget and not _irrigation_queue.is_empty():
		var cell: Vector2i = _irrigation_queue.pop_front()
		_queued_cells.erase(cell)
		if _irrigate_floor_cell(cell):
			changed = true
		processed += 1
	if changed and floorz != null:
		floorz.update_internals()
		floorz.queue_redraw()
	if _irrigation_queue.is_empty():
		set_process(false)

func irrigate_all_reservoirs() -> void:
	_resolve_level_nodes()
	var center_cells: Dictionary = {}
	if building_object_manager != null and building_object_manager.has_method("get_building_cells_by_item_id"):
		var raw_cells: Array = building_object_manager.call("get_building_cells_by_item_id", RESERVOIR_ITEM_ID) as Array
		for raw_cell: Variant in raw_cells:
			var cell: Vector2i = raw_cell as Vector2i
			center_cells[cell] = true
	for reservoir_node: Node in get_tree().get_nodes_in_group(RESERVOIR_GROUP):
		var reservoir_2d: Node2D = reservoir_node as Node2D
		if reservoir_2d == null or floorz == null:
			continue
		var cell: Vector2i = floorz.local_to_map(floorz.to_local(reservoir_2d.global_position))
		center_cells[cell] = true
	for raw_cell: Variant in center_cells.keys():
		request_irrigation_from_cell(raw_cell as Vector2i)

func request_irrigation_from_cell(center_cell: Vector2i) -> void:
	_queue_radius(center_cell, maxi(0, irrigation_radius_tiles))
	if not _irrigation_queue.is_empty():
		set_process(true)

func request_irrigation_from_world_position(world_position: Vector2) -> void:
	_resolve_level_nodes()
	if floorz == null:
		return
	var center_cell: Vector2i = floorz.local_to_map(floorz.to_local(world_position))
	request_irrigation_from_cell(center_cell)

func _resolve_level_nodes() -> void:
	if floorz == null:
		floorz = get_node_or_null("../MonTilemap/floor") as TileMapLayer
	if watersources == null:
		watersources = get_node_or_null("../MonTilemap/watersources") as TileMapLayer
	if building_object_manager == null:
		building_object_manager = get_node_or_null("../BuildingObjectManager")

func _queue_radius(center_cell: Vector2i, radius: int) -> void:
	var radius_squared: int = radius * radius
	for y_offset: int in range(-radius, radius + 1):
		for x_offset: int in range(-radius, radius + 1):
			var distance_squared: int = x_offset * x_offset + y_offset * y_offset
			if distance_squared > radius_squared:
				continue
			var cell: Vector2i = center_cell + Vector2i(x_offset, y_offset)
			if _queued_cells.has(cell):
				continue
			_queued_cells[cell] = true
			_irrigation_queue.append(cell)

func _irrigate_floor_cell(cell: Vector2i) -> bool:
	if floorz == null:
		return false
	var source_id: int = floorz.get_cell_source_id(cell)
	if source_id < 0:
		return false
	if watersources != null and watersources.get_cell_source_id(cell) >= 0:
		return false
	if floorz.get_cell_atlas_coords(cell) == GRASS_GREEN_FLOOR_ATLAS:
		return false
	var alternative_tile: int = floorz.get_cell_alternative_tile(cell)
	floorz.set_cell(cell, source_id, GRASS_GREEN_FLOOR_ATLAS, alternative_tile)
	return true
