extends RefCounted
class_name WorldDepthSort

## Shared world-object depth rule. Static world visuals sort from their logical
## base position, matching agents (`z_index = int(world_y)`).

static func z_index_for_world_base(world_base_position: Vector2) -> int:
	return int(world_base_position.y)


static func apply_world_depth(node: CanvasItem, world_base_position: Vector2) -> void:
	if node == null:
		return
	node.z_as_relative = false
	node.z_index = z_index_for_world_base(world_base_position)


static func cell_center_world(layer: TileMapLayer, cell: Vector2i) -> Vector2:
	if layer == null:
		return Vector2(float(cell.x), float(cell.y))
	return layer.to_global(layer.map_to_local(cell))


static func apply_world_depth_from_cell(node: CanvasItem, layer: TileMapLayer, cell: Vector2i) -> void:
	apply_world_depth(node, cell_center_world(layer, cell))


static func configure_world_depth_tile_layer(layer: TileMapLayer) -> void:
	if layer == null:
		return
	layer.z_as_relative = false
	layer.z_index = 0
	layer.y_sort_enabled = true
