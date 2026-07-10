extends RefCounted
class_name DirectionalFacingState

const AXIS_X: int = 0
const AXIS_Y: int = 1
const SIGN_POSITIVE: int = 1
const SIGN_NEGATIVE: int = -1

var min_direction_length_squared: float = 0.000001
var min_change_interval: float = 0.12
var diagonal_hysteresis_ratio: float = 1.15

var _axis: int = AXIS_Y
var _sign: int = SIGN_POSITIVE
var _initialized: bool = false
var _time_since_change: float = INF


func face_direction(direction: Vector2, delta: float, immediate: bool = false) -> bool:
	_time_since_change += maxf(delta, 0.0)
	if direction.length_squared() <= min_direction_length_squared:
		return false

	var next_axis: int = AXIS_X if absf(direction.x) >= absf(direction.y) else AXIS_Y
	var next_sign: int = SIGN_NEGATIVE if _component_for_axis(direction, next_axis) < 0.0 else SIGN_POSITIVE

	if not _initialized or immediate:
		return _set_facing(next_axis, next_sign)
	if next_axis == _axis and next_sign == _sign:
		return false
	if _time_since_change < min_change_interval:
		return false
	if next_axis != _axis and not _passes_axis_hysteresis(direction, next_axis):
		return false

	return _set_facing(next_axis, next_sign)


func get_axis() -> int:
	return _axis


func get_sign() -> int:
	return _sign


func _set_facing(axis: int, facing_sign: int) -> bool:
	var changed: bool = not _initialized or axis != _axis or facing_sign != _sign
	_axis = axis
	_sign = facing_sign
	_initialized = true
	if changed:
		_time_since_change = 0.0
	return changed


func _passes_axis_hysteresis(direction: Vector2, next_axis: int) -> bool:
	var next_component: float = absf(_component_for_axis(direction, next_axis))
	var current_component: float = absf(_component_for_axis(direction, _axis))
	return next_component >= current_component * diagonal_hysteresis_ratio


func _component_for_axis(direction: Vector2, axis: int) -> float:
	return direction.x if axis == AXIS_X else direction.y
