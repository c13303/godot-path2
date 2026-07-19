extends Node2D
class_name GroundDropManager

# Owns pooled ground drops: temporary corpse parts and persistent collectible
# currency items. Coordinates are absolute world positions; tile queries are only
# used to keep final resting positions out of walls.

const BLOOD_PARTS_TEXTURE: Texture2D = preload("res://assets/sprites/fx/blood_parts.png")
const PLANT_PARTS_TEXTURE: Texture2D = preload("res://assets/sprites/fx/plant_parts.png")
const TINY_SHADOW_TEXTURE: Texture2D = preload("res://assets/sprites/fx/tiny_shadow.png")
const ITEMS_TEXTURE: Texture2D = preload("res://assets/sprites/legval/items.png")
const FLOAT_SHADER: Shader = preload("res://scripts/map/ground_drop_float.gdshader")
const PART_FRAME_SIZE: Vector2 = Vector2(16.0, 16.0)
const ITEM_FRAME_SIZE: Vector2 = Vector2(32.0, 32.0)
const KIND_CORPSE: StringName = &"corpse"
const KIND_COLLECTIBLE: StringName = &"collectible"
const STATE_FALLING: StringName = &"falling"
const STATE_READY: StringName = &"ready"
const STATE_FADING: StringName = &"fading"
const GRAVITY: float = 720.0
const FLOOR_BOUNCE: float = 0.45
const FLOOR_FRICTION: float = 0.64
const REST_HEIGHT_EPSILON: float = 0.75
const REST_VERTICAL_SPEED: float = 26.0
const REST_HORIZONTAL_SPEED: float = 8.0
const COLLECTIBLE_REST_VERTICAL_SPEED: float = 42.0
const COLLECTIBLE_REST_HORIZONTAL_SPEED: float = 14.0
const CORPSE_FADE_SECONDS: float = 0.55
const PICKUP_RADIUS_FALLBACK: float = 36.0
const PICKUP_RADIUS_TILE_MULTIPLIER: float = 1.15
const PICKUP_CHECK_INTERVAL: float = 0.06
const FLOAT_AMPLITUDE: float = 3.0
const FLOAT_SPEED: float = 1.65
const LANDING_SEARCH_RADIUS_CELLS: int = 2
const FORCED_LANDING_SEARCH_RADIUS_CELLS: int = 24
const DEFAULT_POOL_SIZE: int = 36

@export_range(0, 16, 1, "or_greater") var corpse_part_count: int = 3
@export_range(0.0, 3.0, 0.05, "or_greater") var impulse_randomness: float = 1.0

var _manager: BuildingManager
var _pool: Array[Dictionary] = []
var _active: Array[Dictionary] = []
var _animated: Array[Dictionary] = []
var _settled: Array[Dictionary] = []
var _settled_by_cell: Dictionary = {}
var _cached_player: Node2D = null
var _pickup_radius: float = PICKUP_RADIUS_FALLBACK
var _pickup_radius_squared: float = PICKUP_RADIUS_FALLBACK * PICKUP_RADIUS_FALLBACK
var _pickup_cell_radius: int = 1
var _pickup_timer: Timer = null
var _debug_settled_examined_last_query: int = 0
var _debug_flying_processed_last_frame: int = 0


func setup(manager: BuildingManager) -> void:
	_manager = manager
	z_as_relative = false
	z_index = 0
	_refresh_pickup_radius()
	_preload_pool(DEFAULT_POOL_SIZE)
	_pickup_timer = Timer.new()
	_pickup_timer.name = "PickupTimer"
	_pickup_timer.wait_time = PICKUP_CHECK_INTERVAL
	_pickup_timer.timeout.connect(_check_nearby_pickups)
	add_child(_pickup_timer)
	set_process(false)


func _ready() -> void:
	_refresh_processing_state()


func spawn_agent_death_burst(world_position: Vector2) -> void:
	var count: int = maxi(0, corpse_part_count)
	for i: int in range(count):
		_spawn_corpse_part(world_position, i)


func spawn_plant_parts_burst(world_position: Vector2) -> void:
	var count: int = maxi(0, corpse_part_count)
	for i: int in range(count):
		_spawn_plant_part(world_position, i)


