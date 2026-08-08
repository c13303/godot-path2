extends Node
class_name NavigationFlowCoordinator

## Host-side lifecycle coordinator for CPathLib flow and cohort handles.
## CPathLib owns construction and sampling; this object only maps host requests
## onto explicit generic handles.

const INVALID_HANDLE: int = 0
const FLOW_PENDING: int = 0
const FLOW_READY: int = 1

var _navigation: Node
var _crowd: Node
var _floor_layer: TileMapLayer
var _flow_by_cohort: Dictionary = {}
var _pending_flow_by_cohort: Dictionary = {}


func setup(navigation_world: Node, crowd_world: Node, floor_layer: TileMapLayer) -> bool:
	if navigation_world == null or crowd_world == null or floor_layer == null:
		return false
	if not navigation_world.has_method(&"request_flow_handle_to_cell_with_options"):
		return false
	_navigation = navigation_world
	_crowd = crowd_world
	_floor_layer = floor_layer
	set_process(true)
	return true


func request_flow(
	cohort_handle: int,
	goal_world: Vector2,
	blocker_channel_mask: int,
	directional_channel: int = -1
) -> int:
	if _navigation == null or cohort_handle == INVALID_HANDLE:
		return INVALID_HANDLE
	cancel_pending_flow(cohort_handle)
	var goal_cell: Vector2i = _floor_layer.local_to_map(_floor_layer.to_local(goal_world))
	var flow_handle: int = int(_navigation.call(
		&"request_flow_handle_to_cell_with_options", goal_cell,
		blocker_channel_mask, directional_channel
	))
	if flow_handle != INVALID_HANDLE:
		_pending_flow_by_cohort[cohort_handle] = flow_handle
	return flow_handle


func build_and_assign_flow(
	cohort_handle: int,
	goal_world: Vector2,
	blocker_channel_mask: int,
	directional_channel: int = -1
) -> bool:
	if _navigation == null or _crowd == null or cohort_handle == INVALID_HANDLE:
		return false
	var goal_cell: Vector2i = _floor_layer.local_to_map(_floor_layer.to_local(goal_world))
	var flow_handle: int = int(_navigation.call(
		&"create_flow_to_cell_with_options", goal_cell,
		blocker_channel_mask, directional_channel
	))
	if flow_handle == INVALID_HANDLE or int(_navigation.call(
		&"get_flow_status", flow_handle
	)) != FLOW_READY:
		if flow_handle != INVALID_HANDLE:
			_navigation.call(&"release_flow", flow_handle)
		return false
	return _install_for_cohort(cohort_handle, flow_handle)


func cancel_pending_flow(cohort_handle: int) -> void:
	var flow_handle: int = int(_pending_flow_by_cohort.get(cohort_handle, INVALID_HANDLE))
	if flow_handle != INVALID_HANDLE and _navigation != null:
		_navigation.call(&"cancel_flow", flow_handle)
		_navigation.call(&"release_flow", flow_handle)
	_pending_flow_by_cohort.erase(cohort_handle)


func release_cohort_flow(cohort_handle: int) -> void:
	cancel_pending_flow(cohort_handle)
	var flow_handle: int = int(_flow_by_cohort.get(cohort_handle, INVALID_HANDLE))
	if flow_handle != INVALID_HANDLE:
		if _crowd != null:
			_crowd.call(&"remove_navigation_flow", flow_handle)
		if _navigation != null:
			_navigation.call(&"release_flow", flow_handle)
	_flow_by_cohort.erase(cohort_handle)


func is_flow_ready(cohort_handle: int) -> bool:
	return _flow_by_cohort.has(cohort_handle) and not _pending_flow_by_cohort.has(cohort_handle)


func has_pending_flows() -> bool:
	return not _pending_flow_by_cohort.is_empty()


func flow_handle_for_cohort(cohort_handle: int) -> int:
	return int(_flow_by_cohort.get(cohort_handle, INVALID_HANDLE))


func sample_direction(cohort_handle: int, world_position: Vector2) -> Vector2:
	var flow_handle: int = flow_handle_for_cohort(cohort_handle)
	if _navigation == null or flow_handle == INVALID_HANDLE:
		return Vector2.ZERO
	return _navigation.call(&"sample_flow", flow_handle, world_position) as Vector2


func route_cost(cohort_handle: int, world_position: Vector2) -> float:
	var flow_handle: int = flow_handle_for_cohort(cohort_handle)
	if _navigation == null or flow_handle == INVALID_HANDLE:
		return INF
	return float(_navigation.call(&"get_flow_route_cost", flow_handle, world_position))


func _process(_delta: float) -> void:
	if _navigation == null or _crowd == null:
		return
	var completed: Array = []
	var rejected: Array = []
	for raw_cohort: Variant in _pending_flow_by_cohort:
		var cohort_handle: int = int(raw_cohort)
		var flow_handle: int = int(_pending_flow_by_cohort[cohort_handle])
		var status: int = int(_navigation.call(&"get_flow_status", flow_handle))
		if status == FLOW_READY:
			completed.append(cohort_handle)
		elif status != FLOW_PENDING:
			rejected.append(cohort_handle)
	for raw_cohort: Variant in completed:
		var cohort_handle: int = int(raw_cohort)
		var flow_handle: int = int(_pending_flow_by_cohort[cohort_handle])
		_pending_flow_by_cohort.erase(cohort_handle)
		if not _install_for_cohort(cohort_handle, flow_handle):
			_navigation.call(&"release_flow", flow_handle)
	for raw_cohort: Variant in rejected:
		var cohort_handle: int = int(raw_cohort)
		var flow_handle: int = int(_pending_flow_by_cohort[cohort_handle])
		_pending_flow_by_cohort.erase(cohort_handle)
		_navigation.call(&"release_flow", flow_handle)


func _install_for_cohort(cohort_handle: int, flow_handle: int) -> bool:
	if not bool(_crowd.call(&"install_navigation_flow", _navigation, flow_handle)):
		return false
	if not bool(_crowd.call(&"assign_cohort_flow", cohort_handle, flow_handle)):
		_crowd.call(&"remove_navigation_flow", flow_handle)
		return false
	var previous: int = int(_flow_by_cohort.get(cohort_handle, INVALID_HANDLE))
	_flow_by_cohort[cohort_handle] = flow_handle
	if previous != INVALID_HANDLE and previous != flow_handle:
		_crowd.call(&"remove_navigation_flow", previous)
		_navigation.call(&"release_flow", previous)
	return true
