extends RefCounted
class_name BuildRemovalService

# Owns unbuild/removal target detection and removal commits. BuildSystem keeps
# input handling, hold timing, drag state, preview bars, and UI-facing API.

const PLAYER_BUILDABLE_WALL_ATLAS: Vector2i = Vector2i(11, 1)

var _manager: BuildSystem
var _wallz_layer: TileMapLayer
var _plantz_layer: TileMapLayer
var _traversable_buildings_layer: TileMapLayer
var _blocking_buildings_layer: TileMapLayer
var _fences_layer: TileMapLayer
var _previewbuild_layer: TileMapLayer
var _plant_manager_node: Node
var _building_object_manager_node: Node
var _reservoir_system_node: Node
var _game_ui_layer: CanvasLayer


func setup(manager: BuildSystem) -> void:
	_manager = manager
	_wallz_layer = manager.wallz
	_plantz_layer = manager.plantz
	_traversable_buildings_layer = manager.traversable_buildings
	_blocking_buildings_layer = manager.blocking_buildings
	_fences_layer = manager.fences
	_previewbuild_layer = manager.previewbuild
	_plant_manager_node = manager.plant_manager
	_building_object_manager_node = manager.building_object_manager
	_reservoir_system_node = manager.reservoir_system
	_game_ui_layer = manager.game_ui


func try_remove_at_cell(cell: Vector2i) -> bool:
	var removal: Dictionary = removable_at_cell(cell)
	if removal.is_empty():
		return false
	return commit_removal(removal)


func commit_removal(removal: Dictionary) -> bool:
	if bool(removal.get("is_house", false)):
		return _commit_house_removal(removal)
	var cell: Vector2i = removal.get("cell", Vector2i.ZERO) as Vector2i
	var item_id: String = str(removal.get("item_id", ""))
	var layer: TileMapLayer = removal.get("layer") as TileMapLayer
	if layer == null or item_id == "":
		return false

	var current_removal: Dictionary = removable_at_cell(cell)
	if current_removal.is_empty() or str(current_removal.get("item_id", "")) != item_id:
		return false

	remove_tile(layer, cell, item_id)
	var game_ui: CanvasLayer = _game_ui()
	if game_ui and game_ui.has_method("refund_build"):
		game_ui.call("refund_build", item_id, refund_world_position(cell), 1)
	return true


# Normal unbuild of one complete player-built house (resolved from any of its six presence cells).
# HouseManager tears the whole house down atomically; one house item is refunded to the inventory
# (never five wall items, never money). Authored houses are not player-built and never reach here.
func _commit_house_removal(removal: Dictionary) -> bool:
	var entrance: Vector2i = removal.get("cell", Vector2i.ZERO) as Vector2i
	var house_id: String = str(removal.get("house_id", ""))
	var house_manager: HouseManager = _house_manager()
	if house_manager == null:
		return false
	# Re-resolve against the live registry so a stale queued removal cannot fire twice.
	var current: Dictionary = _house_removable_at_cell(entrance)
	if current.is_empty() or str(current.get("house_id", "")) != house_id:
		return false
	if not house_manager.remove_player_built_house(entrance):
		return false
	var game_ui: CanvasLayer = _game_ui()
	if game_ui and game_ui.has_method("refund_build"):
		game_ui.call("refund_build", "house", refund_world_position(entrance), 1)
	return true


# Resolves the complete logical house from any hovered presence cell (walls OR walkable entrance),
# normalized to a single removal keyed by its entrance so five wall cells never queue five removals.
# Only player-built, removable houses qualify (authored houses such as house_seedmerchant do not).
func _house_removable_at_cell(cell: Vector2i) -> Dictionary:
	var house_manager: HouseManager = _house_manager()
	if house_manager == null:
		return {}
	var record: HouseManager.HouseRecord = house_manager.get_house_at_presence_cell(cell)
	if record == null or not record.player_built or not record.removable:
		return {}
	return {
		"item_id": record.item_id,
		"cell": record.entrance_cell,
		"is_house": true,
		"house_id": String(record.id),
	}


func _house_manager() -> HouseManager:
	if _manager != null and _manager.has_method("get_house_manager"):
		return _manager.get_house_manager()
	return null


func refund_world_position(cell: Vector2i) -> Vector2:
	var previewbuild: TileMapLayer = _previewbuild()
	if previewbuild == null:
		return Vector2.ZERO
	return previewbuild.to_global(previewbuild.map_to_local(cell))


