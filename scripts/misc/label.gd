extends Label

const REFRESH_INTERVAL: float = 0.25

var hover_cell_text: String = ""
## Master gate: driven by cpp_debug_options.debug_enabled. When off, the label is
## hidden and processing is disabled so nothing is computed.
var _enabled: bool = false
var _refresh_elapsed: float = REFRESH_INTERVAL
var _agent_tracker: AgentCellTracker = null
var _debug_agent_count_refreshes: int = 0
var _debug_scene_group_count_scans: int = 0

func _ready() -> void:
	visibility_changed.connect(_on_visibility_changed)
	set_process(false)


func _process(delta: float) -> void:
	if not _enabled:
		return
	_refresh_elapsed += delta
	if _refresh_elapsed < REFRESH_INTERVAL:
		return
	_refresh_elapsed = 0.0
	var sb: String = ""
	sb += "FPS: %d\n" % Engine.get_frames_per_second()
	sb += "Agents: %d\n" % _registered_agent_count()
	if hover_cell_text != "":
		sb += hover_cell_text
	text = sb
	_debug_agent_count_refreshes += 1

func set_enabled(value: bool) -> void:
	_enabled = value
	visible = value
	set_process(value and is_visible_in_tree())
	_refresh_elapsed = REFRESH_INTERVAL
	if not value:
		text = ""

func set_hover_cell_text(t: String) -> void:
	hover_cell_text = t


func _on_visibility_changed() -> void:
	set_process(_enabled and is_visible_in_tree())


func _registered_agent_count() -> int:
	if _agent_tracker == null:
		var scene: Node = get_tree().current_scene
		var manager: Node = scene.get_node_or_null("Map/BuildingManager") if scene != null else null
		if manager != null and manager.has_method("get_agent_cell_tracker"):
			_agent_tracker = manager.call("get_agent_cell_tracker") as AgentCellTracker
	if _agent_tracker != null:
		return _agent_tracker.registered_count()
	# Startup-only compatibility fallback. It remains throttled with the label refresh.
	var seen: Dictionary = {}
	var groups: Array[StringName] = [&"main_chars", &"monsters", &"clients", &"merchants", &"player"]
	for group_name: StringName in groups:
		for node: Node in get_tree().get_nodes_in_group(group_name):
			seen[node.get_instance_id()] = true
	_debug_scene_group_count_scans += 1
	return seen.size()


func debug_stats() -> Dictionary:
	return {
		"debug_agent_count_refreshes": _debug_agent_count_refreshes,
		"scene_group_count_scans": _debug_scene_group_count_scans,
	}
