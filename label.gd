extends Label

var t := 0.0

func _process(delta: float) -> void:
	t += delta
	if t < 1.0:
		return
	t = 0.0

	text = "FPS: %d\n" % Engine.get_frames_per_second()
	text += "Agents: %d" % get_tree().get_nodes_in_group("main_chars").size()
