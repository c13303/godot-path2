#flowFieldCode.gd
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

	# chargement initial
	ff.store_floor_native()
	ff.store_wall_native()
	ff.build_walkable_snapshot()

func _on_mouse_goal(world_pos: Vector2) -> void:
	if ff == null:
		return

	var test_cell: Vector2i = ff.world_to_cell(world_pos)
	var cell_world_center: Vector2 = ff.cell_to_world(test_cell)


	ff.rebuild_async(world_pos)
