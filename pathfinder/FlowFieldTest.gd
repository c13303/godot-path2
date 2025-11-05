extends Node

@onready var ff: FlowField = $"../FlowField"
@onready var floor: TileMapLayer = $"../MonTilemap/floor"
@onready var walls: TileMapLayer = $"../MonTilemap/wallz"

func _ready():
	ff.set_floor_layer(floor)
	ff.set_wall_layer(walls)

	ff.capture_tile_size()
	ff.build_walkable_snapshot()

	var used := floor.get_used_rect()
	var center_cell := used.position + used.size / 2
	var goal_world := floor.get_global_position() + Vector2(
		center_cell.x * ff.get_tile_size().x + ff.get_tile_size().x * 0.5,
		center_cell.y * ff.get_tile_size().y + ff.get_tile_size().y * 0.5
	)

	ff.debug_draw = false
	ff.rebuild_async(goal_world)
	print("FlowField: rebuild_async lancé")

	await get_tree().create_timer(1.0).timeout
	print("is_ready:", ff.is_ready())
	print("flow_version:", ff.flow_version()) 

	await get_tree().create_timer(2.0).timeout
	get_tree().quit()
