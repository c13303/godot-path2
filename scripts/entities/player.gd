extends CharacterBody2D
class_name PlayerCharacter

const HEALTH_BAR_SIZE: Vector2 = Vector2(28.0, 4.0)
const HEALTH_BAR_POSITION: Vector2 = Vector2(-14.0, -44.0)
const HEALTH_BAR_SPRITE_GAP: float = 4.0

@export var acceleration: float = 900.0
@export var deceleration: float = 1200.0
@export var max_health: int = 100

## Max movement speed. 0 = inherit the global agent_max_speed from GlobalConfigNative.
@export var max_speed: float = 0.0

@export_group("Sprite")
## Path to the visual sprite child (e.g. "rosa"). Empty = first Sprite2D child.
@export var sprite_node_path: NodePath
## Local offset applied to the sprite so its feet line up with the world hitbox
## center. The hitbox center sits at (0, -world_radius) relative to this node, so
## set y to about -world_radius - sprite_height/2.
@export var sprite_offset: Vector2 = Vector2.ZERO

@export_group("Combat")
## Local offset (relative to this node) defining where all player-originated
## attacks emanate from: melee/AOE zones, thrown bombs, gun projectiles, and the
## sprites/effects they spawn. Use get_weapon_origin() to read it in world space.
@export var weapon_origin: Vector2 = Vector2.ZERO

const FRAME_SOUTH: int = 0
const FRAME_EAST: int = 1
const FRAME_NORTH: int = 2
const LANCE_Z_BEHIND_PLAYER: int = -1
const LANCE_Z_IN_FRONT_OF_PLAYER: int = 2
const SPRITESHEET_PADDING: int = 2
const SPRITESHEET_FRAME_SIZE: Vector2 = Vector2(64.0, 64.0)
const SPRITESHEET_CELL_SIZE: int = 68

var _nav_id: int = -1
var _is_propelled: bool = false
var _controls_impaired: bool = false
var _velocity_len: float = 0.0
var _facing_frame: int = FRAME_SOUTH
var _facing_west: bool = false
var _spritesheet_texture: Texture2D
var _direction_textures: Array[AtlasTexture] = []
var health: int = 100

var nav_id: int = -1:
	get:
		return _nav_id
	set(value):
		_nav_id = value

func _ready() -> void:
	health = maxi(1, max_health)
	_apply_sprite_offset()
	var sprite: Sprite2D = get_sprite()
	if sprite:
		_spritesheet_texture = sprite.texture
		_ensure_direction_textures()
	_apply_facing_visual()
	set_physics_process(false)

func _process(_delta: float) -> void:
	z_index = int(position.y)

func _draw() -> void:
	if not should_show_health_bar():
		return
	var bar_position: Vector2 = _health_bar_position()
	draw_rect(Rect2(bar_position, HEALTH_BAR_SIZE), Color.BLACK)
	var health_ratio: float = float(health) / float(maxi(1, max_health))
	var fill_size: Vector2 = Vector2((HEALTH_BAR_SIZE.x - 2.0) * health_ratio, HEALTH_BAR_SIZE.y - 2.0)
	draw_rect(Rect2(bar_position + Vector2.ONE, fill_size), Color(0.9, 0.05, 0.05, 1.0))

func take_damage(amount: int) -> bool:
	if amount <= 0:
		return false
	var health_cap: int = maxi(0, max_health)
	health = clampi(health - amount, 0, health_cap)
	queue_redraw()
	return health <= 0

func heal(amount: int) -> void:
	if amount <= 0:
		return
	var health_cap: int = maxi(0, max_health)
	health = clampi(health + amount, 0, health_cap)
	queue_redraw()

func should_show_health_bar() -> bool:
	return max_health > 0 and health < max_health

func set_propelled_state(enabled: bool) -> void:
	_is_propelled = enabled

func set_control_impaired_state(enabled: bool) -> void:
	if _controls_impaired == enabled:
		return

	_controls_impaired = enabled
	_update_sprite_tint()

func set_velocity_len(value: float) -> void:
	_velocity_len = value

## World-space point that all player-originated attacks spawn from.
func get_weapon_origin() -> Vector2:
	return global_position + weapon_origin

func get_sprite() -> Sprite2D:
	if not sprite_node_path.is_empty():
		return get_node_or_null(sprite_node_path) as Sprite2D
	for child in get_children():
		if child is Sprite2D:
			return child
	return null

func set_facing_direction(direction: Vector2) -> void:
	if direction.length_squared() <= 0.000001:
		return

	if absf(direction.x) >= absf(direction.y):
		_facing_frame = FRAME_EAST
		_facing_west = direction.x < 0.0
	else:
		_facing_frame = FRAME_NORTH if direction.y < 0.0 else FRAME_SOUTH
		_facing_west = false
	_apply_facing_visual()

func is_facing_north() -> bool:
	return _facing_frame == FRAME_NORTH

func _apply_sprite_offset() -> void:
	var sprite: Sprite2D = get_sprite()
	if sprite:
		sprite.position = sprite_offset

func _health_bar_position() -> Vector2:
	var sprite: Sprite2D = get_sprite()
	if sprite == null or sprite.texture == null:
		return HEALTH_BAR_POSITION
	var sprite_height: float = sprite.texture.get_size().y * absf(sprite.scale.y)
	var sprite_top: float = sprite.position.y
	if sprite.centered:
		sprite_top -= sprite_height * 0.5
	var bar_x: float = sprite.position.x - HEALTH_BAR_SIZE.x * 0.5
	var bar_y: float = sprite_top - HEALTH_BAR_SPRITE_GAP - HEALTH_BAR_SIZE.y
	return Vector2(bar_x, bar_y)

func _apply_facing_visual() -> void:
	var sprite: Sprite2D = get_sprite()
	if sprite:
		_ensure_direction_textures()
		if _facing_frame >= 0 and _facing_frame < _direction_textures.size():
			sprite.texture = _direction_textures[_facing_frame]
		sprite.hframes = 1
		sprite.vframes = 1
		sprite.frame = 0
		sprite.flip_h = _facing_frame == FRAME_EAST and _facing_west

	var lance: Sprite2D = get_node_or_null("lance") as Sprite2D
	if lance:
		lance.z_index = LANCE_Z_BEHIND_PLAYER if _facing_frame == FRAME_NORTH else LANCE_Z_IN_FRONT_OF_PLAYER

func _ensure_direction_textures() -> void:
	if _spritesheet_texture == null or not _direction_textures.is_empty():
		return

	for frame_index: int in range(3):
		var texture: AtlasTexture = AtlasTexture.new()
		texture.atlas = _spritesheet_texture
		texture.region = Rect2(
			Vector2(float(frame_index * SPRITESHEET_CELL_SIZE + SPRITESHEET_PADDING), float(SPRITESHEET_PADDING)),
			SPRITESHEET_FRAME_SIZE
		)
		_direction_textures.append(texture)

func _update_sprite_tint() -> void:
	var color: Color = Color(1, 0, 0, 1) if _controls_impaired else Color(1, 1, 1, 1)
	for child in get_children():
		if child is Sprite2D:
			var sprite: Sprite2D = child
			sprite.self_modulate = color
