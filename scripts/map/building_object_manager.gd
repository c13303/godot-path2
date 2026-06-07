extends Node
class_name BuildingObjectManager

signal building_added(cell: Vector2i, item_id: String)
signal building_removed(cell: Vector2i, item_id: String)

@export var buildings: TileMapLayer
@export var runtime_parent: Node2D

var _buildings_by_cell: Dictionary = {}
var _runtime_nodes_by_cell: Dictionary = {}

func _ready() -> void:
	initialize_from_layer()

func initialize_from_layer() -> void:
	_buildings_by_cell.clear()
	_clear_runtime_nodes()
	if not buildings:
		return
	for raw_cell in buildings.get_used_cells():
		var cell: Vector2i = raw_cell
		var item_def: Dictionary = _default_building_def_for_existing_tile(cell)
		if not item_def.is_empty():
			add_building(cell, item_def)

func add_building(cell: Vector2i, item_def: Dictionary) -> void:
	var item_id: String = str(item_def.get("id", ""))
	var building_subtype: String = str(item_def.get("building_subtype", ""))
	var runtime_id: String = str(item_def.get("runtime_id", item_id))
	if item_id == "":
		return
	if _buildings_by_cell.has(cell):
		remove_building(cell)
	_buildings_by_cell[cell] = {
		"item_id": item_id,
		"runtime_id": runtime_id,
		"building_subtype": building_subtype,
	}
	if building_subtype == "lamp":
		_register_lamp_runtime(cell)
	building_added.emit(cell, item_id)

func remove_building(cell: Vector2i, erase_tile: bool = false) -> void:
	if not _buildings_by_cell.has(cell):
		return
	var data: Dictionary = _buildings_by_cell[cell] as Dictionary
	var item_id: String = str(data.get("item_id", ""))
	_buildings_by_cell.erase(cell)
	_remove_runtime_node(cell)
	if erase_tile and buildings:
		buildings.erase_cell(cell)
		buildings.update_internals()
	building_removed.emit(cell, item_id)

func get_building(cell: Vector2i) -> Dictionary:
	if not _buildings_by_cell.has(cell):
		return {}
	return _buildings_by_cell[cell] as Dictionary

func has_building(cell: Vector2i) -> bool:
	return _buildings_by_cell.has(cell)

func clear() -> void:
	_buildings_by_cell.clear()
	_clear_runtime_nodes()

func _register_lamp_runtime(cell: Vector2i) -> void:
	var parent: Node2D = _runtime_parent()
	if not parent:
		return
	var marker: Node2D = Node2D.new()
	marker.name = "Lamp_%d_%d" % [cell.x, cell.y]
	marker.global_position = _cell_center(cell)
	parent.add_child(marker)
	_runtime_nodes_by_cell[cell] = marker

func _runtime_parent() -> Node2D:
	if runtime_parent:
		return runtime_parent
	if get_parent() is Node2D:
		return get_parent() as Node2D
	return null

func _cell_center(cell: Vector2i) -> Vector2:
	if buildings:
		return buildings.to_global(buildings.map_to_local(cell))
	return Vector2(float(cell.x), float(cell.y))

func _remove_runtime_node(cell: Vector2i) -> void:
	if not _runtime_nodes_by_cell.has(cell):
		return
	var node: Node = _runtime_nodes_by_cell[cell] as Node
	_runtime_nodes_by_cell.erase(cell)
	if node and is_instance_valid(node):
		node.queue_free()

func _clear_runtime_nodes() -> void:
	for raw_node in _runtime_nodes_by_cell.values():
		var node: Node = raw_node as Node
		if node and is_instance_valid(node):
			node.queue_free()
	_runtime_nodes_by_cell.clear()

func _default_building_def_for_existing_tile(_cell: Vector2i) -> Dictionary:
	if not buildings:
		return {}
	var atlas: Vector2i = buildings.get_cell_atlas_coords(_cell)
	for raw_item_def in ItemCatalog.ITEM_DEFS.values():
		var item_def: Dictionary = raw_item_def as Dictionary
		if str(item_def.get("item_type", "")) != "placeable":
			continue
		if str(item_def.get("placeable_kind", "")) != "building":
			continue
		if str(item_def.get("target_layer", "")) != "buildings":
			continue
		var item_atlas: Vector2i = _atlas_coords_from_item_def(item_def)
		if item_atlas == atlas:
			return item_def
	return {}

func _atlas_coords_from_item_def(item_def: Dictionary) -> Vector2i:
	var raw: Variant = item_def.get("atlas", Vector2i(-1, -1))
	if raw is Vector2i:
		return raw
	if raw is Vector2:
		return Vector2i(int(raw.x), int(raw.y))
	if raw is Array and raw.size() == 2:
		return Vector2i(int(raw[0]), int(raw[1]))
	return Vector2i(-1, -1)
