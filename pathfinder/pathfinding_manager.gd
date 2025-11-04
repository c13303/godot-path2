extends Node
class_name PathManager

@export var flow_enabled: bool = true

var last_rebuild_ms: float = 0.0

func _ready() -> void:
	set_process(true)

func _process(_delta: float) -> void:
	pass

func is_ready() -> bool:
	return false

func set_goal(goal_world: Vector2) -> void:
	pass

func sample_dir(world_pos: Vector2) -> Vector2:
	return Vector2.ZERO
 
