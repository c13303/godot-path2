extends Node2D
class_name KrakenVisual

signal grab_contacted
signal grab_retract_finished
signal eating_finished
signal digestion_finished

const STATE_IDLE: StringName = &"idle"
const STATE_GRAB_PREPARING: StringName = &"grab_preparing"
const STATE_GRAB_EXTENDING: StringName = &"grab_extending"
const STATE_GRAB_HOLDING: StringName = &"grab_holding"
const STATE_GRAB_RETRACTING: StringName = &"grab_retracting"
const STATE_EATING: StringName = &"eating"
const STATE_DIGESTING: StringName = &"digesting"

const SEGMENT_COUNT: int = 8
const MOVABLE_SEGMENT_COUNT: int = 7
const CAPTURE_ANCHOR_SEGMENT_INDEX: int = 7
const IDLE_BLEND_DURATION: float = 0.35
const EATING_BLEND_DURATION: float = 0.25
const DIGESTION_BLEND_DURATION: float = 0.32
const DEFAULT_KRAKEN_TEXTURE: Texture2D = preload("res://assets/sprites/animations/kraken.png")

@export var kraken_texture: Texture2D = DEFAULT_KRAKEN_TEXTURE
@export var idle_direction: Vector2 = Vector2.UP
@export_range(4.0, 32.0, 0.5, "or_greater") var idle_segment_spacing: float = 13.0
@export_range(8.0, 40.0, 0.5, "or_greater") var maximum_stretched_segment_spacing: float = 28.0
@export_range(32.0, 320.0, 1.0, "or_greater") var maximum_grab_reach: float = 190.0

@export_range(0.0, 1.5, 0.01) var idle_wave_amplitude: float = 0.42
@export_range(0.1, 8.0, 0.01) var idle_wave_speed: float = 2.0
@export_range(0.0, 2.0, 0.01) var idle_phase_delay: float = 0.48
@export_range(0.0, 1.0, 0.01) var idle_secondary_wave_amount: float = 0.22

@export_range(0.01, 2.0, 0.01) var grab_preparation_duration: float = 0.50
@export_range(0.01, 2.0, 0.01) var grab_extension_duration: float = 0.25
@export_range(0.0, 2.0, 0.01) var grab_contact_hold_duration: float = 0.30
@export_range(0.01, 2.0, 0.01) var grab_retraction_duration: float = 0.10
@export_range(0.0, 120.0, 0.5) var grab_curve_amount: float = 44.0
@export_range(0.0, 1.0, 0.01) var grab_extension_curve_scale: float = 0.22
@export_range(0.0, 40.0, 0.5) var grab_overshoot_amount: float = 9.0

@export_range(0.1, 8.0, 0.01) var eating_duration: float = 3.0
@export_range(0.1, 16.0, 0.01) var eating_idle_speed_multiplier: float = 8.0
@export_range(0.0, 0.6, 0.01) var eating_bite_contraction_amount: float = 0.28
@export_range(0.1, 16.0, 0.01) var eating_bite_speed: float = 7.5
@export_range(0.0, 0.8, 0.01) var eating_upper_sway_amount: float = 0.24

@export_range(0.2, 1.0, 0.01) var digestion_compactness: float = 0.48
@export_range(0.0, 4.0, 0.01) var digestion_curl_amount: float = 1.35
@export_range(0.1, 8.0, 0.01) var digestion_pulse_speed: float = 1.25

@export_range(-6.283, 6.283, 0.001) var sprite_rotation_offset: float = PI * 0.5

var segment_points: PackedVector2Array = PackedVector2Array()

