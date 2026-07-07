extends RefCounted
class_name BuildingPreparationController

# Owns night/client preparation sequencing extracted from BuildingManager.
# This is an orchestration-only extraction: domain state and underlying rebuild
# operations still live on BuildingManager and its existing services.

const SPAWNER_KIND_MONSTER: StringName = &"monster"
const SPAWNER_KIND_CLIENT: StringName = &"client"
const SPAWNER_KIND_MERCHANT: StringName = &"merchant"

var _manager: BuildingManager


func setup(manager: BuildingManager) -> void:
	_manager = manager


func run_night_preparation(token: int) -> void:
	# Start on a clean frame; the mode-change input frame performs no navigation.
	await _manager.get_tree().process_frame
	if not _manager._night_preparation_is_current(token):
		return

	var prep_result: bool = await _run_shared_preparation(token)
	if not prep_result:
		return

	_manager._rebuild_spawner_garden_route_cache()
	var monster_kinds: Array[StringName] = [SPAWNER_KIND_MONSTER]
	prep_result = await _manager._initialize_spawner_routes_for_kinds(monster_kinds, token)
	if not prep_result:
		return

	prep_result = await _manager._prewarm_spawner_entry_flows_for_kind(SPAWNER_KIND_MONSTER, token)
	if not prep_result:
		return

	# Exit fields also use the native worker during preparation.
	prep_result = await _manager._rebuild_exit_wall_escapes_budgeted(token)
	if not prep_result:
		return
	await _manager.get_tree().process_frame
	if not _manager._night_preparation_is_current(token):
		return

	prep_result = await _prepare_static_colliders()
	if not prep_result:
		return

	# Do not open the spawn gate until async work has finished. Older exported
	# native DLLs may not expose async status methods; in that case requests are
	# assigned synchronously by _request_group_flow_rebuild().
	if not _manager._flow_uses_async_requests() and not _manager._flow_supports_sync_assign():
		push_error("BuildingManager: FlowFieldNative cannot assign group routes; night preparation cannot spawn monsters.")
		return
	if _manager._flow_uses_async_requests():
		while _manager._night_preparation_is_current(token) and not bool(_manager.flow.call("are_async_flows_idle")):
			await _manager.get_tree().process_frame
	if not _manager._night_preparation_is_current(token):
		return
	if not _manager._night_flow_fields_are_ready_for_kinds(monster_kinds, true):
		push_error("BuildingManager: night flow-field preparation completed with an unusable route")
		return

	_manager._night_preparing = false
	_manager._night_preparation_ready = true
	_manager._seed_merchant.start_pending_leave_if_needed()
	CppDebugOptions.dlog("ff & gardens computed, monster night starts now")


func run_client_preparation(token: int) -> void:
	await _manager.get_tree().process_frame
	if not _manager._night_preparation_is_current(token):
		return

	var prep_result: bool = await _run_shared_preparation(token)
	if not prep_result:
		_manager._abort_client_preparation(token)
		return

	_manager._rebuild_spawner_garden_route_cache()
	var client_kinds: Array[StringName] = [SPAWNER_KIND_CLIENT, SPAWNER_KIND_MERCHANT]
	prep_result = await _manager._initialize_spawner_routes_for_kinds(client_kinds, token)
	if not prep_result:
		_manager._abort_client_preparation(token)
		return

	prep_result = await _manager._prewarm_spawner_entry_flows_for_kind(SPAWNER_KIND_CLIENT, token)
	if not prep_result:
		_manager._abort_client_preparation(token)
		return

	prep_result = await _prepare_static_colliders()
	if not prep_result:
		_manager._abort_client_preparation(token)
		return

	if not _manager._flow_uses_async_requests() and not _manager._flow_supports_sync_assign():
		push_error("BuildingManager: FlowFieldNative cannot assign group routes; client preparation cannot spawn clients.")
		_manager._abort_client_preparation(token)
		return
	if _manager._flow_uses_async_requests():
		while _manager._night_preparation_is_current(token) and not bool(_manager.flow.call("are_async_flows_idle")):
			await _manager.get_tree().process_frame
	if not _manager._night_preparation_is_current(token):
		return
	if not _manager._night_flow_fields_are_ready_for_kinds(client_kinds, false):
		push_error("BuildingManager: client flow-field preparation completed with an unusable route")
		_manager._abort_client_preparation(token)
		return

	_manager._client_preparing = false
	_manager._client_sale.activate()


func _run_shared_preparation(token: int) -> bool:
	_manager._scan_buildings()
	_manager._sync_flow_extra_blocking_cells()
	_manager._rebuild_waterpool_directional_field()
	_manager._building_invalidation_controller.clear_navigation_topology_dirty()
	await _manager.get_tree().process_frame
	var prep_result: bool = await _manager._rebuild_walkable_map_cache_budgeted(token)
	if not prep_result:
		return false
	prep_result = await _manager._build_gardens_from_plants_budgeted(token)
	if not prep_result:
		return false
	prep_result = await _manager._validate_gardens_budgeted(token)
	if not prep_result:
		return false
	return true


func _prepare_static_colliders() -> bool:
	var scene: Node = _manager.get_tree().current_scene
	var fight_system: Node = scene.get_node_or_null("fightSystem") if scene else null
	if fight_system and fight_system.has_method("prepare_night_static_colliders_budgeted"):
		var prep_result: bool = bool(await fight_system.call("prepare_night_static_colliders_budgeted", _manager.night_preparation_budget_ms))
		if not prep_result:
			return false
	elif fight_system and fight_system.has_method("prepare_night_static_colliders"):
		fight_system.call("prepare_night_static_colliders")
	return true
