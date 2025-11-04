extends Node
class_name PathManager

@export var flow: FlowField
@export var flow_enabled: bool = true

var _last_goal_cell: Vector2i = Vector2i.MIN
var _last_request_frame: int = -1
var _last_request_ms: int = 0
var _last_version: int = -1

var last_rebuild_ms: float = 0.0

func _ready() -> void:
	set_process(true)
	if flow != null:
		_last_version = flow.flow_version()

func _process(_delta: float) -> void:
	if flow == null:
		return
	var v: int = flow.flow_version()
	if v != _last_version:
		_last_version = v
		if _last_request_ms > 0:
			last_rebuild_ms = float(Time.get_ticks_msec() - _last_request_ms)

func is_ready() -> bool:
	if flow == null:
		return false
	return flow.is_ready()

func set_goal(goal_world: Vector2) -> void:
	if flow == null or not flow_enabled:
		return
	var cell: Vector2i = flow.world_to_cell(goal_world)
	var frame_now: int = Engine.get_frames_drawn()
	if _last_goal_cell == cell and _last_request_frame == frame_now:
		return
	_last_goal_cell = cell
	_last_request_frame = frame_now
	_last_request_ms = Time.get_ticks_msec()
	flow.rebuild_async(goal_world)

func sample_dir(world_pos: Vector2) -> Vector2:
	if not flow_enabled or flow == null:
		return Vector2.ZERO
	if not flow.is_ready():
		return Vector2.ZERO
	return flow.sample_dir_world_bilinear(world_pos)
