extends RefCounted
class_name MonsterDeathController

# Owns agent death flow: corpse burst, monster currency drops, and delegating
# manager-owned registry cleanup in the original order.

const MONSTER_DEATH_DROP_SEED: StringName = &"seed"
const MONSTER_DEATH_DROP_GEM: StringName = &"gem"

var _manager: BuildingManager


func setup(manager: BuildingManager) -> void:
	_manager = manager


func remove_dead_monster(agent: Node2D, spawn_death_effects: bool = true) -> void:
	if not is_instance_valid(agent):
		return
	var is_client: bool = agent.is_in_group("clients")
	var awards_monster_drop: bool = agent.is_in_group("monsters") and not is_client and not agent.is_in_group("merchants") and not agent.is_in_group("builders")
	var death_position: Vector2 = agent.global_position
	if spawn_death_effects:
		_manager.spawn_agent_death_burst(death_position)
	if spawn_death_effects and awards_monster_drop:
		_spawn_monster_death_drop(death_position)
	_remove_dead_agent_without_drop(agent)


func remove_dead_monster_with_forced_currency_drop(agent: Node2D, currency: StringName, landing_target: Vector2) -> void:
	if not is_instance_valid(agent):
		return
	var death_position: Vector2 = agent.global_position
	_manager.spawn_agent_death_burst(death_position)
	_manager.spawn_collectible_currency_toward(currency, death_position, landing_target)
	_remove_dead_agent_without_drop(agent)


func _spawn_monster_death_drop(world_position: Vector2) -> void:
	var seed_chance_percent: int = _manager.monster_death_drop_seed_chance_percent()
	var seed_chance: float = float(clampi(seed_chance_percent, 0, 100)) / 100.0
	var drop_type: StringName = MONSTER_DEATH_DROP_SEED if randf() < seed_chance else MONSTER_DEATH_DROP_GEM
	_manager.spawn_collectible_currency(drop_type, world_position)


func _remove_dead_agent_without_drop(agent: Node2D) -> void:
	var is_house_resident: bool = agent.is_in_group("house_residents")
	var nav_id: int = int(agent.get("nav_id"))
	_manager._clear_removed_agent_state(nav_id)
	_manager._unregister_nav_agent(nav_id)
	_manager._unregister_runtime_agent(agent)
	agent.remove_from_group("monsters")
	agent.remove_from_group("clients")
	agent.remove_from_group("merchants")
	agent.remove_from_group("builders")
	agent.remove_from_group("house_residents")
	agent.queue_free()
	# Route every house villager (merchant, builders) through the one generic removal handler.
	if is_house_resident:
		_manager.on_removed_house_resident_agent(agent)
