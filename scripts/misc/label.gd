extends Label

var hover_cell_text := ""
## Master gate: driven by cpp_debug_options.debug_enabled. When off, the label is
## hidden and _process bails immediately so nothing is computed.
var _enabled := false

func _process(_delta: float) -> void:
	if not _enabled:
		return
	var sb := ""
	sb += "FPS: %d\n" % Engine.get_frames_per_second()
	# Mirror the groups the native agent manager registers (player, monsters,
	# clients, main_chars) plus merchants. Dedupe so an agent that lives in two
	# groups is only tallied once.
	var seen := {}
	for group_name in ["main_chars", "monsters", "clients", "merchants", "player"]:
		for node in get_tree().get_nodes_in_group(group_name):
			seen[node.get_instance_id()] = true
	sb += "Agents: %d\n" % seen.size()
	if hover_cell_text != "":
		sb += hover_cell_text
	text = sb

func set_enabled(value: bool) -> void:
	_enabled = value
	visible = value
	if not value:
		text = ""

func set_hover_cell_text(t: String) -> void:
	hover_cell_text = t
