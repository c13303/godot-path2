extends Node


@export var floorz: TileMapLayer
@export var wallz: TileMapLayer
@export var plantz: TileMapLayer
@export var traversable_buildings: TileMapLayer
@export var blocking_buildings: TileMapLayer
@export var previewbuild: TileMapLayer
@export var plant_manager: Node
@export var building_object_manager: Node
@export var game_ui: CanvasLayer
@export var notif: Node
@export var occupied_groups: Array[String] = ["main_chars", "monsters", "player"]

var _atlas_source_id: int = -1

var _hover_active: bool = false
var _hover_cell: Vector2i
var _hover_atlas_coords: Vector2i = Vector2i(-1, -1)
var _plant_layer_flush_queued: bool = false

func _ready() -> void:
	_resolve_atlas_source_id()
	set_process(true)
	set_process_input(true)

func _process(_delta: float) -> void:
	var placeable_def: Dictionary = _selected_placeable_def()
	if _placement_disabled() or placeable_def.is_empty() or _is_inventory_open() or get_viewport().gui_get_hovered_control() != null:
		_clear_hover()
		return

	var cell: Vector2i = _hovered_cell()
	var atlas_coords: Vector2i = _atlas_coords_from_placeable(placeable_def)
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
	var placeable_def: Dictionary = _selected_placeable_def()
	if _placement_disabled() or placeable_def.is_empty() or _is_inventory_open() or get_viewport().gui_get_hovered_control() != null:
		return

	if event is InputEventMouseButton and event.pressed:
		var mouse_event: InputEventMouseButton = event
		if mouse_event.button_index == MOUSE_BUTTON_LEFT:
			_apply_placeable(placeable_def)
			get_viewport().set_input_as_handled()

func _resolve_atlas_source_id() -> void:
	var ref: TileMapLayer = previewbuild if previewbuild else wallz
	if not ref or not ref.tile_set:
		return

	var ts: TileSet = ref.tile_set
	for i in range(ts.get_source_count()):
		var sid: int = ts.get_source_id(i)
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

func _apply_placeable(placeable_def: Dictionary) -> void:
	if _atlas_source_id < 0:
		return
	var atlas_coords: Vector2i = _atlas_coords_from_placeable(placeable_def)
	if atlas_coords == Vector2i(-1, -1):
		return

	var target_layer: TileMapLayer = _target_tile_layer(str(placeable_def.get("target_layer", "wallz")))
	if not target_layer:
		return

	_hover_cell = _hovered_cell()
	if bool(placeable_def.get("requires_walkable_floor", false)) and not _is_free_walkable_cell(_hover_cell):
		_notify("invalid construction")
		return
	if _is_placeable_occupied(_hover_cell, target_layer, placeable_def):
		_notify("invalid construction")
		return

	_clear_other_build_layer(target_layer, _hover_cell)
	target_layer.set_cell(
		_hover_cell,
		_atlas_source_id,
		atlas_coords,
		0
	)
	target_layer.update_internals()
	_after_placeable_placed(_hover_cell, placeable_def)
	_consume_placed_item(str(placeable_def.get("id", "")))

func _consume_placed_item(item_id: String) -> void:
	if item_id == "" or not game_ui or not game_ui.has_method("consume_selected_quick_item"):
		return
	game_ui.call("consume_selected_quick_item", item_id)

func _target_tile_layer(layer_name: String) -> TileMapLayer:
	if layer_name == "plantz":
		return plantz
	if layer_name == "traversable_buildings":
		return traversable_buildings
	if layer_name == "blocking_buildings":
		return blocking_buildings
	# Backward compatibility: old "buildings" target maps to traversable_buildings.
	if layer_name == "buildings":
		return traversable_buildings
	return wallz

func _clear_other_build_layer(target_layer: TileMapLayer, cell: Vector2i) -> void:
	if target_layer != wallz and wallz:
		wallz.erase_cell(cell)
		wallz.update_internals()
	if target_layer != plantz and plantz:
		plantz.erase_cell(cell)
		_flush_plant_layer_visuals()
		if plant_manager and plant_manager.has_method("remove_plant"):
			plant_manager.call("remove_plant", cell, false)
	if target_layer != traversable_buildings and traversable_buildings:
		traversable_buildings.erase_cell(cell)
		traversable_buildings.update_internals()
		if building_object_manager and building_object_manager.has_method("remove_building"):
			building_object_manager.call("remove_building", cell, false)
	if target_layer != blocking_buildings and blocking_buildings:
		blocking_buildings.erase_cell(cell)
		blocking_buildings.update_internals()
		if building_object_manager and building_object_manager.has_method("remove_building"):
			building_object_manager.call("remove_building", cell, false)

