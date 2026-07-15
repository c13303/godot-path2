extends RefCounted
class_name GardenAccessResolver

# Owns garden access-cell scoring, garden-entry selection, and the memoized
# entry-resolve cache. BuildingManager keeps the garden topology / walkability
# source-of-truth state and low-level queries, reached through the callbacks at
# the bottom of this file.
#
# Two selection paths, deliberately different:
#   * inbound (resolve_garden_entry_from_spawner) ranks entrances by the real route
#     cost read from the spawner's approach field in SpawnerRouteService, so a maze
#     between spawner and garden is understood. Local geometry only breaks ties.
#   * outbound (nearest_garden_entry_to_exit) still scores against the escape flow
#     through _select_scored_garden_entry, unchanged.

const IDLE_GROUP: int = 0
const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)
# Two approach costs within this margin count as tied, so the local entrance-quality
# penalty below decides between them. Kept tiny on purpose: route cost is the primary
# decision and a locally prettier entrance must never win a substantially longer route.
const APPROACH_COST_TIE_EPSILON: float = 0.001

# Garden access-cell scoring penalties. Distance / escape cost stays the main
# driver; these only nudge selection away from obviously bad local geometry (a
# wall-pocket exit that forces an immediate reversal, a dead-ended outside tile).
# They are deliberately conservative and additive: a valid access cell is never
# rejected outright for being near walls, only ranked slightly lower when its
# continuation geometry is also poor. Tune as needed.
const ACCESS_NO_OUTSIDE_PENALTY: float = 1000.0
const ACCESS_EXIT_WORSE_PENALTY: float = 100.0
const ACCESS_EXIT_FLAT_PENALTY: float = 10.0
const ACCESS_DEAD_CONTINUATION_PENALTY: float = 100.0
const ACCESS_NARROW_CONTINUATION_PENALTY: float = 20.0
const ACCESS_REVERSAL_PENALTY: float = 100.0
const ACCESS_TURN_PENALTY: float = 5.0
const ACCESS_BLOCKED_CARDINAL_PENALTY: float = 2.0
# Enter mode uses softer continuation penalties (the agent is heading inward, so
# outside continuation matters less than for exits).
const ACCESS_ENTER_DEAD_CONTINUATION_PENALTY: float = 30.0
const ACCESS_ENTER_NARROW_CONTINUATION_PENALTY: float = 10.0

var _manager: BuildingManager

# Memoizes the scored garden-entry selection (resolve_garden_entry_from_spawner).
# The chosen entry depends only on (garden_id, spawner cell) for a given approach
# generation: scoring samples the spawner's approach field at every entry's outside
# neighbours, and the retarget path asks once per (spawner, garden) pair for every
# agent, so many agents targeting the same routes would recompute identical results.
# Keyed by "spawner|garden" so different spawners never share a (possibly far/bad)
# entry — the result is source-dependent, never cached by garden_id alone.
#
# Value: the structured resolve result, always carrying the approach_generation it was
# computed under. The rules that keep it honest:
#   * a PENDING result is never stored — a guess must never outlive the wait;
#   * an entry resolved under an older approach generation is never reused;
#   * a genuine "unreachable" is only trusted for the generation that produced it.
# Invalidated wholesale on any topology/wall/entry rebuild (see clear_cache call
# sites); plain plant eating that leaves the garden connected with the same entries
# does NOT touch it.
var _garden_entry_resolve_cache: Dictionary = {}  # "spawner|garden" -> result Dictionary
# Retarget breakdown debug counters (read into the consolidated profile line).
# Per-call flag set by nearest_garden_entry; per-resolve tallies accumulated by
# BuildingManager._select_spawner_garden_for_agent (which calls nearest_garden_entry
# many times and records each outcome).
var _garden_entry_resolve_cache_hit: bool = false
var _garden_entry_resolve_hits: int = 0
var _garden_entry_resolve_misses: int = 0


func setup(manager: BuildingManager) -> void:
	_manager = manager


