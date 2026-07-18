class_name TurretGeometry
extends RefCounted

static func is_within_directional_angle(origin: Vector2, target: Vector2, direction: Vector2i, angle_degrees: float) -> bool:
	if angle_degrees >= 360.0:
		return true
	if direction == Vector2i.ZERO:
		return false
	var offset: Vector2 = target - origin
	if offset.is_zero_approx():
		return true
	var facing: Vector2 = Vector2(float(direction.x), float(direction.y)).normalized()
	var minimum_dot: float = cos(deg_to_rad(angle_degrees * 0.5))
	return facing.dot(offset.normalized()) >= minimum_dot
