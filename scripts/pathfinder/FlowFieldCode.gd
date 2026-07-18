extends Node2D

signal flow_field_ready
signal loading_progress(progress: float, label: String)

@onready var ff: FlowFieldNative = get_parent()
@onready var floor_layer: TileMapLayer = $"../../../Map/MonTilemap/floor"
@onready var wall_layer: TileMapLayer = $"../../../Map/MonTilemap/wallz"
@onready var water_layer: TileMapLayer = $"../../../Map/MonTilemap/watersources"

const ONE_WAY_DIRECTIONS: Dictionary = {
	Vector2i(12, 8): Vector2i.UP,
	Vector2i(13, 8): Vector2i.DOWN,
	Vector2i(14, 8): Vector2i.LEFT,
	Vector2i(15, 8): Vector2i.RIGHT,
}

var is_ready: bool = false

func _ready() -> void:
	
	
	CppDebugOptions.dlog(">>> FlowFieldCode.gd _ready() triggered <<<")
	loading_progress.emit(0.05, "Preparing navigation")

	await get_tree().process_frame

	CppDebugOptions.dlog("FlowFieldCode: _ready() called")

	if ff == null:
		print("FlowFieldCode: FlowFieldNative node not found.")
		return

	#print("FlowFieldCode: assigning layers...")
	ff.set_floor_layer(floor_layer)
	ff.set_wall_layer(wall_layer)
	if ff.has_method("set_navigation_blocking_layer"):
		ff.call("set_navigation_blocking_layer", water_layer)
	elif ff.has_method("set_water_layer"):
		ff.call("set_water_layer", water_layer)
	_apply_authored_map_bounds()
	_register_client_one_way_tiles()
	loading_progress.emit(0.15, "Reading map layers")

	#print("floor_layer:", floor_layer)
	#print("wall_layer:", wall_layer)



	await get_tree().process_frame

	# The default field is required immediately by manual player steering for hard
	# wall collision and wall correction. Monster group flow fields remain lazy and
	# are prepared separately by BuildingManager when night starts.
	loading_progress.emit(0.25, "Computing wall collisions")
	await get_tree().process_frame
	ff.compute_distance_field_global()
	is_ready = true
	loading_progress.emit(0.45, "Flow field ready")
	flow_field_ready.emit()
	CppDebugOptions.dlog("FlowFieldCode: initialization complete--------------------------------")


# The authored map extent (mapBounds) defines the native field's size/origin, replacing
# the floor layer's used-rect. Must run before compute_distance_field_global(). Guarded so
# levels without a mapBounds node, or older DLLs without set_map_bounds, keep the previous
# floor-derived extent.
func _apply_authored_map_bounds() -> void:
	if not ff.has_method("set_map_bounds"):
		return
	var loader: Node = get_tree().current_scene.get_node_or_null("LevelLoader") if get_tree().current_scene else null
	if loader == null or not loader.has_method("get_loaded_map_bounds_cells"):
		return
	var bounds: Rect2i = loader.call("get_loaded_map_bounds_cells")
	if bounds.size.x <= 0 or bounds.size.y <= 0:
		return
	ff.set_map_bounds(bounds)


func _register_client_one_way_tiles() -> void:
	if not ff.has_method("set_directional_traversal_field"):
		return
	var scene: Node = get_tree().current_scene
	var special_tiles: TileMapLayer = scene.get_node_or_null("Map/MonTilemap/special_tiles") as TileMapLayer if scene != null else null
	if special_tiles == null:
		ff.clear_directional_traversal_field(SpawnerRouteService.CLIENT_ONE_WAY_FIELD_ID)
		return
	var cells: PackedVector2Array = PackedVector2Array()
	var directions: PackedVector2Array = PackedVector2Array()
	var level_context: String = ""
	var loader: Node = scene.get_node_or_null("LevelLoader") if scene != null else null
	if loader != null and loader.has_method("get_loaded_level_scene_path"):
		level_context = str(loader.call("get_loaded_level_scene_path"))
	for raw_cell: Variant in special_tiles.get_used_cells():
		var cell: Vector2i = raw_cell as Vector2i
		var atlas: Vector2i = special_tiles.get_cell_atlas_coords(cell)
		if not ONE_WAY_DIRECTIONS.has(atlas):
			push_warning("FlowFieldCode: ignored special tile at %s with atlas %s%s." % [cell, atlas, _level_context_suffix(level_context)])
			continue
		if floor_layer.get_cell_source_id(cell) == -1:
			push_warning("FlowFieldCode: ignored one-way tile at %s because it has no floor cell%s." % [cell, _level_context_suffix(level_context)])
			continue
		var direction: Vector2i = ONE_WAY_DIRECTIONS[atlas] as Vector2i
		cells.append(Vector2(cell.x, cell.y))
		directions.append(Vector2(direction.x, direction.y))
	ff.set_directional_traversal_field(SpawnerRouteService.CLIENT_ONE_WAY_FIELD_ID, cells, directions)


func _level_context_suffix(level_context: String) -> String:
	if level_context.is_empty():
		return ""
	return " in level '%s'" % level_context


func _on_mouse_goal(world_pos: Vector2) -> void:
	if ff == null:
		push_warning("FlowFieldCode: FlowFieldNative not ready.")
		return
	ff.rebuild_async(world_pos)
