extends Node

## Owns the wet-grass patches painted by the map's irrigation centers (reservoirs and
## watermelons).
##
## Each center is an IrrigationSource: a wall-aware flood fill that grows one ring per
## `ring_interval_seconds`, and shrinks the same way when its center is removed. This
## node keeps the sources, ticks them, and paints the floor; IrrigationSource owns the
## patch geometry.

const FLOOR_TILE_CATALOG: Script = preload("res://scripts/map/floor_tile_catalog.gd")
const RESERVOIR_GROUP: StringName = &"reservoirs"
const RESERVOIR_ITEM_ID: String = "reservoir"
const PASTEQUE_ITEM_ID: String = "pasteque"
const PASTEQUE_DEFAULT_IRRIGATION_RADIUS_TILES: int = 9

@export var floorz: TileMapLayer
@export var watersources: TileMapLayer
@export var wallz: TileMapLayer
@export var building_object_manager: Node
@export var reservoir_irrigation_radius_tiles: int = 9
## Seconds a patch takes to grow (or shrink) by one tile of radius.
@export var ring_interval_seconds: float = 0.25

# Irrigation centers keyed by center cell. Sources are kept after they finish animating:
# they are the source of truth for whether a cell is still irrigated by someone else when
# a neighbouring patch shrinks.
var _sources: Dictionary = {}
var _ring_timer: float = 0.0

func _ready() -> void:
	GameState.set_reservoir_destroyed(false)
	_resolve_level_nodes()
	set_process(false)
	call_deferred("irrigate_all_reservoirs")


func any_reservoir_destroyed() -> bool:
	if GameState.is_reservoir_destroyed:
		return true
	for reservoir_node: Node in get_tree().get_nodes_in_group(RESERVOIR_GROUP):
		if reservoir_node != null and reservoir_node.has_method("is_destroyed") and bool(reservoir_node.call("is_destroyed")):
			return true
	return false

func _process(delta: float) -> void:
	var interval: float = maxf(0.01, ring_interval_seconds)
	_ring_timer += delta
	if _ring_timer < interval:
		return
	# Reset rather than subtract: after a frame hitch the animation resumes at its normal
	# pace instead of bursting through several rings to catch up.
	_ring_timer = 0.0
	_advance_sources()
	if not _has_animating_source():
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
	_register_source(center_cell, maxi(0, reservoir_irrigation_radius_tiles), _restore_floor_atlas_for(RESERVOIR_ITEM_ID))

func request_pasteque_irrigation_from_cell(center_cell: Vector2i) -> void:
	_register_source(center_cell, _pasteque_irrigation_radius_tiles(), _restore_floor_atlas_for(PASTEQUE_ITEM_ID))

func request_irrigation_from_world_position(world_position: Vector2) -> void:
	_resolve_level_nodes()
	if floorz == null:
		return
	var center_cell: Vector2i = floorz.local_to_map(floorz.to_local(world_position))
	request_reservoir_irrigation_from_cell(center_cell)

func clear_pasteque_irrigation_from_cell(center_cell: Vector2i) -> void:
	var source: IrrigationSource = _sources.get(center_cell) as IrrigationSource
	if source == null:
		return
	# -1 shrinks the patch away one ring per tick; the source is dropped once it is gone.
	source.target_radius = -1
	set_process(true)

func _register_source(center_cell: Vector2i, radius: int, restore_atlas: Vector2i) -> void:
	_resolve_level_nodes()
	if floorz == null:
		return
	# Always a fresh fill: re-placing on a cell whose patch is still shrinking must grow
	# back from the walls as they stand now, not resume a stale patch. Cells the old patch
	# already painted stay grass until some source shrinks past them.
	_sources[center_cell] = IrrigationSource.new(center_cell, radius, restore_atlas, _is_spread_blocked)
	set_process(true)

func _advance_sources() -> void:
	var painted: Array[Vector2i] = []
	var cleared: Array[Vector2i] = []
	var finished_centers: Array[Vector2i] = []
	for raw_center: Variant in _sources:
		var center_cell: Vector2i = raw_center as Vector2i
		var source: IrrigationSource = _sources[center_cell]
		if source.current_radius < source.target_radius:
			_irrigate_cells(source.grow_one_ring(), painted)
		elif source.current_radius > source.target_radius:
			_restore_cells(source, source.shrink_one_ring(), cleared)
			if source.current_radius < 0:
				finished_centers.append(center_cell)
	for center_cell: Vector2i in finished_centers:
		_sources.erase(center_cell)
	_apply_floor_changes(painted, cleared)