func spawn_collectible_currency(currency: StringName, world_position: Vector2) -> void:
	var record: Dictionary = _acquire_record()
	_configure_record_base(record, KIND_COLLECTIBLE, world_position)
	record["currency"] = currency
	record["state"] = STATE_FALLING
	record["velocity"] = _random_horizontal_velocity(70.0, 145.0)
	record["height"] = randf_range(18.0, 38.0)
	record["vertical_velocity"] = randf_range(160.0, 255.0)
	record["rotation_velocity"] = randf_range(-2.2, 2.2)
	record["float_phase"] = randf_range(0.0, TAU)
	record["pickup_pending"] = false
	var sprite: Sprite2D = record["sprite"] as Sprite2D
	sprite.texture = _currency_texture(currency)
	sprite.centered = true
	sprite.scale = Vector2(0.72, 0.72)
	_activate_record(record)


func spawn_collectible_currency_toward(currency: StringName, origin: Vector2, landing_target: Vector2) -> void:
	var record: Dictionary = _acquire_record()
	_configure_record_base(record, KIND_COLLECTIBLE, origin)
	record["currency"] = currency
	record["state"] = STATE_FALLING
	record["landing_target"] = landing_target
	var offset: Vector2 = landing_target - origin
	var travel_seconds: float = clampf(offset.length() / 260.0, 0.35, 0.85)
	record["velocity"] = offset / travel_seconds
	record["height"] = 8.0
	record["vertical_velocity"] = GRAVITY * travel_seconds * 0.5
	record["rotation_velocity"] = randf_range(-2.2, 2.2)
	record["float_phase"] = randf_range(0.0, TAU)
	record["pickup_pending"] = false
	var sprite: Sprite2D = record["sprite"] as Sprite2D
	sprite.texture = _currency_texture(currency)
	sprite.centered = true
	sprite.scale = Vector2(0.72, 0.72)
	_activate_record(record)


func nearest_valid_dry_floor_world(origin: Vector2) -> Vector2:
	if _manager == null or _manager.floorz == null:
		return origin
	var origin_cell: Vector2i = _manager.floorz.local_to_map(_manager.floorz.to_local(origin))
	var best_cell: Vector2i = Vector2i(2147483647, 2147483647)
	var best_distance_squared: float = INF
	for radius: int in range(0, FORCED_LANDING_SEARCH_RADIUS_CELLS + 1):
		for y: int in range(origin_cell.y - radius, origin_cell.y + radius + 1):
			for x: int in range(origin_cell.x - radius, origin_cell.x + radius + 1):
				if radius > 0 and x != origin_cell.x - radius and x != origin_cell.x + radius and y != origin_cell.y - radius and y != origin_cell.y + radius:
					continue
				var cell: Vector2i = Vector2i(x, y)
				if not _is_valid_dry_landing_cell(cell):
					continue
				var candidate: Vector2 = _manager.cell_center(cell)
				var distance_squared: float = candidate.distance_squared_to(origin)
				if distance_squared < best_distance_squared:
					best_distance_squared = distance_squared
					best_cell = cell
		if best_cell != Vector2i(2147483647, 2147483647):
			return _manager.cell_center(best_cell)
	return origin


func serialize_state() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for record: Dictionary in _active:
		if StringName(record.get("kind", &"")) != KIND_COLLECTIBLE:
			continue
			var ground_position: Vector2 = record.get("ground_position", Vector2.ZERO) as Vector2
			var velocity: Vector2 = record.get("velocity", Vector2.ZERO) as Vector2
			result.append({
				"currency": String(StringName(record.get("currency", &"gem"))),
				"state": String(StringName(record.get("state", STATE_READY))),
			"x": ground_position.x,
			"y": ground_position.y,
			"vx": velocity.x,
			"vy": velocity.y,
			"height": float(record.get("height", 0.0)),
			"vertical_velocity": float(record.get("vertical_velocity", 0.0)),
			"rotation": float(record.get("rotation", 0.0)),
			"rotation_velocity": float(record.get("rotation_velocity", 0.0)),
			"float_phase": float(record.get("float_phase", 0.0)),
		})
	return result


