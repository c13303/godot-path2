extends TextureRect

@export_group("Gem Harvest Animation")
@export_range(0.0, 1.0, 0.01, "suffix:s") var delay_between_gems: float = 0.06
@export_range(0.1, 5.0, 0.05, "or_greater", "suffix:x") var animation_speed: float = 1.0
@export_range(0.0, 5.0, 0.05, "or_greater", "suffix:x") var curve_strength: float = 1.0


func animate_gem_harvest(
	world_position: Vector2,
	sequence_index: int = 0,
	stagger_seconds: float = -1.0,
	finished_callback: Callable = Callable()
) -> bool:
	return CurrencyHarvestAnimation.animate_harvest(
		self,
		world_position,
		sequence_index,
		delay_between_gems,
		animation_speed,
		curve_strength,
		Callable(self, "_credit_gem"),
		Callable(),
		true,
		stagger_seconds,
		finished_callback
	)


func _credit_gem() -> void:
	var scene: Node = get_tree().current_scene
	var progression_node: Node = scene.get_node_or_null("progression") if scene != null else null
	if progression_node != null and progression_node.has_method("update_gems"):
		progression_node.call("update_gems", 1)
		Sfx.play_sound(&"bag")
