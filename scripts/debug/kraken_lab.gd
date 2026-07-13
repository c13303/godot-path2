extends Node2D

class AttackPreset:
	var name: String
	var percent: float
	var direction: Vector2

	func _init(p_name: String, p_percent: float, p_direction: Vector2) -> void:
		name = p_name
		percent = p_percent
		direction = p_direction.normalized()


class LabCorpsePart:
	var sprite: Sprite2D
	var velocity: Vector2 = Vector2.ZERO
	var age: float = 0.0
	var lifetime: float = 0.0
	var rotation_velocity: float = 0.0
	var base_scale: Vector2 = Vector2.ONE


const MODE_AUTO: StringName = &"auto"
const MODE_IDLE: StringName = &"idle"
const MODE_SEQUENCE: StringName = &"sequence"
const MODE_GRAB_LOOP: StringName = &"grab_loop"
const MODE_EATING_LOOP: StringName = &"eating_loop"
const MODE_DIGESTION_LOOP: StringName = &"digestion_loop"
const MODE_MOUSE_GRAB: StringName = &"mouse_grab"

const PHASE_IDLE_WAIT: StringName = &"idle_wait"
const PHASE_GRABBING: StringName = &"grabbing"
const PHASE_EATING: StringName = &"eating"
const PHASE_DISAPPEARING: StringName = &"disappearing"
const PHASE_DIGESTING: StringName = &"digesting"
const PHASE_DONE: StringName = &"done"

const AUTO_IDLE_SECONDS: float = 2.0
const LAB_DIGESTION_SECONDS: float = 2.5
const DUMMY_DISAPPEAR_SECONDS: float = 0.36
const DUMMY_CAPTURE_ROTATION_BLEND_SECONDS: float = 0.08
const MONSTER_TEXTURE: Texture2D = preload("res://assets/sprites/legval/monster.png")
const BLOOD_PARTS_TEXTURE: Texture2D = preload("res://assets/sprites/fx/blood_parts.png")
const CORPSE_PART_COUNT: int = 5
const CORPSE_PART_LIFETIME: float = 0.55
const CORPSE_PART_SPEED_MIN: float = 45.0
const CORPSE_PART_SPEED_MAX: float = 120.0

@onready var _kraken: KrakenVisual = $KrakenVisual
@onready var _dummy: Node2D = $DummyMonster
@onready var _dummy_sprite: Sprite2D = $DummyMonster/Sprite2D
@onready var _ui_label: Label = $CanvasLayer/UI/InfoLabel

var _presets: Array[AttackPreset] = []
var _preset_index: int = 0
var _mode: StringName = MODE_AUTO
var _phase: StringName = PHASE_IDLE_WAIT
var _phase_time: float = 0.0
var _dummy_captured: bool = false
var _dummy_disappear_time: float = 0.0
var _active_target_global: Vector2 = Vector2.ZERO
var _active_target_name: String = ""
var _active_target_percent: float = 0.0
var _active_target_angle: float = 0.0
var _automatic_showcase_enabled: bool = true
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _dummy_capture_rotation: float = 0.0
var _dummy_capture_rotation_start: float = 0.0
var _dummy_capture_rotation_time: float = 0.0
var _dummy_capture_rotation_blending: bool = false
var _corpse_parts: Array[LabCorpsePart] = []


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_rng.randomize()
	_build_presets()
	_setup_dummy()
	_connect_kraken_signals()
	_select_preset(0)
	_start_complete_sequence(MODE_AUTO)


func _process(delta: float) -> void:
	var safe_delta: float = maxf(0.0, delta)
	_phase_time += safe_delta
	_update_dummy_motion(safe_delta)
	_update_sequence(safe_delta)
	_update_corpse_parts(safe_delta)
	_update_ui()
	queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	var key_event: InputEventKey = event as InputEventKey
	if key_event != null and key_event.pressed and not key_event.echo:
		_handle_key_press(key_event.keycode)
		return

	var mouse_event: InputEventMouseButton = event as InputEventMouseButton
	if mouse_event != null and mouse_event.pressed and mouse_event.button_index == MOUSE_BUTTON_LEFT:
		_start_mouse_grab(get_global_mouse_position())


func _draw() -> void:
	if not is_instance_valid(_kraken):
		return
	var base: Vector2 = _kraken.position
	draw_rect(Rect2(Vector2(-520.0, -300.0), Vector2(1040.0, 600.0)), Color(0.075, 0.09, 0.105, 1.0), true)
	draw_rect(Rect2(base - Vector2(20.0, 20.0), Vector2(40.0, 40.0)), Color(0.22, 0.24, 0.25, 0.42), false, 2.0)
	draw_arc(base, _kraken.maximum_grab_reach, 0.0, TAU, 96, Color(0.35, 0.55, 0.7, 0.28), 1.5)
	draw_line(_active_target_global + Vector2(-7.0, 0.0), _active_target_global + Vector2(7.0, 0.0), Color(0.9, 0.25, 0.25, 0.9), 2.0)
	draw_line(_active_target_global + Vector2(0.0, -7.0), _active_target_global + Vector2(0.0, 7.0), Color(0.9, 0.25, 0.25, 0.9), 2.0)


