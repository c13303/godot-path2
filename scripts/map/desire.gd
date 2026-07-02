extends Sprite2D

const MARK_TEXTURE: Texture2D = preload("res://assets/sprites/legval/desire.png")
# Monsters can number in the hundreds, so they are stamped from a cached
# round-robin sample each update without scene-tree scans.
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
@export_range(1, 32, 1) var stamp_rotation_variants: int = 8
@export var floor_path: NodePath = NodePath("../floor")
@export var watersources_path: NodePath = NodePath("../watersources")

var _floor: TileMapLayer
var _watersources: WaterSources
var _canvas_image: Image
var _canvas_texture: ImageTexture
var _mark_image: Image
var _stamp_images: Array[Image] = []
var _used_rect: Rect2i
var _tile_size: Vector2i = Vector2i.ZERO
var _origin_floor_local: Vector2 = Vector2.ZERO
var _update_timer: Timer
var _last_mark_positions: Dictionary = {}
var _monster_agents: Array[Node2D] = []
var _priority_agents: Array[Node2D] = []
var _registered_agent_ids: Dictionary = {}
var _monster_cursor: int = 0


func _ready() -> void:
	set_process(false)
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
	if _canvas_image == null or _canvas_texture == null:
		return
	_rebuild_stamp_images()
	_rebuild_agent_cache()
	_update_timer = Timer.new()
	_update_timer.one_shot = true
	_update_timer.timeout.connect(_on_update_timer_timeout)
	add_child(_update_timer)
	_schedule_next_update()


func register_agent(agent: Node2D, group_name: StringName) -> void:
	if agent == null or not is_instance_valid(agent):
		return
	if group_name != MONSTER_GROUP and not PRIORITY_CREATURE_GROUPS.has(group_name):
		return
	var agent_id: int = agent.get_instance_id()
	if _registered_agent_ids.has(agent_id):
		return
	_registered_agent_ids[agent_id] = group_name
	if group_name == MONSTER_GROUP:
		_monster_agents.append(agent)
	else:
		_priority_agents.append(agent)
	if _update_timer != null and _update_timer.is_stopped():
		_schedule_next_update()


func unregister_agent(agent: Node2D) -> void:
	if agent == null:
		return
	var agent_id: int = agent.get_instance_id()
	_registered_agent_ids.erase(agent_id)
	_last_mark_positions.erase(agent_id)
	_erase_cached_agent(_monster_agents, agent)
	_erase_cached_agent(_priority_agents, agent)
	if _monster_cursor >= _monster_agents.size():
		_monster_cursor = 0
	if _update_timer != null and not _has_agents():
		_update_timer.stop()


func _on_update_timer_timeout() -> void:
	if _canvas_image == null or _canvas_texture == null:
		return
	if not _is_enabled():
		return
	_stamp_random_agents()
	_schedule_next_update()


func _is_enabled() -> bool:
	return update_freq_max > 0.0 and agents_per_update > 0 and mark_alpha > 0.0


func _schedule_next_update() -> void:
	if _update_timer == null or not _is_enabled() or not _has_agents():
		return
	_update_timer.start(_next_update_delay())


func _has_agents() -> bool:
	return not _monster_agents.is_empty() or not _priority_agents.is_empty()


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
	for index: int in range(_priority_agents.size() - 1, -1, -1):
		var agent: Node2D = _priority_agents[index]
		if not _is_cached_agent_valid(agent):
			_unregister_cached_agent_at(_priority_agents, index)
			continue
		if _should_stamp(agent):
			if _stamp_agent_marks(agent):
				stamped = true

	# Monsters: bounded round-robin sample to cap per-update cost with large hordes.
	var monster_count: int = _monster_agents.size()
	if monster_count > 0:
		var checked: int = 0
		var target_count: int = mini(agents_per_update, monster_count)
		while checked < target_count and not _monster_agents.is_empty():
			if _monster_cursor >= _monster_agents.size():
				_monster_cursor = 0
			var agent: Node2D = _monster_agents[_monster_cursor]
			if not _is_cached_agent_valid(agent):
				_unregister_cached_agent_at(_monster_agents, _monster_cursor)
				continue
			_monster_cursor += 1
			checked += 1
			if _should_stamp(agent):
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


func _rebuild_agent_cache() -> void:
	_monster_agents.clear()
	_priority_agents.clear()
	_registered_agent_ids.clear()
	for raw_monster: Node in get_tree().get_nodes_in_group(MONSTER_GROUP):
		register_agent(raw_monster as Node2D, MONSTER_GROUP)
	for group_name: StringName in PRIORITY_CREATURE_GROUPS:
		for raw_agent: Node in get_tree().get_nodes_in_group(group_name):
			register_agent(raw_agent as Node2D, group_name)
	_monster_cursor = 0


