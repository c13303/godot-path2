extends RefCounted
class_name PlayerPlaceableDurabilityService

# Owns the generic destructible target system: registered build provenance, live
# map/runtime target discovery for tantrum fallback, current/max health, target
# validity, cheap nearest-target selection, damage application, instant plant
# destruction, and save serialization/restoration for registered tile targets.
#
# BuildingManager owns this service and exposes thin wrappers. Provenance is still
# registered on placement (BuildPlacementService.after_placeable_placed) and
# removed on the central removal path (BuildRemovalService.remove_tile). Tantrum
# can also ask the service to discover current live destructible targets so old
# saves and level-authored reservoirs do not leave hostile clients with nothing
# to attack.
#
# BuildRemovalService remains the owner of the actual tile removal + cleanup:
# structure destruction routes through BuildSystem.destroy_placeable_no_refund
# (same cleanup as a normal unbuild, minus the refund), and plant destruction
# reuses the authoritative PlantManager consume path.

const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)
const RESERVOIR_ITEM_ID: String = "reservoir"
const RUNTIME_RESERVOIR_LAYER: String = "runtime_reservoir"
const RESERVOIR_GROUP: StringName = &"reservoirs"

var _manager: BuildingManager = null
var _overlay: Node = null
var _build_system: Node = null

# key(String) -> record Dictionary. A registered record IS the player-built
# provenance; the record shape is centralized here so target dictionaries never
# leak loosely-typed across files.
#   { "key": String, "cell": Vector2i, "item_id": String, "layer_name": String,
#     "health": int, "max_health": int, "instant_destroy": bool }
var _targets_by_key: Dictionary = {}
# cell(Vector2i) -> Dictionary[key(String) -> true]. Multiple target layers may
# legally share one cell (for example a plant-layer target and a structure), so
# provenance removal must be keyed by layer + cell when the caller knows the layer.
var _keys_by_cell: Dictionary = {}
# Bumped on any registration/health/destruction change so idle hostiles can retry
# target selection when the world changed instead of scanning every frame.
var _revision: int = 0


func setup(manager: BuildingManager) -> void:
	_manager = manager


func set_overlay(overlay: Node) -> void:
	_overlay = overlay


func revision() -> int:
	return _revision


func clear() -> void:
	_targets_by_key.clear()
	_keys_by_cell.clear()
	_bump_and_redraw()


# ---------------------------------------------------------------------------
# Provenance registration (central placement / removal hooks).
# ---------------------------------------------------------------------------
func register_player_placeable(cell: Vector2i, item_id: String, layer_name: String) -> void:
	if item_id == "" or not ItemCatalog.is_destructible_placeable(item_id):
		return
	var normalized_layer: String = _normalize_layer_name(layer_name)
	var key: String = _make_key(normalized_layer, cell)
	# Overbuild replaces prior provenance for the same layer/cell, but does not
	# discard another layer's target that happens to share the same map cell.
	_erase_record_by_key(key)
	var instant_destroy: bool = ItemCatalog.is_instant_destroy_placeable(item_id)
	var max_health: int = 1 if instant_destroy else maxi(1, ItemCatalog.get_max_health(item_id))
	_targets_by_key[key] = {
		"key": key,
		"cell": cell,
		"item_id": item_id,
		"layer_name": normalized_layer,
		"health": max_health,
		"max_health": max_health,
		"instant_destroy": instant_destroy,
	}
	_add_cell_key(cell, key)
	_bump_and_redraw()


func unregister_player_placeable(cell: Vector2i) -> void:
	if _erase_records_at_cell(cell):
		_bump_and_redraw()


func unregister_player_placeable_at(cell: Vector2i, layer_name: String) -> void:
	var key: String = _make_key(_normalize_layer_name(layer_name), cell)
	if _targets_by_key.has(key):
		_erase_record_by_key(key)
		_bump_and_redraw()


func is_player_built_cell(cell: Vector2i) -> bool:
	return _keys_by_cell.has(cell) and not (_keys_by_cell[cell] as Dictionary).is_empty()


func register_live_destructible_targets() -> int:
	var added: int = 0
	for layer_name: String in ["wallz", "plantz", "traversable_buildings", "blocking_buildings", "fences"]:
		var layer: TileMapLayer = _layer_for_name(layer_name)
		if layer == null:
			continue
		for raw_cell: Variant in layer.get_used_cells():
			var cell: Vector2i = raw_cell as Vector2i
			if _register_live_destructible_target(layer, layer_name, cell):
				added += 1
	added += _register_live_reservoir_nodes()
	if added > 0:
		_bump_and_redraw()
	return added


# ---------------------------------------------------------------------------
# Target queries / selection.
# ---------------------------------------------------------------------------
func has_targets() -> bool:
	return not _targets_by_key.is_empty()


