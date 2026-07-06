extends RefCounted
class_name GardenTopologyService

# Owns garden topology state: garden clustering, geometry, reachability, plant-zone
# caches, counter access cells, and the walkable-map cache. BuildingManager still
# coordinates phases, routes, retargeting, scoring, and agent behavior.

const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)
const PLANT_ZONE_MARGIN: int = 2
const GARDEN_LINK_DISTANCE: int = PLANT_ZONE_MARGIN * 2 + 1
const SPAWNER_KIND_MONSTER: StringName = &"monster"
const SPAWNER_KIND_CLIENT: StringName = &"client"

var _manager: Node
var _gardens: Dictionary = {}
var _garden_by_plant_cell: Dictionary = {}
var _dirty_gardens: Dictionary = {}
var _next_garden_id: int = 1
var _gardens_epoch: int = 0
var _gardens_iter_depth: int = 0
var _garden_debug_logs: bool = true
var _pending_empty_gardens: Dictionary = {}
var _spawner_reachable_cells: Dictionary = {}
var _walkable_map_tiles: Dictionary = {}
var _plant_zone_tiles: Dictionary = {}
var _plant_zone_margin_tiles: Dictionary = {}
var _plant_zone_built: bool = false
var _counter_access_cells: Dictionary = {}


func setup(manager: Node) -> void:
	_manager = manager


func gardens() -> Dictionary:
	return _gardens


func garden_by_plant_cell() -> Dictionary:
	return _garden_by_plant_cell


func dirty_gardens() -> Dictionary:
	return _dirty_gardens


func pending_empty_gardens() -> Dictionary:
	return _pending_empty_gardens


func spawner_reachable_cells() -> Dictionary:
	return _spawner_reachable_cells


func walkable_map_tiles() -> Dictionary:
	return _walkable_map_tiles


func plant_zone_tiles() -> Dictionary:
	return _plant_zone_tiles


func plant_zone_margin_tiles() -> Dictionary:
	return _plant_zone_margin_tiles


func counter_access_cells() -> Dictionary:
	return _counter_access_cells


func plant_zone_built() -> bool:
	return _plant_zone_built


func set_plant_zone_built(value: bool) -> void:
	_plant_zone_built = value


func gardens_iter_depth() -> int:
	return _gardens_iter_depth


func begin_garden_iteration() -> void:
	_gardens_iter_depth += 1


func end_garden_iteration() -> void:
	_gardens_iter_depth = maxi(0, _gardens_iter_depth - 1)


func clear_counter_access_cells() -> void:
	_counter_access_cells.clear()


func rebuild_walkable_map_cache_budgeted(token: int) -> bool:
	_walkable_map_tiles.clear()
	var floorz: TileMapLayer = _floorz()
	if floorz == null:
		return true
	var slice_started_us: int = Time.get_ticks_usec()
	var floor_cells: Array[Vector2i] = floorz.get_used_cells()
	for cell: Vector2i in floor_cells:
		if not _night_preparation_is_current(token):
			return false
		if _is_walkable(cell):
			_walkable_map_tiles[cell] = true
		if Time.get_ticks_usec() - slice_started_us >= _night_preparation_budget_us():
			await _manager.get_tree().process_frame
			slice_started_us = Time.get_ticks_usec()
	return true


