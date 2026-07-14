extends Node2D

# Drawn by BuildingManager when debug_show_plantzone is true.
# - zone tiles, including margin: orange 30% opacity, filled.
# - selected A* entry/exit tiles: orange 100%, filled.

var building_manager: Node

const ZONE_COLOR: Color = Color(1.0, 0.5, 0.0, 0.3)
const ROUTE_COLOR: Color = Color(1.0, 0.5, 0.0, 1.0)
const UNREACHABLE_COLOR: Color = Color(0.9, 0.1, 0.1, 0.55)
const DIRTY_COLOR: Color = Color(0.95, 0.85, 0.15, 0.65)
const ENTER_COLOR: Color = Color(1.0, 0.9, 0.1, 0.9)

func _draw() -> void:
	if not visible:
		return
	if building_manager == null:
		return
	var floorz: TileMapLayer = null
	if building_manager.has_method("get_floorz"):
		floorz = building_manager.call("get_floorz") as TileMapLayer
	if floorz == null or floorz.tile_set == null:
		return
	var tile_size: Vector2i = floorz.tile_set.get_tile_size()
	var half: Vector2 = Vector2(float(tile_size.x), float(tile_size.y)) * 0.5

	var zone_cells: Array = []
	if building_manager.has_method("get_plant_zone_tiles"):
		zone_cells = building_manager.call("get_plant_zone_tiles") as Array
	if zone_cells.is_empty():
		return

	for raw_cell in zone_cells:
		var c: Vector2i = raw_cell
		var center_local: Vector2 = _cell_center_local(floorz, c)
		draw_rect(Rect2(center_local - half, half * 2.0), ZONE_COLOR, true)

	var route_cells: Array = []
	if building_manager.has_method("get_plant_zone_route_tiles"):
		route_cells = building_manager.call("get_plant_zone_route_tiles") as Array
	for raw_cell in route_cells:
		var c: Vector2i = raw_cell
		var center_local: Vector2 = _cell_center_local(floorz, c)
		draw_rect(Rect2(center_local - half, half * 2.0), ROUTE_COLOR, true)

	var unreachable_cells: Array = []
	if building_manager.has_method("get_unreachable_garden_cells"):
		unreachable_cells = building_manager.call("get_unreachable_garden_cells") as Array
	for raw_cell in unreachable_cells:
		var c: Vector2i = raw_cell
		var center_local: Vector2 = _cell_center_local(floorz, c)
		draw_rect(Rect2(center_local - half, half * 2.0), UNREACHABLE_COLOR, true)

	var dirty_cells: Array = []
	if building_manager.has_method("get_dirty_garden_cells"):
		dirty_cells = building_manager.call("get_dirty_garden_cells") as Array
	for raw_cell in dirty_cells:
		var c: Vector2i = raw_cell
		var center_local: Vector2 = _cell_center_local(floorz, c)
		draw_rect(Rect2(center_local - half, half * 2.0), DIRTY_COLOR, true)

	# Selected inbound garden-entry tiles (yellow), one per relevant spawner/garden
	# pair. Runtime monsters do not navigate to a selected garden exit after eating
	# (they use the global escape flow field), so no exit tile is drawn.
	var show_enters_exits: bool = false
	if building_manager.has_method("get_show_enters_exits"):
		show_enters_exits = bool(building_manager.call("get_show_enters_exits"))
	if show_enters_exits:
		var enter_cells: Array = []
		if building_manager.has_method("get_garden_enter_tiles"):
			enter_cells = building_manager.call("get_garden_enter_tiles") as Array
		for raw_cell in enter_cells:
			var c: Vector2i = raw_cell
			var center_local: Vector2 = _cell_center_local(floorz, c)
			draw_rect(Rect2(center_local - half, half * 2.0), ENTER_COLOR, true)

func _cell_center_local(floorz: TileMapLayer, cell: Vector2i) -> Vector2:
	if get_parent() == floorz:
		return floorz.map_to_local(cell)
	var center_world: Vector2 = floorz.to_global(floorz.map_to_local(cell))
	return to_local(center_world)
