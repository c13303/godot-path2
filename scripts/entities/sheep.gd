extends CharacterBody2D
class_name SheepAgent

const PHASE_NONE: int = 0
const PHASE_ASTAR_IN: int = 2
const PHASE_EATING: int = 3

const ROW_SOUTH: int = 0
const ROW_EAST: int = 1
const ROW_NORTH: int = 2
const ROW_EAT: int = 4
const WALK_FRAME_COUNT: int = 4
const FRAME_SECONDS: float = 0.16
const FACING_CHANGE_MIN_SECONDS: float = 0.14
const FACING_DIAGONAL_HYSTERESIS_RATIO: float = 1.20

var _agent_manager: Node
var _nav_id: int = -1
var _is_propelled: bool = false
var _controls_impaired: bool = false
var _velocity_len: float = 0.0
var _paused: bool = false
var _status: StringName = &"idle"
var _facing_row: int = ROW_SOUTH
var _facing_west: bool = false
var _frame_time: float = 0.0
var _anim_frame: int = 0
var _walk_direction: Vector2 = Vector2.ZERO
var _facing_state: DirectionalFacingState = DirectionalFacingState.new()

@export var max_speed: float = 100.0
@export var drownable: bool = false
@onready var _sprite: Sprite2D = $SheepSprite2D

var nav_id: int = -1:
	get:
		return _nav_id
	set(value):
		_nav_id = value


func _ready() -> void:
	set_physics_process(false)
	_facing_state.min_change_interval = FACING_CHANGE_MIN_SECONDS
	_facing_state.diagonal_hysteresis_ratio = FACING_DIAGONAL_HYSTERESIS_RATIO
	_apply_sprite_frame()


func _process(delta: float) -> void:
	z_index = int(position.y)
	if _paused:
		return
	_update_facing_from_walk_intent(delta)
	_update_animation(delta)


func set_paused(value: bool) -> void:
	_paused = value


func set_propelled_state(enabled: bool) -> void:
	_is_propelled = enabled


func set_control_impaired_state(enabled: bool) -> void:
	_controls_impaired = enabled


func set_velocity_len(value: float) -> void:
	_velocity_len = value


func start_idle() -> void:
	_status = &"idle"
	_walk_direction = Vector2.ZERO
	_anim_frame = 0
	_set_phase(PHASE_NONE)
	_apply_sprite_frame()


func start_walking_to(direction: Vector2) -> void:
	_status = &"walking"
	set_walk_direction(direction, true)
	_set_phase(PHASE_ASTAR_IN)


func set_walk_direction(direction: Vector2, immediate: bool = false) -> void:
	_walk_direction = direction
	if immediate:
		_apply_facing_direction(direction, 0.0, true)


func start_eating(seconds: float) -> void:
	_status = &"eating"
	_frame_time = 0.0
	_anim_frame = 0
	_set_phase(PHASE_EATING, ceil(maxf(seconds, 0.0)))
	_apply_sprite_frame()


func stop_eating() -> void:
	if _status == &"eating":
		_status = &"idle"
		_anim_frame = 0
		_set_phase(PHASE_NONE)
		_apply_sprite_frame()


func _update_animation(delta: float) -> void:
	if _status == &"idle":
		if _anim_frame != 0:
			_anim_frame = 0
			_apply_sprite_frame()
		return

	_frame_time += delta
	if _frame_time < FRAME_SECONDS:
		return
	_frame_time = 0.0
	_anim_frame = (_anim_frame + 1) % WALK_FRAME_COUNT
	_apply_sprite_frame()


func _apply_facing_direction(direction: Vector2, delta: float, immediate: bool = false) -> void:
	if not _facing_state.face_direction(direction, delta, immediate):
		return
	if _facing_state.get_axis() == DirectionalFacingState.AXIS_X:
		_facing_row = ROW_EAST
		_facing_west = _facing_state.get_sign() == DirectionalFacingState.SIGN_NEGATIVE
	else:
		_facing_row = ROW_NORTH if _facing_state.get_sign() == DirectionalFacingState.SIGN_NEGATIVE else ROW_SOUTH
		_facing_west = false
	_apply_sprite_frame()


func _update_facing_from_walk_intent(delta: float) -> void:
	if _status != &"walking":
		return
	_apply_facing_direction(_walk_direction, delta)


func _apply_sprite_frame() -> void:
	if _sprite == null:
		return
	_sprite.vframes = 5
	_sprite.hframes = WALK_FRAME_COUNT
	_sprite.frame_coords = Vector2i(_anim_frame, ROW_EAT if _status == &"eating" else _facing_row)
	_sprite.flip_h = _facing_row == ROW_EAST and _facing_west
	_sprite.self_modulate = Color(1, 0.85, 0.85, 1) if _controls_impaired else Color.WHITE


func _set_phase(phase: int, eating_seconds: float = 0.0) -> void:
	var mgr: Node = _get_agent_manager()
	if mgr != null and mgr.has_method("set_agent_phase") and _nav_id >= 0:
		mgr.call("set_agent_phase", _nav_id, phase, eating_seconds)


func _get_agent_manager() -> Node:
	if is_instance_valid(_agent_manager):
		return _agent_manager
	var root: Node = get_tree().get_root()
	if root != null:
		_agent_manager = root.find_child("AgentManagerNative", true, false)
	return _agent_manager