func restore_state(saved_items: Array) -> void:
	clear_collectibles()
	for raw_item: Variant in saved_items:
		if not (raw_item is Dictionary):
			continue
		var item_data: Dictionary = raw_item as Dictionary
		var currency: StringName = StringName(str(item_data.get("currency", "gem")))
		var drop_position: Vector2 = Vector2(float(item_data.get("x", 0.0)), float(item_data.get("y", 0.0)))
		var record: Dictionary = _acquire_record()
		_configure_record_base(record, KIND_COLLECTIBLE, drop_position)
		record["currency"] = currency
		record["state"] = StringName(str(item_data.get("state", "ready")))
		record["velocity"] = Vector2(float(item_data.get("vx", 0.0)), float(item_data.get("vy", 0.0)))
		record["height"] = maxf(0.0, float(item_data.get("height", 0.0)))
		record["vertical_velocity"] = float(item_data.get("vertical_velocity", 0.0))
		record["rotation"] = float(item_data.get("rotation", 0.0))
		record["rotation_velocity"] = float(item_data.get("rotation_velocity", 0.0))
		record["float_phase"] = float(item_data.get("float_phase", randf_range(0.0, TAU)))
		record["pickup_pending"] = false
		var sprite: Sprite2D = record["sprite"] as Sprite2D
		sprite.texture = _currency_texture(currency)
		sprite.scale = Vector2(0.72, 0.72)
		_activate_record(record)
		_update_record_visual(record)


func clear_collectibles() -> void:
	for index: int in range(_active.size() - 1, -1, -1):
		var record: Dictionary = _active[index]
		if StringName(record.get("kind", &"")) == KIND_COLLECTIBLE:
			_release_record(record)


func _process(delta: float) -> void:
	_debug_flying_processed_last_frame = 0
	for index: int in range(_animated.size() - 1, -1, -1):
		var record: Dictionary = _animated[index]
		if not bool(record.get("active", false)):
			continue
		if StringName(record.get("state", STATE_FALLING)) == STATE_FALLING:
			_debug_flying_processed_last_frame += 1
		_process_record(record, delta)
	if _animated.is_empty():
		set_process(false)


func _spawn_corpse_part(world_position: Vector2, frame_index: int) -> void:
	_spawn_temporary_part(world_position, _part_texture(BLOOD_PARTS_TEXTURE, frame_index % 3))


func _spawn_plant_part(world_position: Vector2, frame_index: int) -> void:
	_spawn_temporary_part(world_position, _part_texture(PLANT_PARTS_TEXTURE, frame_index % 3))


func _spawn_temporary_part(world_position: Vector2, texture: Texture2D) -> void:
	var record: Dictionary = _acquire_record()
	_configure_record_base(record, KIND_CORPSE, world_position)
	record["state"] = STATE_FALLING
	record["velocity"] = _random_horizontal_velocity(95.0, 205.0)
	record["height"] = randf_range(14.0, 42.0)
	record["vertical_velocity"] = randf_range(180.0, 310.0)
	record["rotation_velocity"] = randf_range(-3.8, 3.8)
	record["fade_timer"] = CORPSE_FADE_SECONDS
	var sprite: Sprite2D = record["sprite"] as Sprite2D
	sprite.texture = texture
	sprite.centered = true
	sprite.scale = Vector2.ONE
	_activate_record(record)


func _process_record(record: Dictionary, delta: float) -> void:
	var state: StringName = StringName(record.get("state", STATE_FALLING))
	if state == STATE_FALLING:
		_process_falling(record, delta)
	elif state == STATE_FADING:
		_process_fading(record, delta)
	_update_record_visual(record)