func _handle_key_press(keycode: int) -> void:
	if keycode == KEY_1:
		_automatic_showcase_enabled = false
		_reset_to_idle()
	elif keycode == KEY_2:
		_automatic_showcase_enabled = false
		_start_grab_loop()
	elif keycode == KEY_3:
		_automatic_showcase_enabled = false
		_start_eating_loop()
	elif keycode == KEY_4:
		_automatic_showcase_enabled = false
		_start_digestion_loop()
	elif keycode == KEY_SPACE:
		_automatic_showcase_enabled = false
		_start_complete_sequence(MODE_SEQUENCE)
	elif keycode == KEY_TAB:
		_automatic_showcase_enabled = false
		_select_preset(_preset_index + 1)
		_reset_dummy_at_target()
		_mode = MODE_IDLE
		_phase = PHASE_DONE
	elif keycode == KEY_A:
		_automatic_showcase_enabled = not _automatic_showcase_enabled
		if _automatic_showcase_enabled:
			_start_complete_sequence(MODE_AUTO)
		else:
			_mode = MODE_IDLE
			_phase = PHASE_DONE
	elif keycode == KEY_R:
		_automatic_showcase_enabled = false
		_reset_to_idle()


func _build_presets() -> void:
	_presets.clear()
	_presets.append(AttackPreset.new("35% reach - right", 0.35, Vector2.RIGHT))
	_presets.append(AttackPreset.new("65% reach - upper-right", 0.65, Vector2(1.0, -1.0)))
	_presets.append(AttackPreset.new("100% reach - upper-right", 1.0, Vector2(1.0, -1.0)))
	_presets.append(AttackPreset.new("50% reach - up", 0.50, Vector2.UP))
	_presets.append(AttackPreset.new("100% reach - up", 1.0, Vector2.UP))
	_presets.append(AttackPreset.new("70% reach - upper-left", 0.70, Vector2(-1.0, -1.0)))
	_presets.append(AttackPreset.new("100% reach - left", 1.0, Vector2.LEFT))
	_presets.append(AttackPreset.new("45% reach - lower-left", 0.45, Vector2(-1.0, 1.0)))
	_presets.append(AttackPreset.new("75% reach - down", 0.75, Vector2.DOWN))
	_presets.append(AttackPreset.new("100% reach - lower-right", 1.0, Vector2(1.0, 1.0)))


func _setup_dummy() -> void:
	_dummy_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_dummy_sprite.texture = MONSTER_TEXTURE
	_dummy_sprite.hframes = 4
	_dummy_sprite.vframes = 1
	_dummy_sprite.frame = 0
	_dummy_sprite.scale = Vector2(0.75, 0.75)
	_dummy.visible = false


func _connect_kraken_signals() -> void:
	_kraken.grab_contacted.connect(_on_grab_contacted)
	_kraken.grab_retract_finished.connect(_on_grab_retract_finished)
	_kraken.eating_finished.connect(_on_eating_finished)
	_kraken.digestion_finished.connect(_on_digestion_finished)


func _select_preset(index: int) -> void:
	if _presets.is_empty():
		return
	_preset_index = posmod(index, _presets.size())
	var preset: AttackPreset = _presets[_preset_index]
	var distance: float = _kraken.get_effective_maximum_grab_reach() * preset.percent
	_active_target_global = _kraken.global_position + preset.direction * distance
	_active_target_name = preset.name
	_active_target_percent = preset.percent
	_active_target_angle = rad_to_deg(atan2(preset.direction.y, preset.direction.x))


func _start_complete_sequence(mode: StringName) -> void:
	_mode = mode
	_phase = PHASE_IDLE_WAIT
	_phase_time = 0.0
	_dummy_captured = false
	_dummy.visible = false
	_clear_corpse_parts()
	_kraken.reset_to_idle()


func _start_grab_loop() -> void:
	_mode = MODE_GRAB_LOOP
	_phase = PHASE_GRABBING
	_phase_time = 0.0
	_reset_dummy_at_target()
	_kraken.play_grab_retract(_active_target_global)


