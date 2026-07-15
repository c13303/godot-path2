extends Node2D
class_name PathPreviewRunner

# One pooled invisible preview Walk Animation section that stamps fading footprints along a
# prepared route. It is a pure view: PathPreviewRoutePlanner owns the tile-center path, while
# this runner only samples that cached polyline by arc length.

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
var _cumulative_lengths: Array[float] = []
var _total_length: float = 0.0
var _owned_segments: Dictionary = {}
var _footprint_frame: int = FOOTPRINT_FRAME_MONSTER
var _walk_speed: float = 128.0
var _stride_distance: float = 16.0
var _side_offset: float = 6.0
var _fade_duration: float = 0.45
var _footprint_scale: float = 1.0
var _section_start_distance: float = 0.0
var _section_boundary_distance: float = 0.0
var _section_step_count: int = 0
var _current_path_distance: float = 0.0
var _next_local_step_index: int = 0
var _held_left: Dictionary = {}
var _fading_left: Dictionary = {}
var _held_right: Dictionary = {}
var _fading_right: Dictionary = {}


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
	walk_speed: float,
	stride_distance: float,
	side_offset: float,
	fade_duration: float,
	footprint_scale: float,
	section_start_distance: float,
	section_boundary_distance: float,
	section_step_count: int
) -> void:
	_path = path
	_segment_lengths.clear()
	_cumulative_lengths.clear()
	_owned_segments = owned_segments.duplicate()
	_total_length = _calculate_path_length_cache(_path, _segment_lengths, _cumulative_lengths)
	_footprint_frame = footprint_frame
	_walk_speed = maxf(1.0, walk_speed)
	_stride_distance = maxf(1.0, stride_distance)
	_side_offset = maxf(0.0, side_offset)
	_fade_duration = maxf(0.05, fade_duration)
	_footprint_scale = maxf(0.05, footprint_scale)
	_section_start_distance = clampf(section_start_distance, 0.0, _total_length)
	_section_boundary_distance = clampf(section_boundary_distance, _section_start_distance, _total_length)
	_section_step_count = maxi(0, section_step_count)
	_current_path_distance = _section_start_distance
	_next_local_step_index = 0
	_clear_footprints()
	_active = (
		_path.size() >= 2
		and _total_length > MIN_SEGMENT_LENGTH
		and _section_step_count >= 2
		and _section_boundary_distance > _section_start_distance + MIN_SEGMENT_LENGTH
	)
	if _active:
		_try_stamp_next_step()
	visible = _active
	set_process(_active)
	queue_redraw()


func recycle() -> void:
	_active = false
	_path = PackedVector2Array()
	_segment_lengths.clear()
	_cumulative_lengths.clear()
	_owned_segments.clear()
	_total_length = 0.0
	_section_start_distance = 0.0
	_section_boundary_distance = 0.0
	_section_step_count = 0
	_current_path_distance = 0.0
	_next_local_step_index = 0
	_clear_footprints()
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
	_age_fading_footprints(delta)
	_advance_section(maxf(0.0, _walk_speed * delta))
	queue_redraw()


func _calculate_path_length_cache(
	path: PackedVector2Array,
	segment_lengths: Array[float],
	cumulative_lengths: Array[float]
) -> float:
	var total: float = 0.0
	for index: int in range(path.size() - 1):
		cumulative_lengths.append(total)
		var segment_length: float = path[index].distance_to(path[index + 1])
		segment_lengths.append(segment_length)
		total += segment_length
	return total


func _advance_section(distance_to_travel: float) -> void:
	var remaining: float = distance_to_travel
	while remaining > 0.0:
		var distance_to_boundary: float = _section_boundary_distance - _current_path_distance
		if distance_to_boundary <= MIN_SEGMENT_LENGTH:
			_wrap_to_section_start()
			continue
		var next_step_distance: float = _next_step_path_distance()
		var distance_to_next_step: float = next_step_distance - _current_path_distance
		var distance_to_event: float = distance_to_boundary
		if _next_local_step_index < _section_step_count and distance_to_next_step > MIN_SEGMENT_LENGTH:
			distance_to_event = minf(distance_to_boundary, distance_to_next_step)
		var travel: float = minf(remaining, distance_to_event)
		_current_path_distance = minf(_current_path_distance + travel, _section_boundary_distance)
		remaining -= travel
		while (
			_next_local_step_index < _section_step_count
			and _current_path_distance + MIN_SEGMENT_LENGTH >= _next_step_path_distance()
		):
			_try_stamp_next_step()
		if _current_path_distance + MIN_SEGMENT_LENGTH >= _section_boundary_distance:
			_wrap_to_section_start()


