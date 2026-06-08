extends Node
class_name BuildingObjectManager

signal building_added(cell: Vector2i, item_id: String)
signal building_removed(cell: Vector2i, item_id: String)

@export var traversable_buildings: TileMapLayer
@export var blocking_buildings: TileMapLayer
@export var runtime_parent: Node2D

const LIGHT_TEXTURE_FALLBACK_TILE_SIZE: int = 16
const LIGHT_COLOR: Color = Color(1.0, 0.72, 0.32, 1.0)
const LIGHT_ENERGY: float = 0.75
const BUILDING_CATEGORIES: Array[String] = ["furniture", "turret", "trap"]

var _buildings_by_cell: Dictionary = {}
var _runtime_nodes_by_cell: Dictionary = {}

func _ready() -> void:
	_connect_game_state()
	initialize_from_layer()

func initialize_from_layer() -> void:
	_buildings_by_cell.clear()
	_clear_runtime_nodes()
	_initialize_from_one_layer(traversable_buildings)
	_initialize_from_one_layer(blocking_buildings)

func _initialize_from_one_layer(layer: TileMapLayer) -> void:
	if not layer:
		return
	for raw_cell in layer.get_used_cells():
		var cell: Vector2i = raw_cell
		var item_def: Dictionary = _default_building_def_for_existing_tile(layer, cell)
		if not item_def.is_empty():
			add_building(cell, item_def)

func add_building(cell: Vector2i, item_def: Dictionary) -> void:
	var item_id: String = str(item_def.get("id", ""))
	var placeable_category: String = str(item_def.get("category", ""))
	var runtime_id: String = str(item_def.get("runtime_id", item_id))
	var light_source: float = float(item_def.get("light_source", 0.0))
	if item_id == "":
		return
	if runtime_id == "":
		runtime_id = item_id
	if _buildings_by_cell.has(cell):
		remove_building(cell)
	var building_data: Dictionary = {
		"item_id": item_id,
		"category": placeable_category,
		"runtime_id": runtime_id,
	}
	if item_def.has("light_source"):
		building_data["light_source"] = light_source
	_buildings_by_cell[cell] = building_data
	if light_source > 0.0:
		_register_light_runtime(cell, runtime_id, light_source)
	building_added.emit(cell, item_id)

func remove_building(cell: Vector2i, erase_tile: bool = false) -> void:
	if not _buildings_by_cell.has(cell):
		return
	var data: Dictionary = _buildings_by_cell[cell] as Dictionary
	var item_id: String = str(data.get("item_id", ""))
	_buildings_by_cell.erase(cell)
	_remove_runtime_node(cell)
	if erase_tile:
		for layer in [traversable_buildings, blocking_buildings]:
			if layer and layer.get_cell_source_id(cell) >= 0:
				layer.erase_cell(cell)
				layer.update_internals()
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

func _register_light_runtime(cell: Vector2i, runtime_id: String, light_source: float) -> void:
	var parent: Node2D = _runtime_parent()
	if not parent:
		return
	var runtime_node: Node2D = Node2D.new()
	runtime_node.name = "%s_Light_%d_%d" % [runtime_id.capitalize(), cell.x, cell.y]
	runtime_node.global_position = _cell_center(cell)

	var radius_pixels: int = max(1, int(round(light_source * float(_tile_size_pixels()))))
	var light: PointLight2D = PointLight2D.new()
	light.name = "PointLight2D"
	light.texture = _create_light_texture(radius_pixels)
	light.color = LIGHT_COLOR
	light.energy = LIGHT_ENERGY
	light.shadow_enabled = false
	light.range_item_cull_mask = 1
	light.range_layer_min = -128
	light.range_layer_max = 128
	light.range_z_min = -4096
	light.range_z_max = 4096
	light.enabled = _is_game_state_night()
	runtime_node.add_child(light)

	parent.add_child(runtime_node)
	_runtime_nodes_by_cell[cell] = runtime_node

