extends Node2D
class_name PathPreviewRunner

# One pooled preview arrow travelling a prepared route.
#
# This is a pure view. The chain of tile centers it walks is precomputed once per route by
# PathPreviewRoutePlanner, so the runner never touches the flow field, never allocates while
# running, and simply interpolates from one cell center to the next. It only ever changes
# heading on a center, which is what makes the route read as "through the tiles" rather than
# along their edges, and leftover travel carries into the next segment so a fast arrow
# follows every turn instead of skipping past it.

const ARROW_TEXTURE: Texture2D = preload("res://assets/sprites/house/starpath_arrow.png")
# Sheet is two 24x24 frames, each holding a 16x16 arrow inside 4px of padding. Drawing the
# whole frame centered therefore centers the arrow itself.
const ARROW_FRAME_SIZE: float = 24.0
const ARROW_FRAME_CLIENT: int = 0
const ARROW_FRAME_MONSTER: int = 1
# The sheet's arrows point down (+Y), so a heading has to be turned back a quarter turn.
const ARROW_HEADING_OFFSET: float = -PI * 0.5
# Halo passes drawn under the arrow, largest and faintest first.
const GLOW_SCALES: Array[float] = [2.5, 1.6]
const GLOW_ALPHAS: Array[float] = [0.20, 0.35]
const TRAIL_MIN_SPACING: float = 3.0
const TRAIL_CORE_WIDTH: float = 2.0
const TRAIL_GLOW_WIDTH: float = 5.0
const TRAIL_CORE_ALPHA: float = 0.75
const TRAIL_GLOW_ALPHA: float = 0.30

var _active: bool = false
var _path: PackedVector2Array = PackedVector2Array()
var _segment_index: int = 0
var _segment_progress: float = 0.0
var _world_position: Vector2 = Vector2.ZERO
var _heading: float = 0.0
var _arrow_frame: int = ARROW_FRAME_MONSTER
var _tint: Color = Color.WHITE
var _speed: float = 380.0
var _arrow_scale: float = 1.25
var _trail_points: Array[Vector2] = []
var _trail_point_limit: int = 18


func configure() -> void:
	position = Vector2.ZERO
	rotation = 0.0
	scale = Vector2.ONE
	# Additive blending is what turns the flat sprite into a glow, and the material is
	# built once per pooled runner rather than per emitted arrow.
	if material == null:
		var glow_material: CanvasItemMaterial = CanvasItemMaterial.new()
		glow_material.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		material = glow_material
	set_process(false)
	visible = false


func start(
	path: PackedVector2Array,
	tint: Color,
	arrow_frame: int,
	speed: float,
	arrow_scale: float,
	trail_point_limit: int
) -> void:
	_path = path
	_tint = tint
	_arrow_frame = arrow_frame
	_speed = maxf(1.0, speed)
	_arrow_scale = maxf(0.05, arrow_scale)
	_trail_point_limit = maxi(2, trail_point_limit)
	_segment_index = 0
	_segment_progress = 0.0
	_trail_points.clear()
	_active = _path.size() >= 2
	if _active:
		_world_position = _path[0]
		_heading = (_path[1] - _path[0]).angle()
	visible = _active
	set_process(_active)
	queue_redraw()


func recycle() -> void:
	_active = false
	_path = PackedVector2Array()
	_trail_points.clear()
	visible = false
	set_process(false)
	queue_redraw()


func is_active() -> bool:
	return _active


func _process(delta: float) -> void:
	if not _active:
		return
	var remaining: float = maxf(0.0, _speed * delta)
	while remaining > 0.0 and _segment_index < _path.size() - 1:
		var from_point: Vector2 = _path[_segment_index]
		var to_point: Vector2 = _path[_segment_index + 1]
		var segment_length: float = from_point.distance_to(to_point)
		if segment_length <= 0.0:
			_segment_index += 1
			continue
		var travel: float = minf(remaining, segment_length - _segment_progress)
		_segment_progress += travel
		remaining -= travel
		_world_position = from_point.lerp(to_point, clampf(_segment_progress / segment_length, 0.0, 1.0))
		_heading = (to_point - from_point).angle()
		if _segment_progress >= segment_length:
			# Reached this cell's center: turn here, and let the unspent travel continue
			# into the next segment so no route segment is ever jumped over.
			_segment_index += 1
			_segment_progress = 0.0
	if _segment_index >= _path.size() - 1:
		recycle()
		return
	_record_trail_point(_world_position)
	queue_redraw()


func _record_trail_point(world_pos: Vector2) -> void:
	if not _trail_points.is_empty() and _trail_points[_trail_points.size() - 1].distance_to(world_pos) < TRAIL_MIN_SPACING:
		return
	_trail_points.append(world_pos)
	while _trail_points.size() > _trail_point_limit:
		_trail_points.pop_front()


func _draw() -> void:
	if not _active:
		return
	_draw_trail()
	_draw_arrow()


func _draw_trail() -> void:
	if _trail_points.size() < 2:
		return
	var last_index: int = _trail_points.size() - 1
	for index: int in range(1, _trail_points.size()):
		# Oldest segment is nearly gone, newest is brightest, so the trail reads as a tail
		# fading out behind the arrow.
		var fade: float = float(index) / float(last_index)
		var from_point: Vector2 = to_local(_trail_points[index - 1])
		var to_point: Vector2 = to_local(_trail_points[index])
		draw_line(from_point, to_point, _tint_with_alpha(fade * TRAIL_GLOW_ALPHA), TRAIL_GLOW_WIDTH)
		draw_line(from_point, to_point, _tint_with_alpha(fade * TRAIL_CORE_ALPHA), TRAIL_CORE_WIDTH)


func _draw_arrow() -> void:
	var region: Rect2 = Rect2(float(_arrow_frame) * ARROW_FRAME_SIZE, 0.0, ARROW_FRAME_SIZE, ARROW_FRAME_SIZE)
	var frame_rect: Rect2 = Rect2(
		Vector2(-ARROW_FRAME_SIZE, -ARROW_FRAME_SIZE) * 0.5,
		Vector2(ARROW_FRAME_SIZE, ARROW_FRAME_SIZE)
	)
	var local_center: Vector2 = to_local(_world_position)
	var arrow_rotation: float = _heading + ARROW_HEADING_OFFSET
	for index: int in range(GLOW_SCALES.size()):
		draw_set_transform(local_center, arrow_rotation, Vector2.ONE * (_arrow_scale * GLOW_SCALES[index]))
		draw_texture_rect_region(ARROW_TEXTURE, frame_rect, region, _tint_with_alpha(GLOW_ALPHAS[index]))
	# Core last so the arrow itself stays the brightest part of the glow.
	draw_set_transform(local_center, arrow_rotation, Vector2.ONE * _arrow_scale)
	draw_texture_rect_region(ARROW_TEXTURE, frame_rect, region, _tint)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _tint_with_alpha(alpha: float) -> Color:
	return Color(_tint.r, _tint.g, _tint.b, _tint.a * alpha)
