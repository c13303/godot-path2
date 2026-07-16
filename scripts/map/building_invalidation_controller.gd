extends RefCounted
class_name BuildingInvalidationController

# Owns the "something changed on the map/building layer, now dependent systems must
# be marked dirty or rebuilt" orchestration extracted from BuildingManager. This
# controller owns the navigation-topology dirty flag and sequences invalidation /
# dirty-marking / follow-up refreshes; it never performs the underlying gameplay
# mutation (placement, removal, inventory, refunds). BuildingManager keeps owned
# services and scene-facing lifecycle orchestration.
#
# Behavior note: this is an extraction only. The order of every invalidation call,
# the dirty flags touched, the cache-clear timing, and the debug/telemetry strings
# are preserved exactly as they were inline in BuildingManager.

var _manager: BuildingManager
var _work_gate: BuildingPreparationWorkGate
var _garden_topology: GardenTopologyService
var _spawner_route_service: SpawnerRouteService
var _navigation_sync_service: BuildingNavigationSyncService
var _debug_telemetry: BuildingDebugTelemetry
var _navigation_topology_dirty: bool = true
var _plant_layout_dirty: bool = false
var _walkability_quiet_seconds_remaining: float = 0.0
# Runtime (mid-gameplay) walkability rebuilds run as a budgeted coroutine so a wall
# built with agents active never costs a full rebuild in one frame. While active,
# BuildingManager.should_skip_building_runtime_tick() pauses the GDScript decision
# ticks; native steering keeps moving agents on their current flow fields. The id
# guards the active flag against a superseded (zombie) coroutine clearing it.
var _runtime_rebuild_active: bool = false
var _runtime_rebuild_is_plant_layout: bool = false
var _runtime_rebuild_id: int = 0
var _runtime_work_token: int = 0
var _runtime_rebuild_wants_gardens: bool = false
# Coarse 0..1 progress of the current runtime rebuild, advanced between the
# budgeted passes. Read by BuildingConstructionOverlay for the progress bar.
var _runtime_rebuild_progress: float = 0.0
var _navigation_revision: int = 0

const WALKABILITY_REBUILD_QUIET_SECONDS: float = 0.15


func setup(
	manager: BuildingManager,
	work_gate: BuildingPreparationWorkGate,
	navigation_sync_service: BuildingNavigationSyncService
) -> void:
	_manager = manager
	_work_gate = work_gate
	_garden_topology = manager.get_garden_topology_service()
	_spawner_route_service = manager.get_spawner_route_service()
	_navigation_sync_service = navigation_sync_service
	_debug_telemetry = manager.get_building_debug_telemetry()


func mark_navigation_topology_dirty() -> void:
	_navigation_topology_dirty = true
	_walkability_quiet_seconds_remaining = WALKABILITY_REBUILD_QUIET_SECONDS


func clear_navigation_topology_dirty() -> void:
	_navigation_topology_dirty = false
	_walkability_quiet_seconds_remaining = 0.0


func mark_plant_layout_dirty() -> void:
	_plant_layout_dirty = true
	_walkability_quiet_seconds_remaining = WALKABILITY_REBUILD_QUIET_SECONDS
	# A plant edit between budgeted slices supersedes that topology snapshot.
	if _runtime_rebuild_active:
		if not _runtime_rebuild_is_plant_layout:
			_navigation_topology_dirty = true
		_work_gate.cancel_if_current(_runtime_work_token)


func clear_plant_layout_dirty() -> void:
	_plant_layout_dirty = false


# A wall / blocking-building change altered map walkability (which cells block
# movement / flow). Only a lightweight mark: the actual rebuild happens later when
# apply_navigation_topology_rebuild() consumes the dirty flag.
func after_walkability_changed(_reason: String = "") -> void:
	mark_navigation_topology_dirty()


func mark_after_building_scan_changed() -> void:
	after_walkability_changed("building_scan")


func mark_after_blocking_building_added() -> void:
	after_walkability_changed("building_added")


func mark_after_blocking_building_removed() -> void:
	after_walkability_changed("building_removed")


# A plant was added/removed during the day (or while no runtime agents are active).
# Invalidates the built plant-zone snapshot, restarts the shared topology quiet
# period, and refreshes the zone overlay. The budgeted owner rebuilds later.
func after_plant_layout_changed(_reason: String = "") -> void:
	var topology: GardenTopologyService = _garden_topology
	topology.set_plant_zone_built(false)
	mark_plant_layout_dirty()
	_manager.queue_plant_zone_overlay_redraw()


