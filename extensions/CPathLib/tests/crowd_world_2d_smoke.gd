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

	var left_flow: int = int(navigation.call(&"create_flow_to_cell", Vector2i(0, 0)))
	var right_flow: int = int(navigation.call(&"create_flow_to_cell", Vector2i(5, 0)))
	if left_flow <= 0 or right_flow <= 0:
		_fail("generational flow creation failed")
		return
	if not bool(crowd.call(&"install_navigation_flow", navigation, left_flow)) \
			or not bool(crowd.call(&"install_navigation_flow", navigation, right_flow)):
		_fail("crowd did not install independent navigation flows")
		return

	var profile: int = int(crowd.call(
		&"create_profile", 2.0, 30.0, 300.0, 300.0, 0.0, 0.0, 2.0, 0, 1
	))
	var left_agent: int = int(crowd.call(&"add_agent_with_profile", Vector2(45.0, 5.0), profile))
	var right_agent: int = int(crowd.call(&"add_agent_with_profile", Vector2(15.0, 5.0), profile))
	var left_cohort: int = int(crowd.call(&"create_cohort"))
	var right_cohort: int = int(crowd.call(&"create_cohort"))
	if profile <= 0 or left_agent <= 0 or right_agent <= 0 \
			or left_cohort <= 0 or right_cohort <= 0:
		_fail("profile, agent, or cohort handle creation failed")
		return
	if not bool(crowd.call(&"assign_agent_to_cohort", left_agent, left_cohort)) \
			or not bool(crowd.call(&"assign_agent_to_cohort", right_agent, right_cohort)) \
			or not bool(crowd.call(&"assign_cohort_flow", left_cohort, left_flow)) \
			or not bool(crowd.call(&"assign_cohort_flow", right_cohort, right_flow)):
		_fail("cohort flow assignment failed")
		return
	if int(crowd.call(&"get_cohort_member_count", left_cohort)) != 1:
		_fail("cohort member accounting failed")
		return

	var left_before: Vector2 = crowd.call(&"get_agent_position", left_agent) as Vector2
	var right_before: Vector2 = crowd.call(&"get_agent_position", right_agent) as Vector2
	crowd.call(&"step", 0.1)
	var left_after: Vector2 = crowd.call(&"get_agent_position", left_agent) as Vector2
	var right_after: Vector2 = crowd.call(&"get_agent_position", right_agent) as Vector2
	if left_after.x >= left_before.x or right_after.x <= right_before.x:
		_fail("agents did not follow their independent cohort flows")
		return

	crowd.call(&"remove_agent", left_agent)
	crowd.call(&"remove_agent", right_agent)
	crowd.call(&"remove_cohort", left_cohort)
	crowd.call(&"remove_cohort", right_cohort)
	crowd.call(&"remove_profile", profile)
	crowd.call(&"remove_navigation_flow", left_flow)
	crowd.call(&"remove_navigation_flow", right_flow)
	navigation.call(&"release_flow", left_flow)
	navigation.call(&"release_flow", right_flow)

	crowd.queue_free()
	navigation.queue_free()
	print("CrowdWorld2D smoke test passed")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
