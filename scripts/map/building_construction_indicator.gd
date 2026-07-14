extends Node2D
class_name BuildingConstructionIndicator

# One "under construction" visual for a single external sprite (a house), driven by
# BuildingConstructionOverlay. Unlike the overlay's per-cell tile ghosting, a house is one
# sprite with one progress bar: this indicator ghosts the sprite to 50% opacity and draws a
# single bar centred just above the sprite's local rect. It is added as a child of the sprite
# so its z-index stays above the house, and it restores the sprite's exact original
# modulation when construction finishes (or if it is freed early).

const GHOST_ALPHA: float = 0.5
const PROGRESS_BG_COLOR: Color = Color(0.08, 0.08, 0.08, 0.85)
const PROGRESS_FILL_COLOR: Color = Color(0.35, 0.9, 0.4, 0.95)
const PROGRESS_BAR_HEIGHT: float = 3.0
const PROGRESS_BAR_WIDTH_RATIO: float = 0.5
const BAR_MARGIN_ABOVE: float = 4.0

var _sprite: Sprite2D = null
var _original_modulate: Color = Color.WHITE
var _modulate_applied: bool = false
var _progress: float = 0.0


func setup(sprite: Sprite2D) -> void:
	_sprite = sprite
	_original_modulate = sprite.modulate
	var ghost: Color = _original_modulate
	ghost.a = _original_modulate.a * GHOST_ALPHA
	sprite.modulate = ghost
	_modulate_applied = true
	# Relative z so the bar always draws just above whatever absolute z the house resolves to.
	z_as_relative = true
	z_index = 1
	queue_redraw()


func set_progress(value: float) -> void:
	_progress = clampf(value, 0.0, 1.0)
	queue_redraw()


func finish() -> void:
	_restore_modulate()
	queue_free()


func _restore_modulate() -> void:
	if _modulate_applied and is_instance_valid(_sprite):
		_sprite.modulate = _original_modulate
	_modulate_applied = false


func _exit_tree() -> void:
	# Safety net: if the house sprite (our parent) is freed mid-construction, or the overlay is
	# torn down, still restore the sprite's original modulation exactly.
	_restore_modulate()


func _draw() -> void:
	if _sprite == null or _sprite.texture == null:
		return
	var local_rect: Rect2 = _sprite_local_rect()
	var bar_width: float = local_rect.size.x * PROGRESS_BAR_WIDTH_RATIO
	var bar_pos: Vector2 = Vector2(
		local_rect.position.x + (local_rect.size.x - bar_width) * 0.5,
		local_rect.position.y - PROGRESS_BAR_HEIGHT - BAR_MARGIN_ABOVE
	)
	draw_rect(Rect2(bar_pos, Vector2(bar_width, PROGRESS_BAR_HEIGHT)), PROGRESS_BG_COLOR)
	draw_rect(Rect2(bar_pos, Vector2(bar_width * _progress, PROGRESS_BAR_HEIGHT)), PROGRESS_FILL_COLOR)


# The sprite's texture rect in its local space. Because this indicator is a child at local
# (0,0) with identity transform, the sprite's local space is our draw space.
func _sprite_local_rect() -> Rect2:
	var tex_size: Vector2 = _sprite.texture.get_size()
	var rect_pos: Vector2 = _sprite.offset
	if _sprite.centered:
		rect_pos -= tex_size * 0.5
	return Rect2(rect_pos, tex_size)
