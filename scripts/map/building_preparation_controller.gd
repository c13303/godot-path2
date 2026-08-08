extends RefCounted
class_name BuildingPreparationController

# Owns night/client preparation lifecycle and sequencing. Budgeted work-token
# generation is shared through BuildingPreparationWorkGate.

enum PreparationMode {
	NONE,
	NIGHT,
	CLIENT,
}

const SPAWNER_KIND_MONSTER: StringName = &"monster"
const SPAWNER_KIND_CLIENT: StringName = &"client"
const SPAWNER_KIND_MERCHANT: StringName = &"merchant"

var _host: Node = null
var _work_gate: BuildingPreparationWorkGate = null
var _invalidation_controller: BuildingInvalidationController = null
var _navigation_sync_service: BuildingNavigationSyncService = null
var _garden_topology_service: GardenTopologyService = null
var _spawner_route_service: SpawnerRouteService = null
var _budget_us: int = 500
var _budget_ms: float = 0.5
var _night_success_callback: Callable
var _client_success_callback: Callable
var _client_abort_callback: Callable

var _mode: int = PreparationMode.NONE
var _active_token: int = 0
var _night_ready: bool = false


func setup(
	host: Node,
	work_gate: BuildingPreparationWorkGate,
	_scan_service: BuildingScanService,
	invalidation_controller: BuildingInvalidationController,
	navigation_sync_service: BuildingNavigationSyncService,
	garden_topology_service: GardenTopologyService,
	spawner_route_service: SpawnerRouteService,
	budget_microseconds: int,
	night_success_callback: Callable,
	client_success_callback: Callable,
	client_abort_callback: Callable
) -> void:
	_host = host
	_work_gate = work_gate
	# Kept in the setup signature for BuildingManager compatibility. Complete map scans
	# belong to bootstrap; phase preparation consumes authoritative dirty state only.
	_invalidation_controller = invalidation_controller
	_navigation_sync_service = navigation_sync_service
	_garden_topology_service = garden_topology_service
	_spawner_route_service = spawner_route_service
	_budget_us = maxi(500, budget_microseconds)
	_budget_ms = float(_budget_us) / 1000.0
	_night_success_callback = night_success_callback
	_client_success_callback = client_success_callback
	_client_abort_callback = client_abort_callback


func is_night_preparing() -> bool:
	return _mode == PreparationMode.NIGHT and _work_gate != null and _work_gate.is_current(_active_token)


func is_client_preparing() -> bool:
	return _mode == PreparationMode.CLIENT and _work_gate != null and _work_gate.is_current(_active_token)


func is_preparing() -> bool:
	return is_night_preparing() or is_client_preparing()


func is_night_ready() -> bool:
	return _night_ready


func budget_us() -> int:
	return _budget_us


func begin_night_preparation() -> int:
	_active_token = _work_gate.begin_work(&"night_preparation")
	_mode = PreparationMode.NIGHT
	_night_ready = false
	return _active_token


func begin_client_preparation() -> int:
	_active_token = _work_gate.begin_work(&"client_preparation")
	_mode = PreparationMode.CLIENT
	_night_ready = false
	return _active_token


func reset_for_phase_transition() -> void:
	if _work_gate != null:
		_work_gate.cancel_current_work()
	_mode = PreparationMode.NONE
	_active_token = 0
	_night_ready = false


func restore_prepared_night_state() -> void:
	if _work_gate != null:
		_work_gate.cancel_current_work()
	_mode = PreparationMode.NONE
	_active_token = 0
	_night_ready = true


func restore_unprepared_state() -> void:
	if _work_gate != null:
		_work_gate.cancel_current_work()
	_mode = PreparationMode.NONE
	_active_token = 0
	_night_ready = false


func run_night_preparation(token: int) -> bool:
	await _host.get_tree().process_frame
	if not _owns_current_night(token):
		return false

	var prep_result: bool = await _run_shared_preparation(token)
	if not prep_result or not _owns_current_night(token):
		return false

	_spawner_route_service.rebuild_spawner_garden_route_cache()
	var monster_kinds: Array[StringName] = [SPAWNER_KIND_MONSTER]
	prep_result = await _spawner_route_service.initialize_spawner_routes_for_kinds(monster_kinds, token)
	if not prep_result or not _owns_current_night(token):
		return false

	prep_result = await _spawner_route_service.rebuild_exit_wall_escapes_budgeted(token)
	if not prep_result or not _owns_current_night(token):
		return false
	await _host.get_tree().process_frame
	if not _owns_current_night(token):
		return false

	prep_result = await _prepare_static_colliders()
	if not prep_result or not _owns_current_night(token):
		return false

	if not _spawner_route_service.flow_uses_async_requests() and not _spawner_route_service.flow_supports_sync_assign():
		push_error("BuildingManager: NavigationRuntime cannot assign group routes; night preparation cannot spawn monsters.")
		# Fail closed: keep the current night preparation token active and unready so
		# spawning remains gated until an authoritative phase reset cancels it.
		return false

	_publish_night_success(token)
	CppDebugOptions.dlog("gardens ready, monster night starts now (flow fields compute lazily)")
	return true


