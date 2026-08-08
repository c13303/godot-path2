extends SceneTree


func _initialize() -> void:
	var navigation: Node = ClassDB.instantiate(&"NavigationWorld2D") as Node
	var crowd: Node = ClassDB.instantiate(&"CrowdWorld2D") as Node
	if navigation == null or crowd == null:
		_fail("generic navigation or crowd class is not registered")
		return
	root.add_child(navigation)
	root.add_child(crowd)
	crowd.set(&"automatic_step", false)

	var walkable: PackedVector2Array = PackedVector2Array()
	for y: int in range(2):
		for x: int in range(6):
			walkable.append(Vector2(x, y))
	if not bool(navigation.call(
		&"configure_grid", Rect2i(0, 0, 6, 2), 10.0, Vector2.ZERO,
		walkable, PackedVector2Array()
	)):
		_fail("crowd fixture grid configuration failed")
		return
	if not bool(navigation.call(&"build_flow_to_cell", Vector2i(5, 0))):
		_fail("crowd fixture flow build failed")
		return
	if not bool(crowd.call(&"use_navigation_flow", navigation)):
		_fail("crowd did not accept the navigation flow")
		return

	var first: int = int(crowd.call(&"add_agent", Vector2(5.0, 5.0), 2.0, 30.0, 8.0, 0.5))
	var second: int = int(crowd.call(&"add_agent", Vector2(5.0, 15.0), 2.0, 30.0, 8.0, 0.5))
	if first <= 0 or second <= 0:
		_fail("generic crowd agent creation failed")
		return
	if not bool(crowd.call(&"follow_flow", first)) or not bool(crowd.call(&"follow_flow", second)):
		_fail("generic agents did not attach to the shared flow")
		return
	for _index: int in range(10):
		crowd.call(&"step", 0.05)
	var moved_position: Vector2 = crowd.call(&"get_agent_position", first) as Vector2
	if moved_position.x <= 5.0:
		_fail("flow-driven generic agent did not move")
		return

	var before_impulse: Vector2 = crowd.call(&"get_agent_position", second) as Vector2
	crowd.call(&"stop_navigation", second)
	crowd.call(&"apply_impulse", second, Vector2(20.0, 0.0), 0.0, 0.0, 0.0, true, 10)
	crowd.call(&"step", 0.1)
	var after_impulse: Vector2 = crowd.call(&"get_agent_position", second) as Vector2
	if after_impulse.x <= before_impulse.x:
		_fail("generic impulse did not alter motion")
		return

	var handles: PackedInt64Array = crowd.call(&"get_agent_handles") as PackedInt64Array
	var positions: PackedVector2Array = crowd.call(&"get_agent_positions") as PackedVector2Array
	if handles.size() != 2 or positions.size() != 2:
		_fail("batched generic crowd state has an invalid shape")
		return

	crowd.queue_free()
	navigation.queue_free()
	print("CrowdWorld2D smoke test passed")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
