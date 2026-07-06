extends RefCounted
class_name SpawnerGardenSelectionService

# Owns the "which garden should this spawner target / which spawner should serve this
# garden" selection scoring extracted from BuildingManager. These are pure read-only
# queries: they iterate gardens/spawners, score reachable+ready routes by Manhattan
# distance, and return the best garden id / spawner cell / (spawner, garden) pair.
# They perform no placement, spawning, or navigation side effects of their own — only
# the same route-cache warming (_get_or_create_spawner_garden_route) and pending-empty
# draining (_drain_pending_empty_gardens) the inline code already did.
#
# Behavior note: this is an extraction only. The iteration order, the targetable /
# edible / target-for-kind gating, the route-ready checks, the distance scoring, the
# empty-garden draining, and the stale-garden fall-through are preserved exactly as
# they were inline in BuildingManager. BuildingManager keeps thin compatibility
# wrappers so existing callers (including _manager.call(...) from other controllers)
# continue to work unchanged.

const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)
const SPAWNER_KIND_MONSTER: StringName = &"monster"
const SPAWNER_KIND_CLIENT: StringName = &"client"

var _manager: Node


func setup(manager: Node) -> void:
	_manager = manager


func select_garden_for_spawner(spawner_cell: Vector2i) -> int:
	var best_garden_id: int = 0
	var best_dist: int = 2147483647
	var topology: Object = _garden_topology()
	topology.call("begin_garden_iteration")
	var gardens: Dictionary = topology.call("gardens") as Dictionary
	for raw_garden_id in gardens.keys():
		var garden_id: int = int(raw_garden_id)
		var garden: Dictionary = gardens[garden_id] as Dictionary
		if not bool(garden.get("targetable", false)):
			continue
		if not bool(_manager.call("_garden_has_edible_plants", garden_id)):
			continue
		var entry_cell: Vector2i = _manager.call("_nearest_garden_entry", garden_id, spawner_cell) as Vector2i
		if entry_cell == INVALID_CELL:
			continue
		var route: Dictionary = _manager.call("_get_or_create_spawner_garden_route", spawner_cell, garden_id) as Dictionary
		if not bool(route.get("ready", false)):
			continue
		var delta: Vector2i = entry_cell - spawner_cell
		var manhattan: int = abs(delta.x) + abs(delta.y)
		if manhattan < best_dist:
			best_dist = manhattan
			best_garden_id = garden_id
	topology.call("end_garden_iteration")
	_manager.call("_drain_pending_empty_gardens")
	# The chosen garden may have just been drained as empty; fall through to 0.
	if best_garden_id > 0 and not (topology.call("gardens") as Dictionary).has(best_garden_id):
		return 0
	return best_garden_id


func select_garden_for_client_spawner(spawner_cell: Vector2i) -> int:
	var best_garden_id: int = 0
	var best_dist: int = 2147483647
	var topology: Object = _garden_topology()
	topology.call("begin_garden_iteration")
	var gardens: Dictionary = topology.call("gardens") as Dictionary
	for raw_garden_id: Variant in gardens.keys():
		var garden_id: int = int(raw_garden_id)
		var garden: Dictionary = gardens[garden_id] as Dictionary
		if not bool(garden.get("targetable", false)):
			continue
		if not bool(_manager.call("_garden_has_target_for_kind", garden_id, SPAWNER_KIND_CLIENT)):
			continue
		var entry_cell: Vector2i = _manager.call("_nearest_garden_entry", garden_id, spawner_cell) as Vector2i
		if entry_cell == INVALID_CELL:
			continue
		var route: Dictionary = _manager.call("_get_or_create_spawner_garden_route", spawner_cell, garden_id) as Dictionary
		if not bool(route.get("ready", false)):
			continue
		var delta: Vector2i = entry_cell - spawner_cell
		var manhattan: int = abs(delta.x) + abs(delta.y)
		if manhattan < best_dist:
			best_dist = manhattan
			best_garden_id = garden_id
	topology.call("end_garden_iteration")
	if best_garden_id > 0 and not (topology.call("gardens") as Dictionary).has(best_garden_id):
		return 0
	return best_garden_id


