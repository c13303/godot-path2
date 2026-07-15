extends RefCounted
class_name SpawnerGardenSelectionService

# Owns the "which garden should this spawner target / which spawner should serve this
# garden" selection scoring extracted from BuildingManager.
#
# Two distinct metrics live here, and they are not interchangeable:
#   * spawner-origin selection (select_garden_for_spawner, select_garden_for_client_spawner,
#     select_garden_entry_for_route) ranks gardens by the REAL approach route cost from
#     that spawner, via GardenAccessResolver. Manhattan distance from a spawner is
#     meaningless once a maze sits between the spawner and the garden.
#   * selection for an already-active agent (select_spawner_garden_for_agent,
#     select_spawner_for_garden_from_cell) still ranks by proximity to the agent's own
#     from_cell, which is a legitimate immediate-proximity metric for an agent that is
#     already standing somewhere. nearest_spawner_cell is unrelated geometry.
#
# Selection is separated from side effects: candidates are scored first, then an actual
# inbound garden route is created only for the winner (next candidate on failure), so
# merely deciding which garden wins never allocates and queues a flow group per garden.
#
# Behavior note: routes are usable once their flow GROUP exists — the field itself may
# still be queued/computing (spawned agents park as "ff wait" until it applies).
# Requiring route.ready here would filter every garden during the lazy window and
# misreport it as "no reachable garden". A spawner whose approach field is not ready
# yet reports PENDING, which the spawn path retries rather than treating as unreachable.

const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)
const IDLE_GROUP: int = 0
const SPAWNER_KIND_MONSTER: StringName = &"monster"
const SPAWNER_KIND_CLIENT: StringName = &"client"
const STATUS_READY: StringName = SpawnerRouteService.APPROACH_STATUS_READY
const STATUS_PENDING: StringName = SpawnerRouteService.APPROACH_STATUS_PENDING
const STATUS_UNAVAILABLE: StringName = SpawnerRouteService.APPROACH_STATUS_UNAVAILABLE

var _manager: BuildingManager
var _garden_topology: GardenTopologyService
var _garden_access_resolver: GardenAccessResolver
var _spawner_route_service: SpawnerRouteService


func setup(manager: BuildingManager) -> void:
	_manager = manager
	_garden_topology = manager.get_garden_topology_service()
	_garden_access_resolver = manager.get_garden_access_resolver()
	_spawner_route_service = manager.get_spawner_route_service()


# Compatibility wrappers: callers that only need the garden id. 0 means "no garden
# chosen", which deliberately cannot tell a pending approach field from a genuinely
# unreachable map — use the *_result variants when that difference matters.
func select_garden_for_spawner(spawner_cell: Vector2i) -> int:
	return int(select_garden_for_spawner_result(spawner_cell).get("garden_id", 0))


func select_garden_for_client_spawner(spawner_cell: Vector2i) -> int:
	return int(select_garden_for_client_spawner_result(spawner_cell).get("garden_id", 0))


# {"status": &"ready", "garden_id": int} | {"status": &"pending"|"unavailable", "garden_id": 0}
func select_garden_for_spawner_result(spawner_cell: Vector2i) -> Dictionary:
	return _select_garden_result(spawner_cell, SPAWNER_KIND_MONSTER, true)


func select_garden_for_client_spawner_result(spawner_cell: Vector2i) -> Dictionary:
	return _select_garden_result(spawner_cell, SPAWNER_KIND_CLIENT, false)


