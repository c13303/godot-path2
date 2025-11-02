extends Node

func get_tile_pos_from_mouse(layer: TileMapLayer):
	var mouse_pos = layer.get_local_mouse_position()
	var tile_coords = layer.local_to_map(mouse_pos)
	var cell_center = layer.map_to_local(tile_coords) - layer.tile_set.tile_size / 2.0
	return layer.to_global(cell_center)

func get_tile_pos_from_cell(layer: TileMapLayer, cell: Vector2i):
	var cell_center = layer.map_to_local(cell)
	return layer.to_global(cell_center)
