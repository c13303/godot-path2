extends RefCounted
class_name AgentHeldObjectVisual

# Owns the single held-object Sprite2D attached to one FlowAgent: its texture, frame,
# scale, visibility, local attachment position, front/behind z-index and its temporary
# rotation tween. It knows nothing about roses, hammers, agent kinds or gameplay state;
# callers decide what is held and where the pin sits.

const SPRITE_NAME: StringName = &"HeldObjectSprite2D"
const Z_ABOVE: int = 1
const Z_BELOW: int = -1
const MIN_ROTATION_DURATION: float = 0.01

var _owner: Node2D = null
var _sprite: Sprite2D = null
var _rotation_tween: Tween = null


func setup(owner: Node2D) -> void:
	_owner = owner


# Replaces whatever the agent currently holds; there is only ever one held object.
func show_object(texture: Texture2D, hframes: int, frame: int, object_scale: Vector2) -> void:
	if texture == null:
		clear_object()
		return
	var sprite: Sprite2D = _ensure_sprite()
	if sprite == null:
		return
	_kill_rotation_tween()
	sprite.rotation = 0.0
	sprite.texture = texture
	sprite.hframes = maxi(1, hframes)
	sprite.frame = clampi(frame, 0, sprite.hframes * maxi(1, sprite.vframes) - 1)
	sprite.scale = object_scale
	sprite.visible = true


func set_frame(frame: int) -> void:
	if not is_instance_valid(_sprite) or _sprite.texture == null:
		return
	_sprite.frame = clampi(frame, 0, _sprite.hframes * maxi(1, _sprite.vframes) - 1)


func hide_object() -> void:
	stop_animation(true)
	if is_instance_valid(_sprite):
		_sprite.visible = false


# Drops the held visual but keeps the sprite node for the next show_object().
func clear_object() -> void:
	stop_animation(true)
	if not is_instance_valid(_sprite):
		return
	_sprite.visible = false
	_sprite.texture = null


func is_visible() -> bool:
	return is_instance_valid(_sprite) and _sprite.visible and _sprite.texture != null


func update_attachment(local_position: Vector2, render_behind_agent: bool) -> void:
	if not is_instance_valid(_sprite):
		return
	_sprite.position = local_position
	_sprite.z_index = Z_BELOW if render_behind_agent else Z_ABOVE


# One linear 0 -> TAU turn around the sprite's own centered pivot, then back to rest.
func rotate_full_turn(duration: float) -> void:
	if not is_visible():
		return
	_kill_rotation_tween()
	_sprite.rotation = 0.0
	var tween: Tween = _sprite.create_tween()
	tween.set_trans(Tween.TRANS_LINEAR)
	tween.tween_property(_sprite, "rotation", TAU, maxf(MIN_ROTATION_DURATION, duration))
	tween.tween_callback(Callable(self, "_on_rotation_finished"))
	_rotation_tween = tween


func stop_animation(reset_rotation: bool = true) -> void:
	_kill_rotation_tween()
	if reset_rotation and is_instance_valid(_sprite):
		_sprite.rotation = 0.0


func _on_rotation_finished() -> void:
	_rotation_tween = null
	if is_instance_valid(_sprite):
		_sprite.rotation = 0.0


func _kill_rotation_tween() -> void:
	if _rotation_tween != null and _rotation_tween.is_valid():
		_rotation_tween.kill()
	_rotation_tween = null


func _ensure_sprite() -> Sprite2D:
	if is_instance_valid(_sprite):
		return _sprite
	if not is_instance_valid(_owner):
		return null
	var sprite: Sprite2D = Sprite2D.new()
	sprite.name = SPRITE_NAME
	sprite.centered = true
	sprite.visible = false
	_owner.add_child(sprite)
	_sprite = sprite
	return _sprite
