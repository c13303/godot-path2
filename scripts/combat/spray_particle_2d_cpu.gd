extends CPUParticles2D
class_name SprayParticle2DCPU

@export_group("Player Velocity Adaptation")
@export_range(0.0, 2.0, 0.01, "or_greater") var player_velocity_inheritance: float = 1.0
@export_range(0.0, 5000.0, 10.0, "or_greater") var maximum_player_velocity: float = 1000.0

var _base_direction: Vector2 = Vector2.RIGHT
var _base_velocity_min: float = 0.0
var _base_velocity_max: float = 0.0
var _base_settings_captured: bool = false


func _ready() -> void:
	_capture_base_settings()


func adapt_to_player_velocity(player_velocity: Vector2, emitter_rotation: float) -> void:
	_capture_base_settings()

	var inherited_velocity: Vector2 = player_velocity * player_velocity_inheritance
	if maximum_player_velocity > 0.0:
		inherited_velocity = inherited_velocity.limit_length(maximum_player_velocity)

	var base_speed: float = (_base_velocity_min + _base_velocity_max) * 0.5
	var speed_half_range: float = (_base_velocity_max - _base_velocity_min) * 0.5
	var base_world_direction: Vector2 = _base_direction.rotated(emitter_rotation).normalized()
	var adapted_world_velocity: Vector2 = base_world_direction * base_speed + inherited_velocity
	var adapted_speed: float = adapted_world_velocity.length()

	if adapted_speed <= 0.000001:
		direction = _base_direction
		initial_velocity_min = 0.0
		initial_velocity_max = 0.0
		return

	direction = adapted_world_velocity.rotated(-emitter_rotation).normalized()
	initial_velocity_min = maxf(0.0, adapted_speed - speed_half_range)
	initial_velocity_max = adapted_speed + speed_half_range


func _capture_base_settings() -> void:
	if _base_settings_captured:
		return
	_base_direction = direction.normalized() if direction.length_squared() > 0.000001 else Vector2.RIGHT
	_base_velocity_min = initial_velocity_min
	_base_velocity_max = initial_velocity_max
	_base_settings_captured = true
