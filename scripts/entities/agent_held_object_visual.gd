extends RefCounted
class_name AgentHeldObjectVisual

# Owns the single held-object Sprite2D attached to one FlowAgent: its texture, frame,
# scale, visibility, local attachment position and front/behind z-index. It knows nothing
# about roses, hammers, agent kinds or gameplay state; callers decide what is held, where
# the pin sits, and drive any animation themselves through the transient transform.

const SPRITE_NAME: StringName = &"HeldObjectSprite2D"
const Z_ABOVE: int = 1
const Z_BELOW: int = -1

var _owner: Node2D = null
var _sprite: Sprite2D = null
# The pin the caller re-applies every frame, kept apart from the transient animation pose
# so the two can never overwrite each other.
var _rest_position: Vector2 = Vector2.ZERO
var _animation_offset: Vector2 = Vector2.ZERO
var _animation_rotation: float = 0.0


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
	clear_animation_transform()
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
	clear_animation_transform()
	if is_instance_valid(_sprite):
		_sprite.visible = false


# Drops the held visual but keeps the sprite node for the next show_object().
func clear_object() -> void:
	clear_animation_transform()
	if not is_instance_valid(_sprite):
		return
	_sprite.visible = false
	_sprite.texture = null


func is_visible() -> bool:
	return is_instance_valid(_sprite) and _sprite.visible and _sprite.texture != null


func update_attachment(local_position: Vector2, render_behind_agent: bool) -> void:
	if not is_instance_valid(_sprite):
		return
	_rest_position = local_position
	_sprite.z_index = Z_BELOW if render_behind_agent else Z_ABOVE
	_apply_pose()


# A transient pose laid over the attachment pin: offset in owner-local pixels, rotation in
# radians around the sprite's own centered pivot. This is a rendering primitive only; the
# caller owns whatever animates it and is responsible for clearing it.
func set_animation_transform(offset: Vector2, rotation_radians: float) -> void:
	_animation_offset = offset
	_animation_rotation = rotation_radians
	_apply_pose()


func clear_animation_transform() -> void:
	set_animation_transform(Vector2.ZERO, 0.0)


func _apply_pose() -> void:
	if not is_instance_valid(_sprite):
		return
	_sprite.position = _rest_position + _animation_offset
	_sprite.rotation = _animation_rotation


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
