extends Camera2D
class_name CameraController

@export var min_zoom: float = 0.25
@export var max_zoom: float = 4.0
@export var default_zoom: float = 1.25
var follow_smoothing: float = 8.0
var zoom_snap_step: float = 0.125
var position_snap_step: float = 0.5

var _mouse_locked: bool = false
var _follow_target: Node2D = null

func _ready() -> void:
	var clamped_zoom: float = clamp(default_zoom, min_zoom, max_zoom)
	zoom = Vector2(clamped_zoom, clamped_zoom)

func process(delta: float, paused: bool) -> void:
	if paused:
		return
	if not is_instance_valid(_follow_target):
		return

	var t: float = 1.0 - exp(-follow_smoothing * delta)
	var next_position: Vector2 = global_position.lerp(_follow_target.global_position, t)
	global_position = _snap_position(next_position)

func set_follow_target(target: Node2D, snap: bool = false) -> void:
	_follow_target = target
	if snap and is_instance_valid(_follow_target):
		global_position = _follow_target.global_position

## Clamp the camera so its view cannot scroll past the authored map bounds. Called once
## at level start with the mapBounds world rectangle. A zero-size rect leaves the camera
## unclamped (levels without a mapBounds node).
func set_world_bounds(world_rect: Rect2) -> void:
	if world_rect.size.x <= 0.0 or world_rect.size.y <= 0.0:
		return
	limit_left = int(floor(world_rect.position.x))
	limit_top = int(floor(world_rect.position.y))
	limit_right = int(ceil(world_rect.position.x + world_rect.size.x))
	limit_bottom = int(ceil(world_rect.position.y + world_rect.size.y))

func handle_mouse_wheel(amount: float) -> void:
	_zoom_towards_mouse(amount)

func is_mouse_locked() -> bool:
	return _mouse_locked

func set_mouse_locked(locked: bool) -> void:
	if _mouse_locked == locked:
		return
	_mouse_locked = locked
	var mode: int = Input.MOUSE_MODE_VISIBLE
	if locked:
		mode = Input.MOUSE_MODE_CONFINED
	Input.set_mouse_mode(mode)

func _zoom_towards_mouse(amount: float) -> void:
	var mouse_screen: Vector2 = get_viewport().get_mouse_position()

	var xform_before: Transform2D = get_viewport().get_canvas_transform()
	var world_before: Vector2 = xform_before.affine_inverse() * mouse_screen

	var old_zoom: Vector2 = zoom
	var new_zoom_value: float = _get_next_zoom_value(old_zoom.x, amount)
	var new_zoom: Vector2 = Vector2(new_zoom_value, new_zoom_value)
	zoom = new_zoom

	var xform_after: Transform2D = get_viewport().get_canvas_transform()
	var world_after: Vector2 = xform_after.affine_inverse() * mouse_screen

	position += world_before - world_after

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