# ---------------------------------------------------------------------------
# Public API.
# ---------------------------------------------------------------------------

# Inbound entry selection for one (garden, spawner) pair, decided by the real
# navigable route cost from that spawner's approach field. Returns one of:
#   {"status": &"ready",       "entry_cell": Vector2i, "approach_cost": float}
#   {"status": &"pending",     "entry_cell": INVALID_CELL, "approach_cost": INF}
#   {"status": &"unavailable", "entry_cell": INVALID_CELL, "approach_cost": INF}
# PENDING is transient (the approach field is queued/computing) and the caller must
# retry; UNAVAILABLE means no entrance of this garden is reachable from this spawner.
func resolve_garden_entry_from_spawner(garden_id: int, spawner_cell: Vector2i) -> Dictionary:
	var route_service: SpawnerRouteService = _spawner_route_service()
	var generation: int = route_service.spawner_approach_generation()
	var cache_key: String = _garden_entry_resolve_cache_key(garden_id, spawner_cell)
	var cached: Dictionary = _garden_entry_resolve_cache.get(cache_key, {}) as Dictionary
	if not cached.is_empty():
		if int(cached.get("approach_generation", -1)) == generation and _cached_result_still_valid(garden_id, cached):
			_garden_entry_resolve_cache_hit = true
			return cached.duplicate()
		# Stale (older approach generation, garden gone, entry no longer listed, or no
		# longer walkable): drop it and fall through to recompute.
		_garden_entry_resolve_cache.erase(cache_key)
	_garden_entry_resolve_cache_hit = false
	var result: Dictionary = _resolve_entry_from_approach_cost(garden_id, spawner_cell, route_service)
	if (result.get("status", SpawnerRouteService.APPROACH_STATUS_UNAVAILABLE) as StringName) == SpawnerRouteService.APPROACH_STATUS_PENDING:
		# Never cached: the field is still computing and any answer now would be a guess.
		return result
	result["approach_generation"] = generation
	_garden_entry_resolve_cache[cache_key] = result
	return result.duplicate()


# Compatibility wrapper for the callers that only need the entry cell (route creation,
# retarget meta, spawner-side proximity selection). Returns INVALID_CELL while the
# approach field is pending, so callers that must tell "wait" from "unreachable" have
# to use resolve_garden_entry_from_spawner() instead.
func nearest_garden_entry(garden_id: int, from_cell: Vector2i) -> Vector2i:
	var result: Dictionary = resolve_garden_entry_from_spawner(garden_id, from_cell)
	if (result.get("status", SpawnerRouteService.APPROACH_STATUS_UNAVAILABLE) as StringName) != SpawnerRouteService.APPROACH_STATUS_READY:
		return INVALID_CELL
	return result.get("entry_cell", INVALID_CELL) as Vector2i


# A cached READY entry must still be a walkable entry of that garden. UNAVAILABLE
# results carry no cell, so for the generation that produced them they stay valid.
func _cached_result_still_valid(garden_id: int, cached: Dictionary) -> bool:
	if (cached.get("status", SpawnerRouteService.APPROACH_STATUS_UNAVAILABLE) as StringName) != SpawnerRouteService.APPROACH_STATUS_READY:
		return true
	var gardens: Dictionary = _gardens()
	if not gardens.has(garden_id):
		return false
	var garden: Dictionary = gardens[garden_id] as Dictionary
	var entry_cells: Array = garden.get("entry_cells", []) as Array
	var entry_cell: Vector2i = cached.get("entry_cell", INVALID_CELL) as Vector2i
	return entry_cells.has(entry_cell) and _is_walkable(entry_cell)


