extends Node

const FLOOR_TILE_CATALOG: Script = preload("res://scripts/map/floor_tile_catalog.gd")
const RESERVOIR_GROUP: StringName = &"reservoirs"
const RESERVOIR_ITEM_ID: String = "reservoir"
const PASTEQUE_ITEM_ID: String = "pasteque"
const PASTEQUE_DEFAULT_IRRIGATION_RADIUS_TILES: int = 6

@export var floorz: TileMapLayer
@export var watersources: TileMapLayer
@export var building_object_manager: Node
@export var reservoir_irrigation_radius_tiles: int = 8
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
	var budget: int = maxi(1, max_cells_per_frame)
	var newly_grassed: Array[Vector2i] = []
	while processed < budget and not _irrigation_queue.is_empty():
		var cell: Vector2i = _irrigation_queue.pop_front()
		_queued_cells.erase(cell)
		if _irrigate_floor_cell(cell):
			newly_grassed.append(cell)
		processed += 1
	# Beautify this batch (plus their neighbours). Cells whose neighbours only get
	# grassed on a later frame are re-tiled then, via that frame's neighbour expansion.
	if not newly_grassed.is_empty() and floorz != null:
		GrassAutotile.beautify(floorz, newly_grassed)
		floorz.update_internals()
		floorz.queue_redraw()
	if _irrigation_queue.is_empty():
		set_process(false)

func irrigate_all_reservoirs() -> void:
	_resolve_level_nodes()
	var center_cells: Dictionary = {}
	if building_object_manager != null and building_object_manager.has_method("get_building_cells_by_item_id"):
		var pasteque_cells: Array = building_object_manager.call("get_building_cells_by_item_id", PASTEQUE_ITEM_ID) as Array
		for raw_pasteque_cell: Variant in pasteque_cells:
			var pasteque_cell: Vector2i = raw_pasteque_cell as Vector2i
			request_pasteque_irrigation_from_cell(pasteque_cell)
		var reservoir_cells: Array = building_object_manager.call("get_building_cells_by_item_id", RESERVOIR_ITEM_ID) as Array
		for raw_reservoir_cell: Variant in reservoir_cells:
			var reservoir_cell: Vector2i = raw_reservoir_cell as Vector2i
			center_cells[reservoir_cell] = true
	for reservoir_node: Node in get_tree().get_nodes_in_group(RESERVOIR_GROUP):
		var reservoir_2d: Node2D = reservoir_node as Node2D
		if reservoir_2d == null or floorz == null:
			continue
		var cell: Vector2i = floorz.local_to_map(floorz.to_local(reservoir_2d.global_position))
		center_cells[cell] = true
	for raw_cell: Variant in center_cells.keys():
		request_reservoir_irrigation_from_cell(raw_cell as Vector2i)

func request_irrigation_from_cell(center_cell: Vector2i) -> void:
	request_reservoir_irrigation_from_cell(center_cell)

func request_reservoir_irrigation_from_cell(center_cell: Vector2i) -> void:
	_queue_radius(center_cell, maxi(0, reservoir_irrigation_radius_tiles))
	if not _irrigation_queue.is_empty():
		set_process(true)

func request_pasteque_irrigation_from_cell(center_cell: Vector2i) -> void:
	_queue_radius(center_cell, _pasteque_irrigation_radius_tiles())
	if not _irrigation_queue.is_empty():
		set_process(true)

func request_irrigation_from_world_position(world_position: Vector2) -> void:
	_resolve_level_nodes()
	if floorz == null:
		return
	var center_cell: Vector2i = floorz.local_to_map(floorz.to_local(world_position))
	request_reservoir_irrigation_from_cell(center_cell)

func clear_pasteque_irrigation_from_cell(center_cell: Vector2i) -> void:
	_resolve_level_nodes()
	if floorz == null:
		return
	var radius: int = _pasteque_irrigation_radius_tiles()
	var radius_squared: int = radius * radius
	var restore_atlas: Vector2i = _pasteque_restore_floor_atlas()
	var removed_cells: Array[Vector2i] = []
	for y_offset: int in range(-radius, radius + 1):
		for x_offset: int in range(-radius, radius + 1):
			var distance_squared: int = x_offset * x_offset + y_offset * y_offset
			if distance_squared > radius_squared:
				continue
			var cell: Vector2i = center_cell + Vector2i(x_offset, y_offset)
			if _cell_has_other_irrigation_source(cell, center_cell):
				continue
			if _restore_floor_cell(cell, restore_atlas):
				removed_cells.append(cell)
	if not removed_cells.is_empty():
		# Grass that remains around the removed patch needs its edges re-tiled.
		GrassAutotile.beautify(floorz, removed_cells)
		floorz.update_internals()
		floorz.queue_redraw()

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
	if GrassAutotile.is_grass_atlas(floorz.get_cell_atlas_coords(cell)):
		return false
	var alternative_tile: int = floorz.get_cell_alternative_tile(cell)
	# Paint the interior grass tile as a placeholder; GrassAutotile.beautify() then
	# picks the correct edge/corner tile for this cell and its neighbours.
	floorz.set_cell(cell, source_id, GrassAutotile.GRASS_FULL_ATLAS, alternative_tile)
	return true