func _has_animating_source() -> bool:
	for raw_center: Variant in _sources:
		var source: IrrigationSource = _sources[raw_center as Vector2i]
		if source.is_animating():
			return true
	return false

func _irrigate_cells(cells: Array[Vector2i], painted: Array[Vector2i]) -> void:
	for cell: Vector2i in cells:
		if _irrigate_floor_cell(cell):
			painted.append(cell)

func _restore_cells(source: IrrigationSource, cells: Array[Vector2i], cleared: Array[Vector2i]) -> void:
	for cell: Vector2i in cells:
		if _is_covered_by_other_source(cell, source.center):
			continue
		if _restore_floor_cell(cell, source.restore_atlas):
			cleared.append(cell)

func _is_covered_by_other_source(cell: Vector2i, ignored_center_cell: Vector2i) -> bool:
	for raw_center: Variant in _sources:
		var center_cell: Vector2i = raw_center as Vector2i
		if center_cell == ignored_center_cell:
			continue
		var source: IrrigationSource = _sources[center_cell]
		if source.covers(cell):
			return true
	return false

func _apply_floor_changes(painted: Array[Vector2i], cleared: Array[Vector2i]) -> void:
	if floorz == null or (painted.is_empty() and cleared.is_empty()):
		return
	# Both added and removed cells need their neighbours re-tiled, so the patch's edges
	# and corners match the ring it just gained or lost.
	var touched: Array[Vector2i] = painted.duplicate()
	touched.append_array(cleared)
	GrassAutotile.beautify(floorz, touched)
	floorz.update_internals()
	floorz.queue_redraw()

func _resolve_level_nodes() -> void:
	if floorz == null:
		floorz = get_node_or_null("../MonTilemap/floor") as TileMapLayer
	if watersources == null:
		watersources = get_node_or_null("../MonTilemap/watersources") as TileMapLayer
	if wallz == null:
		wallz = get_node_or_null("../MonTilemap/wallz") as TileMapLayer
	if building_object_manager == null:
		building_object_manager = get_node_or_null("../BuildingObjectManager")

# Grass spreads through open ground only: missing floor (off-map), a wall tile, or a
# water tile stops the fill. That is what keeps a patch from appearing on the far side of
# a wall, detached from its center blob. Floor tiles that simply cannot be grassed (paths
# and such) do not block: the fill runs past them, they just never get painted.
func _is_spread_blocked(cell: Vector2i) -> bool:
	if floorz == null or floorz.get_cell_source_id(cell) < 0:
		return true
	if wallz != null and wallz.get_cell_tile_data(cell) != null:
		return true
	return watersources != null and watersources.get_cell_source_id(cell) >= 0

func _irrigate_floor_cell(cell: Vector2i) -> bool:
	if floorz == null:
		return false
	var source_id: int = floorz.get_cell_source_id(cell)
	if source_id < 0:
		return false
	if watersources != null and watersources.get_cell_source_id(cell) >= 0:
		return false
	if not FLOOR_TILE_CATALOG.is_dry_grass_atlas(floorz.get_cell_atlas_coords(cell)):
		return false
	var alternative_tile: int = floorz.get_cell_alternative_tile(cell)
	# Paint the interior grass tile as a placeholder; GrassAutotile.beautify() then
	# picks the correct edge/corner tile for this cell and its neighbours.
	floorz.set_cell(cell, source_id, GrassAutotile.GRASS_FULL_ATLAS, alternative_tile)
	return true

func _restore_floor_cell(cell: Vector2i, restore_atlas: Vector2i) -> bool:
	if floorz == null:
		return false
	var source_id: int = floorz.get_cell_source_id(cell)
	if source_id < 0:
		return false
	if not GrassAutotile.is_grass_atlas(floorz.get_cell_atlas_coords(cell)):
		return false
	var alternative_tile: int = floorz.get_cell_alternative_tile(cell)
	floorz.set_cell(cell, source_id, restore_atlas, alternative_tile)
	return true

func _pasteque_irrigation_radius_tiles() -> int:
	var pasteque_def: Dictionary = ItemCatalog.get_item_def(PASTEQUE_ITEM_ID)
	return maxi(0, int(pasteque_def.get("irrigation_radius_tiles", PASTEQUE_DEFAULT_IRRIGATION_RADIUS_TILES)))

func _restore_floor_atlas_for(item_id: String) -> Vector2i:
	var item_def: Dictionary = ItemCatalog.get_item_def(item_id)
	return _atlas_coords_from_variant(
		item_def.get("restore_floor_atlas", FLOOR_TILE_CATALOG.DRY_GROUND_FLOOR_ATLAS),
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
