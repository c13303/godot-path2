extends Node2D
class_name PathPreviewRunner

# One pooled invisible preview walker that stamps fading footprints along a prepared route.
#
# This is a pure view. The chain of tile centers it walks is precomputed once per route by
# PathPreviewRoutePlanner, so the runner never touches the flow field and only samples along
# the prepared polyline. When the walker reaches the route end it teleports back to the start;
# that wrap is never counted as travelled route distance for stride stamping.

const FOOTPRINT_TEXTURE: Texture2D = preload("res://assets/sprites/house/starpath_arrow.png")
# Sheet is two 24x24 frames, each holding 16x16 footprint art inside 4px of padding.
const FOOTPRINT_FRAME_SIZE: float = 24.0
const FOOTPRINT_FRAME_CLIENT: int = 0
const FOOTPRINT_FRAME_MONSTER: int = 1
# The authored footprint points down (+Y), so align a path tangent to the sprite's forward axis.
const FOOTPRINT_HEADING_OFFSET: float = -PI * 0.5
const MIN_SEGMENT_LENGTH: float = 0.001

var _active: bool = false
var _path: PackedVector2Array = PackedVector2Array()
var _segment_lengths: Array[float] = []
var _total_length: float = 0.0
var _walker_distance: float = 0.0
var _distance_since_pair_stamp: float = 0.0
var _next_foot_side: int = 1
var _pair_stamp_count: int = 0
var _footprints: Array[Dictionary] = []
var _owned_segments: Dictionary = {}
var _footprint_frame: int = FOOTPRINT_FRAME_MONSTER
var _speed: float = 380.0
var _pair_spacing_distance: float = 10.0
var _side_offset: float = 6.0
var _footprint_scale: float = 1.0
var _footstep_lifetime: float = 2.2


func configure() -> void:
	position = Vector2.ZERO
	rotation = 0.0
	scale = Vector2.ONE
	material = null
	set_process(false)
	visible = false


func start(
	path: PackedVector2Array,
	owned_segments: Dictionary,
	footprint_frame: int,
	speed: float,
	pair_spacing_distance: float,
	side_offset: float,
	footprint_scale: float,
	footstep_lifetime: float,
	start_distance: float
) -> void:
	_path = path
	_segment_lengths.clear()
	_footprints.clear()
	_owned_segments = owned_segments.duplicate()
	_total_length = _calculate_segment_lengths(_path, _segment_lengths)
	_footprint_frame = footprint_frame
	_speed = maxf(1.0, speed)
	_pair_spacing_distance = maxf(1.0, pair_spacing_distance)
	_side_offset = maxf(0.0, side_offset)
	_footprint_scale = maxf(0.05, footprint_scale)
	_footstep_lifetime = maxf(0.05, footstep_lifetime)
	_walker_distance = clampf(start_distance, 0.0, maxf(0.0, _total_length - MIN_SEGMENT_LENGTH))
	_distance_since_pair_stamp = 0.0
	_next_foot_side = -1
	_pair_stamp_count = 0
	_active = _path.size() >= 2 and _total_length > MIN_SEGMENT_LENGTH
	if _active:
		_try_start_pair()
	visible = _active
	set_process(_active)
	queue_redraw()


func recycle() -> void:
	_active = false
	_path = PackedVector2Array()
	_segment_lengths.clear()
	_footprints.clear()
	_owned_segments.clear()
	_total_length = 0.0
	_pair_stamp_count = 0
	visible = false
	set_process(false)
	queue_redraw()


func is_active() -> bool:
	return _active


static func measure_path_length(path: PackedVector2Array) -> float:
	var total: float = 0.0
	for index: int in range(path.size() - 1):
		total += path[index].distance_to(path[index + 1])
	return total


func _process(delta: float) -> void:
	if not _active:
		return
	_age_footprints(delta)
	_advance_walker(maxf(0.0, _speed * delta))
	queue_redraw()


func _calculate_segment_lengths(path: PackedVector2Array, lengths: Array[float]) -> float:
	var total: float = 0.0
	for index: int in range(path.size() - 1):
		var segment_length: float = path[index].distance_to(path[index + 1])
		lengths.append(segment_length)
		total += segment_length
	return total


func _advance_walker(distance_to_travel: float) -> void:
	var remaining: float = distance_to_travel
	while remaining > 0.0:
		var distance_to_end: float = _total_length - _walker_distance
		if distance_to_end <= MIN_SEGMENT_LENGTH:
			_wrap_to_start()
			continue
		var travel: float = minf(remaining, distance_to_end)
		_move_along_route(travel)
		remaining -= travel
		if is_equal_approx(travel, distance_to_end) or travel >= distance_to_end:
			_wrap_to_start()


