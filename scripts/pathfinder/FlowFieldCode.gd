extends Node2D

signal flow_field_ready
signal loading_progress(progress: float, label: String)

@onready var ff: FlowFieldNative = get_parent()
@onready var floor_layer: TileMapLayer = $"../../../Map/MonTilemap/floor"
@onready var wall_layer: TileMapLayer = $"../../../Map/MonTilemap/wallz"
@onready var blocking_layer: TileMapLayer = $"../../../Map/MonTilemap/blocking_buildings"

var is_ready: bool = false

func _ready() -> void:
	
	
	print(">>> FlowFieldCode.gd _ready() triggered <<<")
	loading_progress.emit(0.05, "Preparing navigation")

	await get_tree().process_frame

	print("FlowFieldCode: _ready() called")

	if ff == null:
		print("FlowFieldCode: FlowFieldNative node not found.")
		return

	#print("FlowFieldCode: assigning layers...")
	ff.set_floor_layer(floor_layer)
	ff.set_wall_layer(wall_layer)
	ff.set_blocking_layer(blocking_layer)
	loading_progress.emit(0.15, "Reading map layers")

	#print("floor_layer:", floor_layer)
	#print("wall_layer:", wall_layer)



	await get_tree().process_frame

	# The default field is required immediately by manual player steering for hard
	# wall collision and wall correction. Monster group flow fields remain lazy and
	# are prepared separately by BuildingManager when night starts.
	loading_progress.emit(0.25, "Computing wall collisions")
	await get_tree().process_frame
	ff.compute_distance_field_global()
	is_ready = true
	loading_progress.emit(0.45, "Flow field ready")
	flow_field_ready.emit()
	print("FlowFieldCode: initialization complete--------------------------------")


func _on_mouse_goal(world_pos: Vector2) -> void:
	if ff == null:
		push_warning("FlowFieldCode: FlowFieldNative not ready.")
		return
	ff.rebuild_async(world_pos)
