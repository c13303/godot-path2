extends Node2D

@onready var ff: FlowFieldNative = get_parent()
@onready var floor_layer: TileMapLayer = $"../../../Map/MonTilemap/floor"
@onready var wall_layer: TileMapLayer = $"../../../Map/MonTilemap/wallz"

func _ready() -> void:
	
	
	print(">>> FlowFieldCode.gd _ready() triggered <<<")

	await get_tree().process_frame

	print("FlowFieldCode: _ready() called")

	if ff == null:
		print("FlowFieldCode: FlowFieldNative node not found.")
		return

	#print("FlowFieldCode: assigning layers...")
	ff.set_floor_layer(floor_layer)
	ff.set_wall_layer(wall_layer)

	#print("floor_layer:", floor_layer)
	#print("wall_layer:", wall_layer)



	await get_tree().process_frame

	ff.compute_distance_field_global()
	var _d = ff.compute_flow_dir(global_position)
	#print("Direction lue après rebuild:", _d)


	print("FlowFieldCode: initialization complete--------------------------------")


func _on_mouse_goal(world_pos: Vector2) -> void:
	if ff == null:
		push_warning("FlowFieldCode: FlowFieldNative not ready.")
		return
	ff.rebuild_async(world_pos)
