extends Node2D
class_name GardenHose

const RESERVOIR_GROUP: StringName = &"reservoirs"

@export var lance_path: NodePath
@export var player_path: NodePath
@export var building_object_manager_path: NodePath
@export var reservoir_socket_offset: Vector2 = Vector2(0.0, -8.0)
@export var hose_radius: float = 5.0
@export var border_width: float = 1.25
@export var highlight_width: float = 1.0
@export var segment_length: float = 16.0
@export var slack_length: float = 96.0
@export var min_segments: int = 16
@export var max_segments: int = 220
@export var constraint_iterations: int = 7
@export_range(0.0, 1.0, 0.01) var damping: float = 0.86
@export var spool_interval_seconds: float = 0.035
@export var max_spool_segments_per_step: int = 2
@export var initial_wave_offset: float = 56.0
@export var render_subdivisions: int = 3

@onready var _left_border: Line2D = $LeftBorder
@onready var _right_border: Line2D = $RightBorder
@onready var _highlight: Line2D = $Highlight

var _lance: Node2D
var _player: Node2D
var _building_object_manager: Node
var _points: Array[Vector2] = []
var _previous_points: Array[Vector2] = []
var _active_reservoir: Node2D
var _spool_elapsed: float = 0.0
var _reservoirs_dirty: bool = true
var _building_signals_connected: bool = false
var _cached_reservoirs: Array[Node2D] = []

func _ready() -> void:
	z_as_relative = false
	_resolve_references()
	_configure_lines()
	_connect_building_object_manager()
	set_process(true)

func _process(delta: float) -> void:
	if _lance == null or not is_instance_valid(_lance):
		_resolve_references()
	if not _building_signals_connected:
		_resolve_references()
		_connect_building_object_manager()
	if _reservoirs_dirty:
		_refresh_reservoirs()

	var start: Vector2 = _hose_start()
	var reservoir: Node2D = _closest_reservoir(start)
	if reservoir == null:
		_set_lines_visible(false)
		_clear_simulation()
		return

	var reservoir_anchor: Vector2 = reservoir.global_position + reservoir_socket_offset
	var lance_anchor: Vector2 = start
	_update_verlet_hose(reservoir, reservoir_anchor, lance_anchor, delta)
	_set_lines_visible(true)

func _resolve_references() -> void:
	if not lance_path.is_empty():
		_lance = get_node_or_null(lance_path) as Node2D
	if _lance == null:
		_resolve_player()
		if _player != null:
			_lance = _player.get_node_or_null("lance") as Node2D
	if not building_object_manager_path.is_empty():
		_building_object_manager = get_node_or_null(building_object_manager_path)

func _resolve_player() -> void:
	if _player != null and is_instance_valid(_player):
		return
	if not player_path.is_empty():
		_player = get_node_or_null(player_path) as Node2D
		if _player != null:
			return
	for node: Node in get_tree().get_nodes_in_group("player"):
		var player: Node2D = node as Node2D
		if player != null and is_instance_valid(player):
			_player = player
			return

func _configure_lines() -> void:
	_left_border.width = border_width
	_right_border.width = border_width
	_highlight.width = highlight_width
	_left_border.default_color = Color(1.0, 1.0, 1.0, 0.45)
	_right_border.default_color = Color(1.0, 1.0, 1.0, 0.45)
	_highlight.default_color = Color(1.0, 1.0, 1.0, 0.2)

	for line: Line2D in [_left_border, _right_border, _highlight]:
		line.joint_mode = Line2D.LINE_JOINT_ROUND
		line.begin_cap_mode = Line2D.LINE_CAP_ROUND
		line.end_cap_mode = Line2D.LINE_CAP_ROUND
		line.antialiased = true

func _connect_building_object_manager() -> void:
	if _building_object_manager == null:
		return
	var changed_callable: Callable = Callable(self, "_on_building_changed")
	if _building_object_manager.has_signal("building_added") and not _building_object_manager.is_connected(&"building_added", changed_callable):
		_building_object_manager.connect(&"building_added", changed_callable)
	if _building_object_manager.has_signal("building_removed") and not _building_object_manager.is_connected(&"building_removed", changed_callable):
		_building_object_manager.connect(&"building_removed", changed_callable)
	_building_signals_connected = true

func _on_building_changed(_cell: Vector2i, item_id: String) -> void:
	if item_id == "reservoir":
		_reservoirs_dirty = true

func _refresh_reservoirs() -> void:
	_cached_reservoirs.clear()
	for node: Node in get_tree().get_nodes_in_group(RESERVOIR_GROUP):
		var reservoir: Node2D = node as Node2D
		if reservoir != null and is_instance_valid(reservoir):
			_cached_reservoirs.append(reservoir)
	_reservoirs_dirty = false

