extends Node2D
class_name GroundDropManager

# Owns pooled ground drops: temporary corpse parts and persistent collectible
# currency items. Coordinates are absolute world positions; tile queries are only
# used to keep final resting positions out of walls.

const BLOOD_PARTS_TEXTURE: Texture2D = preload("res://assets/sprites/fx/blood_parts.png")
const TINY_SHADOW_TEXTURE: Texture2D = preload("res://assets/sprites/fx/tiny_shadow.png")
const ITEMS_TEXTURE: Texture2D = preload("res://assets/sprites/legval/items.png")
const BLOOD_FRAME_SIZE: Vector2 = Vector2(16.0, 16.0)
const ITEM_FRAME_SIZE: Vector2 = Vector2(32.0, 32.0)
const KIND_CORPSE: StringName = &"corpse"
const KIND_COLLECTIBLE: StringName = &"collectible"
const STATE_FALLING: StringName = &"falling"
const STATE_READY: StringName = &"ready"
const STATE_FADING: StringName = &"fading"
const CURRENCY_SEED: StringName = &"seed"
const CURRENCY_GEM: StringName = &"gem"
const CURRENCY_MONEY: StringName = &"money"
const GRAVITY: float = 720.0
const FLOOR_BOUNCE: float = 0.45
const FLOOR_FRICTION: float = 0.64
const REST_HEIGHT_EPSILON: float = 0.75
const REST_VERTICAL_SPEED: float = 26.0
const REST_HORIZONTAL_SPEED: float = 8.0
const CORPSE_FADE_SECONDS: float = 0.55
const PICKUP_RADIUS: float = 18.0
const FLOAT_AMPLITUDE: float = 3.0
const FLOAT_SPEED: float = 1.65
const LANDING_SEARCH_RADIUS_CELLS: int = 2
const DEFAULT_POOL_SIZE: int = 36

@export_range(0, 16, 1, "or_greater") var corpse_part_count: int = 3
@export_range(0.0, 3.0, 0.05, "or_greater") var impulse_randomness: float = 1.0

var _manager: BuildingManager
var _pool: Array[Dictionary] = []
var _active: Array[Dictionary] = []


func setup(manager: BuildingManager) -> void:
	_manager = manager
	z_as_relative = false
	z_index = 0
	_preload_pool(DEFAULT_POOL_SIZE)
	set_process(true)


func spawn_agent_death_burst(world_position: Vector2) -> void:
	var count: int = maxi(0, corpse_part_count)
	for i: int in range(count):
		_spawn_corpse_part(world_position, i)


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


