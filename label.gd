extends Label

var hover_cell_text := ""

func _process(_delta: float) -> void:
	var sb := ""
	sb += "FPS: %d\n" % Engine.get_frames_per_second()
	var agent_count := 0
	for group_name in ["main_chars", "monsters", "player"]:
		agent_count += get_tree().get_nodes_in_group(group_name).size()
	sb += "Agents: %d\n" % agent_count
	if hover_cell_text != "":
		sb += hover_cell_text
	text = sb

func set_hover_cell_text(t: String) -> void:
	hover_cell_text = t
