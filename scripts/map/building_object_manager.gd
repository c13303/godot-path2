extends Node
class_name BuildingObjectManager

signal building_added(cell: Vector2i, item_id: String)
signal building_removed(cell: Vector2i, item_id: String)

@export var traversable_buildings: TileMapLayer
@export var blocking_buildings: TileMapLayer
@export var fences: TileMapLayer
@export var runtime_parent: Node2D
# Generic static-obstacle steering system (CPP/SteeringSystemNative). Blocking buildings
# register a circular static obstacle here so agents are locally pushed around them.
@export var steering_system: Node
# Tile is visually square but a round collision favors sliding; keep it < 0.5.
@export var blocking_building_obstacle_radius_ratio: float = 0.45

const LIGHT_TEXTURE_FALLBACK_TILE_SIZE: int = 16
const LIGHT_COLOR: Color = Color(1.0, 0.72, 0.32, 1.0)
const LIGHT_ENERGY: float = 0.75
const RESERVOIR_TEXTURE: Texture2D = preload("res://assets/sprites/legval/reservoir.png")
const RESERVOIR_WATER_TEXTURE: Texture2D = preload("res://assets/sprites/legval/reservoir_water.png")
const RESERVOIR_WATER_FILL_SCRIPT: Script = preload("res://scripts/visual_fx/reservoir_water_fill.gd")
const RESERVOIR_RUNTIME_SCRIPT: Script = preload("res://scripts/map/reservoir_runtime.gd")
const TURRET_SPRITE_VISUAL_SCRIPT: Script = preload("res://scripts/combat/turrets/turret_sprite_visual.gd")
const RESERVOIR_Z_INDEX: int = 510
const BUILDING_CATEGORIES: Array[String] = ["furniture", "turret", "trap", "shop_counter", "irrigation", "fence"]

var _buildings_by_cell: Dictionary = {}
var _runtime_nodes_by_cell: Dictionary = {}
# cell -> static obstacle id we registered with the steering system. Only blocking
# buildings appear here; lamps / traversable buildings never do.
var _static_obstacle_ids_by_cell: Dictionary = {}

func _ready() -> void:
	_connect_game_state()
	_resolve_level_layers()
	initialize_from_layer()

func _resolve_level_layers() -> void:
	if fences == null:
		fences = get_node_or_null("../MonTilemap/fences") as TileMapLayer

func initialize_from_layer() -> void:
	_buildings_by_cell.clear()
	_clear_runtime_nodes()
	_clear_static_obstacles()
	_initialize_from_one_layer(traversable_buildings)
	_initialize_from_one_layer(blocking_buildings)
	_initialize_from_one_layer(fences)
	_log("Indexed buildings=%d rose_shop_counters=%d" % [
		_buildings_by_cell.size(),
		count_buildings_by_item_id("rose_shop_counter"),
	])

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
	if item_def.has("direction"):
		building_data["direction"] = item_def.get("direction", Vector2i(1, 0))
	if item_def.has("light_source"):
		building_data["light_source"] = light_source
	_buildings_by_cell[cell] = building_data
	if item_def.has("turret_sprite_visual"):
		_register_turret_sprite_runtime(cell, runtime_id, item_def)
	elif item_def.get("building_visual_scene", null) is PackedScene:
		_register_building_visual_scene_runtime(cell, runtime_id, item_def)
	if runtime_id == "reservoir":
		_register_reservoir_runtime(cell, runtime_id)
	if light_source > 0.0:
		_register_light_runtime(cell, runtime_id, light_source)
	_register_blocking_obstacle(cell, item_def)
	building_added.emit(cell, item_id)

func remove_building(cell: Vector2i, erase_tile: bool = false) -> void:
	if not _buildings_by_cell.has(cell):
		return
	var data: Dictionary = _buildings_by_cell[cell] as Dictionary
	var item_id: String = str(data.get("item_id", ""))
	_buildings_by_cell.erase(cell)
	_remove_runtime_node(cell)
	_unregister_blocking_obstacle(cell)
	if erase_tile:
		for layer in [traversable_buildings, blocking_buildings, fences]:
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

func get_building_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for raw_cell: Variant in _buildings_by_cell.keys():
		cells.append(raw_cell as Vector2i)
	return cells


func request_contact_dance(cell: Vector2i, duration: float) -> void:
	var runtime_node: Node = _runtime_nodes_by_cell.get(cell, null) as Node
	if runtime_node == null or not is_instance_valid(runtime_node):
		return
	if runtime_node.has_method("request_contact_dance"):
		runtime_node.call("request_contact_dance", duration)


