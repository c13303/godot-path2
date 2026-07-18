extends RefCounted
class_name FloorReplacementRegistry

## Owns semantic floor replacements. The visible floor layer stores the Road tile; this
## registry stores what that tile hides so irrigation and unbuild can update/restore it.

const FLOOR_TILE_CATALOG: Script = preload("res://scripts/map/floor_tile_catalog.gd")
const ROAD_ITEM_ID: String = "road"
const ROAD_SOURCE_ID: StringName = &"road"
const ROAD_ATLAS: Vector2i = Vector2i(10, 6)
const ROAD_SPEED_MULTIPLIER: float = 1.5

var _floor: TileMapLayer = null
var _terrain_speed: RefCounted = null
var _atlas_source_id: int = -1
var _records: Dictionary = {}  # Vector2i -> FloorReplacementRecord.


class FloorReplacementRecord:
	var item_id: String = ""
	var hidden_wet: bool = false

	func _init(p_item_id: String, p_hidden_wet: bool) -> void:
		item_id = p_item_id
		hidden_wet = p_hidden_wet


func setup(floor: TileMapLayer, terrain_speed: RefCounted, atlas_source_id: int) -> void:
	_floor = floor
	_terrain_speed = terrain_speed
	_atlas_source_id = atlas_source_id


func has_replacement_at(cell: Vector2i) -> bool:
	return _records.has(cell)


func item_id_at(cell: Vector2i) -> String:
	var record: FloorReplacementRecord = _records.get(cell) as FloorReplacementRecord
	return record.item_id if record != null else ""


func can_place_road_at(cell: Vector2i) -> bool:
	if _floor == null or _atlas_source_id < 0 or _records.has(cell):
		return false
	return FLOOR_TILE_CATALOG.is_buildable_floor_cell(_floor, cell)


## Places every still-valid Road in one floor/autotile/native batch and returns the cells
## actually committed. Callers purchase only a prevalidated affordable list.
func place_roads(cells: Array[Vector2i]) -> Array[Vector2i]:
	var placed: Array[Vector2i] = []
	var wet_cells: Array[Vector2i] = []
	var seen: Dictionary = {}
	for cell: Vector2i in cells:
		if seen.has(cell) or not can_place_road_at(cell):
			continue
		seen[cell] = true
		var hidden_wet: bool = FLOOR_TILE_CATALOG.is_wet_grass_atlas(_floor.get_cell_atlas_coords(cell))
		_records[cell] = FloorReplacementRecord.new(ROAD_ITEM_ID, hidden_wet)
		_floor.set_cell(cell, _atlas_source_id, ROAD_ATLAS)
		placed.append(cell)
		if hidden_wet:
			wet_cells.append(cell)
	if not placed.is_empty():
		_finalize_floor_changes(wet_cells)
	if _terrain_speed != null and not placed.is_empty():
		_terrain_speed.set_cells_contribution_pair(
			placed,
			ROAD_SOURCE_ID,
			ROAD_SPEED_MULTIPLIER,
			ROAD_SPEED_MULTIPLIER
		)
	return placed


## Removes the Road source only, restores semantic grass, and batches the native update.
func remove_roads(cells: Array[Vector2i]) -> Array[Vector2i]:
	if _floor == null:
		var empty: Array[Vector2i] = []
		return empty
	var removed: Array[Vector2i] = []
	var restored_wet_cells: Array[Vector2i] = []
	var seen: Dictionary = {}
	for cell: Vector2i in cells:
		if seen.has(cell) or not _records.has(cell):
			continue
		seen[cell] = true
		var record: FloorReplacementRecord = _records[cell] as FloorReplacementRecord
		var hidden_wet: bool = record.hidden_wet
		_records.erase(cell)
		var restore_atlas: Vector2i = (
			GrassAutotile.GRASS_FULL_ATLAS
			if hidden_wet
			else FLOOR_TILE_CATALOG.DRY_GROUND_FLOOR_ATLAS
		)
		_floor.set_cell(cell, _atlas_source_id, restore_atlas)
		removed.append(cell)
		if hidden_wet:
			restored_wet_cells.append(cell)
	if not removed.is_empty():
		_finalize_floor_changes(restored_wet_cells)
	if _terrain_speed != null and not removed.is_empty():
		_terrain_speed.clear_cells_contribution_pair(removed, ROAD_SOURCE_ID)
	return removed