var _segments: Array[Sprite2D] = []
var _state: StringName = STATE_IDLE
var _state_time: float = 0.0
var _idle_time: float = 0.0
var _digestion_duration: float = 2.5
var _grab_target: Vector2 = Vector2.ZERO
var _grab_start_tip: Vector2 = Vector2.ZERO
var _retract_start_tip: Vector2 = Vector2.ZERO
var _capture_anchor_local: Vector2 = Vector2.UP * 24.0
var _idle_start_anchor_local: Vector2 = Vector2.UP * 24.0
var _idle_start_points: PackedVector2Array = PackedVector2Array()
var _eating_start_anchor_local: Vector2 = Vector2.UP * 24.0
var _eating_start_points: PackedVector2Array = PackedVector2Array()
var _digestion_start_anchor_local: Vector2 = Vector2.UP * 24.0
var _digestion_start_points: PackedVector2Array = PackedVector2Array()
var _grab_preparation_start_anchor_local: Vector2 = Vector2.UP * 24.0
var _grab_preparation_start_points: PackedVector2Array = PackedVector2Array()
var _grab_extension_start_points: PackedVector2Array = PackedVector2Array()
var _contact_emitted: bool = false
var _finish_emitted: bool = false


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_setup_segment_points()
	_setup_segments()
	reset_to_idle()


func _process(delta: float) -> void:
	var safe_delta: float = maxf(0.0, delta)
	_idle_time += safe_delta
	_state_time += safe_delta

	if _state == STATE_IDLE:
		_update_idle_pose()
	elif _state == STATE_GRAB_PREPARING:
		_update_grab_preparation()
	elif _state == STATE_GRAB_EXTENDING:
		_update_grab_extension()
	elif _state == STATE_GRAB_HOLDING:
		_update_grab_hold()
	elif _state == STATE_GRAB_RETRACTING:
		_update_grab_retraction()
	elif _state == STATE_EATING:
		_update_eating_pose()
	elif _state == STATE_DIGESTING:
		_update_digestion_pose()

	_apply_segment_transforms()


func play_idle() -> void:
	_capture_idle_start_pose()
	_state = STATE_IDLE
	_state_time = 0.0
	_contact_emitted = false
	_finish_emitted = false
	_update_idle_pose()
	_apply_segment_transforms()


func play_grab_retract(target_global_position: Vector2) -> void:
	var target_local: Vector2 = to_local(target_global_position)
	_grab_target = _clamp_to_reach(target_local)
	_capture_grab_preparation_start_pose()
	_state = STATE_GRAB_PREPARING
	_state_time = 0.0
	_contact_emitted = false
	_finish_emitted = false


func play_eating() -> void:
	_capture_eating_start_pose()
	_state = STATE_EATING
	_state_time = 0.0
	_contact_emitted = false
	_finish_emitted = false


func play_digestion(duration: float) -> void:
	_capture_digestion_start_pose()
	_digestion_duration = maxf(0.05, duration)
	_state = STATE_DIGESTING
	_state_time = 0.0
	_contact_emitted = false
	_finish_emitted = false


func reset_to_idle() -> void:
	play_idle()


func get_tip_global_position() -> Vector2:
	return to_global(segment_points[SEGMENT_COUNT - 1])


func get_capture_anchor_global_position() -> Vector2:
	return to_global(_capture_anchor_local)


func get_animation_state() -> StringName:
	return _state


func get_effective_maximum_grab_reach() -> float:
	return minf(maximum_grab_reach, maximum_stretched_segment_spacing * float(MOVABLE_SEGMENT_COUNT))


func _setup_segment_points() -> void:
	segment_points.resize(SEGMENT_COUNT)
	_idle_start_points.resize(SEGMENT_COUNT)
	_eating_start_points.resize(SEGMENT_COUNT)
	_digestion_start_points.resize(SEGMENT_COUNT)
	_grab_preparation_start_points.resize(SEGMENT_COUNT)
	_grab_extension_start_points.resize(SEGMENT_COUNT)
	for index: int in range(SEGMENT_COUNT):
		segment_points[index] = Vector2.ZERO
		_idle_start_points[index] = Vector2.ZERO
		_eating_start_points[index] = Vector2.ZERO
		_digestion_start_points[index] = Vector2.ZERO
		_grab_preparation_start_points[index] = Vector2.ZERO
		_grab_extension_start_points[index] = Vector2.ZERO