func play_turret_shot_animation(cell: Vector2i) -> void:
	var runtime_node: Node = _runtime_nodes_by_cell.get(cell, null) as Node
	if runtime_node == null or not is_instance_valid(runtime_node):
		return
	if runtime_node.has_method("play_shot_animation"):
		runtime_node.call("play_shot_animation")


func set_turret_refractory_active(cell: Vector2i, active: bool) -> void:
	var runtime_node: Node = _runtime_nodes_by_cell.get(cell, null) as Node
	if runtime_node == null or not is_instance_valid(runtime_node):
		return
	if runtime_node.has_method("set_refractory_active"):
		runtime_node.call("set_refractory_active", active)


func get_building_cells_by_item_id(item_id: String) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for raw_cell: Variant in _buildings_by_cell.keys():
		var cell: Vector2i = raw_cell as Vector2i
		var data: Dictionary = _buildings_by_cell[cell] as Dictionary
		if str(data.get("item_id", "")) == item_id:
			cells.append(cell)
	return cells


func get_runtime_node(cell: Vector2i) -> Node2D:
	var node: Node2D = _runtime_nodes_by_cell.get(cell, null) as Node2D
	if node != null and is_instance_valid(node):
		return node
	return null


func count_buildings_by_item_id(item_id: String) -> int:
	return get_building_cells_by_item_id(item_id).size()

func clear() -> void:
	_buildings_by_cell.clear()
	_clear_runtime_nodes()
	_clear_static_obstacles()

# --- Generic static obstacles (blocking buildings) -----------------------------

# Static obstacle ids live in a high, dense range that cannot collide with moving
# agent ids (which start at 1 and grow slowly). The id is a stable function of the
# cell so the same tile always maps to the same obstacle.
const _STATIC_OBSTACLE_ID_BASE: int = 1_000_000_000
const _STATIC_OBSTACLE_ID_STRIDE: int = 100_000

func _blocking_obstacle_id_for_cell(cell: Vector2i) -> int:
	# Map signed cell coords into a non-negative grid so distinct cells stay distinct.
	@warning_ignore("integer_division")
	var gx: int = cell.x + (_STATIC_OBSTACLE_ID_STRIDE / 2)
	@warning_ignore("integer_division")
	var gy: int = cell.y + (_STATIC_OBSTACLE_ID_STRIDE / 2)
	return _STATIC_OBSTACLE_ID_BASE + gy * _STATIC_OBSTACLE_ID_STRIDE + gx

func _def_blocks_movement(item_def: Dictionary) -> bool:
	# Only tiles that explicitly block movement (isWall / blocks_movement) become obstacles.
	if bool(item_def.get("blocks_movement", false)):
		return true
	return bool(item_def.get("isWall", false))

func _def_targets_blocking_layer(item_def: Dictionary) -> bool:
	return str(item_def.get("target_layer", "")) == "blocking_buildings"

func _blocking_obstacle_radius() -> float:
	return float(_tile_size_pixels()) * blocking_building_obstacle_radius_ratio

func _register_blocking_obstacle(cell: Vector2i, item_def: Dictionary) -> void:
	if not steering_system:
		return
	if not _def_blocks_movement(item_def) or not _def_targets_blocking_layer(item_def):
		return
	if not steering_system.has_method("register_static_obstacle"):
		return
	# Center on the blocking_buildings tile in world space.
	var layer: TileMapLayer = blocking_buildings if blocking_buildings else _reference_layer()
	if not layer:
		return
	var world_center: Vector2 = layer.to_global(layer.map_to_local(cell))
	var obstacle_id: int = _blocking_obstacle_id_for_cell(cell)
	steering_system.call("register_static_obstacle", obstacle_id, world_center, _blocking_obstacle_radius(), 1.0)
	_static_obstacle_ids_by_cell[cell] = obstacle_id

func _unregister_blocking_obstacle(cell: Vector2i) -> void:
	if not _static_obstacle_ids_by_cell.has(cell):
		return
	var obstacle_id: int = int(_static_obstacle_ids_by_cell[cell])
	_static_obstacle_ids_by_cell.erase(cell)
	if steering_system and steering_system.has_method("unregister_static_obstacle"):
		steering_system.call("unregister_static_obstacle", obstacle_id)