func _start_eating_loop() -> void:
	_mode = MODE_EATING_LOOP
	_phase = PHASE_EATING
	_phase_time = 0.0
	_dummy_captured = true
	_dummy.visible = true
	_randomize_dummy_capture_rotation()
	_dummy.global_position = _kraken.get_capture_anchor_global_position()
	_dummy.scale = Vector2.ONE
	_dummy.modulate = Color.WHITE
	_kraken.play_eating()


func _start_digestion_loop() -> void:
	_mode = MODE_DIGESTION_LOOP
	_phase = PHASE_DIGESTING
	_phase_time = 0.0
	_dummy.visible = false
	_dummy_captured = false
	_kraken.play_digestion(LAB_DIGESTION_SECONDS)


func _start_mouse_grab(mouse_global_position: Vector2) -> void:
	_automatic_showcase_enabled = false
	_mode = MODE_MOUSE_GRAB
	_phase = PHASE_GRABBING
	_phase_time = 0.0
	var local_target: Vector2 = _kraken.to_local(mouse_global_position)
	var target_length: float = local_target.length()
	var effective_reach: float = _kraken.get_effective_maximum_grab_reach()
	if target_length > effective_reach:
		local_target = local_target / target_length * effective_reach
	_active_target_global = _kraken.to_global(local_target)
	_active_target_name = "Mouse target"
	_active_target_percent = local_target.length() / effective_reach
	_active_target_angle = rad_to_deg(atan2(local_target.y, local_target.x))
	_reset_dummy_at_target()
	_kraken.play_grab_retract(_active_target_global)


func _reset_to_idle() -> void:
	_mode = MODE_IDLE
	_phase = PHASE_DONE
	_phase_time = 0.0
	_dummy_captured = false
	_dummy.visible = false
	_clear_corpse_parts()
	_kraken.reset_to_idle()


func _reset_dummy_at_target() -> void:
	_dummy.global_position = _active_target_global
	_dummy.rotation = 0.0
	_dummy.scale = Vector2.ONE
	_dummy.modulate = Color.WHITE
	_dummy.visible = true
	_dummy_captured = false


func _update_sequence(_delta: float) -> void:
	if _phase == PHASE_IDLE_WAIT and _phase_time >= AUTO_IDLE_SECONDS:
		_reset_dummy_at_target()
		_kraken.play_grab_retract(_active_target_global)
		_phase = PHASE_GRABBING
		_phase_time = 0.0
	elif _phase == PHASE_DISAPPEARING:
		_update_dummy_disappearance()


func _update_dummy_motion(_delta: float) -> void:
	if not _dummy.visible:
		return
	var visual_state: StringName = _kraken.get_animation_state()
	if (visual_state == KrakenVisual.STATE_GRAB_HOLDING or visual_state == KrakenVisual.STATE_GRAB_RETRACTING) and _dummy_captured:
		_dummy.global_position = _kraken.get_tip_global_position()
		_update_dummy_capture_rotation(_delta)
	elif visual_state == KrakenVisual.STATE_EATING:
		_dummy.global_position = _kraken.get_capture_anchor_global_position()
		_update_dummy_capture_rotation(_delta)


func _update_dummy_disappearance() -> void:
	_dummy_disappear_time = minf(DUMMY_DISAPPEAR_SECONDS, _dummy_disappear_time + get_process_delta_time())
	var progress: float = _dummy_disappear_time / DUMMY_DISAPPEAR_SECONDS
	var pulse: float = sin(clampf(progress, 0.0, 1.0) * PI)
	_dummy.scale = Vector2.ONE * (1.0 + pulse * 0.24) * (1.0 - progress * 0.95)
	_dummy.modulate = Color(1.0, 1.0, 1.0, 1.0 - progress)
	if progress >= 1.0:
		_spawn_corpse_burst(_kraken.get_capture_anchor_global_position())
		_dummy.visible = false
		_dummy_captured = false
		_kraken.play_digestion(LAB_DIGESTION_SECONDS)
		_phase = PHASE_DIGESTING
		_phase_time = 0.0


func _on_grab_contacted() -> void:
	_dummy_captured = true
	_dummy.visible = true
	_randomize_dummy_capture_rotation()
	_dummy.global_position = _kraken.get_tip_global_position()
	_spawn_corpse_burst(_dummy.global_position)


func _randomize_dummy_capture_rotation() -> void:
	_dummy_capture_rotation_start = _dummy.rotation
	_dummy_capture_rotation = _rng.randf_range(-PI, PI)
	_dummy_capture_rotation_time = 0.0
	_dummy_capture_rotation_blending = true


