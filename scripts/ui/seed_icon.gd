extends TextureRect

signal harvest_animations_finished

const SEED_FLIGHT_SIZE: Vector2 = Vector2(28.0, 28.0)
const BASE_FLIGHT_DURATION: float = 0.72

@export_group("Seed Harvest Animation")
@export_range(0.0, 1.0, 0.01, "suffix:s") var delay_between_seeds: float = 0.06
@export_range(0.1, 5.0, 0.05, "or_greater", "suffix:x") var animation_speed: float = 1.0
@export_range(0.0, 5.0, 0.05, "or_greater", "suffix:x") var curve_strength: float = 1.0

var _active_harvest_animation_count: int = 0

func animate_seed_harvest(
	world_position: Vector2,
	sequence_index: int = 0,
	on_launch: Callable = Callable(),
	credit_on_finish: bool = true,
	stagger_seconds: float = -1.0
) -> bool:
	if texture == null:
		return false
	var game_ui: CanvasLayer = get_parent().get_parent() as CanvasLayer
	if game_ui == null:
		return false
	_active_harvest_animation_count += 1
	var per_icon_delay: float = delay_between_seeds if stagger_seconds < 0.0 else stagger_seconds
	var start_delay: float = float(sequence_index) * per_icon_delay
	if start_delay <= 0.0:
		_start_seed_flight(world_position, on_launch, credit_on_finish)
		return true
	var delay_tween: Tween = create_tween()
	delay_tween.tween_interval(start_delay)
	delay_tween.tween_callback(Callable(self, "_start_seed_flight").bind(world_position, on_launch, credit_on_finish))
	return true

func _start_seed_flight(world_position: Vector2, on_launch: Callable = Callable(), credit_on_finish: bool = true) -> void:
	# The seed pops off the rose now: let the caller dry the source rose.
	if on_launch.is_valid():
		on_launch.call()
	Sfx.play_random_pop()
	var game_ui: CanvasLayer = get_parent().get_parent() as CanvasLayer
	if game_ui == null or texture == null:
		if credit_on_finish:
			_credit_seed()
		_complete_harvest_animation()
		return
	var seed_sprite: TextureRect = TextureRect.new()
	seed_sprite.texture = texture
	seed_sprite.custom_minimum_size = SEED_FLIGHT_SIZE
	seed_sprite.size = SEED_FLIGHT_SIZE
	seed_sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	seed_sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	seed_sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
	seed_sprite.pivot_offset = SEED_FLIGHT_SIZE * 0.5
	game_ui.add_child(seed_sprite)

	var start_position: Vector2 = get_viewport().get_canvas_transform() * world_position
	var target_rect: Rect2 = get_global_rect()
	var end_position: Vector2 = target_rect.get_center() if visible else target_rect.position
	var distance: float = start_position.distance_to(end_position)
	var base_arc_height: float = clampf(distance * 0.22, 70.0, 180.0)
	var arc_height: float = base_arc_height * curve_strength
	var curve_position: Vector2 = (start_position + end_position) * 0.5 + Vector2(0.0, -arc_height)
	var flight_duration: float = BASE_FLIGHT_DURATION / animation_speed
	seed_sprite.position = start_position - SEED_FLIGHT_SIZE * 0.5
	seed_sprite.scale = Vector2(0.45, 0.45)

	var flight_tween: Tween = create_tween()
	flight_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	flight_tween.tween_method(
		Callable(self, "_update_seed_flight").bind(seed_sprite, start_position, curve_position, end_position),
		0.0,
		1.0,
		flight_duration
	)
	flight_tween.parallel().tween_property(seed_sprite, "scale", Vector2.ONE, 0.18 / animation_speed)
	flight_tween.parallel().tween_property(seed_sprite, "rotation", TAU, flight_duration)
	flight_tween.tween_callback(Callable(self, "_finish_seed_flight").bind(seed_sprite, credit_on_finish))

func _update_seed_flight(
	progress: float,
	seed_sprite: TextureRect,
	start_position: Vector2,
	curve_position: Vector2,
	end_position: Vector2
) -> void:
	if not is_instance_valid(seed_sprite):
		return
	var inverse_progress: float = 1.0 - progress
	var curved_position: Vector2 = (
		inverse_progress * inverse_progress * start_position
		+ 2.0 * inverse_progress * progress * curve_position
		+ progress * progress * end_position
	)
	seed_sprite.position = curved_position - SEED_FLIGHT_SIZE * 0.5

func _finish_seed_flight(seed_sprite: TextureRect, credit_on_finish: bool = true) -> void:
	if is_instance_valid(seed_sprite):
		seed_sprite.queue_free()
	if credit_on_finish:
		_credit_seed()
	_complete_harvest_animation()

func has_active_harvest_animations() -> bool:
	return _active_harvest_animation_count > 0

func _complete_harvest_animation() -> void:
	_active_harvest_animation_count = maxi(0, _active_harvest_animation_count - 1)
	if _active_harvest_animation_count == 0:
		harvest_animations_finished.emit()

func _credit_seed() -> void:
	var scene: Node = get_tree().current_scene
	var progression_node: Node = scene.get_node_or_null("progression") if scene != null else null
	if progression_node != null and progression_node.has_method("update_seeds"):
		progression_node.call("update_seeds", 1)
		Sfx.play_sound(&"bag")
