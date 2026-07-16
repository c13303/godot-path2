extends Node2D
class_name BambooPlantVisual

## One authored bamboo plant's visual: its sprite, its immature/mature frame, its
## base-anchored idle dance (mature plants only), and its world-Y z_index. Nothing else — maturity rules,
## harvesting, currency, save state, dawn events, terrain slowdown and build reservations
## all belong to BambooHarvestController.
##
## Anchoring: bamboo.png holds two horizontal frames. Each frame is the bamboo artwork with
## a transparent margin of FRAME_PADDING_PIXELS authored on every side, so the artwork is
## the frame minus that padding. This node's origin is the floor cell centre (its sort
## point); `_pivot` sits at the cell's bottom edge, and the centred sprite hangs half the
## artwork height above it. That puts the artwork's bottom edge exactly on the tile's bottom
## edge, so its lower half covers the authored tile and its upper half rises above it. The
## dance transforms `_pivot`, so sway and breathe rotate/scale around the planted base
## rather than the sprite centre.

const BAMBOO_TEXTURE: Texture2D = preload("res://assets/sprites/plants/bamboo.png")
const FRAME_IMMATURE: int = 0
const FRAME_MATURE: int = 1
const FRAME_COLUMNS: int = 2
const FRAME_ROWS: int = 1
## Transparent margin authored around the bamboo artwork inside every frame.
const FRAME_PADDING_PIXELS: float = 4.0
## The artwork expected inside that padding. Only used to warn when the asset stops matching
## the anchoring; the offsets themselves are derived from the live texture and tile size.
const EXPECTED_ARTWORK_SIZE: Vector2 = Vector2(32.0, 64.0)

@export_group("Dance")
## Peak sway rotation, in degrees, around the planted base.
@export var sway_degrees: float = 7.0
## Sway oscillations per second.
@export var sway_speed: float = 1.0
## Breathing scale delta on Y (0.06 = ±6%).
@export_range(0.0, 0.5) var breathe_amount: float = 0.06
## Breaths per second.
@export var breathe_speed: float = 1.3
## Tiny bob at the base, in px.
@export var bob_pixels: float = 1.5

var _pivot: Node2D = null
var _sprite: Sprite2D = null
var _base_offset_y: float = 0.0
var _sway_phase: float = 0.0
var _breathe_phase: float = 0.0
var _time: float = 0.0


## Places this bamboo on its floor cell. Must be called after the node is in the tree, so
## `cell_center_world` resolves against the live canvas transform. `tile_size` is the real
## floor tile size; the sprite offset is never derived from a hardcoded tile dimension.
func setup(cell_center_world: Vector2, tile_size: Vector2) -> void:
	global_position = cell_center_world
	# World-Y ordering, the same rule agents use, so an agent standing above a
	# bamboo draws behind it and one below draws in front.
	WorldDepthSort.apply_world_depth(self, cell_center_world)
	_base_offset_y = tile_size.y * 0.5
	# Desync every plant so the grove never sways in unison.
	_sway_phase = randf() * TAU
	_breathe_phase = randf() * TAU
	_warn_if_artwork_unexpected()
	_build_sprite()
	# Matches _build_sprite's mature default frame; set_mature owns processing from here on.
	set_process(true)


## The only state this visual accepts: which frame to show. An immature plant stands still:
## the dance belongs to the grown bamboo, so it stops and returns to rest until maturity
## comes back. The phase is kept, so a regrown plant resumes its own desynced sway.
func set_mature(value: bool) -> void:
	if _sprite == null:
		return
	_sprite.frame = FRAME_MATURE if value else FRAME_IMMATURE
	set_process(value)
	if not value:
		_rest_pivot()


func _build_sprite() -> void:
	_pivot = Node2D.new()
	_pivot.name = "Pivot"
	_pivot.position = Vector2(0.0, _base_offset_y)
	add_child(_pivot)

	_sprite = Sprite2D.new()
	_sprite.name = "Sprite"
	_sprite.texture = BAMBOO_TEXTURE
	_sprite.hframes = FRAME_COLUMNS
	_sprite.vframes = FRAME_ROWS
	_sprite.centered = true
	_sprite.frame = FRAME_MATURE
	_sprite.position = Vector2(0.0, -_artwork_size().y * 0.5)
	_pivot.add_child(_sprite)


func _process(delta: float) -> void:
	if _pivot == null:
		return
	# Plain transform writes on a pooled pivot: no tween is allocated per frame.
	_time += delta
	var sway_omega: float = sway_speed * TAU
	var breathe_omega: float = breathe_speed * TAU
	var angle: float = deg_to_rad(sway_degrees) * sin(_time * sway_omega + _sway_phase)
	var scale_y: float = 1.0 + breathe_amount * sin(_time * breathe_omega + _breathe_phase)
	# Widen X as Y squashes to fake constant volume, like GrownupRoseDance.
	var scale_x: float = 1.0 / scale_y
	var bob: float = -bob_pixels * absf(sin(_time * breathe_omega * 0.5 + _sway_phase))
	_pivot.rotation = angle
	_pivot.scale = Vector2(scale_x, scale_y)
	_pivot.position = Vector2(0.0, _base_offset_y + bob)


## Undoes the last danced frame, so a plant frozen mid-sway does not stay leaning.
func _rest_pivot() -> void:
	if _pivot == null:
		return
	_pivot.rotation = 0.0
	_pivot.scale = Vector2.ONE
	_pivot.position = Vector2(0.0, _base_offset_y)


func _frame_size() -> Vector2:
	if BAMBOO_TEXTURE == null:
		return Vector2.ZERO
	return BAMBOO_TEXTURE.get_size() / Vector2(float(FRAME_COLUMNS), float(FRAME_ROWS))


func _artwork_size() -> Vector2:
	return _frame_size() - Vector2(FRAME_PADDING_PIXELS, FRAME_PADDING_PIXELS) * 2.0


func _warn_if_artwork_unexpected() -> void:
	var artwork_size: Vector2 = _artwork_size()
	if artwork_size.is_equal_approx(EXPECTED_ARTWORK_SIZE):
		return
	push_warning(
		"BambooPlantVisual: bamboo.png frames are %s, giving %s of artwork inside %.0fpx padding (expected %s); tile anchoring may be off."
		% [str(_frame_size()), str(artwork_size), FRAME_PADDING_PIXELS, str(EXPECTED_ARTWORK_SIZE)]
	)
