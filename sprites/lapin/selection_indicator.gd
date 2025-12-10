extends Node2D

class_name SelectionIndicator

const WIDTH: float = 16.0
const HEIGHT: float = 8.0
const SEGMENTS: int = 24

var _color: Color = Color(0.0, 0.75, 0.0, 0.45)
@export var color: Color:
	set(value):
		_color = value
		queue_redraw()  # This triggers _draw() to be called again
	get:
		return _color

var _filled_points: PackedVector2Array = PackedVector2Array()

func _ready() -> void:
	z_index = -1
	_build_polygon()

func _build_polygon() -> void:
	var points := PackedVector2Array()
	for i in range(SEGMENTS):
		var angle := TAU * float(i) / SEGMENTS
		var x := cos(angle) * (WIDTH * 0.5)
		var y := sin(angle) * (HEIGHT * 0.5)
		points.append(Vector2(x, y))
	_filled_points = points

func _draw() -> void:
	if _filled_points.size() == 0:
		_build_polygon()
	draw_polygon(_filled_points, [_color])  # Use _color instead of color