extends Sprite2D

const MARK_TEXTURE: Texture2D = preload("res://assets/sprites/legval/desire.png")
# Monsters can number in the hundreds, so they are stamped from a random sample
# each update to keep the per-update cost bounded.
const MONSTER_GROUP: StringName = &"monsters"
# Clients and merchants are few and short-lived. They get stamped in full every
# update so their trail is as reliable as a monster's — otherwise the bounded
# random monster sample would almost never pick them. The player is deliberately
# excluded (it lives in its own "player" group and never marks the ground).
const PRIORITY_CREATURE_GROUPS: Array[StringName] = [&"clients", &"merchants"]

@export var update_freq_min: float = 0.75
@export var update_freq_max: float = 1.25
@export var agents_per_update: int = 8
@export_range(0.0, 1.0, 0.01) var mark_alpha: float = 0.25
@export var min_distance_between_marks: float = 10.0
@export var random_offset_px: int = 4
# Marks drawn per stamp event for each stamped agent. Every mark is a normal stamp
# (fresh random offset + rotation); only the first respects min_distance_between_marks.
# All marks for the whole event are blended into the CPU image first and pushed to
# the GPU in a SINGLE texture upload, so raising this stays cheap.
@export var repetition: int = 3
@export var floor_path: NodePath = NodePath("../floor")
@export var watersources_path: NodePath = NodePath("../watersources")

var _floor: TileMapLayer
var _watersources: WaterSources
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

	# Marks must never land on water; skip stamping for agents over a water tile.
	_watersources = get_node_or_null(watersources_path) as WaterSources

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
	var stamped: bool = false

	# Clients and merchants: stamp every one so they always leave a trail.
	for group_name: StringName in PRIORITY_CREATURE_GROUPS:
		for raw_agent: Node in get_tree().get_nodes_in_group(group_name):
			var agent: Node2D = raw_agent as Node2D
			if is_instance_valid(agent) and _should_stamp(agent):
				if _stamp_agent_marks(agent):
					stamped = true

	# Monsters: bounded random sample to cap per-update cost with large hordes.
	var monsters: Array[Node] = get_tree().get_nodes_in_group(MONSTER_GROUP)
	if not monsters.is_empty():
		var count: int = mini(agents_per_update, monsters.size())
		for i: int in range(count):
			var agent: Node2D = monsters[randi_range(0, monsters.size() - 1)] as Node2D
			if is_instance_valid(agent) and _should_stamp(agent):
				if _stamp_agent_marks(agent):
					stamped = true

	# One GPU upload per event, never one per mark: every mark above was blended
	# into the CPU image, so a single update() pushes them all at once.
	if stamped:
		_canvas_texture.update(_canvas_image)


func _next_update_delay() -> float:
	var min_delay: float = maxf(0.0, update_freq_min)
	var max_delay: float = maxf(min_delay, update_freq_max)
	return randf_range(min_delay, max_delay)


# Gate for a stamp event: skips agents over water or too close to their last
# mark. Records the position so the min-distance rule holds until the agent moves.
func _should_stamp(agent: Node2D) -> bool:
	var agent_pos: Vector2 = agent.global_position
	if _watersources != null and _watersources.has_water_at_foot_position(agent_pos):
		return false
	var agent_id: int = agent.get_instance_id()
	if _last_mark_positions.has(agent_id):
		var previous_pos: Vector2 = _last_mark_positions[agent_id] as Vector2
		if previous_pos.distance_to(agent_pos) < min_distance_between_marks:
			return false
	_last_mark_positions[agent_id] = agent_pos
	return true


# Blends `repetition` marks for one agent into the CPU image (no GPU upload here;
# the caller does a single update() for the whole event). The gate was already
# checked once by _should_stamp, so all marks land. Returns true if any was drawn.
func _stamp_agent_marks(agent: Node2D) -> bool:
	var reps: int = maxi(1, repetition)
	var drew: bool = false
	for i: int in range(reps):
		if _blend_agent_mark(agent):
			drew = true
	return drew


# Blends one mark onto the canvas image at the agent's current position with a
# fresh random offset and rotation. Skips marks that would land on a water tile.
func _blend_agent_mark(agent: Node2D) -> bool:
	var agent_pos: Vector2 = agent.global_position
	if _watersources != null and _watersources.has_water_at_foot_position(agent_pos):
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
	return _blend_mark(draw_center, angle)


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
