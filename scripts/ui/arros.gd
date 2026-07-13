extends CanvasLayer

@export_range(1, 1000, 1) var maximum_arros: int = 100:
	set(value):
		maximum_arros = maxi(1, value)
		if is_inside_tree():
			_rebuild_pool()

@export_range(0.0, 500.0, 1.0) var distance_from_edge: float = 50.0
@export_range(0.1, 10.0, 0.1) var arro_scale: float = 2.0
@export var red_arro_texture: Texture2D = preload("res://assets/sprites/legval/arro_red.png")
@export var green_arro_texture: Texture2D = preload("res://assets/sprites/legval/arro_green.png")
@export var rotation_offset_degrees: float = 0.0
@export var target_refresh_interval: float = 0.25

const MONSTER_GROUP: StringName = &"monsters"
const MERCHANT_GROUP: StringName = &"merchants"

var _pool: Array[Sprite2D] = []
var _targets: Array[Node2D] = []
var _target_textures: Array[Texture2D] = []
var _refresh_elapsed: float = 999.0
var _half_viewport_size: Vector2 = Vector2.ZERO


func _ready() -> void:
	layer = 90
	_rebuild_pool()
	set_process(true)


func _process(delta: float) -> void:
	_refresh_elapsed += delta
	if _refresh_elapsed >= target_refresh_interval:
		_refresh_targets()
		_refresh_elapsed = 0.0
	_update_arros()


func _rebuild_pool() -> void:
	for arro: Sprite2D in _pool:
		if is_instance_valid(arro):
			arro.queue_free()
	_pool.clear()

	for index: int in range(maximum_arros):
		var arro: Sprite2D = Sprite2D.new()
		arro.name = "arro_%03d" % index
		arro.texture = red_arro_texture
		arro.centered = true
		arro.scale = Vector2(arro_scale, arro_scale)
		arro.visible = false
		add_child(arro)
		_pool.append(arro)


func _refresh_targets() -> void:
	_targets.clear()
	_target_textures.clear()
	_append_group_targets(MERCHANT_GROUP, green_arro_texture)
	_append_group_targets(MONSTER_GROUP, red_arro_texture)


func _append_group_targets(group_name: StringName, texture: Texture2D) -> void:
	if _targets.size() >= maximum_arros:
		return
	for raw_node: Node in get_tree().get_nodes_in_group(group_name):
		if _targets.size() >= maximum_arros:
			return
		var target: Node2D = raw_node as Node2D
		if target == null or not target.is_inside_tree():
			continue
		_targets.append(target)
		_target_textures.append(texture)


func _update_arros() -> void:
	var viewport_rect: Rect2 = get_viewport().get_visible_rect()
	var viewport_size: Vector2 = viewport_rect.size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		_hide_from(0)
		return

	_half_viewport_size = viewport_size * 0.5
	var canvas_transform: Transform2D = get_viewport().get_canvas_transform()
	var used_count: int = 0
	var rotation_offset: float = deg_to_rad(rotation_offset_degrees)

	for index: int in range(_targets.size()):
		if used_count >= _pool.size():
			break
		var target: Node2D = _targets[index]
		if not is_instance_valid(target):
			continue
		var screen_position: Vector2 = canvas_transform * target.global_position
		if _is_on_screen(screen_position, viewport_size):
			continue

		var direction: Vector2 = screen_position - _half_viewport_size
		if direction.length_squared() <= 0.0001:
			continue

		var arrow_position: Vector2 = _edge_position(direction, viewport_size)
		var arro: Sprite2D = _pool[used_count]
		arro.position = arrow_position
		arro.rotation = direction.angle() + rotation_offset
		arro.texture = _target_textures[index]
		arro.visible = true
		used_count += 1

	_hide_from(used_count)


func _is_on_screen(screen_position: Vector2, viewport_size: Vector2) -> bool:
	return (
		screen_position.x >= 0.0
		and screen_position.y >= 0.0
		and screen_position.x <= viewport_size.x
		and screen_position.y <= viewport_size.y
	)


func _edge_position(direction: Vector2, _viewport_size: Vector2) -> Vector2:
	var edge_half_size: Vector2 = Vector2(
		max(0.0, _half_viewport_size.x - distance_from_edge),
		max(0.0, _half_viewport_size.y - distance_from_edge)
	)
	var scale_x: float = INF
	if direction.x != 0.0:
		scale_x = edge_half_size.x / absf(direction.x)
	var scale_y: float = INF
	if direction.y != 0.0:
		scale_y = edge_half_size.y / absf(direction.y)
	var edge_scale: float = minf(scale_x, scale_y)
	return _half_viewport_size + direction * edge_scale


func _hide_from(first_index: int) -> void:
	for index: int in range(first_index, _pool.size()):
		_pool[index].visible = false
