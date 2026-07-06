extends RefCounted
class_name BuildRemovalService

# Owns unbuild/removal target detection and removal commits. BuildSystem keeps
# input handling, hold timing, drag state, preview bars, and UI-facing API.

const PLAYER_BUILDABLE_WALL_ATLAS: Vector2i = Vector2i(11, 1)

var _manager: Node


func setup(manager: Node) -> void:
	_manager = manager


func try_remove_at_cell(cell: Vector2i) -> bool:
	var removal: Dictionary = removable_at_cell(cell)
	if removal.is_empty():
		return false
	return commit_removal(removal)


func commit_removal(removal: Dictionary) -> bool:
	var cell: Vector2i = removal.get("cell", Vector2i.ZERO) as Vector2i
	var item_id: String = str(removal.get("item_id", ""))
	var layer: TileMapLayer = removal.get("layer") as TileMapLayer
	if layer == null or item_id == "":
		return false

	var current_removal: Dictionary = removable_at_cell(cell)
	if current_removal.is_empty() or str(current_removal.get("item_id", "")) != item_id:
		return false

	remove_tile(layer, cell)
	var game_ui: CanvasLayer = _game_ui()
	if game_ui and game_ui.has_method("refund_build"):
		game_ui.call("refund_build", item_id, refund_world_position(cell), 1)
	return true


func refund_world_position(cell: Vector2i) -> Vector2:
	var previewbuild: TileMapLayer = _previewbuild()
	if previewbuild == null:
		return Vector2.ZERO
	return previewbuild.to_global(previewbuild.map_to_local(cell))


func remove_tile(layer: TileMapLayer, cell: Vector2i) -> void:
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
		if layer == fences:
			_refresh_fence_autotiles_around(cell)
		return

	layer.erase_cell(cell)
	layer.update_internals()
	_refresh_cell_collision(cell)
	_refresh_cell_terrain_speed(cell)


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


func can_unbuild_tile(layer: TileMapLayer, item_id: String, atlas_coords: Vector2i) -> bool:
	if layer == _wallz():
		return item_id == "wall" and atlas_coords == PLAYER_BUILDABLE_WALL_ATLAS
	return true


func remove_rectangle_cells(start_cell: Vector2i, end_cell: Vector2i) -> Array[Dictionary]:
	var removals: Array[Dictionary] = []
	var seen_cells: Dictionary = {}
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
					removals.append(removal)
					seen_cells[cell] = true
			if x == end_cell.x:
				break
			x += x_step
		if y == end_cell.y:
			break
		y += y_step
	return removals


func _refresh_cell_collision(cell: Vector2i) -> void:
	if _manager != null:
		_manager.call("_refresh_cell_collision", cell)


func _refresh_cell_terrain_speed(cell: Vector2i) -> void:
	if _manager != null:
		_manager.call("_refresh_cell_terrain_speed", cell)


func _refresh_fence_autotiles_around(cell: Vector2i) -> void:
	if _manager != null:
		_manager.call("_refresh_fence_autotiles_around", cell)


func _flush_plant_layer_visuals() -> void:
	if _manager != null:
		_manager.call("_flush_plant_layer_visuals")


func _wallz() -> TileMapLayer:
	return _manager.get("wallz") as TileMapLayer


func _plantz() -> TileMapLayer:
	return _manager.get("plantz") as TileMapLayer


func _traversable_buildings() -> TileMapLayer:
	return _manager.get("traversable_buildings") as TileMapLayer


func _blocking_buildings() -> TileMapLayer:
	return _manager.get("blocking_buildings") as TileMapLayer


func _fences() -> TileMapLayer:
	return _manager.get("fences") as TileMapLayer


func _previewbuild() -> TileMapLayer:
	return _manager.get("previewbuild") as TileMapLayer


func _plant_manager() -> Node:
	return _manager.get("plant_manager") as Node


func _building_object_manager() -> Node:
	return _manager.get("building_object_manager") as Node


func _reservoir_system() -> Node:
	return _manager.get("reservoir_system") as Node


func _game_ui() -> CanvasLayer:
	return _manager.get("game_ui") as CanvasLayer
