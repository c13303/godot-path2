extends Label

var hover_cell_text := ""

func _process(delta: float) -> void:
	var sb := ""
	sb += "FPS: %d\n" % Engine.get_frames_per_second()
	sb += "Agents: %d\n" % get_tree().get_nodes_in_group("main_chars").size()
	if hover_cell_text != "":
		sb += hover_cell_text
	text = sb

func set_hover_cell_text(t: String) -> void:
	hover_cell_text = t
