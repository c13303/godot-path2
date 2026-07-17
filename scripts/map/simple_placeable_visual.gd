extends Node2D
class_name SimplePlaceableVisual

var _sprite: Sprite2D = null
var _base_modulate: Color = Color.WHITE
var _damage_flash_tween: Tween = null
var _contact_tween: Tween = null
var _health_bar_offset: Vector2 = Vector2(0.0, -16.0)
var _contact_dance_enabled: bool = false
var _contact_dance_active: bool = false


func setup(visual_def: Dictionary) -> void:
	_sprite = Sprite2D.new()
	_sprite.name = "Sprite2D"
	_sprite.texture = _texture_from_def(visual_def)
	_sprite.offset = visual_def.get("offset", Vector2.ZERO) as Vector2
	_sprite.centered = true
	add_child(_sprite)
	_base_modulate = _sprite.modulate
	_contact_dance_enabled = bool(visual_def.get("contact_dance", false))
	_health_bar_offset = visual_def.get("health_bar_offset", Vector2(0.0, -16.0)) as Vector2


func play_damage_flash(duration: float) -> void:
	if _sprite == null or not is_instance_valid(_sprite):
		return
	if _damage_flash_tween != null and _damage_flash_tween.is_valid():
		_damage_flash_tween.kill()
	_sprite.modulate = Color(1.0, 0.12, 0.12, _base_modulate.a)
	_damage_flash_tween = create_tween()
	_damage_flash_tween.tween_property(_sprite, "modulate", _base_modulate, maxf(0.0, duration)).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func request_contact_dance(duration: float) -> void:
	if not _contact_dance_enabled or _sprite == null or not is_instance_valid(_sprite):
		return
	if _contact_tween != null and _contact_tween.is_valid():
		_contact_tween.kill()
	_sprite.rotation = -0.14
	_contact_tween = create_tween()
	_contact_tween.tween_property(_sprite, "rotation", 0.14, maxf(0.0, duration) * 0.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_contact_tween.tween_property(_sprite, "rotation", 0.0, maxf(0.0, duration) * 0.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


func set_contact_dance_active(active: bool) -> void:
	if not _contact_dance_enabled or _sprite == null or not is_instance_valid(_sprite):
		return
	_contact_dance_active = active
	if _contact_tween != null and _contact_tween.is_valid():
		_contact_tween.kill()
	if not active:
		_sprite.rotation = 0.0
		return
	_sprite.rotation = -0.14
	_contact_tween = create_tween().set_loops()
	_contact_tween.tween_property(_sprite, "rotation", 0.14, 0.08).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_contact_tween.tween_property(_sprite, "rotation", -0.14, 0.08).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func get_health_bar_anchor_world_position() -> Vector2:
	return global_position + _health_bar_offset


func _texture_from_def(visual_def: Dictionary) -> Texture2D:
	var base_texture: Texture2D = visual_def.get("texture", null) as Texture2D
	if base_texture == null:
		return null
	if not visual_def.has("atlas_coords"):
		return base_texture
	var frame_size: Vector2i = visual_def.get("frame_size", Vector2i.ZERO) as Vector2i
	var atlas_coords: Vector2i = visual_def.get("atlas_coords", Vector2i.ZERO) as Vector2i
	if frame_size.x <= 0 or frame_size.y <= 0:
		return base_texture
	var atlas_texture: AtlasTexture = AtlasTexture.new()
	atlas_texture.atlas = base_texture
	atlas_texture.region = Rect2(
		Vector2(float(atlas_coords.x * frame_size.x), float(atlas_coords.y * frame_size.y)),
		Vector2(float(frame_size.x), float(frame_size.y))
	)
	return atlas_texture