func _process_falling(record: Dictionary, delta: float) -> void:
	var ground_position: Vector2 = record.get("ground_position", Vector2.ZERO) as Vector2
	var previous_ground_position: Vector2 = ground_position
	var velocity: Vector2 = record.get("velocity", Vector2.ZERO) as Vector2
	var height: float = float(record.get("height", 0.0))
	var vertical_velocity: float = float(record.get("vertical_velocity", 0.0))
	var kind: StringName = StringName(record.get("kind", KIND_CORPSE))
	var rest_vertical_speed: float = REST_VERTICAL_SPEED
	var rest_horizontal_speed: float = REST_HORIZONTAL_SPEED
	if kind == KIND_COLLECTIBLE:
		rest_vertical_speed = COLLECTIBLE_REST_VERTICAL_SPEED
		rest_horizontal_speed = COLLECTIBLE_REST_HORIZONTAL_SPEED
	ground_position += velocity * delta
	vertical_velocity -= GRAVITY * delta
	height += vertical_velocity * delta
	if height <= 0.0:
		height = 0.0
		if record.has("landing_target"):
			ground_position = record["landing_target"] as Vector2
			_rest_record(record, ground_position)
			return
		ground_position = _resolve_landing_position(ground_position)
		if absf(vertical_velocity) <= rest_vertical_speed and velocity.length() <= rest_horizontal_speed:
			_rest_record(record, ground_position)
			return
		vertical_velocity = absf(vertical_velocity) * FLOOR_BOUNCE
		velocity *= FLOOR_FRICTION
	else:
		velocity *= pow(0.985, delta * 60.0)
	var spin: float = float(record.get("rotation", 0.0))
	var rotation_velocity: float = float(record.get("rotation_velocity", 0.0))
	record["ground_position"] = ground_position
	record["velocity"] = velocity
	record["height"] = height
	record["vertical_velocity"] = vertical_velocity
	record["rotation"] = spin + rotation_velocity * delta
	if record.has("landing_target"):
		var landing_target: Vector2 = record["landing_target"] as Vector2
		var previous_distance: float = previous_ground_position.distance_squared_to(landing_target)
		var current_distance: float = ground_position.distance_squared_to(landing_target)
		if current_distance <= 16.0 or current_distance > previous_distance:
			_rest_record(record, landing_target)
			return
	if height <= REST_HEIGHT_EPSILON and velocity.length() <= rest_horizontal_speed and absf(vertical_velocity) <= rest_vertical_speed:
		_rest_record(record, _resolve_landing_position(ground_position))


func _rest_record(record: Dictionary, ground_position: Vector2) -> void:
	record["ground_position"] = ground_position
	record["velocity"] = Vector2.ZERO
	record["height"] = 0.0
	record["vertical_velocity"] = 0.0
	record["rotation_velocity"] = 0.0
	var kind: StringName = StringName(record.get("kind", KIND_CORPSE))
	if kind == KIND_CORPSE:
		record["state"] = STATE_FADING
		record["fade_timer"] = CORPSE_FADE_SECONDS
	else:
		record["state"] = STATE_READY
		record["rotation"] = 0.0
		_register_settled_record(record)


func _process_fading(record: Dictionary, delta: float) -> void:
	var fade_timer: float = float(record.get("fade_timer", CORPSE_FADE_SECONDS)) - delta
	record["fade_timer"] = fade_timer
	var sprite: Sprite2D = record["sprite"] as Sprite2D
	var shadow: Sprite2D = record["shadow"] as Sprite2D
	var alpha: float = clampf(fade_timer / CORPSE_FADE_SECONDS, 0.0, 1.0)
	sprite.modulate = Color(1.0, 1.0, 1.0, alpha)
	shadow.modulate = Color(1.0, 1.0, 1.0, alpha * 0.45)
	if fade_timer <= 0.0:
		_release_record(record)


func _update_record_visual(record: Dictionary) -> void:
	var root: Node2D = record["root"] as Node2D
	var sprite: Sprite2D = record["sprite"] as Sprite2D
	var shadow: Sprite2D = record["shadow"] as Sprite2D
	if root == null or sprite == null or shadow == null:
		return
	var ground_position: Vector2 = record.get("ground_position", Vector2.ZERO) as Vector2
	var height: float = float(record.get("height", 0.0))
	var kind: StringName = StringName(record.get("kind", KIND_CORPSE))
	root.global_position = ground_position
	root.z_index = int(ground_position.y)
	sprite.position = Vector2(0.0, -height)
	sprite.rotation = float(record.get("rotation", 0.0))
	var is_settled_collectible: bool = kind == KIND_COLLECTIBLE and StringName(record.get("state", STATE_FALLING)) == STATE_READY
	var scale_y: float = maxf(0.001, absf(sprite.scale.y))
	sprite.set_instance_shader_parameter("float_amplitude", FLOAT_AMPLITUDE / scale_y if is_settled_collectible else 0.0)
	sprite.set_instance_shader_parameter("float_phase", float(record.get("float_phase", 0.0)))
	shadow.position = Vector2.ZERO
	var shadow_scale: float = clampf(1.0 - height / 96.0, 0.35, 1.0)
	shadow.scale = Vector2(shadow_scale, shadow_scale * 0.8)
	if StringName(record.get("state", STATE_READY)) != STATE_FADING:
		sprite.modulate = Color.WHITE
		shadow.modulate = Color(1.0, 1.0, 1.0, 0.45)


