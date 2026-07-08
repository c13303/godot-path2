extends Node
class_name PlantManager

signal plant_added(cell: Vector2i)
signal plant_removed(cell: Vector2i)
signal plant_state_changed(cell: Vector2i, atlas_coords: Vector2i)
signal plant_visual_changed(cell: Vector2i, plant_kind: String, stage: int, watered: bool)
signal new_day_finished
signal day_seed_harvest_finished

const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)
const PLANT_KIND_ROSE: String = "rose"
const PLANT_KIND_IMPERIAL: String = "imperial"
const ROSE_GROWNUP_ATLAS: Vector2i = Vector2i(0, 1)
const ROSE_DRY_ATLAS: Vector2i = Vector2i(0, 0)
const ROSE_GREEN_ATLAS: Vector2i = Vector2i(0, 2)
const ROSE_WET_ATLAS: Vector2i = Vector2i(0, 2)
const DEBRIS_ATLAS: Vector2i = Vector2i(1, 1)
const IMPERIAL_MAX_STAGE: int = 5
const NEW_DAY_DELAY: int = 3000
const GROWNUP_BLOOM_TOTAL_SECONDS: float = 1.5

@export var plantz: TileMapLayer
@export var bucket_size: int = 16

var _plants: Dictionary = {}
var _plant_tiles: Dictionary = {}
var _buckets: Dictionary = {}
var _hidden_visual_cells: Dictionary = {}
var _initialized: bool = false
var _plant_layer_flush_queued: bool = false

func _ready() -> void:
	initialize_from_layer()
	_connect_day_started()
	if not GameState.building_phase_changed.is_connected(_on_building_phase_changed):
		GameState.building_phase_changed.connect(_on_building_phase_changed)

func _on_building_phase_changed(is_building_phase: bool) -> void:
	# A fresh build phase resets roses; imperial plants dry during morning growth.
	if is_building_phase:
		dry_all_roses()

func _connect_day_started() -> void:
	var scene: Node = get_tree().current_scene
	var progression_node: Node = scene.get_node_or_null("progression") if scene else null
	if progression_node and progression_node.has_signal("day_started"):
		var callback: Callable = Callable(self, "_on_day_started")
		if not progression_node.is_connected("day_started", callback):
			progression_node.connect("day_started", callback)

func _on_day_started(_day_number: int) -> void:
	var delay_seconds: float = float(NEW_DAY_DELAY) / 1000.0
	await get_tree().create_timer(delay_seconds).timeout
	var progression_node: Node = _get_progression_node()
	if GameState.is_night:
		_log("Rose-growth auto-save skipped: stale day-start handler reached night")
		return
	if progression_node != null and progression_node.has_method("get_value"):
		var current_day_number: int = int(progression_node.call("get_value", &"nDays"))
		if current_day_number != _day_number:
			_log("Rose-growth auto-save skipped: stale day-start handler day=%d current=%d" % [
				_day_number,
				current_day_number,
			])
			return
	var grown_count: int = grow_new_day_plants()
	if progression_node == null or not progression_node.has_method("auto_save_after_rose_growth"):
		_log("Rose-growth auto-save blocked: progression node missing")
		return
	var saved: bool = bool(progression_node.call("auto_save_after_rose_growth"))
	if not saved:
		_log("Rose-growth auto-save failed; new day remains locked")
		return
	_log("Rose-growth auto-save succeeded; grown_roses=%d" % grown_count)
	new_day_finished.emit()
	day_seed_harvest_finished.emit()

func _get_progression_node() -> Node:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return null
	return scene.get_node_or_null("progression")

func initialize_from_layer() -> void:
	_plants.clear()
	_plant_tiles.clear()
	_buckets.clear()
	_hidden_visual_cells.clear()
	if not plantz:
		_initialized = true
		return
	for raw_cell in plantz.get_used_cells():
		var cell: Vector2i = raw_cell
		if not _is_rose_atlas(plantz.get_cell_atlas_coords(cell)):
			continue
		_capture_tile_metadata(cell)
		_index_cell(cell)
	_initialized = true

