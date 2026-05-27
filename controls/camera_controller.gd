extends Node
class_name CameraController

var camera: Camera2D
var speed: float = 400.0
var zoom_speed: float = 0.1
var min_zoom: float = 0.5
var max_zoom: float = 3.0
var scroll_margin_pixel: float = 100.0
var lock_mouse_to_view: bool = true
var follow_smoothing: float = 8.0
var zoom_snap_step: float = 0.125
var position_snap_step: float = 0.5

var _mouse_locked: bool = false
var _follow_target: Node2D = null

func setup(
	cam: Camera2D,
	move_speed: float,
	zoom_step: float,
	min_zoom_in: float,
	max_zoom_in: float,
	scroll_margin_in: float,
	lock_mouse: bool
) -> void:
	camera = cam
	speed = move_speed
	zoom_speed = zoom_step
	min_zoom = min_zoom_in
	max_zoom = max_zoom_in
	scroll_margin_pixel = scroll_margin_in
	lock_mouse_to_view = lock_mouse

func process(delta: float, paused: bool) -> void:
	if paused:
		return
	if not camera:
		return
	if not is_instance_valid(_follow_target):
		return

	var t: float = 1.0 - exp(-follow_smoothing * delta)
	var next_position: Vector2 = camera.global_position.lerp(_follow_target.global_position, t)
	camera.global_position = _snap_position(next_position)

func set_follow_target(target: Node2D, snap: bool = false) -> void:
	_follow_target = target
	if snap and camera and is_instance_valid(_follow_target):
		camera.global_position = _follow_target.global_position

func handle_mouse_wheel(amount: float) -> void:
	_zoom_towards_mouse(amount)

func is_mouse_locked() -> bool:
	return _mouse_locked

func set_mouse_locked(enabled: bool) -> void:
	if _mouse_locked == enabled:
		return
	_mouse_locked = enabled
	var mode: int = Input.MOUSE_MODE_VISIBLE
	if enabled:
		mode = Input.MOUSE_MODE_CONFINED
	Input.set_mouse_mode(mode)

func _zoom_towards_mouse(amount: float) -> void:
	if not camera:
		return

	var mouse_screen: Vector2 = get_viewport().get_mouse_position()

	var xform_before: Transform2D = get_viewport().get_canvas_transform()
	var world_before: Vector2 = xform_before.affine_inverse() * mouse_screen

	var old_zoom: Vector2 = camera.zoom
	var new_zoom_value: float = _get_next_zoom_value(old_zoom.x, amount)
	var new_zoom: Vector2 = Vector2(new_zoom_value, new_zoom_value)
	camera.zoom = new_zoom

	var xform_after: Transform2D = get_viewport().get_canvas_transform()
	var world_after: Vector2 = xform_after.affine_inverse() * mouse_screen

	camera.position += world_before - world_after

func _get_next_zoom_value(current_zoom: float, amount: float) -> float:
	var direction: float = sign(amount)
	if direction == 0.0:
		return clamp(current_zoom, min_zoom, max_zoom)

	var raw_zoom: float = current_zoom + amount
	var stepped_zoom: float = round(raw_zoom / zoom_snap_step) * zoom_snap_step
	if direction > 0.0 and stepped_zoom <= current_zoom:
		stepped_zoom += zoom_snap_step
	elif direction < 0.0 and stepped_zoom >= current_zoom:
		stepped_zoom -= zoom_snap_step

	return clamp(stepped_zoom, min_zoom, max_zoom)

func _snap_position(pos: Vector2) -> Vector2:
	if position_snap_step <= 0.0:
		return pos
	return Vector2(
		round(pos.x / position_snap_step) * position_snap_step,
		round(pos.y / position_snap_step) * position_snap_step
	)