func build_gardens_from_plants_budgeted(token: int) -> bool:
	_reset_for_full_rebuild("night_prepare_gardens")
	if _plant_manager() == null or not _plant_manager().has_method("get_plant_cells"):
		_plant_zone_built = true
		return true

	var unassigned: Dictionary = {}
	var source_cells: Array = _plant_manager().call("get_plant_cells") as Array
	source_cells.append_array(collect_counter_access_cells())
	for raw_cell: Variant in source_cells:
		var source_cell: Vector2i = raw_cell as Vector2i
		if not _is_walkable(source_cell):
			continue
		unassigned[source_cell] = true

	var slice_started_us: int = Time.get_ticks_usec()
	while not unassigned.is_empty():
		if not _night_preparation_is_current(token):
			return false
		var seed_cell: Vector2i = unassigned.keys()[0] as Vector2i
		var garden_id: int = create_garden()
		var garden: Dictionary = _gardens[garden_id] as Dictionary
		var garden_plants: Dictionary = garden.get("plant_cells", {}) as Dictionary
		var frontier_plants: Array[Vector2i] = [seed_cell]
		unassigned.erase(seed_cell)
		garden_plants[seed_cell] = true
		_garden_by_plant_cell[seed_cell] = garden_id

		while not frontier_plants.is_empty():
			var from_plant: Vector2i = frontier_plants.pop_back()
			var visited: Dictionary = {from_plant: 0}
			var queue: Array[Vector2i] = [from_plant]
			var head: int = 0
			while head < queue.size():
				if not _night_preparation_is_current(token):
					return false
				var cell: Vector2i = queue[head]
				head += 1
				var distance: int = int(visited[cell])
				if distance < GARDEN_LINK_DISTANCE:
					for dy: int in range(-1, 2):
						for dx: int in range(-1, 2):
							if dx == 0 and dy == 0:
								continue
							var neighbor: Vector2i = cell + Vector2i(dx, dy)
							if visited.has(neighbor) or not _is_walkable(neighbor):
								continue
							if dx != 0 and dy != 0:
								if not _is_walkable(cell + Vector2i(dx, 0)) or not _is_walkable(cell + Vector2i(0, dy)):
									continue
							visited[neighbor] = distance + 1
							queue.append(neighbor)
							if unassigned.has(neighbor):
								unassigned.erase(neighbor)
								garden_plants[neighbor] = true
								_garden_by_plant_cell[neighbor] = garden_id
								frontier_plants.append(neighbor)
				if Time.get_ticks_usec() - slice_started_us >= _night_preparation_budget_us():
					await _manager.get_tree().process_frame
					slice_started_us = Time.get_ticks_usec()

		garden["plant_cells"] = garden_plants
		garden["edible_count"] = garden_plants.size()
		garden["targetable"] = false
		_gardens[garden_id] = garden
		mark_garden_dirty(garden_id, false)
	_plant_zone_built = true
	return true


func validate_gardens_budgeted(token: int) -> bool:
	var dirty_ids: Array = _dirty_gardens.keys()
	_dirty_gardens.clear()
	_clear_garden_entry_resolve_cache("night_prepare_validate")
	for raw_garden_id: Variant in dirty_ids:
		if not _night_preparation_is_current(token):
			return false
		var garden_id: int = int(raw_garden_id)
		if not _gardens.has(garden_id):
			continue
		var garden: Dictionary = _gardens[garden_id] as Dictionary
		var plant_cells: Dictionary = garden.get("plant_cells", {}) as Dictionary
		if plant_cells.is_empty():
			_release_garden_routes(garden_id)
			erase_garden(garden_id, "night_prepare_empty")
			continue
		var geometry_result: Variant = await recompute_garden_geometry_budgeted(garden_id, token)
		if not bool(geometry_result):
			return false

	var reachable_result: Variant = await recompute_spawner_reachable_cells_budgeted(token)
	if not bool(reachable_result):
		return false
	_gardens_iter_depth += 1
	var total_entry_points: int = 0
	var slice_started_us: int = Time.get_ticks_usec()
	for raw_garden_id: Variant in _gardens.keys():
		if not _night_preparation_is_current(token):
			_gardens_iter_depth -= 1
			return false
		var garden_id: int = int(raw_garden_id)
		apply_spawner_reachability(garden_id)
		total_entry_points += (_gardens[garden_id] as Dictionary).get("entry_cells", []).size()
		if Time.get_ticks_usec() - slice_started_us >= _night_preparation_budget_us():
			await _manager.get_tree().process_frame
			slice_started_us = Time.get_ticks_usec()
	_gardens_iter_depth -= 1
	var cache_result: Variant = await rebuild_plant_zone_compatibility_cache_budgeted(token)
	if not bool(cache_result):
		return false
	_plant_zone_built = true
	_queue_zone_overlay_redraw()
	if _is_verbose():
		print("BuildingManager: %d gardens recomputed with %d entry points" % [_gardens.size(), total_entry_points])
	return true


