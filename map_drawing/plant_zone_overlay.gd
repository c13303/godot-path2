extends Node2D

# Drawn by BuildingManager when debug_show_plantzone is true.
# - zone tiles, including margin: orange 30% opacity, filled.
# - selected A* entry/exit tiles: orange 100%, filled.

var building_manager: Node

const ZONE_COLOR: Color = Color(1.0, 0.5, 0.0, 0.3)
const ROUTE_COLOR: Color = Color(1.0, 0.5, 0.0, 1.0)

func _draw() -> void:
	if not visible:
		return
	if building_manager == null:
		return
	var floorz: TileMapLayer = building_manager.call("get_floorz") if building_manager.has_method("get_floorz") else null
	if floorz == null or floorz.tile_set == null:
		return
	var tile_size: Vector2i = floorz.tile_set.get_tile_size()
	var half: Vector2 = Vector2(float(tile_size.x), float(tile_size.y)) * 0.5

	var zone_cells: Array = building_manager.call("get_plant_zone_tiles") if building_manager.has_method("get_plant_zone_tiles") else []
	if zone_cells.is_empty():
		return

	for raw_cell in zone_cells:
		var c: Vector2i = raw_cell
		var center_local: Vector2 = _cell_center_local(floorz, c)
		draw_rect(Rect2(center_local - half, half * 2.0), ZONE_COLOR, true)

	var route_cells: Array = building_manager.call("get_plant_zone_route_tiles") if building_manager.has_method("get_plant_zone_route_tiles") else []
	for raw_cell in route_cells:
		var c: Vector2i = raw_cell
		var center_local: Vector2 = _cell_center_local(floorz, c)
		draw_rect(Rect2(center_local - half, half * 2.0), ROUTE_COLOR, true)

func _cell_center_local(floorz: TileMapLayer, cell: Vector2i) -> Vector2:
	if get_parent() == floorz:
		return floorz.map_to_local(cell)
	var center_world: Vector2 = floorz.to_global(floorz.map_to_local(cell))
	return to_local(center_world)
