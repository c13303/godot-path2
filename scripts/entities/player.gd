extends CharacterBody2D
class_name PlayerCharacter

@export var acceleration: float = 900.0
@export var deceleration: float = 1200.0

## Max movement speed. 0 = inherit the global agent_max_speed from GlobalConfigNative.
@export var max_speed: float = 0.0

@export_group("Sprite")
## Path to the visual sprite child (e.g. "rosa"). Empty = first Sprite2D child.
@export var sprite_node_path: NodePath
## Local offset applied to the sprite so its feet line up with the world hitbox
## center. The hitbox center sits at (0, -world_radius) relative to this node, so
## set y to about -world_radius - sprite_height/2.
@export var sprite_offset: Vector2 = Vector2.ZERO

@export_group("Combat")
## Local offset (relative to this node) defining where all player-originated
## attacks emanate from: melee/AOE zones, thrown bombs, gun projectiles, and the
## sprites/effects they spawn. Use get_weapon_origin() to read it in world space.
@export var weapon_origin: Vector2 = Vector2.ZERO

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
	_apply_sprite_offset()
	_update_day_night_frame(GameState.is_night)
	GameState.mode_changed.connect(_on_game_mode_changed)
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

## World-space point that all player-originated attacks spawn from.
func get_weapon_origin() -> Vector2:
	return global_position + weapon_origin

func get_sprite() -> Sprite2D:
	if not sprite_node_path.is_empty():
		return get_node_or_null(sprite_node_path) as Sprite2D
	for child in get_children():
		if child is Sprite2D:
			return child
	return null

func _apply_sprite_offset() -> void:
	var sprite: Sprite2D = get_sprite()
	if sprite:
		sprite.position = sprite_offset

func _on_game_mode_changed(is_night: bool) -> void:
	_update_day_night_frame(is_night)

func _update_day_night_frame(is_night: bool) -> void:
	var sprite: Sprite2D = get_sprite()
	if sprite:
		sprite.frame = 1 if is_night else 0

func _update_sprite_tint() -> void:
	var color: Color = Color(1, 0, 0, 1) if _controls_impaired else Color(1, 1, 1, 1)
	for child in get_children():
		if child is Sprite2D:
			var sprite: Sprite2D = child
			sprite.self_modulate = color