func remove_tile(layer: TileMapLayer, cell: Vector2i, item_id: String = "") -> void:
	# Central removal path (normal unbuild AND hostile no-refund destruction): drop any
	# player-built provenance for this layer/cell before the tile is erased. Idempotent,
	# so a hostile destruction that already removed the durability record is a no-op here.
	if _manager != null and _manager.has_method("unregister_player_placeable"):
		_manager.call("unregister_player_placeable", cell, str(layer.name))
	var plantz: TileMapLayer = _plantz()
	if layer == plantz:
		var plant_manager: Node = _plant_manager()
		if plant_manager and plant_manager.has_method("remove_plant"):
			plant_manager.call("remove_plant", cell, true)
		if plantz.get_cell_source_id(cell) >= 0:
			plantz.erase_cell(cell)
			_flush_plant_layer_visuals()
		_refresh_cell_terrain_speed(cell)
		return

	var traversable_buildings: TileMapLayer = _traversable_buildings()
	var blocking_buildings: TileMapLayer = _blocking_buildings()
	var fences: TileMapLayer = _fences()
	if layer == traversable_buildings or layer == blocking_buildings or layer == fences:
		clear_pasteque_irrigation_before_unbuild(layer, cell)
		var building_object_manager: Node = _building_object_manager()
		if building_object_manager and building_object_manager.has_method("remove_building"):
			building_object_manager.call("remove_building", cell, true)
		if layer.get_cell_source_id(cell) >= 0:
			layer.erase_cell(cell)
			layer.update_internals()
		_refresh_cell_collision(cell)
		_refresh_cell_terrain_speed(cell)
		if removed_tile_affects_navigation(layer, item_id):
			_notify_navigation_topology_changed(cell, "placeable_removed")
		if layer == fences:
			_refresh_fence_autotiles_around(cell)
		return

	layer.erase_cell(cell)
	layer.update_internals()
	_refresh_cell_collision(cell)
	_refresh_cell_terrain_speed(cell)
	if layer == _wallz():
		_notify_navigation_topology_changed(cell, "wall_removed")


# True only when removing this tile is a genuine hard-topology change. Turrets and other
# speed-only placeables return false: their slowdown is cleared live via
# _refresh_cell_terrain_speed. Fences resolve by the current phase.
func removed_tile_affects_navigation(layer: TileMapLayer, item_id: String) -> bool:
	var layer_role: String = _nav_layer_role(layer)
	var item_def: Dictionary = ItemCatalog.get_item_def(item_id) if item_id != "" else {}
	var impact: PlaceableNavImpact.Impact = PlaceableNavImpact.classify_for_layer(layer_role, item_def)
	return PlaceableNavImpact.requires_hard_topology(impact, _fences_block_navigation())


func _nav_layer_role(layer: TileMapLayer) -> String:
	if layer == _wallz():
		return PlaceableNavImpact.LAYER_WALLZ
	if layer == _fences():
		return PlaceableNavImpact.LAYER_FENCES
	if layer == _blocking_buildings():
		return PlaceableNavImpact.LAYER_BLOCKING
	return "other"


func _fences_block_navigation() -> bool:
	if _manager != null and _manager.has_method("fences_currently_block_navigation"):
		return bool(_manager.call("fences_currently_block_navigation"))
	return true


func clear_pasteque_irrigation_before_unbuild(layer: TileMapLayer, cell: Vector2i) -> void:
	var traversable_buildings: TileMapLayer = _traversable_buildings()
	if layer != traversable_buildings:
		return
	var item_id: String = ""
	var building_object_manager: Node = _building_object_manager()
	if building_object_manager and building_object_manager.has_method("get_building"):
		var building: Dictionary = building_object_manager.call("get_building", cell) as Dictionary
		item_id = str(building.get("item_id", ""))
	if item_id == "" and layer.get_cell_source_id(cell) >= 0:
		item_id = ItemCatalog.get_placeable_id_for_tile(str(layer.name), layer.get_cell_atlas_coords(cell))
	if item_id != "pasteque":
		return
	var reservoir_system: Node = _reservoir_system()
	if reservoir_system != null and reservoir_system.has_method("clear_pasteque_irrigation_from_cell"):
		reservoir_system.call("clear_pasteque_irrigation_from_cell", cell)