func target_record(key: String) -> Dictionary:
	return _targets_by_key.get(key, {}) as Dictionary


func target_world_position(key: String) -> Vector2:
	if not _targets_by_key.has(key):
		return Vector2.ZERO
	var rec: Dictionary = _targets_by_key[key] as Dictionary
	if str(rec.get("layer_name", "")) == RUNTIME_RESERVOIR_LAYER:
		var reservoir: Node2D = rec.get("node", null) as Node2D
		if reservoir != null and is_instance_valid(reservoir):
			return reservoir.global_position
	return _manager.cell_center(rec.get("cell", INVALID_CELL) as Vector2i)


func is_target_valid(key: String) -> bool:
	if not _targets_by_key.has(key):
		return false
	var rec: Dictionary = _targets_by_key[key] as Dictionary
	var cell: Vector2i = rec.get("cell", INVALID_CELL) as Vector2i
	var layer_name: String = str(rec.get("layer_name", ""))
	if layer_name == RUNTIME_RESERVOIR_LAYER:
		var reservoir: Node = rec.get("node", null) as Node
		if reservoir == null or not is_instance_valid(reservoir):
			return false
		if reservoir.has_method("is_destroyed") and bool(reservoir.call("is_destroyed")):
			return false
		return true
	var layer: TileMapLayer = _layer_for_name(layer_name)
	if layer == null or layer.get_cell_source_id(cell) < 0:
		return false
	return _live_item_id_at(layer, layer_name, cell) == str(rec.get("item_id", ""))


# Cheapest nearest live target by squared Euclidean world distance, skipping any
# key in `rejected`. Deterministic tie-break by cell coordinates. Invalid records
# encountered here are pruned so the registry does not grow stale.
func nearest_target_key(from_world: Vector2, rejected: Dictionary = {}) -> String:
	var invalid_keys: Array[String] = []
	var best_key: String = ""
	var best_distance: float = INF
	var best_cell: Vector2i = INVALID_CELL
	for raw_key: Variant in _targets_by_key.keys():
		var key: String = str(raw_key)
		if not is_target_valid(key):
			invalid_keys.append(key)
			continue
		if rejected.has(key):
			continue
		var rec: Dictionary = _targets_by_key[key] as Dictionary
		var cell: Vector2i = rec.get("cell", INVALID_CELL) as Vector2i
		var distance: float = from_world.distance_squared_to(_manager.cell_center(cell))
		if best_key == "" or distance < best_distance or (distance == best_distance and _cell_precedes(cell, best_cell)):
			best_key = key
			best_distance = distance
			best_cell = cell
	if not invalid_keys.is_empty():
		for key: String in invalid_keys:
			_erase_record_by_key(key)
		_bump_and_redraw()
	return best_key


func damaged_records() -> Array:
	var out: Array = []
	for raw_key: Variant in _targets_by_key.keys():
		var rec: Dictionary = _targets_by_key[raw_key] as Dictionary
		if bool(rec.get("instant_destroy", false)):
			continue
		var health: int = int(rec.get("health", 0))
		var max_health: int = int(rec.get("max_health", 0))
		if health > 0 and health < max_health:
			out.append(rec)
	return out


# ---------------------------------------------------------------------------
# Damage / destruction.
# ---------------------------------------------------------------------------
# Returns true when the target was destroyed by this hit.
func apply_damage(key: String, amount: int) -> bool:
	if amount <= 0 or not _targets_by_key.has(key):
		return false
	var rec: Dictionary = _targets_by_key[key] as Dictionary
	if bool(rec.get("instant_destroy", false)):
		destroy_target(key)
		return true
	var health: int = maxi(0, int(rec.get("health", 0)) - amount)
	rec["health"] = health
	_targets_by_key[key] = rec
	if health <= 0:
		destroy_target(key)
		return true
	_bump_and_redraw()
	return false


func destroy_target(key: String) -> void:
	if not _targets_by_key.has(key):
		return
	var rec: Dictionary = _targets_by_key[key] as Dictionary
	var cell: Vector2i = rec.get("cell", INVALID_CELL) as Vector2i
	var item_id: String = str(rec.get("item_id", ""))
	var instant_destroy: bool = bool(rec.get("instant_destroy", false))
	# Remove provenance first so the removal callback (remove_tile ->
	# unregister_player_placeable) is idempotent and cannot recurse.
	_erase_record_by_key(key)
	if instant_destroy:
		_destroy_plant_cell(cell)
	elif str(rec.get("layer_name", "")) == RUNTIME_RESERVOIR_LAYER:
		_destroy_runtime_reservoir(rec)
	else:
		if item_id == RESERVOIR_ITEM_ID:
			# Authoritative reservoir-destroyed game-state path; the existing
			# game-over UI polls GameState.is_reservoir_destroyed.
			GameState.set_reservoir_destroyed(true)
		_destroy_structure_cell(cell, str(rec.get("layer_name", "")), item_id)
	_bump_and_redraw()


