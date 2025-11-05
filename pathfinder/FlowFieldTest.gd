extends Node

func _ready():
	var ff = FlowField.new()
	add_child(ff)
	ff.set_process(true)
	print("Starting flowfield build...")
	ff.rebuild_async(Vector2(100, 100))
