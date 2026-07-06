extends Node

@export var debug_events: bool = false

func _ready() -> void:
	var mgr := get_parent()
	if not mgr:
		push_warning("AgentListener: no parent to connect to.")
		return
	if not mgr.has_signal("agent_event"):
		push_warning("AgentListener: parent has no agent_event signal.")
		return
	mgr.connect("agent_event", Callable(self, "_on_agent_event"))
	if debug_events and CppDebugOptions.logs_enabled:
		print("AgentListener: connected to agent_event")

func _on_agent_event(event_name: String, agent_id: int, payload: Dictionary) -> void:
	if debug_events and CppDebugOptions.logs_enabled:
		print("AgentListener event:", event_name, "agent:", agent_id, "payload:", payload)

	match event_name:
		"propelled_state_update":
			_apply_propelled_state(agent_id, payload)

func _apply_propelled_state(agent_id: int, payload: Dictionary) -> void:
	var node := _get_agent_node(agent_id)
	if node == null:
		return
	_apply_propelled_payload(node, payload)

func _apply_propelled_payload(node: Node2D, payload: Dictionary) -> void:
	var propelled: bool = bool(payload.get("is_propelled", false))
	if node.has_method("set_propelled_state"):
		node.set_propelled_state(propelled)
	var controls_impaired: bool = bool(payload.get("controls_impaired", propelled))
	if node.has_method("set_control_impaired_state"):
		node.set_control_impaired_state(controls_impaired)
	if payload.has("velocity_len"):
		var vel: float = float(payload.get("velocity_len", 0.0))
		if node.has_method("set_velocity_len"):
			node.set_velocity_len(vel)

func _get_agent_node(agent_id: int) -> Node2D:
	var mgr := get_parent()
	if not mgr or not mgr.has_method("find_node_by_agent"):
		return null
	return mgr.find_node_by_agent(agent_id)
