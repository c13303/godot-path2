extends Node2D

@onready var floorz: TileMapLayer = $"../MonTilemap/floor"
@onready var path_manager: Node = $"../PathfindingManager"
@onready var marker: Node2D = preload("res://elements/green_circle.tscn").instantiate()
var MainCharScene: PackedScene = preload("res://personnage/main_char.tscn")

var destinations: Array[Vector2] = []


func _ready() -> void:
	add_child(marker)
	marker.visible = false
	marker.z_index = 1

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var cell_center: Vector2 = Utils.get_tile_pos_from_mouse(floorz)
		marker.global_position = cell_center
		marker.visible = true		
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_A:
		var cell_center: Vector2 = Utils.get_tile_pos_from_mouse(floorz)
		spawn_mainchar(cell_center)

func spawn_mainchar(pos: Vector2) -> void:
	var pathfinder: Pathfinding = path_manager.get("pathfinder")
	var floor := pathfinder.floor_layer

	var occupied_cells: Array[Vector2i] = []
	for node in get_tree().get_nodes_in_group("main_chars"):
		var cell: Vector2i = floor.local_to_map(floor.to_local(node.global_position))
		occupied_cells.append(cell)

	var origin_cell: Vector2i = floor.local_to_map(floor.to_local(pos))
	var free_cell: Vector2i = pathfinder.find_free_spawn_cell(origin_cell, occupied_cells)
	var free_pos: Vector2 = floor.map_to_local(free_cell)

	var c: Node2D = MainCharScene.instantiate()
	get_parent().add_child(c)
	c.global_position = free_pos
	c.set("path_manager", path_manager)
	c.add_to_group("main_chars")

	var total: int = get_tree().get_nodes_in_group("main_chars").size()
	print("Personnages actifs :", total)