func _update_dummy_capture_rotation(delta: float) -> void:
	if not _dummy_capture_rotation_blending:
		_dummy.rotation = _dummy_capture_rotation
		return
	_dummy_capture_rotation_time = minf(DUMMY_CAPTURE_ROTATION_BLEND_SECONDS, _dummy_capture_rotation_time + delta)
	var progress: float = _dummy_capture_rotation_time / DUMMY_CAPTURE_ROTATION_BLEND_SECONDS
	var eased_progress: float = progress * progress * (3.0 - 2.0 * progress)
	_dummy.rotation = lerp_angle(_dummy_capture_rotation_start, _dummy_capture_rotation, eased_progress)
	if progress >= 1.0:
		_dummy_capture_rotation_blending = false


func _spawn_corpse_burst(world_position: Vector2) -> void:
	for index: int in range(CORPSE_PART_COUNT):
		var part: LabCorpsePart = LabCorpsePart.new()
		var sprite: Sprite2D = Sprite2D.new()
		sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		sprite.texture = BLOOD_PARTS_TEXTURE
		sprite.hframes = 3
		sprite.frame = index % 3
		sprite.centered = true
		sprite.position = to_local(world_position)
		sprite.rotation = _rng.randf_range(-PI, PI)
		sprite.z_index = 20
		add_child(sprite)

		var direction_angle: float = _rng.randf_range(-PI, PI)
		var speed: float = _rng.randf_range(CORPSE_PART_SPEED_MIN, CORPSE_PART_SPEED_MAX)
		part.sprite = sprite
		part.velocity = Vector2.from_angle(direction_angle) * speed
		part.lifetime = CORPSE_PART_LIFETIME
		part.rotation_velocity = _rng.randf_range(-9.0, 9.0)
		part.base_scale = Vector2.ONE * _rng.randf_range(0.75, 1.05)
		sprite.scale = part.base_scale
		_corpse_parts.append(part)


func _update_corpse_parts(delta: float) -> void:
	for index: int in range(_corpse_parts.size() - 1, -1, -1):
		var part: LabCorpsePart = _corpse_parts[index]
		if not is_instance_valid(part.sprite):
			_corpse_parts.remove_at(index)
			continue
		part.age += delta
		if part.age >= part.lifetime:
			part.sprite.queue_free()
			_corpse_parts.remove_at(index)
			continue
		var progress: float = part.age / part.lifetime
		part.sprite.position += part.velocity * delta
		part.velocity *= pow(0.08, delta)
		part.sprite.rotation += part.rotation_velocity * delta
		part.sprite.modulate = Color(1.0, 1.0, 1.0, 1.0 - _smooth_step(progress))
		part.sprite.scale = part.base_scale * (1.0 - progress * 0.35)


func _clear_corpse_parts() -> void:
	for part: LabCorpsePart in _corpse_parts:
		if is_instance_valid(part.sprite):
			part.sprite.queue_free()
	_corpse_parts.clear()


func _smooth_step(value: float) -> float:
	var clamped_value: float = clampf(value, 0.0, 1.0)
	return clamped_value * clamped_value * (3.0 - 2.0 * clamped_value)


func _on_grab_retract_finished() -> void:
	if _mode == MODE_AUTO or _mode == MODE_SEQUENCE:
		_phase = PHASE_EATING
		_phase_time = 0.0
		_kraken.play_eating()
	elif _mode == MODE_GRAB_LOOP:
		_select_preset(_preset_index + 1)
		_start_grab_loop()


func _on_eating_finished() -> void:
	if _mode == MODE_EATING_LOOP:
		_start_eating_loop()
		return
	if _mode == MODE_AUTO or _mode == MODE_SEQUENCE:
		_phase = PHASE_DISAPPEARING
		_phase_time = 0.0
		_dummy_disappear_time = 0.0
		_dummy.global_position = _kraken.get_capture_anchor_global_position()


func _on_digestion_finished() -> void:
	if _mode == MODE_DIGESTION_LOOP:
		_start_digestion_loop()
	elif _mode == MODE_AUTO and _automatic_showcase_enabled:
		_select_preset(_preset_index + 1)
		_start_complete_sequence(MODE_AUTO)
	else:
		_reset_to_idle()


func _update_ui() -> void:
	var distance: float = _kraken.global_position.distance_to(_active_target_global)
	var state_text: String = String(_kraken.get_animation_state())
	var mode_text: String = "AUTO" if _automatic_showcase_enabled and _mode == MODE_AUTO else String(_mode)
	_ui_label.text = (
		"Kraken laboratory\n"
		+ "Mode: %s  State: %s\n" % [mode_text, state_text]
		+ "Preset: %s\n" % _active_target_name
		+ "Distance: %.1f px  Reach: %.0f%%  Angle: %.1f deg\n" % [distance, _active_target_percent * 100.0, _active_target_angle]
		+ "1 Idle  2 Grab loop  3 Eating loop  4 Digestion loop\n"
		+ "Space Sequence  Tab Next target  A Auto  R Reset  Left click Target"
	)