# Scores every entry of the garden against the one approach field of this spawner.
# Lexicographic: real route cost first, then the local entrance-quality penalty, then
# the old Manhattan distance, then stable coordinate order.
func _resolve_entry_from_approach_cost(
	garden_id: int,
	spawner_cell: Vector2i,
	route_service: SpawnerRouteService
) -> Dictionary:
	var approach_status: StringName = route_service.spawner_approach_status(spawner_cell)
	if approach_status != SpawnerRouteService.APPROACH_STATUS_READY:
		# Either still computing (retry) or this spawner has no approach anchor at all.
		return _entry_result(approach_status, INVALID_CELL, INF)
	var gardens: Dictionary = _gardens()
	if not gardens.has(garden_id):
		return _entry_result(SpawnerRouteService.APPROACH_STATUS_UNAVAILABLE, INVALID_CELL, INF)
	var garden: Dictionary = gardens[garden_id] as Dictionary
	var entry_cells: Array = garden.get("entry_cells", []) as Array

	var best_cell: Vector2i = INVALID_CELL
	var best_cost: float = INF
	var best_penalty: float = INF
	var best_tiebreak: int = 2147483647
	for raw_cell: Variant in entry_cells:
		var cell: Vector2i = raw_cell as Vector2i
		if not _is_walkable(cell):
			continue
		# The route arrives at the outside neighbour, not at the interior entry cell:
		# sampling the interior tile would read a cost that already crossed the door.
		var outside_neighbors: Array[Vector2i] = _garden_access_outside_neighbors(garden, cell)
		if outside_neighbors.is_empty():
			continue
		var cell_cost: float = INF
		var cell_outside: Vector2i = INVALID_CELL
		for neighbor: Vector2i in outside_neighbors:
			var sample: Dictionary = route_service.spawner_approach_cost_at_cell(spawner_cell, neighbor)
			if (sample.get("status", SpawnerRouteService.APPROACH_STATUS_UNAVAILABLE) as StringName) != SpawnerRouteService.APPROACH_STATUS_READY:
				continue
			var cost: float = float(sample.get("cost", INF))
			if cost < cell_cost:
				cell_cost = cost
				cell_outside = neighbor
		if not is_finite(cell_cost) or cell_outside == INVALID_CELL:
			# No outside neighbour of this entrance is on any route from the spawner.
			continue
		var penalty: float = _enter_local_penalty(cell, cell_outside)
		var tiebreak: int = _manhattan_cell(cell, spawner_cell)
		if _entry_is_better(cell, cell_cost, penalty, tiebreak, best_cell, best_cost, best_penalty, best_tiebreak):
			best_cell = cell
			best_cost = cell_cost
			best_penalty = penalty
			best_tiebreak = tiebreak

	if best_cell == INVALID_CELL:
		return _entry_result(SpawnerRouteService.APPROACH_STATUS_UNAVAILABLE, INVALID_CELL, INF)
	if _debug_logs() and CppDebugOptions.logs_enabled:
		print("BuildingManager: garden %d enter access %s approach_cost=%.1f penalty=%.1f spawner=%s" % [
			garden_id, str(best_cell), best_cost, best_penalty, str(spawner_cell)
		])
	return _entry_result(SpawnerRouteService.APPROACH_STATUS_READY, best_cell, best_cost)


func _entry_result(status: StringName, entry_cell: Vector2i, approach_cost: float) -> Dictionary:
	return {
		"status": status,
		"entry_cell": entry_cell,
		"approach_cost": approach_cost,
	}


# Lexicographic comparison. Costs closer than APPROACH_COST_TIE_EPSILON are treated as
# equal so the secondary keys can break genuine ties (symmetric geometry) without ever
# letting them override a real route-cost difference.
func _entry_is_better(
	cell: Vector2i, cost: float, penalty: float, tiebreak: int,
	best_cell: Vector2i, best_cost: float, best_penalty: float, best_tiebreak: int
) -> bool:
	if best_cell == INVALID_CELL:
		return true
	if not is_equal_approx(cost, best_cost) and absf(cost - best_cost) > APPROACH_COST_TIE_EPSILON:
		return cost < best_cost
	if not is_equal_approx(penalty, best_penalty):
		return penalty < best_penalty
	if tiebreak != best_tiebreak:
		return tiebreak < best_tiebreak
	if cell.y != best_cell.y:
		return cell.y < best_cell.y
	return cell.x < best_cell.x


