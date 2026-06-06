extends Node


@export var wallz: TileMapLayer
@export var plantz: TileMapLayer
@export var buildings: TileMapLayer
@export var previewbuild: TileMapLayer
@export var plant_manager: Node
@export var game_ui: CanvasLayer
@export var notif: Node
@export var occupied_groups: Array[String] = ["main_chars", "monsters", "player"]

var _atlas_source_id: int = -1

var _hover_active: bool = false
var _hover_cell: Vector2i
var _hover_atlas_coords: Vector2i = Vector2i(-1, -1)

func _ready() -> void:
	_resolve_atlas_source_id()
	set_process(true)
	set_process_input(true)

func _process(_delta: float) -> void:
	var place_tile := _selected_place_tile()
	if place_tile.is_empty() or _is_inventory_open() or get_viewport().gui_get_hovered_control() != null:
		_clear_hover()
		return

	var cell := _hovered_cell()
	var atlas_coords := _atlas_coords_from_place_tile(place_tile)
	if atlas_coords == Vector2i(-1, -1):
		_clear_hover()
		return

	if _hover_active and cell == _hover_cell and atlas_coords == _hover_atlas_coords:
		return

	_clear_hover()
	_hover_cell = cell
	_hover_atlas_coords = atlas_coords
	_hover_active = true
	_draw_preview(cell, atlas_coords)

func _input(event: InputEvent) -> void:
	var place_tile := _selected_place_tile()
	if place_tile.is_empty() or _is_inventory_open() or get_viewport().gui_get_hovered_control() != null:
		return

	if event is InputEventMouseButton and event.pressed:
		var mouse_event: InputEventMouseButton = event
		if mouse_event.button_index == MOUSE_BUTTON_LEFT:
			_apply_place_tile(place_tile)
			get_viewport().set_input_as_handled()

func _resolve_atlas_source_id() -> void:
	var ref := previewbuild if previewbuild else wallz
	if not ref or not ref.tile_set:
		return

	var ts := ref.tile_set
	for i in range(ts.get_source_count()):
		var sid := ts.get_source_id(i)
		if ts.get_source(sid) is TileSetAtlasSource:
			_atlas_source_id = sid
			return

func _draw_preview(cell: Vector2i, atlas_coords: Vector2i) -> void:
	if _atlas_source_id < 0:
		return

	previewbuild.set_cell(
		cell,
		_atlas_source_id,
		atlas_coords,
		0
	)
	previewbuild.update_internals()

func _apply_place_tile(place_tile: Dictionary) -> void:
	if _atlas_source_id < 0:
		return
	var atlas_coords := _atlas_coords_from_place_tile(place_tile)
	if atlas_coords == Vector2i(-1, -1):
		return

	var target_layer := _target_tile_layer(str(place_tile.get("layer", "wallz")))
	if not target_layer:
		return

	_hover_cell = _hovered_cell()
	if _is_tile_occupied(_hover_cell, target_layer):
		_notify("invalid construction")
		return

	_clear_other_build_layer(target_layer)
	target_layer.set_cell(
		_hover_cell,
		_atlas_source_id,
		atlas_coords,
		0
	)
	target_layer.update_internals()
	if target_layer == plantz and plant_manager and plant_manager.has_method("add_plant"):
		plant_manager.call("add_plant", _hover_cell)

func _target_tile_layer(layer_name: String) -> TileMapLayer:
	if layer_name == "plantz":
		return plantz
	if layer_name == "buildings":
		return buildings
	return wallz

func _clear_other_build_layer(target_layer: TileMapLayer) -> void:
	if target_layer != wallz and wallz:
		wallz.erase_cell(_hover_cell)
		wallz.update_internals()
	if target_layer != plantz and plantz:
		plantz.erase_cell(_hover_cell)
		plantz.update_internals()
		if plant_manager and plant_manager.has_method("remove_plant"):
			plant_manager.call("remove_plant", _hover_cell, false)
	if target_layer != buildings and buildings:
		buildings.erase_cell(_hover_cell)
		buildings.update_internals()

func _is_tile_occupied(cell: Vector2i, target_layer: TileMapLayer) -> bool:
	if target_layer.get_cell_source_id(cell) >= 0:
		return true
	if wallz and wallz != target_layer and wallz.get_cell_source_id(cell) >= 0:
		return true
	if plantz and plantz != target_layer and plantz.get_cell_source_id(cell) >= 0:
		return true
	if buildings and buildings != target_layer and buildings.get_cell_source_id(cell) >= 0:
		return true
	return _is_occupied_by_group_node(cell)

func _is_occupied_by_group_node(cell: Vector2i) -> bool:
	var map_layer := previewbuild if previewbuild else wallz
	if not map_layer:
		return false
	for group_name in occupied_groups:
		var nodes := get_tree().get_nodes_in_group(group_name)
		for node in nodes:
			if node is Node2D:
				var occupant := node as Node2D
				var occupant_cell := map_layer.local_to_map(map_layer.to_local(occupant.global_position))
				if occupant_cell == cell:
					return true
	return false

func _notify(message: String) -> void:
	if not notif:
		return
	if notif.has_method("show_notif"):
		notif.call("show_notif", message)

func _clear_hover() -> void:
	if not _hover_active:
		return
	previewbuild.erase_cell(_hover_cell)
	previewbuild.update_internals()
	_hover_active = false
	_hover_atlas_coords = Vector2i(-1, -1)

func _hovered_cell() -> Vector2i:
	var world := previewbuild.get_global_mouse_position()
	return previewbuild.local_to_map(previewbuild.to_local(world))

func _selected_place_tile() -> Dictionary:
	if not game_ui or not game_ui.has_method("get_selected_quick_item_id"):
		return {}
	return ItemCatalog.get_place_tile(String(game_ui.call("get_selected_quick_item_id")))

func _is_inventory_open() -> bool:
	return game_ui and game_ui.has_method("is_inventory_open") and bool(game_ui.call("is_inventory_open"))

func _atlas_coords_from_place_tile(place_tile: Dictionary) -> Vector2i:
	var raw: Variant = place_tile.get("atlas", Vector2i(-1, -1))
	if raw is Vector2i:
		return raw
	if raw is Vector2:
		return Vector2i(int(raw.x), int(raw.y))
	if raw is Array and raw.size() == 2:
		return Vector2i(int(raw[0]), int(raw[1]))
	return Vector2i(-1, -1)
