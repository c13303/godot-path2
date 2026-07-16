extends RefCounted
class_name BuildActorDisplacementService

# Moves actors out of cells that just became occupied by player-built structures.
# BuildPlacementService owns when this runs; this service owns who moves and where.

const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)
const ACTOR_DISPLACEMENT_MAX_RADIUS: int = 6
const ACTOR_DISPLACEMENT_GROUPS: Array[StringName] = [&"main_chars", &"monsters", &"clients", AgentDefinitionService.VILLAGERS_GROUP, &"sheep", &"player"]

var _manager: BuildSystem


func setup(manager: BuildSystem) -> void:
	_manager = manager


## Shared actor-occupancy query for placement rules that must keep a cell free instead of
## displacing whoever stands there. Uses the same complete actor set as displacement.
func is_actor_in_cell(cell: Vector2i) -> bool:
	return _actor_cell_has_actor(cell)


func displace_from_cells(cells: Array[Vector2i]) -> void:
	if cells.is_empty() or _manager == null:
		return
	var blocked_cells: Dictionary = {}
	for cell: Vector2i in cells:
		blocked_cells[cell] = true
	var actors: Array[Node2D] = _actors_in_cells(blocked_cells)
	for actor: Node2D in actors:
		var from_cell: Vector2i = _floor_cell_for_actor(actor)
		if not blocked_cells.has(from_cell):
			continue
		var target_cell: Vector2i = _nearest_actor_displacement_cell(from_cell, blocked_cells)
		if target_cell == INVALID_CELL:
			continue
		_move_actor_to_cell(actor, target_cell)


func _actors_in_cells(cells: Dictionary) -> Array[Node2D]:
	var actors: Array[Node2D] = []
	var seen: Dictionary = {}
	for group_name: StringName in _actor_displacement_groups():
		for raw_node: Node in _manager.get_tree().get_nodes_in_group(group_name):
			if not (raw_node is Node2D):
				continue
			var actor: Node2D = raw_node as Node2D
			if not is_instance_valid(actor) or actor.is_queued_for_deletion():
				continue
			var instance_id: int = actor.get_instance_id()
			if seen.has(instance_id):
				continue
			var cell: Vector2i = _floor_cell_for_actor(actor)
			if not cells.has(cell):
				continue
			seen[instance_id] = true
			actors.append(actor)
	return actors


func _actor_displacement_groups() -> Array[StringName]:
	var groups: Array[StringName] = []
	var seen: Dictionary = {}
	for group_name: StringName in ACTOR_DISPLACEMENT_GROUPS:
		groups.append(group_name)
		seen[group_name] = true
	for raw_group: String in _manager.occupied_groups:
		var group_name: StringName = StringName(raw_group)
		if seen.has(group_name):
			continue
		groups.append(group_name)
		seen[group_name] = true
	return groups


func _nearest_actor_displacement_cell(from_cell: Vector2i, blocked_cells: Dictionary) -> Vector2i:
	var target_cell: Vector2i = _nearest_actor_displacement_cell_with_occupancy(from_cell, blocked_cells, true)
	if target_cell != INVALID_CELL:
		return target_cell
	return _nearest_actor_displacement_cell_with_occupancy(from_cell, blocked_cells, false)


func _nearest_actor_displacement_cell_with_occupancy(from_cell: Vector2i, blocked_cells: Dictionary, require_unoccupied: bool) -> Vector2i:
	for radius: int in range(1, ACTOR_DISPLACEMENT_MAX_RADIUS + 1):
		for y: int in range(-radius, radius + 1):
			for x: int in range(-radius, radius + 1):
				if x != -radius and x != radius and y != -radius and y != radius:
					continue
				var cell: Vector2i = from_cell + Vector2i(x, y)
				if _is_actor_displacement_target(cell, blocked_cells, require_unoccupied):
					return cell
	return INVALID_CELL


func _is_actor_displacement_target(cell: Vector2i, blocked_cells: Dictionary, require_unoccupied: bool) -> bool:
	if blocked_cells.has(cell):
		return false
	if not _has_floor_cell(cell):
		return false
	if _is_water_source_cell(cell):
		return false
	if _layer_has_cell(_manager.wallz, cell):
		return false
	if _layer_has_cell(_manager.traversable_buildings, cell):
		return false
	if _layer_has_cell(_manager.blocking_buildings, cell):
		return false
	if _layer_has_cell(_manager.fences, cell):
		return false
	var house_manager: HouseManager = _manager.get_house_manager()
	if house_manager != null and house_manager.get_house_at_presence_cell(cell) != null:
		return false
	if require_unoccupied and _actor_cell_has_actor(cell):
		return false
	return true


func _actor_cell_has_actor(cell: Vector2i) -> bool:
	for group_name: StringName in _actor_displacement_groups():
		for raw_node: Node in _manager.get_tree().get_nodes_in_group(group_name):
			if not (raw_node is Node2D):
				continue
			var actor: Node2D = raw_node as Node2D
			if not is_instance_valid(actor) or actor.is_queued_for_deletion():
				continue
			if _floor_cell_for_actor(actor) == cell:
				return true
	return false


func _has_floor_cell(cell: Vector2i) -> bool:
	return _manager.floorz != null and _manager.floorz.get_cell_source_id(cell) >= 0


func _is_water_source_cell(cell: Vector2i) -> bool:
	return _manager.watersources != null and _manager.watersources.get_cell_source_id(cell) >= 0


func _layer_has_cell(layer: TileMapLayer, cell: Vector2i) -> bool:
	return layer != null and layer.get_cell_source_id(cell) >= 0


func _floor_cell_for_actor(actor: Node2D) -> Vector2i:
	if actor == null or _manager.floorz == null:
		return INVALID_CELL
	return _manager.floorz.local_to_map(_manager.floorz.to_local(actor.global_position))


func _move_actor_to_cell(actor: Node2D, cell: Vector2i) -> void:
	var world_position: Vector2 = _cell_world_position(cell)
	var nav_id: int = _actor_nav_id(actor)
	var steering: Node = _steering_system()
	if nav_id >= 0 and steering != null and steering.has_method("set_agent_position"):
		steering.call("set_agent_position", nav_id, world_position, true)
	actor.global_position = world_position
	actor.z_index = int(world_position.y)
	_request_actor_cell_recheck(actor)


func _cell_world_position(cell: Vector2i) -> Vector2:
	var layer: TileMapLayer = _manager.wallz if _manager.wallz != null else _manager.floorz
	if layer == null:
		return Vector2.ZERO
	return layer.to_global(layer.map_to_local(cell))


func _actor_nav_id(actor: Node2D) -> int:
	if actor != null and "nav_id" in actor:
		return int(actor.get("nav_id"))
	return -1


func _steering_system() -> Node:
	if _manager == null:
		return null
	var scene: Node = _manager.get_tree().current_scene
	if scene == null:
		return null
	return scene.get_node_or_null("CPP/SteeringSystemNative")


func _request_actor_cell_recheck(actor: Node2D) -> void:
	if _manager == null or not _manager.has_method("_resolve_building_manager"):
		return
	var building_manager: Object = _manager.call("_resolve_building_manager")
	if building_manager == null or not building_manager.has_method("get_agent_cell_tracker"):
		return
	var tracker: Object = building_manager.call("get_agent_cell_tracker")
	if tracker != null and tracker.has_method("refresh_agent"):
		tracker.call("refresh_agent", actor)