func removable_at_cell(cell: Vector2i) -> Dictionary:
	# Houses are resolved first and from any presence cell, since the entrance has no wall tile and
	# the invisible blocker atlas must not identify the logical house (see AGENTS.md).
	var house_removal: Dictionary = _house_removable_at_cell(cell)
	if not house_removal.is_empty():
		return house_removal
	var logical_plant_removal: Dictionary = logical_plant_removable_at_cell(cell)
	if not logical_plant_removal.is_empty():
		return logical_plant_removal
	var blocking_buildings: TileMapLayer = _blocking_buildings()
	var fences: TileMapLayer = _fences()
	var traversable_buildings: TileMapLayer = _traversable_buildings()
	var layers: Array[TileMapLayer] = [blocking_buildings, fences, traversable_buildings, _plantz(), _wallz()]
	var building_object_manager: Node = _building_object_manager()
	for layer: TileMapLayer in layers:
		if not layer or layer.get_cell_source_id(cell) < 0:
			continue
		var atlas_coords: Vector2i = layer.get_cell_atlas_coords(cell)
		var item_id: String = ItemCatalog.get_placeable_id_for_tile(str(layer.name), atlas_coords)
		var uses_building_object_manager: bool = (
			layer == blocking_buildings
			or layer == traversable_buildings
			or layer == fences
		)
		if building_object_manager and building_object_manager.has_method("get_building") and uses_building_object_manager:
			var building: Dictionary = building_object_manager.call("get_building", cell) as Dictionary
			item_id = str(building.get("item_id", item_id))
		if item_id != "" and can_unbuild_tile(layer, item_id, atlas_coords):
			return {"item_id": item_id, "layer": layer, "cell": cell}
	return {}


func logical_plant_removable_at_cell(cell: Vector2i) -> Dictionary:
	var plant_manager: Node = _plant_manager()
	var plantz: TileMapLayer = _plantz()
	if plant_manager == null or plantz == null:
		return {}
	if not plant_manager.has_method("get_plant_kind"):
		return {}
	var plant_kind: String = str(plant_manager.call("get_plant_kind", cell))
	if plant_kind == "imperial":
		return {"item_id": "imperial_seed", "layer": plantz, "cell": cell}
	return {}


func can_unbuild_tile(layer: TileMapLayer, item_id: String, atlas_coords: Vector2i) -> bool:
	if layer == _wallz():
		return item_id == "wall" and atlas_coords == PLAYER_BUILDABLE_WALL_ATLAS
	return true


func remove_rectangle_cells(start_cell: Vector2i, end_cell: Vector2i) -> Array[Dictionary]:
	var removals: Array[Dictionary] = []
	var seen_cells: Dictionary = {}
	# One house is one logical removal even when several of its footprint cells fall in the rect,
	# so it is refunded once, not once per wall cell.
	var seen_houses: Dictionary = {}
	var x_step: int = 1 if end_cell.x >= start_cell.x else -1
	var y_step: int = 1 if end_cell.y >= start_cell.y else -1
	var y: int = start_cell.y
	while true:
		var x: int = start_cell.x
		while true:
			var cell: Vector2i = Vector2i(x, y)
			if not seen_cells.has(cell):
				var removal: Dictionary = removable_at_cell(cell)
				if not removal.is_empty():
					seen_cells[cell] = true
					if bool(removal.get("is_house", false)):
						var house_id: String = str(removal.get("house_id", ""))
						if not seen_houses.has(house_id):
							seen_houses[house_id] = true
							removals.append(removal)
					else:
						removals.append(removal)
			if x == end_cell.x:
				break
			x += x_step
		if y == end_cell.y:
			break
		y += y_step
	return removals


func _refresh_cell_collision(cell: Vector2i) -> void:
	if _manager != null:
		_manager._refresh_cell_collision(cell)


func _notify_navigation_topology_changed(cell: Vector2i, reason: String) -> void:
	if _manager != null:
		_manager._notify_navigation_topology_changed(cell, reason)


func _refresh_cell_terrain_speed(cell: Vector2i) -> void:
	if _manager != null:
		_manager._refresh_cell_terrain_speed(cell)


func _refresh_fence_autotiles_around(cell: Vector2i) -> void:
	if _manager != null:
		_manager._refresh_fence_autotiles_around(cell)


func _flush_plant_layer_visuals() -> void:
	if _manager != null:
		_manager._flush_plant_layer_visuals()


func _wallz() -> TileMapLayer:
	return _wallz_layer


func _plantz() -> TileMapLayer:
	return _plantz_layer


func _traversable_buildings() -> TileMapLayer:
	return _traversable_buildings_layer


func _blocking_buildings() -> TileMapLayer:
	return _blocking_buildings_layer


func _fences() -> TileMapLayer:
	return _fences_layer


func _previewbuild() -> TileMapLayer:
	return _previewbuild_layer


func _plant_manager() -> Node:
	return _plant_manager_node


func _building_object_manager() -> Node:
	return _building_object_manager_node


func _reservoir_system() -> Node:
	return _reservoir_system_node


func _game_ui() -> CanvasLayer:
	return _game_ui_layer
