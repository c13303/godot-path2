extends RefCounted
class_name BuildingScanService

# Owns map/building scan input: tile definition lookup, special-tile migration,
# configured spawner detection, and topology signature change detection.

const BUILD_TILES_INDEX_PATH: String = "res://scripts/map/build_tiles_index.tres"
const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)
const SPAWNER_KIND_MONSTER: StringName = &"monster"
const SPAWNER_KIND_CLIENT: StringName = &"client"
const SPAWNER_KIND_MERCHANT: StringName = &"merchant"

var _manager: Node
var _tile_defs_by_atlas: Dictionary = {}
var _last_wall_signature: int = 0
var _last_water_signature: int = 0
var _last_blocking_signature: int = 0
var _last_fence_signature: int = 0


func setup(manager: Node) -> void:
	_manager = manager


func load_tile_definitions() -> void:
	_tile_defs_by_atlas.clear()
	var res: Resource = load(BUILD_TILES_INDEX_PATH)
	if not (res is JSON):
		return

	var json: JSON = res as JSON
	for key: Variant in json.data.keys():
		var definition: Variant = json.data[key]
		if not (definition is Dictionary):
			continue
		var tile_definition: Dictionary = definition as Dictionary
		var atlas: Array = tile_definition.get("atlas", [])
		if atlas.size() != 2:
			continue
		var atlas_key: String = _atlas_key(Vector2i(int(atlas[0]), int(atlas[1])))
		_tile_defs_by_atlas[atlas_key] = {
			"key": str(key),
			"kind": str(tile_definition.get("kind", ""))
		}


func scan_buildings() -> void:
	var traversable_buildings: TileMapLayer = _traversable_buildings()
	if not traversable_buildings:
		return

	var debug_telemetry: BuildingDebugTelemetry = _debug_telemetry()
	var t: int = Time.get_ticks_usec()
	var migrated: bool = migrate_special_tiles_from_wallz()
	debug_telemetry.warn_garden_task_lag_us("_migrate_special_tiles_from_wallz", Time.get_ticks_usec() - t,
		"migrated=%s" % str(migrated))

	t = Time.get_ticks_usec()
	var wallz: TileMapLayer = _wallz()
	var watersources: TileMapLayer = _watersources()
	var blocking_buildings: TileMapLayer = _blocking_buildings()
	var fences: TileMapLayer = _fences()
	var wall_signature: int = tile_layer_signature(wallz)
	var water_signature: int = tile_layer_signature(watersources)
	var blocking_signature: int = tile_layer_signature(blocking_buildings)
	var fence_signature: int = tile_layer_signature(fences)
	debug_telemetry.warn_garden_task_lag_us("_tile_layer_signature", Time.get_ticks_usec() - t,
		"wall_cells=%d water_cells=%d fence_cells=%d" % [
			wallz.get_used_cells().size() if wallz else 0,
			watersources.get_used_cells().size() if watersources else 0,
			fences.get_used_cells().size() if fences else 0,
		])
	var walls_changed: bool = (
		wall_signature != _last_wall_signature
		or water_signature != _last_water_signature
		or blocking_signature != _last_blocking_signature
		or fence_signature != _last_fence_signature
		or migrated
	)
	_last_wall_signature = wall_signature
	_last_water_signature = water_signature
	_last_blocking_signature = blocking_signature
	_last_fence_signature = fence_signature

	var seen_spawners: Dictionary = {}
	t = Time.get_ticks_usec()
	# Spawners are authored as child nodes in the loaded level's spawner/spawners
	# container. Tile special scanning is kept only for non-spawner legacy markers.
	scan_configured_spawner_nodes(seen_spawners)
	scan_special_layer(traversable_buildings, seen_spawners)
	scan_special_layer(wallz, seen_spawners)
	debug_telemetry.warn_garden_task_lag_us("_scan_special_layer", Time.get_ticks_usec() - t,
		"seen_spawners=%d" % seen_spawners.size())
	debug_telemetry.log_scan_summary(seen_spawners, migrated, walls_changed)

	var spawners: Dictionary = _spawners()
	var dirty_spawner_escapes: Dictionary = _dirty_spawner_escapes()
	for raw_spawner_cell: Variant in spawners.keys():
		var cell: Vector2i = raw_spawner_cell as Vector2i
		if not seen_spawners.has(cell):
			spawners.erase(cell)
			_manager.call("_release_spawner_route", cell)
			dirty_spawner_escapes.erase(cell)

	if walls_changed:
		_manager.set("_navigation_topology_dirty", true)


func scan_special_layer(layer: TileMapLayer, _seen_spawners: Dictionary) -> void:
	if not layer:
		return

	for raw_cell: Variant in layer.get_used_cells():
		var map_cell: Vector2i = raw_cell as Vector2i
		var definition: Dictionary = definition_for_layer_cell(layer, map_cell)
		var kind: String = str(definition.get("kind", ""))
		if kind == "spawner":
			continue