func recompute_garden_geometry_budgeted(garden_id: int, token: int) -> bool:
	if not _gardens.has(garden_id):
		return true
	var garden: Dictionary = _gardens[garden_id] as Dictionary
	var plant_cells: Dictionary = garden.get("plant_cells", {}) as Dictionary
	var zone_tiles: Dictionary = {}
	var distances: Dictionary = {}
	var queue: Array[Vector2i] = []
	var head: int = 0
	for raw_cell: Variant in plant_cells.keys():
		var plant_cell: Vector2i = raw_cell as Vector2i
		zone_tiles[plant_cell] = true
		distances[plant_cell] = 0
		queue.append(plant_cell)
	var entry_inside: Dictionary = {}
	var slice_started_us: int = Time.get_ticks_usec()
	while head < queue.size():
		if not _night_preparation_is_current(token):
			return false
		var cell: Vector2i = queue[head]
		head += 1
		var cell_distance: int = int(distances[cell])
		for dy: int in range(-1, 2):
			for dx: int in range(-1, 2):
				if dx == 0 and dy == 0:
					continue
				var neighbor: Vector2i = cell + Vector2i(dx, dy)
				if not _is_walkable(neighbor):
					continue
				if dx != 0 and dy != 0:
					if not _is_walkable(cell + Vector2i(dx, 0)) or not _is_walkable(cell + Vector2i(0, dy)):
						continue
				if zone_tiles.has(neighbor):
					continue
				var next_distance: int = cell_distance + 1
				if next_distance <= PLANT_ZONE_MARGIN:
					if not distances.has(neighbor) or next_distance < int(distances[neighbor]):
						distances[neighbor] = next_distance
						zone_tiles[neighbor] = true
						queue.append(neighbor)
				else:
					entry_inside[cell] = true
		if Time.get_ticks_usec() - slice_started_us >= _night_preparation_budget_us():
			await _manager.get_tree().process_frame
			slice_started_us = Time.get_ticks_usec()

	var margin_tiles: Dictionary = {}
	for raw_cell: Variant in zone_tiles.keys():
		var zone_cell: Vector2i = raw_cell as Vector2i
		if not plant_cells.has(zone_cell):
			margin_tiles[zone_cell] = true
	var entry_cells: Array[Vector2i] = []
	for raw_cell: Variant in entry_inside.keys():
		entry_cells.append(raw_cell as Vector2i)
	garden["zone_tiles"] = zone_tiles
	garden["margin_tiles"] = margin_tiles
	garden["entry_cells"] = entry_cells
	garden["reachable"] = not entry_cells.is_empty()
	garden["edible_count"] = plant_cells.size()
	garden["targetable"] = plant_cells.size() > 0 and not entry_cells.is_empty()
	garden["dirty"] = false
	_gardens[garden_id] = garden
	return true


func recompute_spawner_reachable_cells_budgeted(token: int) -> bool:
	_spawner_reachable_cells.clear()
	var spawners: Dictionary = _spawners()
	if spawners.is_empty():
		return true
	var queue: Array[Vector2i] = []
	var head: int = 0
	for raw_spawner_cell: Variant in spawners.keys():
		var spawner_cell: Vector2i = raw_spawner_cell as Vector2i
		for dy: int in range(-1, 2):
			for dx: int in range(-1, 2):
				var candidate_cell: Vector2i = spawner_cell + Vector2i(dx, dy)
				if _spawner_reachable_cells.has(candidate_cell) or not _is_walkable(candidate_cell):
					continue
				_spawner_reachable_cells[candidate_cell] = true
				queue.append(candidate_cell)
	var slice_started_us: int = Time.get_ticks_usec()
	while head < queue.size():
		if not _night_preparation_is_current(token):
			return false
		var cell: Vector2i = queue[head]
		head += 1
		for dy: int in range(-1, 2):
			for dx: int in range(-1, 2):
				if dx == 0 and dy == 0:
					continue
				var neighbor: Vector2i = cell + Vector2i(dx, dy)
				if _spawner_reachable_cells.has(neighbor) or not _is_walkable(neighbor):
					continue
				if dx != 0 and dy != 0:
					if not _is_walkable(cell + Vector2i(dx, 0)) or not _is_walkable(cell + Vector2i(0, dy)):
						continue
				_spawner_reachable_cells[neighbor] = true
				queue.append(neighbor)
		if Time.get_ticks_usec() - slice_started_us >= _night_preparation_budget_us():
			await _manager.get_tree().process_frame
			slice_started_us = Time.get_ticks_usec()
	return true


func rebuild_plant_zone_compatibility_cache_budgeted(token: int) -> bool:
	_plant_zone_tiles.clear()
	_plant_zone_margin_tiles.clear()
	var slice_started_us: int = Time.get_ticks_usec()
	for raw_garden: Variant in _gardens.values():
		if not _night_preparation_is_current(token):
			return false
		var garden: Dictionary = raw_garden as Dictionary
		var zone_tiles: Dictionary = garden.get("zone_tiles", {}) as Dictionary
		var margin_tiles: Dictionary = garden.get("margin_tiles", {}) as Dictionary
		for raw_cell: Variant in zone_tiles.keys():
			var zone_cell: Vector2i = raw_cell as Vector2i
			_plant_zone_tiles[zone_cell] = true
		for raw_cell: Variant in margin_tiles.keys():
			var margin_cell: Vector2i = raw_cell as Vector2i
			_plant_zone_margin_tiles[margin_cell] = true
		if Time.get_ticks_usec() - slice_started_us >= _night_preparation_budget_us():
			await _manager.get_tree().process_frame
			slice_started_us = Time.get_ticks_usec()
	return true


