extends CanvasLayer
class_name TutorialWorldArrow
## Screen-space pointer that guides the player toward a world tile during the tutorial.
##
## Give it a target (a live Node2D or a fixed world position) and it projects that target
## through the active canvas transform every frame:
##   - target on-screen  -> the tutorial arrow hovers just above it, points straight down
##                          and oscillates.
##   - target off-screen -> a merchant-style green arrow clamps to the screen edge and
##                          points toward the target (same edge behaviour as the agent and
##                          merchant off-screen arrows in arros.gd).
##
## It owns no tutorial logic: callers pick what to point at via point_at_node() /
## point_at_world_position() and call clear() when the step is done. This keeps it reusable
## for any future "point the player at this tile" tutorial step.

const TUTO_ARROW_TEXTURE: Texture2D = preload("res://assets/sprites/legval/tutorial_arrow.png")
const EDGE_ARROW_TEXTURE: Texture2D = preload("res://assets/sprites/legval/arro_green.png")

# tutorial_arrow.png points left (-X) at rotation 0; +1.5*PI (270 deg clockwise) points it down.
const TUTO_POINT_DOWN_ROTATION: float = PI * 1.5
const ON_SCREEN_OFFSET_PIXELS: float = 44.0
const OSCILLATION_PIXELS: float = 6.0
const OSCILLATION_SPEED: float = 5.0

@export_range(0.1, 10.0, 0.1) var tuto_arrow_scale: float = 2.0
@export_range(0.1, 10.0, 0.1) var edge_arrow_scale: float = 2.0
@export_range(0.0, 500.0, 1.0) var distance_from_edge: float = 50.0

var _tuto_arrow: Sprite2D
var _edge_arrow: Sprite2D
var _target_node: Node2D
var _target_world_position: Vector2 = Vector2.ZERO
var _has_target: bool = false
var _time: float = 0.0


func _ready() -> void:
	layer = 91
	_tuto_arrow = _make_sprite(TUTO_ARROW_TEXTURE, tuto_arrow_scale)
	_tuto_arrow.name = "TutoArrow"
	_edge_arrow = _make_sprite(EDGE_ARROW_TEXTURE, edge_arrow_scale)
	_edge_arrow.name = "EdgeArrow"
	add_child(_tuto_arrow)
	add_child(_edge_arrow)
	_hide_both()
	set_process(true)


## Point at a live world node; the arrow follows it every frame until cleared.
func point_at_node(node: Node2D) -> void:
	_target_node = node
	_has_target = node != null


## Point at a fixed world position.
func point_at_world_position(world_position: Vector2) -> void:
	_target_node = null
	_target_world_position = world_position
	_has_target = true


## Stop pointing and hide both arrows.
func clear() -> void:
	_target_node = null
	_has_target = false
	_hide_both()


func _process(delta: float) -> void:
	_time += delta
	if not _has_target:
		_hide_both()
		return
	if _target_node != null and not is_instance_valid(_target_node):
		clear()
		return
	var world_position: Vector2 = _target_world_position
	if _target_node != null:
		world_position = _target_node.global_position
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		_hide_both()
		return
	var canvas_transform: Transform2D = get_viewport().get_canvas_transform()
	var screen_position: Vector2 = canvas_transform * world_position
	if _is_on_screen(screen_position, viewport_size):
		_show_on_screen(screen_position)
	else:
		_show_off_screen(screen_position, viewport_size)


func _show_on_screen(screen_position: Vector2) -> void:
	var bob_offset: float = sin(_time * OSCILLATION_SPEED) * OSCILLATION_PIXELS
	_tuto_arrow.position = screen_position + Vector2(0.0, -ON_SCREEN_OFFSET_PIXELS + bob_offset)
	_tuto_arrow.rotation = TUTO_POINT_DOWN_ROTATION
	_tuto_arrow.visible = true
	_edge_arrow.visible = false


func _show_off_screen(screen_position: Vector2, viewport_size: Vector2) -> void:
	var half_size: Vector2 = viewport_size * 0.5
	var direction: Vector2 = screen_position - half_size
	if direction.length_squared() <= 0.0001:
		_hide_both()
		return
	_edge_arrow.position = _edge_position(direction, half_size)
	# arro_green.png points right (+X) at rotation 0, so the raw angle points it at the target.
	_edge_arrow.rotation = direction.angle()
	_edge_arrow.visible = true
	_tuto_arrow.visible = false


func _is_on_screen(screen_position: Vector2, viewport_size: Vector2) -> bool:
	return (
		screen_position.x >= 0.0
		and screen_position.y >= 0.0
		and screen_position.x <= viewport_size.x
		and screen_position.y <= viewport_size.y
	)


func _edge_position(direction: Vector2, half_size: Vector2) -> Vector2:
	var edge_half_size: Vector2 = Vector2(
		maxf(0.0, half_size.x - distance_from_edge),
		maxf(0.0, half_size.y - distance_from_edge)
	)
	var scale_x: float = INF
	if direction.x != 0.0:
		scale_x = edge_half_size.x / absf(direction.x)
	var scale_y: float = INF
	if direction.y != 0.0:
		scale_y = edge_half_size.y / absf(direction.y)
	var edge_scale: float = minf(scale_x, scale_y)
	return half_size + direction * edge_scale


func _make_sprite(texture: Texture2D, sprite_scale: float) -> Sprite2D:
	var sprite: Sprite2D = Sprite2D.new()
	sprite.texture = texture
	sprite.centered = true
	sprite.scale = Vector2(sprite_scale, sprite_scale)
	sprite.z_index = 500
	sprite.visible = false
	return sprite


func _hide_both() -> void:
	if _tuto_arrow != null:
		_tuto_arrow.visible = false
	if _edge_arrow != null:
		_edge_arrow.visible = false
