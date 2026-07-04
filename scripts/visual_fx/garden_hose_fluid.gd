extends Node2D
class_name GardenHoseFluid

const MODE_EMPTY: int = 0
const MODE_FILL_TO_LANCE: int = 1
const MODE_FULL_TO_LANCE: int = 2
const MODE_DRAIN_FROM_RESERVOIR: int = 3
const MODE_FILL_TO_RESERVOIR: int = 4
const MODE_FULL_TO_RESERVOIR: int = 5
const MODE_DRAIN_FROM_LANCE: int = 6

@export var hose_path: NodePath
@export var fluid_width: float = 7.0
@export var fill_speed_progress_per_second: float = 3.2
@export var drain_speed_progress_per_second: float = 2.4
@export var fluid_color: Color = Color(0.2, 0.58, 1.0, 0.72)
@export var highlight_color: Color = Color(1.0, 1.0, 1.0, 0.2)
@export var highlight_width: float = 2.0

var _hose: GardenHose
var _mode: int = MODE_EMPTY
var _fluid_start: float = 0.0
var _fluid_end: float = 0.0
var _shooting_requested: bool = false
var _refill_requested: bool = false

func _ready() -> void:
	_resolve_hose()
	set_process(true)

func _process(delta: float) -> void:
	if _hose == null or not is_instance_valid(_hose):
		_resolve_hose()
	_update_state(delta)
	queue_redraw()

func begin_shooting_flow() -> void:
	_shooting_requested = true
	_refill_requested = false
	if _mode == MODE_FULL_TO_LANCE or _mode == MODE_FILL_TO_LANCE:
		return
	_mode = MODE_FILL_TO_LANCE
	_fluid_start = 0.0
	_fluid_end = clampf(_fluid_end, 0.0, 1.0)

func end_shooting_flow() -> void:
	_shooting_requested = false
	if _mode == MODE_FILL_TO_LANCE or _mode == MODE_FULL_TO_LANCE:
		_mode = MODE_DRAIN_FROM_RESERVOIR
		_fluid_start = 0.0
		_fluid_end = maxf(_fluid_end, 0.0)

func begin_refill_flow() -> void:
	_refill_requested = true
	_shooting_requested = false
	if _mode == MODE_FULL_TO_RESERVOIR or _mode == MODE_FILL_TO_RESERVOIR:
		return
	var was_empty: bool = _mode == MODE_EMPTY or _fluid_end <= _fluid_start
	_mode = MODE_FILL_TO_RESERVOIR
	_fluid_end = 1.0
	if was_empty:
		_fluid_start = 1.0
	else:
		_fluid_start = clampf(_fluid_start, 0.0, 1.0)

func end_refill_flow() -> void:
	_refill_requested = false
	if _mode == MODE_FILL_TO_RESERVOIR or _mode == MODE_FULL_TO_RESERVOIR:
		_mode = MODE_DRAIN_FROM_LANCE
		_fluid_start = minf(_fluid_start, 1.0)
		_fluid_end = 1.0

func is_ready_for_shooting() -> bool:
	return _mode == MODE_FULL_TO_LANCE

func is_ready_for_refill() -> bool:
	return _mode == MODE_FULL_TO_RESERVOIR

func request_gun_shot(_gun_id: String, _direction: Vector2, _source_agent_id: int, _fight_system: Node) -> bool:
	begin_shooting_flow()
	return is_ready_for_shooting()

func request_water_shot(_origin: Vector2, direction: Vector2, source_agent_id: int, fight_system: Node) -> bool:
	return request_gun_shot("water", direction, source_agent_id, fight_system)

func request_spray_projectile(_type_id: int, _direction: Vector2, _inherited_velocity: Vector2, _source_agent_id: int, _fight_system: Node) -> bool:
	begin_shooting_flow()
	return is_ready_for_shooting()

func request_refill(_amount: int, _fight_system: Node) -> bool:
	begin_refill_flow()
	return is_ready_for_refill()

func request_refill_visual() -> bool:
	begin_refill_flow()
	return true

