extends RefCounted
class_name GardenAccessResolver

# Owns garden access-cell scoring, garden-entry selection, and the memoized
# entry-resolve cache. BuildingManager keeps the garden topology / walkability
# source-of-truth state and low-level queries, reached through the callbacks at
# the bottom of this file. Extracted from BuildingManager to keep that manager
# lean; behavior is preserved exactly.

const IDLE_GROUP: int = 0
const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)

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

var _manager: Node

# Memoizes the expensive scored garden-entry selection (nearest_garden_entry =
# _select_scored_garden_entry in "enter" mode, no escape group). The chosen entry
# depends only on (garden_id, source/spawner cell): scoring runs flow lookups +
# per-candidate neighbor/walkability scans over every entry cell, and the retarget
# path calls it once per (spawner, garden) pair for every agent, so many agents
# targeting the same routes recompute identical results. Keyed by "spawner|garden"
# so different spawners never share a (possibly far/bad) entry — the result is
# source-dependent, never cached by garden_id alone. Value: the selected entry
# Vector2i (may be INVALID_CELL — cached too, that "no entry" result is also reused).
# Invalidated wholesale on any topology/wall/entry rebuild (see clear_cache call
# sites); plain plant eating that leaves the garden connected with the same entries
# does NOT touch it.
var _garden_entry_resolve_cache: Dictionary = {}  # "spawner|garden" -> Vector2i
# Retarget breakdown debug counters (read into the consolidated profile line).
# Per-call flag set by nearest_garden_entry; per-resolve tallies accumulated by
# BuildingManager._select_spawner_garden_for_agent (which calls nearest_garden_entry
# many times and records each outcome).
var _garden_entry_resolve_cache_hit: bool = false
var _garden_entry_resolve_hits: int = 0
var _garden_entry_resolve_misses: int = 0


func setup(manager: Node) -> void:
	_manager = manager


# ---------------------------------------------------------------------------
# Public API.
# ---------------------------------------------------------------------------

func nearest_garden_entry(garden_id: int, from_cell: Vector2i) -> Vector2i:
	# Memoized: the retarget path calls this once per (spawner, garden) for every
	# agent, and the scored selection is the dominant cost in target_resolve.
	var cache_key: String = _garden_entry_resolve_cache_key(garden_id, from_cell)
	if _garden_entry_resolve_cache.has(cache_key):
		var cached: Vector2i = _garden_entry_resolve_cache[cache_key] as Vector2i
		# Cheap validation before trusting the cached entry. A real INVALID_CELL is a
		# legitimate cached "no entry" result and is reused as-is; only a finite cell
		# is re-checked for garden existence + membership + walkability.
		if cached == INVALID_CELL:
			_garden_entry_resolve_cache_hit = true
			return cached
		var gardens: Dictionary = _gardens()
		if gardens.has(garden_id):
			var garden: Dictionary = gardens[garden_id] as Dictionary
			var entry_cells: Array = garden.get("entry_cells", []) as Array
			if entry_cells.has(cached) and _is_walkable(cached):
				_garden_entry_resolve_cache_hit = true
				return cached
		# Stale (garden gone, entry no longer listed, or no longer walkable): drop it
		# and fall through to recompute.
		_garden_entry_resolve_cache.erase(cache_key)
	_garden_entry_resolve_cache_hit = false
	var entry: Vector2i = _select_scored_garden_entry(garden_id, from_cell, "enter")
	_garden_entry_resolve_cache[cache_key] = entry
	return entry


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
		# Enter mode: agent heads inward, so outside continuation matters less and
		# we do not penalize "outside farther than inside" (direction is reversed).
		var enter_continuations: int = 0
		for cont in _valid_walkable_neighbors_no_corner_cut(outside_neighbor):
			if cont == access_cell:
				continue
			enter_continuations += 1
		if enter_continuations == 0:
			score += ACCESS_ENTER_DEAD_CONTINUATION_PENALTY
		elif enter_continuations == 1:
			score += ACCESS_ENTER_NARROW_CONTINUATION_PENALTY
		score += float(_blocked_cardinal_count(outside_neighbor)) * ACCESS_BLOCKED_CARDINAL_PENALTY

	return score

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
	# Source cell + garden fully determine the scored "enter" entry, so the key
	# includes the spawner/source context (never garden_id alone — that would let
	# monsters from different spawners share a far/bad entry).
	return "%s|%d" % [str(from_cell), garden_id]


# ---------------------------------------------------------------------------
# Manager callbacks (source-of-truth state / low-level queries).
# ---------------------------------------------------------------------------

func _gardens() -> Dictionary:
	return _manager.call("_get_gardens") as Dictionary

func _is_walkable(cell: Vector2i) -> bool:
	return bool(_manager.call("_is_walkable", cell))

func _cell_center(cell: Vector2i) -> Vector2:
	return _manager.call("_cell_center", cell) as Vector2

func _flow() -> Node:
	return _manager.get("flow") as Node

func _spawner_route_service() -> SpawnerRouteService:
	return _manager.get("_spawner_route_service") as SpawnerRouteService

func _debug_logs() -> bool:
	return bool(_manager.get("debug_logs"))