# True only when `cell` is a real floor tile with no blocking wall on it. Used by
# placeables (e.g. turret1) that may only be built on free walkable ground. This is
# a placement-time guard; it does not affect navigation/flowfields.
func _is_free_walkable_cell(cell: Vector2i) -> bool:
	if floorz and floorz.get_cell_source_id(cell) < 0:
		return false
	if wallz and wallz.get_cell_source_id(cell) >= 0:
		return false
	return true

func _is_placeable_occupied(cell: Vector2i, target_layer: TileMapLayer, placeable_def: Dictionary) -> bool:
	if bool(placeable_def.get("occupies_cell", true)) and target_layer.get_cell_source_id(cell) >= 0:
		return true
	if wallz and wallz != target_layer and wallz.get_cell_source_id(cell) >= 0:
		return true
	if plantz and plantz != target_layer and plantz.get_cell_source_id(cell) >= 0:
		return true
	if traversable_buildings and traversable_buildings != target_layer and traversable_buildings.get_cell_source_id(cell) >= 0:
		return true
	if blocking_buildings and blocking_buildings != target_layer and blocking_buildings.get_cell_source_id(cell) >= 0:
		return true
	return _is_occupied_by_group_node(cell)

func _after_placeable_placed(cell: Vector2i, placeable_def: Dictionary) -> void:
	var placeable_category: String = str(placeable_def.get("category", ""))
	if placeable_category == "plant" and plant_manager and plant_manager.has_method("add_plant"):
		plant_manager.call("add_plant", cell)
	if _uses_building_object_manager(placeable_def) and building_object_manager and building_object_manager.has_method("add_building"):
		building_object_manager.call("add_building", cell, placeable_def)

func _uses_building_object_manager(placeable_def: Dictionary) -> bool:
	var placeable_category: String = str(placeable_def.get("category", ""))
	var light_source: float = float(placeable_def.get("light_source", 0.0))
	if light_source > 0.0:
		return true
	return placeable_category == "furniture" or placeable_category == "turret" or placeable_category == "trap"

func _is_occupied_by_group_node(cell: Vector2i) -> bool:
	var map_layer: TileMapLayer = previewbuild if previewbuild else wallz
	if not map_layer:
		return false
	for group_name in occupied_groups:
		var nodes: Array[Node] = get_tree().get_nodes_in_group(group_name)
		for node in nodes:
			if node is Node2D:
				var occupant: Node2D = node as Node2D
				var occupant_cell: Vector2i = map_layer.local_to_map(map_layer.to_local(occupant.global_position))
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
	var world: Vector2 = previewbuild.get_global_mouse_position()
	return previewbuild.local_to_map(previewbuild.to_local(world))

func _flush_plant_layer_visuals() -> void:
	if not plantz:
		return
	plantz.update_internals()
	plantz.queue_redraw()
	if _plant_layer_flush_queued:
		return
	_plant_layer_flush_queued = true
	call_deferred("_flush_plant_layer_visuals_deferred")

func _flush_plant_layer_visuals_deferred() -> void:
	_plant_layer_flush_queued = false
	if not plantz:
		return
	plantz.update_internals()
	plantz.queue_redraw()

func _selected_placeable_def() -> Dictionary:
	if not game_ui or not game_ui.has_method("get_selected_quick_item_id"):
		return {}
	if _placement_disabled():
		return {}
	return ItemCatalog.get_placeable_def(String(game_ui.call("get_selected_quick_item_id")))

func _is_inventory_open() -> bool:
	return game_ui and game_ui.has_method("is_inventory_open") and bool(game_ui.call("is_inventory_open"))

func _placement_disabled() -> bool:
	return GameState.is_night

func _atlas_coords_from_placeable(placeable_def: Dictionary) -> Vector2i:
	var raw: Variant = placeable_def.get("atlas", Vector2i(-1, -1))
	if raw is Vector2i:
		return raw
	if raw is Vector2:
		return Vector2i(int(raw.x), int(raw.y))
	if raw is Array and raw.size() == 2:
		return Vector2i(int(raw[0]), int(raw[1]))
	return Vector2i(-1, -1)