func _clear_static_obstacles() -> void:
	# Unregister only the obstacles this manager owns; do not nuke obstacles other
	# systems may have registered with the shared steering system.
	if steering_system and steering_system.has_method("unregister_static_obstacle"):
		for raw_id in _static_obstacle_ids_by_cell.values():
			steering_system.call("unregister_static_obstacle", int(raw_id))
	_static_obstacle_ids_by_cell.clear()

func rebuild_blocking_obstacles_from_layer() -> void:
	_clear_static_obstacles()
	if not blocking_buildings:
		return
	for raw_cell in blocking_buildings.get_used_cells():
		var cell: Vector2i = raw_cell
		var item_def: Dictionary = _default_building_def_for_existing_tile(blocking_buildings, cell)
		if not item_def.is_empty():
			_register_blocking_obstacle(cell, item_def)

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

func _register_reservoir_runtime(cell: Vector2i, runtime_id: String) -> void:
	var parent: Node2D = _runtime_parent()
	if not parent:
		return
	var runtime_node: Node2D = Node2D.new()
	runtime_node.name = "%s_%d_%d" % [runtime_id.capitalize(), cell.x, cell.y]
	runtime_node.script = RESERVOIR_RUNTIME_SCRIPT
	runtime_node.global_position = _cell_center(cell)
	runtime_node.add_to_group("reservoirs")

	var sprite: Sprite2D = Sprite2D.new()
	sprite.name = "Sprite2D"
	sprite.texture = RESERVOIR_TEXTURE
	sprite.z_as_relative = false
	sprite.z_index = RESERVOIR_Z_INDEX
	_add_reservoir_water_fill(sprite)
	runtime_node.add_child(sprite)

	parent.add_child(runtime_node)
	_runtime_nodes_by_cell[cell] = runtime_node

func _add_reservoir_water_fill(reservoir_sprite: Sprite2D) -> void:
	var water: Sprite2D = Sprite2D.new()
	water.name = "WaterFill"
	water.texture = RESERVOIR_WATER_TEXTURE
	water.z_as_relative = true
	water.z_index = -1
	water.script = RESERVOIR_WATER_FILL_SCRIPT
	reservoir_sprite.add_child(water)

func _register_turret_sprite_runtime(cell: Vector2i, runtime_id: String, item_def: Dictionary) -> void:
	var parent: Node2D = _runtime_parent()
	if not parent:
		return
	var visual_def: Dictionary = item_def.get("turret_sprite_visual", {}) as Dictionary
	if visual_def.is_empty():
		return
	var direction: Vector2i = item_def.get("direction", BuildDirectionRules.DIRECTION_RIGHT) as Vector2i
	var runtime_node: Node2D = Node2D.new()
	runtime_node.name = "%s_%d_%d" % [runtime_id.capitalize(), cell.x, cell.y]
	runtime_node.script = TURRET_SPRITE_VISUAL_SCRIPT
	runtime_node.z_as_relative = false
	runtime_node.global_position = _cell_center(cell)
	runtime_node.z_index = int(runtime_node.global_position.y)
	parent.add_child(runtime_node)
	runtime_node.call("setup", visual_def, direction)
	_runtime_nodes_by_cell[cell] = runtime_node


func _register_building_visual_scene_runtime(cell: Vector2i, runtime_id: String, item_def: Dictionary) -> void:
	var parent: Node2D = _runtime_parent()
	if not parent:
		return
	var scene: PackedScene = item_def.get("building_visual_scene", null) as PackedScene
	if scene == null:
		return
	var runtime_node: Node2D = scene.instantiate() as Node2D
	if runtime_node == null:
		return
	runtime_node.name = "%s_%d_%d" % [runtime_id.capitalize(), cell.x, cell.y]
	runtime_node.z_as_relative = false
	runtime_node.global_position = _cell_center(cell)
	runtime_node.z_index = int(runtime_node.global_position.y)
	parent.add_child(runtime_node)
	if runtime_node.has_method("reset_to_idle"):
		runtime_node.call("reset_to_idle")
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
	if fences:
		return fences
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

func _log(message: String) -> void:
	CppDebugOptions.save_log("[SAVE] BuildingObjectManager: " + message)

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
			var resolved_def: Dictionary = item_def.duplicate(true)
			if bool(resolved_def.get("directional", false)):
				resolved_def["direction"] = BuildDirectionRules.direction_from_alternative(layer.get_cell_alternative_tile(_cell))
			return resolved_def
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
