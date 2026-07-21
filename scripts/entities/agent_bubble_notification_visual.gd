extends RefCounted
class_name AgentBubbleNotificationVisual

## Owns one local notification sprite for a FlowAgent. Reasons are independent so
## callers only control their own request for the shared visual.

const SPRITE_NAME: StringName = &"BubbleNotificationSprite2D"
const BUBBLE_TEXTURE: Texture2D = preload("res://assets/sprites/legval/bnote.png")
const LOCAL_POSITION: Vector2 = Vector2(0.0, -64.0)
const FIXED_Z_INDEX: int = 4096
const FRAME_NORMAL: int = 0

var _owner: Node2D = null
var _sprite: Sprite2D = null
var _active_reasons: Dictionary = {} # StringName -> atlas frame


func setup(owner: Node2D) -> void:
	_owner = owner


func set_bubble_notification(reason: StringName, active: bool) -> void:
	set_bubble_notification_frame(reason, active, FRAME_NORMAL)


func set_bubble_notification_frame(reason: StringName, active: bool, frame: int) -> void:
	if reason == &"":
		return
	if active:
		_active_reasons[reason] = maxi(FRAME_NORMAL, frame)
	else:
		_active_reasons.erase(reason)
	var sprite: Sprite2D = _ensure_sprite()
	if sprite != null:
		sprite.frame = _visible_frame()
		sprite.visible = not _active_reasons.is_empty()


func has_bubble_notification(reason: StringName) -> bool:
	return reason != &"" and _active_reasons.has(reason)


func _visible_frame() -> int:
	var frame: int = FRAME_NORMAL
	for raw_frame: Variant in _active_reasons.values():
		frame = maxi(frame, int(raw_frame))
	return frame


func _ensure_sprite() -> Sprite2D:
	if is_instance_valid(_sprite):
		return _sprite
	if not is_instance_valid(_owner):
		return null
	var sprite: Sprite2D = Sprite2D.new()
	sprite.name = SPRITE_NAME
	sprite.texture = BUBBLE_TEXTURE
	sprite.hframes = 3
	sprite.position = LOCAL_POSITION
	# This is deliberately independent of FlowAgent's world-Y z-index.
	sprite.z_as_relative = false
	sprite.z_index = FIXED_Z_INDEX
	sprite.y_sort_enabled = false
	sprite.visible = false
	_owner.add_child(sprite)
	_sprite = sprite
	return _sprite
