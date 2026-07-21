extends Control
class_name PlayerPickupFeedbackController

## Visual-only "you picked this up" feedback. World acquisitions use GroundItemVisual so the item
## follows a ground path with a floor shadow and physical altitude before reaching the player.
## Screen-only sources (dialogs and shop rows) remain UI icons. Both paths finish with the same
## above-head pop and own no game state: rewards are committed before feedback begins.
##
## Processing runs only while at least one visual is alive; there is no permanent polling.

const GROUND_ITEM_VISUAL_SCRIPT: Script = preload("res://scripts/map/ground_item_visual.gd")
const ICON_SIZE: Vector2 = Vector2(30.0, 30.0)

# Timing / shape tuning. All animation constants live here.
const FLIGHT_DURATION: float = 0.45
const BOUNCE_DURATION: float = 0.34
const ARC_HEIGHT: float = 46.0
const BOUNCE_RISE: float = 26.0
const LAUNCH_SPREAD_RADIUS: float = 26.0
const LAUNCH_STAGGER_MAX: float = 0.05
const LAUNCH_STAGGER_TOTAL: float = 0.5
const FLIGHT_START_SCALE: float = 0.5
const BOUNCE_POP_SCALE: float = 1.25
const BOUNCE_POP_FRACTION: float = 0.35
# The icon settles a little above the player's origin (roughly head height).
const PLAYER_HEAD_OFFSET: Vector2 = Vector2(0.0, -30.0)

# Visual caps. One reward shows at most PER_EVENT_VISUAL_CAP icons, and no more than
# GLOBAL_ACTIVE_VISUAL_CAP fly at once. Excess icons are skipped: the logical reward is already
# granted in full by the caller, so skipping visuals is always safe.
const PER_EVENT_VISUAL_CAP: int = 15
const GLOBAL_ACTIVE_VISUAL_CAP: int = 60

var _player: Node2D = null
var _player_head_screen: Vector2 = Vector2.ZERO
var _has_player_screen: bool = false
var _visuals: Array[PickupVisual] = []


## One flying icon's state. Flight runs first (from the source to the player), then a compact
## above-head bounce. `flight_elapsed` starts negative so an icon can wait out its launch stagger
## before it appears.
class PickupVisual:
	var texture: AtlasTexture = null
	var screen_sprite: TextureRect = null
	var world_visual: GroundItemVisual = null
	var start_position: Vector2 = Vector2.ZERO
	var spread_offset: Vector2 = Vector2.ZERO
	var rotation_velocity: float = 0.0
	var flight_elapsed: float = 0.0
	var bounce_elapsed: float = 0.0
	var in_bounce: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	set_process(false)


# --- Public API --------------------------------------------------------------

## Fly `quantity` icons of `item_id` from a world position to the player. Returns false only when
## the item has no usable icon or nothing could be spawned; the caller's reward is unaffected.
func play_from_world(item_id: String, world_position: Vector2, quantity: int = 1) -> bool:
	var texture: AtlasTexture = GROUND_ITEM_VISUAL_SCRIPT.item_texture(item_id)
	if texture == null or quantity <= 0:
		return false
	var world_parent: Node2D = _world_visual_parent()
	if world_parent == null:
		return _play_screen(texture, _world_to_screen(world_position), quantity)
	var spawn_count: int = _spawn_count(quantity)
	if spawn_count <= 0:
		return false
	var stagger: float = _launch_stagger(spawn_count)
	for i: int in range(spawn_count):
		_spawn_world_visual(texture, world_parent, world_position, i, spawn_count, float(i) * stagger)
	set_process(true)
	return true


## Fly `quantity` icons of `item_id` from a screen position (e.g. a dialog row) to the player.
func play_from_screen(item_id: String, screen_position: Vector2, quantity: int = 1) -> bool:
	var texture: AtlasTexture = GROUND_ITEM_VISUAL_SCRIPT.item_texture(item_id)
	if texture == null:
		return false
	return _play_screen(texture, screen_position, quantity)


# --- Spawning ----------------------------------------------------------------

func _play_screen(texture: AtlasTexture, screen_start: Vector2, quantity: int) -> bool:
	if quantity <= 0:
		return false
	var spawn_count: int = _spawn_count(quantity)
	if spawn_count <= 0:
		return false
	var stagger: float = _launch_stagger(spawn_count)
	for i: int in range(spawn_count):
		_spawn_screen_visual(texture, screen_start, i, spawn_count, float(i) * stagger)
	set_process(true)
	return true


