extends Node

var ff = FlowField.new()

func _ready():	
	var rect = Rect2i(Vector2i(10, 20), Vector2i(5, 3))
	var arr = ff.make_dist_array(rect)
	arr = ff.set_dist(Vector2i(11, 21), 123, rect, arr)
	print(ff.get_dist(Vector2i(11, 21), rect, arr)) # doit afficher 123

func _exit_tree():
	ff.queue_free()