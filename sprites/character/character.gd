extends CharacterBody2D
class_name FlowAgent

const BLOOD_ENABLED: bool = false
const BLOOD_NODE_PATH: String = "Map/MonTilemap/BloodLayer/bloodMultiMesh2D"
const BLOOD_NODE_NAME: String = "bloodMultiMesh2D"
const BLOOD_DROP_INTERVAL: float = 0.1
const GLOBAL_CONFIG_NODE_NAME: String = "GlobalConfigNative"

var _is_propelled: bool = false
var _controls_impaired: bool = false
var _blood_drop_timer: float = 0.0
var _blood_layer: Node2D
var _global_config_node: Node
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
	if BLOOD_ENABLED:
		_process_blood(delta)

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
	if _status_label:
		_status_label.text = "flow in"
		_status_label.visible = true

func stop_flow_in() -> void:
	if status == "flow_in":
		status = ""
	if _status_label:
		_status_label.visible = false

func start_escape() -> void:
	status = "flow_out"
	_eating_timer = 0.0
	if _status_label:
		_status_label.text = "flow out"
		_status_label.visible = true

func stop_escape() -> void:
	if status == "escape" or status == "flow_out":
		status = ""
	if _status_label:
		_status_label.visible = false

func start_astar_in() -> void:
	status = "astar_in"
	_eating_timer = 0.0
	if _status_label:
		_status_label.text = "astar_in"
		_status_label.visible = true

func stop_astar_in() -> void:
	if status == "astar_in":
		status = ""
	if _status_label:
		_status_label.visible = false

func start_astar_out() -> void:
	status = "astar_out"
	_eating_timer = 0.0
	if _status_label:
		_status_label.text = "astar_out"
		_status_label.visible = true

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
	_status_label.text = "eating %ds" % int(ceil(_eating_timer))
	_status_label.visible = true

func _process_blood(delta: float) -> void:
	if not BLOOD_ENABLED or not _is_propelled or not _should_drop_blood():
		_blood_drop_timer = 0.0
		return

	_blood_drop_timer -= delta
	if _blood_drop_timer > 0.0:
		return

	_blood_drop_timer = BLOOD_DROP_INTERVAL
	_spawn_blood_drop()

func _spawn_blood_drop() -> void:
	var blood_node: Node2D = _get_blood_layer()
	if blood_node and blood_node.has_method("spawn_blood"):
		blood_node.spawn_blood(
			blood_node.to_local(global_position)
		)


func _get_blood_layer() -> Node2D:
	if _blood_layer:
		return _blood_layer

	var scene: Node = get_tree().get_current_scene()
	if scene:
		_blood_layer = scene.get_node_or_null(BLOOD_NODE_PATH)
	if not _blood_layer:
		_blood_layer = _find_blood_node_by_name()
	if not _blood_layer:
		var tree_root: Node = get_tree().get_root()
		if tree_root:
			_blood_layer = tree_root.get_node_or_null(BLOOD_NODE_PATH)
	if not _blood_layer:
		_blood_layer = _find_blood_node_by_name()
	return _blood_layer

func _find_blood_node_by_name() -> Node2D:
	var tree = get_tree()
	if not tree:
		return null
	var root: Node = tree.get_current_scene()
	if not root:
		root = tree.get_root()
	if not root:
		return null
	return root.find_node(BLOOD_NODE_NAME, true, false) as Node2D

func _should_drop_blood() -> bool:
	var threshold: float = _movement_threshold()
	if threshold <= 0.0:
		return true
	return _velocity_len >= threshold

func _movement_threshold() -> float:
	var config: Node = _get_global_config_node()
	if config and config.has_method("get_movement_threshold"):
		return float(config.call("get_movement_threshold"))
	return 0.0

func _get_global_config_node() -> Node:
	if _global_config_node:
		return _global_config_node

	var scene: Node = get_tree().get_current_scene()
	if scene:
		_global_config_node = scene.get_node_or_null(GLOBAL_CONFIG_NODE_NAME)
	if not _global_config_node:
		var root: Node = get_tree().get_root()
		if root:
			_global_config_node = root.get_node_or_null(GLOBAL_CONFIG_NODE_NAME)
	return _global_config_node

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
	if _is_propelled:
		_blood_drop_timer = 0.0

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
