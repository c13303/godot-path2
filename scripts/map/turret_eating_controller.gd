extends RefCounted
class_name TurretEatingController

# Owns the "monster devours an eatable turret then chews for a beat" hazard:
# detecting an agent overlapping a turret cell, consuming the turret (debris + tile
# removal + sfx), and running the per-agent eating timer. Mirrors DrowningController:
# holds a back-reference to BuildingManager and delegates the shared agent suspend/
# capture/resume machinery (also used by drowning) plus the turret tile edits back
# to the manager rather than duplicating them.

const SPAWNER_KIND_CLIENT: StringName = &"client"
const SPAWNER_KIND_MERCHANT: StringName = &"merchant"
const SPAWNER_KIND_BUILDER: StringName = &"builder"

var _manager: BuildingManager
# nav_id -> turret-eating state (node, timer, resume_state).
var _turret_eating_agents: Dictionary = {}


func setup(manager: BuildingManager) -> void:
	_manager = manager


func is_eating(nav_id: int) -> bool:
	return _turret_eating_agents.has(nav_id)


func turret_eating_count() -> int:
	return _turret_eating_agents.size()


func clear_agent(nav_id: int) -> void:
	_turret_eating_agents.erase(nav_id)


# Single-agent turret-overlap check, invoked by AgentTileInteractionController when
# an agent (re)enters a relevant cell. Skip while garden-eating, turret-eating or
# drowning, then consume the turret: villagers crush every turret they walk over, while
# monsters only devour the ones whose TurretData allows monster eating.
# Sheep never reach this method (AgentTileInteractionController filters them out).
# Returns true when a turret was actually consumed.
func evaluate_agent(agent: Node2D) -> bool:
	if agent == null or not is_instance_valid(agent):
		return false
	var blocking_buildings: TileMapLayer = _manager.blocking_buildings
	if blocking_buildings == null:
		return false
	var nav_id: int = int(agent.get("nav_id"))
	if nav_id < 0:
		return false
	var eating_agents: Dictionary = _manager._eating_agents
	var drowning: DrowningController = _manager._drowning_controller
	if eating_agents.has(nav_id) or _turret_eating_agents.has(nav_id) or drowning.is_drowning(nav_id):
		return false
	var agent_cell: Vector2i = blocking_buildings.local_to_map(blocking_buildings.to_local(agent.global_position))
	var turret_data: TurretData = _turret_data_at_cell(agent_cell)
	if turret_data == null:
		return false
	var agent_kind: StringName = _manager._agent_kind(agent)
	if not _is_villager_kind(agent_kind) and not turret_data.eatable_by_monsters:
		return false
	return _consume_turret(agent, agent_cell, agent_kind)


# Villagers are the people agents: they crush placeables by walking over them rather than
# devouring them, so they take the instant-destroy path in _consume_turret.
func _is_villager_kind(agent_kind: StringName) -> bool:
	return agent_kind == SPAWNER_KIND_CLIENT or agent_kind == SPAWNER_KIND_MERCHANT or agent_kind == SPAWNER_KIND_BUILDER


func _consume_turret(agent: Node2D, turret_cell: Vector2i, agent_kind: StringName) -> bool:
	var nav_id: int = int(agent.get("nav_id"))
	if nav_id < 0:
		return false
	# Villagers crush and walk on: no eating pause, no suspend/resume machinery.
	if _is_villager_kind(agent_kind):
		_manager._leave_turret_debris(turret_cell)
		_manager._remove_turret_cell(turret_cell)
		Sfx.play_sound(&"crunsh")
		return true
	var eating_time: float = _manager._eating_time
	var resume_state: Dictionary = _manager._capture_agent_resume_state(nav_id, agent)
	_turret_eating_agents[nav_id] = {
		"node": agent,
		"timer": eating_time,
		"resume_state": resume_state,
	}
	_manager._suspend_agent_for_turret_eating(nav_id)
	_manager._leave_turret_debris(turret_cell)
	_manager._remove_turret_cell(turret_cell)
	Sfx.play_sound(&"crunsh")
	if agent.has_method("start_eating"):
		agent.call("start_eating", eating_time)
	return true


func _turret_data_at_cell(cell: Vector2i) -> TurretData:
	var building_objects: BuildingObjectManager = _manager.get_building_object_manager()
	if building_objects != null and building_objects.has_method("get_building"):
		var building_data: Dictionary = building_objects.call("get_building", cell) as Dictionary
		var item_id: String = str(building_data.get("item_id", ""))
		var turret_data: TurretData = ItemCatalog.get_turret_data(item_id)
		if turret_data != null:
			return turret_data
	if _manager.blocking_buildings == null or _manager.blocking_buildings.get_cell_source_id(cell) < 0:
		return null
	var atlas: Vector2i = _manager.blocking_buildings.get_cell_atlas_coords(cell)
	var fallback_item_id: String = ItemCatalog.get_placeable_id_for_tile(str(_manager.blocking_buildings.name), atlas)
	return ItemCatalog.get_turret_data(fallback_item_id)


func process_turret_eating_agents(delta: float) -> void:
	var finished: Array[int] = []
	for raw_nav_id: Variant in _turret_eating_agents.keys():
		var nav_id: int = int(raw_nav_id)
		if not _turret_eating_agents.has(nav_id):
			continue
		var data: Dictionary = _turret_eating_agents[nav_id] as Dictionary
		var timer: float = float(data.get("timer", 0.0)) - delta
		data["timer"] = timer
		_turret_eating_agents[nav_id] = data
		if timer <= 0.0:
			finished.append(nav_id)

	for nav_id: int in finished:
		var data: Dictionary = _turret_eating_agents.get(nav_id, {}) as Dictionary
		_turret_eating_agents.erase(nav_id)
		var raw_agent: Variant = data.get("node", null)
		if not is_instance_valid(raw_agent):
			continue
		var agent: Node2D = raw_agent as Node2D
		if agent == null:
			continue
		if agent.has_method("stop_eating"):
			agent.call("stop_eating")
		_manager.get_agent_cell_tracker().request_recheck(agent)
		var resume_state: Dictionary = data.get("resume_state", {}) as Dictionary
		_manager._resume_agent_after_turret_eating(nav_id, agent, resume_state)
