extends SceneTree

var _navigation: Node
var _frames_waited: int = 0


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

	var request_id: int = int(_navigation.call(&"request_flow_to_cell", Vector2i(2, 2)))
	if request_id <= 0:
		_fail("asynchronous generic flow request failed")


func _process(_delta: float) -> bool:
	_frames_waited += 1
	if _frames_waited > 300:
		_fail("asynchronous generic flow request timed out")
	return false


func _on_flow_ready(_request_id: int, status: int, _topology_revision: int) -> void:
	if status != 0:
		_fail("asynchronous generic flow returned status %d" % status)
		return
	_navigation.queue_free()
	print("NavigationWorld2D smoke test passed")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	if _navigation != null:
		_navigation.queue_free()
	quit(1)