func _setup_segments() -> void:
	var segment_root: Node2D = _get_or_create_segment_root()
	_segments.clear()
	for index: int in range(SEGMENT_COUNT):
		var sprite: Sprite2D = segment_root.get_node_or_null("Segment%d" % index) as Sprite2D
		if sprite == null:
			sprite = Sprite2D.new()
			sprite.name = "Segment%d" % index
			segment_root.add_child(sprite)
		sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		sprite.texture = kraken_texture
		sprite.hframes = SEGMENT_COUNT
		sprite.vframes = 1
		sprite.frame = index
		sprite.centered = true
		sprite.visible = true
		sprite.z_index = index
		_segments.append(sprite)


func _get_or_create_segment_root() -> Node2D:
	var segment_root: Node2D = get_node_or_null("Segments") as Node2D
	if segment_root != null:
		return segment_root
	segment_root = Node2D.new()
	segment_root.name = "Segments"
	add_child(segment_root)
	return segment_root


func _update_idle_pose() -> void:
	var blend: float = _smooth_step(clampf(_state_time / IDLE_BLEND_DURATION, 0.0, 1.0))
	segment_points[0] = Vector2.ZERO
	var base_angle: float = _safe_idle_direction().angle()
	var previous_point: Vector2 = Vector2.ZERO
	for index: int in range(1, SEGMENT_COUNT):
		var ratio: float = float(index) / float(MOVABLE_SEGMENT_COUNT)
		var weight: float = ratio * ratio
		var wave_phase: float = _idle_time * idle_wave_speed - float(index) * idle_phase_delay
		var primary_wave: float = sin(wave_phase) * idle_wave_amplitude * weight
		var secondary_wave: float = sin(wave_phase * 1.73 + 0.9) * idle_wave_amplitude * idle_secondary_wave_amount * ratio
		var angle: float = base_angle + primary_wave + secondary_wave
		previous_point += Vector2.from_angle(angle) * idle_segment_spacing
		segment_points[index] = _idle_start_points[index].lerp(previous_point, blend)
	var target_anchor: Vector2 = _safe_idle_direction() * (idle_segment_spacing * 1.9)
	_capture_anchor_local = _idle_start_anchor_local.lerp(target_anchor, blend)


func _update_grab_preparation() -> void:
	var progress: float = _smooth_step(clampf(_state_time / grab_preparation_duration, 0.0, 1.0))
	var target_direction: Vector2 = _safe_direction(_grab_target)
	var side: Vector2 = Vector2(-target_direction.y, target_direction.x)
	var spacing: float = idle_segment_spacing * 0.58
	var curl_direction: float = -1.0 if target_direction.x < 0.0 else 1.0
	segment_points[0] = Vector2.ZERO
	var previous_point: Vector2 = Vector2.ZERO
	for index: int in range(1, SEGMENT_COUNT):
		var ratio: float = float(index) / float(MOVABLE_SEGMENT_COUNT)
		var curl: float = sin(ratio * PI) * 0.32 * curl_direction * (1.0 - ratio * 0.35)
		var prepared_step: Vector2 = target_direction.rotated(curl) * spacing
		var tucked_offset: Vector2 = side * sin(ratio * PI) * idle_segment_spacing * 0.42 * curl_direction
		previous_point += prepared_step
		var prepared_point: Vector2 = previous_point + tucked_offset
		segment_points[index] = _grab_preparation_start_points[index].lerp(prepared_point, progress)
	_capture_anchor_local = _grab_preparation_start_anchor_local.lerp(segment_points[CAPTURE_ANCHOR_SEGMENT_INDEX], progress)
	if progress >= 1.0:
		_grab_start_tip = segment_points[SEGMENT_COUNT - 1]
		_capture_grab_extension_start_pose()
		_state = STATE_GRAB_EXTENDING
		_state_time = 0.0