func rebuild_walkable_map_cache() -> void:
	_walkable_map_tiles.clear()
	var floorz: TileMapLayer = _floorz()
	if floorz == null:
		return
	for raw_cell: Variant in floorz.get_used_cells():
		var cell: Vector2i = raw_cell as Vector2i
		if _is_walkable(cell):
			_walkable_map_tiles[cell] = true


func build_plant_zone() -> void:
	if _plant_zone_built:
		return
	build_gardens_from_plants()
	validate_dirty_gardens()


func rebuild_plant_zone_from_layer() -> void:
	var debug_telemetry: BuildingDebugTelemetry = _debug_telemetry()
	var rebuild_us: int = Time.get_ticks_usec()
	var t: int = Time.get_ticks_usec()
	build_gardens_from_plants()
	debug_telemetry.warn_garden_task_lag_us("_build_gardens_from_plants", Time.get_ticks_usec() - t,
		"gardens=%d" % _gardens.size())
	t = Time.get_ticks_usec()
	validate_dirty_gardens()
	debug_telemetry.warn_garden_task_lag_us("_validate_dirty_gardens", Time.get_ticks_usec() - t,
		"gardens=%d" % _gardens.size())
	t = Time.get_ticks_usec()
	_manager.call("_rebuild_spawner_garden_route_cache")
	debug_telemetry.warn_garden_task_lag_us("_rebuild_spawner_garden_route_cache", Time.get_ticks_usec() - t,
		"spawners=%d" % int(_manager.call("_spawner_garden_route_count")))
	t = Time.get_ticks_usec()
	_manager.call("_queue_agents_after_garden_rebuild")
	debug_telemetry.warn_garden_task_lag_us("_queue_agents_after_garden_rebuild", Time.get_ticks_usec() - t,
		"retarget_queue=%d" % int(_manager.call("_garden_retarget_queue_size")))
	debug_telemetry.warn_garden_task_lag_us("_rebuild_plant_zone_from_layer", Time.get_ticks_usec() - rebuild_us,
		"gardens=%d" % _gardens.size())


func build_gardens_from_plants() -> void:
	if _gardens_iter_depth > 0:
		push_warning("GARDEN-CRASH-GUARD: full rebuild requested mid-iteration (depth=%d)!" % _gardens_iter_depth)
	_reset_for_full_rebuild("build_gardens")
	var plant_manager: Node = _plant_manager()
	if plant_manager == null or not plant_manager.has_method("get_plant_cells"):
		rebuild_plant_zone_compatibility_cache()
		_plant_zone_built = true
		return
	var plant_cells_from_manager: Array = plant_manager.call("get_plant_cells") as Array
	var eatable_cells: Array = plant_cells_from_manager.duplicate()
	eatable_cells.append_array(collect_counter_access_cells())
	_cluster_plants_by_walkable_reachability(eatable_cells)
	_plant_zone_built = true


func add_plant_to_gardens(cell: Vector2i) -> void:
	if _garden_by_plant_cell.has(cell):
		return
	rebuild_plant_zone_from_layer()


func remove_plant_from_garden_content_only(cell: Vector2i) -> Dictionary:
	if not _garden_by_plant_cell.has(cell):
		return {
			"garden_id": 0,
			"was_removed": false,
			"became_empty": false,
			"remaining_count": 0
		}
	var garden_id: int = int(_garden_by_plant_cell[cell])
	_garden_by_plant_cell.erase(cell)
	if not _gardens.has(garden_id):
		return {
			"garden_id": garden_id,
			"was_removed": true,
			"became_empty": true,
			"remaining_count": 0
		}
	var garden: Dictionary = _gardens[garden_id] as Dictionary
	var plant_cells: Dictionary = garden.get("plant_cells", {}) as Dictionary
	plant_cells.erase(cell)
	var remaining_count: int = plant_cells.size()
	garden["plant_cells"] = plant_cells
	garden["edible_count"] = remaining_count
	if remaining_count == 0:
		garden["targetable"] = false
	else:
		garden["targetable"] = bool(garden.get("reachable", false))
	_gardens[garden_id] = garden
	return {
		"garden_id": garden_id,
		"was_removed": true,
		"became_empty": remaining_count == 0,
		"remaining_count": remaining_count
	}