func _closest_reservoir(from_position: Vector2) -> Node2D:
	var closest: Node2D = null
	var closest_distance_squared: float = INF
	for reservoir: Node2D in _cached_reservoirs:
		if reservoir == null or not is_instance_valid(reservoir):
			_reservoirs_dirty = true
			continue
		var distance_squared: float = from_position.distance_squared_to(reservoir.global_position)
		if distance_squared < closest_distance_squared:
			closest_distance_squared = distance_squared
			closest = reservoir
	return closest

func _hose_start() -> Vector2:
	if _lance != null and is_instance_valid(_lance):
		return _lance.global_position
	_resolve_player()
	if _player != null and is_instance_valid(_player):
		if _player.has_method("get_weapon_origin"):
			return _player.call("get_weapon_origin") as Vector2
		return _player.global_position
	return global_position

func _update_verlet_hose(reservoir: Node2D, reservoir_anchor: Vector2, lance_anchor: Vector2, delta: float) -> void:
	var target_segments: int = _target_segment_count(reservoir_anchor, lance_anchor)
	if _active_reservoir != reservoir or _points.size() < 2:
		_initialize_hose(reservoir, reservoir_anchor, lance_anchor, target_segments)
	else:
		_adjust_spooled_length(target_segments, reservoir_anchor, lance_anchor, delta)

	_pin_anchors(reservoir_anchor, lance_anchor)
	_integrate_points(delta)
	_pin_anchors(reservoir_anchor, lance_anchor)
	for _iteration: int in range(maxi(1, constraint_iterations)):
		_solve_distance_constraints()
		_pin_anchors(reservoir_anchor, lance_anchor)
	_render_points()

func _target_segment_count(reservoir_anchor: Vector2, lance_anchor: Vector2) -> int:
	var safe_segment_length: float = maxf(1.0, segment_length)
	var safe_min_segments: int = maxi(2, min_segments)
	var safe_max_segments: int = maxi(safe_min_segments, max_segments)
	var desired_length: float = reservoir_anchor.distance_to(lance_anchor) + maxf(0.0, slack_length)
	var desired_segments: int = ceili(desired_length / safe_segment_length)
	return clampi(desired_segments, safe_min_segments, safe_max_segments)

func _initialize_hose(reservoir: Node2D, reservoir_anchor: Vector2, lance_anchor: Vector2, segment_count: int) -> void:
	_active_reservoir = reservoir
	_points.clear()
	_previous_points.clear()

	var count: int = maxi(2, segment_count + 1)
	var tangent: Vector2 = lance_anchor - reservoir_anchor
	var side: Vector2 = Vector2.RIGHT
	if tangent.length_squared() > 0.000001:
		side = tangent.orthogonal().normalized()
	for index: int in range(count):
		var t: float = float(index) / float(count - 1)
		var wave: float = sin(t * TAU * 2.0) * sin(t * PI)
		var point: Vector2 = reservoir_anchor.lerp(lance_anchor, t) + side * wave * initial_wave_offset
		_points.append(point)
		_previous_points.append(point)
	_pin_anchors(reservoir_anchor, lance_anchor)

func _adjust_spooled_length(target_segments: int, reservoir_anchor: Vector2, lance_anchor: Vector2, delta: float) -> void:
	_spool_elapsed += delta
	if _spool_elapsed < maxf(0.001, spool_interval_seconds):
		return
	_spool_elapsed = 0.0

	var current_segments: int = maxi(0, _points.size() - 1)
	var segment_difference: int = target_segments - current_segments
	if segment_difference == 0:
		return

	var steps: int = mini(abs(segment_difference), maxi(1, max_spool_segments_per_step))
	for _step: int in range(steps):
		if segment_difference > 0:
			_spool_out_segment(reservoir_anchor, lance_anchor)
		elif _points.size() > maxi(3, min_segments + 1):
			_rewind_segment()

func _spool_out_segment(reservoir_anchor: Vector2, lance_anchor: Vector2) -> void:
	if _points.size() < 2:
		return
	var next_point: Vector2 = _points[1]
	var tangent: Vector2 = lance_anchor - reservoir_anchor
	var side: Vector2 = Vector2.RIGHT
	if tangent.length_squared() > 0.000001:
		side = tangent.orthogonal().normalized()
	var wave_sign: float = -1.0 if _points.size() % 2 == 0 else 1.0
	var point: Vector2 = reservoir_anchor.lerp(next_point, 0.45) + side * wave_sign * segment_length * 0.35
	_points.insert(1, point)
	_previous_points.insert(1, point)

func _rewind_segment() -> void:
	if _points.size() <= 3:
		return
	_points.remove_at(1)
	_previous_points.remove_at(1)

func _pin_anchors(reservoir_anchor: Vector2, lance_anchor: Vector2) -> void:
	if _points.size() < 2:
		return
	var last_index: int = _points.size() - 1
	_points[0] = reservoir_anchor
	_previous_points[0] = reservoir_anchor
	_points[last_index] = lance_anchor
	_previous_points[last_index] = lance_anchor

func _integrate_points(_delta: float) -> void:
	for index: int in range(1, _points.size() - 1):
		var current: Vector2 = _points[index]
		var velocity: Vector2 = (current - _previous_points[index]) * damping
		_previous_points[index] = current
		_points[index] = current + velocity