func _update_grab_extension() -> void:
	var raw_progress: float = clampf(_state_time / grab_extension_duration, 0.0, 1.0)
	var progress: float = _smooth_step(raw_progress)
	var target_tip: Vector2 = _grab_target
	if raw_progress > 0.82 and grab_overshoot_amount > 0.0:
		var direction: Vector2 = _safe_direction(_grab_target)
		var recoil_phase: float = sin((raw_progress - 0.82) / 0.18 * PI)
		target_tip += direction * grab_overshoot_amount * recoil_phase * 0.35
	var tip: Vector2 = _grab_start_tip.lerp(target_tip, progress)
	segment_points[0] = Vector2.ZERO
	for index: int in range(1, SEGMENT_COUNT):
		var curve_point: Vector2 = _curve_point_to_tip(index, tip, _grab_target.length(), progress, false, grab_extension_curve_scale)
		segment_points[index] = _grab_extension_start_points[index].lerp(curve_point, progress)
	if raw_progress >= 1.0:
		segment_points[SEGMENT_COUNT - 1] = _grab_target
		_apply_segment_transforms()
		if not _contact_emitted:
			_contact_emitted = true
			grab_contacted.emit()
		_retract_start_tip = _grab_target
		_state = STATE_GRAB_HOLDING
		_state_time = 0.0


func _update_grab_hold() -> void:
	_build_curve_to_tip(_grab_target, _grab_target.length(), 1.0, false, grab_extension_curve_scale)
	segment_points[SEGMENT_COUNT - 1] = _grab_target
	if _state_time >= grab_contact_hold_duration:
		_retract_start_tip = _grab_target
		_state = STATE_GRAB_RETRACTING
		_state_time = 0.0


func _update_grab_retraction() -> void:
	var raw_progress: float = clampf(_state_time / grab_retraction_duration, 0.0, 1.0)
	var progress: float = _smooth_step(raw_progress)
	var base_direction: Vector2 = _safe_direction(_retract_start_tip)
	var anchor: Vector2 = _safe_idle_direction() * (idle_segment_spacing * 0.75)
	var side: Vector2 = Vector2(-base_direction.y, base_direction.x)
	var retreat_tip: Vector2 = _cubic_bezier(_retract_start_tip, _retract_start_tip + side * grab_curve_amount * 0.55, anchor + side * grab_curve_amount * 0.20, anchor, progress)
	if raw_progress > 0.78:
		var settle: float = sin((raw_progress - 0.78) / 0.22 * PI)
		retreat_tip += base_direction * grab_overshoot_amount * 0.25 * settle
	_build_curve_to_tip(retreat_tip, retreat_tip.length(), 1.0 - progress * 0.55, true, 0.55)
	_capture_anchor_local = anchor + side * sin(raw_progress * PI) * 2.0
	if raw_progress >= 1.0:
		segment_points[SEGMENT_COUNT - 1] = _capture_anchor_local
		_apply_segment_transforms()
		if not _finish_emitted:
			_finish_emitted = true
			grab_retract_finished.emit()