# Consumes a pending navigation-topology dirty mark: re-syncs flow blocking cells,
# rebuilds the walkable map + (if built) the plant zone, refreshes spawner/garden
# route caches, re-plans per-spawner plant flow fields, marks spawner escapes dirty,
# and rebuilds the exit-wall escape fields (with the same telemetry span). No-op when
# nothing is dirty. Preserves the exact order the sequence had inline.
func apply_navigation_topology_rebuild(delta: float = -1.0) -> void:
	if delta <= 0.0 and _runtime_rebuild_active:
		# A synchronous caller (save/load, startup sync) needs consistent topology
		# now. Cancel the in-flight budgeted rebuild (its token goes stale at the
		# next slice) and force the synchronous rebuild below so the caller never
		# observes half-built gardens.
		_work_gate.cancel_if_current(_runtime_work_token)
		_runtime_rebuild_id += 1
		_runtime_rebuild_active = false
		_runtime_rebuild_is_plant_layout = false
		_runtime_work_token = 0
		_navigation_topology_dirty = true
	if (_navigation_topology_dirty or _plant_layout_dirty) and delta > 0.0:
		_walkability_quiet_seconds_remaining = maxf(0.0, _walkability_quiet_seconds_remaining - delta)
		if _walkability_quiet_seconds_remaining > 0.0:
			return
	if _navigation_topology_dirty:
		if delta > 0.0:
			_start_runtime_walkability_rebuild()
		else:
			_apply_walkability_topology_rebuild()
	elif _plant_layout_dirty:
		if delta > 0.0:
			_start_runtime_plant_layout_rebuild()
		else:
			_apply_plant_layout_rebuild()


func runtime_rebuild_active() -> bool:
	return _runtime_rebuild_active


func runtime_rebuild_progress() -> float:
	return _runtime_rebuild_progress


func navigation_topology_dirty() -> bool:
	return _navigation_topology_dirty


func plant_layout_dirty() -> bool:
	return _plant_layout_dirty


func navigation_revision() -> int:
	return _navigation_revision


func mark_navigation_rebuild_completed() -> void:
	_bump_navigation_revision()


# Budgeted (multi-frame) mirror of _apply_walkability_topology_rebuild for live
# gameplay: same step order, but the heavy passes (walkable cache, garden
# clustering/validation, exit-wall escapes) are sliced across frames using the
# configured preparation budget. Cancellation: the shared work token goes stale
# (night/client prep start, sync rebuild, save/load) -> the budgeted passes return
# false and the coroutine stops without touching further state.
func _start_runtime_walkability_rebuild() -> void:
	if _runtime_rebuild_active:
		return
	clear_navigation_topology_dirty()
	# Capture the tile state we are about to rebuild for, so the next periodic scan sees a
	# matching baseline and does not re-trigger a second rebuild for this same mutation.
	_manager.get_building_scan_service().resync_topology_signatures()
	_runtime_rebuild_active = true
	_runtime_rebuild_is_plant_layout = false
	_runtime_rebuild_id += 1
	# Remember that gardens were built so an aborted run still rebuilds them on the
	# next attempt (a partial run can leave plant_zone_built false).
	_runtime_rebuild_wants_gardens = (
		_runtime_rebuild_wants_gardens
		or _plant_layout_dirty
		or _garden_topology.plant_zone_built()
	)
	_runtime_work_token = _work_gate.begin_work(&"runtime_walkability_rebuild")
	_run_runtime_walkability_rebuild(_runtime_work_token, _runtime_rebuild_id)


func _run_runtime_walkability_rebuild(token: int, rebuild_id: int) -> void:
	var started_us: int = Time.get_ticks_usec()
	CppDebugOptions.dlog("walkability rebuild started (budgeted)")
	_runtime_rebuild_progress = 0.0
	_navigation_sync_service.sync_flow_extra_blocking_cells()
	_navigation_sync_service.rebuild_waterpool_directional_field()
	# Hard walkability changed, so every approach field is stale: invalidate before the
	# route caches below re-validate against it, otherwise an inbound route could stay
	# "current" (unchanged garden version) while pointing at the entrance the old maze
	# made best. This only bumps the generation and queues one field per spawner; the
	# shared queue drains them at its normal one-per-frame rate.
	_spawner_route_service.invalidate_spawner_approach_flows()
	var ok: bool = bool(await _manager._rebuild_walkable_map_cache_budgeted(token))
	_runtime_rebuild_progress = 0.3
	if ok:
		_manager.get_ally_housing_controller().repath_residents()
		if _runtime_rebuild_wants_gardens:
			ok = bool(await _manager._build_gardens_from_plants_budgeted(token))
			if ok:
				ok = bool(await _manager._validate_gardens_budgeted(token))
			if ok:
				_spawner_route_service.rebuild_spawner_garden_route_cache()
				_manager._queue_agents_after_garden_rebuild()
	_runtime_rebuild_progress = 0.7
	if ok:
		_manager._rebuild_spawner_garden_route_cache()
		for raw_spawner_cell: Variant in _manager.get_spawners().keys():
			var spawner_cell: Vector2i = raw_spawner_cell as Vector2i
			_manager._rebuild_spawner_plant_ff(spawner_cell)
			_spawner_route_service.mark_spawner_escape_dirty(spawner_cell)
		ok = bool(await _manager._rebuild_exit_wall_escapes_budgeted(token))
	_runtime_rebuild_progress = 1.0
	if ok:
		_runtime_rebuild_wants_gardens = false
		clear_plant_layout_dirty()
		_bump_navigation_revision()
		_manager.get_house_builder_work_controller().on_topology_changed()
		var elapsed_ms: int = int(round(float(Time.get_ticks_usec() - started_us) / 1000.0))
		CppDebugOptions.dlog("walkability rebuild completed in %dms (budgeted)" % elapsed_ms)
	else:
		CppDebugOptions.dlog("walkability rebuild aborted (superseded)")
	_work_gate.finish_work(token)
	if rebuild_id == _runtime_rebuild_id:
		_runtime_rebuild_active = false
		_runtime_rebuild_is_plant_layout = false
		_runtime_work_token = 0


