extends RefCounted
class_name NavigationGridUploadService

## Converts this project's TileMap interpretation into CPathLib's explicit grid.
## TileMap references and coverage policy deliberately stay outside the extension.

const DYNAMIC_BLOCKER_CHANNEL: int = 1
const FENCE_BLOCKER_CHANNEL: int = 2


func configure_world(
	navigation_world: Node,
	floor_layer: TileMapLayer,
	physical_wall_layer: TileMapLayer,
	navigation_blocking_layer: TileMapLayer,
	bounds: Rect2i,
	agent_radius: float,
	navigation_coverage_threshold: float,
	wall_clearance_weight: float,
	bottleneck_zone_radius: int
) -> bool:
	if navigation_world == null or floor_layer == null or physical_wall_layer == null:
		return false
	if bounds.size.x <= 0 or bounds.size.y <= 0:
		bounds = floor_layer.get_used_rect()
	if bounds.size.x <= 0 or bounds.size.y <= 0:
		return false
	var wall_cells: Dictionary = _cell_set(physical_wall_layer.get_used_cells())
	var navigation_blockers: Dictionary = wall_cells.duplicate()
	_add_navigation_coverage_blockers(
		floor_layer, navigation_blocking_layer, agent_radius,
		navigation_coverage_threshold, navigation_blockers
	)
	var walkable: PackedVector2Array = PackedVector2Array()
	for raw_cell: Variant in floor_layer.get_used_cells():
		var cell: Vector2i = raw_cell as Vector2i
		if not navigation_blockers.has(cell):
			walkable.append(Vector2(cell.x, cell.y))
	var physical_walls: PackedVector2Array = _packed_cells(wall_cells)
	var tile_size: Vector2i = floor_layer.tile_set.tile_size
	var cell_size: float = maxf(float(tile_size.x), 1.0)
	var zero_center: Vector2 = floor_layer.to_global(floor_layer.map_to_local(Vector2i.ZERO))
	var world_origin: Vector2 = zero_center - Vector2.ONE * cell_size * 0.5
	var configured: bool = bool(navigation_world.call(
		&"configure_grid", bounds, cell_size, world_origin, walkable, physical_walls
	))
	if configured:
		navigation_world.call(
			&"configure_flow", wall_clearance_weight, true, bottleneck_zone_radius
		)
	return configured


func replace_dynamic_blockers(navigation_world: Node, cells: PackedVector2Array) -> bool:
	return navigation_world != null and bool(navigation_world.call(
		&"replace_blocker_channel", DYNAMIC_BLOCKER_CHANNEL, cells, true, true
	))


func set_dynamic_blocker(navigation_world: Node, cell: Vector2i, blocked: bool) -> bool:
	return navigation_world != null and bool(navigation_world.call(
		&"set_blocker_channel_cell", DYNAMIC_BLOCKER_CHANNEL,
		cell, blocked, true, true
	))


func replace_fence_blockers(navigation_world: Node, cells: PackedVector2Array) -> bool:
	return navigation_world != null and bool(navigation_world.call(
		&"replace_blocker_channel", FENCE_BLOCKER_CHANNEL, cells, true, false
	))


func _add_navigation_coverage_blockers(
	floor_layer: TileMapLayer,
	blocking_layer: TileMapLayer,
	agent_radius: float,
	coverage_threshold: float,
	result: Dictionary
) -> void:
	if blocking_layer == null:
		return
	var threshold: float = clampf(coverage_threshold, 0.0, 1.0)
	if threshold <= 0.0:
		for raw_cell: Variant in blocking_layer.get_used_cells():
			result[raw_cell as Vector2i] = true
		return
	var radius: float = maxf(agent_radius, 1.0)
	for raw_cell: Variant in floor_layer.get_used_cells():
		var cell: Vector2i = raw_cell as Vector2i
		var center: Vector2 = floor_layer.to_global(floor_layer.map_to_local(cell))
		var footprint: Rect2 = Rect2(
			center - Vector2.ONE * radius, Vector2.ONE * radius * 2.0
		)
		if _coverage(blocking_layer, footprint) >= threshold:
			result[cell] = true


func _coverage(layer: TileMapLayer, world_rect: Rect2) -> float:
	if layer.has_method(&"water_coverage_of_world_rect"):
		return float(layer.call(&"water_coverage_of_world_rect", world_rect))
	var local_start: Vector2 = layer.to_local(world_rect.position)
	var local_end: Vector2 = layer.to_local(world_rect.end)
	var local_rect: Rect2 = Rect2(local_start, local_end - local_start).abs()
	var total_area: float = local_rect.get_area()
	if total_area <= 0.0:
		return 0.0
	var tile_size_i: Vector2i = layer.tile_set.tile_size
	var tile_size: Vector2 = Vector2(tile_size_i)
	var first: Vector2i = layer.local_to_map(local_rect.position) - Vector2i.ONE
	var last: Vector2i = layer.local_to_map(local_rect.end) + Vector2i.ONE
	var covered: float = 0.0
	for y: int in range(first.y, last.y + 1):
		for x: int in range(first.x, last.x + 1):
			var cell: Vector2i = Vector2i(x, y)
			if layer.get_cell_source_id(cell) == -1:
				continue
			var center: Vector2 = layer.map_to_local(cell)
			var cell_rect: Rect2 = Rect2(center - tile_size * 0.5, tile_size)
			covered += local_rect.intersection(cell_rect).get_area()
	return clampf(covered / total_area, 0.0, 1.0)


func _cell_set(cells: Array[Vector2i]) -> Dictionary:
	var result: Dictionary = {}
	for cell: Vector2i in cells:
		result[cell] = true
	return result


func _packed_cells(cells: Dictionary) -> PackedVector2Array:
	var result: PackedVector2Array = PackedVector2Array()
	for raw_cell: Variant in cells:
		var cell: Vector2i = raw_cell as Vector2i
		result.append(Vector2(cell.x, cell.y))
	return result