func nearest_garden_entry_to_exit(garden_id: int, spawner_cell: Vector2i) -> Vector2i:
	var exit_wall_cell: Vector2i = INVALID_CELL
	var spawner_route: Dictionary = _spawner_route_service().get_spawner_route(spawner_cell)
	exit_wall_cell = spawner_route.get("exit_wall_cell", INVALID_CELL) as Vector2i
	var escape_group: int = int(spawner_route.get("escape_group", -1))
	if exit_wall_cell == INVALID_CELL:
		return _select_scored_garden_entry(garden_id, spawner_cell, "exit", INVALID_CELL, escape_group)
	return _select_scored_garden_entry(garden_id, exit_wall_cell, "exit", INVALID_CELL, escape_group)


# Clears the memoized garden-entry resolution. Called from every rebuild path
# that can change garden topology, entries, walls, or routes. Cheap (a dict
# clear); the optional reason is only for tracing if we ever log it.
func clear_cache(_reason: String = "") -> void:
	_garden_entry_resolve_cache.clear()


# Drops every cached entry resolved from one source cell. Used when a spawner route is
# released, so a spawner re-added on the same tile cannot inherit entries chosen by the
# approach field that was just dissolved.
func clear_cache_for_source(from_cell: Vector2i) -> void:
	var prefix: String = "%s|" % str(from_cell)
	for raw_key: Variant in _garden_entry_resolve_cache.keys():
		var key: String = String(raw_key)
		if key.begins_with(prefix):
			_garden_entry_resolve_cache.erase(key)


# True if the most recent nearest_garden_entry served a cache hit. Read
# immediately after that call, before any intervening resolve overwrites it.
func cache_hit() -> bool:
	return _garden_entry_resolve_cache_hit


func reset_resolve_counters() -> void:
	_garden_entry_resolve_hits = 0
	_garden_entry_resolve_misses = 0


# Tally the most recent nearest_garden_entry outcome (via the cache_hit flag).
# Must be called immediately after nearest_garden_entry, before any intervening
# resolve overwrites the flag.
func record_resolve_result() -> void:
	if _garden_entry_resolve_cache_hit:
		_garden_entry_resolve_hits += 1
	else:
		_garden_entry_resolve_misses += 1


func resolve_hits() -> int:
	return _garden_entry_resolve_hits


func resolve_misses() -> int:
	return _garden_entry_resolve_misses


func cache_size() -> int:
	return _garden_entry_resolve_cache.size()


# ---------------------------------------------------------------------------
# Scoring / selection (moved verbatim from BuildingManager).
# ---------------------------------------------------------------------------

func _manhattan_cell(a: Vector2i, b: Vector2i) -> int:
	var delta: Vector2i = a - b
	return abs(delta.x) + abs(delta.y)

