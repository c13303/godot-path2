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
var _garden_topology: GardenTopologyService
var _spawner_route_service: SpawnerRouteService
var _debug_telemetry: BuildingDebugTelemetry
var _navigation_topology_dirty: bool = true
var _plant_layout_dirty: bool = false
var _walkability_quiet_seconds_remaining: float = 0.0

const WALKABILITY_REBUILD_QUIET_SECONDS: float = 0.15


func setup(manager: BuildingManager) -> void:
	_manager = manager
	_garden_topology = manager.get_garden_topology_service()
	_spawner_route_service = manager.get_spawner_route_service()
	_debug_telemetry = manager.get_building_debug_telemetry()


func mark_navigation_topology_dirty() -> void:
	_navigation_topology_dirty = true
	_walkability_quiet_seconds_remaining = WALKABILITY_REBUILD_QUIET_SECONDS


func clear_navigation_topology_dirty() -> void:
	_navigation_topology_dirty = false
	_walkability_quiet_seconds_remaining = 0.0


func mark_plant_layout_dirty() -> void:
	_plant_layout_dirty = true


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


func mark_after_counter_stock_restored() -> void:
	_garden_topology.counter_access_cells().clear()
	_garden_topology.set_plant_zone_built(false)
	mark_plant_layout_dirty()


# A plant was added/removed during the day (or while no runtime agents are active).
# Invalidates the built plant-zone snapshot, marks navigation topology dirty, and
# refreshes the zone overlay. Matches the old inline sequence in _on_plant_added /
# _on_plant_removed exactly (set_plant_zone_built -> dirty -> overlay redraw).
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
	if _navigation_topology_dirty and delta > 0.0:
		_walkability_quiet_seconds_remaining = maxf(0.0, _walkability_quiet_seconds_remaining - delta)
		if _walkability_quiet_seconds_remaining > 0.0:
			return
	if _navigation_topology_dirty:
		_apply_walkability_topology_rebuild()
	elif _plant_layout_dirty and delta <= 0.0:
		_apply_plant_layout_rebuild()


func _apply_walkability_topology_rebuild() -> void:
	if not _navigation_topology_dirty:
		return
	clear_navigation_topology_dirty()
	clear_plant_layout_dirty()
	_manager._sync_flow_extra_blocking_cells()
	_manager._rebuild_waterpool_directional_field()
	_manager._rebuild_walkable_map_cache()
	_manager.get_seed_merchant_controller().repath_for_walkability_change()
	var topology: GardenTopologyService = _garden_topology
	if topology.plant_zone_built():
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


func _apply_plant_layout_rebuild() -> void:
	if not _plant_layout_dirty:
		return
	clear_plant_layout_dirty()
	_manager._rebuild_walkable_map_cache()
	var topology: GardenTopologyService = _garden_topology
	if topology.plant_zone_built():
		_manager._rebuild_plant_zone_from_layer()