func _runtime_parent() -> Node2D:
	if runtime_parent:
		return runtime_parent
	if get_parent() is Node2D:
		return get_parent() as Node2D
	return null

func _reference_layer() -> TileMapLayer:
	if traversable_buildings:
		return traversable_buildings
	return blocking_buildings

func _cell_center(cell: Vector2i) -> Vector2:
	var layer: TileMapLayer = _reference_layer()
	if layer:
		return layer.to_global(layer.map_to_local(cell))
	return Vector2(float(cell.x), float(cell.y))

func _tile_size_pixels() -> int:
	var layer: TileMapLayer = _reference_layer()
	if not layer or not layer.tile_set:
		return LIGHT_TEXTURE_FALLBACK_TILE_SIZE
	var tile_size: Vector2i = layer.tile_set.tile_size
	var size_pixels: int = max(tile_size.x, tile_size.y)
	if size_pixels <= 0:
		return LIGHT_TEXTURE_FALLBACK_TILE_SIZE
	return size_pixels

func _create_light_texture(radius_pixels: int) -> Texture2D:
	var safe_radius: int = max(1, radius_pixels)
	var diameter: int = safe_radius * 2
	var image: Image = Image.create(diameter, diameter, false, Image.FORMAT_RGBA8)
	var center: Vector2 = Vector2(float(safe_radius), float(safe_radius))
	for y in range(diameter):
		for x in range(diameter):
			var offset: Vector2 = Vector2(float(x), float(y)) - center
			var normalized_distance: float = offset.length() / float(safe_radius)
			var alpha: float = clampf(1.0 - normalized_distance, 0.0, 1.0)
			alpha = alpha * alpha
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha))
	var texture: ImageTexture = ImageTexture.create_from_image(image)
	return texture

func _connect_game_state() -> void:
	var game_state: Node = get_node_or_null("/root/GameState")
	if not game_state or not game_state.has_signal("mode_changed"):
		return
	var mode_changed_callable: Callable = Callable(self, "_on_game_mode_changed")
	if not game_state.is_connected(&"mode_changed", mode_changed_callable):
		game_state.connect(&"mode_changed", mode_changed_callable)

func _on_game_mode_changed(is_night: bool) -> void:
	_set_all_runtime_lights_enabled(is_night)

func _is_game_state_night() -> bool:
	var game_state: Node = get_node_or_null("/root/GameState")
	if not game_state:
		return false
	return bool(game_state.get("is_night"))

func _set_all_runtime_lights_enabled(enabled: bool) -> void:
	for raw_node in _runtime_nodes_by_cell.values():
		var runtime_node: Node = raw_node as Node
		if runtime_node and is_instance_valid(runtime_node):
			_set_runtime_node_light_enabled(runtime_node, enabled)

func _set_runtime_node_light_enabled(runtime_node: Node, enabled: bool) -> void:
	var child_count: int = runtime_node.get_child_count()
	for i in range(child_count):
		var child: Node = runtime_node.get_child(i)
		if child is PointLight2D:
			var light: PointLight2D = child as PointLight2D
			light.enabled = enabled

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

func _default_building_def_for_existing_tile(layer: TileMapLayer, _cell: Vector2i) -> Dictionary:
	if not layer:
		return {}
	var layer_name: String = layer.name
	var atlas: Vector2i = layer.get_cell_atlas_coords(_cell)
	for raw_item_def in ItemCatalog.ITEM_DEFS.values():
		var item_def: Dictionary = raw_item_def as Dictionary
		if str(item_def.get("type", "")) != "placeable":
			continue
		var placeable_category: String = str(item_def.get("category", ""))
		if not BUILDING_CATEGORIES.has(placeable_category):
			continue
		var target_layer: String = str(item_def.get("target_layer", ""))
		# Match the def's target layer to the layer the tile actually lives on.
		# Old saves/scenes that still say "buildings" map to traversable_buildings.
		if target_layer == "buildings":
			target_layer = "traversable_buildings"
		if target_layer != layer_name:
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
