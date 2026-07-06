extends RefCounted
class_name SpawnerRouteService

# Owns spawner escape routes, spawner-to-garden route flow groups, and exit-wall
# escape flow groups. BuildingManager keeps spawner/garden source-of-truth state.

const IDLE_GROUP: int = 0
const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)
const EXIT_WALL_ATLAS: Vector2i = Vector2i(13, 0)
const SPAWNER_KIND_MONSTER: StringName = &"monster"

var _manager: Node
var _spawner_routes: Dictionary = {}
var _spawner_garden_routes: Dictionary = {}
var _dirty_spawner_escapes: Dictionary = {}
var _exit_wall_escapes: Dictionary = {}
var _route_cache_hits: int = 0
var _route_cache_misses: int = 0


func setup(manager: Node) -> void:
	_manager = manager


func route_cache_hits() -> int:
	return _route_cache_hits


func route_cache_misses() -> int:
	return _route_cache_misses


func dirty_spawner_escape_count() -> int:
	return _dirty_spawner_escapes.size()


func exit_wall_escape_count() -> int:
	return _exit_wall_escapes.size()


func spawner_garden_route_count() -> int:
	return _spawner_garden_routes.size()


func has_spawner_route(spawner_cell: Vector2i) -> bool:
	return _spawner_routes.has(spawner_cell)


func get_spawner_route(spawner_cell: Vector2i) -> Dictionary:
	return (_spawner_routes.get(spawner_cell, {}) as Dictionary).duplicate()


func mark_spawner_escape_dirty(spawner_cell: Vector2i) -> void:
	_dirty_spawner_escapes[spawner_cell] = true


func clear_dirty_spawner_escape(spawner_cell: Vector2i) -> void:
	_dirty_spawner_escapes.erase(spawner_cell)


func flow_uses_async_requests() -> bool:
	var flow: Node = _flow()
	return (
		flow != null
		and flow.has_method("request_flow_to_group")
		and flow.has_method("are_async_flows_idle")
		and flow.has_method("is_group_flow_request_ready")
	)


func flow_supports_sync_assign() -> bool:
	var flow: Node = _flow()
	return flow != null and flow.has_method("assign_flow_to_group")


func group_flow_id_is_ready(group_id: int) -> bool:
	if group_id <= IDLE_GROUP:
		return false
	var flow: Node = _flow()
	if flow == null:
		return false
	if flow.has_method("is_group_flow_request_ready"):
		return bool(flow.call("is_group_flow_request_ready", group_id))
	return flow.has_method("group_route_cost_at_world")


func group_flow_is_ready_at_world(group_id: int, world_pos: Vector2) -> bool:
	if group_id <= IDLE_GROUP:
		return false
	var flow: Node = _flow()
	if flow == null or not flow.has_method("group_route_cost_at_world"):
		return false
	if not group_flow_id_is_ready(group_id):
		return false
	var cost: float = float(flow.call("group_route_cost_at_world", group_id, world_pos))
	return is_finite(cost)


func initialize_spawner_routes_for_kinds(agent_kinds: Array[StringName], token: int) -> bool:
	var slice_started_us: int = Time.get_ticks_usec()
	var spawners: Dictionary = _spawners()
	for raw_spawner_cell: Variant in spawners.keys():
		if not _night_preparation_is_current(token):
			return false
		var spawner_cell: Vector2i = raw_spawner_cell as Vector2i
		if not _spawner_is_one_of_kinds(spawner_cell, agent_kinds):
			continue
		initialize_spawner_route(spawner_cell)
		if Time.get_ticks_usec() - slice_started_us >= _night_preparation_budget_us():
			await _manager.get_tree().process_frame
			slice_started_us = Time.get_ticks_usec()
	return true