# Scores every eligible garden by the real approach cost from this spawner, then creates
# the inbound route only for the winner, walking down the ordered candidates if route
# creation genuinely fails. drain_empty mirrors the pre-existing per-kind difference:
# the monster path drains pending-empty gardens, the client path does not.
func _select_garden_result(spawner_cell: Vector2i, agent_kind: StringName, drain_empty: bool) -> Dictionary:
	var topology: GardenTopologyService = _garden_topology
	var candidates: Array[Dictionary] = []
	var pending: bool = false
	topology.begin_garden_iteration()
	var gardens: Dictionary = topology.gardens()
	for raw_garden_id: Variant in gardens.keys():
		var garden_id: int = int(raw_garden_id)
		var garden: Dictionary = gardens[garden_id] as Dictionary
		if not bool(garden.get("targetable", false)):
			continue
		if agent_kind == SPAWNER_KIND_CLIENT:
			if not topology.garden_has_target_for_kind(garden_id, SPAWNER_KIND_CLIENT):
				continue
		elif not topology.garden_has_edible_plants(garden_id):
			continue
		var resolved: Dictionary = _garden_access_resolver.resolve_garden_entry_from_spawner(garden_id, spawner_cell)
		var status: StringName = resolved.get("status", STATUS_UNAVAILABLE) as StringName
		if status == STATUS_PENDING:
			# All gardens share this spawner's one approach field: if it is not ready,
			# no garden can be scored and choosing among the rest would be a guess.
			pending = true
			break
		if status != STATUS_READY:
			continue
		candidates.append({
			"garden_id": garden_id,
			"approach_cost": float(resolved.get("approach_cost", INF)),
		})
	topology.end_garden_iteration()
	if drain_empty:
		topology.drain_pending_empty_gardens()
	if pending:
		return {"status": STATUS_PENDING, "garden_id": 0}

	_sort_garden_candidates(candidates)
	for candidate: Dictionary in candidates:
		var garden_id: int = int(candidate.get("garden_id", 0))
		# The winner may have just been drained as empty; try the next one.
		if not topology.gardens().has(garden_id):
			continue
		var route: Dictionary = _spawner_route_service.get_or_create_spawner_garden_route(spawner_cell, garden_id)
		if int(route.get("plant_group", -1)) <= IDLE_GROUP:
			continue
		return {"status": STATUS_READY, "garden_id": garden_id}
	return {"status": STATUS_UNAVAILABLE, "garden_id": 0}


# Route preparation (previews + the sale's own warm-up). Returns the ready result with
# the resolved entry, {"status": &"pending"} while this spawner's approach field is
# computing, or {} when no garden is reachable — the empty-dictionary contract existing
# callers already check.
func select_garden_entry_for_route(spawner_cell: Vector2i, agent_kind: StringName) -> Dictionary:
	var best: Dictionary = {}
	var best_cost: float = INF
	var pending: bool = false
	var topology: GardenTopologyService = _garden_topology
	topology.begin_garden_iteration()
	var gardens: Dictionary = topology.gardens()
	for raw_garden_id: Variant in gardens.keys():
		var garden_id: int = int(raw_garden_id)
		var garden: Dictionary = gardens[garden_id] as Dictionary
		# Monster routes may be prepared during afternoon, when targetability still
		# reflects daytime fence blocking. Use target presence + entry scoring; the
		# route service applies the explicit monster navigation policy.
		if agent_kind == SPAWNER_KIND_CLIENT and not bool(garden.get("targetable", false)):
			continue
		if not _garden_has_route_target(garden_id, agent_kind):
			continue
		var resolved: Dictionary = _garden_access_resolver.resolve_garden_entry_from_spawner(garden_id, spawner_cell)
		var status: StringName = resolved.get("status", STATUS_UNAVAILABLE) as StringName
		if status == STATUS_PENDING:
			pending = true
			break
		if status != STATUS_READY:
			continue
		var cost: float = float(resolved.get("approach_cost", INF))
		if cost < best_cost or (cost == best_cost and garden_id < int(best.get("garden_id", 2147483647))):
			best_cost = cost
			best = {
				"status": STATUS_READY,
				"garden_id": garden_id,
				"entry_cell": resolved.get("entry_cell", INVALID_CELL) as Vector2i,
				"approach_cost": cost,
			}
	topology.end_garden_iteration()
	if pending:
		return {"status": STATUS_PENDING}
	if not best.is_empty() and not topology.gardens().has(int(best.get("garden_id", 0))):
		return {}
	return best


# Lowest real approach cost first, garden id as the deterministic tie-breaker.
func _sort_garden_candidates(candidates: Array[Dictionary]) -> void:
	candidates.sort_custom(Callable(self, "_garden_candidate_less_than"))


func _garden_candidate_less_than(a: Dictionary, b: Dictionary) -> bool:
	var cost_a: float = float(a.get("approach_cost", INF))
	var cost_b: float = float(b.get("approach_cost", INF))
	if not is_equal_approx(cost_a, cost_b):
		return cost_a < cost_b
	return int(a.get("garden_id", 0)) < int(b.get("garden_id", 0))


