extends RefCounted
class_name BuildingPathService

# Owns the low-level walkable A* glue extracted from BuildingManager: path queries
# on the walkable map / per-garden zone, pushing walkable tiles + wall blockers into
# the pathfinder, and converting cell paths to world positions. BuildingManager keeps
# the source-of-truth state and thin compatibility wrappers; this service keeps its
# main service dependencies explicit and reads level layers from the manager.

const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)

var _manager: BuildingManager
var _garden_topology: GardenTopologyService
var _debug_telemetry: BuildingDebugTelemetry
var _last_zone_blocker_us: int = 0


func setup(manager: BuildingManager) -> void:
	_manager = manager
	_garden_topology = manager._garden_topology as GardenTopologyService
	_debug_telemetry = manager._debug_telemetry


# ---------------------------------------------------------------------------
# A* glue: find paths via PathfinderNative.
# ---------------------------------------------------------------------------
func find_path_on_walkable_map(from_tile: Vector2i, to_tile: Vector2i) -> PackedVector2Array:
	var pf: Node = _pathfinder()
	if pf == null or not pf.has_method("find_path"):
		return PackedVector2Array()
	var topo: GardenTopologyService = _garden_topology
	if topo.walkable_map_tiles().is_empty():
		_manager._rebuild_walkable_map_cache()
	if topo.walkable_map_tiles().is_empty():
		return PackedVector2Array()
	var path_tiles: Dictionary = topo.walkable_map_tiles()
	var path_tiles_copied: bool = false
	if _is_walkable(from_tile) and not path_tiles.has(from_tile):
		path_tiles = topo.walkable_map_tiles().duplicate()
		path_tiles_copied = true
		path_tiles[from_tile] = true
	if _is_walkable(to_tile) and not path_tiles.has(to_tile):
		if not path_tiles_copied:
			path_tiles = topo.walkable_map_tiles().duplicate()
			path_tiles_copied = true
		path_tiles[to_tile] = true
	sync_pathfinder_zone_tiles(path_tiles)
	var start_tile: Vector2i = from_tile if path_tiles.has(from_tile) else _nearest_zone_tile_to(from_tile, path_tiles)
	var end_tile: Vector2i = to_tile if path_tiles.has(to_tile) else _nearest_zone_tile_to(to_tile, path_tiles)
	if start_tile == INVALID_CELL or end_tile == INVALID_CELL:
		return PackedVector2Array()
	return pf.call("find_path", start_tile, end_tile) as PackedVector2Array


func find_sheep_path(from_tile: Vector2i, to_tile: Vector2i) -> PackedVector2Array:
	var pf: Node = _pathfinder()
	var floorz: TileMapLayer = _floorz()
	if pf == null or not pf.has_method("find_path") or floorz == null:
		return PackedVector2Array()
	var path_tiles: Dictionary = {}
	for raw_cell: Variant in floorz.get_used_cells():
		var cell: Vector2i = raw_cell as Vector2i
		if _manager.is_sheep_walkable_cell(cell):
			path_tiles[cell] = true
	if path_tiles.is_empty():
		return PackedVector2Array()
	var start_tile: Vector2i = from_tile if path_tiles.has(from_tile) else _nearest_zone_tile_to(from_tile, path_tiles)
	var end_tile: Vector2i = to_tile if path_tiles.has(to_tile) else _nearest_zone_tile_to(to_tile, path_tiles)
	if start_tile == INVALID_CELL or end_tile == INVALID_CELL:
		return PackedVector2Array()
	sync_pathfinder_zone_tiles(path_tiles)
	return pf.call("find_path", start_tile, end_tile) as PackedVector2Array