func night_flow_fields_are_ready_for_kinds(agent_kinds: Array[StringName], check_exit_wall_escapes: bool) -> bool:
	var flow: Node = _flow()
	if not flow or not flow.has_method("group_route_cost_at_world"):
		return false
	var spawners: Dictionary = _spawners()
	for raw_spawner_cell: Variant in spawners.keys():
		var spawner_cell: Vector2i = raw_spawner_cell as Vector2i
		if not _spawner_is_one_of_kinds(spawner_cell, agent_kinds):
			continue
		if not _spawner_routes.has(spawner_cell):
			return false
		var route: Dictionary = _spawner_routes[spawner_cell] as Dictionary
		if not bool(route.get("escape_ready", false)):
			return false
		var group_id: int = int(route.get("escape_group", -1))
		var goal_world: Vector2 = route.get("escape_world", Vector2.ZERO) as Vector2
		if not group_flow_is_ready_at_world(group_id, goal_world):
			return false
	if not check_exit_wall_escapes:
		return true
	for raw_escape: Variant in _exit_wall_escapes.values():
		var escape: Dictionary = raw_escape as Dictionary
		var exit_group_id: int = int(escape.get("escape_group", -1))
		var exit_goal_world: Vector2 = escape.get("escape_world", Vector2.ZERO) as Vector2
		if exit_group_id > IDLE_GROUP and not group_flow_is_ready_at_world(exit_group_id, exit_goal_world):
			return false
	return true


func prewarm_spawner_entry_flows_for_kind(agent_kind: StringName, token: int) -> bool:
	if not bool(_manager.get("_flow_ready")) or _agent_manager() == null or _flow() == null:
		return true
	var flow: Node = _flow()
	if not flow.has_method("group_route_cost_at_world"):
		return false
	var requested_groups: Dictionary = {}
	var slice_started_us: int = Time.get_ticks_usec()
	var spawners: Dictionary = _spawners()
	var gardens: Dictionary = _gardens()
	var spawner_kind_by_cell: Dictionary = _spawner_kind_by_cell()
	for raw_spawner_cell: Variant in spawners.keys():
		if not _night_preparation_is_current(token):
			return false
		var spawner_cell: Vector2i = raw_spawner_cell as Vector2i
		if (spawner_kind_by_cell.get(spawner_cell, SPAWNER_KIND_MONSTER) as StringName) != agent_kind:
			continue
		for raw_garden_id: Variant in gardens.keys():
			if not _night_preparation_is_current(token):
				return false
			var garden_id: int = int(raw_garden_id)
			var garden: Dictionary = gardens[garden_id] as Dictionary
			if not bool(garden.get("targetable", false)):
				continue
			if not bool(_manager.call("_garden_has_target_for_kind", garden_id, agent_kind)):
				continue
			var route: Dictionary = get_or_create_spawner_garden_route(spawner_cell, garden_id)
			var group_id: int = int(route.get("plant_group", -1))
			if group_id > IDLE_GROUP:
				requested_groups[group_id] = true
			if Time.get_ticks_usec() - slice_started_us >= _night_preparation_budget_us():
				await _manager.get_tree().process_frame
				slice_started_us = Time.get_ticks_usec()
	if flow_uses_async_requests():
		while _night_preparation_is_current(token) and not bool(flow.call("are_async_flows_idle")):
			await _manager.get_tree().process_frame
	if not _night_preparation_is_current(token):
		return false
	for raw_group_id: Variant in requested_groups.keys():
		var group_id: int = int(raw_group_id)
		if not group_flow_id_is_ready(group_id):
			return false
	mark_spawner_entry_routes_ready_for_groups(requested_groups)
	return true


func mark_spawner_entry_routes_ready_for_groups(group_ids: Dictionary) -> void:
	for raw_spawner_cell: Variant in _spawner_garden_routes.keys():
		var spawner_cell: Vector2i = raw_spawner_cell as Vector2i
		var routes: Dictionary = _spawner_garden_routes[spawner_cell] as Dictionary
		for raw_garden_id: Variant in routes.keys():
			var garden_id: int = int(raw_garden_id)
			var route: Dictionary = routes[garden_id] as Dictionary
			var group_id: int = int(route.get("plant_group", -1))
			if group_ids.has(group_id) and garden_route_is_current(route, garden_id):
				route["ready"] = spawner_garden_route_flow_ready(route, spawner_cell)
				routes[garden_id] = route
		_spawner_garden_routes[spawner_cell] = routes


