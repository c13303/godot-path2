extends CharacterBody2D
class_name FlowAgent

const SELECTION_OFFSET: Vector2 = Vector2(0, 8)
const PROPELLED_SHADOW_COLOR: Color = Color(1, 0, 0, 0.45)
const BLOOD_ENABLED: bool = false
const BLOOD_NODE_PATH: String = "Map/MonTilemap/BloodLayer/bloodMultiMesh2D"
const BLOOD_NODE_NAME: String = "bloodMultiMesh2D"
const BLOOD_DROP_INTERVAL: float = 0.1
const GLOBAL_CONFIG_NODE_NAME: String = "GlobalConfigNative"

var _shadow_indicator: CharacterShadow
var _show_shadow: bool = true
var _colored_shadow: bool = false
var _colored_shadow_when_selected: bool = false
var _is_propelled: bool = false
var _blood_drop_timer: float = 0.0
var _blood_layer: Node2D
var _global_config_node: Node
var _velocity_len: float = 0.0

@export var use_native_steering := true
@export var show_shadow: bool = false:
	set(value):
		_show_shadow = value
		_update_shadow()
	get:
		return _show_shadow
@export var colored_shadow: bool = false:
	set(value):
		_colored_shadow = value
		_update_shadow()
	get:
		return _colored_shadow
@export var colored_shadow_when_selected: bool = true:
	set(value):
		_colored_shadow_when_selected = value
		_update_shadow()
	get:
		return _colored_shadow_when_selected

@export var max_speed: float = 100.0
@export var max_force: float = 1200.0
@export var steering_smooth: float = 0.45
@export var flow_sample_stride: int = 2
@export var use_bilinear: bool = true

var arrived: bool = false
var arrived_reported: bool = false
var prev_dist_to_target: float = INF
var _nav_id: int = -1  # ID dans le FF/Steering
var agent_color: Color = _agent_color()
var nav_id: int = -1:
	get:
		return _nav_id
	set(value):
		_nav_id = value
		agent_color = _agent_color()
		_update_shadow()
var _is_selected: bool = false
var _is_previewed: bool = false


func _ready() -> void:
	if use_native_steering:
		set_physics_process(false)
	_update_shadow()

func _process(delta: float) -> void:
	z_index = int(position.y)
	if BLOOD_ENABLED:
		_process_blood(delta)

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
	var blood_node := _get_blood_layer()
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
	_update_shadow()

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
	_update_shadow()
	if _is_propelled:
		_blood_drop_timer = 0.0

func set_velocity_len(value: float) -> void:
	_velocity_len = value

func _exit_tree() -> void:
	if _shadow_indicator:
		_shadow_indicator.queue_free()
		_shadow_indicator = null

func _agent_color() -> Color:
	if _nav_id < 0:
		return Color(0.0, 0.75, 0.0, 0.45)
	var h: int = int(((_nav_id * 2654435761) + 1013904223) & 0xFFFFFFFF)
	var r: float = float(h & 0xFF) / 255.0
	var g: float = float((h >> 8) & 0xFF) / 255.0
	var b: float = float((h >> 16) & 0xFF) / 255.0
	return Color(r, g, b, 0.3)

func _shadow_color() -> Color:
	if _is_propelled:
		return PROPELLED_SHADOW_COLOR
	if _colored_shadow_when_selected and _is_selected:
		return agent_color
	if _is_selected:
		return Color(0, 1, 0, 0.45)
	if _colored_shadow:
		return agent_color
	return Color(0, 0, 0, 0.3)

func _update_shadow() -> void:
	if _show_shadow:
		if not _shadow_indicator:
			_shadow_indicator = CharacterShadow.new()
			_shadow_indicator.position = SELECTION_OFFSET
			add_child(_shadow_indicator)
		_shadow_indicator.color = _shadow_color()
	else:
		if _shadow_indicator:
			_shadow_indicator.queue_free()
			_shadow_indicator = null
