extends Node

func _ready():
	var ff = FlowField.new()
	add_child(ff)
	ff.floor_layer = $"../MonTilemap/floor"
	ff.capture_tile_size()
	ff.build_walkable_snapshot()

	var pos = ff.cell_to_world(Vector2i(3, 4))
	print("cell(3,4) center:", pos)