func rebuild_exit_wall_escapes_budgeted(token: int) -> bool:
	if not bool(_manager.get("_flow_ready")) or _agent_manager() == null or _flow() == null:
		return true
	var agent_manager: Node = _agent_manager()
	if not agent_manager.has_method("create_group"):
		return true
	_manager.call("_clear_garden_entry_resolve_cache", "night_prepare_exit_escapes")
	var current_exits: Dictionary = {}
	var wallz: TileMapLayer = _wallz()
	if wallz:
		for raw_cell: Variant in wallz.get_used_cells():
			var wall_cell: Vector2i = raw_cell as Vector2i
			if wallz.get_cell_atlas_coords(wall_cell) == EXIT_WALL_ATLAS:
				current_exits[wall_cell] = true
	for raw_exit_cell: Variant in _exit_wall_escapes.keys().duplicate():
		var old_exit_cell: Vector2i = raw_exit_cell as Vector2i
		if not current_exits.has(old_exit_cell):
			release_exit_wall_escape(old_exit_cell)

	var slice_started_us: int = Time.get_ticks_usec()
	for raw_exit_cell: Variant in current_exits.keys():
		if not _night_preparation_is_current(token):
			return false
		var exit_cell: Vector2i = raw_exit_cell as Vector2i
		var target_cell: Vector2i = _nearest_walkable_adjacent(exit_cell)
		if target_cell == INVALID_CELL:
			release_exit_wall_escape(exit_cell)
			continue
		var escape: Dictionary = _exit_wall_escapes.get(exit_cell, {}) as Dictionary
		var escape_group: int = int(escape.get("escape_group", -1))
		if escape_group <= IDLE_GROUP:
			escape_group = int(agent_manager.call("create_group"))
		if escape_group <= IDLE_GROUP:
			push_error("BuildingManager: could not allocate escape group for exit wall %s" % exit_cell)
			continue
		var escape_world: Vector2 = _cell_center(target_cell)
		if not _is_finite_world(escape_world):
			release_exit_wall_escape(exit_cell)
			continue
		request_group_flow_rebuild(escape_group, escape_world)
		escape["escape_group"] = escape_group
		escape["escape_target_cell"] = target_cell
		escape["escape_world"] = escape_world
		escape["ready"] = true
		_exit_wall_escapes[exit_cell] = escape
		if Time.get_ticks_usec() - slice_started_us >= _night_preparation_budget_us():
			await _manager.get_tree().process_frame
			slice_started_us = Time.get_ticks_usec()
	return true


func release_spawner_route(spawner_cell: Vector2i) -> void:
	var route: Dictionary = _spawner_routes.get(spawner_cell, {}) as Dictionary
	var escape_group: int = int(route.get("escape_group", -1))
	var agent_manager: Node = _agent_manager()
	if agent_manager and agent_manager.has_method("dissolve_group"):
		if escape_group > IDLE_GROUP:
			agent_manager.call("dissolve_group", escape_group)
		if _spawner_garden_routes.has(spawner_cell):
			var garden_routes: Dictionary = _spawner_garden_routes[spawner_cell] as Dictionary
			for raw_route: Variant in garden_routes.values():
				var garden_route: Dictionary = raw_route as Dictionary
				var plant_group: int = int(garden_route.get("plant_group", -1))
				if plant_group > IDLE_GROUP:
					agent_manager.call("dissolve_group", plant_group)
	_spawner_routes.erase(spawner_cell)
	_spawner_garden_routes.erase(spawner_cell)


func drain_dirty_routes() -> void:
	if not bool(_manager.get("_flow_ready")):
		return
	var agent_manager: Node = _agent_manager()
	var flow: Node = _flow()
	if not agent_manager or not agent_manager.has_method("create_group"):
		return
	if not flow or not flow.has_method("assign_flow_to_group"):
		return

	var escape_cells: Array = _dirty_spawner_escapes.keys()
	_dirty_spawner_escapes.clear()

	var spawners: Dictionary = _spawners()
	for raw_cell: Variant in escape_cells:
		if spawners.has(raw_cell):
			var spawner_cell: Vector2i = raw_cell as Vector2i
			rebuild_spawner_escape_ff(spawner_cell)