func _finish_currency_pickup(record: Dictionary) -> void:
	if bool(record.get("active", false)):
		_release_record(record)


func _start_currency_pickup(currency: StringName, world_position: Vector2, record: Dictionary) -> bool:
	var scene: Node = get_tree().current_scene
	var game_ui: Node = scene.get_node_or_null("GameUI") if scene != null else null
	if game_ui == null or not game_ui.has_method("collect_currency_from_world"):
		return false
	var finished: Callable = Callable(self, "_finish_currency_pickup").bind(record)
	return bool(game_ui.call("collect_currency_from_world", currency, world_position, 1, finished))


## The shared ground-currency pickup radius for a floor layer. Gems, coins and every other
## loose drop are collected at this distance; BambooHarvestController reuses this helper so
## bamboo harvests at exactly the same range instead of duplicating the constants.
static func pickup_radius_for_floor(floor_layer: TileMapLayer) -> float:
	if floor_layer == null or floor_layer.tile_set == null:
		return PICKUP_RADIUS_FALLBACK
	var tile_size: Vector2i = floor_layer.tile_set.tile_size
	var tile_radius: float = float(maxi(tile_size.x, tile_size.y)) * PICKUP_RADIUS_TILE_MULTIPLIER
	return maxf(PICKUP_RADIUS_FALLBACK, tile_radius)


func _refresh_pickup_radius() -> void:
	var floor_layer: TileMapLayer = _manager.floorz if _manager != null else null
	_pickup_radius = pickup_radius_for_floor(floor_layer)
	_pickup_radius_squared = _pickup_radius * _pickup_radius
	if floor_layer != null and floor_layer.tile_set != null:
		var tile_size: Vector2i = floor_layer.tile_set.tile_size
		_pickup_cell_radius = maxi(1, ceili(_pickup_radius / maxf(1.0, float(mini(tile_size.x, tile_size.y)))))


func _get_player_node() -> Node2D:
	if _cached_player != null and is_instance_valid(_cached_player):
		return _cached_player
	_cached_player = get_tree().get_first_node_in_group("player") as Node2D
	return _cached_player


func _configure_record_base(record: Dictionary, kind: StringName, world_position: Vector2) -> void:
	var root: Node2D = record["root"] as Node2D
	var sprite: Sprite2D = record["sprite"] as Sprite2D
	var shadow: Sprite2D = record["shadow"] as Sprite2D
	record["active"] = true
	record["kind"] = kind
	record["ground_position"] = world_position
	record["velocity"] = Vector2.ZERO
	record["height"] = 0.0
	record["vertical_velocity"] = 0.0
	record["rotation"] = randf_range(-0.35, 0.35)
	record["rotation_velocity"] = 0.0
	record["fade_timer"] = 0.0
	record["currency"] = &""
	record["float_phase"] = 0.0
	record["pickup_pending"] = false
	sprite.set_instance_shader_parameter("float_amplitude", 0.0)
	root.visible = true
	root.global_position = world_position
	sprite.visible = true
	sprite.modulate = Color.WHITE
	sprite.rotation = float(record["rotation"])
	shadow.visible = true
	shadow.texture = TINY_SHADOW_TEXTURE
	shadow.modulate = Color(1.0, 1.0, 1.0, 0.45)


