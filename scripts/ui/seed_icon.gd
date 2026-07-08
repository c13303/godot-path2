extends TextureRect

signal harvest_animations_finished

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
	_active_harvest_animation_count += 1
	var started: bool = CurrencyHarvestAnimation.animate_harvest(
		self,
		world_position,
		sequence_index,
		delay_between_seeds,
		animation_speed,
		curve_strength,
		Callable(self, "_credit_seed"),
		Callable(self, "_launch_seed_harvest").bind(on_launch),
		credit_on_finish,
		stagger_seconds,
		Callable(self, "_complete_harvest_animation")
	)
	if not started:
		_complete_harvest_animation()
	return started


func _launch_seed_harvest(on_launch: Callable = Callable()) -> void:
	# The seed pops off the rose now: let the caller dry the source rose.
	if on_launch.is_valid():
		on_launch.call()
	Sfx.play_random_pop()

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
