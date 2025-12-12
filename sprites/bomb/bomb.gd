extends Node


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	var t := Timer.new()
	t.wait_time = 1.0
	t.one_shot = true
	add_child(t)
	t.start()
	t.timeout.connect(queue_free)


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta: float) -> void:
	pass