## Irrigation compatibility: the Road remains visible while only its hidden semantic grass
## changes. Returns false when the cell is not a registered floor replacement.
func set_hidden_underlay_wet(cell: Vector2i, wet: bool) -> bool:
	var record: FloorReplacementRecord = _records.get(cell) as FloorReplacementRecord
	if record == null:
		return false
	record.hidden_wet = wet
	return true


func serialize_state() -> Array[Dictionary]:
	var cells: Array[Vector2i] = []
	for raw_cell: Variant in _records.keys():
		cells.append(raw_cell as Vector2i)
	cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.y < b.y or (a.y == b.y and a.x < b.x))
	var state: Array[Dictionary] = []
	for cell: Vector2i in cells:
		var record: FloorReplacementRecord = _records[cell] as FloorReplacementRecord
		state.append({
			"x": cell.x,
			"y": cell.y,
			"item_id": record.item_id,
			"hidden_wet": record.hidden_wet,
		})
	return state


## Restores semantic records from a fresh-scene save load. Missing data is an empty list.
## The floor layer has already been restored, but Road is stamped again defensively from the
## semantic record so the two saved representations cannot drift.
func restore_state(saved_state: Array) -> void:
	_records.clear()
	if _floor == null or _atlas_source_id < 0:
		return
	var restored: Array[Vector2i] = []
	for raw_entry: Variant in saved_state:
		if not (raw_entry is Dictionary):
			push_warning("FloorReplacementRegistry: ignoring non-dictionary save entry.")
			continue
		var entry: Dictionary = raw_entry as Dictionary
		if not entry.has("x") or not entry.has("y") or not entry.has("hidden_wet"):
			push_warning("FloorReplacementRegistry: ignoring save entry missing x/y/hidden_wet.")
			continue
		if str(entry.get("item_id", ROAD_ITEM_ID)) != ROAD_ITEM_ID:
			push_warning("FloorReplacementRegistry: ignoring unknown replacement kind '%s'." % str(entry.get("item_id", "")))
			continue
		var cell: Vector2i = Vector2i(int(entry["x"]), int(entry["y"]))
		if _records.has(cell):
			push_warning("FloorReplacementRegistry: ignoring duplicate Road at %s." % str(cell))
			continue
		_records[cell] = FloorReplacementRecord.new(ROAD_ITEM_ID, bool(entry["hidden_wet"]))
		_floor.set_cell(cell, _atlas_source_id, ROAD_ATLAS)
		restored.append(cell)
	if not restored.is_empty():
		_floor.update_internals()
		_floor.queue_redraw()
	# Progression immediately performs the controlled full terrain-speed resync, whose final
	# step calls refresh_terrain_modifiers once for this restored batch.


## Re-registers semantic Road contributions after a controlled full terrain-speed rebuild.
func refresh_terrain_modifiers() -> void:
	if _terrain_speed == null or _records.is_empty():
		return
	var cells: Array[Vector2i] = []
	for raw_cell: Variant in _records.keys():
		cells.append(raw_cell as Vector2i)
	_terrain_speed.set_cells_contribution_pair(
		cells,
		ROAD_SOURCE_ID,
		ROAD_SPEED_MULTIPLIER,
		ROAD_SPEED_MULTIPLIER
	)


func _finalize_floor_changes(grass_cells: Array[Vector2i]) -> void:
	if _floor == null:
		return
	if not grass_cells.is_empty():
		GrassAutotile.beautify(_floor, grass_cells)
	_floor.update_internals()
	_floor.queue_redraw()