func _destroy_plant_cell(cell: Vector2i) -> void:
	# Reuse the authoritative creature plant-destruction semantics (burst + debris
	# tile) rather than erasing only the tile.
	var plant_manager: Node = _manager.get_plant_manager()
	_manager.spawn_plant_parts_burst(_manager.cell_center(cell))
	if plant_manager != null and plant_manager.has_method("consume_plant"):
		plant_manager.call("consume_plant", cell)
	elif plant_manager != null and plant_manager.has_method("remove_plant"):
		plant_manager.call("remove_plant", cell, true)


func _destroy_structure_cell(cell: Vector2i, layer_name: String, item_id: String) -> void:
	var build_system: Node = _resolve_build_system()
	if build_system != null and build_system.has_method("destroy_placeable_no_refund"):
		build_system.call("destroy_placeable_no_refund", cell, layer_name, item_id)


func _destroy_runtime_reservoir(record: Dictionary) -> void:
	var reservoir: Node = record.get("node", null) as Node
	if reservoir != null and is_instance_valid(reservoir) and reservoir.has_method("take_damage"):
		reservoir.call("take_damage", int(record.get("max_health", 100)))
	else:
		GameState.set_reservoir_destroyed(true)


# ---------------------------------------------------------------------------
# Save / load.
# ---------------------------------------------------------------------------
func serialize() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for raw_key: Variant in _targets_by_key.keys():
		var key: String = str(raw_key)
		if not is_target_valid(key):
			continue
		var rec: Dictionary = _targets_by_key[key] as Dictionary
		if str(rec.get("layer_name", "")) == RUNTIME_RESERVOIR_LAYER:
			continue
		var cell: Vector2i = rec.get("cell", INVALID_CELL) as Vector2i
		out.append({
			"x": cell.x,
			"y": cell.y,
			"layer": str(rec.get("layer_name", "")),
			"item_id": str(rec.get("item_id", "")),
			"health": int(rec.get("health", 0)),
			"max_health": int(rec.get("max_health", 0)),
		})
	return out


func restore(saved: Array) -> void:
	_targets_by_key.clear()
	_keys_by_cell.clear()
	var ignored: int = 0
	for raw_entry: Variant in saved:
		if not (raw_entry is Dictionary):
			ignored += 1
			continue
		var entry: Dictionary = raw_entry as Dictionary
		var cell: Vector2i = Vector2i(int(entry.get("x", INVALID_CELL.x)), int(entry.get("y", INVALID_CELL.y)))
		var item_id: String = str(entry.get("item_id", ""))
		var layer_name: String = _normalize_layer_name(str(entry.get("layer", "")))
		if item_id == "" or not ItemCatalog.is_destructible_placeable(item_id):
			ignored += 1
			continue
		var layer: TileMapLayer = _layer_for_name(layer_name)
		# Validate every saved record against the actual live item at that cell.
		if layer == null or layer.get_cell_source_id(cell) < 0 or _live_item_id_at(layer, layer_name, cell) != item_id:
			ignored += 1
			continue
		var instant_destroy: bool = ItemCatalog.is_instant_destroy_placeable(item_id)
		var max_health: int = 1 if instant_destroy else maxi(1, int(entry.get("max_health", ItemCatalog.get_max_health(item_id))))
		var health: int = 1 if instant_destroy else clampi(int(entry.get("health", max_health)), 1, max_health)
		var key: String = _make_key(layer_name, cell)
		_targets_by_key[key] = {
			"key": key,
			"cell": cell,
			"item_id": item_id,
			"layer_name": layer_name,
			"health": health,
			"max_health": max_health,
			"instant_destroy": instant_destroy,
		}
		_add_cell_key(cell, key)
	if ignored > 0:
		push_warning("PlayerPlaceableDurabilityService: ignored %d stale/invalid durability records on load." % ignored)
	_bump_and_redraw()


# ---------------------------------------------------------------------------
# Internal helpers.
# ---------------------------------------------------------------------------
func _bump_and_redraw() -> void:
	_revision += 1
	if _overlay != null and is_instance_valid(_overlay) and _overlay.has_method("refresh"):
		_overlay.call("refresh")


func _add_cell_key(cell: Vector2i, key: String) -> void:
	var keys: Dictionary = _keys_by_cell.get(cell, {}) as Dictionary
	keys[key] = true
	_keys_by_cell[cell] = keys


