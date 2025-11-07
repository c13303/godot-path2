extends Node

@onready var steering_native = self

func _process(delta: float) -> void:
	if steering_native and steering_native.has_method("update_all_agents"):
		steering_native.update_all_agents(delta)
	
