extends CharacterBody2D
class_name FlowAgent

const HEALTH_BAR_SIZE: Vector2 = Vector2(28.0, 4.0)
const HEALTH_BAR_POSITION: Vector2 = Vector2(-14.0, -38.0)
const HEALTH_BAR_SPRITE_GAP: float = 4.0
const FLASH_DURATION: float = 0.09
const FLASH_SHADER: Shader = preload("res://scripts/entities/enemy_flash.gdshader")

static var _shared_flash_material: ShaderMaterial

# Mission phase codes — must match ffcore::AgentPhase in agent.h.
const PHASE_NONE: int = 0
const PHASE_FLOW_IN: int = 1
const PHASE_ASTAR_IN: int = 2
const PHASE_EATING: int = 3
# Retained only to keep the enum numbering aligned with ffcore::AgentPhase in
# agent.h (FlowOut=5, WaitingNewStatus=6 depend on it). The old plant→garden-exit
# A*-out phase is gone — finished eaters attach straight to the wall-exit FF — so
# nothing in GDScript sets this phase anymore.
const PHASE_ASTAR_OUT: int = 4
const PHASE_FLOW_OUT: int = 5
# Temporary holding phase: the agent's garden assignment became invalid (garden
# deleted/rebuilt) and building_manager queued it for budgeted retargeting. Not
# gameplay behavior — just a visible debug label while the agent waits a few
# frames for a new navigation state. Mirrors ffcore::AgentPhase::WaitingNewStatus.
const PHASE_WAITING_NEW_STATUS: int = 6
const PHASE_DROWNING: int = 7

var _is_propelled: bool = false
var _controls_impaired: bool = false
var _agent_manager: Node
var _velocity_len: float = 0.0
var _eating_timer: float = 0.0
var status: String = ""
@export var max_health: int = 100
@export var drownable: bool = true
@export_range(0.0, 60.0, 0.1, "or_greater") var drowning: float = 1.0
@export_range(0.01, 10.0, 0.01, "or_greater") var drowning_update_freq: float = 0.1
var health: int = 100
var _flash_time_left: float = 0.0
var _dead: bool = false
var _paused: bool = false

@export var use_native_steering: bool = true
@export var max_speed: float = 100.0
@export var max_force: float = 1200.0
@export var steering_smooth: float = 0.45
@export var flow_sample_stride: int = 2
@export var use_bilinear: bool = true

var arrived: bool = false
var arrived_reported: bool = false
var prev_dist_to_target: float = INF
var _nav_id: int = -1  # ID dans le FF/Steering
var nav_id: int = -1:
	get:
		return _nav_id
	set(value):
		_nav_id = value
var _is_selected: bool = false
var _is_previewed: bool = false

# Directional monster sheets use a 6-frame horizontal layout:
# south / east / north / eating / unused legacy slot / drowning.
const MONSTER_DIRECTIONAL_FRAME_COUNT: int = 6
const MONSTER_FRAME_SOUTH: int = 0
const MONSTER_FRAME_EAST: int = 1
const MONSTER_FRAME_NORTH: int = 2
const MONSTER_FRAME_ROSE_EATING: int = 3
const MONSTER_FRAME_WATER_DROWNING: int = 5
const MONSTER_FRAME_LAYOUT_DIRECTIONAL_6_HORIZONTAL: StringName = &"directional_6_horizontal"
const CLIENT_DIRECTIONAL_FRAME_COUNT: int = 7
const CLIENT_FRAME_WATER_DROWNING: int = 3
const CLIENT_FRAME_TANTRUM_SOUTH: int = 4
const CLIENT_FRAME_TANTRUM_EAST: int = 5
const CLIENT_FRAME_TANTRUM_NORTH: int = 6
const CLIENT_FRAME_LAYOUT_DIRECTIONAL_7_HORIZONTAL: StringName = &"client_directional_7_horizontal"
const CLIENT_ROSE_TEXTURE: Texture2D = preload("res://assets/sprites/legval/rose.png")
const CLIENT_ROSE_TEXTURE_FRAME_COUNT: int = 3
const CLIENT_ROSE_TEXTURE_FRAME: int = 0
const CLIENT_ROSE_SCALE: Vector2 = Vector2(0.56, 0.56)
const CLIENT_ROSE_Z_ABOVE: int = 1
const CLIENT_ROSE_Z_BELOW: int = -1
const FACING_CHANGE_MIN_SECONDS: float = 0.14
const FACING_DIAGONAL_HYSTERESIS_RATIO: float = 1.20

