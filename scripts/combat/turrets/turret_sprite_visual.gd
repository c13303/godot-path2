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
const DEFAULT_SHOT_FRAMES: Array[Dictionary] = []
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
var _texture: Texture2D
var _frame_size: Vector2i = DEFAULT_FRAME_SIZE
var _frame_padding: Vector2i = DEFAULT_FRAME_PADDING
var _frame_stride_x: int = DEFAULT_FRAME_STRIDE_X
var _head_idle_frame: int = DEFAULT_HEAD_FRAME
var _shot_frames: Array[Dictionary] = []
var _shot_time_left: float = 0.0
var _shot_frame_index: int = 0


func setup(visual_def: Dictionary, direction: Vector2i) -> void:
	_clear_sprites()
	_base_position = position
	_texture = visual_def.get("texture", null) as Texture2D
	if _texture == null:
		return

	_frame_size = _vector2i_from_variant(visual_def.get("frame_size", DEFAULT_FRAME_SIZE), DEFAULT_FRAME_SIZE)
	_frame_padding = _vector2i_from_variant(visual_def.get("frame_padding", DEFAULT_FRAME_PADDING), DEFAULT_FRAME_PADDING)
	_frame_stride_x = int(visual_def.get("frame_stride_x", DEFAULT_FRAME_STRIDE_X))
	var base_frame: int = int(visual_def.get("base_frame", DEFAULT_BASE_FRAME))
	_head_idle_frame = int(visual_def.get("head_frame", DEFAULT_HEAD_FRAME))
	var head_offset: Vector2 = _vector2_from_variant(visual_def.get("head_offset", DEFAULT_HEAD_OFFSET), DEFAULT_HEAD_OFFSET)
	_shot_frames = _shot_frames_from_variant(visual_def.get("shot_frames", DEFAULT_SHOT_FRAMES))

	_base_sprite = _create_frame_sprite(_texture, _frame_region(base_frame))
	_base_sprite.name = "Base"
	_base_sprite.z_index = 0
	add_child(_base_sprite)

	_head_sprite = _create_frame_sprite(_texture, _frame_region(_head_idle_frame))
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


func play_shot_animation() -> void:
	if _head_sprite == null or _shot_frames.is_empty():
		return
	_shot_frame_index = 0
	_apply_shot_frame(_shot_frame_index)


func _process(delta: float) -> void:
	_time += delta
	_process_shot_animation(delta)
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
	_texture = null
	_shot_frames.clear()
	_shot_time_left = 0.0
	_shot_frame_index = 0


func _frame_region(frame: int) -> Rect2:
	var x: float = float(_frame_padding.x + frame * _frame_stride_x)
	var y: float = float(_frame_padding.y)
	return Rect2(Vector2(x, y), Vector2(_frame_size))


func _process_shot_animation(delta: float) -> void:
	if _head_sprite == null or _shot_time_left <= 0.0:
		return
	_shot_time_left -= delta
	while _shot_time_left <= 0.0:
		_shot_frame_index += 1
		if _shot_frame_index >= _shot_frames.size():
			_set_head_frame(_head_idle_frame)
			_shot_time_left = 0.0
			return
		var carry: float = _shot_time_left
		_apply_shot_frame(_shot_frame_index)
		_shot_time_left += carry


func _apply_shot_frame(frame_index: int) -> void:
	var frame_data: Dictionary = _shot_frames[frame_index]
	_set_head_frame(int(frame_data.get("frame", _head_idle_frame)))
	_shot_time_left = maxf(0.0, float(frame_data.get("duration", 0.0)))
	if _shot_time_left <= 0.0:
		_shot_time_left = 0.001


func _set_head_frame(frame: int) -> void:
	if _head_sprite == null:
		return
	_head_sprite.region_rect = _frame_region(frame)


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


func _shot_frames_from_variant(value: Variant) -> Array[Dictionary]:
	var frames: Array[Dictionary] = []
	if not (value is Array):
		return frames
	var raw_frames: Array = value as Array
	for raw_frame: Variant in raw_frames:
		if not (raw_frame is Dictionary):
			continue
		var frame_data: Dictionary = raw_frame as Dictionary
		frames.append({
			"frame": int(frame_data.get("frame", _head_idle_frame)),
			"duration": maxf(0.0, float(frame_data.get("duration", 0.0))),
		})
	return frames
