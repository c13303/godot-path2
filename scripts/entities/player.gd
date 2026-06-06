extends CharacterBody2D
class_name PlayerCharacter

@export var acceleration: float = 900.0
@export var deceleration: float = 1200.0

var _nav_id: int = -1
var _is_propelled: bool = false
var _controls_impaired: bool = false
var _velocity_len: float = 0.0

var nav_id: int = -1:
	get:
		return _nav_id
	set(value):
		_nav_id = value

func _ready() -> void:
	_align_sprite_to_bottom_center()
	set_physics_process(false)

func _process(_delta: float) -> void:
	z_index = int(position.y)

func set_propelled_state(enabled: bool) -> void:
	_is_propelled = enabled

func set_control_impaired_state(enabled: bool) -> void:
	if _controls_impaired == enabled:
		return

	_controls_impaired = enabled
	_update_sprite_tint()

func set_velocity_len(value: float) -> void:
	_velocity_len = value

func _align_sprite_to_bottom_center() -> void:
	var sprite := get_node_or_null("Sprite2D") as Sprite2D
	if not sprite or not sprite.texture:
		return

	var size: Vector2 = sprite.texture.get_size()
	if sprite.centered:
		sprite.position = Vector2(0.0, -size.y * abs(sprite.scale.y) * 0.5)
	else:
		sprite.position = Vector2(-size.x * abs(sprite.scale.x) * 0.5, -size.y * abs(sprite.scale.y))

func _update_sprite_tint() -> void:
	var color: Color = Color(1, 0, 0, 1) if _controls_impaired else Color(1, 1, 1, 1)
	for child in get_children():
		if child is Sprite2D:
			var sprite: Sprite2D = child
			sprite.self_modulate = color