func serialize_state() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for record: Dictionary in _active:
		if StringName(record.get("kind", &"")) != KIND_COLLECTIBLE:
			continue
		var ground_position: Vector2 = record.get("ground_position", Vector2.ZERO) as Vector2
		var velocity: Vector2 = record.get("velocity", Vector2.ZERO) as Vector2
		result.append({
			"currency": String(StringName(record.get("currency", CURRENCY_GEM))),
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
	var records: Array = _active.duplicate()
	for raw_record: Variant in records:
		var record: Dictionary = raw_record as Dictionary
		if StringName(record.get("kind", &"")) == KIND_COLLECTIBLE:
			_release_record(record)


func _process(delta: float) -> void:
	if _active.is_empty():
		return
	var records: Array = _active.duplicate()
	for raw_record: Variant in records:
		var record: Dictionary = raw_record as Dictionary
		if not bool(record.get("active", false)):
			continue
		_process_record(record, delta)


func _spawn_corpse_part(world_position: Vector2, frame_index: int) -> void:
	var record: Dictionary = _acquire_record()
	_configure_record_base(record, KIND_CORPSE, world_position)
	record["state"] = STATE_FALLING
	record["velocity"] = _random_horizontal_velocity(95.0, 205.0)
	record["height"] = randf_range(14.0, 42.0)
	record["vertical_velocity"] = randf_range(180.0, 310.0)
	record["rotation_velocity"] = randf_range(-3.8, 3.8)
	record["fade_timer"] = CORPSE_FADE_SECONDS
	var sprite: Sprite2D = record["sprite"] as Sprite2D
	sprite.texture = _blood_part_texture(frame_index % 3)
	sprite.centered = true
	sprite.scale = Vector2.ONE
	_activate_record(record)


func _process_record(record: Dictionary, delta: float) -> void:
	var state: StringName = StringName(record.get("state", STATE_FALLING))
	if state == STATE_FALLING:
		_process_falling(record, delta)
	elif state == STATE_READY:
		_process_ready_collectible(record, delta)
	elif state == STATE_FADING:
		_process_fading(record, delta)
	_update_record_visual(record)


func _process_falling(record: Dictionary, delta: float) -> void:
	var ground_position: Vector2 = record.get("ground_position", Vector2.ZERO) as Vector2
	var velocity: Vector2 = record.get("velocity", Vector2.ZERO) as Vector2
	var height: float = float(record.get("height", 0.0))
	var vertical_velocity: float = float(record.get("vertical_velocity", 0.0))
	ground_position += velocity * delta
	vertical_velocity -= GRAVITY * delta
	height += vertical_velocity * delta
	if height <= 0.0:
		height = 0.0
		ground_position = _resolve_landing_position(ground_position)
		if absf(vertical_velocity) <= REST_VERTICAL_SPEED and velocity.length() <= REST_HORIZONTAL_SPEED:
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
	if height <= REST_HEIGHT_EPSILON and velocity.length() <= REST_HORIZONTAL_SPEED and absf(vertical_velocity) <= REST_VERTICAL_SPEED:
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


func _process_ready_collectible(record: Dictionary, delta: float) -> void:
	record["float_phase"] = float(record.get("float_phase", 0.0)) + delta * FLOAT_SPEED
	if bool(record.get("pickup_pending", false)):
		return
	var player: Node2D = get_tree().get_first_node_in_group("player") as Node2D
	if player == null or not is_instance_valid(player):
		return
	var ground_position: Vector2 = record.get("ground_position", Vector2.ZERO) as Vector2
	if player.global_position.distance_squared_to(ground_position) > PICKUP_RADIUS * PICKUP_RADIUS:
		return
	var currency: StringName = StringName(record.get("currency", CURRENCY_GEM))
	if _start_currency_pickup(currency, ground_position, record):
		record["pickup_pending"] = true
		var root: Node2D = record["root"] as Node2D
		if root != null:
			root.visible = false


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
	var float_offset: float = 0.0
	if kind == KIND_COLLECTIBLE and StringName(record.get("state", STATE_FALLING)) == STATE_READY:
		float_offset = sin(float(record.get("float_phase", 0.0))) * FLOAT_AMPLITUDE
	root.global_position = ground_position
	root.z_index = int(ground_position.y)
	sprite.position = Vector2(0.0, -height + float_offset)
	sprite.rotation = float(record.get("rotation", 0.0))
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
	_update_record_visual(record)


func _acquire_record() -> Dictionary:
	for record: Dictionary in _pool:
		if not bool(record.get("active", false)):
			return record
	var record: Dictionary = _create_record()
	_pool.append(record)
	return record


func _release_record(record: Dictionary) -> void:
	record["active"] = false
	record["kind"] = &""
	record["state"] = &""
	var root: Node2D = record["root"] as Node2D
	if root != null:
		root.visible = false
	_active.erase(record)


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


func _blood_part_texture(frame_index: int) -> AtlasTexture:
	var texture: AtlasTexture = AtlasTexture.new()
	texture.atlas = BLOOD_PARTS_TEXTURE
	texture.region = Rect2(Vector2(float(frame_index) * BLOOD_FRAME_SIZE.x, 0.0), BLOOD_FRAME_SIZE)
	return texture


func _currency_texture(currency: StringName) -> Texture2D:
	var icon_texture: Texture2D = _currency_ui_texture(currency)
	if icon_texture != null:
		return icon_texture
	var frame: int = 8
	if currency == CURRENCY_SEED:
		frame = 7
	elif currency == CURRENCY_MONEY:
		frame = 13
	var texture: AtlasTexture = AtlasTexture.new()
	texture.atlas = ITEMS_TEXTURE
	texture.region = Rect2(Vector2(float(frame) * ITEM_FRAME_SIZE.x, 0.0), ITEM_FRAME_SIZE)
	return texture


func _currency_ui_texture(currency: StringName) -> Texture2D:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return null
	var icon_name: String = "gemIcon"
	if currency == CURRENCY_SEED:
		icon_name = "seedIcon"
	elif currency == CURRENCY_MONEY:
		icon_name = "moneyIcon"
	var icon: TextureRect = scene.get_node_or_null("GameUI/currenciesUI/" + icon_name) as TextureRect
	return icon.texture if icon != null else null
