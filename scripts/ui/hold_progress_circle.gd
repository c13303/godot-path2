extends Control
class_name HoldProgressCircle

@export var radius: float = 18.0
@export var stroke_width: float = 4.0
@export var background_color: Color = Color(0.0, 0.0, 0.0, 0.35)
@export var progress_color: Color = Color(1.0, 0.88, 0.22, 0.95)

var _progress: float = 0.0
var progress: float = 0.0:
	set(value):
		_progress = clampf(value, 0.0, 1.0)
		queue_redraw()
	get:
		return _progress


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(radius * 2.0 + stroke_width, radius * 2.0 + stroke_width)


func _draw() -> void:
	var center: Vector2 = size * 0.5
	draw_arc(center, radius, 0.0, TAU, 48, background_color, stroke_width, true)
	if _progress <= 0.0:
		return
	var start_angle: float = -PI * 0.5
	var end_angle: float = start_angle + TAU * _progress
	draw_arc(center, radius, start_angle, end_angle, 48, progress_color, stroke_width, true)
