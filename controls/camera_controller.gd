extends Node
class_name CameraController

var camera: Camera2D
var speed: float = 400.0
var zoom_speed: float = 0.1
var min_zoom: float = 0.5
var max_zoom: float = 3.0
var scroll_margin_pixel: float = 100.0
var lock_mouse_to_view: bool = true

var _mouse_locked: bool = false

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
	if lock_mouse_to_view:
		set_mouse_locked(true)

func process(delta: float, paused: bool) -> void:
	if paused:
		return
	if not camera:
		return

	var mov: Vector2 = Vector2.ZERO
	if Input.is_key_pressed(KEY_UP):
		mov.y -= 1.0
	if Input.is_key_pressed(KEY_DOWN):
		mov.y += 1.0
	if Input.is_key_pressed(KEY_LEFT):
		mov.x -= 1.0
	if Input.is_key_pressed(KEY_RIGHT):
		mov.x += 1.0
	if mov != Vector2.ZERO:
		camera.position += mov.normalized() * speed * delta

	_scroll_camera_via_mouse(delta)

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

func _scroll_camera_via_mouse(delta: float) -> void:
	if not camera or scroll_margin_pixel <= 0.0:
		return

	var viewport_rect: Rect2 = get_viewport().get_visible_rect()
	var mouse_pos: Vector2 = get_viewport().get_mouse_position()
	var scroll_vec: Vector2 = Vector2.ZERO

	scroll_vec.x = _scroll_axis(mouse_pos.x, viewport_rect.size.x)
	scroll_vec.y = _scroll_axis(mouse_pos.y, viewport_rect.size.y)

	if scroll_vec == Vector2.ZERO:
		return

	camera.position += scroll_vec * delta

func _scroll_axis(coord: float, dimension: float) -> float:
	if coord < 0.0 or coord > dimension:
		return 0.0

	var factor: float = 0.0
	if coord <= scroll_margin_pixel:
		var progress: float = clamp((scroll_margin_pixel - coord) / scroll_margin_pixel, 0.0, 1.0)
		factor = 0.2 + 0.8 * progress
		return -speed * factor
	elif coord >= dimension - scroll_margin_pixel:
		var dist: float = dimension - coord
		var progress2: float = clamp((scroll_margin_pixel - dist) / scroll_margin_pixel, 0.0, 1.0)
		factor = 0.2 + 0.8 * progress2
		return speed * factor

	return 0.0

func _zoom_towards_mouse(amount: float) -> void:
	if not camera:
		return

	var mouse_screen: Vector2 = get_viewport().get_mouse_position()

	var xform_before: Transform2D = get_viewport().get_canvas_transform()
	var world_before: Vector2 = xform_before.affine_inverse() * mouse_screen

	var old_zoom: Vector2 = camera.zoom
	var new_zoom: Vector2 = Vector2(
		clamp(old_zoom.x + amount, min_zoom, max_zoom),
		clamp(old_zoom.y + amount, min_zoom, max_zoom)
	)
	camera.zoom = new_zoom

	var xform_after: Transform2D = get_viewport().get_canvas_transform()
	var world_after: Vector2 = xform_after.affine_inverse() * mouse_screen

	camera.position += world_before - world_after