func _move_along_route(distance_to_travel: float) -> void:
	var remaining: float = distance_to_travel
	while remaining > 0.0:
		if _pair_stamp_count == 0:
			_try_start_pair()
		var distance_until_stamp: float = remaining
		if _pair_stamp_count == 1:
			distance_until_stamp = maxf(0.0, _pair_spacing_distance - _distance_since_pair_stamp)
		var step: float = minf(remaining, distance_until_stamp)
		_walker_distance = minf(_walker_distance + step, _total_length)
		if _pair_stamp_count == 1:
			_distance_since_pair_stamp += step
		remaining -= step
		if _pair_stamp_count == 1 and _distance_since_pair_stamp >= _pair_spacing_distance:
			if not _stamp_at_distance(_walker_distance, 0.0):
				_pair_stamp_count = 2
			_distance_since_pair_stamp = 0.0


func _wrap_to_start() -> void:
	_walker_distance = 0.0
	_distance_since_pair_stamp = 0.0
	if _pair_stamp_count == 1:
		_pair_stamp_count = 2


func _age_footprints(delta: float) -> void:
	for index: int in range(_footprints.size() - 1, -1, -1):
		var footprint: Dictionary = _footprints[index]
		var next_age: float = float(footprint.get("age", 0.0)) + delta
		if next_age >= _footstep_lifetime:
			_footprints.remove_at(index)
			continue
		footprint["age"] = next_age
		_footprints[index] = footprint
	if _footprints.is_empty() and _pair_stamp_count >= 2:
		_pair_stamp_count = 0
		_distance_since_pair_stamp = 0.0


func _try_start_pair() -> void:
	if _pair_stamp_count != 0 or not _footprints.is_empty():
		return
	if _stamp_at_distance(_walker_distance, 0.0):
		_distance_since_pair_stamp = 0.0


func _stamp_at_distance(route_distance: float, age: float) -> bool:
	var sample: Dictionary = _sample_path(route_distance)
	var segment_index: int = int(sample.get("segment_index", -1))
	if not _owned_segments.has(segment_index):
		return false
	var tangent: Vector2 = sample.get("tangent", Vector2.DOWN) as Vector2
	if tangent.length_squared() <= 0.0:
		return false
	var perpendicular: Vector2 = Vector2(-tangent.y, tangent.x).normalized()
	var side: int = _next_foot_side
	var center: Vector2 = (sample.get("position", Vector2.ZERO) as Vector2) + perpendicular * float(side) * _side_offset
	_footprints.append({
		"position": center,
		"heading": tangent.angle(),
		"side": side,
		"age": age,
	})
	_next_foot_side *= -1
	_pair_stamp_count = mini(_pair_stamp_count + 1, 2)
	return true


func _sample_path(route_distance: float) -> Dictionary:
	var clamped_distance: float = clampf(route_distance, 0.0, _total_length)
	var walked: float = 0.0
	for index: int in range(_segment_lengths.size()):
		var segment_length: float = _segment_lengths[index]
		if segment_length <= MIN_SEGMENT_LENGTH:
			continue
		if clamped_distance <= walked + segment_length or index == _segment_lengths.size() - 1:
			var from_point: Vector2 = _path[index]
			var to_point: Vector2 = _path[index + 1]
			var tangent: Vector2 = (to_point - from_point).normalized()
			var progress: float = clampf((clamped_distance - walked) / segment_length, 0.0, 1.0)
			return {
				"position": from_point.lerp(to_point, progress),
				"tangent": tangent,
				"segment_index": index,
			}
		walked += segment_length
	return {
		"position": _path[_path.size() - 1],
		"tangent": (_path[_path.size() - 1] - _path[_path.size() - 2]).normalized(),
		"segment_index": _segment_lengths.size() - 1,
	}


func _draw() -> void:
	if not _active:
		return
	var region: Rect2 = Rect2(float(_footprint_frame) * FOOTPRINT_FRAME_SIZE, 0.0, FOOTPRINT_FRAME_SIZE, FOOTPRINT_FRAME_SIZE)
	var frame_rect: Rect2 = Rect2(
		Vector2(-FOOTPRINT_FRAME_SIZE, -FOOTPRINT_FRAME_SIZE) * 0.5,
		Vector2(FOOTPRINT_FRAME_SIZE, FOOTPRINT_FRAME_SIZE)
	)
	for footprint: Dictionary in _footprints:
		var age: float = float(footprint.get("age", 0.0))
		var alpha: float = clampf(1.0 - age / _footstep_lifetime, 0.0, 1.0)
		if alpha <= 0.0:
			continue
		var side: int = int(footprint.get("side", 1))
		var local_center: Vector2 = to_local(footprint.get("position", Vector2.ZERO) as Vector2)
		var footprint_rotation: float = float(footprint.get("heading", 0.0)) + FOOTPRINT_HEADING_OFFSET
		draw_set_transform(local_center, footprint_rotation, Vector2(_footprint_scale * float(side), _footprint_scale))
		draw_texture_rect_region(FOOTPRINT_TEXTURE, frame_rect, region, Color(1.0, 1.0, 1.0, alpha))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
