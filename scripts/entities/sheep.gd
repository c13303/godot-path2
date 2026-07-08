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
const FACING_MOVEMENT_MIN_DISTANCE_SQUARED: float = 0.25

var _agent_manager: Node
var _nav_id: int = -1
var _is_propelled: bool = false
var _controls_impaired: bool = false
var _velocity_len: float = 0.0
var _last_global_position: Vector2 = Vector2.ZERO
var _paused: bool = false
var _status: StringName = &"idle"
var _facing_row: int = ROW_SOUTH
var _facing_west: bool = false
var _frame_time: float = 0.0
var _anim_frame: int = 0

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
	_last_global_position = global_position
	_apply_sprite_frame()


func _process(delta: float) -> void:
	z_index = int(position.y)
	var current_position: Vector2 = global_position
	if _paused:
		_last_global_position = current_position
		return
	_update_facing_from_movement(current_position)
	_last_global_position = current_position
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
	_anim_frame = 0
	_set_phase(PHASE_NONE)
	_apply_sprite_frame()


func start_walking_to(direction: Vector2) -> void:
	_status = &"walking"
	_set_facing_direction(direction)
	_set_phase(PHASE_ASTAR_IN)


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


func _set_facing_direction(direction: Vector2) -> void:
	if direction.length_squared() <= 0.000001:
		return
	if absf(direction.x) >= absf(direction.y):
		_facing_row = ROW_EAST
		_facing_west = direction.x < 0.0
	else:
		_facing_row = ROW_NORTH if direction.y < 0.0 else ROW_SOUTH
		_facing_west = false
	_apply_sprite_frame()


func _update_facing_from_movement(current_position: Vector2) -> void:
	if _status != &"walking":
		return
	var movement: Vector2 = current_position - _last_global_position
	if movement.length_squared() <= FACING_MOVEMENT_MIN_DISTANCE_SQUARED:
		return
	_set_facing_direction(movement)


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
