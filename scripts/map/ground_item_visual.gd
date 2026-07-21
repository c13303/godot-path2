extends Node2D
class_name GroundItemVisual

## Shared presentation for an item moving above the world floor. The root follows the
## ground path, the shadow stays on that path, and the item sprite uses local Y as altitude.

const SHADOW_TEXTURE: Texture2D = preload("res://assets/sprites/fx/tiny_shadow.png")
const ITEMS_TEXTURE: Texture2D = preload("res://assets/sprites/legval/items.png")
const ITEM_FRAME_SIZE: Vector2 = Vector2(32.0, 32.0)
const SHADOW_ALPHA: float = 0.45
const SHADOW_HEIGHT_RANGE: float = 96.0
const SHADOW_MIN_SCALE: float = 0.35
const SHADOW_Y_SCALE: float = 0.8
const DEFAULT_ITEM_SCALE: Vector2 = Vector2(0.72, 0.72)

var shadow: Sprite2D = null
var sprite: Sprite2D = null


func setup_catalog_item(item_id: String, item_scale: Vector2 = DEFAULT_ITEM_SCALE) -> bool:
	var texture: AtlasTexture = item_texture(item_id)
	if texture == null:
		return false
	setup_item(texture, 1, 0, item_scale)
	return true


func setup_item(texture: Texture2D, frame_count: int, frame_index: int, item_scale: Vector2) -> void:
	z_as_relative = false
	shadow = create_floor_shadow()
	shadow.name = "FloorShadow"
	# Animated item visuals may be parented directly under the scene root while tile/agent
	# visuals use independent world depths. Give both drawables explicit absolute depths so
	# the shadow cannot inherit an unrelated parent/root ordering and disappear behind the map.
	shadow.z_as_relative = false
	sprite = Sprite2D.new()
	sprite.name = "ItemSprite"
	sprite.texture = texture
	sprite.hframes = maxi(1, frame_count)
	sprite.frame = clampi(frame_index, 0, sprite.hframes - 1)
	sprite.centered = true
	sprite.scale = item_scale
	sprite.z_as_relative = false
	sprite.z_index = 0
	add_child(shadow)
	add_child(sprite)


func set_flight_pose(ground_position: Vector2, height: float, depth_offset: int = 0) -> void:
	global_position = ground_position
	var world_depth: int = int(ground_position.y) + depth_offset
	if sprite != null:
		sprite.position = Vector2(0.0, -maxf(0.0, height))
		sprite.z_index = world_depth
	if shadow != null:
		shadow.z_index = world_depth - 1
		update_floor_shadow(shadow, height)


## Shared item-flight arc. `progress` controls both travel and altitude, while `spread_offset`
## fans simultaneous items out at launch and converges them onto the same destination.
func set_arc_flight_pose(
	start_ground: Vector2,
	end_ground: Vector2,
	progress: float,
	peak_height: float,
	start_height: float = 0.0,
	end_height: float = 0.0,
	depth_offset: int = 0,
	spread_offset: Vector2 = Vector2.ZERO
) -> void:
	var t: float = clampf(progress, 0.0, 1.0)
	var ground_position: Vector2 = start_ground.lerp(end_ground, t) + spread_offset * (1.0 - t)
	var base_height: float = lerpf(start_height, end_height, t)
	var arc_height: float = 4.0 * maxf(0.0, peak_height) * t * (1.0 - t)
	set_flight_pose(ground_position, base_height + arc_height, depth_offset)


static func create_floor_shadow() -> Sprite2D:
	var floor_shadow: Sprite2D = Sprite2D.new()
	floor_shadow.texture = SHADOW_TEXTURE
	floor_shadow.centered = true
	floor_shadow.z_index = -1
	reset_floor_shadow(floor_shadow)
	return floor_shadow


static func reset_floor_shadow(floor_shadow: Sprite2D) -> void:
	if floor_shadow == null:
		return
	floor_shadow.visible = true
	floor_shadow.texture = SHADOW_TEXTURE
	floor_shadow.position = Vector2.ZERO
	floor_shadow.modulate = Color(1.0, 1.0, 1.0, SHADOW_ALPHA)
	update_floor_shadow(floor_shadow, 0.0)


static func update_floor_shadow(floor_shadow: Sprite2D, height: float) -> void:
	if floor_shadow == null:
		return
	var shadow_scale: float = clampf(1.0 - maxf(0.0, height) / SHADOW_HEIGHT_RANGE, SHADOW_MIN_SCALE, 1.0)
	floor_shadow.scale = Vector2(shadow_scale, shadow_scale * SHADOW_Y_SCALE)


static func set_floor_shadow_alpha(floor_shadow: Sprite2D, alpha: float) -> void:
	if floor_shadow == null:
		return
	floor_shadow.modulate = Color(1.0, 1.0, 1.0, clampf(alpha, 0.0, 1.0) * SHADOW_ALPHA)


## Canonical world/UI texture for an item id. Currency regions and ordinary catalog frames
## are resolved here so every item presentation uses the same source image.
static func item_texture(item_id: String) -> AtlasTexture:
	if not has_item_texture(item_id):
		return null
	var texture: AtlasTexture = AtlasTexture.new()
	texture.atlas = ITEMS_TEXTURE
	var currency: StringName = CurrencyCatalog.get_currency_for_item_id(item_id)
	if currency != &"":
		texture.region = CurrencyCatalog.get_icon_region(currency)
		return texture
	var frame: int = int(ItemCatalog.get_item_def(item_id).get("frame", -1))
	texture.region = Rect2(Vector2(float(frame) * ITEM_FRAME_SIZE.x, 0.0), ITEM_FRAME_SIZE)
	return texture


static func has_item_texture(item_id: String) -> bool:
	if item_id == "":
		return false
	if CurrencyCatalog.get_currency_for_item_id(item_id) != &"":
		return true
	return int(ItemCatalog.get_item_def(item_id).get("frame", -1)) >= 0
