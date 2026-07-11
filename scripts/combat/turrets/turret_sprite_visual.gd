extends Node2D
class_name TurretSpriteVisual

# Owns composed turret sprite visuals: fixed base plus independently rotated head.
# Gameplay ownership stays with BuildingObjectManager/TurretSystem.

const DEFAULT_FRAME_SIZE: Vector2i = Vector2i(32, 32)
const DEFAULT_FRAME_PADDING: Vector2i = Vector2i(2, 2)
const DEFAULT_FRAME_STRIDE_X: int = 36
const DEFAULT_BASE_FRAME: int = 0
const DEFAULT_HEAD_FRAME: int = 1
const DEFAULT_HEAD_OFFSET: Vector2 = Vector2(0.0, -16.0)
const CONTACT_SWAY_DEGREES: float = 5.0
const CONTACT_SWAY_SPEED: float = 1.1
const CONTACT_BREATHE_AMOUNT: float = 0.05
const CONTACT_BREATHE_SPEED: float = 1.4
const CONTACT_BOB_PIXELS: float = 1.0

var _base_sprite: Sprite2D
var _head_sprite: Sprite2D
var _time: float = 0.0
var _contact_until: float = 0.0
var _sway_phase: float = 0.0
var _breathe_phase: float = 0.0
var _base_position: Vector2 = Vector2.ZERO


func setup(visual_def: Dictionary, direction: Vector2i) -> void:
	_clear_sprites()
	_base_position = position
	var texture: Texture2D = visual_def.get("texture", null) as Texture2D
	if texture == null:
		return

	var frame_size: Vector2i = _vector2i_from_variant(visual_def.get("frame_size", DEFAULT_FRAME_SIZE), DEFAULT_FRAME_SIZE)
	var frame_padding: Vector2i = _vector2i_from_variant(visual_def.get("frame_padding", DEFAULT_FRAME_PADDING), DEFAULT_FRAME_PADDING)
	var frame_stride_x: int = int(visual_def.get("frame_stride_x", DEFAULT_FRAME_STRIDE_X))
	var base_frame: int = int(visual_def.get("base_frame", DEFAULT_BASE_FRAME))
	var head_frame: int = int(visual_def.get("head_frame", DEFAULT_HEAD_FRAME))
	var head_offset: Vector2 = _vector2_from_variant(visual_def.get("head_offset", DEFAULT_HEAD_OFFSET), DEFAULT_HEAD_OFFSET)

	_base_sprite = _create_frame_sprite(texture, _frame_region(base_frame, frame_padding, frame_size, frame_stride_x))
	_base_sprite.name = "Base"
	_base_sprite.z_index = 0
	add_child(_base_sprite)

	_head_sprite = _create_frame_sprite(texture, _frame_region(head_frame, frame_padding, frame_size, frame_stride_x))
	_head_sprite.name = "Head"
	_head_sprite.position = head_offset
	_head_sprite.z_index = 1
	add_child(_head_sprite)

	set_direction(direction)


func request_contact_dance(duration: float) -> void:
	_contact_until = maxf(_contact_until, _time + maxf(0.0, duration))
	if _sway_phase == 0.0 and _breathe_phase == 0.0:
		_sway_phase = randf() * TAU
		_breathe_phase = randf() * TAU


func _process(delta: float) -> void:
	_time += delta
	if _time >= _contact_until:
		position = _base_position
		scale = Vector2.ONE
		rotation = 0.0
		return
	var sway: float = deg_to_rad(CONTACT_SWAY_DEGREES) * sin(_time * CONTACT_SWAY_SPEED * TAU + _sway_phase)
	var sy: float = 1.0 + CONTACT_BREATHE_AMOUNT * sin(_time * CONTACT_BREATHE_SPEED * TAU + _breathe_phase)
	var sx: float = 1.0 / sy
	var bob: float = -CONTACT_BOB_PIXELS * absf(sin(_time * CONTACT_BREATHE_SPEED * TAU * 0.5 + _sway_phase))
	position = _base_position + Vector2(0.0, bob)
	scale = Vector2(sx, sy)
	rotation = sway


func set_direction(direction: Vector2i) -> void:
	if _head_sprite == null:
		return
	_head_sprite.rotation = _rotation_for_direction(direction)


func _create_frame_sprite(texture: Texture2D, region: Rect2) -> Sprite2D:
	var sprite: Sprite2D = Sprite2D.new()
	sprite.texture = texture
	sprite.region_enabled = true
	sprite.region_rect = region
	sprite.centered = true
	sprite.z_as_relative = true
	return sprite


func _clear_sprites() -> void:
	for child: Node in get_children():
		child.queue_free()
	_base_sprite = null
	_head_sprite = null


func _frame_region(frame: int, padding: Vector2i, frame_size: Vector2i, frame_stride_x: int) -> Rect2:
	var x: float = float(padding.x + frame * frame_stride_x)
	var y: float = float(padding.y)
	return Rect2(Vector2(x, y), Vector2(frame_size))


func _rotation_for_direction(direction: Vector2i) -> float:
	if direction == BuildDirectionRules.DIRECTION_DOWN:
		return PI * 0.5
	if direction == BuildDirectionRules.DIRECTION_LEFT:
		return PI
	if direction == BuildDirectionRules.DIRECTION_UP:
		return -PI * 0.5
	return 0.0


func _vector2i_from_variant(value: Variant, fallback: Vector2i) -> Vector2i:
	if value is Vector2i:
		return value as Vector2i
	if value is Vector2:
		var vector_value: Vector2 = value as Vector2
		return Vector2i(int(vector_value.x), int(vector_value.y))
	if value is Array and (value as Array).size() == 2:
		var array_value: Array = value as Array
		return Vector2i(int(array_value[0]), int(array_value[1]))
	return fallback


func _vector2_from_variant(value: Variant, fallback: Vector2) -> Vector2:
	if value is Vector2:
		return value as Vector2
	if value is Vector2i:
		var vector_i_value: Vector2i = value as Vector2i
		return Vector2(float(vector_i_value.x), float(vector_i_value.y))
	if value is Array and (value as Array).size() == 2:
		var array_value: Array = value as Array
		return Vector2(float(array_value[0]), float(array_value[1]))
	return fallback