# Walkable cells *outside* the garden that a monster could actually step to from
# this interior access cell. "Outside" = not in zone_tiles. Uses the same
# walkability + diagonal no-corner-cut rules as _recompute_garden_geometry(), so
# the neighbors returned mirror the transitions that made access_cell an access
# cell in the first place.
func _garden_access_outside_neighbors(garden: Dictionary, access_cell: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var zone_tiles: Dictionary = garden.get("zone_tiles", {}) as Dictionary
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			var neighbor: Vector2i = access_cell + Vector2i(dx, dy)
			if not _is_walkable(neighbor):
				continue
			if zone_tiles.has(neighbor):
				continue
			if dx != 0 and dy != 0:
				if not _is_walkable(access_cell + Vector2i(dx, 0)) or not _is_walkable(access_cell + Vector2i(0, dy)):
					continue
			out.append(neighbor)
	return out

# Walkable neighbors of a cell using the same no-corner-cut rule. Pure local
# geometry (no zone awareness): used to gauge whether an outside tile is cramped
# or dead-ended for continuation scoring.
func _valid_walkable_neighbors_no_corner_cut(cell: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			var neighbor: Vector2i = cell + Vector2i(dx, dy)
			if not _is_walkable(neighbor):
				continue
			if dx != 0 and dy != 0:
				if not _is_walkable(cell + Vector2i(dx, 0)) or not _is_walkable(cell + Vector2i(0, dy)):
					continue
			out.append(neighbor)
	return out

# Route cost for a group at a cell center, or INF when flow / the group is not
# available. Wraps the optional flow.group_route_cost_at_world cache so callers
# can compare inside vs outside cost along the real escape flow.
func _group_route_cost_at_cell(escape_group: int, cell: Vector2i) -> float:
	if escape_group <= IDLE_GROUP:
		return INF
	var flow_node: Node = _flow()
	if not flow_node or not flow_node.has_method("group_route_cost_at_world"):
		return INF
	return float(flow_node.call("group_route_cost_at_world", escape_group, _cell_center(cell)))

# Low-cost score for a garden access (entry/exit) cell. Lower is better. The base
# is Manhattan distance to target_cell so behavior stays close to the old
# nearest-entry selection; penalties are purely additive and only discourage
# obviously bad local geometry. Wall proximity alone is never enough to reject a
# cell — it only adds a small cramped penalty, which doors naturally incur.
func _score_garden_access_cell(
	garden_id: int,
	access_cell: Vector2i,
	target_cell: Vector2i,
	mode: String,
	forbidden_cell: Vector2i = INVALID_CELL,
	escape_group: int = -1
) -> float:
	var gardens: Dictionary = _gardens()
	if not gardens.has(garden_id):
		return INF
	if access_cell == forbidden_cell:
		return INF
	if not _is_walkable(access_cell):
		return INF
	var garden: Dictionary = gardens[garden_id] as Dictionary

	var score: float = float(_manhattan_cell(access_cell, target_cell))

	var outside_neighbors: Array[Vector2i] = _garden_access_outside_neighbors(garden, access_cell)
	if outside_neighbors.is_empty():
		# Degenerate: an access cell with no reachable outside step. Penalize
		# heavily but never crash — the cell may still be the only option.
		return score + ACCESS_NO_OUTSIDE_PENALTY

	# Pick the outside neighbor that best follows the target / escape flow.
	var flow_node: Node = _flow()
	var use_flow: bool = escape_group > IDLE_GROUP and flow_node and flow_node.has_method("group_route_cost_at_world")
	var outside_neighbor: Vector2i = outside_neighbors[0]
	var best_outside_metric: float = INF
	for candidate in outside_neighbors:
		var metric: float
		if use_flow:
			metric = _group_route_cost_at_cell(escape_group, candidate)
			if not is_finite(metric):
				metric = float(_manhattan_cell(candidate, target_cell))
		else:
			metric = float(_manhattan_cell(candidate, target_cell))
		if metric < best_outside_metric:
			best_outside_metric = metric
			outside_neighbor = candidate

	if mode == "exit":
		# Stepping outside should not lose progress toward the target. Prefer the
		# real escape flow when available, fall back to Manhattan otherwise.
		var compared: bool = false
		if use_flow:
			var inside_cost: float = _group_route_cost_at_cell(escape_group, access_cell)
			var outside_cost: float = _group_route_cost_at_cell(escape_group, outside_neighbor)
			if is_finite(inside_cost) and is_finite(outside_cost):
				compared = true
				if outside_cost > inside_cost:
					score += ACCESS_EXIT_WORSE_PENALTY
				elif outside_cost == inside_cost:
					score += ACCESS_EXIT_FLAT_PENALTY
		if not compared:
			var inside_dist: int = _manhattan_cell(access_cell, target_cell)
			var outside_dist: int = _manhattan_cell(outside_neighbor, target_cell)
			if outside_dist > inside_dist:
				score += ACCESS_EXIT_WORSE_PENALTY
			elif outside_dist == inside_dist:
				score += ACCESS_EXIT_FLAT_PENALTY

		# Continuation: how many ways out of the outside tile, excluding stepping
		# straight back inside. A dead end forces an immediate reversal.
		var continuations: Array[Vector2i] = []
		for cont in _valid_walkable_neighbors_no_corner_cut(outside_neighbor):
			if cont == access_cell:
				continue
			continuations.append(cont)
		if continuations.is_empty():
			score += ACCESS_DEAD_CONTINUATION_PENALTY
		elif continuations.size() == 1:
			score += ACCESS_NARROW_CONTINUATION_PENALTY

		# Immediate reversal: if the best next step from the outside tile heads
		# back the way we came, the exit geometry is awkward (wall pocket).
		if not continuations.is_empty():
			var best_next: Vector2i = continuations[0]
			var best_next_metric: float = INF
			for cont in continuations:
				var cont_metric: float
				if use_flow:
					cont_metric = _group_route_cost_at_cell(escape_group, cont)
					if not is_finite(cont_metric):
						cont_metric = float(_manhattan_cell(cont, target_cell))
				else:
					cont_metric = float(_manhattan_cell(cont, target_cell))
				if cont_metric < best_next_metric:
					best_next_metric = cont_metric
					best_next = cont
			var exit_dir: Vector2i = outside_neighbor - access_cell
			var best_dir: Vector2i = best_next - outside_neighbor
			var dot: int = signi(exit_dir.x) * signi(best_dir.x) + signi(exit_dir.y) * signi(best_dir.y)
			if dot < 0:
				score += ACCESS_REVERSAL_PENALTY
			elif dot == 0:
				score += ACCESS_TURN_PENALTY

		# Small cramped penalty: blocked cardinal tiles around the outside cell.
		# Kept tiny so it can never dominate a real door's distance advantage.
		score += float(_blocked_cardinal_count(outside_neighbor)) * ACCESS_BLOCKED_CARDINAL_PENALTY
	else:
		score += _enter_local_penalty(access_cell, outside_neighbor)

	return score


# Local entrance-quality penalty for an inbound access cell reached via outside_neighbor.
# The agent heads inward, so outside continuation matters less than for exits and we do
# not penalize "outside farther than inside" (that direction is reversed). This is only a
# tie-breaker between entrances of comparable route cost — never a substitute for it.
func _enter_local_penalty(access_cell: Vector2i, outside_neighbor: Vector2i) -> float:
	var penalty: float = 0.0
	var continuations: int = 0
	for cont: Vector2i in _valid_walkable_neighbors_no_corner_cut(outside_neighbor):
		if cont == access_cell:
			continue
		continuations += 1
	if continuations == 0:
		penalty += ACCESS_ENTER_DEAD_CONTINUATION_PENALTY
	elif continuations == 1:
		penalty += ACCESS_ENTER_NARROW_CONTINUATION_PENALTY
	penalty += float(_blocked_cardinal_count(outside_neighbor)) * ACCESS_BLOCKED_CARDINAL_PENALTY
	return penalty

# Count of the 4 cardinal neighbors of `cell` that are not walkable.
func _blocked_cardinal_count(cell: Vector2i) -> int:
	var blocked: int = 0
	if not _is_walkable(cell + Vector2i(1, 0)):
		blocked += 1
	if not _is_walkable(cell + Vector2i(-1, 0)):
		blocked += 1
	if not _is_walkable(cell + Vector2i(0, 1)):
		blocked += 1
	if not _is_walkable(cell + Vector2i(0, -1)):
		blocked += 1
	return blocked

# Shared scored selector for garden access cells. Loops entry_cells, scores each
# candidate, and returns the lowest-scoring one, tie-broken by old Manhattan
# distance to target_cell for predictable behavior. If every candidate scores INF
# (or scoring finds nothing usable), falls back to the old pure-Manhattan logic.
#
# Inbound selection no longer comes through here — it uses the spawner approach field
# via resolve_garden_entry_from_spawner(). This now serves exit selection, which reads
# the real escape flow and is deliberately left as it was.
func _select_scored_garden_entry(
	garden_id: int,
	target_cell: Vector2i,
	mode: String,
	forbidden_cell: Vector2i = INVALID_CELL,
	escape_group: int = -1
) -> Vector2i:
	var gardens: Dictionary = _gardens()
	if not gardens.has(garden_id):
		return INVALID_CELL
	var garden: Dictionary = gardens[garden_id] as Dictionary
	var entry_cells: Array = garden.get("entry_cells", []) as Array
	var best_cell: Vector2i = INVALID_CELL
	var best_score: float = INF
	var best_tiebreak: int = 2147483647
	for raw_cell in entry_cells:
		var cell: Vector2i = raw_cell
		var score: float = _score_garden_access_cell(garden_id, cell, target_cell, mode, forbidden_cell, escape_group)
		if not is_finite(score):
			continue
		var tiebreak: int = _manhattan_cell(cell, target_cell)
		if score < best_score or (score == best_score and tiebreak < best_tiebreak):
			best_score = score
			best_tiebreak = tiebreak
			best_cell = cell
	if best_cell != INVALID_CELL:
		# Gated on the opt-in export (defaults off) so the debug overlay's
		# per-frame path queries can't spam this; selection itself is rare.
		if _debug_logs() and CppDebugOptions.logs_enabled:
			print("BuildingManager: garden %d %s access %s score=%.1f target=%s" % [garden_id, mode, str(best_cell), best_score, str(target_cell)])
		return best_cell
	# Nothing scored finite: fall back to the old Manhattan nearest logic so
	# behavior is never worse than before.
	return _nearest_garden_entry_manhattan(garden_id, target_cell, forbidden_cell)

# Old pure-Manhattan nearest-entry selection, preserved as the fallback for the
# scored selector. Honors forbidden_cell (pass INVALID_CELL to disable).
func _nearest_garden_entry_manhattan(garden_id: int, from_cell: Vector2i, forbidden_cell: Vector2i = INVALID_CELL) -> Vector2i:
	var gardens: Dictionary = _gardens()
	if not gardens.has(garden_id):
		return INVALID_CELL
	var garden: Dictionary = gardens[garden_id] as Dictionary
	var entry_cells: Array = garden.get("entry_cells", []) as Array
	var best_cell: Vector2i = INVALID_CELL
	var best_dist: int = 2147483647
	for raw_cell in entry_cells:
		var cell: Vector2i = raw_cell
		if cell == forbidden_cell:
			continue
		if not _is_walkable(cell):
			continue
		var manhattan: int = _manhattan_cell(cell, from_cell)
		if manhattan < best_dist:
			best_dist = manhattan
			best_cell = cell
	return best_cell

func _garden_entry_resolve_cache_key(garden_id: int, from_cell: Vector2i) -> String:
	# Spawner + garden fully determine the inbound entry for one approach generation, so
	# the key includes the spawner/source context (never garden_id alone — spawners on
	# opposite sides of a garden legitimately pick different entrances, and sharing the
	# result between them is exactly the bug this cache must not reintroduce).
	# clear_cache_for_source() depends on this "<cell>|<garden>" shape.
	return "%s|%d" % [str(from_cell), garden_id]


# ---------------------------------------------------------------------------
# Manager callbacks (source-of-truth state / low-level queries).
# ---------------------------------------------------------------------------

func _gardens() -> Dictionary:
	return _manager.get_gardens()

func _is_walkable(cell: Vector2i) -> bool:
	return _manager.is_walkable_cell(cell)

func _cell_center(cell: Vector2i) -> Vector2:
	return _manager.cell_center(cell)

func _flow() -> Node:
	return _manager.get_flow()

func _spawner_route_service() -> SpawnerRouteService:
	return _manager.get_spawner_route_service()

func _debug_logs() -> bool:
	return _manager.debug_logs_enabled()
