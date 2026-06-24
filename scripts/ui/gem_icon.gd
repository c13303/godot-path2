extends TextureRect

const GEM_FLIGHT_SIZE: Vector2 = Vector2(28.0, 28.0)
const BASE_FLIGHT_DURATION: float = 0.72

@export_group("Gem Harvest Animation")
@export_range(0.0, 1.0, 0.01, "suffix:s") var delay_between_gems: float = 0.06
@export_range(0.1, 5.0, 0.05, "or_greater", "suffix:x") var animation_speed: float = 1.0
@export_range(0.0, 5.0, 0.05, "or_greater", "suffix:x") var curve_strength: float = 1.0


func animate_gem_harvest(world_position: Vector2, sequence_index: int = 0) -> bool:
	if texture == null:
		return false
	var game_ui: CanvasLayer = get_parent().get_parent() as CanvasLayer
	if game_ui == null:
		return false
	var start_delay: float = float(sequence_index) * delay_between_gems
	if start_delay <= 0.0:
		_start_gem_flight(world_position)
		return true
	var delay_tween: Tween = create_tween()
	delay_tween.tween_interval(start_delay)
	delay_tween.tween_callback(Callable(self, "_start_gem_flight").bind(world_position))
	return true


func _start_gem_flight(world_position: Vector2) -> void:
	var game_ui: CanvasLayer = get_parent().get_parent() as CanvasLayer
	if game_ui == null or texture == null:
		_credit_gem()
		return
	var gem_sprite: TextureRect = TextureRect.new()
	gem_sprite.texture = texture
	gem_sprite.custom_minimum_size = GEM_FLIGHT_SIZE
	gem_sprite.size = GEM_FLIGHT_SIZE
	gem_sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	gem_sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	gem_sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gem_sprite.pivot_offset = GEM_FLIGHT_SIZE * 0.5
	game_ui.add_child(gem_sprite)

	var start_position: Vector2 = get_viewport().get_canvas_transform() * world_position
	var end_position: Vector2 = get_global_rect().get_center()
	var distance: float = start_position.distance_to(end_position)
	var base_arc_height: float = clampf(distance * 0.22, 70.0, 180.0)
	var arc_height: float = base_arc_height * curve_strength
	var curve_position: Vector2 = (start_position + end_position) * 0.5 + Vector2(0.0, -arc_height)
	var flight_duration: float = BASE_FLIGHT_DURATION / animation_speed
	gem_sprite.position = start_position - GEM_FLIGHT_SIZE * 0.5
	gem_sprite.scale = Vector2(0.45, 0.45)

	var flight_tween: Tween = create_tween()
	flight_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	flight_tween.tween_method(
		Callable(self, "_update_gem_flight").bind(gem_sprite, start_position, curve_position, end_position),
		0.0,
		1.0,
		flight_duration
	)
	flight_tween.parallel().tween_property(gem_sprite, "scale", Vector2.ONE, 0.18 / animation_speed)
	flight_tween.parallel().tween_property(gem_sprite, "rotation", TAU, flight_duration)
	flight_tween.tween_callback(Callable(self, "_finish_gem_flight").bind(gem_sprite))


func _update_gem_flight(
	progress: float,
	gem_sprite: TextureRect,
	start_position: Vector2,
	curve_position: Vector2,
	end_position: Vector2
) -> void:
	if not is_instance_valid(gem_sprite):
		return
	var inverse_progress: float = 1.0 - progress
	var curved_position: Vector2 = (
		inverse_progress * inverse_progress * start_position
		+ 2.0 * inverse_progress * progress * curve_position
		+ progress * progress * end_position
	)
	gem_sprite.position = curved_position - GEM_FLIGHT_SIZE * 0.5


func _finish_gem_flight(gem_sprite: TextureRect) -> void:
	if is_instance_valid(gem_sprite):
		gem_sprite.queue_free()
	_credit_gem()


func _credit_gem() -> void:
	var scene: Node = get_tree().current_scene
	var progression_node: Node = scene.get_node_or_null("progression") if scene != null else null
	if progression_node != null and progression_node.has_method("update_gems"):
		progression_node.call("update_gems", 1)