func _restore_floor_cell(cell: Vector2i, restore_atlas: Vector2i) -> bool:
	var source_id: int = floorz.get_cell_source_id(cell)
	if source_id < 0:
		return false
	if not GrassAutotile.is_grass_atlas(floorz.get_cell_atlas_coords(cell)):
		return false
	var alternative_tile: int = floorz.get_cell_alternative_tile(cell)
	floorz.set_cell(cell, source_id, restore_atlas, alternative_tile)
	return true

func _cell_has_other_irrigation_source(cell: Vector2i, ignored_center_cell: Vector2i) -> bool:
	var reservoir_radius: int = maxi(0, reservoir_irrigation_radius_tiles)
	var reservoir_radius_squared: int = reservoir_radius * reservoir_radius
	for reservoir_node: Node in get_tree().get_nodes_in_group(RESERVOIR_GROUP):
		var reservoir_2d: Node2D = reservoir_node as Node2D
		if reservoir_2d == null or floorz == null:
			continue
		var reservoir_cell: Vector2i = floorz.local_to_map(floorz.to_local(reservoir_2d.global_position))
		if reservoir_cell == ignored_center_cell:
			continue
		var reservoir_delta: Vector2i = cell - reservoir_cell
		if reservoir_delta.x * reservoir_delta.x + reservoir_delta.y * reservoir_delta.y <= reservoir_radius_squared:
			return true
	if building_object_manager == null or not building_object_manager.has_method("get_building_cells_by_item_id"):
		return false
	var building_reservoir_cells: Array = building_object_manager.call("get_building_cells_by_item_id", RESERVOIR_ITEM_ID) as Array
	for raw_building_reservoir_cell: Variant in building_reservoir_cells:
		var building_reservoir_cell: Vector2i = raw_building_reservoir_cell as Vector2i
		if building_reservoir_cell == ignored_center_cell:
			continue
		var building_reservoir_delta: Vector2i = cell - building_reservoir_cell
		if building_reservoir_delta.x * building_reservoir_delta.x + building_reservoir_delta.y * building_reservoir_delta.y <= reservoir_radius_squared:
			return true
	var pasteque_radius: int = _pasteque_irrigation_radius_tiles()
	var pasteque_radius_squared: int = pasteque_radius * pasteque_radius
	var pasteque_cells: Array = building_object_manager.call("get_building_cells_by_item_id", PASTEQUE_ITEM_ID) as Array
	for raw_pasteque_cell: Variant in pasteque_cells:
		var pasteque_cell: Vector2i = raw_pasteque_cell as Vector2i
		if pasteque_cell == ignored_center_cell:
			continue
		var pasteque_delta: Vector2i = cell - pasteque_cell
		if pasteque_delta.x * pasteque_delta.x + pasteque_delta.y * pasteque_delta.y <= pasteque_radius_squared:
			return true
	return false

func _pasteque_irrigation_radius_tiles() -> int:
	var pasteque_def: Dictionary = ItemCatalog.get_item_def(PASTEQUE_ITEM_ID)
	return maxi(0, int(pasteque_def.get("irrigation_radius_tiles", PASTEQUE_DEFAULT_IRRIGATION_RADIUS_TILES)))

func _pasteque_restore_floor_atlas() -> Vector2i:
	var pasteque_def: Dictionary = ItemCatalog.get_item_def(PASTEQUE_ITEM_ID)
	return _atlas_coords_from_variant(
		pasteque_def.get("restore_floor_atlas", FLOOR_TILE_CATALOG.DRY_GROUND_FLOOR_ATLAS),
		FLOOR_TILE_CATALOG.DRY_GROUND_FLOOR_ATLAS
	)

func _atlas_coords_from_variant(raw_atlas: Variant, fallback: Vector2i) -> Vector2i:
	if raw_atlas is Vector2i:
		return raw_atlas as Vector2i
	if raw_atlas is Vector2:
		var vector_atlas: Vector2 = raw_atlas as Vector2
		return Vector2i(int(vector_atlas.x), int(vector_atlas.y))
	if raw_atlas is Array:
		var atlas_array: Array = raw_atlas as Array
		if atlas_array.size() >= 2:
			return Vector2i(int(atlas_array[0]), int(atlas_array[1]))
	return fallback
