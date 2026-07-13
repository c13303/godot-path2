extends CanvasLayer

# Screen-space warning arrows that flag the spawners which will activate on the upcoming
# night, shown only while the planificator's big focus slot is that night preview. One
# arrow per active spawner: hovering above and pointing down at the spawner when it is
# on-screen, clamped to the screen edge and pointing toward it when off-screen. All arrows
# hide the instant the night starts (the focus stops being a night preview).
#
# This node owns no schedule semantics: it asks the planificator which night is focused and
# BuildingManager for that night's active spawner world positions. Projection mirrors the
# off-screen monster arrows in arros.gd (canvas transform + edge clamp).

const ARRO_TEXTURE: Texture2D = preload("res://assets/sprites/legval/arro_warning.png")
const MAX_ARROWS: int = 32
const REFRESH_INTERVAL: float = 0.25
const ON_SCREEN_OFFSET_PIXELS: float = 44.0
const BOB_AMPLITUDE_PIXELS: float = 6.0
const BOB_SPEED: float = 4.0
# arro_warning.png points right (+X); rotating by +90 degrees points it straight down.
const POINT_DOWN_ROTATION: float = PI * 0.5

@export_range(0.1, 10.0, 0.1) var arro_scale: float = 2.0
@export_range(0.0, 500.0, 1.0) var distance_from_edge: float = 50.0

var _pool: Array[Sprite2D] = []
var _target_positions: Array[Vector2] = []
var _refresh_elapsed: float = 999.0
var _bob_phase: float = 0.0


func _ready() -> void:
	layer = 89
	_build_pool()
	set_process(true)


func _build_pool() -> void:
	for index: int in range(MAX_ARROWS):
		var arro: Sprite2D = Sprite2D.new()
		arro.name = "warning_arro_%02d" % index
		arro.texture = ARRO_TEXTURE
		arro.centered = true
		arro.scale = Vector2(arro_scale, arro_scale)
		arro.visible = false
		add_child(arro)
		_pool.append(arro)


func _process(delta: float) -> void:
	_bob_phase += delta * BOB_SPEED
	_refresh_elapsed += delta
	if _refresh_elapsed >= REFRESH_INTERVAL:
		_refresh_elapsed = 0.0
		_refresh_targets()
	_update_arrows()


# Recompute which spawner world positions to flag. Empty (all arrows hidden) unless the
# planificator's big focus is the upcoming-night preview; explicitly cleared once the night
# is running so arrows vanish immediately at night start rather than after a preview poll.
func _refresh_targets() -> void:
	_target_positions.clear()
	if GameState.is_night:
		return
	var planificator: Node = _get_planificator()
	if planificator == null or not planificator.has_method("focused_night_preview_index"):
		return
	var night_index: int = int(planificator.call("focused_night_preview_index"))
	if night_index < 0:
		return
	var building_manager: Node = _get_building_manager()
	if building_manager == null or not building_manager.has_method("night_active_spawner_world_positions"):
		return
	var raw: Variant = building_manager.call("night_active_spawner_world_positions", night_index)
	if not (raw is Array):
		return
	for value: Variant in raw as Array:
		if value is Vector2:
			_target_positions.append(value as Vector2)


func _update_arrows() -> void:
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0 or _target_positions.is_empty():
		_hide_from(0)
		return
	var half_size: Vector2 = viewport_size * 0.5
	var canvas_transform: Transform2D = get_viewport().get_canvas_transform()
	var bob_offset: float = sin(_bob_phase) * BOB_AMPLITUDE_PIXELS
	var used: int = 0
	for target: Vector2 in _target_positions:
		if used >= _pool.size():
			break
		var screen_position: Vector2 = canvas_transform * target
		var arro: Sprite2D = _pool[used]
		if _is_on_screen(screen_position, viewport_size):
			# On-screen: hover above the spawner, pointing straight down at it.
			arro.position = screen_position + Vector2(0.0, -ON_SCREEN_OFFSET_PIXELS + bob_offset)
			arro.rotation = POINT_DOWN_ROTATION
		else:
			var direction: Vector2 = screen_position - half_size
			if direction.length_squared() <= 0.0001:
				continue
			arro.position = _edge_position(direction, half_size)
			arro.rotation = direction.angle()
		arro.visible = true
		used += 1
	_hide_from(used)


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


func _hide_from(first_index: int) -> void:
	for index: int in range(first_index, _pool.size()):
		_pool[index].visible = false


func _get_building_manager() -> Node:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return null
	return scene.get_node_or_null("Map/BuildingManager")


func _get_planificator() -> Node:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return null
	return scene.get_node_or_null("GameUI/planificator")