func _update_eating_pose() -> void:
	var progress: float = clampf(_state_time / eating_duration, 0.0, 1.0)
	var blend: float = _smooth_step(clampf(_state_time / EATING_BLEND_DURATION, 0.0, 1.0))
	var base_angle: float = _safe_idle_direction().angle()
	var eating_time: float = _state_time * eating_idle_speed_multiplier
	var bite_wave: float = sin(_state_time * eating_bite_speed * TAU) * 0.5 + 0.5
	var bite_envelope: float = _smooth_step(bite_wave)
	var spacing: float = idle_segment_spacing * (1.0 - eating_bite_contraction_amount * bite_envelope)
	segment_points[0] = Vector2.ZERO
	var previous_point: Vector2 = Vector2.ZERO
	for index: int in range(1, SEGMENT_COUNT):
		var ratio: float = float(index) / float(MOVABLE_SEGMENT_COUNT)
		var weight: float = ratio * ratio
		var wave_phase: float = eating_time * idle_wave_speed - float(index) * idle_phase_delay
		var primary_wave: float = sin(wave_phase) * idle_wave_amplitude * weight
		var secondary_wave: float = sin(wave_phase * 1.73 + 0.9) * idle_wave_amplitude * idle_secondary_wave_amount * ratio
		var upper_sway: float = sin(eating_time * idle_wave_speed * 0.55 - float(index) * 0.25) * eating_upper_sway_amount * weight
		var bite_curl: float = sin(_state_time * eating_bite_speed * TAU + float(index) * 0.35) * 0.16 * bite_envelope * ratio
		var angle: float = base_angle + primary_wave + secondary_wave + upper_sway + bite_curl
		previous_point += Vector2.from_angle(angle) * spacing
		segment_points[index] = _eating_start_points[index].lerp(previous_point, blend)
	_capture_anchor_local = _eating_start_anchor_local.lerp(segment_points[CAPTURE_ANCHOR_SEGMENT_INDEX], blend)
	if progress >= 1.0 and not _finish_emitted:
		_finish_emitted = true
		eating_finished.emit()


func _update_digestion_pose() -> void:
	var progress: float = clampf(_state_time / _digestion_duration, 0.0, 1.0)
	var blend: float = _smooth_step(clampf(_state_time / DIGESTION_BLEND_DURATION, 0.0, 1.0))
	var base_angle: float = _safe_idle_direction().angle()
	var slow_pulse: float = sin(_state_time * digestion_pulse_speed * TAU) * 0.5 + 0.5
	var contraction: float = 0.10 * slow_pulse + 0.08 * _deterministic_contraction(_state_time)
	var spacing: float = idle_segment_spacing * digestion_compactness * (1.0 - contraction)
	segment_points[0] = Vector2.ZERO
	var previous_point: Vector2 = Vector2.ZERO
	for index: int in range(1, SEGMENT_COUNT):
		var ratio: float = float(index) / float(MOVABLE_SEGMENT_COUNT)
		var weight: float = ratio * ratio
		var wave_phase: float = _state_time * idle_wave_speed * 0.75 - float(index) * idle_phase_delay
		var primary_wave: float = sin(wave_phase) * idle_wave_amplitude * 0.34 * weight
		var secondary_wave: float = sin(wave_phase * 1.73 + 0.9) * idle_wave_amplitude * idle_secondary_wave_amount * 0.25 * ratio
		var curl: float = digestion_curl_amount * 0.18 * ratio
		var angle: float = base_angle + curl + primary_wave + secondary_wave
		previous_point += Vector2.from_angle(angle) * spacing
		segment_points[index] = _digestion_start_points[index].lerp(previous_point, blend)
	_capture_anchor_local = _digestion_start_anchor_local.lerp(segment_points[CAPTURE_ANCHOR_SEGMENT_INDEX], blend)
	if progress >= 1.0 and not _finish_emitted:
		_finish_emitted = true
		digestion_finished.emit()


func _build_curve_to_tip(tip: Vector2, distance: float, unfold: float, retracting: bool, curve_scale: float) -> void:
	segment_points[0] = Vector2.ZERO
	for index: int in range(1, SEGMENT_COUNT):
		segment_points[index] = _curve_point_to_tip(index, tip, distance, unfold, retracting, curve_scale)
	segment_points[SEGMENT_COUNT - 1] = tip