# Legacy 4-frame sheets are kept for older monster/client/merchant textures.
const MONSTER_FRAME_IDLE: int = 0
const MONSTER_FRAME_EATING: int = 1
const MONSTER_FRAME_DROWNING: int = 3
const CLIENT_FRAME_ANGRY: int = 4
@onready var _monster_sprite: Sprite2D = $MonsterSprite2D
var _client_rose_sprite: Sprite2D
var _facing_frame: int = MONSTER_FRAME_SOUTH
var _facing_west: bool = false
var _facing_state: DirectionalFacingState = DirectionalFacingState.new()
var _last_facing_position: Vector2 = Vector2.ZERO


func _ready() -> void:
	health = max(1, max_health)
	_setup_flash_material()
	_facing_state.min_change_interval = FACING_CHANGE_MIN_SECONDS
	_facing_state.diagonal_hysteresis_ratio = FACING_DIAGONAL_HYSTERESIS_RATIO
	_last_facing_position = global_position
	queue_redraw()
	if use_native_steering:
		set_physics_process(false)

func _process(delta: float) -> void:
	z_index = int(position.y)
	if _paused:
		return
	_process_damage_flash(delta)
	_process_eating_status(delta)
	_update_directional_facing(delta)
	_update_monster_frame()
	_update_client_rose_pin()
	_last_facing_position = global_position

func take_damage(amount: int) -> bool:
	if _dead or amount <= 0:
		return false
	if _is_damage_immune_agent() and status != "drowning":
		_flash_time_left = FLASH_DURATION
		_monster_sprite.set_instance_shader_parameter("flash_amount", 1.0)
		return false
	health = max(0, health - amount)
	_flash_time_left = FLASH_DURATION
	_monster_sprite.set_instance_shader_parameter("flash_amount", 1.0)
	queue_redraw()
	if health <= 0:
		_dead = true
		return true
	return false

func _draw() -> void:
	if _is_damage_immune_agent():
		return
	var bar_position: Vector2 = _health_bar_position()
	var background_rect: Rect2 = Rect2(bar_position, HEALTH_BAR_SIZE)
	draw_rect(background_rect, Color.BLACK)
	var health_ratio: float = float(health) / float(max(1, max_health))
	var fill_size: Vector2 = Vector2((HEALTH_BAR_SIZE.x - 2.0) * health_ratio, HEALTH_BAR_SIZE.y - 2.0)
	draw_rect(Rect2(bar_position + Vector2.ONE, fill_size), Color(0.9, 0.05, 0.05, 1.0))


func _health_bar_position() -> Vector2:
	if not is_instance_valid(_monster_sprite) or _monster_sprite.texture == null:
		return HEALTH_BAR_POSITION
	var frame_height: float = float(_monster_sprite.texture.get_height()) / float(maxi(1, _monster_sprite.vframes))
	var sprite_top: float = _monster_sprite.position.y + _monster_sprite.offset.y
	if _monster_sprite.centered:
		sprite_top -= frame_height * absf(_monster_sprite.scale.y) * 0.5
	var bar_x: float = _monster_sprite.position.x + _monster_sprite.offset.x - HEALTH_BAR_SIZE.x * 0.5
	var bar_y: float = sprite_top - HEALTH_BAR_SPRITE_GAP - HEALTH_BAR_SIZE.y
	return Vector2(bar_x, bar_y)