func is_initialized() -> bool:
	return _initialized

func has_plant(cell: Vector2i) -> bool:
	return _plants.has(cell)

func is_empty() -> bool:
	return _plants.is_empty()

func size() -> int:
	return _plants.size()

func rose_count() -> int:
	if not plantz:
		return 0
	var count: int = 0
	for raw_cell: Variant in _plants.keys():
		var cell: Vector2i = raw_cell as Vector2i
		if is_rose_cell(cell):
			count += 1
	return count

## Number of planted roses that are still dry (not yet watered).
func unwatered_rose_count() -> int:
	if not plantz:
		return 0
	var count: int = 0
	for raw_cell: Variant in _plants.keys():
		var cell: Vector2i = raw_cell as Vector2i
		if not is_rose_cell(cell):
			continue
		if not bool((_plants[cell] as Dictionary).get("watered_once", false)):
			count += 1
	return count

func is_rose_cell(cell: Vector2i) -> bool:
	return get_plant_kind(cell) == PLANT_KIND_ROSE

func is_imperial_cell(cell: Vector2i) -> bool:
	return get_plant_kind(cell) == PLANT_KIND_IMPERIAL

func get_plant_kind(cell: Vector2i) -> String:
	if not _plants.has(cell):
		return ""
	var plant_data: Dictionary = _plants[cell] as Dictionary
	return str(plant_data.get("plant_kind", PLANT_KIND_ROSE))

func is_client_target_cell(cell: Vector2i) -> bool:
	return is_rose_cell(cell) and is_rose_grownup(cell)

func _is_rose_atlas(atlas_coords: Vector2i) -> bool:
	return atlas_coords == ROSE_DRY_ATLAS or atlas_coords == ROSE_GREEN_ATLAS or atlas_coords == ROSE_GROWNUP_ATLAS

func wet_rose(cell: Vector2i) -> bool:
	if not plantz or not is_rose_cell(cell):
		return false
	if is_rose_grownup(cell):
		return false
	var plant_data: Dictionary = _plants[cell] as Dictionary
	if bool(plant_data.get("watered_once", false)):
		return false
	plant_data["watered_once"] = true
	plant_data["grownup"] = false
	_plants[cell] = plant_data
	_set_rose_atlas(cell, ROSE_WET_ATLAS)
	return true

func wet_plant(cell: Vector2i) -> bool:
	if is_rose_cell(cell):
		return wet_rose(cell)
	if is_imperial_cell(cell):
		return wet_imperial(cell)
	return false

func wet_imperial(cell: Vector2i) -> bool:
	if not is_imperial_cell(cell):
		return false
	var plant_data: Dictionary = _plants[cell] as Dictionary
	if int(plant_data.get("stage", 0)) >= IMPERIAL_MAX_STAGE:
		return false
	if bool(plant_data.get("watered_once", false)):
		return false
	plant_data["watered_once"] = true
	_plants[cell] = plant_data
	_emit_visual_changed(cell)
	return true

func grow_new_day_plants() -> int:
	var rose_count_grown: int = grow_green_roses()
	var imperial_count_grown: int = grow_imperial_plants()
	return rose_count_grown + imperial_count_grown

func grow_green_roses() -> int:
	if not plantz:
		return 0
	var grown_count: int = 0
	for raw_cell: Variant in _plants.keys():
		var cell: Vector2i = raw_cell as Vector2i
		if not is_rose_cell(cell):
			continue
		var plant_data: Dictionary = _plants[cell] as Dictionary
		if not bool(plant_data.get("watered_once", false)) or bool(plant_data.get("grownup", false)):
			continue
		plant_data["grownup"] = true
		_plants[cell] = plant_data
		# Grown roses keep their watered (green) look through the night and morning;
		# they only open into the full-bloom "rose-rose" tile once the harvest phase
		# begins (see bloom_grownup_roses), and revert to the dry tile at the next
		# build phase (see dry_all_roses), so a watered rose never appears to dry out
		# overnight.
		_set_rose_atlas(cell, ROSE_WET_ATLAS)
		grown_count += 1
	return grown_count