func scan_configured_spawner_nodes(seen_spawners: Dictionary) -> void:
	var debug_telemetry: BuildingDebugTelemetry = _debug_telemetry()
	var level_spawner_bindings: Array = _manager.get("_level_spawner_bindings") as Array
	for raw_binding: Variant in level_spawner_bindings:
		var binding: SpawnerBinding = raw_binding as SpawnerBinding
		if binding == null:
			continue
		if binding.kind != SPAWNER_KIND_MONSTER and binding.kind != SPAWNER_KIND_CLIENT and binding.kind != SPAWNER_KIND_MERCHANT:
			continue
		debug_telemetry.log("detected spawner node id=%s cell=%s floor=%s wall=%s" % [
			String(binding.spawner_id),
			binding.cell,
			bool(_manager.call("_has_floor", binding.cell)),
			bool(_manager.call("_has_wall", binding.cell)),
		])
		seen_spawners[binding.cell] = true
		_manager.call("_register_spawner", binding.cell, binding.kind, binding.exit_cell, binding.frequency_client, binding.spot_cell)


func migrate_special_tiles_from_wallz() -> bool:
	var wallz: TileMapLayer = _wallz()
	var traversable_buildings: TileMapLayer = _traversable_buildings()
	if not wallz or not traversable_buildings:
		return false

	var plantz: TileMapLayer = _plantz()
	var debug_telemetry: BuildingDebugTelemetry = _debug_telemetry()
	var migrated: bool = false
	for raw_cell: Variant in wallz.get_used_cells():
		var cell: Vector2i = raw_cell as Vector2i
		var definition: Dictionary = definition_for_layer_cell(wallz, cell)
		var kind: String = str(definition.get("kind", ""))
		if kind == "" or kind == "wall":
			continue
		if kind == "spawner":
			var legacy_atlas: Vector2i = wallz.get_cell_atlas_coords(cell)
			wallz.erase_cell(cell)
			migrated = true
			debug_telemetry.log("removed legacy spawner tile cell=%s atlas=%s from wallz; level spawner nodes are used instead" % [
				cell,
				legacy_atlas,
			])
			continue

		var target_layer: TileMapLayer = plantz if kind == "plantsToTarget" else traversable_buildings
		if not target_layer:
			continue
		target_layer.set_cell(
			cell,
			wallz.get_cell_source_id(cell),
			wallz.get_cell_atlas_coords(cell),
			wallz.get_cell_alternative_tile(cell)
		)
		wallz.erase_cell(cell)
		migrated = true
		debug_telemetry.log("migrated special tile kind=%s cell=%s atlas=%s from wallz to %s" % [
			kind,
			cell,
			target_layer.get_cell_atlas_coords(cell),
			target_layer.name
		])

	if migrated:
		traversable_buildings.update_internals()
		if plantz:
			plantz.update_internals()
		wallz.update_internals()
	return migrated


func definition_for_cell(cell: Vector2i) -> Dictionary:
	return definition_for_layer_cell(_traversable_buildings(), cell)


func definition_for_layer_cell(layer: TileMapLayer, cell: Vector2i) -> Dictionary:
	if not layer:
		return {}
	var atlas: Vector2i = layer.get_cell_atlas_coords(cell)
	var atlas_key: String = _atlas_key(atlas)
	return _tile_defs_by_atlas.get(atlas_key, {}) as Dictionary


func tile_layer_signature(layer: TileMapLayer) -> int:
	if not layer:
		return 0
	var signature: int = 17
	for raw_cell: Variant in layer.get_used_cells():
		var cell: Vector2i = raw_cell as Vector2i
		var atlas: Vector2i = layer.get_cell_atlas_coords(cell)
		signature += int(cell.x * 73856093 + cell.y * 19349663)
		signature += int(atlas.x * 83492791 + atlas.y * 2654435761)
	return signature


func _atlas_key(atlas: Vector2i) -> String:
	return "%d,%d" % [atlas.x, atlas.y]


func _debug_telemetry() -> BuildingDebugTelemetry:
	return _manager.get("_debug_telemetry") as BuildingDebugTelemetry


func _spawners() -> Dictionary:
	return _manager.get("_spawners") as Dictionary


func _dirty_spawner_escapes() -> Dictionary:
	return _manager.get("_dirty_spawner_escapes") as Dictionary


func _wallz() -> TileMapLayer:
	return _manager.get("wallz") as TileMapLayer


func _watersources() -> TileMapLayer:
	return _manager.get("watersources") as TileMapLayer


func _plantz() -> TileMapLayer:
	return _manager.get("plantz") as TileMapLayer


func _traversable_buildings() -> TileMapLayer:
	return _manager.get("traversable_buildings") as TileMapLayer


func _blocking_buildings() -> TileMapLayer:
	return _manager.get("blocking_buildings") as TileMapLayer


func _fences() -> TileMapLayer:
	return _manager.get("fences") as TileMapLayer
