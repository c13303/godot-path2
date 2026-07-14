extends Node2D
class_name PathPreviewRunner

signal finished(runner: PathPreviewRunner)

const IDLE_GROUP: int = 0
const FALLBACK_SAMPLE_DIRECTIONS: Array[Vector2] = [
	Vector2.RIGHT,
	Vector2.LEFT,
	Vector2.DOWN,
	Vector2.UP,
	Vector2(0.70710678, 0.70710678),
	Vector2(0.70710678, -0.70710678),
	Vector2(-0.70710678, 0.70710678),
	Vector2(-0.70710678, -0.70710678),
]

var _flow: Node
var _active: bool = false
var _group_id: int = IDLE_GROUP
var _goal_world: Vector2 = Vector2.ZERO
var _route_color: Color = Color.WHITE
var _speed: float = 180.0
var _arrival_radius: float = 12.0
var _max_lifetime: float = 8.0
var _max_zero_flow_seconds: float = 0.35
var _max_substep: float = 8.0
var _max_substeps: int = 8
var _trail_points: Array[Vector2] = []
var _trail_point_limit: int = 8
var _star_radius: float = 5.0
var _lifetime: float = 0.0
var _zero_flow_seconds: float = 0.0
var _debug_logs: bool = true


func configure(flow: Node, debug_logs: bool = true) -> void:
	_flow = flow
	_debug_logs = debug_logs
	set_process(false)
	visible = false


func start(
		group_id: int,
		start_world: Vector2,
		goal_world: Vector2,
		route_color: Color,
		speed: float,
		arrival_radius: float,
		max_lifetime: float,
		max_zero_flow_seconds: float,
		max_substep: float,
		max_substeps: int,
		trail_point_limit: int,
		star_radius: float
) -> void:
	_group_id = group_id
	_goal_world = goal_world
	_route_color = route_color
	_speed = speed
	_arrival_radius = arrival_radius
	_max_lifetime = max_lifetime
	_max_zero_flow_seconds = max_zero_flow_seconds
	_max_substep = maxf(1.0, max_substep)
	_max_substeps = maxi(1, max_substeps)
	_trail_point_limit = maxi(2, trail_point_limit)
	_star_radius = maxf(1.0, star_radius)
	_lifetime = 0.0
	_zero_flow_seconds = 0.0
	_trail_points.clear()
	global_position = start_world
	_active = group_id > IDLE_GROUP and _flow != null
	visible = _active
	set_process(_active)
	queue_redraw()


func recycle() -> void:
	_active = false
	_group_id = IDLE_GROUP
	_trail_points.clear()
	visible = false
	set_process(false)
	queue_redraw()


func is_active() -> bool:
	return _active


func _process(delta: float) -> void:
	if not _active:
		return
	_lifetime += delta
	if _lifetime >= _max_lifetime:
		_finish("max_lifetime")
		return
	if not _position_is_finite(global_position):
		_finish("non_finite_position")
		return
	if global_position.distance_to(_goal_world) <= _arrival_radius:
		_finish("arrival_distance")
		return
	if _flow == null:
		_finish("missing_flow")
		return
	if _flow.has_method("group_route_cost_at_world"):
		var cost: float = float(_flow.call("group_route_cost_at_world", _group_id, global_position))
		if not is_finite(cost):
			_finish("unreachable_cost")
			return
		if cost <= _arrival_radius:
			_finish("arrival_cost")
			return

	var remaining_distance: float = maxf(0.0, _speed * delta)
	var substeps: int = mini(_max_substeps, maxi(1, ceili(remaining_distance / _max_substep)))
	var step_distance: float = remaining_distance / float(substeps)
	for _index: int in range(substeps):
		var direction: Vector2 = _sample_direction()
		if direction == Vector2.ZERO:
			_zero_flow_seconds += delta
			if _zero_flow_seconds >= _max_zero_flow_seconds:
				_finish("zero_flow_timeout")
				return
			break
		_zero_flow_seconds = 0.0
		global_position += direction * step_distance
		if global_position.distance_to(_goal_world) <= _arrival_radius:
			_finish("arrival_after_step")
			return
	_record_trail_point(global_position)
	queue_redraw()


func _sample_direction() -> Vector2:
	var direction: Vector2 = Vector2.ZERO
	if _flow.has_method("compute_group_flow_dir"):
		var raw_dir: Variant = _flow.call("compute_group_flow_dir", _group_id, global_position)
		if raw_dir is Vector2:
			direction = raw_dir as Vector2
	else:
		direction = _sample_cost_gradient_direction()
	if not _position_is_finite(direction):
		return Vector2.ZERO
	if direction.length_squared() <= 0.0001:
		return Vector2.ZERO
	return direction.normalized()


func _sample_cost_gradient_direction() -> Vector2:
	if not _flow.has_method("group_route_cost_at_world"):
		return Vector2.ZERO
	var current_cost: float = float(_flow.call("group_route_cost_at_world", _group_id, global_position))
	if not is_finite(current_cost):
		return Vector2.ZERO
	var best_direction: Vector2 = Vector2.ZERO
	var best_cost: float = current_cost
	for sample_direction: Vector2 in FALLBACK_SAMPLE_DIRECTIONS:
		var sample_pos: Vector2 = global_position + sample_direction * _max_substep
		var sample_cost: float = float(_flow.call("group_route_cost_at_world", _group_id, sample_pos))
		if not is_finite(sample_cost):
			continue
		if sample_cost < best_cost:
			best_cost = sample_cost
			best_direction = sample_direction
	return best_direction


func _record_trail_point(world_pos: Vector2) -> void:
	if not _trail_points.is_empty() and _trail_points[_trail_points.size() - 1].distance_to(world_pos) < 2.0:
		return
	_trail_points.append(world_pos)
	while _trail_points.size() > _trail_point_limit:
		_trail_points.pop_front()


func _finish(reason: String) -> void:
	if _debug_logs:
		print("[PathPreviewRunner] recycle group=%d reason=%s pos=%s goal=%s lifetime=%.2f zero_flow=%.2f" % [
			_group_id, reason, str(global_position), str(_goal_world), _lifetime, _zero_flow_seconds
		])
	recycle()
	finished.emit(self)


func _draw() -> void:
	if not _active:
		return
	for index: int in range(1, _trail_points.size()):
		var alpha: float = float(index) / float(_trail_points.size())
		var color: Color = Color(_route_color.r, _route_color.g, _route_color.b, _route_color.a * alpha * 0.45)
		draw_line(to_local(_trail_points[index - 1]), to_local(_trail_points[index]), color, 2.0)
	_draw_star(Vector2.ZERO, _star_radius, _route_color)


func _draw_star(center: Vector2, radius: float, color: Color) -> void:
	var points: PackedVector2Array = PackedVector2Array()
	var inner_radius: float = radius * 0.45
	for index: int in range(10):
		var angle: float = -PI * 0.5 + float(index) * PI / 5.0
		var point_radius: float = radius if index % 2 == 0 else inner_radius
		points.append(center + Vector2(cos(angle), sin(angle)) * point_radius)
	draw_colored_polygon(points, color)


func _position_is_finite(value: Vector2) -> bool:
	return is_finite(value.x) and is_finite(value.y)