func _curve_point_to_tip(index: int, tip: Vector2, distance: float, unfold: float, retracting: bool, curve_scale: float) -> Vector2:
	var direction: Vector2 = _safe_direction(tip)
	var side: Vector2 = Vector2(-direction.y, direction.x)
	var reach_ratio: float = clampf(distance / maximum_grab_reach, 0.0, 1.0)
	var bend_scale: float = 1.0 - reach_ratio * 0.72
	var retraction_scale: float = 0.45 if retracting else 1.0
	var bend: float = grab_curve_amount * bend_scale * (1.0 - unfold * 0.45) * retraction_scale * curve_scale
	var length: float = tip.length()
	var control_a: Vector2 = direction * length * 0.24 + side * bend
	var control_b: Vector2 = direction * length * 0.68 + side * bend * 0.55
	var ratio: float = float(index) / float(MOVABLE_SEGMENT_COUNT)
	var spacing_bias: float = lerpf(0.86, 1.0, reach_ratio)
	var curve_t: float = clampf(pow(ratio, spacing_bias), 0.0, 1.0)
	return _cubic_bezier(Vector2.ZERO, control_a, control_b, tip, curve_t)


func _apply_segment_transforms() -> void:
	for index: int in range(SEGMENT_COUNT):
		var sprite: Sprite2D = _segments[index]
		if index == 0:
			sprite.position = Vector2.ZERO
			sprite.rotation = 0.0
			sprite.scale = Vector2.ONE
			continue
		sprite.position = segment_points[index]
		sprite.scale = Vector2.ONE
		var direction: Vector2 = segment_points[index] - segment_points[index - 1]
		if direction.length_squared() > 0.0001:
			sprite.rotation = direction.angle() + sprite_rotation_offset


func _clamp_to_reach(local_position: Vector2) -> Vector2:
	var length: float = local_position.length()
	var effective_reach: float = get_effective_maximum_grab_reach()
	if length <= effective_reach:
		return local_position
	if length <= 0.001:
		return _safe_idle_direction() * effective_reach
	return local_position / length * effective_reach


func _safe_idle_direction() -> Vector2:
	if idle_direction.length_squared() <= 0.0001:
		return Vector2.UP
	return idle_direction.normalized()


func _safe_direction(vector: Vector2) -> Vector2:
	if vector.length_squared() <= 0.0001:
		return _safe_idle_direction()
	return vector.normalized()


func _smooth_step(value: float) -> float:
	var clamped_value: float = clampf(value, 0.0, 1.0)
	return clamped_value * clamped_value * (3.0 - 2.0 * clamped_value)


func _cubic_bezier(a: Vector2, b: Vector2, c: Vector2, d: Vector2, t: float) -> Vector2:
	var inverse: float = 1.0 - t
	return a * inverse * inverse * inverse + b * 3.0 * inverse * inverse * t + c * 3.0 * inverse * t * t + d * t * t * t


func _capture_idle_start_pose() -> void:
	_idle_start_anchor_local = _capture_anchor_local
	for index: int in range(SEGMENT_COUNT):
		_idle_start_points[index] = segment_points[index]


func _capture_eating_start_pose() -> void:
	_eating_start_anchor_local = _capture_anchor_local
	for index: int in range(SEGMENT_COUNT):
		_eating_start_points[index] = segment_points[index]


func _capture_digestion_start_pose() -> void:
	_digestion_start_anchor_local = _capture_anchor_local
	for index: int in range(SEGMENT_COUNT):
		_digestion_start_points[index] = segment_points[index]


func _capture_grab_preparation_start_pose() -> void:
	_grab_preparation_start_anchor_local = _capture_anchor_local
	for index: int in range(SEGMENT_COUNT):
		_grab_preparation_start_points[index] = segment_points[index]


func _capture_grab_extension_start_pose() -> void:
	for index: int in range(SEGMENT_COUNT):
		_grab_extension_start_points[index] = segment_points[index]


func _deterministic_contraction(time: float) -> float:
	var cycle: float = fmod(time, 1.7)
	if cycle > 0.18:
		return 0.0
	return sin(cycle / 0.18 * PI)