func grow_imperial_plants() -> int:
	var grown_count: int = 0
	for raw_cell: Variant in _plants.keys():
		var cell: Vector2i = raw_cell as Vector2i
		if not is_imperial_cell(cell):
			continue
		var plant_data: Dictionary = _plants[cell] as Dictionary
		if not bool(plant_data.get("watered_once", false)):
			continue
		var stage: int = clampi(int(plant_data.get("stage", 0)), 0, IMPERIAL_MAX_STAGE)
		if stage >= IMPERIAL_MAX_STAGE:
			plant_data["watered_once"] = false
			_plants[cell] = plant_data
			_emit_visual_changed(cell)
			continue
		plant_data["stage"] = stage + 1
		plant_data["watered_once"] = false
		_plants[cell] = plant_data
		_emit_visual_changed(cell)
		grown_count += 1
	return grown_count


## Opens every grown rose into its full-bloom "rose-rose" tile one by one. Called
## when the morning harvest phase begins so watered roses (still green from
## overnight growth) visibly bloom into full roses before the player can collect
## them. The full map completes in total_duration_seconds, so more roses bloom
## faster per rose.
func bloom_grownup_roses(total_duration_seconds: float = GROWNUP_BLOOM_TOTAL_SECONDS) -> int:
	await get_tree().process_frame
	if not plantz:
		return 0
	var cells: Array[Vector2i] = []
	for raw_cell: Variant in _plants.keys():
		var cell: Vector2i = raw_cell as Vector2i
		if not is_rose_cell(cell):
			continue
		if not is_rose_grownup(cell):
			continue
		if plantz.get_cell_atlas_coords(cell) == ROSE_GROWNUP_ATLAS:
			continue
		cells.append(cell)
	cells.sort_custom(Callable(self, "_sort_cells_top_left"))
	var bloom_count: int = cells.size()
	if bloom_count <= 0:
		return 0
	var delay_seconds: float = maxf(0.0, total_duration_seconds) / float(bloom_count)
	var bloomed_count: int = 0
	for cell: Vector2i in cells:
		if delay_seconds > 0.0:
			await get_tree().create_timer(delay_seconds).timeout
		if not plantz or not is_rose_grownup(cell):
			continue
		if plantz.get_cell_atlas_coords(cell) == ROSE_GROWNUP_ATLAS:
			continue
		_set_rose_atlas(cell, ROSE_GROWNUP_ATLAS)
		bloomed_count += 1
	return bloomed_count

func _sort_cells_top_left(a: Vector2i, b: Vector2i) -> bool:
	if a.y == b.y:
		return a.x < b.x
	return a.y < b.y


## Reverts every rose to its dry, unwatered state (dry tile, needs watering again to
## grow). Called when a new build phase starts so the player re-waters each day; not
## called overnight, so watered roses stay green until then.
func dry_all_roses() -> void:
	if not plantz:
		return
	for raw_cell: Variant in _plants.keys():
		var cell: Vector2i = raw_cell as Vector2i
		if not is_rose_cell(cell):
			continue
		var plant_data: Dictionary = _plants[cell] as Dictionary
		plant_data["watered_once"] = false
		plant_data["grownup"] = false
		_plants[cell] = plant_data
		_set_rose_atlas(cell, ROSE_DRY_ATLAS, false)
	_flush_plant_layer_now()
	_queue_plant_layer_flush()

func grownup_rose_count() -> int:
	var count: int = 0
	for raw_cell: Variant in _plants.keys():
		var cell: Vector2i = raw_cell as Vector2i
		if not is_rose_cell(cell):
			continue
		if is_rose_grownup(cell):
			count += 1
	return count

