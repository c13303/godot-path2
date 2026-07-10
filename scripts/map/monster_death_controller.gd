extends RefCounted
class_name MonsterDeathController

# Owns monster death flow: death-drop animation/crediting and delegating
# manager-owned registry cleanup in the original order.

const MONSTER_DEATH_DROP_SEED: StringName = &"seed"
const MONSTER_DEATH_DROP_GEM: StringName = &"gem"

var _manager: BuildingManager


func setup(manager: BuildingManager) -> void:
	_manager = manager


func remove_dead_monster(agent: Node2D, _legacy_spawn_visual: bool = true) -> void:
	if not is_instance_valid(agent):
		return
	var is_client: bool = agent.is_in_group("clients")
	var is_merchant: bool = agent.is_in_group("merchants")
	var awards_monster_drop: bool = agent.is_in_group("monsters") and not is_client and not is_merchant
	var death_position: Vector2 = agent.global_position
	if awards_monster_drop:
		_spawn_monster_death_drop(death_position)
	var nav_id: int = int(agent.get("nav_id"))
	_manager._clear_removed_agent_state(nav_id)
	_manager._unregister_nav_agent(nav_id)
	_manager._unregister_desire_agent(agent)
	agent.remove_from_group("monsters")
	agent.remove_from_group("clients")
	agent.remove_from_group("merchants")
	agent.queue_free()
	if is_merchant:
		_manager._on_removed_merchant_agent(agent)


func _spawn_monster_death_drop(world_position: Vector2) -> void:
	var seed_chance_percent: int = _manager._monster_death_drop_seed_chance_percent()
	var seed_chance: float = float(clampi(seed_chance_percent, 0, 100)) / 100.0
	var drop_type: StringName = MONSTER_DEATH_DROP_SEED if randf() < seed_chance else MONSTER_DEATH_DROP_GEM
	var scene: Node = _manager.get_tree().current_scene
	var icon: Node = null
	var animate_method: String = ""
	if scene != null:
		if drop_type == MONSTER_DEATH_DROP_SEED:
			icon = scene.get_node_or_null("GameUI/currenciesUI/seedIcon")
			animate_method = "animate_seed_harvest"
		else:
			icon = scene.get_node_or_null("GameUI/currenciesUI/gemIcon")
			animate_method = "animate_gem_harvest"
	if icon != null and icon.has_method(animate_method):
		var animation_started: bool = bool(icon.call(animate_method, world_position))
		if animation_started:
			if drop_type == MONSTER_DEATH_DROP_GEM:
				Sfx.play_sound(&"gem")
			return
	_credit_monster_death_drop(drop_type)


func _credit_monster_death_drop(drop_type: StringName) -> void:
	var scene: Node = _manager.get_tree().current_scene
	var progression_node: Node = scene.get_node_or_null("progression") if scene != null else null
	if progression_node == null:
		return
	if drop_type == MONSTER_DEATH_DROP_SEED:
		if progression_node.has_method("update_seeds"):
			progression_node.call("update_seeds", 1)
	elif drop_type == MONSTER_DEATH_DROP_GEM:
		if progression_node.has_method("update_gems"):
			progression_node.call("update_gems", 1)
