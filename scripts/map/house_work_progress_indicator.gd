extends Node2D
class_name HouseWorkProgressIndicator

const PROGRESS_BG_COLOR: Color = Color(0.08, 0.08, 0.08, 0.85)
const PROGRESS_FILL_COLOR: Color = Color(0.35, 0.9, 0.4, 0.95)
const PROGRESS_BAR_HEIGHT: float = 3.0
const PROGRESS_BAR_WIDTH_RATIO: float = 0.5
const BAR_MARGIN_ABOVE: float = 10.0

var _sprite: Sprite2D = null
var _progress: float = 0.0


func setup(sprite: Sprite2D) -> void:
	_sprite = sprite
	z_as_relative = true
	z_index = 2
	queue_redraw()


func set_progress(value: float) -> void:
	_progress = clampf(value, 0.0, 1.0)
	visible = true
	queue_redraw()


func _draw() -> void:
	if _sprite == null or not is_instance_valid(_sprite) or _sprite.texture == null:
		return
	var local_rect: Rect2 = _sprite_local_rect()
	var bar_width: float = local_rect.size.x * PROGRESS_BAR_WIDTH_RATIO
	var bar_pos: Vector2 = Vector2(
		local_rect.position.x + (local_rect.size.x - bar_width) * 0.5,
		local_rect.position.y - PROGRESS_BAR_HEIGHT - BAR_MARGIN_ABOVE
	)
	draw_rect(Rect2(bar_pos, Vector2(bar_width, PROGRESS_BAR_HEIGHT)), PROGRESS_BG_COLOR)
	draw_rect(Rect2(bar_pos, Vector2(bar_width * _progress, PROGRESS_BAR_HEIGHT)), PROGRESS_FILL_COLOR)


func _sprite_local_rect() -> Rect2:
	var tex_size: Vector2 = _sprite.texture.get_size()
	var rect_pos: Vector2 = _sprite.offset
	if _sprite.centered:
		rect_pos -= tex_size * 0.5
	return Rect2(rect_pos, tex_size)