func is_rose_grownup(cell: Vector2i) -> bool:
	if not is_rose_cell(cell):
		return false
	return bool((_plants[cell] as Dictionary).get("grownup", false))

func get_grownup_rose_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for raw_cell: Variant in _plants.keys():
		var cell: Vector2i = raw_cell as Vector2i
		if not is_rose_cell(cell):
			continue
		if is_rose_grownup(cell):
			cells.append(cell)
	return cells


func harvest_grownup_rose(cell: Vector2i) -> bool:
	if not is_rose_grownup(cell):
		return false
	remove_plant(cell, true)
	return true

func set_rose_visual_hidden(cell: Vector2i, hidden: bool) -> void:
	if not plantz or not is_rose_cell(cell):
		return
	if hidden:
		if _hidden_visual_cells.has(cell):
			return
		_capture_tile_metadata(cell)
		_hidden_visual_cells[cell] = true
		plantz.erase_cell(cell)
	else:
		if not _hidden_visual_cells.has(cell):
			return
		var tile_data: Dictionary = _plant_tiles.get(cell, {}) as Dictionary
		if tile_data.is_empty():
			return
		_hidden_visual_cells.erase(cell)
		var source_id: int = int(tile_data.get("source_id", -1))
		var atlas_coords: Vector2i = tile_data.get("atlas_coords", ROSE_DRY_ATLAS) as Vector2i
		var alternative_tile: int = int(tile_data.get("alternative_tile", 0))
		if source_id >= 0:
			plantz.set_cell(cell, source_id, atlas_coords, alternative_tile)
	_flush_plant_layer_now()
	_queue_plant_layer_flush()

func _set_rose_atlas(cell: Vector2i, atlas_coords: Vector2i, flush_visuals: bool = true) -> void:
	var source_id: int = plantz.get_cell_source_id(cell)
	var alternative_tile: int = plantz.get_cell_alternative_tile(cell)
	if source_id < 0:
		var tile_data: Dictionary = _plant_tiles.get(cell, {}) as Dictionary
		source_id = int(tile_data.get("source_id", -1))
		alternative_tile = int(tile_data.get("alternative_tile", 0))
	if source_id < 0:
		return
	_plant_tiles[cell] = {
		"source_id": source_id,
		"atlas_coords": atlas_coords,
		"alternative_tile": alternative_tile
	}
	if not _hidden_visual_cells.has(cell):
		plantz.set_cell(cell, source_id, atlas_coords, alternative_tile)
		_capture_tile_metadata(cell)
	if flush_visuals:
		_flush_plant_layer_now()
		_queue_plant_layer_flush()
	plant_state_changed.emit(cell, atlas_coords)

func get_plant_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for raw_cell in _plants.keys():
		var cell: Vector2i = raw_cell
		cells.append(cell)
	return cells

func serialize_plant_states() -> Array[Dictionary]:
	var states: Array[Dictionary] = []
	for raw_cell: Variant in _plants.keys():
		var cell: Vector2i = raw_cell as Vector2i
		var plant_data: Dictionary = _plants[cell] as Dictionary
		states.append({
			"x": cell.x,
			"y": cell.y,
			"plant_kind": str(plant_data.get("plant_kind", PLANT_KIND_ROSE)),
			"watered_once": bool(plant_data.get("watered_once", false)),
			"grownup": bool(plant_data.get("grownup", false)),
			"stage": int(plant_data.get("stage", 0)),
		})
	return states

