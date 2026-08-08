extends Node2D

const CELL_SIZE: float = 32.0
const GRID_WIDTH: int = 14
const GRID_HEIGHT: int = 8
const BOTTLENECK_ID: int = 1

var _navigation: Node
var _crowd: Node
var _forward_agent: int = 0
var _reverse_agent: int = 0
var _forward_released: bool = false
var _reverse_released: bool = false
var _impulse_applied: bool = false
var _elapsed: float = 0.0


func _ready() -> void:
	_navigation = ClassDB.instantiate(&"NavigationWorld2D") as Node
	_crowd = ClassDB.instantiate(&"CrowdWorld2D") as Node
	if _navigation == null or _crowd == null:
		push_error("Build the reusable GDExtension before running this demo.")
		return
	add_child(_navigation)
	add_child(_crowd)

	var walkable: PackedVector2Array = PackedVector2Array()
	for y: int in range(GRID_HEIGHT):
		for x: int in range(GRID_WIDTH):
			if x != 6 or y == 3:
				walkable.append(Vector2(x, y))
	_navigation.call(
		&"configure_grid",
		Rect2i(0, 0, GRID_WIDTH, GRID_HEIGHT),
		CELL_SIZE,
		Vector2.ZERO,
		walkable,
		PackedVector2Array()
	)
	_navigation.call(&"configure_flow", 0.5, true, 1)
	_navigation.call(&"build_flow_to_cell", Vector2i(12, 3))

	var area: int = int(_navigation.call(
		&"create_area",
		PackedVector2Array([
			Vector2(10, 2), Vector2(11, 2), Vector2(12, 2),
			Vector2(10, 3), Vector2(11, 3), Vector2(12, 3),
			Vector2(10, 4), Vector2(11, 4), Vector2(12, 4),
		]),
		PackedVector2Array([Vector2(12, 3)])
	))
	_navigation.call(
		&"create_portal", area,
		PackedVector2Array([Vector2(10, 3)]),
		PackedVector2Array([Vector2(9, 3)]), 0, 1
	)
	var route: RefCounted = _navigation.call(
		&"plan_enter_area", area, Vector2i(1, 3), Vector2i(12, 3)
	) as RefCounted
	if route == null or int(route.call(&"get_status")) != 0:
		push_error("Demo area route could not be built.")

	_crowd.call(&"use_navigation_flow", _navigation)
	_crowd.call(&"configure_bottleneck", BOTTLENECK_ID, 1, 10.0)
	_forward_agent = int(_crowd.call(
		&"add_agent", _cell_center(Vector2i(1, 3)), 8.0, 70.0, 22.0, 0.8
	))
	_reverse_agent = int(_crowd.call(
		&"add_agent", _cell_center(Vector2i(8, 3)), 8.0, 55.0, 22.0, 0.8
	))
	_crowd.call(&"follow_flow", _forward_agent)
	_crowd.call(&"set_manual_direction", _reverse_agent, Vector2.LEFT)
	_crowd.call(&"request_bottleneck", BOTTLENECK_ID, _forward_agent, 1, 0)
	_crowd.call(&"request_bottleneck", BOTTLENECK_ID, _reverse_agent, -1, 0)


func _physics_process(delta: float) -> void:
	if _crowd == null:
		return
	_elapsed += delta
	var forward_has_access: bool = bool(_crowd.call(
		&"has_bottleneck_access", BOTTLENECK_ID, _forward_agent
	))
	var reverse_has_access: bool = bool(_crowd.call(
		&"has_bottleneck_access", BOTTLENECK_ID, _reverse_agent
	))
	_crowd.call(&"set_agent_paused", _forward_agent, not forward_has_access and not _forward_released)
	_crowd.call(&"set_agent_paused", _reverse_agent, not reverse_has_access and not _reverse_released)

	var forward_position: Vector2 = _crowd.call(&"get_agent_position", _forward_agent) as Vector2
	var reverse_position: Vector2 = _crowd.call(&"get_agent_position", _reverse_agent) as Vector2
	if not _forward_released and forward_position.x > _cell_center(Vector2i(7, 3)).x:
		_crowd.call(&"release_bottleneck", BOTTLENECK_ID, _forward_agent)
		_forward_released = true
	if not _reverse_released and reverse_position.x < _cell_center(Vector2i(5, 3)).x:
		_crowd.call(&"release_bottleneck", BOTTLENECK_ID, _reverse_agent)
		_reverse_released = true
	if not _impulse_applied and _elapsed >= 1.0:
		_crowd.call(
			&"apply_impulse", _forward_agent, Vector2(0.0, -100.0),
			0.0, 3.0, 0.15, true, 10
		)
		_impulse_applied = true
	queue_redraw()


func _draw() -> void:
	for y: int in range(GRID_HEIGHT):
		for x: int in range(GRID_WIDTH):
			var blocked: bool = x == 6 and y != 3
			var color: Color = Color(0.14, 0.16, 0.20) if blocked else Color(0.25, 0.29, 0.34)
			draw_rect(Rect2(Vector2(x, y) * CELL_SIZE, Vector2.ONE * CELL_SIZE), color, true)
			draw_rect(Rect2(Vector2(x, y) * CELL_SIZE, Vector2.ONE * CELL_SIZE), Color(0.4, 0.45, 0.5), false)
	draw_rect(Rect2(Vector2(10, 2) * CELL_SIZE, Vector2(3, 3) * CELL_SIZE), Color(0.2, 0.65, 0.35, 0.25), true)
	draw_rect(Rect2(Vector2(10, 3) * CELL_SIZE, Vector2.ONE * CELL_SIZE), Color(0.9, 0.75, 0.2), false, 4.0)
	if _crowd != null:
		var positions: PackedVector2Array = _crowd.call(&"get_agent_positions") as PackedVector2Array
		for index: int in range(positions.size()):
			var color: Color = Color(0.3, 0.75, 1.0) if index == 0 else Color(1.0, 0.45, 0.3)
			draw_circle(positions[index], 8.0, color)


func _cell_center(cell: Vector2i) -> Vector2:
	return (Vector2(cell) + Vector2(0.5, 0.5)) * CELL_SIZE
