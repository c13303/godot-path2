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
	if not bool(crowd.call(&"set_agent_motion_limits", first, 30.0, 300.0, 300.0)):
		_fail("per-agent generic motion limits failed")
		return
	moved_position = crowd.call(&"get_agent_position", first) as Vector2
	var nearby: PackedInt64Array = crowd.call(
		&"query_agents_in_circle", moved_position, 0.1, -1, 0
	) as PackedInt64Array
	if nearby.find(first) < 0:
		_fail("generic circle query omitted an overlapping agent")
		return
	var moved_cell: Vector2i = Vector2i(
		int(floor(moved_position.x / 10.0)), int(floor(moved_position.y / 10.0))
	)
	var cell_agents: PackedInt64Array = crowd.call(
		&"get_agents_in_navigation_cell", navigation, moved_cell
	) as PackedInt64Array
	if cell_agents.find(first) < 0:
		_fail("generic navigation-cell query omitted an agent")
		return

	crowd.call(&"set_terrain_speed_cell", Vector2i(1, 0), 0.5, 3)
	crowd.call(
		&"set_terrain_speed_cells",
		PackedVector2Array([Vector2(2, 0)]), PackedFloat64Array([0.75]), 3
	)
	crowd.call(&"clear_terrain_speed_cell", Vector2i(1, 0), 3)
	crowd.call(
		&"clear_terrain_speed_cells", PackedVector2Array([Vector2(2, 0)]), 3
	)
	crowd.call(&"clear_terrain_speed_channel", 3)

	if not bool(crowd.call(&"set_agent_position", second, Vector2(25.0, 15.0), true)):
		_fail("generic agent teleport failed")
		return
	var obstacle: int = int(crowd.call(
		&"create_static_obstacle", Vector2(25.0, 15.0), 3.0, 1.0
	))
	if obstacle <= 0 or int(crowd.call(&"get_static_obstacle_count")) != 1:
		_fail("generic static-obstacle handle creation failed")
		return
	crowd.call(&"step", 0.05)
	var depenetrated: Vector2 = crowd.call(&"get_agent_position", second) as Vector2
	if depenetrated.distance_to(Vector2(25.0, 15.0)) < 4.99:
		_fail("generic static-obstacle depenetration failed")
		return
	if not bool(crowd.call(
		&"update_static_obstacle", obstacle, Vector2(35.0, 15.0), 3.0, 2.0
	)) or not bool(crowd.call(&"remove_static_obstacle", obstacle)):
		_fail("generic static-obstacle update/removal failed")
		return

	var directional_field: int = int(crowd.call(
		&"create_directional_motion_field", Vector2.ZERO, 10.0, 20.0,
		PackedVector2Array([Vector2(0, 1)]), PackedVector2Array([Vector2.RIGHT]),
		Vector2.ZERO, 0.0
	))
	crowd.call(&"set_agent_position", second, Vector2(5.0, 15.0), true)
	if directional_field <= 0 or not bool(crowd.call(
		&"follow_directional_motion_field", second, directional_field
	)):
		_fail("generic directional-motion field assignment failed")
		return
	var directional_before: Vector2 = crowd.call(&"get_agent_position", second) as Vector2
	crowd.call(&"step", 0.1)
	var directional_after: Vector2 = crowd.call(&"get_agent_position", second) as Vector2
	var directional_diagnostics: Dictionary = crowd.call(
		&"get_agent_diagnostics", second
	) as Dictionary
	if directional_after.x <= directional_before.x \
			or int(directional_diagnostics.get("navigation_source", -1)) != 4:
		_fail("generic directional-motion field did not drive the agent")
		return
	if not bool(crowd.call(
		&"update_directional_motion_field", directional_field,
		Vector2.ZERO, 10.0, 20.0,
		PackedVector2Array([Vector2(0, 1)]), PackedVector2Array([Vector2.LEFT]),
		Vector2.ZERO, 0.0
	)) or not bool(crowd.call(&"remove_directional_motion_field", directional_field)):
		_fail("generic directional-motion field update/removal failed")
		return
	if bool(crowd.call(&"follow_directional_motion_field", second, directional_field)):
		_fail("stale directional-motion field handle remained usable")
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
