extends RefCounted
class_name AgentSuspendService

# Owns temporary agent suspension/resume shared by hazards that briefly take
# control of movement, while BuildingManager keeps the underlying registries.

const IDLE_GROUP: int = 0
const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)
const SPAWNER_KIND_CLIENT: StringName = &"client"

var _manager: Node


func setup(manager: Node) -> void:
	_manager = manager


func suspend_agent_for_drowning(nav_id: int) -> void:
	_detach_agent_navigation(nav_id)
	_entry_path_agents().erase(nav_id)
	_manager.call("_erase_astar_in_agent", nav_id)
	_manager.call("_erase_eating_agent", nav_id)
	_escaping_agents().erase(nav_id)
	_client_counter_agents().erase(nav_id)


func resume_agent_after_drowning(nav_id: int, agent: Node2D, resume_state: Dictionary) -> void:
	resume_agent_after_turret_eating(nav_id, agent, resume_state)


func capture_agent_resume_state(nav_id: int, agent: Node2D) -> Dictionary:
	var entry_path_agents: Dictionary = _entry_path_agents()
	if entry_path_agents.has(nav_id):
		return {
			"kind": "entry",
			"data": (entry_path_agents[nav_id] as Dictionary).duplicate(),
		}
	var astar_in_agents: Dictionary = _astar_in_agents()
	if astar_in_agents.has(nav_id):
		return {
			"kind": "astar",
			"data": (astar_in_agents[nav_id] as Dictionary).duplicate(),
		}
	var escaping_agents: Dictionary = _escaping_agents()
	if escaping_agents.has(nav_id):
		return {
			"kind": "escape",
			"data": (escaping_agents[nav_id] as Dictionary).duplicate(),
		}
	var client_counter_agents: Dictionary = _client_counter_agents()
	if client_counter_agents.has(nav_id):
		return {
			"kind": "client_counter",
			"data": (client_counter_agents[nav_id] as Dictionary).duplicate(),
		}
	var spawner_cell: Vector2i = INVALID_CELL
	if agent.has_meta("spawner_cell"):
		spawner_cell = agent.get_meta("spawner_cell") as Vector2i
	var garden_id: int = 0
	if agent.has_meta("garden_id"):
		garden_id = int(agent.get_meta("garden_id"))
	return {
		"kind": "retarget",
		"spawner_cell": spawner_cell,
		"garden_id": garden_id,
	}


func suspend_agent_for_turret_eating(nav_id: int) -> void:
	_detach_agent_navigation(nav_id)
	_entry_path_agents().erase(nav_id)
	_manager.call("_erase_astar_in_agent", nav_id)
	_escaping_agents().erase(nav_id)
	_client_counter_agents().erase(nav_id)


func resume_agent_after_turret_eating(nav_id: int, agent: Node2D, resume_state: Dictionary) -> void:
	var kind: String = str(resume_state.get("kind", "retarget"))
	var data: Dictionary = resume_state.get("data", {}) as Dictionary
	if kind == "entry":
		if _resume_agent_entry_flow(nav_id, agent, data):
			_entry_path_agents()[nav_id] = data
			_manager.call("_erase_astar_in_agent", nav_id)
			_escaping_agents().erase(nav_id)
			if agent.has_method("start_flow_in"):
				agent.call("start_flow_in")
			return
	elif kind == "astar":
		if _resume_agent_path(nav_id, agent, data):
			_entry_path_agents().erase(nav_id)
			_manager.call("_set_astar_in_agent", nav_id, data)
			_escaping_agents().erase(nav_id)
			if agent.has_method("start_astar_in"):
				agent.call("start_astar_in")
			return
	elif kind == "escape":
		var escape_result: Variant = _manager.call("_assign_agent_to_escape", agent)
		if bool(escape_result):
			return
	elif kind == "client_counter":
		if _resume_agent_path(nav_id, agent, data):
			_client_counter_agents()[nav_id] = data
			_entry_path_agents().erase(nav_id)
			_manager.call("_erase_astar_in_agent", nav_id)
			_escaping_agents().erase(nav_id)
			if agent.has_method("start_astar_in"):
				agent.call("start_astar_in")
			return

	var spawner_cell: Vector2i = resume_state.get("spawner_cell", INVALID_CELL) as Vector2i
	if spawner_cell == INVALID_CELL and agent.has_meta("spawner_cell"):
		spawner_cell = agent.get_meta("spawner_cell") as Vector2i
	var agent_kind: StringName = StringName(_manager.call("_agent_kind", agent))
	if agent_kind == SPAWNER_KIND_CLIENT:
		if not _retarget_agent_or_escape(agent, spawner_cell) and agent.has_method("start_waiting_new_status"):
			agent.call("start_waiting_new_status")
		return
	if not _retarget_agent_or_escape(agent, spawner_cell) and agent.has_method("start_waiting_new_status"):
		agent.call("start_waiting_new_status")


func _resume_agent_entry_flow(nav_id: int, agent: Node2D, data: Dictionary) -> bool:
	var agent_manager: Node = _agent_manager()
	if agent_manager == null or not agent_manager.has_method("assign_agent"):
		return false
	var plant_group: int = int(data.get("plant_group", -1))
	if plant_group <= IDLE_GROUP:
		return false
	if agent_manager.has_method("detach_agent_path"):
		agent_manager.call("detach_agent_path", nav_id)
	agent_manager.call("assign_agent", agent, plant_group)
	return true


func _resume_agent_path(nav_id: int, agent: Node2D, data: Dictionary) -> bool:
	var agent_manager: Node = _agent_manager()
	if agent_manager == null or not agent_manager.has_method("assign_agent_path"):
		return false
	var path_world: PackedVector2Array = data.get("path_world", PackedVector2Array()) as PackedVector2Array
	if path_world.is_empty():
		return false
	if agent_manager.has_method("detach_agent_flow"):
		agent_manager.call("detach_agent_flow", nav_id)
	if agent_manager.has_method("detach_agent_path"):
		agent_manager.call("detach_agent_path", nav_id)
	data["node"] = agent
	agent_manager.call("assign_agent_path", nav_id, path_world)
	return true


func _detach_agent_navigation(nav_id: int) -> void:
	var agent_manager: Node = _agent_manager()
	if agent_manager and agent_manager.has_method("detach_agent_flow"):
		agent_manager.call("detach_agent_flow", nav_id)
	if agent_manager and agent_manager.has_method("detach_agent_path"):
		agent_manager.call("detach_agent_path", nav_id)


func _retarget_agent_or_escape(agent: Node2D, spawner_cell: Vector2i) -> bool:
	var result: Variant = _manager.call("_retarget_agent_or_escape", agent, spawner_cell)
	return bool(result)


func _agent_manager() -> Node:
	if _manager == null:
		return null
	return _manager.get("agent_manager") as Node


func _entry_path_agents() -> Dictionary:
	return _manager.get("_entry_path_agents") as Dictionary


func _astar_in_agents() -> Dictionary:
	return _manager.get("_astar_in_agents") as Dictionary


func _escaping_agents() -> Dictionary:
	return _manager.get("_escaping_agents") as Dictionary


func _client_counter_agents() -> Dictionary:
	return _manager.get("_client_counter_agents") as Dictionary
