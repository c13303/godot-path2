extends Node
class_name CharacterAnimation

## Procedural "alive" animation for a character sprite: a squash-&-stretch walk
## bounce and a subtle breathing idle, driven entirely by transform (no shader,
## no keyframes). Attach this to a child Node of a Node2D body (player / monster);
## it animates a Sprite2D sibling.
##
## Movement speed is measured from the body's own position delta each frame, so it
## works no matter how the body moves (native steering, physics, tween). It NEVER
## touches the body transform (z-order is derived from the body's y) and it captures
## the sprite's rest position/scale on the first frame — after the parent's _ready
## has applied any sprite offset — then layers the bounce on top. Walk and breathe
## are the same sine math at different amplitude/speed; a blend eases between them.

# Preset fills the tuning fields below at startup. Pick CUSTOM to hand-tune in the
# inspector; PLAYER / MONSTER override the fields with their bundled values.
enum Preset { CUSTOM, PLAYER, MONSTER }

## Which bundled tuning to apply on _ready. CUSTOM = use the values set below.
@export var preset: Preset = Preset.CUSTOM

@export_group("Target")
## Sprite2D to animate. Empty = first Sprite2D found among the parent's children.
@export var target_sprite_path: NodePath
## Reference speed (px/s) that counts as "full speed" for velocity scaling.
## 0 = use the parent's max_speed, falling back to 100 if it has none.
@export var reference_speed: float = 0.0

@export_group("Feet anchor")
## Keep the sprite's bottom edge planted while it squashes/stretches (so squash
## doesn't look like the whole sprite is floating). The hop itself still lifts it.
@export var anchor_to_feet: bool = true
## Rest rendered half-height in local px used for feet anchoring.
## 0 = auto from the sprite's frame height and authored scale.
@export var sprite_half_height: float = 0.0

@export_group("Walk bounce")
## Apex height of each hop, in px.
@export var bounce_height: float = 4.0
## Hops per second at full speed.
@export var bounce_speed: float = 4.5
## Squash/stretch strength, 0..1. At the apex the sprite stretches tall+thin; at
## the bottom of the step it squashes short+wide.
@export_range(0.0, 1.0) var walk_squash: float = 0.12
## Widen X as Y squashes (and vice-versa) to fake constant volume — the classic
## cartoon look. Off = only Y changes.
@export var preserve_volume: bool = true
## Speed (px/s) above which the walk bounce plays; below it eases into the idle.
@export var velocity_threshold: float = 5.0
## Scale hop height by how fast the character is actually moving.
@export var amplitude_scales_with_velocity: bool = true
## Speed up the hop tempo as the character moves faster.
@export var speed_scales_with_velocity: bool = true

@export_group("Idle breathe")
## Play the breathing pulse while standing still.
@export var breathe_enabled: bool = true
## Breathing scale delta (0.03 = ±3% on Y).
@export_range(0.0, 0.5) var breathe_amount: float = 0.03
## Breaths per second.
@export var breathe_speed: float = 0.8

@export_group("Blend")
## Seconds to ease between idle and walk when the character starts/stops moving.
@export var state_blend_time: float = 0.15
## Start each instance at a random phase so a crowd doesn't pulse in unison.
@export var randomize_phase: bool = true
## Low-pass smoothing for the measured speed, 0..1 (higher = smoother/laggier).
@export_range(0.0, 0.99) var velocity_smoothing: float = 0.6

var _body: Node2D
var _sprite: Sprite2D
var _initialized: bool = false
var _base_position: Vector2 = Vector2.ZERO
var _base_scale: Vector2 = Vector2.ONE
var _half_height: float = 0.0
var _ref_speed: float = 100.0

var _last_body_pos: Vector2 = Vector2.ZERO
var _speed: float = 0.0  # smoothed measured speed (px/s)
var _walk_phase: float = 0.0
var _breathe_phase: float = 0.0
var _walk_weight: float = 0.0  # 0 = idle, 1 = walking; eased over state_blend_time


func _ready() -> void:
	_apply_preset()
	_body = get_parent() as Node2D
	_sprite = _resolve_sprite()
	if _body == null or _sprite == null:
		push_warning("CharacterAnimation: needs a Node2D parent with a Sprite2D child; disabling.")
		set_process(false)
		return
	if randomize_phase:
		_walk_phase = randf() * TAU
		_breathe_phase = randf() * TAU


# Captured on the first frame so the parent's _ready (which may reposition the
# sprite, e.g. player.gd applying sprite_offset) has already run.
func _initialize_rest_pose() -> void:
	_base_position = _sprite.position
	_base_scale = _sprite.scale
	_half_height = _compute_half_height()
	_ref_speed = _resolve_reference_speed()
	_last_body_pos = _body.global_position
	_initialized = true


