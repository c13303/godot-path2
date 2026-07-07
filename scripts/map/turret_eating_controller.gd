extends RefCounted
class_name TurretEatingController

# Owns the "monster devours a turret then chews for a beat" hazard: detecting an
# agent overlapping a turret cell, consuming the turret (debris + tile removal +
# sfx), and running the per-agent eating timer. Mirrors DrowningController: holds a
# back-reference to BuildingManager and delegates the shared agent suspend/capture/
# resume machinery (also used by drowning) plus the turret tile edits back to the
# manager rather than duplicating them.

const SPAWNER_KIND_CLIENT: StringName = &"client"
const SPAWNER_KIND_MERCHANT: StringName = &"merchant"

var _manager: BuildingManager
# nav_id -> turret-eating state (node, timer, resume_state).
var _turret_eating_agents: Dictionary = {}


func setup(manager: BuildingManager) -> void:
	_manager = manager


func is_eating(nav_id: int) -> bool:
	return _turret_eating_agents.has(nav_id)


func turret_eating_count() -> int:
	return _turret_eating_agents.size()


func process_turret_overlaps() -> void:
	var blocking_buildings: TileMapLayer = _manager.blocking_buildings
	if blocking_buildings == null:
		return
	var eating_agents: Dictionary = _manager._eating_agents
	var drowning: DrowningController = _manager._drowning_controller
	var agent_groups: Array[String] = ["monsters", "clients", "merchants"]
	var checked_nav_ids: Dictionary = {}
	for group_name: String in agent_groups:
		for raw_node: Node in _manager.get_tree().get_nodes_in_group(group_name):
			var agent: Node2D = raw_node as Node2D
			if agent == null or not is_instance_valid(agent):
				continue
			var nav_id: int = int(agent.get("nav_id"))
			if nav_id < 0 or checked_nav_ids.has(nav_id) or eating_agents.has(nav_id) or _turret_eating_agents.has(nav_id) or drowning.is_drowning(nav_id):
				continue
			checked_nav_ids[nav_id] = true
			var agent_cell: Vector2i = blocking_buildings.local_to_map(blocking_buildings.to_local(agent.global_position))
			if not _manager._is_turret_cell(agent_cell):
				continue
			_consume_turret(agent, agent_cell)


func _consume_turret(agent: Node2D, turret_cell: Vector2i) -> void:
	var nav_id: int = int(agent.get("nav_id"))
	if nav_id < 0:
		return
	var agent_kind: StringName = _manager._agent_kind(agent)
	if agent_kind == SPAWNER_KIND_CLIENT or agent_kind == SPAWNER_KIND_MERCHANT:
		_manager._leave_turret_debris(turret_cell)
		_manager._remove_turret_cell(turret_cell)
		Sfx.play_sound(&"crunsh")
		return
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
		var resume_state: Dictionary = data.get("resume_state", {}) as Dictionary
		_manager._resume_agent_after_turret_eating(nav_id, agent, resume_state)
