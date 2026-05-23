extends CharacterBody2D
class_name PlayerCharacter

var _nav_id: int = -1
var _is_propelled: bool = false
var _velocity_len: float = 0.0

var nav_id: int = -1:
	get:
		return _nav_id
	set(value):
		_nav_id = value

func _ready() -> void:
	set_physics_process(false)

func _process(_delta: float) -> void:
	z_index = int(position.y)

func set_propelled_state(enabled: bool) -> void:
	_is_propelled = enabled

func set_velocity_len(value: float) -> void:
	_velocity_len = value
