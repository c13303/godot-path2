extends Node

@onready var ff: FlowField = $"../FlowField"
@onready var floor_layer: TileMapLayer = $"../MonTilemap/floor"
@onready var wall_layer: TileMapLayer = $"../MonTilemap/wallz"
@onready var controls_node: Node2D = $"../Controls"

func _ready():
	if ff == null:
		push_warning("FlowField_tester: FlowField node not found.")
		return

	ff.set_floor_layer(floor_layer)
	ff.set_wall_layer(wall_layer)
	ff.capture_tile_size()
	ff.allow_diagonals = true

	if controls_node:
		controls_node.connect("mouse_goal_set", Callable(self, "_on_mouse_goal"))
	else:
		push_warning("FlowField_tester: controls node not found.")

func _on_mouse_goal(world_pos: Vector2):
	if ff == null:
		return

	ff.build_walkable_snapshot()

	var offset = Vector2(-ff.get_tile_size().x * 0.5, -ff.get_tile_size().y * 0.5)
	var adjusted_goal = world_pos + offset
	print("Rebuild FlowField at:", adjusted_goal)
	ff.rebuild_async(adjusted_goal)