func _process(delta: float) -> void:
	if not _initialized:
		_initialize_rest_pose()
		return
	if _is_parent_paused() or delta <= 0.0:
		return

	# Measure speed from the body's own movement (works for any drive method).
	var raw_speed: float = (_body.global_position - _last_body_pos).length() / delta
	_last_body_pos = _body.global_position
	_speed = lerpf(raw_speed, _speed, velocity_smoothing)
	var vnorm: float = clampf(_speed / maxf(0.001, _ref_speed), 0.0, 1.0)

	# Ease the walk/idle blend weight toward the current movement state.
	var target_weight: float = 1.0 if _speed > velocity_threshold else 0.0
	var blend_rate: float = 1.0 / maxf(0.0001, state_blend_time)
	_walk_weight = move_toward(_walk_weight, target_weight, delta * blend_rate)

	# --- Walk bounce ---
	var hop_amp: float = bounce_height * (vnorm if amplitude_scales_with_velocity else 1.0)
	var step_speed: float = bounce_speed * (lerpf(0.6, 1.0, vnorm) if speed_scales_with_velocity else 1.0)
	_walk_phase = fmod(_walk_phase + delta * step_speed * PI, TAU)
	var hop: float = absf(sin(_walk_phase))                      # 0 ground .. 1 apex
	var walk_offset: float = -hop_amp * hop
	var sy_walk: float = 1.0 + walk_squash * (hop - 0.5) * 2.0   # tall at apex, squashed at ground

	# --- Idle breathe ---
	_breathe_phase = fmod(_breathe_phase + delta * breathe_speed * TAU, TAU)
	var sy_idle: float = 1.0 + (breathe_amount * sin(_breathe_phase) if breathe_enabled else 0.0)

	# --- Blend the two states ---
	var w: float = _walk_weight
	var sy: float = lerpf(sy_idle, sy_walk, w)
	var offset_y: float = lerpf(0.0, walk_offset, w)
	var sx: float = (1.0 / sy) if preserve_volume else 1.0

	var feet: float = (1.0 - sy) * _half_height if anchor_to_feet else 0.0
	_sprite.scale = Vector2(_base_scale.x * sx, _base_scale.y * sy)
	_sprite.position = _base_position + Vector2(0.0, offset_y + feet)


func animated_parent_position(rest_parent_position: Vector2) -> Vector2:
	if not _initialized or _sprite == null:
		return rest_parent_position

	var offset_from_sprite: Vector2 = rest_parent_position - _base_position
	var scale_x: float = 1.0
	var scale_y: float = 1.0
	if not is_zero_approx(_base_scale.x):
		scale_x = _sprite.scale.x / _base_scale.x
	if not is_zero_approx(_base_scale.y):
		scale_y = _sprite.scale.y / _base_scale.y
	return _sprite.position + Vector2(offset_from_sprite.x * scale_x, offset_from_sprite.y * scale_y)


func _resolve_sprite() -> Sprite2D:
	if not target_sprite_path.is_empty():
		return get_node_or_null(target_sprite_path) as Sprite2D
	var parent: Node = get_parent()
	if parent:
		for child in parent.get_children():
			if child is Sprite2D:
				return child
	return null


func _compute_half_height() -> float:
	if sprite_half_height > 0.0:
		return sprite_half_height
	if _sprite and _sprite.texture:
		var frame_h: float = float(_sprite.texture.get_height()) / float(maxi(1, _sprite.vframes))
		return frame_h * absf(_base_scale.y) * 0.5
	return 0.0


func _resolve_reference_speed() -> float:
	if reference_speed > 0.0:
		return reference_speed
	if _body:
		var ms: Variant = _body.get("max_speed")
		if ms != null and float(ms) > 0.0:
			return float(ms)
	return 100.0


func _is_parent_paused() -> bool:
	if _body == null:
		return false
	var paused: Variant = _body.get("_paused")
	return paused is bool and paused


func _apply_preset() -> void:
	match preset:
		Preset.PLAYER:
			bounce_height = 1.5
			bounce_speed = 4
			walk_squash = 0.07
			breathe_amount = 0.03
			breathe_speed = 0.8
			velocity_threshold = 5.0
			state_blend_time = 0.15
			preserve_volume = true
			anchor_to_feet = true
			amplitude_scales_with_velocity = true
			speed_scales_with_velocity = true
			randomize_phase = false
		Preset.MONSTER:
			bounce_height = 1.125
			bounce_speed = 3.5
			walk_squash = 0.07
			breathe_amount = 0.05
			breathe_speed = 1.1
			velocity_threshold = 5.0
			state_blend_time = 0.15
			preserve_volume = true
			anchor_to_feet = true
			amplitude_scales_with_velocity = true
			speed_scales_with_velocity = true
			randomize_phase = true
		Preset.CUSTOM:
			pass
