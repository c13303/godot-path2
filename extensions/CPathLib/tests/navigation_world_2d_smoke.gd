extends SceneTree

var _navigation: Node
var _frames_waited: int = 0
var _async_flow_handle: int = 0
var _option_async_flow_handle: int = 0
var _completed_requests: int = 0


func _initialize() -> void:
	_navigation = ClassDB.instantiate(&"NavigationWorld2D") as Node
	if _navigation == null:
		_fail("NavigationWorld2D is not registered")
		return
	root.add_child(_navigation)
	_navigation.connect(&"flow_ready", _on_flow_ready)

	var walkable: PackedVector2Array = PackedVector2Array()
	for y: int in range(3):
		for x: int in range(3):
			walkable.append(Vector2(x, y))
	var sparse_configured: bool = bool(_navigation.call(
		&"configure_sparse_grid",
		walkable,
		PackedVector2Array()
	))
	if not sparse_configured:
		_fail("sparse grid configuration failed")
		return
	var sparse_path: PackedVector2Array = _navigation.call(
		&"find_path_cells", Vector2i(0, 0), Vector2i(2, 2)
	) as PackedVector2Array
	if sparse_path != PackedVector2Array([Vector2(0, 0), Vector2(1, 1), Vector2(2, 2)]):
		_fail("sparse-grid path result changed: %s" % sparse_path)
		return
	var configured: bool = bool(_navigation.call(
		&"configure_grid",
		Rect2i(0, 0, 3, 3),
		16.0,
		Vector2(100.0, -50.0),
		walkable,
		PackedVector2Array()
	))
	if not configured:
		_fail("raw grid configuration failed")
		return

	var path: PackedVector2Array = _navigation.call(
		&"find_path_cells", Vector2i(0, 0), Vector2i(2, 2)
	) as PackedVector2Array
	if path != PackedVector2Array([Vector2(0, 0), Vector2(1, 1), Vector2(2, 2)]):
		_fail("generic path result changed: %s" % path)
		return
	if not bool(_navigation.call(&"set_cell_traversal_cost", Vector2i(1, 1), 20.0)):
		_fail("generic traversal cost edit failed")
		return
	var weighted_path: PackedVector2Array = _navigation.call(
		&"find_path_cells", Vector2i(0, 0), Vector2i(2, 2)
	) as PackedVector2Array
	if weighted_path.size() < 3 or weighted_path[1] == Vector2(1, 1):
		_fail("generic weighted A* did not avoid the expensive cell")
		return
	_navigation.call(&"set_cell_traversal_cost", Vector2i(1, 1), 1.0)
	if not bool(_navigation.call(&"build_flow_to_cell", Vector2i(2, 2))):
		_fail("synchronous generic flow build failed")
		return
	var direction: Vector2 = _navigation.call(
		&"sample_latest_flow", Vector2(108.0, -42.0)
	) as Vector2
	if direction.distance_to(Vector2(1, 1).normalized()) > 0.0001:
		_fail("world-origin flow sampling changed: %s" % direction)
		return
	var area: int = int(_navigation.call(
		&"create_area",
		PackedVector2Array([Vector2(1, 1), Vector2(2, 1)]),
		PackedVector2Array([Vector2(2, 1)])
	))
	var portal: int = int(_navigation.call(
		&"create_portal",
		area,
		PackedVector2Array([Vector2(1, 1)]),
		PackedVector2Array([Vector2(0, 1)]),
		0,
		1
	))
	if area <= 0 or portal <= 0:
		_fail("generic area/portal creation failed")
		return
	var route: RefCounted = _navigation.call(
		&"plan_enter_area", area, Vector2i(0, 1), Vector2i(2, 1)
	) as RefCounted
	if route == null or int(route.call(&"get_status")) != 0:
		_fail("generic area enter route failed")
		return
	if int(route.call(&"get_segment_count")) != 3:
		_fail("generic area route did not expose three typed segments")
		return
	if not bool(_navigation.call(&"is_route_current", route)):
		_fail("fresh generic area route was reported stale")
		return

	var barrier_cells: PackedVector2Array = PackedVector2Array([
		Vector2(1, 0), Vector2(1, 1), Vector2(1, 2),
	])
	if not bool(_navigation.call(
		&"replace_blocker_channel", 1, barrier_cells, true, true
	)):
		_fail("blocker channel upload failed")
		return
	var open_flow: int = int(_navigation.call(
		&"create_flow_to_cell_with_options", Vector2i(2, 1), 0, -1
	))
	var blocked_flow: int = int(_navigation.call(
		&"create_flow_to_cell_with_options", Vector2i(2, 1), 2, -1
	))
	var open_direction: Vector2 = _navigation.call(
		&"sample_flow", open_flow, Vector2(108.0, -26.0)
	) as Vector2
	var blocked_direction: Vector2 = _navigation.call(
		&"sample_flow", blocked_flow, Vector2(108.0, -26.0)
	) as Vector2
	if open_direction.x <= 0.0 or not blocked_direction.is_zero_approx():
		_fail("selective blocker channel flow behavior changed")
		return
	var blocked_cost: float = float(_navigation.call(
		&"get_flow_route_cost", blocked_flow, Vector2(108.0, -26.0)
	))
	if not is_inf(blocked_cost):
		_fail("unreachable flow route cost should be infinite")
		return
	var diagnostics: Dictionary = _navigation.call(
		&"get_flow_diagnostics", open_flow
	) as Dictionary
	if not bool(diagnostics.get("valid", false)) or int(diagnostics.get("status", -1)) != 1:
		_fail("flow diagnostics did not report a ready handle")
		return
	var bottlenecks: Array = _navigation.call(&"get_flow_bottlenecks", open_flow) as Array
	if bottlenecks.size() != int(diagnostics.get("bottleneck_count", -1)):
		_fail("flow bottleneck diagnostics disagree")
		return
	var flow_handles: PackedInt64Array = _navigation.call(&"get_flow_handles") as PackedInt64Array
	if flow_handles.find(open_flow) < 0 or flow_handles.find(blocked_flow) < 0:
		_fail("active flow handle diagnostics are incomplete")
		return

	var seeded_garden: int = int(_navigation.call(
		&"create_garden_from_seed", Vector2i(0, 1), 0, 2
	))
	var garden_info: Dictionary = _navigation.call(
		&"get_garden_info", seeded_garden
	) as Dictionary
	var garden_cells: PackedVector2Array = garden_info.get(
		"interior_cells", PackedVector2Array()
	) as PackedVector2Array
	if seeded_garden <= 0 or garden_cells.size() != 3:
		_fail("seeded garden did not respect the blocker channel")
		return
	if not bool(_navigation.call(
		&"set_garden_target_cells", seeded_garden,
		PackedVector2Array([Vector2(0, 0)])
	)):
		_fail("seeded garden target update failed")
		return
	var garden_portal: int = int(_navigation.call(
		&"create_garden_portal", seeded_garden,
		PackedVector2Array([Vector2(0, 1)]),
		PackedVector2Array([Vector2(1, 1)]), 0, 2
	))
	var portal_info: Dictionary = _navigation.call(
		&"get_portal_info", garden_portal
	) as Dictionary
	if garden_portal <= 0 or int(portal_info.get("capacity", 0)) != 2:
		_fail("garden portal diagnostics changed")
		return
	var garden_route: RefCounted = _navigation.call(
		&"plan_enter_garden", seeded_garden,
		Vector2i(2, 1), Vector2i(0, 0), 0
	) as RefCounted
	if garden_route == null or int(garden_route.call(&"get_status")) != 0:
		_fail("option-aware garden enter route failed")
		return
	if not bool(_navigation.call(&"remove_portal", garden_portal)) \
			or not bool(_navigation.call(&"remove_garden", seeded_garden)):
		_fail("garden or portal removal failed")
		return

	var directed_cells: PackedVector2Array = barrier_cells
	var directed_values: PackedVector2Array = PackedVector2Array([
		Vector2.LEFT, Vector2.LEFT, Vector2.LEFT,
	])
	if not bool(_navigation.call(
		&"replace_directional_traversal_channel", 7,
		directed_cells, directed_values
	)):
		_fail("directional traversal channel upload failed")
		return
	var directed_flow: int = int(_navigation.call(
		&"create_flow_to_cell_with_options", Vector2i(2, 1), 0, 7
	))
	var directed_sample: Vector2 = _navigation.call(
		&"sample_flow", directed_flow, Vector2(108.0, -26.0)
	) as Vector2
	if not directed_sample.is_zero_approx():
		_fail("directional traversal channel was not applied")
		return
	_navigation.call(&"release_flow", open_flow)
	_navigation.call(&"release_flow", blocked_flow)
	_navigation.call(&"release_flow", directed_flow)
	_navigation.call(&"clear_blocker_channel", 1)
	_navigation.call(&"clear_directional_traversal_channel", 7)

	var request_id: int = int(_navigation.call(&"request_flow_to_cell", Vector2i(2, 2)))
	if request_id <= 0:
		_fail("asynchronous generic flow request failed")
		return
	_async_flow_handle = int(_navigation.call(
		&"request_flow_handle_to_cell", Vector2i(0, 0)
	))
	if _async_flow_handle <= 0:
		_fail("asynchronous generational flow request failed")
		return
	_option_async_flow_handle = int(_navigation.call(
		&"request_flow_handle_to_cell_with_options", Vector2i(2, 0), 0, -1
	))
	if _option_async_flow_handle <= 0:
		_fail("option-aware asynchronous flow request failed")


func _process(_delta: float) -> bool:
	_frames_waited += 1
	if _frames_waited > 300:
		_fail("asynchronous generic flow request timed out")
	return false


func _on_flow_ready(_request_id: int, status: int, _topology_revision: int) -> void:
	if status != 0:
		_fail("asynchronous generic flow returned status %d" % status)
		return
	_completed_requests += 1
	if _completed_requests < 3:
		return
	if int(_navigation.call(&"get_flow_status", _async_flow_handle)) != 1:
		_fail("completed generational flow was not installed as ready")
		return
	var reverse_direction: Vector2 = _navigation.call(
		&"sample_flow", _async_flow_handle, Vector2(132.0, -42.0)
	) as Vector2
	if reverse_direction.x >= 0.0:
		_fail("flow-handle sampling used the wrong destination")
		return
	if int(_navigation.call(&"get_flow_status", _option_async_flow_handle)) != 1:
		_fail("option-aware asynchronous flow did not become ready")
		return
	_navigation.call(&"release_flow", _async_flow_handle)
	_navigation.call(&"release_flow", _option_async_flow_handle)
	_navigation.queue_free()
	print("NavigationWorld2D smoke test passed")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	if _navigation != null:
		_navigation.queue_free()
	quit(1)
