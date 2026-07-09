extends Node2D
class_name BuildingConstructionOverlay

# Shows flow-blocking buildings (walls, turrets, fences) as "under construction"
# from placement until they are functional for navigation: the walkability rebuild
# finished AND every queued flow field is computed and applied. While pending, the
# building tile is redrawn at 50% opacity (over its floor tile so the ghost reads
# as translucent) with a small progress bar above it.
#
# Purely visual: the tile stays fully functional for physics/scan the whole time;
# this only communicates why agents may still walk through it for a moment.

const GHOST_ALPHA: float = 0.5
const PROGRESS_BG_COLOR: Color = Color(0.08, 0.08, 0.08, 0.85)
const PROGRESS_FILL_COLOR: Color = Color(0.35, 0.9, 0.4, 0.95)
const PROGRESS_BAR_HEIGHT: float = 2.0
const PROGRESS_BAR_WIDTH_RATIO: float = 0.8

var building_manager: BuildingManager = null

var _pending_cells: Dictionary = {}
var _flow_queue_peak: int = 0
var _progress: float = 0.0


func _ready() -> void:
	z_as_relative = false
	z_index = 300
	set_process(false)


func track_cell(cell: Vector2i) -> void:
	_pending_cells[cell] = true
	set_process(true)
	queue_redraw()


func untrack_cell(cell: Vector2i) -> void:
	if _pending_cells.erase(cell):
		queue_redraw()


func _process(_delta: float) -> void:
	if _pending_cells.is_empty() or building_manager == null:
		_pending_cells.clear()
		_flow_queue_peak = 0
		set_process(false)
		queue_redraw()
		return
	_progress = _compute_construction_progress()
	if _progress >= 1.0:
		_pending_cells.clear()
		_flow_queue_peak = 0
		set_process(false)
	queue_redraw()


# Coarse but honest progress: dirty/quiet window -> 10%, budgeted walkability
# rebuild -> 10..65%, lazy flow-field queue drain -> 65..95%, async worker still
# computing -> 95%, everything applied -> 100% (construction done).
func _compute_construction_progress() -> float:
	var invalidation: BuildingInvalidationController = building_manager.get_building_invalidation_controller()
	if invalidation.navigation_topology_dirty():
		_flow_queue_peak = 0
		return 0.1
	if invalidation.runtime_rebuild_active():
		_flow_queue_peak = 0
		return 0.1 + 0.55 * clampf(invalidation.runtime_rebuild_progress(), 0.0, 1.0)
	var route_service: SpawnerRouteService = building_manager.get_spawner_route_service()
	var queued: int = route_service.queued_flow_request_count()
	if queued > 0:
		_flow_queue_peak = maxi(_flow_queue_peak, queued)
		var drained: float = 1.0 - float(queued) / float(maxi(1, _flow_queue_peak))
		return 0.65 + 0.3 * drained
	var flow: Node = building_manager.flow
	if flow != null and flow.has_method("are_async_flows_idle") and not bool(flow.call("are_async_flows_idle")):
		return 0.95
	return 1.0


func _draw() -> void:
	if _pending_cells.is_empty() or building_manager == null:
		return
	var floorz: TileMapLayer = building_manager.floorz
	if floorz == null:
		return
	for raw_cell: Variant in _pending_cells.keys():
		var cell: Vector2i = raw_cell as Vector2i
		var cell_rect: Rect2 = _cell_local_rect(floorz, cell)
		# Repaint the floor at full opacity first so the 50% building on top of it
		# blends against the floor, not against its own fully drawn tile beneath.
		_draw_cell_tile(floorz, cell, cell_rect, 1.0)
		var building_layer: TileMapLayer = _building_layer_for_cell(cell)
		if building_layer != null:
			_draw_cell_tile(building_layer, cell, cell_rect, GHOST_ALPHA)
		_draw_progress_bar(cell_rect)


func _building_layer_for_cell(cell: Vector2i) -> TileMapLayer:
	# Player-built walls live on wallz; turrets and co on blocking_buildings; fences
	# on their own layer. Whichever holds a tile at the cell is the one to ghost.
	for layer: TileMapLayer in [building_manager.wallz, building_manager.blocking_buildings, building_manager.fences]:
		if layer != null and layer.get_cell_source_id(cell) >= 0:
			return layer
	return null


func _cell_local_rect(floorz: TileMapLayer, cell: Vector2i) -> Rect2:
	var world_center: Vector2 = floorz.to_global(floorz.map_to_local(cell))
	var local_center: Vector2 = to_local(world_center)
	var tile_size: Vector2 = Vector2(floorz.tile_set.tile_size) if floorz.tile_set else Vector2(16.0, 16.0)
	return Rect2(local_center - tile_size * 0.5, tile_size)


func _draw_cell_tile(layer: TileMapLayer, cell: Vector2i, cell_rect: Rect2, alpha: float) -> void:
	var source_id: int = layer.get_cell_source_id(cell)
	if source_id < 0 or layer.tile_set == null:
		return
	var source: TileSetAtlasSource = layer.tile_set.get_source(source_id) as TileSetAtlasSource
	if source == null or source.texture == null:
		return
	var region: Rect2i = source.get_tile_texture_region(layer.get_cell_atlas_coords(cell))
	var draw_size: Vector2 = Vector2(region.size)
	var draw_pos: Vector2 = cell_rect.position + (cell_rect.size - draw_size) * 0.5
	draw_texture_rect_region(source.texture, Rect2(draw_pos, draw_size), Rect2(region), Color(1.0, 1.0, 1.0, alpha))


func _draw_progress_bar(cell_rect: Rect2) -> void:
	var bar_width: float = cell_rect.size.x * PROGRESS_BAR_WIDTH_RATIO
	var bar_pos: Vector2 = Vector2(
		cell_rect.position.x + (cell_rect.size.x - bar_width) * 0.5,
		cell_rect.position.y - PROGRESS_BAR_HEIGHT - 2.0
	)
	draw_rect(Rect2(bar_pos, Vector2(bar_width, PROGRESS_BAR_HEIGHT)), PROGRESS_BG_COLOR)
	draw_rect(Rect2(bar_pos, Vector2(bar_width * clampf(_progress, 0.0, 1.0), PROGRESS_BAR_HEIGHT)), PROGRESS_FILL_COLOR)