func initialize_spawner_route(spawner_cell: Vector2i) -> void:
	if not bool(_manager.get("_flow_ready")) or not bool(_manager.get("_plant_zone_built")):
		return
	var agent_manager: Node = _agent_manager()
	var flow: Node = _flow()
	if not agent_manager or not flow:
		return

	var route: Dictionary = _spawner_routes.get(spawner_cell, {}) as Dictionary
	var bound_exit_cell: Vector2i = _spawner_exit_cell_by_cell().get(spawner_cell, INVALID_CELL) as Vector2i
	var exit_wall_cell: Vector2i = bound_exit_cell
	if exit_wall_cell == INVALID_CELL:
		exit_wall_cell = _nearest_exit_wall_for_spawner(spawner_cell)
	route["exit_wall_cell"] = exit_wall_cell
	route["has_bound_exit"] = bound_exit_cell != INVALID_CELL

	var escape_wall_target_cell: Vector2i = INVALID_CELL
	if exit_wall_cell != INVALID_CELL:
		if bound_exit_cell != INVALID_CELL and _is_walkable(exit_wall_cell):
			escape_wall_target_cell = exit_wall_cell
		else:
			escape_wall_target_cell = _nearest_walkable_adjacent(exit_wall_cell)
	if escape_wall_target_cell == INVALID_CELL:
		escape_wall_target_cell = _resolve_walkable_goal(spawner_cell, "escape@%s" % spawner_cell)
	route["escape_wall_target_cell"] = escape_wall_target_cell

	if escape_wall_target_cell != INVALID_CELL:
		var escape_group: int = int(route.get("escape_group", -1))
		if escape_group <= IDLE_GROUP:
			escape_group = int(agent_manager.call("create_group"))
		if escape_group > IDLE_GROUP:
			var escape_world: Vector2 = _cell_center(escape_wall_target_cell)
			if not _is_finite_world(escape_world):
				push_warning("LOST-AGENT-GUARD: insane escape_world %s (cell %s) for spawner %s" % [
					escape_world, escape_wall_target_cell, spawner_cell
				])
				route["escape_ready"] = false
				_spawner_routes[spawner_cell] = route
				return
			request_group_flow_rebuild(escape_group, escape_world)
			route["escape_group"] = escape_group
			route["escape_world"] = escape_world
			route["escape_ready"] = true
		else:
			push_error("BuildingManager: spawner %s could not allocate escape group" % spawner_cell)
			route["escape_ready"] = false
	else:
		route["escape_ready"] = false

	_spawner_routes[spawner_cell] = route
	_debug_telemetry().log("initialized spawner=%s exit_wall=%s escape_target=%s" % [
		spawner_cell, exit_wall_cell, escape_wall_target_cell
	])


func rebuild_spawner_plant_ff(spawner_cell: Vector2i) -> void:
	if not _spawner_garden_routes.has(spawner_cell):
		return
	var garden_routes: Dictionary = _spawner_garden_routes[spawner_cell] as Dictionary
	for raw_garden_id: Variant in garden_routes.keys():
		var garden_id: int = int(raw_garden_id)
		var route: Dictionary = garden_routes[garden_id] as Dictionary
		var entry_cell: Vector2i = route.get("entry_cell", INVALID_CELL) as Vector2i
		if entry_cell == INVALID_CELL:
			continue
		var plant_group: int = int(route.get("plant_group", -1))
		if plant_group <= IDLE_GROUP:
			continue
		var entry_world: Vector2 = _cell_center(entry_cell)
		route["entry_world"] = entry_world
		route["ready"] = false
		route["flow_requested"] = true
		request_group_flow_rebuild(plant_group, entry_world)
		garden_routes[garden_id] = route
	_spawner_garden_routes[spawner_cell] = garden_routes


func rebuild_spawner_escape_ff(spawner_cell: Vector2i) -> void:
	var route: Dictionary = _spawner_routes.get(spawner_cell, {}) as Dictionary
	var target_cell: Vector2i = route.get("escape_wall_target_cell", INVALID_CELL) as Vector2i
	if target_cell == INVALID_CELL:
		return
	var escape_group: int = int(route.get("escape_group", -1))
	if escape_group <= IDLE_GROUP:
		return
	var escape_world: Vector2 = _cell_center(target_cell)
	request_group_flow_rebuild(escape_group, escape_world)
	route["escape_world"] = escape_world
	_spawner_routes[spawner_cell] = route


func rebuild_all_spawner_routes() -> void:
	if not bool(_manager.get("_flow_ready")) or not bool(_manager.get("_plant_zone_built")):
		return
	var spawners: Dictionary = _spawners()
	for raw_cell: Variant in spawners.keys():
		var spawner_cell: Vector2i = raw_cell as Vector2i
		initialize_spawner_route(spawner_cell)


