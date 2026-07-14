extends Node2D
class_name PathPreviewRunner

const IDLE_GROUP: int = 0
const GOAL_ROUTE_COST: float = 0.001
const PROGRESS_DISTANCE: float = 0.25
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

var _flow: Node = null
var _active: bool = false
var _group_id: int = IDLE_GROUP
var _world_position: Vector2 = Vector2.ZERO
var _goal_world: Vector2 = Vector2.ZERO
var _route_color: Color = Color.WHITE
var _speed: float = 180.0
var _arrival_radius: float = 12.0
var _stalled_timeout: float = 5.0
var _max_substep: float = 8.0
var _max_substeps: int = 8
var _trail_points: Array[Vector2] = []
var _trail_point_limit: int = 8
var _star_radius: float = 5.0
var _stalled_seconds: float = 0.0
var _last_progress_position: Vector2 = Vector2.ZERO
var _best_distance_to_goal: float = INF
var _best_route_cost: float = INF


func configure(flow: Node, _preview_z_index: int) -> void:
	_flow = flow
	position = Vector2.ZERO
	rotation = 0.0
	scale = Vector2.ONE
	set_process(false)
	visible = false


func start(
	group_id: int,
	start_world: Vector2,
	goal_world: Vector2,
	route_color: Color,
	speed: float,
	arrival_radius: float,
	stalled_timeout: float,
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
	_stalled_timeout = maxf(1.0, stalled_timeout)
	_max_substep = maxf(1.0, max_substep)
	_max_substeps = maxi(1, max_substeps)
	_trail_point_limit = maxi(2, trail_point_limit)
	_star_radius = maxf(1.0, star_radius)
	_stalled_seconds = 0.0
	_trail_points.clear()
	_world_position = start_world
	_last_progress_position = start_world
	_best_distance_to_goal = start_world.distance_to(goal_world)
	_best_route_cost = _route_cost_at(start_world)
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
	if not _position_is_finite(_world_position):
		_finish("non_finite_position")
		return
	if _world_position.distance_to(_goal_world) <= _arrival_radius:
		_finish("arrival_distance")
		return
	if _flow == null:
		_finish("missing_flow")
		return
	var route_cost: float = _route_cost_at(_world_position)
	if not is_finite(route_cost):
		_finish("unreachable_cost")
		return

	var remaining_distance: float = maxf(0.0, _speed * delta)
	var substeps: int = mini(_max_substeps, maxi(1, ceili(remaining_distance / _max_substep)))
	var step_distance: float = remaining_distance / float(substeps)
	for _index: int in range(substeps):
		var direction: Vector2 = _sample_direction()
		if direction == Vector2.ZERO:
			route_cost = _route_cost_at(_world_position)
			if is_finite(route_cost) and route_cost <= GOAL_ROUTE_COST:
				var remaining: float = _world_position.distance_to(_goal_world)
				if remaining <= _arrival_radius:
					_finish("arrival_at_goal_cell")
					return
				var direction_to_goal: Vector2 = _world_position.direction_to(_goal_world)
				var movement: float = minf(step_distance, remaining)
				_world_position += direction_to_goal * movement
				if _world_position.distance_to(_goal_world) <= _arrival_radius:
					_finish("arrival_after_goal_step")
					return
				continue
			break
		_world_position += direction * step_distance
		if _world_position.distance_to(_goal_world) <= _arrival_radius:
			_finish("arrival_after_step")
			return

	_update_stalled_watchdog(delta)
	if not _active:
		return
	_record_trail_point(_world_position)
	queue_redraw()


func _update_stalled_watchdog(delta: float) -> void:
	var distance_to_goal: float = _world_position.distance_to(_goal_world)
	var route_cost: float = _route_cost_at(_world_position)
	var position_progress: bool = _last_progress_position.distance_to(_world_position) >= PROGRESS_DISTANCE
	var distance_progress: bool = distance_to_goal <= _best_distance_to_goal - PROGRESS_DISTANCE
	var cost_progress: bool = is_finite(route_cost) and route_cost < _best_route_cost - GOAL_ROUTE_COST
	if position_progress or distance_progress or cost_progress:
		_stalled_seconds = 0.0
		_last_progress_position = _world_position
		_best_distance_to_goal = minf(_best_distance_to_goal, distance_to_goal)
		if is_finite(route_cost):
			_best_route_cost = minf(_best_route_cost, route_cost)
		return
	_stalled_seconds += delta
	if _stalled_seconds >= _stalled_timeout:
		_finish("stalled")


func _route_cost_at(world_pos: Vector2) -> float:
	if _flow == null or not _flow.has_method("group_route_cost_at_world"):
		return INF
	return float(_flow.call("group_route_cost_at_world", _group_id, world_pos))


func _sample_direction() -> Vector2:
	var direction: Vector2 = Vector2.ZERO
	if _flow.has_method("compute_group_flow_dir"):
		var raw_dir: Variant = _flow.call("compute_group_flow_dir", _group_id, _world_position)
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
	var current_cost: float = _route_cost_at(_world_position)
	if not is_finite(current_cost):
		return Vector2.ZERO
	var best_direction: Vector2 = Vector2.ZERO
	var best_cost: float = current_cost
	for sample_direction: Vector2 in FALLBACK_SAMPLE_DIRECTIONS:
		var sample_pos: Vector2 = _world_position + sample_direction * _max_substep
		var sample_cost: float = _route_cost_at(sample_pos)
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


func _finish(_reason: String) -> void:
	recycle()


func _draw() -> void:
	if not _active:
		return
	for index: int in range(1, _trail_points.size()):
		var alpha: float = float(index) / float(_trail_points.size())
		var color: Color = Color(_route_color.r, _route_color.g, _route_color.b, _route_color.a * alpha * 0.45)
		draw_line(to_local(_trail_points[index - 1]), to_local(_trail_points[index]), color, 2.0)
	_draw_star(to_local(_world_position), _star_radius, _route_color)


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
