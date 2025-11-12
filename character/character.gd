extends CharacterBody2D
class_name FlowAgent

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

func _ready() -> void:
	if use_native_steering:
		set_physics_process(false)
		return

func _process(_delta: float) -> void:
	z_index = int(position.y)