func rebuild_exit_wall_escapes(use_async_requests: bool = false) -> void:
	if not bool(_manager.get("_flow_ready")):
		return
	var agent_manager: Node = _agent_manager()
	if not agent_manager or not agent_manager.has_method("create_group"):
		return
	_manager.call("_clear_garden_entry_resolve_cache", "rebuild_exit_escapes")
	var flow: Node = _flow()
	if not flow:
		return

	var current_exits: Dictionary = {}
	var wallz: TileMapLayer = _wallz()
	if wallz:
		for raw_cell: Variant in wallz.get_used_cells():
			var cell: Vector2i = raw_cell as Vector2i
			if wallz.get_cell_atlas_coords(cell) == EXIT_WALL_ATLAS:
				current_exits[cell] = true

	for raw_exit_cell: Variant in _exit_wall_escapes.keys():
		var exit_cell: Vector2i = raw_exit_cell as Vector2i
		if not current_exits.has(exit_cell):
			release_exit_wall_escape(exit_cell)

	for raw_exit_cell: Variant in current_exits.keys():
		var exit_cell: Vector2i = raw_exit_cell as Vector2i
		var target_cell: Vector2i = _nearest_walkable_adjacent(exit_cell)
		if target_cell == INVALID_CELL:
			release_exit_wall_escape(exit_cell)
			continue
		var escape: Dictionary = _exit_wall_escapes.get(exit_cell, {}) as Dictionary
		var escape_group: int = int(escape.get("escape_group", -1))
		if escape_group <= IDLE_GROUP:
			escape_group = int(agent_manager.call("create_group"))
		if escape_group <= IDLE_GROUP:
			push_error("BuildingManager: could not allocate escape group for exit wall %s" % exit_cell)
			continue
		var escape_world: Vector2 = _cell_center(target_cell)
		if not _is_finite_world(escape_world):
			push_warning("LOST-AGENT-GUARD: insane exit-wall escape_world %s (cell %s) for exit %s" % [
				escape_world, target_cell, exit_cell
			])
			release_exit_wall_escape(exit_cell)
			continue
		if use_async_requests and flow_uses_async_requests():
			request_group_flow_rebuild(escape_group, escape_world)
		elif flow.has_method("assign_flow_to_group"):
			flow.call("assign_flow_to_group", escape_group, escape_world, _fences_block_navigation())
		else:
			request_group_flow_rebuild(escape_group, escape_world)
		escape["escape_group"] = escape_group
		escape["escape_target_cell"] = target_cell
		escape["escape_world"] = escape_world
		escape["ready"] = true
		_exit_wall_escapes[exit_cell] = escape


func release_exit_wall_escape(exit_cell: Vector2i) -> void:
	if not _exit_wall_escapes.has(exit_cell):
		return
	var escape: Dictionary = _exit_wall_escapes[exit_cell] as Dictionary
	var escape_group: int = int(escape.get("escape_group", -1))
	var agent_manager: Node = _agent_manager()
	if escape_group > IDLE_GROUP and agent_manager and agent_manager.has_method("dissolve_group"):
		agent_manager.call("dissolve_group", escape_group)
	_exit_wall_escapes.erase(exit_cell)


func nearest_reachable_exit_escape(world_pos: Vector2) -> Dictionary:
	var flow: Node = _flow()
	if not flow or not flow.has_method("group_route_cost_at_world"):
		return {}
	var best: Dictionary = {}
	var best_cost: float = INF
	for raw_exit_cell: Variant in _exit_wall_escapes.keys():
		var escape: Dictionary = _exit_wall_escapes[raw_exit_cell] as Dictionary
		if not bool(escape.get("ready", false)):
			continue
		var escape_group: int = int(escape.get("escape_group", -1))
		if escape_group <= IDLE_GROUP:
			continue
		var cost: float = float(flow.call("group_route_cost_at_world", escape_group, world_pos))
		if cost < best_cost:
			best_cost = cost
			best = escape
	return best


