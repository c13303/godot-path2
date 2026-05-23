extends Node
class_name SpawnController

const AGENT_SCENE := preload("res://sprites/character/character.tscn")
const PLAYER_SCENE := preload("res://sprites/player/player.tscn")
const CONTROL_MODE_MANUAL: int = 1

var floorz: TileMapLayer
var wallz: TileMapLayer
var agent_manager: Node
var steering: Node
var parent_for_agents: Node

func setup(floor_layer: TileMapLayer, wall_layer: TileMapLayer, agent_mgr: Node, parent_node: Node, steering_node: Node = null) -> void:
	floorz = floor_layer
	wallz = wall_layer
	agent_manager = agent_mgr
	steering = steering_node
	parent_for_agents = parent_node

func spawn_mainchar(pos: Vector2, current_group: int) -> int:
	var group_id: int = current_group
	if group_id < 1:
		if agent_manager and agent_manager.has_method("create_group"):
			group_id = int(agent_manager.call("create_group"))

	var target_cell: Vector2i = floorz.local_to_map(floorz.to_local(pos))
	var occupied: Array[Vector2i] = _occupied_cells()
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

func spawn_player(pos: Vector2) -> int:
	var target_cell: Vector2i = floorz.local_to_map(floorz.to_local(pos))
	var occupied: Array[Vector2i] = _occupied_cells()
	var free_cell: Vector2i = _find_free_cell_near(target_cell, occupied)
	var free_pos: Vector2 = floorz.to_global(floorz.map_to_local(free_cell))
	print("[PlayerControl] spawn target_cell=", target_cell, " free_cell=", free_cell, " free_pos=", free_pos, " walkable=", _is_walkable(free_cell))

	var player: Node2D = PLAYER_SCENE.instantiate()
	parent_for_agents.add_child(player)
	player.global_position = free_pos
	player.z_index = int(free_pos.y)
	player.add_to_group("player")

	if agent_manager and agent_manager.has_method("spawn_agent"):
		var nav_id: int = int(agent_manager.call("spawn_agent", player, 0))
		player.set("nav_id", nav_id)
		if steering and steering.has_method("set_agent_control_mode"):
			steering.call("set_agent_control_mode", nav_id, CONTROL_MODE_MANUAL)
		return nav_id

	return -1

func _occupied_cells() -> Array[Vector2i]:
	var occupied: Array[Vector2i] = []
	for group_name in ["main_chars", "player"]:
		for node in get_tree().get_nodes_in_group(group_name):
			if node is Node2D:
				var unit: Node2D = node
				occupied.append(floorz.local_to_map(floorz.to_local(unit.global_position)))
	return occupied

func _find_free_cell_near(start_cell: Vector2i, occupied: Array[Vector2i], max_radius: int = 32) -> Vector2i:
	if start_cell not in occupied and _is_walkable(start_cell):
		return start_cell
	for r in range(1, max_radius + 1):
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				var c: Vector2i = start_cell + Vector2i(dx, dy)
				if c not in occupied and _is_walkable(c):
					return c
	return _find_nearest_walkable_cell(start_cell, occupied)

func _find_nearest_walkable_cell(start_cell: Vector2i, occupied: Array[Vector2i]) -> Vector2i:
	var best_cell: Vector2i = start_cell
	var best_dist_sq: int = 2147483647
	for cell in floorz.get_used_cells():
		var c: Vector2i = cell
		if c in occupied or not _is_walkable(c):
			continue
		var d: Vector2i = c - start_cell
		var dist_sq: int = d.x * d.x + d.y * d.y
		if dist_sq < best_dist_sq:
			best_dist_sq = dist_sq
			best_cell = c
	return best_cell

func _is_walkable(cell: Vector2i) -> bool:
	var has_floor: bool = floorz.get_cell_tile_data(cell) != null
	var has_wall: bool = wallz and wallz.get_cell_tile_data(cell) != null
	return has_floor and not has_wall
