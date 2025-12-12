extends Node2D

@export var canvas: Node

func _unhandled_input(event):
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		canvas.stamp_world(get_global_mouse_position())
		canvas.flush()