func _wrap_to_section_start() -> void:
	_current_path_distance = _section_start_distance
	_next_local_step_index = 0
	_try_stamp_next_step()


func _next_step_path_distance() -> float:
	return _section_start_distance + float(_next_local_step_index) * _stride_distance


func _try_stamp_next_step() -> void:
	if _next_local_step_index >= _section_step_count:
		return
	var step_distance: float = _next_step_path_distance()
	var sample: Dictionary = _sample_path(step_distance)
	var segment_index: int = int(sample.get("segment_index", -1))
	var is_left: bool = _next_local_step_index % 2 == 0
	if _owned_segments.has(segment_index):
		_stamp_sample(sample, _next_local_step_index)
	else:
		_retire_held_footprint(is_left)
	_next_local_step_index += 1


func _stamp_sample(sample: Dictionary, local_step_index: int) -> void:
	var tangent: Vector2 = sample.get("tangent", Vector2.DOWN) as Vector2
	if tangent.length_squared() <= 0.0:
		return
	var normalized_tangent: Vector2 = tangent.normalized()
	var is_left: bool = local_step_index % 2 == 0
	var perpendicular: Vector2 = Vector2(-normalized_tangent.y, normalized_tangent.x)
	var side_sign: float = -1.0 if is_left else 1.0
	var path_position: Vector2 = sample.get("position", Vector2.ZERO) as Vector2
	var final_position: Vector2 = path_position + perpendicular * side_sign * _side_offset
	var footprint: Dictionary = {
		"position": final_position,
		"heading": normalized_tangent.angle(),
		"side_sign": side_sign,
	}
	if is_left:
		if not _held_left.is_empty():
			_fading_left = _held_left
			_fading_left["fade_age"] = 0.0
		_held_left = footprint
	else:
		if not _held_right.is_empty():
			_fading_right = _held_right
			_fading_right["fade_age"] = 0.0
		_held_right = footprint


func _retire_held_footprint(is_left: bool) -> void:
	if is_left:
		if not _held_left.is_empty():
			_fading_left = _held_left
			_fading_left["fade_age"] = 0.0
			_held_left = {}
	else:
		if not _held_right.is_empty():
			_fading_right = _held_right
			_fading_right["fade_age"] = 0.0
			_held_right = {}


func _age_fading_footprints(delta: float) -> void:
	_fading_left = _age_fading_footprint(_fading_left, delta)
	_fading_right = _age_fading_footprint(_fading_right, delta)


func _age_fading_footprint(footprint: Dictionary, delta: float) -> Dictionary:
	if footprint.is_empty():
		return footprint
	var next_age: float = float(footprint.get("fade_age", 0.0)) + delta
	if next_age >= _fade_duration:
		return {}
	footprint["fade_age"] = next_age
	return footprint


func _clear_footprints() -> void:
	_held_left = {}
	_fading_left = {}
	_held_right = {}
	_fading_right = {}


func _sample_path(route_distance: float) -> Dictionary:
	var clamped_distance: float = clampf(route_distance, 0.0, _total_length)
	for index: int in range(_segment_lengths.size()):
		var walked: float = _cumulative_lengths[index]
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
	_draw_footprint(region, frame_rect, _fading_left, _fading_alpha(_fading_left))
	_draw_footprint(region, frame_rect, _fading_right, _fading_alpha(_fading_right))
	_draw_footprint(region, frame_rect, _held_left, 1.0)
	_draw_footprint(region, frame_rect, _held_right, 1.0)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _fading_alpha(footprint: Dictionary) -> float:
	if footprint.is_empty():
		return 0.0
	var fade_age: float = float(footprint.get("fade_age", 0.0))
	return clampf(1.0 - fade_age / _fade_duration, 0.0, 1.0)


func _draw_footprint(region: Rect2, frame_rect: Rect2, footprint: Dictionary, alpha: float) -> void:
	if footprint.is_empty() or alpha <= 0.0:
		return
	var side_sign: float = float(footprint.get("side_sign", 1.0))
	var local_center: Vector2 = to_local(footprint.get("position", Vector2.ZERO) as Vector2)
	var footprint_rotation: float = float(footprint.get("heading", 0.0)) + FOOTPRINT_HEADING_OFFSET
	draw_set_transform(local_center, footprint_rotation, Vector2(_footprint_scale * side_sign, _footprint_scale))
	draw_texture_rect_region(FOOTPRINT_TEXTURE, frame_rect, region, Color(1.0, 1.0, 1.0, alpha))
