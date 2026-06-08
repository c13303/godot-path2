extends CharacterBody2D
class_name FlowAgent

# Mission phase codes — must match ffcore::AgentPhase in agent.h.
const PHASE_NONE: int = 0
const PHASE_FLOW_IN: int = 1
const PHASE_ASTAR_IN: int = 2
const PHASE_EATING: int = 3
const PHASE_ASTAR_OUT: int = 4
const PHASE_FLOW_OUT: int = 5

var _is_propelled: bool = false
var _controls_impaired: bool = false
var _agent_manager: Node
var _velocity_len: float = 0.0
var _eating_timer: float = 0.0
var status: String = ""

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


func _ready() -> void:
	if use_native_steering:
		set_physics_process(false)

func _process(delta: float) -> void:
	z_index = int(position.y)
	_process_eating_status(delta)

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

func start_astar_out() -> void:
	status = "astar_out"
	_eating_timer = 0.0
	_set_phase(PHASE_ASTAR_OUT)

func stop_astar_out() -> void:
	if status == "astar_out":
		status = ""
	_set_phase(PHASE_NONE)

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