func _setup_flash_material() -> void:
	if not is_instance_valid(_monster_sprite):
		return
	if _shared_flash_material == null:
		_shared_flash_material = ShaderMaterial.new()
		_shared_flash_material.shader = FLASH_SHADER
	_monster_sprite.material = _shared_flash_material
	_monster_sprite.set_instance_shader_parameter("flash_amount", 0.0)

func _process_damage_flash(delta: float) -> void:
	if _flash_time_left <= 0.0 or not is_instance_valid(_monster_sprite):
		return
	_flash_time_left = max(0.0, _flash_time_left - delta)
	var flash_amount: float = _flash_time_left / FLASH_DURATION
	_monster_sprite.set_instance_shader_parameter("flash_amount", flash_amount)

# Drive the spritesheet frame purely from the eating status so it can never desync.
func _update_monster_frame() -> void:
	if not is_instance_valid(_monster_sprite):
		return
	var frame: int = _directional_idle_frame() if _uses_directional_monster_frames() else MONSTER_FRAME_IDLE
	var flip_h: bool = _uses_directional_monster_frames() and _facing_west
	if _uses_directional_client_frames():
		frame = _directional_idle_frame()
		flip_h = _facing_west
	if status == "angry":
		if _uses_directional_client_frames():
			frame = _directional_client_tantrum_frame()
			flip_h = _facing_west
		else:
			frame = CLIENT_FRAME_ANGRY
			flip_h = false
	elif status == "eating":
		frame = MONSTER_FRAME_ROSE_EATING if _uses_directional_monster_frames() else MONSTER_FRAME_EATING
		flip_h = false
	elif status == "drowning":
		if _uses_directional_client_frames():
			frame = CLIENT_FRAME_WATER_DROWNING
		else:
			frame = MONSTER_FRAME_WATER_DROWNING if _uses_directional_monster_frames() else MONSTER_FRAME_DROWNING
		flip_h = false
	if _monster_sprite.frame != frame:
		_monster_sprite.frame = frame
	if _monster_sprite.flip_h != flip_h:
		_monster_sprite.flip_h = flip_h


func _update_directional_facing(delta: float) -> void:
	if not _uses_directional_monster_frames() and not _uses_directional_client_frames():
		return
	var direction: Vector2 = global_position - _last_facing_position
	if not _facing_state.face_direction(direction, delta):
		return
	if _facing_state.get_axis() == DirectionalFacingState.AXIS_X:
		_facing_frame = MONSTER_FRAME_EAST
		_facing_west = _facing_state.get_sign() == DirectionalFacingState.SIGN_NEGATIVE
	else:
		_facing_frame = MONSTER_FRAME_NORTH if _facing_state.get_sign() == DirectionalFacingState.SIGN_NEGATIVE else MONSTER_FRAME_SOUTH
		_facing_west = false


func _directional_idle_frame() -> int:
	return _facing_frame


func _uses_directional_monster_frames() -> bool:
	if not _is_monster_agent() or not is_instance_valid(_monster_sprite):
		return false
	if not has_meta("monster_sprite_frame_layout"):
		return false
	var frame_layout: StringName = StringName(str(get_meta("monster_sprite_frame_layout")))
	return frame_layout == MONSTER_FRAME_LAYOUT_DIRECTIONAL_6_HORIZONTAL and _monster_sprite.hframes >= MONSTER_DIRECTIONAL_FRAME_COUNT


func _uses_directional_client_frames() -> bool:
	if not _is_client_agent() or not is_instance_valid(_monster_sprite):
		return false
	if not has_meta("client_sprite_frame_layout"):
		return false
	var frame_layout: StringName = StringName(str(get_meta("client_sprite_frame_layout")))
	return frame_layout == CLIENT_FRAME_LAYOUT_DIRECTIONAL_7_HORIZONTAL and _monster_sprite.hframes >= CLIENT_DIRECTIONAL_FRAME_COUNT