func _spawn_screen_visual(texture: AtlasTexture, screen_start: Vector2, index: int, count: int, delay: float) -> void:
	var sprite: TextureRect = _create_screen_sprite(texture)
	sprite.scale = Vector2(FLIGHT_START_SCALE, FLIGHT_START_SCALE)
	sprite.visible = delay <= 0.0
	add_child(sprite)
	_position_sprite(sprite, screen_start)
	var visual: PickupVisual = PickupVisual.new()
	visual.texture = texture
	visual.screen_sprite = sprite
	visual.start_position = screen_start
	visual.spread_offset = _spread_offset(index, count)
	visual.flight_elapsed = -delay
	_visuals.append(visual)


func _spawn_world_visual(
	texture: AtlasTexture,
	world_parent: Node2D,
	world_start: Vector2,
	index: int,
	count: int,
	delay: float
) -> void:
	var item_visual: GroundItemVisual = GROUND_ITEM_VISUAL_SCRIPT.new()
	item_visual.setup_item(texture, 1, 0, GROUND_ITEM_VISUAL_SCRIPT.DEFAULT_ITEM_SCALE)
	item_visual.visible = delay <= 0.0
	world_parent.add_child(item_visual)
	item_visual.set_flight_pose(world_start, 0.0)
	var visual: PickupVisual = PickupVisual.new()
	visual.texture = texture
	visual.world_visual = item_visual
	visual.start_position = world_start
	visual.spread_offset = _spread_offset(index, count)
	visual.rotation_velocity = randf_range(-2.2, 2.2)
	visual.flight_elapsed = -delay
	_visuals.append(visual)


func _create_screen_sprite(texture: AtlasTexture) -> TextureRect:
	var sprite: TextureRect = TextureRect.new()
	sprite.texture = texture
	sprite.custom_minimum_size = ICON_SIZE
	sprite.size = ICON_SIZE
	sprite.pivot_offset = ICON_SIZE * 0.5
	sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return sprite


func _spawn_count(quantity: int) -> int:
	var event_count: int = mini(quantity, PER_EVENT_VISUAL_CAP)
	var global_room: int = GLOBAL_ACTIVE_VISUAL_CAP - _visuals.size()
	return mini(event_count, global_room)


func _launch_stagger(spawn_count: int) -> float:
	return minf(LAUNCH_STAGGER_MAX, LAUNCH_STAGGER_TOTAL / float(maxi(spawn_count - 1, 1)))


## A small deterministic ring offset so several icons from one reward do not perfectly overlap at
## launch. Converges to zero over the flight so they still meet at the player.
func _spread_offset(index: int, count: int) -> Vector2:
	if count <= 1:
		return Vector2.ZERO
	var angle: float = TAU * float(index) / float(count)
	return Vector2(cos(angle), sin(angle)) * LAUNCH_SPREAD_RADIUS


# --- Per-frame update --------------------------------------------------------

func _process(delta: float) -> void:
	_refresh_player_screen()
	for i: int in range(_visuals.size() - 1, -1, -1):
		var visual: PickupVisual = _visuals[i]
		if not _update_visual(visual, delta):
			_free_visual_nodes(visual)
			_visuals.remove_at(i)
	if _visuals.is_empty():
		set_process(false)


## Advances one visual. Returns false when it has finished and should be freed. The player target
## is resolved live every frame, so the icon still reaches the player if they run or the camera moves.
func _update_visual(visual: PickupVisual, delta: float) -> bool:
	if not visual.in_bounce:
		visual.flight_elapsed += delta
		if visual.flight_elapsed <= 0.0:
			return true
		var t: float = clampf(visual.flight_elapsed / FLIGHT_DURATION, 0.0, 1.0)
		var eased: float = 1.0 - (1.0 - t) * (1.0 - t)
		if visual.world_visual != null:
			if not is_instance_valid(visual.world_visual):
				return false
			_update_world_flight(visual, delta, eased)
		elif visual.screen_sprite != null and is_instance_valid(visual.screen_sprite):
			_update_screen_flight(visual, t, eased)
		else:
			return false
		if t >= 1.0:
			_start_screen_bounce(visual)
		return true

	if not is_instance_valid(visual.screen_sprite):
		return false
	visual.bounce_elapsed += delta
	var b: float = clampf(visual.bounce_elapsed / BOUNCE_DURATION, 0.0, 1.0)
	var rise: float = -BOUNCE_RISE * (1.0 - (1.0 - b) * (1.0 - b))
	_position_sprite(visual.screen_sprite, _player_target_screen() + Vector2(0.0, rise))
	var pop_scale: float = _bounce_scale(b)
	visual.screen_sprite.scale = Vector2(pop_scale, pop_scale)
	visual.screen_sprite.modulate.a = 1.0 if b < 0.5 else clampf(1.0 - (b - 0.5) / 0.5, 0.0, 1.0)
	return b < 1.0