func restore_plant_states(saved_states: Array) -> void:
	var restored_count: int = 0
	var ignored_count: int = 0
	var grown_count: int = 0
	var watered_count: int = 0
	for raw_entry: Variant in saved_states:
		if not (raw_entry is Dictionary):
			ignored_count += 1
			continue
		var entry: Dictionary = raw_entry as Dictionary
		var cell: Vector2i = Vector2i(int(entry.get("x", 0)), int(entry.get("y", 0)))
		var plant_kind: String = str(entry.get("plant_kind", PLANT_KIND_ROSE))
		if not _plants.has(cell) and plant_kind == PLANT_KIND_IMPERIAL:
			add_plant(cell, PLANT_KIND_IMPERIAL)
		if not _plants.has(cell):
			ignored_count += 1
			continue
		var plant_data: Dictionary = _plants[cell] as Dictionary
		plant_data["plant_kind"] = plant_kind
		plant_data["watered_once"] = bool(entry.get("watered_once", plant_data.get("watered_once", false)))
		plant_data["grownup"] = bool(entry.get("grownup", plant_data.get("grownup", false)))
		plant_data["stage"] = clampi(int(entry.get("stage", plant_data.get("stage", 0))), 0, IMPERIAL_MAX_STAGE)
		_plants[cell] = plant_data
		_emit_visual_changed(cell)
		restored_count += 1
		if bool(plant_data.get("watered_once", false)):
			watered_count += 1
		if bool(plant_data.get("grownup", false)):
			grown_count += 1
	_log("Restore plant states: saved=%d restored=%d ignored=%d watered=%d grown=%d live_roses=%d" % [
		saved_states.size(),
		restored_count,
		ignored_count,
		watered_count,
		grown_count,
		rose_count(),
	])

func add_plant(cell: Vector2i, plant_kind: String = PLANT_KIND_ROSE) -> void:
	if _plants.has(cell):
		return
	if plant_kind == PLANT_KIND_ROSE:
		_capture_tile_metadata(cell)
	_plants[cell] = {
		"plant_kind": plant_kind,
		"watered_once": false,
		"grownup": false,
		"stage": 0,
	}
	_index_cell(cell)
	_emit_visual_changed(cell)
	plant_added.emit(cell)

func remove_plant(cell: Vector2i, erase_tile: bool = true) -> void:
	if not _plants.has(cell):
		return
	_unindex_cell(cell)
	if erase_tile and plantz:
		plantz.erase_cell(cell)
		_queue_plant_layer_flush()
	_emit_visual_removed(cell)
	plant_removed.emit(cell)

func consume_plant(cell: Vector2i) -> void:
	if not plantz or not _plants.has(cell):
		return
	var source_id: int = plantz.get_cell_source_id(cell)
	var alternative_tile: int = plantz.get_cell_alternative_tile(cell)
	_unindex_cell(cell)
	_emit_visual_removed(cell)
	if source_id < 0:
		source_id = _plant_layer_source_id()
	if source_id >= 0:
		plantz.set_cell(cell, source_id, DEBRIS_ATLAS, alternative_tile)
		_flush_plant_layer_now()
		_queue_plant_layer_flush()
	plant_removed.emit(cell)

func _capture_tile_metadata(cell: Vector2i) -> void:
	if not plantz:
		return
	var source_id: int = plantz.get_cell_source_id(cell)
	if source_id < 0:
		_plant_tiles.erase(cell)
		return
	var atlas_coords: Vector2i = plantz.get_cell_atlas_coords(cell)
	var existing_data: Dictionary = _plants.get(cell, {}) as Dictionary
	var watered_once: bool = bool(existing_data.get("watered_once", atlas_coords == ROSE_GREEN_ATLAS))
	var grownup: bool = bool(existing_data.get("grownup", atlas_coords == ROSE_GROWNUP_ATLAS and not watered_once))
	_plants[cell] = {
		"plant_kind": PLANT_KIND_ROSE,
		"watered_once": watered_once,
		"grownup": grownup,
		"stage": 0,
	}
	_plant_tiles[cell] = {
		"source_id": source_id,
		"atlas_coords": atlas_coords,
		"alternative_tile": plantz.get_cell_alternative_tile(cell)
	}