func _directional_client_tantrum_frame() -> int:
	if _facing_frame == MONSTER_FRAME_EAST:
		return CLIENT_FRAME_TANTRUM_EAST
	if _facing_frame == MONSTER_FRAME_NORTH:
		return CLIENT_FRAME_TANTRUM_NORTH
	return CLIENT_FRAME_TANTRUM_SOUTH


func _update_client_rose_pin() -> void:
	var rose_visible: bool = _is_client_agent() and bool(get_meta("client_rose_visible", false))
	if not rose_visible:
		if is_instance_valid(_client_rose_sprite):
			_client_rose_sprite.visible = false
		return
	var rose_sprite: Sprite2D = _ensure_client_rose_sprite()
	if rose_sprite == null or not is_instance_valid(_monster_sprite) or _monster_sprite.texture == null:
		return
	rose_sprite.visible = true
	rose_sprite.position = _client_rose_pin_position()
	rose_sprite.z_index = CLIENT_ROSE_Z_BELOW if _facing_frame == MONSTER_FRAME_NORTH else CLIENT_ROSE_Z_ABOVE


func _ensure_client_rose_sprite() -> Sprite2D:
	if is_instance_valid(_client_rose_sprite):
		return _client_rose_sprite
	var sprite: Sprite2D = Sprite2D.new()
	sprite.name = "ClientRoseSprite2D"
	sprite.texture = CLIENT_ROSE_TEXTURE
	sprite.hframes = CLIENT_ROSE_TEXTURE_FRAME_COUNT
	sprite.frame = CLIENT_ROSE_TEXTURE_FRAME
	sprite.centered = true
	sprite.scale = CLIENT_ROSE_SCALE
	sprite.visible = false
	add_child(sprite)
	_client_rose_sprite = sprite
	return _client_rose_sprite


func _client_rose_pin_position() -> Vector2:
	var frame_width: float = float(_monster_sprite.texture.get_width()) / float(maxi(1, _monster_sprite.hframes))
	var frame_height: float = float(_monster_sprite.texture.get_height()) / float(maxi(1, _monster_sprite.vframes))
	var half_width: float = frame_width * absf(_monster_sprite.scale.x) * 0.5
	var half_height: float = frame_height * absf(_monster_sprite.scale.y) * 0.5
	var center: Vector2 = _monster_sprite.position + _monster_sprite.offset
	if not _monster_sprite.centered:
		center += Vector2(half_width, half_height)
	var low_half_y: float = center.y + half_height * 0.5
	if _facing_frame == MONSTER_FRAME_EAST:
		var x_sign: float = -1.0 if _facing_west else 1.0
		return Vector2(center.x + half_width * 0.5 * x_sign, low_half_y)
	return Vector2(center.x, low_half_y)


func _is_monster_agent() -> bool:
	return has_meta("agent_kind") and StringName(str(get_meta("agent_kind"))) == &"monster"


func _is_client_agent() -> bool:
	return has_meta("agent_kind") and StringName(str(get_meta("agent_kind"))) == &"client"


func _is_damage_immune_agent() -> bool:
	if not has_meta("agent_kind"):
		return false
	if status == "angry":
		return false
	var agent_kind: StringName = StringName(str(get_meta("agent_kind")))
	return agent_kind == &"client" or agent_kind == &"merchant"

# Phase label is rendered by the C++ debug overlay (SteeringSystemNative). These
# start_*/stop_* methods just push the agent's mission phase into AgentData so the
# overlay is a continuous function of state and can never desync from gameplay.
func _set_phase(phase: int, eating_seconds: float = 0.0) -> void:
	var mgr: Node = _get_agent_manager()
	if mgr and mgr.has_method("set_agent_phase") and _nav_id >= 0:
		mgr.call("set_agent_phase", _nav_id, phase, eating_seconds)

func start_eating(seconds: float) -> void:
	status = "eating"
	_eating_timer = max(0.0, seconds)
	_set_phase(PHASE_EATING, ceil(_eating_timer))