func erase_garden(garden_id: int, reason: String) -> void:
	if _gardens_iter_depth > 0 and reason != "mark_empty":
		push_warning("GARDEN-CRASH-GUARD: _gardens erased during iteration! id=%d reason=%s depth=%d size_before=%d" % [
			garden_id, reason, _gardens_iter_depth, _gardens.size()
		])
	if _garden_debug_logs:
		_debug_telemetry().log("garden erase id=%d reason=%s gardens_now=%d" % [garden_id, reason, _gardens.size() - 1])
	_pending_empty_gardens.erase(garden_id)
	_gardens.erase(garden_id)
	_dirty_gardens.erase(garden_id)
	if _plant_zone_built:
		rebuild_plant_zone_compatibility_cache()
	_queue_zone_overlay_redraw()


func create_garden() -> int:
	var garden_id: int = _next_garden_id
	_next_garden_id += 1
	_gardens[garden_id] = {
		"id": garden_id,
		"epoch": _gardens_epoch,
		"plant_cells": {},
		"zone_tiles": {},
		"margin_tiles": {},
		"entry_cells": [],
		"edible_count": 0,
		"targetable": false,
		"dirty": true,
		"reachable": false,
		"version": 0
	}
	_dirty_gardens[garden_id] = true
	return garden_id


func mark_garden_dirty(garden_id: int, invalidate_routes: bool) -> void:
	if not _gardens.has(garden_id):
		return
	var garden: Dictionary = _gardens[garden_id] as Dictionary
	garden["dirty"] = true
	if invalidate_routes:
		garden["reachable"] = false
		garden["targetable"] = false
		garden["version"] = int(garden.get("version", 0)) + 1
	_gardens[garden_id] = garden
	_dirty_gardens[garden_id] = true


func validate_dirty_gardens() -> void:
	if _dirty_gardens.is_empty():
		rebuild_plant_zone_compatibility_cache()
		return
	var dirty_ids: Array = _dirty_gardens.keys()
	_dirty_gardens.clear()
	_clear_garden_entry_resolve_cache("validate_dirty_gardens")
	for raw_garden_id: Variant in dirty_ids:
		var garden_id: int = int(raw_garden_id)
		if not _gardens.has(garden_id):
			continue
		var garden: Dictionary = _gardens[garden_id] as Dictionary
		var plant_cells: Dictionary = garden.get("plant_cells", {}) as Dictionary
		if plant_cells.is_empty():
			_release_garden_routes(garden_id)
			erase_garden(garden_id, "validate_empty")
			continue
		recompute_garden_geometry(garden_id)
	recompute_spawner_reachable_cells()
	_gardens_iter_depth += 1
	var total_entry_points: int = 0
	for raw_garden_id: Variant in _gardens.keys():
		var gid: int = int(raw_garden_id)
		apply_spawner_reachability(gid)
		total_entry_points += (_gardens[gid] as Dictionary).get("entry_cells", []).size()
	_gardens_iter_depth -= 1
	rebuild_plant_zone_compatibility_cache()
	_plant_zone_built = true
	_queue_zone_overlay_redraw()
	if _is_verbose():
		print("BuildingManager: %d gardens recomputed with %d entry points" % [_gardens.size(), total_entry_points])