func _update_world_flight(visual: PickupVisual, delta: float, eased: float) -> void:
	var item_visual: GroundItemVisual = visual.world_visual
	item_visual.visible = true
	var player: Node2D = _player_node()
	var target_world: Vector2 = player.global_position if player != null else visual.start_position
	item_visual.set_arc_flight_pose(
		visual.start_position,
		target_world,
		eased,
		ARC_HEIGHT,
		0.0,
		_player_catch_world_height(),
		0,
		visual.spread_offset
	)
	item_visual.sprite.rotation += visual.rotation_velocity * delta


func _update_screen_flight(visual: PickupVisual, progress: float, eased: float) -> void:
	visual.screen_sprite.visible = true
	var target: Vector2 = _player_target_screen()
	var base: Vector2 = visual.start_position.lerp(target, eased)
	var arc: Vector2 = Vector2(0.0, -ARC_HEIGHT * sin(PI * progress))
	var spread: Vector2 = visual.spread_offset * (1.0 - eased)
	_position_sprite(visual.screen_sprite, base + arc + spread)
	var flight_scale: float = lerpf(FLIGHT_START_SCALE, 1.0, eased)
	visual.screen_sprite.scale = Vector2(flight_scale, flight_scale)


func _start_screen_bounce(visual: PickupVisual) -> void:
	if visual.world_visual != null and is_instance_valid(visual.world_visual):
		visual.world_visual.visible = false
		visual.world_visual.queue_free()
	visual.world_visual = null
	if visual.screen_sprite == null:
		visual.screen_sprite = _create_screen_sprite(visual.texture)
		add_child(visual.screen_sprite)
	visual.screen_sprite.visible = true
	visual.screen_sprite.scale = Vector2.ONE
	_position_sprite(visual.screen_sprite, _player_target_screen())
	visual.in_bounce = true


func _free_visual_nodes(visual: PickupVisual) -> void:
	if visual.world_visual != null and is_instance_valid(visual.world_visual):
		visual.world_visual.queue_free()
	if visual.screen_sprite != null and is_instance_valid(visual.screen_sprite):
		visual.screen_sprite.queue_free()


## Pop up to BOUNCE_POP_SCALE, then shrink to nothing — reads as "acquired!".
func _bounce_scale(b: float) -> float:
	if b < BOUNCE_POP_FRACTION:
		return lerpf(1.0, BOUNCE_POP_SCALE, b / BOUNCE_POP_FRACTION)
	return lerpf(BOUNCE_POP_SCALE, 0.0, (b - BOUNCE_POP_FRACTION) / (1.0 - BOUNCE_POP_FRACTION))


func _position_sprite(sprite: TextureRect, center: Vector2) -> void:
	sprite.position = center - ICON_SIZE * 0.5


# --- Player / coordinate resolution ------------------------------------------

func _player_node() -> Node2D:
	if _player != null and is_instance_valid(_player):
		return _player
	_player = get_tree().get_first_node_in_group("player") as Node2D
	return _player


func _refresh_player_screen() -> void:
	var player: Node2D = _player_node()
	if player == null:
		return
	_player_head_screen = _world_to_screen(player.global_position) + PLAYER_HEAD_OFFSET
	_has_player_screen = true


func _player_target_screen() -> Vector2:
	if _has_player_screen:
		return _player_head_screen
	# No player yet: aim at the screen centre so the animation still completes harmlessly.
	return get_viewport_rect().size * 0.5


func _world_to_screen(world_position: Vector2) -> Vector2:
	return get_viewport().get_canvas_transform() * world_position


func _player_catch_world_height() -> float:
	var canvas_transform: Transform2D = get_viewport().get_canvas_transform()
	var canvas_scale: float = maxf(0.001, canvas_transform.y.length())
	return absf(PLAYER_HEAD_OFFSET.y) / canvas_scale


func _world_visual_parent() -> Node2D:
	return get_tree().current_scene as Node2D