func _rebuild_plant_layer_from_index() -> void:
	if not plantz:
		return
	# Rebuild only edible plants; non-plant occupants such as debris must remain.
	for raw_used_cell: Variant in plantz.get_used_cells():
		var used_cell: Vector2i = raw_used_cell as Vector2i
		if _is_rose_atlas(plantz.get_cell_atlas_coords(used_cell)):
			plantz.erase_cell(used_cell)
	for raw_cell in _plants.keys():
		var cell: Vector2i = raw_cell
		var tile_data: Dictionary = _plant_tiles.get(cell, {}) as Dictionary
		if tile_data.is_empty():
			continue
		var source_id: int = int(tile_data.get("source_id", -1))
		var atlas_coords: Vector2i = tile_data.get("atlas_coords", Vector2i(-1, -1)) as Vector2i
		var alternative_tile: int = int(tile_data.get("alternative_tile", 0))
		if source_id >= 0:
			plantz.set_cell(cell, source_id, atlas_coords, alternative_tile)
	_flush_plant_layer_now()
	_queue_plant_layer_flush()

func _flush_plant_layer_now() -> void:
	if not plantz:
		return
	plantz.update_internals()
	plantz.queue_redraw()

func _queue_plant_layer_flush() -> void:
	if _plant_layer_flush_queued:
		return
	_plant_layer_flush_queued = true
	call_deferred("_flush_plant_layer_deferred")

func _flush_plant_layer_deferred() -> void:
	_plant_layer_flush_queued = false
	_flush_plant_layer_now()

func nearest_plant_cell(from_cell: Vector2i, excluded_cell: Vector2i = INVALID_CELL) -> Vector2i:
	if _plants.is_empty():
		return INVALID_CELL

	var origin_bucket: Vector2i = _bucket_for_cell(from_cell)
	var best_cell: Vector2i = INVALID_CELL
	var best_dist_sq: int = 2147483647
	var max_radius: int = _max_bucket_search_radius(origin_bucket)

	for radius in range(0, max_radius + 1):
		var radius_min_dist_sq: int = _bucket_ring_min_dist_sq(from_cell, origin_bucket, radius)
		if best_cell != INVALID_CELL and radius_min_dist_sq > best_dist_sq:
			break
		for bucket in _bucket_ring(origin_bucket, radius):
			if not _buckets.has(bucket):
				continue
			var bucket_cells: Dictionary = _buckets[bucket] as Dictionary
			for raw_cell in bucket_cells.keys():
				var cell: Vector2i = raw_cell
				if cell == excluded_cell:
					continue
				var d: Vector2i = cell - from_cell
				var dist_sq: int = d.x * d.x + d.y * d.y
				if dist_sq < best_dist_sq:
					best_dist_sq = dist_sq
					best_cell = cell

	return best_cell

func _index_cell(cell: Vector2i) -> void:
	if not _plants.has(cell):
		_plants[cell] = {"plant_kind": PLANT_KIND_ROSE, "watered_once": false, "grownup": false, "stage": 0}
	var bucket: Vector2i = _bucket_for_cell(cell)
	if not _buckets.has(bucket):
		_buckets[bucket] = {}
	var bucket_cells: Dictionary = _buckets[bucket] as Dictionary
	bucket_cells[cell] = true
	_buckets[bucket] = bucket_cells

func _unindex_cell(cell: Vector2i) -> void:
	_plants.erase(cell)
	_plant_tiles.erase(cell)
	_hidden_visual_cells.erase(cell)
	var bucket: Vector2i = _bucket_for_cell(cell)
	if not _buckets.has(bucket):
		return
	var bucket_cells: Dictionary = _buckets[bucket] as Dictionary
	bucket_cells.erase(cell)
	if bucket_cells.is_empty():
		_buckets.erase(bucket)
	else:
		_buckets[bucket] = bucket_cells