func _solve_distance_constraints() -> void:
	var safe_segment_length: float = maxf(1.0, segment_length)
	for index: int in range(_points.size() - 1):
		var a: Vector2 = _points[index]
		var b: Vector2 = _points[index + 1]
		var delta: Vector2 = b - a
		var distance: float = delta.length()
		if distance <= 0.0001:
			continue
		var difference: float = (distance - safe_segment_length) / distance
		var correction: Vector2 = delta * difference
		if index == 0:
			_points[index + 1] = b - correction
		elif index == _points.size() - 2:
			_points[index] = a + correction
		else:
			_points[index] = a + correction * 0.5
			_points[index + 1] = b - correction * 0.5

func _render_points() -> void:
	var center_points: Array[Vector2] = _smoothed_render_points()
	var left_points: PackedVector2Array = PackedVector2Array()
	var right_points: PackedVector2Array = PackedVector2Array()
	var highlight_points: PackedVector2Array = PackedVector2Array()
	for index: int in range(center_points.size()):
		var point: Vector2 = center_points[index]
		var normal: Vector2 = _render_normal(center_points, index)
		left_points.append(to_local(point + normal * hose_radius))
		right_points.append(to_local(point - normal * hose_radius))
		highlight_points.append(to_local(point + normal * hose_radius * 0.45))
	_left_border.points = left_points
	_right_border.points = right_points
	_highlight.points = highlight_points

func get_hose_world_points() -> PackedVector2Array:
	var world_points: PackedVector2Array = PackedVector2Array()
	var center_points: Array[Vector2] = _smoothed_render_points()
	for point: Vector2 in center_points:
		world_points.append(point)
	return world_points

func sample_world_position(progress: float) -> Vector2:
	var points: PackedVector2Array = get_hose_world_points()
	if points.is_empty():
		return global_position
	if points.size() == 1:
		return points[0]

	var clamped_progress: float = clampf(progress, 0.0, 1.0)
	var total_length: float = _polyline_length(points)
	if total_length <= 0.0001:
		return points[points.size() - 1]

	var target_distance: float = total_length * clamped_progress
	var traversed: float = 0.0
	for index: int in range(points.size() - 1):
		var a: Vector2 = points[index]
		var b: Vector2 = points[index + 1]
		var segment_distance: float = a.distance_to(b)
		if segment_distance <= 0.0001:
			continue
		if traversed + segment_distance >= target_distance:
			var segment_t: float = (target_distance - traversed) / segment_distance
			return a.lerp(b, segment_t)
		traversed += segment_distance
	return points[points.size() - 1]

func get_hose_length() -> float:
	return _polyline_length(get_hose_world_points())

func _polyline_length(points: PackedVector2Array) -> float:
	var total: float = 0.0
	for index: int in range(points.size() - 1):
		total += points[index].distance_to(points[index + 1])
	return total

func _clear_simulation() -> void:
	_points.clear()
	_previous_points.clear()
	_active_reservoir = null
	_spool_elapsed = 0.0

func _smoothed_render_points() -> Array[Vector2]:
	var rendered: Array[Vector2] = []
	if _points.size() <= 2:
		for point: Vector2 in _points:
			rendered.append(point)
		return rendered

	var subdivisions: int = maxi(1, render_subdivisions)
	for segment_index: int in range(_points.size() - 1):
		for step: int in range(subdivisions):
			if segment_index > 0 and step == 0:
				continue
			var t: float = float(step) / float(subdivisions)
			rendered.append(_catmull_rom_render_point(segment_index, t))
	rendered.append(_points[_points.size() - 1])
	return rendered

func _catmull_rom_render_point(segment_index: int, t: float) -> Vector2:
	var p0: Vector2 = _points[maxi(segment_index - 1, 0)]
	var p1: Vector2 = _points[segment_index]
	var p2: Vector2 = _points[mini(segment_index + 1, _points.size() - 1)]
	var p3: Vector2 = _points[mini(segment_index + 2, _points.size() - 1)]
	var t_squared: float = t * t
	var t_cubed: float = t_squared * t
	return (p1 * 2.0 + (p2 - p0) * t + (p0 * 2.0 - p1 * 5.0 + p2 * 4.0 - p3) * t_squared + (-p0 + p1 * 3.0 - p2 * 3.0 + p3) * t_cubed) * 0.5

func _set_lines_visible(lines_visible: bool) -> void:
	_left_border.visible = lines_visible
	_right_border.visible = lines_visible
	_highlight.visible = lines_visible

func _render_normal(points: Array[Vector2], index: int) -> Vector2:
	if points.size() < 2:
		return Vector2.UP
	var previous_index: int = maxi(index - 1, 0)
	var next_index: int = mini(index + 1, points.size() - 1)
	var tangent: Vector2 = points[next_index] - points[previous_index]
	if tangent.length_squared() <= 0.000001:
		return Vector2.UP
	return tangent.orthogonal().normalized()