func _activate_record(record: Dictionary) -> void:
	if not _active.has(record):
		_active.append(record)
	if StringName(record.get("state", STATE_FALLING)) == STATE_READY:
		_register_settled_record(record)
	elif not _animated.has(record):
		_animated.append(record)
	_update_record_visual(record)
	_refresh_processing_state()


func _acquire_record() -> Dictionary:
	for record: Dictionary in _pool:
		if not bool(record.get("active", false)):
			return record
	var record: Dictionary = _create_record()
	_pool.append(record)
	return record


func _release_record(record: Dictionary) -> void:
	_unregister_settled_record(record)
	_animated.erase(record)
	record["active"] = false
	record["kind"] = &""
	record["state"] = &""
	record.erase("landing_target")
	var root: Node2D = record["root"] as Node2D
	if root != null:
		root.visible = false
	_active.erase(record)
	_refresh_processing_state()


func _preload_pool(count: int) -> void:
	for i: int in range(maxi(0, count)):
		_pool.append(_create_record())


func _create_record() -> Dictionary:
	var root: Node2D = Node2D.new()
	root.visible = false
	root.z_as_relative = false
	var shadow: Sprite2D = Sprite2D.new()
	shadow.texture = TINY_SHADOW_TEXTURE
	shadow.centered = true
	shadow.z_index = -1
	var sprite: Sprite2D = Sprite2D.new()
	sprite.centered = true
	sprite.z_index = 0
	var float_material: ShaderMaterial = ShaderMaterial.new()
	float_material.shader = FLOAT_SHADER
	float_material.set_shader_parameter("float_speed", FLOAT_SPEED)
	sprite.material = float_material
	root.add_child(shadow)
	root.add_child(sprite)
	add_child(root)
	return {
		"active": false,
		"root": root,
		"sprite": sprite,
		"shadow": shadow,
	}


func _random_horizontal_velocity(min_speed: float, max_speed: float) -> Vector2:
	var angle: float = randf_range(0.0, TAU)
	var speed: float = randf_range(min_speed, max_speed) * maxf(0.0, impulse_randomness)
	return Vector2(cos(angle), sin(angle)) * speed


func _resolve_landing_position(world_position: Vector2) -> Vector2:
	if not _is_blocked_world(world_position):
		return world_position
	if _manager == null or _manager.floorz == null:
		return world_position
	var origin_cell: Vector2i = _manager.floorz.local_to_map(_manager.floorz.to_local(world_position))
	var best_position: Vector2 = world_position
	var best_distance_sq: float = INF
	for radius: int in range(1, LANDING_SEARCH_RADIUS_CELLS + 1):
		for y: int in range(origin_cell.y - radius, origin_cell.y + radius + 1):
			for x: int in range(origin_cell.x - radius, origin_cell.x + radius + 1):
				if x != origin_cell.x - radius and x != origin_cell.x + radius and y != origin_cell.y - radius and y != origin_cell.y + radius:
					continue
				var cell: Vector2i = Vector2i(x, y)
				var candidate: Vector2 = _manager.cell_center(cell)
				if _is_blocked_world(candidate):
					continue
				var distance_sq: float = candidate.distance_squared_to(world_position)
				if distance_sq < best_distance_sq:
					best_distance_sq = distance_sq
					best_position = candidate
		if best_distance_sq < INF:
			return best_position
	return best_position


func _is_blocked_world(world_position: Vector2) -> bool:
	if _manager == null or not _manager.has_method("is_ground_drop_blocked_world"):
		return false
	return bool(_manager.call("is_ground_drop_blocked_world", world_position))


func _is_valid_dry_landing_cell(cell: Vector2i) -> bool:
	if _manager == null:
		return false
	if _manager.watersources != null and _manager.watersources.get_cell_source_id(cell) >= 0:
		return false
	return not _manager.is_ground_drop_blocked_cell(cell)


func _part_texture(atlas: Texture2D, frame_index: int) -> AtlasTexture:
	var texture: AtlasTexture = AtlasTexture.new()
	texture.atlas = atlas
	texture.region = Rect2(Vector2(float(frame_index) * PART_FRAME_SIZE.x, 0.0), PART_FRAME_SIZE)
	return texture


