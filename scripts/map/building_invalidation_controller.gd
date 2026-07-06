extends RefCounted
class_name BuildingInvalidationController

# Owns the "something changed on the map/building layer, now dependent systems must
# be marked dirty or rebuilt" orchestration extracted from BuildingManager. This
# controller only sequences invalidation / dirty-marking / follow-up refreshes; it
# never performs the underlying gameplay mutation (placement, removal, inventory,
# refunds). BuildingManager keeps the source-of-truth state (the dirty flag, the
# owned services) and thin compatibility wrappers; this reaches back through
# _manager for all of it.
#
# Behavior note: this is an extraction only. The order of every invalidation call,
# the dirty flags touched, the cache-clear timing, and the debug/telemetry strings
# are preserved exactly as they were inline in BuildingManager.

var _manager: Node


func setup(manager: Node) -> void:
	_manager = manager


# A wall / blocking-building change altered map walkability (which cells block
# movement / flow). Only a lightweight mark: the actual rebuild happens later when
# apply_navigation_topology_rebuild() consumes the dirty flag.
func after_walkability_changed(_reason: String = "") -> void:
	_manager.set("_navigation_topology_dirty", true)


# A plant was added/removed during the day (or while no runtime agents are active).
# Invalidates the built plant-zone snapshot, marks navigation topology dirty, and
# refreshes the zone overlay. Matches the old inline sequence in _on_plant_added /
# _on_plant_removed exactly (set_plant_zone_built -> dirty -> overlay redraw).
func after_plant_layout_changed(_reason: String = "") -> void:
	var topology: Variant = _manager.get("_garden_topology")
	topology.set_plant_zone_built(false)
	_manager.set("_navigation_topology_dirty", true)
	var overlay: Node2D = _manager.get("_zone_overlay") as Node2D
	if overlay:
		overlay.queue_redraw()


# Consumes a pending navigation-topology dirty mark: re-syncs flow blocking cells,
# rebuilds the walkable map + (if built) the plant zone, refreshes spawner/garden
# route caches, re-plans per-spawner plant flow fields, marks spawner escapes dirty,
# and rebuilds the exit-wall escape fields (with the same telemetry span). No-op when
# nothing is dirty. Preserves the exact order the sequence had inline.
func apply_navigation_topology_rebuild() -> void:
	if not bool(_manager.get("_navigation_topology_dirty")):
		return
	_manager.set("_navigation_topology_dirty", false)
	_manager.call("_sync_flow_extra_blocking_cells")
	_manager.call("_rebuild_waterpool_directional_field")
	_manager.call("_rebuild_walkable_map_cache")
	var topology: Variant = _manager.get("_garden_topology")
	if topology.plant_zone_built():
		_manager.call("_rebuild_plant_zone_from_layer")
	_manager.call("_rebuild_spawner_garden_route_cache")
	var route_service: Variant = _manager.get("_spawner_route_service")
	var spawners: Dictionary = _manager.get("_spawners")
	for raw_spawner_cell: Variant in spawners.keys():
		var spawner_cell: Vector2i = raw_spawner_cell as Vector2i
		_manager.call("_rebuild_spawner_plant_ff", spawner_cell)
		route_service.mark_spawner_escape_dirty(spawner_cell)
	var telemetry: Variant = _manager.get("_debug_telemetry")
	var exits_us: int = Time.get_ticks_usec()
	_manager.call("_rebuild_exit_wall_escapes")
	telemetry.warn_garden_task_lag_us("_rebuild_exit_wall_escapes", Time.get_ticks_usec() - exits_us,
		"exits=%d" % route_service.exit_wall_escape_count())