func _is_cached_agent_valid(agent: Node2D) -> bool:
	return is_instance_valid(agent) and agent.is_inside_tree()


func _erase_cached_agent(agents: Array[Node2D], agent: Node2D) -> void:
	for index: int in range(agents.size() - 1, -1, -1):
		if agents[index] == agent:
			agents.remove_at(index)


func _unregister_cached_agent_at(agents: Array[Node2D], index: int) -> void:
	var agent: Node2D = agents[index]
	if agent != null:
		var agent_id: int = agent.get_instance_id()
		_registered_agent_ids.erase(agent_id)
		_last_mark_positions.erase(agent_id)
	agents.remove_at(index)
	if _update_timer != null and not _has_agents():
		_update_timer.stop()


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
	var agent_pos: Vector2 = agent.global_position
	var floor_local: Vector2 = _floor.to_local(agent_pos)
	var pixel_center: Vector2 = floor_local - _origin_floor_local
	var drew: bool = false
	for i: int in range(reps):
		if _blend_agent_mark(pixel_center):
			drew = true
	return drew


# Blends one precomputed mark onto the canvas image with a fresh random offset.
func _blend_agent_mark(pixel_center: Vector2) -> bool:
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
	return _blend_mark(draw_center)


func _blend_mark(draw_center: Vector2i) -> bool:
	if _stamp_images.is_empty():
		return false
	var canvas_rect: Rect2i = Rect2i(Vector2i.ZERO, _canvas_image.get_size())
	var stamp_index: int = randi_range(0, _stamp_images.size() - 1)
	var stamp_image: Image = _stamp_images[stamp_index]
	var stamp_size: Vector2i = stamp_image.get_size()
	var half_diagonal: int = int(stamp_size.x / 2)
	var bounds_position: Vector2i = draw_center - Vector2i(half_diagonal, half_diagonal)
	var bounds_size: Vector2i = stamp_size
	var clipped_rect: Rect2i = canvas_rect.intersection(Rect2i(bounds_position, bounds_size))
	if clipped_rect.size.x <= 0 or clipped_rect.size.y <= 0:
		return false

	var source_position: Vector2i = clipped_rect.position - bounds_position
	_canvas_image.blend_rect(stamp_image, Rect2i(source_position, clipped_rect.size), clipped_rect.position)
	return true


func _rebuild_stamp_images() -> void:
	_stamp_images.clear()
	var alpha_scale: float = clampf(mark_alpha, 0.0, 1.0)
	if alpha_scale <= 0.0:
		return
	var mark_size: Vector2i = _mark_image.get_size()
	var half_diagonal: int = int(ceil(Vector2(mark_size).length() * 0.5))
	var stamp_size: Vector2i = Vector2i(half_diagonal * 2, half_diagonal * 2)
	var variant_count: int = maxi(1, stamp_rotation_variants)
	for variant_index: int in range(variant_count):
		var angle: float = TAU * float(variant_index) / float(variant_count)
		_stamp_images.append(_create_rotated_stamp_image(mark_size, stamp_size, angle, alpha_scale))


func _create_rotated_stamp_image(mark_size: Vector2i, stamp_size: Vector2i, angle: float, alpha_scale: float) -> Image:
	var stamp_image: Image = Image.create(stamp_size.x, stamp_size.y, false, Image.FORMAT_RGBA8)
	stamp_image.fill(Color.TRANSPARENT)
	var source_center: Vector2 = Vector2(mark_size) * 0.5
	var destination_center: Vector2 = Vector2(stamp_size) * 0.5
	for y: int in range(stamp_size.y):
		for x: int in range(stamp_size.x):
			var destination_local: Vector2 = Vector2(float(x) + 0.5, float(y) + 0.5) - destination_center
			var source_float: Vector2 = destination_local.rotated(-angle) + source_center
			var source_pos: Vector2i = Vector2i(int(floor(source_float.x)), int(floor(source_float.y)))
			if source_pos.x < 0 or source_pos.y < 0 or source_pos.x >= mark_size.x or source_pos.y >= mark_size.y:
				continue
			var source_color: Color = _mark_image.get_pixelv(source_pos)
			source_color.a *= alpha_scale
			if source_color.a > 0.0:
				stamp_image.set_pixelv(Vector2i(x, y), source_color)
	return stamp_image
