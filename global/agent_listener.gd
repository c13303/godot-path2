extends Node

@export var debug_events: bool = false

const ANIM_E := "Walk_E"
const ANIM_W := "Walk_W"
const ANIM_S := "Walk_S"
const ANIM_N := "Walk_N"

func _ready() -> void:
	var mgr := get_parent()
	if not mgr:
		push_warning("AgentListener: no parent to connect to.")
		return
	if not mgr.has_signal("agent_event"):
		push_warning("AgentListener: parent has no agent_event signal.")
		return
	mgr.connect("agent_event", Callable(self, "_on_agent_event"))
	if debug_events:
		print("AgentListener: connected to agent_event")

func _on_agent_event(event_name: String, agent_id: int, payload: Dictionary) -> void:
	if debug_events:
		print("AgentListener event:", event_name, "agent:", agent_id, "payload:", payload)

	if event_name == "main_animation_update":
		_apply_anim_update(agent_id, payload)

var _last_dir_code: Dictionary = {}

func _apply_anim_update(agent_id: int, payload: Dictionary) -> void:
	var mgr := get_parent()
	if not mgr or not mgr.has_method("find_node_by_agent"):
		return
	var node: Node2D = mgr.find_node_by_agent(agent_id)
	if node == null:
		return
	var sprite: AnimatedSprite2D = node.get_node_or_null("LapinSprite2D")
	if sprite == null:
		return

	var code: int = int(payload.get("code", -1))
	var moving: bool = bool(payload.get("moving", false))
	if code >= 0:
		_last_dir_code[agent_id] = code
	else:
		code = int(_last_dir_code.get(agent_id, 2)) # default south

	if moving:
		match code:
			0: sprite.animation = ANIM_E
			1: sprite.animation = ANIM_W
			2: sprite.animation = ANIM_S
			3: sprite.animation = ANIM_N
			_: sprite.animation = ANIM_S
	else:
		match code:
			0: sprite.animation = "Idle_E"
			1: sprite.animation = "Idle_W"
			2: sprite.animation = "Idle_S"
			3: sprite.animation = "Idle_N"
			_: sprite.animation = "Idle_S"
	sprite.play()