func _apply_walkability_topology_rebuild() -> void:
	if not _navigation_topology_dirty:
		return
	clear_navigation_topology_dirty()
	# Keep the periodic scan's baseline in sync with the tiles we rebuild for so it does
	# not re-detect this mutation and rebuild again (see resync_topology_signatures).
	_manager.get_building_scan_service().resync_topology_signatures()
	_navigation_sync_service.sync_flow_extra_blocking_cells()
	_navigation_sync_service.rebuild_waterpool_directional_field()
	# Same reason as the budgeted path: refuse every approach answer from the old map
	# before the route caches below decide what is still current.
	_spawner_route_service.invalidate_spawner_approach_flows()
	_manager._rebuild_walkable_map_cache()
	_manager.get_ally_housing_controller().repath_residents()
	_manager.get_house_builder_work_controller().on_topology_changed()
	var topology: GardenTopologyService = _garden_topology
	if _plant_layout_dirty or topology.plant_zone_built():
		_manager._rebuild_plant_zone_from_layer()
	_manager._rebuild_spawner_garden_route_cache()
	var route_service: SpawnerRouteService = _spawner_route_service
	var spawners: Dictionary = _manager.get_spawners()
	for raw_spawner_cell: Variant in spawners.keys():
		var spawner_cell: Vector2i = raw_spawner_cell as Vector2i
		_manager._rebuild_spawner_plant_ff(spawner_cell)
		route_service.mark_spawner_escape_dirty(spawner_cell)
	var telemetry: BuildingDebugTelemetry = _debug_telemetry
	var exits_us: int = Time.get_ticks_usec()
	_manager._rebuild_exit_wall_escapes()
	telemetry.warn_garden_task_lag_us("_rebuild_exit_wall_escapes", Time.get_ticks_usec() - exits_us,
		"exits=%d" % route_service.exit_wall_escape_count())
	clear_plant_layout_dirty()
	_bump_navigation_revision()


# Plant placement does not change walkability. This uses the same quiet period,
# shared work token, active-state gate, and per-frame budget as wall rebuilding,
# while limiting work to garden topology and its real inbound spawner routes.
#
# Deliberately does NOT invalidate the spawner approach fields: a rose changes garden
# geometry, never the external maze, so the route cost from a spawner to a garden's
# outside neighbours is exactly what it was. Garden entry caches and inbound routes
# still refresh below (via the garden version), re-resolving against the approach
# fields that are already computed — so planting queues no approach flow and adds no
# rose-placement lag.
func _start_runtime_plant_layout_rebuild() -> void:
	if _runtime_rebuild_active:
		return
	_runtime_rebuild_active = true
	_runtime_rebuild_is_plant_layout = true
	_runtime_rebuild_id += 1
	_runtime_work_token = _work_gate.begin_work(&"runtime_plant_layout_rebuild")
	_run_runtime_plant_layout_rebuild(_runtime_work_token, _runtime_rebuild_id)


func _run_runtime_plant_layout_rebuild(token: int, rebuild_id: int) -> void:
	var started_us: int = Time.get_ticks_usec()
	CppDebugOptions.dlog("plant layout rebuild started (budgeted)")
	_runtime_rebuild_progress = 0.0
	var ok: bool = bool(await _manager._build_gardens_from_plants_budgeted(token))
	_runtime_rebuild_progress = 0.5
	if ok:
		ok = bool(await _manager._validate_gardens_budgeted(token))
	_runtime_rebuild_progress = 0.8
	if ok:
		_spawner_route_service.rebuild_spawner_garden_route_cache()
		_manager._queue_agents_after_garden_rebuild()
		clear_plant_layout_dirty()
		_bump_navigation_revision()
		_runtime_rebuild_progress = 1.0
		var elapsed_ms: int = int(round(float(Time.get_ticks_usec() - started_us) / 1000.0))
		CppDebugOptions.dlog("plant layout rebuild completed in %dms (budgeted)" % elapsed_ms)
	else:
		CppDebugOptions.dlog("plant layout rebuild aborted (superseded)")
	_work_gate.finish_work(token)
	if rebuild_id == _runtime_rebuild_id:
		_runtime_rebuild_active = false
		_runtime_rebuild_is_plant_layout = false
		_runtime_work_token = 0


func _apply_plant_layout_rebuild() -> void:
	if not _plant_layout_dirty:
		return
	_manager._rebuild_plant_zone_from_layer()
	clear_plant_layout_dirty()
	_bump_navigation_revision()


func _bump_navigation_revision() -> void:
	_navigation_revision += 1
	_spawner_route_service.prepare_upcoming_monster_routes(_navigation_revision)
	_spawner_route_service.prepare_upcoming_client_routes(_navigation_revision)
