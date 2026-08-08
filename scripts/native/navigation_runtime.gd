extends Node2D
class_name NavigationRuntime

## Project adapter from authored TileMap data and route groups to CPathLib.

const DYNAMIC_BLOCKER_CHANNEL: int = 1
const FENCE_BLOCKER_CHANNEL: int = 2
const DYNAMIC_BLOCKER_MASK: int = 1 << DYNAMIC_BLOCKER_CHANNEL
const FENCE_BLOCKER_MASK: int = 1 << FENCE_BLOCKER_CHANNEL
const INVALID_HANDLE: int = 0

@export var world_path: NodePath = NodePath("World")
@export var crowd_path: NodePath = NodePath("../CrowdWorld")
@export var registry_path: NodePath = NodePath("../AgentRegistry")

var _world: Node
var _crowd: Node
var _registry: Node
var _floor_layer: TileMapLayer
var _wall_layer: TileMapLayer
var _navigation_blocking_layer: TileMapLayer
var _map_bounds: Rect2i = Rect2i()
var _upload: NavigationGridUploadService = NavigationGridUploadService.new()
var _coordinator: NavigationFlowCoordinator
var _directional_channels: Dictionary = {}
var _debug_draw: bool = false
var _debug_group: int = 0
var _baseline_goal_cell: Vector2i = Vector2i.ZERO
var _baseline_flow_handle: int = INVALID_HANDLE


func _ready() -> void:
	_world = get_node_or_null(world_path)
	_crowd = get_node_or_null(crowd_path)
	_registry = get_node_or_null(registry_path)
	_coordinator = NavigationFlowCoordinator.new()
	_coordinator.name = "FlowCoordinator"
	add_child(_coordinator)
	_coordinator.cohort_flow_installed.connect(_on_cohort_flow_finished)
	_coordinator.cohort_flow_failed.connect(_on_cohort_flow_finished)


func world() -> Node:
	return _world


func set_floor_layer(layer: TileMapLayer) -> void:
	_floor_layer = layer


func set_wall_layer(layer: TileMapLayer) -> void:
	_wall_layer = layer


func set_navigation_blocking_layer(layer: TileMapLayer) -> void:
	_navigation_blocking_layer = layer


func set_water_layer(layer: TileMapLayer) -> void:
	set_navigation_blocking_layer(layer)


func set_blocking_layer(layer: TileMapLayer) -> void:
	set_navigation_blocking_layer(layer)


func get_floor_layer() -> TileMapLayer:
	return _floor_layer


func get_wall_layer() -> TileMapLayer:
	return _wall_layer


func get_navigation_blocking_layer() -> TileMapLayer:
	return _navigation_blocking_layer


func get_water_layer() -> TileMapLayer:
	return _navigation_blocking_layer


func get_blocking_layer() -> TileMapLayer:
	return _navigation_blocking_layer


func set_map_bounds(bounds: Rect2i) -> void:
	_map_bounds = bounds


func compute_distance_field_global() -> void:
	if _world == null or _floor_layer == null or _wall_layer == null:
		return
	var config: SimulationConfigService = get_node_or_null("../SimulationConfig") as SimulationConfigService
	var radius: float = config.get_agent_world_radius() if config != null else 14.4
	var clearance: float = config.flow_field_wall_clearance if config != null else 0.5
	var zone_radius: int = config.bottleneck_zone_radius_tiles if config != null else 2
	if not _upload.configure_world(
		_world, _floor_layer, _wall_layer, _navigation_blocking_layer,
		_map_bounds, radius, 0.5, clearance, zone_radius
	):
		push_error("NavigationRuntime: CPathLib grid configuration failed.")
		return
	_coordinator.setup(_world, _crowd, _floor_layer)
	# Install one baseline field so manual agents receive the same physical-grid
	# collision data before any route cohort is requested.
	var walkable_cells: Array[Vector2i] = _floor_layer.get_used_cells()
	for cell: Vector2i in walkable_cells:
		var handle: int = int(_world.call(
			&"create_flow_to_cell_with_options", cell,
			DYNAMIC_BLOCKER_MASK, -1
		))
		if handle == INVALID_HANDLE or int(_world.call(&"get_flow_status", handle)) != 1:
			if handle != INVALID_HANDLE:
				_world.call(&"release_flow", handle)
			continue
		_baseline_goal_cell = cell
		_baseline_flow_handle = handle
		_crowd.call(&"use_navigation_flow_handle", _world, handle)
		break


func set_extra_blocking_cells(cells: PackedVector2Array) -> void:
	if _upload.replace_dynamic_blockers(_world, cells):
		_refresh_baseline_collision_flow()


func clear_extra_blocking_cells() -> void:
	if _world != null:
		_world.call(&"clear_blocker_channel", DYNAMIC_BLOCKER_CHANNEL)
		_refresh_baseline_collision_flow()


func set_fence_blocking_cells(cells: PackedVector2Array) -> void:
	_upload.replace_fence_blockers(_world, cells)


func clear_fence_blocking_cells() -> void:
	if _world != null:
		_world.call(&"clear_blocker_channel", FENCE_BLOCKER_CHANNEL)