func _garden_has_route_target(garden_id: int, agent_kind: StringName) -> bool:
	var gardens: Dictionary = _garden_topology.gardens()
	if not gardens.has(garden_id):
		return false
	var garden: Dictionary = gardens[garden_id] as Dictionary
	var plant_cells: Dictionary = garden.get("plant_cells", {}) as Dictionary
	if plant_cells.is_empty():
		return false
	for raw_cell: Variant in plant_cells.keys():
		var cell: Vector2i = raw_cell as Vector2i
		if agent_kind == SPAWNER_KIND_CLIENT:
			if _garden_topology.is_client_target_cell(cell):
				return true
		elif _garden_topology.is_eatable_for_monster(cell):
			return true
	return false


# Picks a (spawner, garden) pair for an agent already standing at from_cell, ranked by
# that agent's own proximity to the candidate entry — its current position is the
# meaningful metric here, not the origin spawner's. The entry itself is now route-aware
# (nearest_garden_entry resolves it from the spawner's approach field).
#
# Returns the pair, {} when nothing is reachable, or {"status": &"pending"} when no pair
# was found but at least one spawner's approach field is still computing. Callers must
# not read that last case as failure: escaping an agent over a few frames of flow-field
# wait would throw it off the map for no reason.
func select_spawner_garden_for_agent(from_cell: Vector2i, agent_kind: StringName = SPAWNER_KIND_MONSTER) -> Dictionary:
	var topology: GardenTopologyService = _garden_topology
	var access_resolver: GardenAccessResolver = _garden_access_resolver
	var route_service: SpawnerRouteService = _spawner_route_service
	var spawners: Dictionary = _spawners()
	var spawner_kind_by_cell: Dictionary = _spawner_kind_by_cell()
	var candidates: Array[Dictionary] = []
	var pending: bool = false
	# Reset the per-resolve cache tallies; each nearest_garden_entry below adds in.
	access_resolver.reset_resolve_counters()
	topology.begin_garden_iteration()
	var gardens: Dictionary = topology.gardens()
	for raw_spawner_cell: Variant in spawners.keys():
		var spawner_cell: Vector2i = raw_spawner_cell as Vector2i
		if (spawner_kind_by_cell.get(spawner_cell, SPAWNER_KIND_MONSTER) as StringName) != agent_kind:
			continue
		if not route_service.has_spawner_route(spawner_cell):
			continue
		if route_service.spawner_approach_status(spawner_cell) == STATUS_PENDING:
			# No entry of any garden can be resolved from this spawner yet, and a
			# geometric guess is exactly the bug this change removes.
			pending = true
			continue
		for raw_garden_id: Variant in gardens.keys():
			var garden_id: int = int(raw_garden_id)
			var garden: Dictionary = gardens[garden_id] as Dictionary
			if not bool(garden.get("targetable", false)):
				continue
			if not topology.garden_has_target_for_kind(garden_id, agent_kind):
				continue
			var entry_cell: Vector2i = access_resolver.nearest_garden_entry(garden_id, spawner_cell)
			access_resolver.record_resolve_result()
			if entry_cell == INVALID_CELL:
				continue
			candidates.append({
				"spawner_cell": spawner_cell,
				"garden_id": garden_id,
				"distance": _manhattan(entry_cell, from_cell),
			})
	topology.end_garden_iteration()
	topology.drain_pending_empty_gardens()
	_sort_pair_candidates(candidates)
	for candidate: Dictionary in candidates:
		var garden_id: int = int(candidate.get("garden_id", 0))
		# The winner may have just been drained as empty; try the next one.
		if not topology.gardens().has(garden_id):
			continue
		var spawner_cell: Vector2i = candidate.get("spawner_cell", INVALID_CELL) as Vector2i
		var route: Dictionary = route_service.get_or_create_spawner_garden_route(spawner_cell, garden_id)
		if int(route.get("plant_group", -1)) <= IDLE_GROUP:
			continue
		return {
			"spawner_cell": spawner_cell,
			"garden_id": garden_id,
		}
	if pending:
		return {"status": STATUS_PENDING}
	return {}