func find_path_in_zone(from_tile: Vector2i, to_tile: Vector2i, garden_id: int = 0) -> PackedVector2Array:
	var pf: Node = _pathfinder()
	if pf == null or not pf.has_method("find_path"):
		return PackedVector2Array()
	var topo: GardenTopologyService = _garden_topology
	var zone_tiles: Dictionary = topo.plant_zone_tiles()
	if garden_id > 0 and topo.gardens().has(garden_id):
		var garden: Dictionary = topo.gardens()[garden_id] as Dictionary
		zone_tiles = garden.get("zone_tiles", {}) as Dictionary
	if zone_tiles.is_empty():
		return PackedVector2Array()
	# An agent arriving via the flow field can settle one tile *outside* the
	# interior (FF overshoot at the entry), so its actual cell may not be in
	# zone_tiles. Add any walkable endpoint to the A* walkable set so the path
	# starts/ends where the agent really stands instead of snapping a tile short.
	# Use a local copy so the cached garden zone_tiles is not mutated.
	# .prep: endpoint handling + zone duplicate cost (the duplicate can be the cost
	# when a garden's zone_tiles dictionary is large and both endpoints are outside).
	# Sub-warnings are gated on debug telemetry thresholds so the context string is
	# built only on a real spike — _find_path_in_zone is called in tight retarget
	# loops, so unconditional formatting here would be the wrong kind of overhead.
	var telemetry: BuildingDebugTelemetry = _debug_telemetry
	var call_start_us: int = Time.get_ticks_usec()
	var prep_us: int = Time.get_ticks_usec()
	var path_tiles: Dictionary = zone_tiles
	if _is_walkable(from_tile) and not zone_tiles.has(from_tile):
		path_tiles = zone_tiles.duplicate()
		path_tiles[from_tile] = true
	if _is_walkable(to_tile) and not path_tiles.has(to_tile):
		if path_tiles == zone_tiles:
			path_tiles = zone_tiles.duplicate()
		path_tiles[to_tile] = true
	if telemetry.over_garden_threshold_us(Time.get_ticks_usec() - prep_us):
		telemetry.warn_garden_task_lag_us("_find_path_in_zone.prep", Time.get_ticks_usec() - prep_us,
			"garden=%d zone_tiles=%d from=%s to=%s" % [garden_id, zone_tiles.size(), str(from_tile), str(to_tile)])
	# .sync_zone: pushes the walkable set + wall blockers into the pathfinder.
	var sync_us: int = Time.get_ticks_usec()
	sync_pathfinder_zone_tiles(path_tiles)
	var sync_elapsed: int = Time.get_ticks_usec() - sync_us
	if telemetry.over_garden_threshold_us(sync_elapsed):
		telemetry.warn_garden_task_lag_us("_find_path_in_zone.sync_zone", sync_elapsed,
			"garden=%d zone_tiles=%d from=%s to=%s" % [garden_id, path_tiles.size(), str(from_tile), str(to_tile)])
	# Snap endpoints to walkable tiles if needed (non-walkable endpoints only).
	var start_tile: Vector2i = from_tile if path_tiles.has(from_tile) else _nearest_zone_tile_to(from_tile, path_tiles)
	var end_tile: Vector2i = to_tile if path_tiles.has(to_tile) else _nearest_zone_tile_to(to_tile, path_tiles)
	if start_tile == INVALID_CELL or end_tile == INVALID_CELL:
		_manager._accumulate_find_path_in_zone(call_start_us, sync_elapsed, _last_zone_blocker_us, 0, from_tile, to_tile, path_tiles.size())
		return PackedVector2Array()
	# .find_path: the pathfinder A* itself.
	var find_us: int = Time.get_ticks_usec()
	var result: PackedVector2Array = pf.call("find_path", start_tile, end_tile) as PackedVector2Array
	var find_elapsed: int = Time.get_ticks_usec() - find_us
	if telemetry.over_garden_threshold_us(find_elapsed):
		telemetry.warn_garden_task_lag_us("_find_path_in_zone.find_path", find_elapsed,
			"garden=%d from=%s to=%s len=%d" % [garden_id, str(start_tile), str(end_tile), result.size()])
	_manager._accumulate_find_path_in_zone(call_start_us, sync_elapsed, _last_zone_blocker_us, find_elapsed, from_tile, to_tile, path_tiles.size())
	return result

func sync_pathfinder_zone_tiles(zone_tiles: Dictionary) -> void:
	_last_zone_blocker_us = 0
	var pf: Node = _pathfinder()
	if pf == null:
		return
	var zone_arr: PackedVector2Array = PackedVector2Array()
	zone_arr.resize(zone_tiles.size())
	var i: int = 0
	for raw_cell in zone_tiles.keys():
		var cell: Vector2i = raw_cell
		zone_arr[i] = Vector2(float(cell.x), float(cell.y))
		i += 1
	if pf.has_method("set_walkable_tiles"):
		pf.call("set_walkable_tiles", zone_arr)
	if pf.has_method("set_blockers"):
		# _wall_blockers_for_cells scans every wall tile against the zone bbox; time it
		# separately since it can dominate sync on a large wall layer. Gated so context
		# is built only on a spike (this runs once per path query). The time is also
		# stashed in _last_zone_blocker_us so the caller can split it out of sync time.
		var telemetry: BuildingDebugTelemetry = _debug_telemetry
		var blockers_us: int = Time.get_ticks_usec()
		var blockers: PackedVector2Array = wall_blockers_for_cells(zone_tiles)
		var blocker_elapsed: int = Time.get_ticks_usec() - blockers_us
		_last_zone_blocker_us = blocker_elapsed
		if telemetry.over_garden_threshold_us(blocker_elapsed):
			telemetry.warn_garden_task_lag_us("_wall_blockers_for_cells", blocker_elapsed,
				"zone_tiles=%d blockers=%d" % [zone_tiles.size(), blockers.size()])
		pf.call("set_blockers", blockers)