func set_cell_blocked(cell: Vector2i, blocked: bool) -> void:
	if _upload.set_dynamic_blocker(_world, cell, blocked):
		_refresh_baseline_collision_flow()


func _refresh_baseline_collision_flow() -> void:
	if _world == null or _crowd == null or _baseline_flow_handle == INVALID_HANDLE:
		return
	var replacement: int = _create_collision_flow(_baseline_goal_cell)
	var replacement_goal: Vector2i = _baseline_goal_cell
	if replacement == INVALID_HANDLE and _floor_layer != null:
		for cell: Vector2i in _floor_layer.get_used_cells():
			if cell == _baseline_goal_cell:
				continue
			replacement = _create_collision_flow(cell)
			if replacement != INVALID_HANDLE:
				replacement_goal = cell
				break
	if replacement == INVALID_HANDLE:
		return
	if bool(_crowd.call(&"use_navigation_flow_handle", _world, replacement)):
		_world.call(&"release_flow", _baseline_flow_handle)
		_baseline_flow_handle = replacement
		_baseline_goal_cell = replacement_goal
	else:
		_world.call(&"release_flow", replacement)


func _create_collision_flow(goal_cell: Vector2i) -> int:
	var handle: int = int(_world.call(
		&"create_flow_to_cell_with_options", goal_cell,
		DYNAMIC_BLOCKER_MASK, -1
	))
	if handle != INVALID_HANDLE and int(_world.call(&"get_flow_status", handle)) == 1:
		return handle
	if handle != INVALID_HANDLE:
		_world.call(&"release_flow", handle)
	return INVALID_HANDLE


func set_directional_traversal_field(field_id: int, cells: PackedVector2Array, directions: PackedVector2Array) -> void:
	if _world == null:
		return
	_world.call(&"replace_directional_traversal_channel", field_id, cells, directions)
	_directional_channels[field_id] = true


func clear_directional_traversal_field(field_id: int) -> void:
	if _world != null:
		_world.call(&"clear_directional_traversal_channel", field_id)
	_directional_channels.erase(field_id)


func clear_directional_traversal_fields() -> void:
	for raw_id: Variant in _directional_channels.keys():
		clear_directional_traversal_field(int(raw_id))


func request_flow_to_group(group_id: int, goal_world: Vector2, block_fences: bool = false, traversal_field_id: int = -1) -> void:
	if _coordinator == null:
		return
	var blocker_mask: int = DYNAMIC_BLOCKER_MASK | (FENCE_BLOCKER_MASK if block_fences else 0)
	_coordinator.request_flow(group_id, goal_world, blocker_mask, traversal_field_id)
	if _registry != null:
		_registry.call(&"set_group_flow_wait", group_id, 1)


func assign_flow_to_group(group_id: int, goal_world: Vector2, block_fences: bool = false, traversal_field_id: int = -1) -> void:
	if _coordinator == null:
		return
	var blocker_mask: int = DYNAMIC_BLOCKER_MASK | (FENCE_BLOCKER_MASK if block_fences else 0)
	_coordinator.build_and_assign_flow(group_id, goal_world, blocker_mask, traversal_field_id)


func mark_group_flow_queued(group_id: int) -> void:
	if _registry != null:
		_registry.call(&"set_group_flow_wait", group_id, 1)


func is_group_flow_request_ready(group_id: int) -> bool:
	return _coordinator != null and _coordinator.is_flow_ready(group_id)


func cancel_group_flow_request(group_id: int) -> void:
	if _coordinator != null:
		_coordinator.release_cohort_flow(group_id)
	if _registry != null:
		_registry.call(&"set_group_flow_wait", group_id, 0)


func _on_cohort_flow_finished(group_id: int) -> void:
	if _registry != null:
		_registry.call(&"set_group_flow_wait", group_id, 0)


func are_async_flows_idle() -> bool:
	return _coordinator == null or not _coordinator.has_pending_flows()


func compute_group_flow_dir(group_id: int, world_position: Vector2) -> Vector2:
	return _coordinator.sample_direction(group_id, world_position) if _coordinator != null else Vector2.ZERO


func group_route_cost_at_world(group_id: int, world_position: Vector2) -> float:
	return _coordinator.route_cost(group_id, world_position) if _coordinator != null else INF


func compute_flow_dir(world_position: Vector2) -> Vector2:
	return _world.call(&"sample_latest_flow", world_position) as Vector2 if _world != null else Vector2.ZERO


func rebuild_async(world_position: Vector2) -> void:
	if _world == null or _floor_layer == null:
		return
	var goal: Vector2i = _floor_layer.local_to_map(_floor_layer.to_local(world_position))
	_world.call(&"request_flow_handle_to_cell", goal)


func get_flow_pool_debug_snapshot() -> Dictionary:
	return {"flow_handles": _world.call(&"get_flow_handles") if _world != null else PackedInt64Array()}


func set_debug_draw(value: bool) -> void:
	_debug_draw = value


func get_debug_draw() -> bool:
	return _debug_draw


func set_debug_draw_group(group_id: int) -> void:
	_debug_group = group_id