func request_group_flow_rebuild(group_id: int, goal_world: Vector2) -> void:
	if not _is_finite_world(goal_world):
		push_warning("LOST-AGENT-GUARD: refused flow goal %s for group %d" % [goal_world, group_id])
		return
	var flow: Node = _flow()
	var block_fences: bool = _fences_block_navigation()
	if flow_uses_async_requests():
		flow.call("request_flow_to_group", group_id, goal_world, block_fences)
	elif flow_supports_sync_assign():
		flow.call("assign_flow_to_group", group_id, goal_world, block_fences)


func rebuild_spawner_garden_route_cache() -> void:
	_manager.call("_clear_garden_entry_resolve_cache", "rebuild_route_cache")
	for raw_spawner_cell: Variant in _spawner_garden_routes.keys().duplicate():
		var spawner_cell: Vector2i = raw_spawner_cell as Vector2i
		if not _spawner_garden_routes.has(spawner_cell):
			continue
		var routes: Dictionary = _spawner_garden_routes[spawner_cell] as Dictionary
		for raw_garden_id: Variant in routes.keys().duplicate():
			var garden_id: int = int(raw_garden_id)
			if not routes.has(garden_id):
				continue
			var route: Dictionary = routes[garden_id] as Dictionary
			if not garden_route_is_current(route, garden_id):
				release_spawner_garden_route(spawner_cell, garden_id)


func release_garden_routes(garden_id: int) -> void:
	for raw_spawner_cell: Variant in _spawner_garden_routes.keys().duplicate():
		var spawner_cell: Vector2i = raw_spawner_cell as Vector2i
		release_spawner_garden_route(spawner_cell, garden_id)


func release_spawner_garden_route(spawner_cell: Vector2i, garden_id: int) -> void:
	if not _spawner_garden_routes.has(spawner_cell):
		return
	var routes: Dictionary = _spawner_garden_routes[spawner_cell] as Dictionary
	if not routes.has(garden_id):
		return
	var route: Dictionary = routes[garden_id] as Dictionary
	var plant_group: int = int(route.get("plant_group", -1))
	var agent_manager: Node = _agent_manager()
	if plant_group > IDLE_GROUP and agent_manager and agent_manager.has_method("dissolve_group"):
		agent_manager.call("dissolve_group", plant_group)
	routes.erase(garden_id)
	if routes.is_empty():
		_spawner_garden_routes.erase(spawner_cell)
	else:
		_spawner_garden_routes[spawner_cell] = routes


func garden_route_is_current(route: Dictionary, garden_id: int) -> bool:
	var gardens: Dictionary = _gardens()
	if not gardens.has(garden_id):
		return false
	var garden: Dictionary = gardens[garden_id] as Dictionary
	if not bool(garden.get("reachable", false)):
		return false
	if int(route.get("garden_epoch", -1)) != int(garden.get("epoch", -2)):
		return false
	return int(route.get("garden_version", -1)) == int(garden.get("version", 0))


func spawner_garden_route_flow_ready(route: Dictionary, spawner_cell: Vector2i) -> bool:
	var plant_group: int = int(route.get("plant_group", -1))
	if plant_group <= IDLE_GROUP:
		return false
	return group_flow_is_ready_at_world(plant_group, _cell_center(spawner_cell))


