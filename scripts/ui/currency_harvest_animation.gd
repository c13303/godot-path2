extends RefCounted
class_name CurrencyHarvestAnimation

const DEFAULT_FLIGHT_SIZE: Vector2 = Vector2(28.0, 28.0)
const BASE_FLIGHT_DURATION: float = 0.72


static func animate_harvest(
	icon: TextureRect,
	world_position: Vector2,
	sequence_index: int,
	delay_between_icons: float,
	animation_speed: float,
	curve_strength: float,
	credit_callback: Callable,
	on_launch: Callable = Callable(),
	credit_on_finish: bool = true,
	stagger_seconds: float = -1.0,
	finished_callback: Callable = Callable()
) -> bool:
	if not is_instance_valid(icon) or icon.texture == null:
		return false
	var icon_parent: Node = icon.get_parent()
	if icon_parent == null:
		return false
	var game_ui: CanvasLayer = icon_parent.get_parent() as CanvasLayer
	if game_ui == null:
		return false
	var per_icon_delay: float = delay_between_icons if stagger_seconds < 0.0 else stagger_seconds
	var start_delay: float = float(sequence_index) * per_icon_delay
	if start_delay <= 0.0:
		_start_flight(icon, game_ui, world_position, animation_speed, curve_strength, credit_callback, on_launch, credit_on_finish, finished_callback)
		return true
	var delay_tween: Tween = icon.create_tween()
	delay_tween.tween_interval(start_delay)
	delay_tween.tween_callback(func() -> void:
		_start_flight(icon, game_ui, world_position, animation_speed, curve_strength, credit_callback, on_launch, credit_on_finish, finished_callback)
	)
	return true


static func _start_flight(
	icon: TextureRect,
	game_ui: CanvasLayer,
	world_position: Vector2,
	animation_speed: float,
	curve_strength: float,
	credit_callback: Callable,
	on_launch: Callable,
	credit_on_finish: bool,
	finished_callback: Callable
) -> void:
	if on_launch.is_valid():
		on_launch.call()
	if not is_instance_valid(icon) or not is_instance_valid(game_ui) or icon.texture == null:
		_credit(credit_callback, credit_on_finish)
		_complete(finished_callback)
		return
	var flying_sprite: TextureRect = TextureRect.new()
	flying_sprite.texture = icon.texture
	flying_sprite.custom_minimum_size = DEFAULT_FLIGHT_SIZE
	flying_sprite.size = DEFAULT_FLIGHT_SIZE
	flying_sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	flying_sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	flying_sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
	flying_sprite.pivot_offset = DEFAULT_FLIGHT_SIZE * 0.5
	game_ui.add_child(flying_sprite)

	var start_position: Vector2 = icon.get_viewport().get_canvas_transform() * world_position
	var target_rect: Rect2 = icon.get_global_rect()
	var end_position: Vector2 = target_rect.get_center() if icon.visible else target_rect.position
	var distance: float = start_position.distance_to(end_position)
	var base_arc_height: float = clampf(distance * 0.22, 70.0, 180.0)
	var arc_height: float = base_arc_height * curve_strength
	var curve_position: Vector2 = (start_position + end_position) * 0.5 + Vector2(0.0, -arc_height)
	var safe_animation_speed: float = maxf(animation_speed, 0.001)
	var flight_duration: float = BASE_FLIGHT_DURATION / safe_animation_speed
	flying_sprite.position = start_position - DEFAULT_FLIGHT_SIZE * 0.5
	flying_sprite.scale = Vector2(0.45, 0.45)

	var flight_tween: Tween = icon.create_tween()
	flight_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	flight_tween.tween_method(
		func(progress: float) -> void:
			_update_flight(progress, flying_sprite, start_position, curve_position, end_position),
		0.0,
		1.0,
		flight_duration
	)
	flight_tween.parallel().tween_property(flying_sprite, "scale", Vector2.ONE, 0.18 / safe_animation_speed)
	flight_tween.parallel().tween_property(flying_sprite, "rotation", TAU, flight_duration)
	flight_tween.tween_callback(func() -> void:
		_finish_flight(flying_sprite, credit_callback, credit_on_finish, finished_callback)
	)


static func _update_flight(
	progress: float,
	flying_sprite: TextureRect,
	start_position: Vector2,
	curve_position: Vector2,
	end_position: Vector2
) -> void:
	if not is_instance_valid(flying_sprite):
		return
	var inverse_progress: float = 1.0 - progress
	var curved_position: Vector2 = (
		inverse_progress * inverse_progress * start_position
		+ 2.0 * inverse_progress * progress * curve_position
		+ progress * progress * end_position
	)
	flying_sprite.position = curved_position - DEFAULT_FLIGHT_SIZE * 0.5


static func _finish_flight(
	flying_sprite: TextureRect,
	credit_callback: Callable,
	credit_on_finish: bool,
	finished_callback: Callable
) -> void:
	if is_instance_valid(flying_sprite):
		flying_sprite.queue_free()
	_credit(credit_callback, credit_on_finish)
	_complete(finished_callback)


static func _credit(credit_callback: Callable, credit_on_finish: bool) -> void:
	if credit_on_finish and credit_callback.is_valid():
		credit_callback.call()


static func _complete(finished_callback: Callable) -> void:
	if finished_callback.is_valid():
		finished_callback.call()