func _bucket_for_cell(cell: Vector2i) -> Vector2i:
	var size_i: int = max(1, bucket_size)
	return Vector2i(floori(float(cell.x) / float(size_i)), floori(float(cell.y) / float(size_i)))

func _bucket_ring(origin: Vector2i, radius: int) -> Array[Vector2i]:
	var buckets: Array[Vector2i] = []
	if radius == 0:
		buckets.append(origin)
		return buckets
	for x in range(origin.x - radius, origin.x + radius + 1):
		buckets.append(Vector2i(x, origin.y - radius))
		buckets.append(Vector2i(x, origin.y + radius))
	for y in range(origin.y - radius + 1, origin.y + radius):
		buckets.append(Vector2i(origin.x - radius, y))
		buckets.append(Vector2i(origin.x + radius, y))
	return buckets

func _bucket_ring_min_dist_sq(from_cell: Vector2i, origin_bucket: Vector2i, radius: int) -> int:
	if radius == 0:
		return 0
	var size_i: int = max(1, bucket_size)
	var inner_radius: int = radius - 1
	var inner_min_x: int = (origin_bucket.x - inner_radius) * size_i
	var inner_max_x: int = ((origin_bucket.x + inner_radius + 1) * size_i) - 1
	var inner_min_y: int = (origin_bucket.y - inner_radius) * size_i
	var inner_max_y: int = ((origin_bucket.y + inner_radius + 1) * size_i) - 1
	var left_dx: int = from_cell.x - (inner_min_x - 1)
	var right_dx: int = (inner_max_x + 1) - from_cell.x
	var top_dy: int = from_cell.y - (inner_min_y - 1)
	var bottom_dy: int = (inner_max_y + 1) - from_cell.y
	var min_axis_dist: int = min(min(left_dx, right_dx), min(top_dy, bottom_dy))
	return min_axis_dist * min_axis_dist

func _max_bucket_search_radius(origin_bucket: Vector2i) -> int:
	var max_radius: int = 0
	for raw_bucket in _buckets.keys():
		var bucket: Vector2i = raw_bucket
		max_radius = max(max_radius, max(abs(bucket.x - origin_bucket.x), abs(bucket.y - origin_bucket.y)))
	return max_radius

func _log(message: String) -> void:
	CppDebugOptions.save_log("[SAVE] PlantManager: " + message)

func get_imperial_plant_visual_states() -> Array[Dictionary]:
	var states: Array[Dictionary] = []
	for raw_cell: Variant in _plants.keys():
		var cell: Vector2i = raw_cell as Vector2i
		if not is_imperial_cell(cell):
			continue
		states.append(get_plant_visual_state(cell))
	return states

func get_plant_visual_state(cell: Vector2i) -> Dictionary:
	if not _plants.has(cell):
		return {}
	var plant_data: Dictionary = _plants[cell] as Dictionary
	return {
		"cell": cell,
		"plant_kind": str(plant_data.get("plant_kind", PLANT_KIND_ROSE)),
		"stage": int(plant_data.get("stage", 0)),
		"watered": bool(plant_data.get("watered_once", false)),
	}

func _emit_visual_changed(cell: Vector2i) -> void:
	if not _plants.has(cell):
		return
	var plant_data: Dictionary = _plants[cell] as Dictionary
	var plant_kind: String = str(plant_data.get("plant_kind", PLANT_KIND_ROSE))
	plant_visual_changed.emit(
		cell,
		plant_kind,
		int(plant_data.get("stage", 0)),
		bool(plant_data.get("watered_once", false))
	)

func _emit_visual_removed(cell: Vector2i) -> void:
	plant_visual_changed.emit(cell, "", 0, false)

func _plant_layer_source_id() -> int:
	if plantz == null or plantz.tile_set == null:
		return -1
	var source_count: int = plantz.tile_set.get_source_count()
	if source_count <= 0:
		return -1
	return plantz.tile_set.get_source_id(0)