func recompute_garden_geometry(garden_id: int) -> void:
	var garden: Dictionary = _gardens[garden_id] as Dictionary
	var plant_cells: Dictionary = garden.get("plant_cells", {}) as Dictionary
	var zone_tiles: Dictionary = {}
	var dist: Dictionary = {}
	var queue: Array[Vector2i] = []
	var head: int = 0
	for raw_cell: Variant in plant_cells.keys():
		var plant_cell: Vector2i = raw_cell as Vector2i
		zone_tiles[plant_cell] = true
		dist[plant_cell] = 0
		queue.append(plant_cell)

	var entry_inside: Dictionary = {}
	while head < queue.size():
		var cell: Vector2i = queue[head]
		head += 1
		var cell_dist: int = int(dist[cell])
		for dy: int in range(-1, 2):
			for dx: int in range(-1, 2):
				if dx == 0 and dy == 0:
					continue
				var neighbor: Vector2i = cell + Vector2i(dx, dy)
				if not _is_walkable(neighbor):
					continue
				if dx != 0 and dy != 0:
					if not _is_walkable(cell + Vector2i(dx, 0)) or not _is_walkable(cell + Vector2i(0, dy)):
						continue
				if zone_tiles.has(neighbor):
					continue
				var next_dist: int = cell_dist + 1
				if next_dist <= PLANT_ZONE_MARGIN:
					if not dist.has(neighbor) or next_dist < int(dist[neighbor]):
						dist[neighbor] = next_dist
						zone_tiles[neighbor] = true
						queue.append(neighbor)
				else:
					entry_inside[cell] = true

	var margin_tiles: Dictionary = {}
	for raw_cell: Variant in zone_tiles.keys():
		var zone_cell: Vector2i = raw_cell as Vector2i
		if not plant_cells.has(zone_cell):
			margin_tiles[zone_cell] = true
	var entry_cells: Array[Vector2i] = []
	for raw_cell: Variant in entry_inside.keys():
		var access_cell: Vector2i = raw_cell as Vector2i
		entry_cells.append(access_cell)

	garden["zone_tiles"] = zone_tiles
	garden["margin_tiles"] = margin_tiles
	garden["entry_cells"] = entry_cells
	garden["reachable"] = not entry_cells.is_empty()
	garden["edible_count"] = plant_cells.size()
	garden["targetable"] = plant_cells.size() > 0 and not entry_cells.is_empty()
	garden["dirty"] = false
	_gardens[garden_id] = garden


func recompute_spawner_reachable_cells() -> void:
	_spawner_reachable_cells.clear()
	var spawners: Dictionary = _spawners()
	if spawners.is_empty():
		return
	var queue: Array[Vector2i] = []
	var head: int = 0
	for raw_spawner_cell: Variant in spawners.keys():
		var spawner_cell: Vector2i = raw_spawner_cell as Vector2i
		for dy: int in range(-1, 2):
			for dx: int in range(-1, 2):
				var myseed: Vector2i = spawner_cell + Vector2i(dx, dy)
				if _spawner_reachable_cells.has(myseed):
					continue
				if not _is_walkable(myseed):
					continue
				_spawner_reachable_cells[myseed] = true
				queue.append(myseed)
	while head < queue.size():
		var cell: Vector2i = queue[head]
		head += 1
		for dy: int in range(-1, 2):
			for dx: int in range(-1, 2):
				if dx == 0 and dy == 0:
					continue
				var neighbor: Vector2i = cell + Vector2i(dx, dy)
				if _spawner_reachable_cells.has(neighbor):
					continue
				if not _is_walkable(neighbor):
					continue
				if dx != 0 and dy != 0:
					if not _is_walkable(cell + Vector2i(dx, 0)) or not _is_walkable(cell + Vector2i(0, dy)):
						continue
				_spawner_reachable_cells[neighbor] = true
				queue.append(neighbor)


func apply_spawner_reachability(garden_id: int) -> void:
	if not _gardens.has(garden_id):
		return
	var garden: Dictionary = _gardens[garden_id] as Dictionary
	var entry_cells: Array = garden.get("entry_cells", []) as Array
	var reachable: bool = false
	var spawners: Dictionary = _spawners()
	if spawners.is_empty():
		reachable = not entry_cells.is_empty()
	else:
		for raw_cell: Variant in entry_cells:
			var entry_cell: Vector2i = raw_cell as Vector2i
			if _spawner_reachable_cells.has(entry_cell):
				reachable = true
				break
	garden["reachable"] = reachable
	var plant_cells: Dictionary = garden.get("plant_cells", {}) as Dictionary
	garden["targetable"] = reachable and plant_cells.size() > 0
	_gardens[garden_id] = garden


func rebuild_plant_zone_compatibility_cache() -> void:
	_plant_zone_tiles.clear()
	_plant_zone_margin_tiles.clear()
	for raw_garden: Variant in _gardens.values():
		var garden: Dictionary = raw_garden as Dictionary
		var zone_tiles: Dictionary = garden.get("zone_tiles", {}) as Dictionary
		var margin_tiles: Dictionary = garden.get("margin_tiles", {}) as Dictionary
		var plant_cells: Dictionary = garden.get("plant_cells", {}) as Dictionary
		for raw_cell: Variant in zone_tiles.keys():
			var zone_cell: Vector2i = raw_cell as Vector2i
			_plant_zone_tiles[zone_cell] = true
		for raw_cell: Variant in margin_tiles.keys():
			var margin_cell: Vector2i = raw_cell as Vector2i
			_plant_zone_margin_tiles[margin_cell] = true
		if bool(garden.get("dirty", false)):
			for raw_cell: Variant in plant_cells.keys():
				var plant_cell: Vector2i = raw_cell as Vector2i
				_plant_zone_tiles[plant_cell] = true


