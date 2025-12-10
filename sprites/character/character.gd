extends CharacterBody2D
class_name FlowAgent

const SelectionIndicator = preload("res://sprites/lapin/selection_indicator.gd")
const SELECTION_OFFSET: Vector2 = Vector2(0, 8)

var _shadow_indicator: SelectionIndicator
var _show_shadow: bool = true
var _colored_shadow: bool = false

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

@export var max_speed: float = 100.0
@export var max_force: float = 1200.0
@export var steering_smooth: float = 0.45
@export var flow_sample_stride: int = 2
@export var use_bilinear: bool = true

var arrived: bool = false
var arrived_reported: bool = false
var prev_dist_to_target: float = INF
var _sample_phase: int = 0
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

func _process(_delta: float) -> void:
	z_index = int(position.y)

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
	if _colored_shadow:
		return agent_color
	return Color(0, 0, 0, 0.3)

func _update_shadow() -> void:
	if _show_shadow:
		if not _shadow_indicator:
			_shadow_indicator = SelectionIndicator.new()
			_shadow_indicator.position = SELECTION_OFFSET
			add_child(_shadow_indicator)
		_shadow_indicator.color = _shadow_color()
	else:
		if _shadow_indicator:
			_shadow_indicator.queue_free()
			_shadow_indicator = null