func get_or_create_spawner_garden_route(spawner_cell: Vector2i, garden_id: int) -> Dictionary:
	if not _spawner_garden_routes.has(spawner_cell):
		_spawner_garden_routes[spawner_cell] = {}
	var routes: Dictionary = _spawner_garden_routes[spawner_cell] as Dictionary
	var existing_route: Dictionary = routes.get(garden_id, {}) as Dictionary
	if int(existing_route.get("plant_group", -1)) > IDLE_GROUP and garden_route_is_current(existing_route, garden_id):
		existing_route["ready"] = spawner_garden_route_flow_ready(existing_route, spawner_cell)
		routes[garden_id] = existing_route
		_spawner_garden_routes[spawner_cell] = routes
		_route_cache_hits += 1
		return existing_route
	_route_cache_misses += 1
	var gardens: Dictionary = _gardens()
	if not gardens.has(garden_id):
		return {"ready": false}
	var garden: Dictionary = gardens[garden_id] as Dictionary
	var entry_cell: Vector2i = _nearest_garden_entry(garden_id, spawner_cell)
	if entry_cell == INVALID_CELL:
		return {"ready": false}
	if not _is_sane_cell(entry_cell):
		push_warning("LOST-AGENT-GUARD: garden %d gave insane entry_cell %s for spawner %s; route refused" % [
			garden_id, entry_cell, spawner_cell
		])
		return {"ready": false}
	var entry_world: Vector2 = _cell_center(entry_cell)
	if not _is_finite_world(entry_world):
		push_warning("LOST-AGENT-GUARD: insane entry_world %s (cell %s) for spawner %s garden %d; route refused" % [
			entry_world, entry_cell, spawner_cell, garden_id
		])
		return {"ready": false}
	var agent_manager: Node = _agent_manager()
	if agent_manager == null or not agent_manager.has_method("create_group"):
		return {"ready": false}
	var plant_group: int = int(existing_route.get("plant_group", -1))
	if plant_group <= IDLE_GROUP:
		plant_group = int(agent_manager.call("create_group"))
	if plant_group <= IDLE_GROUP:
		return {"ready": false}
	request_group_flow_rebuild(plant_group, entry_world)
	var route: Dictionary = {
		"entry_cell": entry_cell,
		"entry_world": entry_world,
		"plant_group": plant_group,
		"ready": spawner_garden_route_flow_ready({"plant_group": plant_group}, spawner_cell),
		"flow_requested": true,
		"garden_version": int(garden.get("version", 0)),
		"garden_epoch": int(garden.get("epoch", -1))
	}
	routes[garden_id] = route
	_spawner_garden_routes[spawner_cell] = routes
	return route


func _spawner_is_one_of_kinds(spawner_cell: Vector2i, agent_kinds: Array[StringName]) -> bool:
	var spawner_kind: StringName = _spawner_kind_by_cell().get(spawner_cell, SPAWNER_KIND_MONSTER) as StringName
	return agent_kinds.has(spawner_kind)


func _night_preparation_is_current(token: int) -> bool:
	return bool(_manager.call("_night_preparation_is_current", token))


func _night_preparation_budget_us() -> int:
	return int(_manager.call("_night_preparation_budget_us"))


func _flow() -> Node:
	return _manager.get("flow") as Node


func _agent_manager() -> Node:
	return _manager.get("agent_manager") as Node


func _debug_telemetry() -> BuildingDebugTelemetry:
	return _manager.get("_debug_telemetry") as BuildingDebugTelemetry


func _spawners() -> Dictionary:
	return _manager.get("_spawners") as Dictionary


func _spawner_kind_by_cell() -> Dictionary:
	return _manager.get("_spawner_kind_by_cell") as Dictionary


func _spawner_exit_cell_by_cell() -> Dictionary:
	return _manager.get("_spawner_exit_cell_by_cell") as Dictionary


func _gardens() -> Dictionary:
	return _manager.get("_gardens") as Dictionary


func _wallz() -> TileMapLayer:
	return _manager.get("wallz") as TileMapLayer


func _nearest_exit_wall_for_spawner(spawner_cell: Vector2i) -> Vector2i:
	return _manager.call("_nearest_exit_wall_for_spawner", spawner_cell) as Vector2i


func _nearest_walkable_adjacent(cell: Vector2i) -> Vector2i:
	return _manager.call("_nearest_walkable_adjacent", cell) as Vector2i


func _resolve_walkable_goal(cell: Vector2i, purpose: String) -> Vector2i:
	return _manager.call("_resolve_walkable_goal", cell, purpose) as Vector2i


func _is_walkable(cell: Vector2i) -> bool:
	return bool(_manager.call("_is_walkable", cell))


func _cell_center(cell: Vector2i) -> Vector2:
	return _manager.call("_cell_center", cell) as Vector2


func _is_finite_world(world_pos: Vector2) -> bool:
	return bool(_manager.call("_is_finite_world", world_pos))


func _fences_block_navigation() -> bool:
	return bool(_manager.call("_fences_block_navigation"))


func _nearest_garden_entry(garden_id: int, spawner_cell: Vector2i) -> Vector2i:
	return _manager.call("_nearest_garden_entry", garden_id, spawner_cell) as Vector2i


func _is_sane_cell(cell: Vector2i) -> bool:
	return bool(_manager.call("_is_sane_cell", cell))