func _resolve_hose() -> void:
	if not hose_path.is_empty():
		_hose = get_node_or_null(hose_path) as GardenHose
	if _hose == null:
		var parent: Node = get_parent()
		if parent != null:
			_hose = parent.get_node_or_null("GardenHose") as GardenHose

func _update_state(delta: float) -> void:
	var fill_step: float = maxf(0.0, fill_speed_progress_per_second) * delta
	var drain_step: float = maxf(0.0, drain_speed_progress_per_second) * delta
	match _mode:
		MODE_EMPTY:
			_fluid_start = 0.0
			_fluid_end = 0.0
		MODE_FILL_TO_LANCE:
			_fluid_start = 0.0
			_fluid_end = minf(1.0, _fluid_end + fill_step)
			if _fluid_end >= 1.0:
				_mode = MODE_FULL_TO_LANCE if _shooting_requested else MODE_DRAIN_FROM_RESERVOIR
		MODE_FULL_TO_LANCE:
			_fluid_start = 0.0
			_fluid_end = 1.0
			if not _shooting_requested:
				_mode = MODE_DRAIN_FROM_RESERVOIR
		MODE_DRAIN_FROM_RESERVOIR:
			_fluid_start = minf(1.0, _fluid_start + drain_step)
			if _fluid_start >= _fluid_end:
				_mode = MODE_EMPTY
		MODE_FILL_TO_RESERVOIR:
			_fluid_end = 1.0
			_fluid_start = maxf(0.0, _fluid_start - fill_step)
			if _fluid_start <= 0.0:
				_mode = MODE_FULL_TO_RESERVOIR if _refill_requested else MODE_DRAIN_FROM_LANCE
		MODE_FULL_TO_RESERVOIR:
			_fluid_start = 0.0
			_fluid_end = 1.0
			if not _refill_requested:
				_mode = MODE_DRAIN_FROM_LANCE
		MODE_DRAIN_FROM_LANCE:
			_fluid_end = maxf(0.0, _fluid_end - drain_step)
			if _fluid_end <= _fluid_start:
				_mode = MODE_EMPTY

func _draw() -> void:
	if _mode == MODE_EMPTY or _hose == null or not is_instance_valid(_hose):
		return
	var points: PackedVector2Array = _fluid_polyline(_fluid_start, _fluid_end)
	if points.size() < 2:
		return
	draw_polyline(points, fluid_color, fluid_width, true)
	if highlight_width > 0.0:
		draw_polyline(points, highlight_color, highlight_width, true)

func _fluid_polyline(start_progress: float, end_progress: float) -> PackedVector2Array:
	var result: PackedVector2Array = PackedVector2Array()
	var source: PackedVector2Array = _hose.get_hose_world_points()
	if source.size() < 2:
		return result
	var total_length: float = _polyline_length(source)
	var start_distance: float = total_length * clampf(start_progress, 0.0, 1.0)
	var end_distance: float = total_length * clampf(end_progress, 0.0, 1.0)
	if end_distance <= start_distance:
		return result

	var traversed: float = 0.0
	for index: int in range(source.size() - 1):
		var a: Vector2 = source[index]
		var b: Vector2 = source[index + 1]
		var segment_length: float = a.distance_to(b)
		if segment_length <= 0.0001:
			continue
		var segment_start: float = traversed
		var segment_end: float = traversed + segment_length
		if segment_end >= start_distance and segment_start <= end_distance:
			var from_t: float = clampf((start_distance - segment_start) / segment_length, 0.0, 1.0)
			var to_t: float = clampf((end_distance - segment_start) / segment_length, 0.0, 1.0)
			var from_point: Vector2 = to_local(a.lerp(b, from_t))
			var to_point: Vector2 = to_local(a.lerp(b, to_t))
			if result.is_empty() or result[result.size() - 1].distance_squared_to(from_point) > 0.0001:
				result.append(from_point)
			result.append(to_point)
		traversed = segment_end
		if traversed > end_distance:
			break
	return result

func _polyline_length(points: PackedVector2Array) -> float:
	var total: float = 0.0
	for index: int in range(points.size() - 1):
		total += points[index].distance_to(points[index + 1])
	return total