func _currency_texture(currency: StringName) -> Texture2D:
	var icon_texture: Texture2D = _currency_ui_texture(currency)
	if icon_texture != null:
		return icon_texture
	var texture: AtlasTexture = AtlasTexture.new()
	texture.atlas = ITEMS_TEXTURE
	if CurrencyCatalog.has_currency(currency):
		texture.region = CurrencyCatalog.get_icon_region(currency)
	else:
		texture.region = Rect2(Vector2(8.0 * ITEM_FRAME_SIZE.x, 0.0), ITEM_FRAME_SIZE)
	return texture


func _currency_ui_texture(currency: StringName) -> Texture2D:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return null
	var icon_name: String = CurrencyCatalog.get_icon_node_name(currency)
	var icon: TextureRect = scene.get_node_or_null("GameUI/currenciesUI/" + icon_name) as TextureRect
	return icon.texture if icon != null else null


func _register_settled_record(record: Dictionary) -> void:
	if _settled.has(record):
		return
	_animated.erase(record)
	_settled.append(record)
	var cell: Vector2i = _world_to_floor_cell(record.get("ground_position", Vector2.ZERO) as Vector2)
	record["settled_cell"] = cell
	var bucket: Array = _settled_by_cell.get(cell, []) as Array
	bucket.append(record)
	_settled_by_cell[cell] = bucket
	_refresh_processing_state()
	_check_record_pickup(record, _get_player_node())


func _unregister_settled_record(record: Dictionary) -> void:
	if not _settled.has(record):
		return
	_settled.erase(record)
	var cell: Vector2i = record.get("settled_cell", Vector2i.ZERO) as Vector2i
	if _settled_by_cell.has(cell):
		var bucket: Array = _settled_by_cell[cell] as Array
		bucket.erase(record)
		if bucket.is_empty():
			_settled_by_cell.erase(cell)
	record.erase("settled_cell")


func _check_nearby_pickups() -> void:
	_debug_settled_examined_last_query = 0
	var player: Node2D = _get_player_node()
	if player == null or not is_instance_valid(player):
		return
	var center_cell: Vector2i = _world_to_floor_cell(player.global_position)
	for y: int in range(center_cell.y - _pickup_cell_radius, center_cell.y + _pickup_cell_radius + 1):
		for x: int in range(center_cell.x - _pickup_cell_radius, center_cell.x + _pickup_cell_radius + 1):
			var cell: Vector2i = Vector2i(x, y)
			if not _settled_by_cell.has(cell):
				continue
			var bucket: Array = _settled_by_cell[cell] as Array
			for index: int in range(bucket.size() - 1, -1, -1):
				var record: Dictionary = bucket[index] as Dictionary
				_debug_settled_examined_last_query += 1
				_check_record_pickup(record, player)


func _check_record_pickup(record: Dictionary, player: Node2D) -> void:
	if player == null or not is_instance_valid(player) or bool(record.get("pickup_pending", false)):
		return
	var ground_position: Vector2 = record.get("ground_position", Vector2.ZERO) as Vector2
	if player.global_position.distance_squared_to(ground_position) > _pickup_radius_squared:
		return
	var currency: StringName = StringName(record.get("currency", &"gem"))
	if not _start_currency_pickup(currency, ground_position, record):
		return
	record["pickup_pending"] = true
	var root: Node2D = record["root"] as Node2D
	if root != null:
		root.visible = false


func _world_to_floor_cell(world_position: Vector2) -> Vector2i:
	if _manager == null or _manager.floorz == null:
		return Vector2i.ZERO
	return _manager.floorz.local_to_map(_manager.floorz.to_local(world_position))


func _refresh_processing_state() -> void:
	set_process(not _animated.is_empty())
	if _pickup_timer == null or not is_inside_tree():
		return
	if _settled.is_empty():
		_pickup_timer.stop()
	elif _pickup_timer.is_stopped():
		_pickup_timer.start()


func debug_stats() -> Dictionary:
	return {
		"active_ground_drops": _active.size(),
		"flying_drops_processed_per_frame": _debug_flying_processed_last_frame,
		"settled_drops": _settled.size(),
		"settled_drops_examined_last_pickup_query": _debug_settled_examined_last_query,
		"ground_drop_array_copies": 0,
	}
