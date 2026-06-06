extends CharacterBody2D
class_name FlowAgent

const STEERING_SYSTEM_NODE_PATH: String = "CPP/SteeringSystemNative"

var _is_propelled: bool = false
var _controls_impaired: bool = false
var _steering_debug_node: Node
var _velocity_len: float = 0.0
var _status_label: Label
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
	_status_label = get_node_or_null("StatusLabel") as Label
	if _status_label:
		_status_label.visible = false
	if use_native_steering:
		set_physics_process(false)

func _process(delta: float) -> void:
	z_index = int(position.y)
	_process_eating_status(delta)
	_process_status_label_visibility()

func start_eating(seconds: float) -> void:
	status = "eating"
	_eating_timer = max(0.0, seconds)
	_update_eating_label()

func stop_eating() -> void:
	if status == "eating":
		status = ""
	_eating_timer = 0.0
	if _status_label:
		_status_label.visible = false

func start_flow_in() -> void:
	status = "flow_in"
	_eating_timer = 0.0
	_show_status_label("flow in")

func stop_flow_in() -> void:
	if status == "flow_in":
		status = ""
	if _status_label:
		_status_label.visible = false

func start_escape() -> void:
	status = "flow_out"
	_eating_timer = 0.0
	_show_status_label("flow out")

func stop_escape() -> void:
	if status == "escape" or status == "flow_out":
		status = ""
	if _status_label:
		_status_label.visible = false

func start_astar_in() -> void:
	status = "astar_in"
	_eating_timer = 0.0
	_show_status_label("astar_in")

func stop_astar_in() -> void:
	if status == "astar_in":
		status = ""
	if _status_label:
		_status_label.visible = false

func start_astar_out() -> void:
	status = "astar_out"
	_eating_timer = 0.0
	_show_status_label("astar_out")

func stop_astar_out() -> void:
	if status == "astar_out":
		status = ""
	if _status_label:
		_status_label.visible = false

func _process_eating_status(delta: float) -> void:
	if status != "eating" or _eating_timer <= 0.0:
		return
	_eating_timer = max(0.0, _eating_timer - delta)
	_update_eating_label()

func _update_eating_label() -> void:
	if not _status_label:
		return
	if _eating_timer <= 0.0:
		_status_label.visible = false
		return
	_show_status_label("eating %ds" % int(ceil(_eating_timer)))

func _show_status_label(text: String) -> void:
	if not _status_label:
		return
	_status_label.text = text
	_status_label.visible = _status_labels_enabled()

func _process_status_label_visibility() -> void:
	if not _status_label:
		return
	if not _status_labels_enabled():
		_status_label.visible = false
		return
	if status == "":
		return
	if status == "eating":
		if _eating_timer > 0.0:
			_update_eating_label()
		return
	_status_label.visible = true

func _status_labels_enabled() -> bool:
	var debug_node: Node = _get_steering_debug_node()
	if debug_node and debug_node.has_method("get_debug_show_agent_state_labels"):
		return bool(debug_node.call("get_debug_show_agent_state_labels"))
	return false

func _get_steering_debug_node() -> Node:
	if is_instance_valid(_steering_debug_node):
		return _steering_debug_node
	var scene: Node = get_tree().get_current_scene()
	if scene:
		_steering_debug_node = scene.get_node_or_null(STEERING_SYSTEM_NODE_PATH)
	if not _steering_debug_node:
		var root: Node = get_tree().get_root()
		if root:
			_steering_debug_node = root.find_child("SteeringSystemNative", true, false)
	return _steering_debug_node

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