func select_spawner_garden_for_agent(from_cell: Vector2i, agent_kind: StringName = SPAWNER_KIND_MONSTER) -> Dictionary:
	var best_pair: Dictionary = {}
	var best_dist: int = 2147483647
	var topology: Object = _garden_topology()
	var access_resolver: Object = _garden_access_resolver()
	var route_service: Object = _spawner_route_service()
	var spawners: Dictionary = _spawners()
	var spawner_kind_by_cell: Dictionary = _spawner_kind_by_cell()
	# Reset the per-resolve cache tallies; each _nearest_garden_entry below adds in.
	access_resolver.call("reset_resolve_counters")
	topology.call("begin_garden_iteration")
	var gardens: Dictionary = topology.call("gardens") as Dictionary
	for raw_spawner_cell in spawners.keys():
		var spawner_cell: Vector2i = raw_spawner_cell
		if (spawner_kind_by_cell.get(spawner_cell, SPAWNER_KIND_MONSTER) as StringName) != agent_kind:
			continue
		if not bool(route_service.call("has_spawner_route", spawner_cell)):
			continue
		for raw_garden_id in gardens.keys():
			var garden_id: int = int(raw_garden_id)
			var garden: Dictionary = gardens[garden_id] as Dictionary
			if not bool(garden.get("targetable", false)):
				continue
			if not bool(_manager.call("_garden_has_target_for_kind", garden_id, agent_kind)):
				continue
			var entry_cell: Vector2i = _manager.call("_nearest_garden_entry", garden_id, spawner_cell) as Vector2i
			access_resolver.call("record_resolve_result")
			if entry_cell == INVALID_CELL:
				continue
			var route: Dictionary = _manager.call("_get_or_create_spawner_garden_route", spawner_cell, garden_id) as Dictionary
			if not bool(route.get("ready", false)):
				continue
			var delta: Vector2i = entry_cell - from_cell
			var manhattan: int = abs(delta.x) + abs(delta.y)
			if manhattan < best_dist:
				best_dist = manhattan
				best_pair = {
					"spawner_cell": spawner_cell,
					"garden_id": garden_id
				}
	topology.call("end_garden_iteration")
	_manager.call("_drain_pending_empty_gardens")
	# The chosen garden may have just been drained as empty; drop the stale pair.
	if not best_pair.is_empty() and not (topology.call("gardens") as Dictionary).has(int(best_pair.get("garden_id", 0))):
		return {}
	return best_pair


func select_spawner_for_garden_from_cell(garden_id: int, from_cell: Vector2i, fallback_spawner_cell: Vector2i, agent_kind: StringName = SPAWNER_KIND_MONSTER) -> Vector2i:
	var best_spawner_cell: Vector2i = INVALID_CELL
	var best_dist: int = 2147483647
	var route_service: Object = _spawner_route_service()
	var spawners: Dictionary = _spawners()
	var spawner_kind_by_cell: Dictionary = _spawner_kind_by_cell()
	for raw_spawner_cell in spawners.keys():
		var spawner_cell: Vector2i = raw_spawner_cell
		if (spawner_kind_by_cell.get(spawner_cell, SPAWNER_KIND_MONSTER) as StringName) != agent_kind:
			continue
		if not bool(route_service.call("has_spawner_route", spawner_cell)):
			continue
		var entry_cell: Vector2i = _manager.call("_nearest_garden_entry", garden_id, spawner_cell) as Vector2i
		if entry_cell == INVALID_CELL:
			continue
		var route: Dictionary = _manager.call("_get_or_create_spawner_garden_route", spawner_cell, garden_id) as Dictionary
		if not bool(route.get("ready", false)):
			continue
		var delta: Vector2i = entry_cell - from_cell
		var manhattan: int = abs(delta.x) + abs(delta.y)
		if manhattan < best_dist:
			best_dist = manhattan
			best_spawner_cell = spawner_cell
	if best_spawner_cell == INVALID_CELL and fallback_spawner_cell != INVALID_CELL and bool(route_service.call("has_spawner_route", fallback_spawner_cell)):
		if (spawner_kind_by_cell.get(fallback_spawner_cell, SPAWNER_KIND_MONSTER) as StringName) != agent_kind:
			return INVALID_CELL
		var fallback_route: Dictionary = _manager.call("_get_or_create_spawner_garden_route", fallback_spawner_cell, garden_id) as Dictionary
		if (_manager.call("_nearest_garden_entry", garden_id, fallback_spawner_cell) as Vector2i) != INVALID_CELL and bool(fallback_route.get("ready", false)):
			best_spawner_cell = fallback_spawner_cell
	return best_spawner_cell


func _garden_topology() -> Object:
	return _manager.get("_garden_topology") as Object


func _garden_access_resolver() -> Object:
	return _manager.get("_garden_access_resolver") as Object


func _spawner_route_service() -> Object:
	return _manager.get("_spawner_route_service") as Object


func _spawners() -> Dictionary:
	return _manager.get("_spawners") as Dictionary


func _spawner_kind_by_cell() -> Dictionary:
	return _manager.get("_spawner_kind_by_cell") as Dictionary