func _register_live_destructible_target(layer: TileMapLayer, layer_name: String, cell: Vector2i) -> bool:
	if layer.get_cell_source_id(cell) < 0:
		return false
	var item_id: String = _live_item_id_at(layer, layer_name, cell)
	if item_id == "" or not ItemCatalog.is_destructible_placeable(item_id):
		return false
	var normalized_layer: String = _normalize_layer_name(layer_name)
	var key: String = _make_key(normalized_layer, cell)
	if _targets_by_key.has(key):
		return false
	var instant_destroy: bool = ItemCatalog.is_instant_destroy_placeable(item_id)
	var max_health: int = 1 if instant_destroy else maxi(1, ItemCatalog.get_max_health(item_id))
	_targets_by_key[key] = {
		"key": key,
		"cell": cell,
		"item_id": item_id,
		"layer_name": normalized_layer,
		"health": max_health,
		"max_health": max_health,
		"instant_destroy": instant_destroy,
	}
	_add_cell_key(cell, key)
	return true


func _register_live_reservoir_nodes() -> int:
	if _manager.floorz == null:
		return 0
	var added: int = 0
	for reservoir_node: Node in _manager.get_tree().get_nodes_in_group(RESERVOIR_GROUP):
		var reservoir: Node2D = reservoir_node as Node2D
		if reservoir == null or not is_instance_valid(reservoir):
			continue
		if reservoir.has_method("is_destroyed") and bool(reservoir.call("is_destroyed")):
			continue
		var cell: Vector2i = _manager.floorz.local_to_map(_manager.floorz.to_local(reservoir.global_position))
		var key: String = _make_key(RUNTIME_RESERVOIR_LAYER, cell)
		if _targets_by_key.has(key):
			continue
		var max_health: int = maxi(1, ItemCatalog.get_max_health(RESERVOIR_ITEM_ID))
		_targets_by_key[key] = {
			"key": key,
			"cell": cell,
			"item_id": RESERVOIR_ITEM_ID,
			"layer_name": RUNTIME_RESERVOIR_LAYER,
			"health": max_health,
			"max_health": max_health,
			"instant_destroy": false,
			"node": reservoir,
		}
		_add_cell_key(cell, key)
		added += 1
	return added


func _erase_records_at_cell(cell: Vector2i) -> bool:
	if not _keys_by_cell.has(cell):
		return false
	var keys: Dictionary = _keys_by_cell[cell] as Dictionary
	for raw_key: Variant in keys.keys():
		_targets_by_key.erase(str(raw_key))
	_keys_by_cell.erase(cell)
	return true


func _erase_record_by_key(key: String) -> void:
	if not _targets_by_key.has(key):
		return
	var rec: Dictionary = _targets_by_key[key] as Dictionary
	var cell: Vector2i = rec.get("cell", INVALID_CELL) as Vector2i
	_targets_by_key.erase(key)
	if _keys_by_cell.has(cell):
		var keys: Dictionary = _keys_by_cell[cell] as Dictionary
		keys.erase(key)
		if keys.is_empty():
			_keys_by_cell.erase(cell)
		else:
			_keys_by_cell[cell] = keys


func _make_key(layer_name: String, cell: Vector2i) -> String:
	return "%s:%d,%d" % [layer_name, cell.x, cell.y]


func _normalize_layer_name(layer_name: String) -> String:
	return "traversable_buildings" if layer_name == "buildings" else layer_name


func _layer_for_name(layer_name: String) -> TileMapLayer:
	match layer_name:
		"wallz":
			return _manager.wallz
		"plantz":
			return _manager.plantz
		"traversable_buildings":
			return _manager.traversable_buildings
		"blocking_buildings":
			return _manager.blocking_buildings
		"fences":
			return _manager.fences
	return null


func _live_item_id_at(layer: TileMapLayer, layer_name: String, cell: Vector2i) -> String:
	if layer_name == "blocking_buildings" or layer_name == "traversable_buildings" or layer_name == "fences":
		var building_object_manager: Node = _manager.get_building_object_manager()
		if building_object_manager != null and building_object_manager.has_method("get_building"):
			var building: Dictionary = building_object_manager.call("get_building", cell) as Dictionary
			var building_item_id: String = str(building.get("item_id", ""))
			if building_item_id != "":
				return building_item_id
	return ItemCatalog.get_placeable_id_for_tile(layer_name, layer.get_cell_atlas_coords(cell))


func _resolve_build_system() -> Node:
	if _build_system != null and is_instance_valid(_build_system):
		return _build_system
	var tree: SceneTree = _manager.get_tree()
	var scene: Node = tree.current_scene if tree != null else null
	if scene != null:
		_build_system = scene.get_node_or_null("Map/BuildSystem")
	return _build_system


func _cell_precedes(a: Vector2i, b: Vector2i) -> bool:
	if b == INVALID_CELL:
		return true
	if a.y != b.y:
		return a.y < b.y
	return a.x < b.x
