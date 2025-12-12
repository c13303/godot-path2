extends Node2D

@export var bloodcanvas: Node

func _unhandled_input(event):
	return
	if event is InputEventMouseButton \
	and event.button_index == MOUSE_BUTTON_LEFT \
	and event.pressed:
		bloodcanvas.blood_spot(get_global_mouse_position())