# Same contract for a fixed garden: which spawner's route should serve an agent already
# at from_cell. Ranked by that agent's proximity to the entry each spawner resolves to.
func select_spawner_for_garden_from_cell(garden_id: int, from_cell: Vector2i, fallback_spawner_cell: Vector2i, agent_kind: StringName = SPAWNER_KIND_MONSTER) -> Vector2i:
	var route_service: SpawnerRouteService = _spawner_route_service
	var spawners: Dictionary = _spawners()
	var spawner_kind_by_cell: Dictionary = _spawner_kind_by_cell()
	var candidates: Array[Dictionary] = []
	for raw_spawner_cell: Variant in spawners.keys():
		var spawner_cell: Vector2i = raw_spawner_cell as Vector2i
		if (spawner_kind_by_cell.get(spawner_cell, SPAWNER_KIND_MONSTER) as StringName) != agent_kind:
			continue
		if not route_service.has_spawner_route(spawner_cell):
			continue
		var entry_cell: Vector2i = _garden_access_resolver.nearest_garden_entry(garden_id, spawner_cell)
		if entry_cell == INVALID_CELL:
			continue
		candidates.append({
			"spawner_cell": spawner_cell,
			"garden_id": garden_id,
			"distance": _manhattan(entry_cell, from_cell),
		})
	_sort_pair_candidates(candidates)
	for candidate: Dictionary in candidates:
		var spawner_cell: Vector2i = candidate.get("spawner_cell", INVALID_CELL) as Vector2i
		var route: Dictionary = route_service.get_or_create_spawner_garden_route(spawner_cell, garden_id)
		if int(route.get("plant_group", -1)) > IDLE_GROUP:
			return spawner_cell
	if fallback_spawner_cell != INVALID_CELL and route_service.has_spawner_route(fallback_spawner_cell):
		if (spawner_kind_by_cell.get(fallback_spawner_cell, SPAWNER_KIND_MONSTER) as StringName) != agent_kind:
			return INVALID_CELL
		var fallback_route: Dictionary = route_service.get_or_create_spawner_garden_route(fallback_spawner_cell, garden_id)
		if _garden_access_resolver.nearest_garden_entry(garden_id, fallback_spawner_cell) != INVALID_CELL and int(fallback_route.get("plant_group", -1)) > IDLE_GROUP:
			return fallback_spawner_cell
	return INVALID_CELL


# Nearest entry to the agent first, then a stable spawner/garden order so two equally
# close candidates always resolve the same way.
func _sort_pair_candidates(candidates: Array[Dictionary]) -> void:
	candidates.sort_custom(Callable(self, "_pair_candidate_less_than"))


func _pair_candidate_less_than(a: Dictionary, b: Dictionary) -> bool:
	var dist_a: int = int(a.get("distance", 2147483647))
	var dist_b: int = int(b.get("distance", 2147483647))
	if dist_a != dist_b:
		return dist_a < dist_b
	var cell_a: Vector2i = a.get("spawner_cell", INVALID_CELL) as Vector2i
	var cell_b: Vector2i = b.get("spawner_cell", INVALID_CELL) as Vector2i
	if cell_a.y != cell_b.y:
		return cell_a.y < cell_b.y
	if cell_a.x != cell_b.x:
		return cell_a.x < cell_b.x
	return int(a.get("garden_id", 0)) < int(b.get("garden_id", 0))


func _manhattan(a: Vector2i, b: Vector2i) -> int:
	var delta: Vector2i = a - b
	return abs(delta.x) + abs(delta.y)


func nearest_spawner_cell(from_cell: Vector2i) -> Vector2i:
	var best_cell: Vector2i = INVALID_CELL
	var best_dist_sq: int = 2147483647
	var spawners: Dictionary = _spawners()
	var spawner_kind_by_cell: Dictionary = _spawner_kind_by_cell()
	for raw_spawner_cell in spawners.keys():
		var spawner_cell: Vector2i = raw_spawner_cell
		if (spawner_kind_by_cell.get(spawner_cell, SPAWNER_KIND_MONSTER) as StringName) != SPAWNER_KIND_MONSTER:
			continue
		var delta: Vector2i = spawner_cell - from_cell
		var dist_sq: int = delta.x * delta.x + delta.y * delta.y
		if dist_sq < best_dist_sq:
			best_dist_sq = dist_sq
			best_cell = spawner_cell
	return best_cell


func _spawners() -> Dictionary:
	return _manager.get_spawners()


func _spawner_kind_by_cell() -> Dictionary:
	return _manager.spawner_kind_by_cell()
