extends Control
class_name PlayerPickupFeedbackController

## Visual-only "you picked this up" feedback. It flies an acquired item's icon from a world or
## screen source to the player, then pops it above the player's head and fades it away. It owns no
## game state: progression, inventory and world sources are committed by the caller before it asks
## for feedback, so a missing player, texture or controller can never lose a reward.
##
## Icons live on this screen-space Control (a child of the GameUI CanvasLayer), so they keep a
## constant readable pixel size and work for both world and UI sources. Processing runs only while
## at least one visual is alive; there is no permanent polling.

const ITEMS_TEXTURE: Texture2D = preload("res://assets/sprites/legval/items.png")
const ITEM_FRAME_SIZE: Vector2 = Vector2(32.0, 32.0)
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
	var sprite: TextureRect = null
	var start_position: Vector2 = Vector2.ZERO
	var spread_offset: Vector2 = Vector2.ZERO
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
	return _play(item_id, _world_to_screen(world_position), quantity)


## Fly `quantity` icons of `item_id` from a screen position (e.g. a dialog row) to the player.
func play_from_screen(item_id: String, screen_position: Vector2, quantity: int = 1) -> bool:
	return _play(item_id, screen_position, quantity)


# --- Spawning ----------------------------------------------------------------

func _play(item_id: String, screen_start: Vector2, quantity: int) -> bool:
	if quantity <= 0:
		return false
	var texture: AtlasTexture = _resolve_icon(item_id)
	if texture == null:
		return false
	var event_count: int = mini(quantity, PER_EVENT_VISUAL_CAP)
	var global_room: int = GLOBAL_ACTIVE_VISUAL_CAP - _visuals.size()
	var spawn_count: int = mini(event_count, global_room)
	if spawn_count <= 0:
		return false
	var stagger: float = minf(LAUNCH_STAGGER_MAX, LAUNCH_STAGGER_TOTAL / float(maxi(spawn_count - 1, 1)))
	for i: int in range(spawn_count):
		_spawn_visual(texture, screen_start, i, spawn_count, float(i) * stagger)
	set_process(true)
	return true


func _spawn_visual(texture: AtlasTexture, screen_start: Vector2, index: int, count: int, delay: float) -> void:
	var sprite: TextureRect = TextureRect.new()
	sprite.texture = texture
	sprite.custom_minimum_size = ICON_SIZE
	sprite.size = ICON_SIZE
	sprite.pivot_offset = ICON_SIZE * 0.5
	sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sprite.scale = Vector2(FLIGHT_START_SCALE, FLIGHT_START_SCALE)
	sprite.visible = delay <= 0.0
	add_child(sprite)
	_position_sprite(sprite, screen_start)

	var visual: PickupVisual = PickupVisual.new()
	visual.sprite = sprite
	visual.start_position = screen_start
	visual.spread_offset = _spread_offset(index, count)
	visual.flight_elapsed = -delay
	_visuals.append(visual)


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
			if is_instance_valid(visual.sprite):
				visual.sprite.queue_free()
			_visuals.remove_at(i)
	if _visuals.is_empty():
		set_process(false)


## Advances one visual. Returns false when it has finished and should be freed. The player target
## is resolved live every frame, so the icon still reaches the player if they run or the camera moves.
func _update_visual(visual: PickupVisual, delta: float) -> bool:
	if not is_instance_valid(visual.sprite):
		return false
	if not visual.in_bounce:
		visual.flight_elapsed += delta
		if visual.flight_elapsed <= 0.0:
			return true
		visual.sprite.visible = true
		var t: float = clampf(visual.flight_elapsed / FLIGHT_DURATION, 0.0, 1.0)
		var eased: float = 1.0 - (1.0 - t) * (1.0 - t)
		var target: Vector2 = _player_target_screen()
		var base: Vector2 = visual.start_position.lerp(target, eased)
		var arc: Vector2 = Vector2(0.0, -ARC_HEIGHT * sin(PI * t))
		var spread: Vector2 = visual.spread_offset * (1.0 - eased)
		_position_sprite(visual.sprite, base + arc + spread)
		var flight_scale: float = lerpf(FLIGHT_START_SCALE, 1.0, eased)
		visual.sprite.scale = Vector2(flight_scale, flight_scale)
		if t >= 1.0:
			visual.in_bounce = true
		return true

	visual.bounce_elapsed += delta
	var b: float = clampf(visual.bounce_elapsed / BOUNCE_DURATION, 0.0, 1.0)
	var rise: float = -BOUNCE_RISE * (1.0 - (1.0 - b) * (1.0 - b))
	_position_sprite(visual.sprite, _player_target_screen() + Vector2(0.0, rise))
	var pop_scale: float = _bounce_scale(b)
	visual.sprite.scale = Vector2(pop_scale, pop_scale)
	visual.sprite.modulate.a = 1.0 if b < 0.5 else clampf(1.0 - (b - 0.5) / 0.5, 0.0, 1.0)
	return b < 1.0


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


# --- Icon resolution ---------------------------------------------------------

## The icon for a canonical item_id: a currency region when the id names a currency, otherwise the
## item's catalog frame. Both come from items.png. Returns null when there is no usable icon, so the
## caller skips the visual without touching the (already granted) reward.
func _resolve_icon(item_id: String) -> AtlasTexture:
	if item_id == "":
		return null
	var texture: AtlasTexture = AtlasTexture.new()
	texture.atlas = ITEMS_TEXTURE
	var currency: StringName = CurrencyCatalog.get_currency_for_item_id(item_id)
	if currency != &"":
		texture.region = CurrencyCatalog.get_icon_region(currency)
		return texture
	var frame: int = int(ItemCatalog.get_item_def(item_id).get("frame", -1))
	if frame < 0:
		return null
	texture.region = Rect2(Vector2(float(frame) * ITEM_FRAME_SIZE.x, 0.0), ITEM_FRAME_SIZE)
	return texture
