extends Node
class_name SpawnController

const AGENT_SCENE := preload("res://sprites/character/character.tscn")

var floorz: TileMapLayer
var wallz: TileMapLayer
var agent_manager: Node
var parent_for_agents: Node

func setup(floor_layer: TileMapLayer, wall_layer: TileMapLayer, agent_mgr: Node, parent_node: Node) -> void:
	floorz = floor_layer
	wallz = wall_layer
	agent_manager = agent_mgr
	parent_for_agents = parent_node

func spawn_mainchar(pos: Vector2, current_group: int) -> int:
	var group_id: int = current_group
	if group_id < 1:
		if agent_manager and agent_manager.has_method("create_group"):
			group_id = int(agent_manager.call("create_group"))

	var target_cell: Vector2i = floorz.local_to_map(floorz.to_local(pos))
	var occupied: Array[Vector2i] = []
	for node in get_tree().get_nodes_in_group("main_chars"):
		if node is Node2D:
			var unit: Node2D = node
			occupied.append(floorz.local_to_map(floorz.to_local(unit.global_position)))
	var free_cell: Vector2i = _find_free_cell_near(target_cell, occupied)
	var free_pos: Vector2 = floorz.to_global(floorz.map_to_local(free_cell))

	var agent: Node2D = AGENT_SCENE.instantiate()
	parent_for_agents.add_child(agent)
	agent.global_position = free_pos
	agent.z_index = int(free_pos.y)
	agent.add_to_group("main_chars")

	if agent_manager and agent_manager.has_method("spawn_agent"):
		var nav_id: int = int(agent_manager.call("spawn_agent", agent, 0))
		agent.set("nav_id", nav_id)

	return group_id

func _find_free_cell_near(start_cell: Vector2i, occupied: Array[Vector2i], max_radius: int = 6) -> Vector2i:
	if start_cell not in occupied and _is_walkable(start_cell):
		return start_cell
	for r in range(1, max_radius + 1):
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				var c: Vector2i = start_cell + Vector2i(dx, dy)
				if c not in occupied and _is_walkable(c):
					return c
	return start_cell

func _is_walkable(cell: Vector2i) -> bool:
	var has_floor: bool = floorz.get_cell_tile_data(cell) != null
	var has_wall: bool = wallz and wallz.get_cell_tile_data(cell) != null
	return has_floor and not has_wall