func collect_counter_access_cells() -> Array[Vector2i]:
	var raw_cells: Array = _manager.call("_collect_counter_access_cells_into", _counter_access_cells) as Array
	var cells: Array[Vector2i] = []
	for raw_cell: Variant in raw_cells:
		cells.append(raw_cell as Vector2i)
	return cells


func garden_has_target_for_kind(garden_id: int, agent_kind: StringName) -> bool:
	if agent_kind == SPAWNER_KIND_CLIENT:
		return garden_has_client_targets(garden_id)
	return garden_has_edible_plants(garden_id)


func has_client_targets_remaining() -> bool:
	if int(_manager.call("_total_counter_stock")) > 0:
		return true
	for raw_garden_id: Variant in _gardens.keys():
		if garden_has_client_targets(int(raw_garden_id)):
			return true
	return false


func garden_has_client_targets(garden_id: int) -> bool:
	if not _gardens.has(garden_id):
		return false
	var garden: Dictionary = _gardens[garden_id] as Dictionary
	var plant_cells: Dictionary = garden.get("plant_cells", {}) as Dictionary
	if plant_cells.is_empty():
		return false
	for raw_cell: Variant in plant_cells.keys():
		var cell: Vector2i = raw_cell as Vector2i
		if is_client_target_cell(cell):
			return true
	return false


func is_client_target_cell(cell: Vector2i) -> bool:
	if _counter_access_cells.has(cell):
		return int(_manager.call("_counter_stock", _counter_access_cells[cell] as Vector2i)) > 0
	var plant_manager: Node = _plant_manager()
	if plant_manager and plant_manager.has_method("has_plant") and not bool(plant_manager.call("has_plant", cell)):
		return false
	return bool(_manager.call("_is_grownup_rose_cell", cell))


func garden_has_grownup_roses(garden_id: int) -> bool:
	if not _gardens.has(garden_id):
		return false
	var garden: Dictionary = _gardens[garden_id] as Dictionary
	var plant_cells: Dictionary = garden.get("plant_cells", {}) as Dictionary
	if plant_cells.is_empty():
		return false
	for raw_cell: Variant in plant_cells.keys():
		var cell: Vector2i = raw_cell as Vector2i
		if bool(_manager.call("_is_grownup_rose_cell", cell)):
			return true
	return false


func garden_has_edible_plants(garden_id: int) -> bool:
	if not _gardens.has(garden_id):
		return false
	var garden: Dictionary = _gardens[garden_id] as Dictionary
	var plant_cells: Dictionary = garden.get("plant_cells", {}) as Dictionary
	if plant_cells.is_empty():
		_pending_empty_gardens[garden_id] = true
		return false
	var plant_manager: Node = _plant_manager()
	if plant_manager == null or not plant_manager.has_method("has_plant"):
		return true
	for raw_cell: Variant in plant_cells.keys():
		var cell: Vector2i = raw_cell as Vector2i
		if is_eatable_for_monster(cell):
			return true
	_pending_empty_gardens[garden_id] = true
	return false


func drain_pending_empty_gardens() -> void:
	if _pending_empty_gardens.is_empty():
		return
	if _gardens_iter_depth > 0:
		push_warning("GARDEN-CRASH-GUARD: drain requested mid-iteration; deferring %d" % _pending_empty_gardens.size())
		return
	var ids: Array = _pending_empty_gardens.keys()
	_pending_empty_gardens.clear()
	for raw_id: Variant in ids:
		mark_garden_empty(int(raw_id))


func mark_garden_empty(garden_id: int) -> void:
	if not _gardens.has(garden_id):
		return
	var garden: Dictionary = _gardens[garden_id] as Dictionary
	var plant_cells: Dictionary = garden.get("plant_cells", {}) as Dictionary
	for raw_cell: Variant in plant_cells.keys():
		var cell: Vector2i = raw_cell as Vector2i
		_garden_by_plant_cell.erase(cell)
	garden["plant_cells"] = {}
	garden["edible_count"] = 0
	garden["targetable"] = false
	_gardens[garden_id] = garden
	_pending_empty_gardens.erase(garden_id)
	_release_garden_routes(garden_id)
	erase_garden(garden_id, "mark_empty")