func run_client_preparation(token: int) -> bool:
	await _host.get_tree().process_frame
	if not _owns_current_client(token):
		return false

	var prep_result: bool = await _run_shared_preparation(token)
	if not prep_result or not _owns_current_client(token):
		_abort_client_if_current(token)
		return false

	_spawner_route_service.rebuild_spawner_garden_route_cache()
	var client_kinds: Array[StringName] = [SPAWNER_KIND_CLIENT, SPAWNER_KIND_MERCHANT]
	prep_result = await _spawner_route_service.initialize_spawner_routes_for_kinds(client_kinds, token)
	if not prep_result or not _owns_current_client(token):
		_abort_client_if_current(token)
		return false

	prep_result = await _prepare_static_colliders()
	if not prep_result or not _owns_current_client(token):
		_abort_client_if_current(token)
		return false

	if not _spawner_route_service.flow_uses_async_requests() and not _spawner_route_service.flow_supports_sync_assign():
		push_error("BuildingManager: NavigationRuntime cannot assign group routes; client preparation cannot spawn clients.")
		_abort_client_if_current(token)
		return false

	_publish_client_success(token)
	return true


func _run_shared_preparation(token: int) -> bool:
	_navigation_sync_service.sync_flow_extra_blocking_cells()
	_navigation_sync_service.rebuild_waterpool_directional_field()
	# A save is applied to the fresh scene before BuildingManager's deferred startup pass. When
	# startup has already built that exact restored snapshot, phase restoration only needs its
	# phase-specific routes below; rebuilding the same complete plant layout is redundant.
	if not _invalidation_controller.navigation_topology_dirty() \
			and not _invalidation_controller.plant_layout_dirty() \
			and _garden_topology_service.plant_zone_built():
		CppDebugOptions.dlog("[PLANT_LAYOUT] request=restore_preparation merged=true reason=clean_startup_snapshot")
		return true
	_invalidation_controller.clear_navigation_topology_dirty()
	_invalidation_controller.clear_plant_layout_dirty()
	await _host.get_tree().process_frame
	if not _owns_current_preparation(token):
		return false
	var prep_result: bool = await _garden_topology_service.rebuild_walkable_map_cache_budgeted(token)
	if not prep_result or not _owns_current_preparation(token):
		return false
	prep_result = await _garden_topology_service.build_gardens_from_plants_budgeted(token)
	if not prep_result or not _owns_current_preparation(token):
		return false
	prep_result = await _garden_topology_service.validate_gardens_budgeted(token)
	if not prep_result or not _owns_current_preparation(token):
		return false
	_invalidation_controller.mark_navigation_rebuild_completed()
	return true


func _prepare_static_colliders() -> bool:
	var scene: Node = _host.get_tree().current_scene
	var fight_system: Node = scene.get_node_or_null("fightSystem") if scene else null
	if fight_system and fight_system.has_method("prepare_night_static_colliders_budgeted"):
		var prep_result: bool = bool(await fight_system.call("prepare_night_static_colliders_budgeted", _budget_ms))
		if not prep_result:
			return false
	elif fight_system and fight_system.has_method("prepare_night_static_colliders"):
		fight_system.call("prepare_night_static_colliders")
	return true


func _publish_night_success(token: int) -> void:
	if not _owns_current_night(token):
		return
	_mode = PreparationMode.NONE
	_active_token = 0
	_night_ready = true
	_work_gate.finish_work(token)
	if _night_success_callback.is_valid():
		_night_success_callback.call()


func _publish_client_success(token: int) -> void:
	if not _owns_current_client(token):
		return
	_mode = PreparationMode.NONE
	_active_token = 0
	_night_ready = false
	_work_gate.finish_work(token)
	if _client_success_callback.is_valid():
		_client_success_callback.call()


func _abort_client_if_current(token: int) -> void:
	if not _owns_current_client(token):
		return
	_mode = PreparationMode.NONE
	_active_token = 0
	_night_ready = false
	_work_gate.cancel_if_current(token)
	if _client_abort_callback.is_valid():
		_client_abort_callback.call()


func _owns_current_preparation(token: int) -> bool:
	if token <= 0 or token != _active_token:
		return false
	if _mode == PreparationMode.NONE:
		return false
	return _work_gate != null and _work_gate.is_current(token)


func _owns_current_night(token: int) -> bool:
	return _mode == PreparationMode.NIGHT and _owns_current_preparation(token)


func _owns_current_client(token: int) -> bool:
	return _mode == PreparationMode.CLIENT and _owns_current_preparation(token)
