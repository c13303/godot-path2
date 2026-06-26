extends Sprite2D

const MARK_TEXTURE: Texture2D = preload("res://assets/sprites/legval/desire.png")
const MONSTER_GROUP: StringName = &"monsters"

@export var update_freq_min: float = 0.75
@export var update_freq_max: float = 1.25
@export var agents_per_update: int = 8
@export_range(0.0, 1.0, 0.01) var mark_alpha: float = 0.25
@export var min_distance_between_marks: float = 10.0
@export var random_offset_px: int = 4
@export var floor_path: NodePath = NodePath("../floor")

var _floor: TileMapLayer
var _canvas_image: Image
var _canvas_texture: ImageTexture
var _mark_image: Image
var _used_rect: Rect2i
var _tile_size: Vector2i = Vector2i.ZERO
var _origin_floor_local: Vector2 = Vector2.ZERO
var _time_until_update: float = 0.0
var _last_mark_positions: Dictionary = {}


func _ready() -> void:
	centered = false
	z_index = -99
	_floor = get_node_or_null(floor_path) as TileMapLayer
	if _floor == null:
		push_warning("Desire: floor TileMapLayer not found.")
		set_process(false)
		return

	_mark_image = MARK_TEXTURE.get_image()
	if _mark_image == null or _mark_image.is_empty():
		push_warning("Desire: desire.png could not be loaded.")
		set_process(false)
		return

	_rebuild_canvas()


func _process(delta: float) -> void:
	if _canvas_image == null or _canvas_texture == null:
		return
	if update_freq_max <= 0.0 or agents_per_update <= 0:
		return

	_time_until_update -= delta
	if _time_until_update > 0.0:
		return

	_time_until_update = _next_update_delay()
	_stamp_random_agents()


func _rebuild_canvas() -> void:
	_used_rect = _floor.get_used_rect()
	if _used_rect.size.x <= 0 or _used_rect.size.y <= 0:
		push_warning("Desire: floor TileMapLayer has no used cells.")
		set_process(false)
		return

	if _floor.tile_set:
		_tile_size = _floor.tile_set.get_tile_size()
	if _tile_size.x <= 0 or _tile_size.y <= 0:
		_tile_size = Vector2i(32, 32)

	var canvas_size: Vector2i = Vector2i(_used_rect.size.x * _tile_size.x, _used_rect.size.y * _tile_size.y)
	_canvas_image = Image.create(canvas_size.x, canvas_size.y, false, Image.FORMAT_RGBA8)
	_canvas_image.fill(Color.TRANSPARENT)
	_canvas_texture = ImageTexture.create_from_image(_canvas_image)
	texture = _canvas_texture

	var top_left_cell: Vector2i = _used_rect.position
	_origin_floor_local = _floor.map_to_local(top_left_cell) - (Vector2(_tile_size) * 0.5)
	global_position = _floor.to_global(_origin_floor_local)


func _stamp_random_agents() -> void:
	var agents: Array[Node] = get_tree().get_nodes_in_group(MONSTER_GROUP)
	if agents.is_empty():
		return

	var count: int = mini(agents_per_update, agents.size())
	var stamped: bool = false
	for i: int in range(count):
		var agent_index: int = randi_range(0, agents.size() - 1)
		var agent: Node2D = agents[agent_index] as Node2D
		if not is_instance_valid(agent):
			continue
		if _stamp_agent(agent):
			stamped = true

	if stamped:
		_canvas_texture.update(_canvas_image)


func _next_update_delay() -> float:
	var min_delay: float = maxf(0.0, update_freq_min)
	var max_delay: float = maxf(min_delay, update_freq_max)
	return randf_range(min_delay, max_delay)


func _stamp_agent(agent: Node2D) -> bool:
	var agent_id: int = agent.get_instance_id()
	var agent_pos: Vector2 = agent.global_position
	if _last_mark_positions.has(agent_id):
		var previous_pos: Vector2 = _last_mark_positions[agent_id] as Vector2
		if previous_pos.distance_to(agent_pos) < min_distance_between_marks:
			return false

	var floor_local: Vector2 = _floor.to_local(agent_pos)
	var pixel_center: Vector2 = floor_local - _origin_floor_local
	var mark_offset: Vector2i = Vector2i.ZERO
	if random_offset_px > 0:
		mark_offset = Vector2i(
			randi_range(-random_offset_px, random_offset_px),
			randi_range(-random_offset_px, random_offset_px)
		)

	var draw_center: Vector2i = Vector2i(
		int(round(pixel_center.x)) + mark_offset.x,
		int(round(pixel_center.y)) + mark_offset.y
	)
	var angle: float = randf_range(0.0, TAU)
	if not _blend_mark(draw_center, angle):
		return false

	_last_mark_positions[agent_id] = agent_pos
	return true


func _blend_mark(draw_center: Vector2i, angle: float) -> bool:
	var canvas_rect: Rect2i = Rect2i(Vector2i.ZERO, _canvas_image.get_size())
	var mark_size: Vector2i = _mark_image.get_size()
	var half_diagonal: int = int(ceil(Vector2(mark_size).length() * 0.5))
	var bounds_position: Vector2i = draw_center - Vector2i(half_diagonal, half_diagonal)
	var bounds_size: Vector2i = Vector2i(half_diagonal * 2, half_diagonal * 2)
	var clipped_rect: Rect2i = canvas_rect.intersection(Rect2i(bounds_position, bounds_size))
	if clipped_rect.size.x <= 0 or clipped_rect.size.y <= 0:
		return false

	var alpha_scale: float = clampf(mark_alpha, 0.0, 1.0)
	if alpha_scale <= 0.0:
		return false

	var source_center: Vector2 = Vector2(mark_size) * 0.5
	var destination_center: Vector2 = Vector2(draw_center)
	for y: int in range(clipped_rect.position.y, clipped_rect.end.y):
		for x: int in range(clipped_rect.position.x, clipped_rect.end.x):
			var destination_local: Vector2 = Vector2(float(x) + 0.5, float(y) + 0.5) - destination_center
			var source_float: Vector2 = destination_local.rotated(-angle) + source_center
			var source_pos: Vector2i = Vector2i(int(floor(source_float.x)), int(floor(source_float.y)))
			if source_pos.x < 0 or source_pos.y < 0 or source_pos.x >= mark_size.x or source_pos.y >= mark_size.y:
				continue
			var source_color: Color = _mark_image.get_pixelv(source_pos)
			var source_alpha: float = source_color.a * alpha_scale
			if source_alpha <= 0.0:
				continue

			var destination_pos: Vector2i = Vector2i(x, y)
			var destination_color: Color = _canvas_image.get_pixelv(destination_pos)
			var out_alpha: float = source_alpha + destination_color.a * (1.0 - source_alpha)
			if out_alpha <= 0.0:
				continue

			var source_rgb: Color = Color(source_color.r, source_color.g, source_color.b, 1.0)
			var destination_rgb: Color = Color(destination_color.r, destination_color.g, destination_color.b, 1.0)
			var out_rgb: Color = source_rgb * source_alpha + destination_rgb * destination_color.a * (1.0 - source_alpha)
			out_rgb.r /= out_alpha
			out_rgb.g /= out_alpha
			out_rgb.b /= out_alpha
			out_rgb.a = out_alpha
			_canvas_image.set_pixelv(destination_pos, out_rgb)

	return true