func wall_blockers_for_cells(cells: Dictionary) -> PackedVector2Array:
	var blockers: PackedVector2Array = PackedVector2Array()
	if cells.is_empty():
		return blockers
	var min_cell: Vector2i = INVALID_CELL
	var max_cell: Vector2i = Vector2i(-2147483648, -2147483648)
	for raw_cell in cells.keys():
		var c: Vector2i = raw_cell
		if min_cell == INVALID_CELL:
			min_cell = c
			max_cell = c
		else:
			min_cell.x = mini(min_cell.x, c.x)
			min_cell.y = mini(min_cell.y, c.y)
			max_cell.x = maxi(max_cell.x, c.x)
			max_cell.y = maxi(max_cell.y, c.y)

	var wallz_layer: TileMapLayer = _wallz()
	var blocking_buildings_layer: TileMapLayer = _blocking_buildings()
	var blocker_layers: Array[TileMapLayer] = [wallz_layer, blocking_buildings_layer]
	for layer: TileMapLayer in blocker_layers:
		if layer == null:
			continue
		for raw_cell: Variant in layer.get_used_cells():
			var c: Vector2i = raw_cell as Vector2i
			if c.x < min_cell.x or c.x > max_cell.x or c.y < min_cell.y or c.y > max_cell.y:
				continue
			if layer == blocking_buildings_layer and not _building_cell_blocks_movement(c):
				continue
			blockers.append(Vector2(float(c.x), float(c.y)))
	return blockers

func path_cells_to_world(path_cells: PackedVector2Array, nav_id: int = -1, disperse_endpoint: bool = false) -> PackedVector2Array:
	var out: PackedVector2Array = PackedVector2Array()
	out.resize(path_cells.size())
	var last_index: int = path_cells.size() - 1
	for i in range(path_cells.size()):
		var v: Vector2 = path_cells[i]
		var cell: Vector2i = Vector2i(int(v.x), int(v.y))
		if disperse_endpoint and i == last_index and nav_id >= 0:
			out[i] = _cell_center_with_local_offset(cell, _path_endpoint_local_offset(cell, nav_id))
		else:
			out[i] = _cell_center(cell)
	return out

# ---------------------------------------------------------------------------
# Local helpers used only by the pathfinding glue above.
# ---------------------------------------------------------------------------
func _nearest_zone_tile_to(cell: Vector2i, zone_tiles: Dictionary) -> Vector2i:
	var best_cell: Vector2i = INVALID_CELL
	var best_dist: int = 2147483647
	for raw_cell in zone_tiles.keys():
		var c: Vector2i = raw_cell
		var d: Vector2i = c - cell
		var manhattan: int = abs(d.x) + abs(d.y)
		if manhattan < best_dist:
			best_dist = manhattan
			best_cell = c
	return best_cell

func _cell_center_with_local_offset(cell: Vector2i, local_offset: Vector2) -> Vector2:
	var fl: TileMapLayer = _floorz()
	return fl.to_global(fl.map_to_local(cell) + local_offset)

func _path_endpoint_local_offset(cell: Vector2i, nav_id: int) -> Vector2:
	var tile_size: Vector2 = _manager._tile_size()
	var radius: float = min(tile_size.x, tile_size.y) * 0.28
	var h: int = nav_id * 1103515245 + cell.x * 73856093 + cell.y * 19349663
	var slot: int = _positive_mod(h, 12)
	@warning_ignore("integer_division")
	var ring: int = _positive_mod(h / 12, 2)
	var angle: float = (PI * 2.0 * float(slot)) / 12.0
	var ring_scale: float = 0.65 + 0.35 * float(ring)
	return Vector2(cos(angle), sin(angle)) * radius * ring_scale

func _positive_mod(value: int, divisor: int) -> int:
	var r: int = value % divisor
	if r < 0:
		r += divisor
	return r

# ---------------------------------------------------------------------------
# Manager callbacks (source-of-truth state / helpers stay on BuildingManager).
# ---------------------------------------------------------------------------
func _pathfinder() -> Node:
	return _manager.pathfinder

func _floorz() -> TileMapLayer:
	return _manager.floorz

func _wallz() -> TileMapLayer:
	return _manager.wallz

func _blocking_buildings() -> TileMapLayer:
	return _manager.blocking_buildings

func _is_walkable(cell: Vector2i) -> bool:
	return _manager._is_walkable(cell)

func _building_cell_blocks_movement(cell: Vector2i) -> bool:
	return _manager._building_cell_blocks_movement(cell)

func _cell_center(cell: Vector2i) -> Vector2:
	return _manager._cell_center(cell)
