extends MultiMeshInstance2D

const MAX_INSTANCES := 4000
const FADE_PER_SECOND := 0.01
const BLOOD_INITIAL_FADE := 1.0

var next_index := 0
var active := []

func _ready() -> void:
	if multimesh == null:
		multimesh = MultiMesh.new()

	multimesh.instance_count = 0
	multimesh.use_custom_data = true
	multimesh.instance_count = MAX_INSTANCES
	multimesh.visible_instance_count = 0
	set_process(true)

func spawn_blood(pos: Vector2) -> void:
	var idx := next_index % multimesh.instance_count

	multimesh.set_instance_transform_2d(
		idx,
		Transform2D(randf() * TAU, pos)
	)

	multimesh.set_instance_custom_data(
		idx,
		Color(float(randi() % 3), BLOOD_INITIAL_FADE, 0.0, 0.0)
	)

	if not active.has(idx):
		active.append(idx)

	next_index += 1
	multimesh.visible_instance_count = min(next_index, multimesh.instance_count)

func _process(delta: float) -> void:
	for j in range(active.size() - 1, -1, -1):
		var idx: int = active[j]
		var d: Color = multimesh.get_instance_custom_data(idx)
		d.g -= delta * FADE_PER_SECOND
		if d.g <= 0.0:
			d.g = 0.0
			active.remove_at(j)
		multimesh.set_instance_custom_data(idx, d)
