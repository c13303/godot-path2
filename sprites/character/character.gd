extends CharacterBody2D
class_name FlowAgent

const SelectionIndicator = preload("res://sprites/lapin/selection_indicator.gd")
const SELECTION_OFFSET: Vector2 = Vector2(0, 8)

@export var use_native_steering := true

@export var max_speed: float = 100.0
@export var max_force: float = 1200.0
@export var steering_smooth: float = 0.45
@export var flow_sample_stride: int = 2
@export var use_bilinear: bool = true

var arrived: bool = false
var arrived_reported: bool = false
var prev_dist_to_target: float = INF
var _sample_phase: int = 0
var nav_id: int = -1  # ID dans le FF/Steering
var _selection_indicator: SelectionIndicator
var _is_selected: bool = false
var _is_previewed: bool = false


func _ready() -> void:
	if use_native_steering:
		set_physics_process(false)
		return

func _process(_delta: float) -> void:
	z_index = int(position.y)

func set_selected(enabled: bool) -> void:
	if _is_selected == enabled:
		return

	_is_selected = enabled
	if enabled:
		if not _selection_indicator:
			_selection_indicator = SelectionIndicator.new()
			_selection_indicator.position = SELECTION_OFFSET
			add_child(_selection_indicator)
	else:
		if _selection_indicator:
			_selection_indicator.queue_free()
			_selection_indicator = null

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
	if _selection_indicator:
		_selection_indicator.queue_free()
		_selection_indicator = null
