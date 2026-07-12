extends Control
class_name TutorialArrow

const ARROW_TEXTURE: Texture2D = preload("res://assets/sprites/legval/tutorial_arrow.png")
const ARROW_SIZE: Vector2 = Vector2(64.0, 32.0)
const ICON_GAP: float = 10.0
const QUICKBAR_CENTER_OFFSET_X: float = 14.0
const QUICKBAR_OVERLAP: float = 9.0
const OSCILLATION_PIXELS: float = 5.0
const OSCILLATION_SPEED: float = 5.0
const POINT_LEFT_ROTATION: float = 0.0
const POINT_RIGHT_ROTATION: float = PI
const POINT_DOWN_ROTATION: float = PI * 1.5

var _arrow: TextureRect
var _shadow: TextureRect
var _base_position: Vector2 = Vector2.ZERO
var _time: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shadow = _make_arrow_rect(Color(0.0, 0.0, 0.0, 0.35))
	_shadow.name = "Shadow"
	_arrow = _make_arrow_rect(Color.WHITE)
	_arrow.name = "Arrow"
	add_child(_shadow)
	add_child(_arrow)
	hide_arrow()


func point_left_at(target_rect: Rect2, delta: float) -> void:
	_base_position = Vector2(
		target_rect.position.x + target_rect.size.x + ICON_GAP,
		target_rect.position.y + target_rect.size.y * 0.5 - ARROW_SIZE.y * 0.5
	)
	_apply_transform(POINT_LEFT_ROTATION, delta)


func point_right_at(target_rect: Rect2, delta: float) -> void:
	_base_position = Vector2(
		target_rect.position.x - ICON_GAP - ARROW_SIZE.x,
		target_rect.position.y + target_rect.size.y * 0.5 - ARROW_SIZE.y * 0.5
	)
	_apply_transform(POINT_RIGHT_ROTATION, delta)


func point_down_at(target_rect: Rect2, delta: float) -> void:
	_base_position = Vector2(
		target_rect.position.x + target_rect.size.x * 0.5 - ARROW_SIZE.x * 0.5 + QUICKBAR_CENTER_OFFSET_X,
		target_rect.position.y - ARROW_SIZE.y * 0.5 + QUICKBAR_OVERLAP
	)
	_apply_transform(POINT_DOWN_ROTATION, delta)


func hide_arrow() -> void:
	if _arrow != null:
		_arrow.visible = false
	if _shadow != null:
		_shadow.visible = false


func _make_arrow_rect(color: Color) -> TextureRect:
	var arrow: TextureRect = TextureRect.new()
	arrow.texture = ARROW_TEXTURE
	arrow.custom_minimum_size = ARROW_SIZE
	arrow.size = ARROW_SIZE
	arrow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	arrow.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	arrow.pivot_offset = ARROW_SIZE * 0.5
	arrow.z_index = 500
	arrow.modulate = color
	return arrow


func _apply_transform(rotation_radians: float, delta: float) -> void:
	if _arrow == null or _shadow == null:
		return
	_time += delta
	var offset: Vector2 = Vector2(0.0, sin(_time * OSCILLATION_SPEED) * OSCILLATION_PIXELS)
	_arrow.visible = true
	_shadow.visible = true
	_arrow.global_position = _base_position + offset
	_shadow.global_position = _base_position + offset + Vector2(3.0, 3.0)
	_arrow.rotation = rotation_radians
	_shadow.rotation = rotation_radians