func is_eatable_for_monster(cell: Vector2i) -> bool:
	if _counter_access_cells.has(cell):
		return int(_manager.call("_counter_stock", _counter_access_cells[cell] as Vector2i)) > 0
	var plant_manager: Node = _plant_manager()
	return plant_manager != null and plant_manager.has_method("has_plant") and bool(plant_manager.call("has_plant", cell))


func _reset_for_full_rebuild(cache_reason: String) -> void:
	_gardens.clear()
	_garden_by_plant_cell.clear()
	_counter_access_cells.clear()
	_dirty_gardens.clear()
	_pending_empty_gardens.clear()
	_clear_garden_entry_resolve_cache(cache_reason)
	_gardens_epoch += 1


func _cluster_plants_by_walkable_reachability(plant_cells_from_manager: Array) -> void:
	var unassigned: Dictionary = {}
	for raw_cell: Variant in plant_cells_from_manager:
		var cell: Vector2i = raw_cell as Vector2i
		if not _is_walkable(cell):
			continue
		unassigned[cell] = true

	while not unassigned.is_empty():
		var seed_cell: Vector2i = unassigned.keys()[0] as Vector2i
		var garden_id: int = create_garden()
		var garden: Dictionary = _gardens[garden_id] as Dictionary
		var plant_cells: Dictionary = garden.get("plant_cells", {}) as Dictionary
		var frontier_plants: Array[Vector2i] = [seed_cell]
		unassigned.erase(seed_cell)
		plant_cells[seed_cell] = true
		_garden_by_plant_cell[seed_cell] = garden_id

		while not frontier_plants.is_empty():
			var from_plant: Vector2i = frontier_plants.pop_back()
			var reached: Array[Vector2i] = _bounded_walkable_plant_search(from_plant, unassigned)
			for reached_cell: Vector2i in reached:
				unassigned.erase(reached_cell)
				plant_cells[reached_cell] = true
				_garden_by_plant_cell[reached_cell] = garden_id
				frontier_plants.append(reached_cell)

		garden["plant_cells"] = plant_cells
		garden["edible_count"] = plant_cells.size()
		garden["targetable"] = false
		_gardens[garden_id] = garden
		mark_garden_dirty(garden_id, false)


func _bounded_walkable_plant_search(seed_cell: Vector2i, unassigned: Dictionary) -> Array[Vector2i]:
	var found: Array[Vector2i] = []
	var visited: Dictionary = {seed_cell: 0}
	var queue: Array[Vector2i] = [seed_cell]
	var head: int = 0
	while head < queue.size():
		var cell: Vector2i = queue[head]
		head += 1
		var dist: int = int(visited[cell])
		if dist >= GARDEN_LINK_DISTANCE:
			continue
		for dy: int in range(-1, 2):
			for dx: int in range(-1, 2):
				if dx == 0 and dy == 0:
					continue
				var neighbor: Vector2i = cell + Vector2i(dx, dy)
				if visited.has(neighbor):
					continue
				if not _is_walkable(neighbor):
					continue
				if dx != 0 and dy != 0:
					if not _is_walkable(cell + Vector2i(dx, 0)) or not _is_walkable(cell + Vector2i(0, dy)):
						continue
				visited[neighbor] = dist + 1
				queue.append(neighbor)
				if unassigned.has(neighbor):
					found.append(neighbor)
	return found


func _floorz() -> TileMapLayer:
	return _manager.get("floorz") as TileMapLayer


func _plant_manager() -> Node:
	return _manager.get("plant_manager") as Node


func _spawners() -> Dictionary:
	return _manager.get("_spawners") as Dictionary


func _debug_telemetry() -> BuildingDebugTelemetry:
	return _manager.get("_debug_telemetry") as BuildingDebugTelemetry


func _is_walkable(cell: Vector2i) -> bool:
	return bool(_manager.call("_is_walkable", cell))


func _night_preparation_is_current(token: int) -> bool:
	return bool(_manager.call("_night_preparation_is_current", token))


func _night_preparation_budget_us() -> int:
	return int(_manager.call("_night_preparation_budget_us"))


func _clear_garden_entry_resolve_cache(reason: String) -> void:
	_manager.call("_clear_garden_entry_resolve_cache", reason)


func _release_garden_routes(garden_id: int) -> void:
	_manager.call("_release_garden_routes", garden_id)


func _queue_zone_overlay_redraw() -> void:
	_manager.call("_queue_zone_overlay_redraw")


func _is_verbose() -> bool:
	return bool(_manager.call("_is_verbose"))