func stop_eating() -> void:
	if status == "eating":
		status = ""
	_eating_timer = 0.0
	_set_phase(PHASE_NONE)

func start_drowning(seconds: float) -> void:
	status = "drowning"
	_eating_timer = 0.0
	_set_phase(PHASE_DROWNING, ceil(maxf(seconds, 0.0)))

func stop_drowning() -> void:
	if status == "drowning":
		status = ""
		_set_phase(PHASE_NONE)

func start_flow_in() -> void:
	status = "flow_in"
	_eating_timer = 0.0
	_set_phase(PHASE_FLOW_IN)

func stop_flow_in() -> void:
	if status == "flow_in":
		status = ""
	_set_phase(PHASE_NONE)

func start_escape() -> void:
	status = "flow_out"
	_eating_timer = 0.0
	_set_phase(PHASE_FLOW_OUT)

func stop_escape() -> void:
	if status == "escape" or status == "flow_out":
		status = ""
	_set_phase(PHASE_NONE)

func start_astar_in() -> void:
	status = "astar_in"
	_eating_timer = 0.0
	_set_phase(PHASE_ASTAR_IN)

func stop_astar_in() -> void:
	if status == "astar_in":
		status = ""
	_set_phase(PHASE_NONE)

# Temporary holding state used by building_manager when this agent's garden was
# deleted/rebuilt and it is queued for retargeting. Sets the visible native phase
# to "waiting new status" so debugging is clear; the agent should not be following
# a stale path/flow while in this state (the manager detaches those before calling).
func start_waiting_new_status() -> void:
	status = "waiting_new_status"
	_eating_timer = 0.0
	_set_phase(PHASE_WAITING_NEW_STATUS)

func stop_waiting_new_status() -> void:
	if status == "waiting_new_status":
		status = ""
		_set_phase(PHASE_NONE)

func start_angry() -> void:
	status = "angry"
	_eating_timer = 0.0
	_set_phase(PHASE_FLOW_IN)

func _process_eating_status(delta: float) -> void:
	if status != "eating" or _eating_timer <= 0.0:
		return
	var prev_secs: int = int(ceil(_eating_timer))
	_eating_timer = max(0.0, _eating_timer - delta)
	# Only push when the displayed whole-second count changes (cheap, avoids per-frame calls).
	var new_secs: int = int(ceil(_eating_timer))
	if new_secs != prev_secs:
		_set_phase(PHASE_EATING, float(new_secs))

func _get_agent_manager() -> Node:
	if is_instance_valid(_agent_manager):
		return _agent_manager
	var root: Node = get_tree().get_root()
	if root:
		_agent_manager = root.find_child("AgentManagerNative", true, false)
	return _agent_manager

func set_selected(enabled: bool) -> void:
	if _is_selected == enabled:
		return

	_is_selected = enabled

	if not enabled:
		modulate = Color(1, 1, 1, 1)

func set_previewed(enabled: bool) -> void:
	if _is_previewed == enabled:
		return

	_is_previewed = enabled
	if enabled:
		modulate = Color(1.15, 1.15, 1.15, 1)
	else:
		modulate = Color(1, 1, 1, 1)

func set_propelled_state(enabled: bool) -> void:
	if _is_propelled == enabled:
		return

	_is_propelled = enabled

func set_control_impaired_state(enabled: bool) -> void:
	if _controls_impaired == enabled:
		return

	_controls_impaired = enabled
	_update_sprite_tint()

func set_paused(enabled: bool) -> void:
	_paused = enabled

func set_velocity_len(value: float) -> void:
	_velocity_len = value

func _update_sprite_tint() -> void:
	_set_sprite_tint_recursive(self, Color(1, 0, 0, 1) if _controls_impaired else Color(1, 1, 1, 1))

func _set_sprite_tint_recursive(node: Node, color: Color) -> void:
	if node is Sprite2D:
		var sprite: Sprite2D = node
		sprite.self_modulate = color
	for child in node.get_children():
		_set_sprite_tint_recursive(child, color)
