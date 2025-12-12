extends MultiMeshInstance2D

var blood := []

var i := 0

func spawn_blood(pos: Vector2):

	var mm = multimesh
	mm.set_instance_transform_2d(i, Transform2D(randf() * TAU, pos))
	mm.set_instance_custom_data(i, Color(float(randi() % 3), 0, 0, 0))
	i += 1
	blood.append({ "i": i, "alpha": 1.0 })
