extends RefCounted
class_name BuildingRuntimeTickController

# Coordinates per-frame runtime updates for BuildingManager.
# Preserve update order and delegate gameplay algorithms to focused services.
# Do not add new gameplay algorithms here; add them to the owning service/controller.

var _manager: BuildingManager = null
# Countdown (seconds) gating the periodic building rescan cadence. Owned here because
# this controller is the sole driver of the scan tick; starts at 0.0 so the first
# eligible frame scans immediately, then resets to the 0.25s interval.
var _scan_timer: float = 0.0


func setup(manager: BuildingManager) -> void:
	_manager = manager


func process(delta: float) -> void:
	if _manager == null:
		return
	if not _manager.is_runtime_ready_for_building_tick():
		return

	if _should_skip_paused_runtime():
		_manager._sync_plant_zone_debug_visibility()
		return
	if _manager.get_morning_harvest_controller().is_active():
		_manager.get_morning_harvest_controller().process_walkover()

	var frame_start_us: int = Time.get_ticks_usec()
	var debug_telemetry: BuildingDebugTelemetry = _manager.get_building_debug_telemetry()

	# Keep scan and route drains before agent ticks so fresh topology is visible this frame.
	_process_building_scan(debug_telemetry, delta)
	_process_navigation_topology_rebuild(debug_telemetry, delta)
	# A runtime walkability rebuild may have just started (budgeted, multi-frame):
	# stop this tick immediately so no decision runs against half-rebuilt topology.
	if _manager.should_skip_building_runtime_tick():
		return
	_process_dirty_routes(debug_telemetry)
	_process_flow_request_queue(debug_telemetry)
	_process_agent_runtime(debug_telemetry, delta)
	# Retargeting stays after arrivals/escapes and before spawn/client phase ticks.
	_process_retarget_runtime(debug_telemetry)
	_process_phase_runtime(debug_telemetry, delta)
	_process_debug_runtime(debug_telemetry)
	_warn_total_frame_lag(debug_telemetry, frame_start_us)


func _should_skip_paused_runtime() -> bool:
	return _manager.should_skip_building_runtime_tick()


func _process_building_scan(debug_telemetry: BuildingDebugTelemetry, delta: float) -> void:
	_scan_timer -= delta
	if _scan_timer <= 0.0:
		_scan_timer = 0.25
		var t: int = Time.get_ticks_usec()
		_manager._scan_buildings()
		debug_telemetry.warn_garden_task_lag_us("_scan_buildings", Time.get_ticks_usec() - t,
			"spawners=%d" % _manager.get_spawners().size())


func _process_dirty_routes(debug_telemetry: BuildingDebugTelemetry) -> void:
	var spawner_route_service: SpawnerRouteService = _manager.get_spawner_route_service()
	if spawner_route_service.dirty_spawner_escape_count() > 0:
		# Capture the count before the call: _drain_dirty_routes clears the dict.
		var dirty_escapes_before: int = spawner_route_service.dirty_spawner_escape_count()
		var t: int = Time.get_ticks_usec()
		_manager._drain_dirty_routes()
		debug_telemetry.warn_garden_task_lag_us("_drain_dirty_routes", Time.get_ticks_usec() - t,
			"dirty_escapes=%d" % dirty_escapes_before)


func _process_navigation_topology_rebuild(debug_telemetry: BuildingDebugTelemetry, delta: float) -> void:
	var t: int = Time.get_ticks_usec()
	_manager.get_building_invalidation_controller().apply_navigation_topology_rebuild(delta)
	debug_telemetry.warn_garden_task_lag_us("_apply_navigation_topology_rebuild", Time.get_ticks_usec() - t)


func _process_flow_request_queue(debug_telemetry: BuildingDebugTelemetry) -> void:
	var spawner_route_service: SpawnerRouteService = _manager.get_spawner_route_service()
	if spawner_route_service.queued_flow_request_count() <= 0:
		return
	var queued_before: int = spawner_route_service.queued_flow_request_count()
	var t: int = Time.get_ticks_usec()
	var processed: int = spawner_route_service.process_queued_flow_requests(1, _manager._night_preparation_budget_us())
	debug_telemetry.warn_garden_task_lag_us("_process_flow_request_queue", Time.get_ticks_usec() - t,
		"processed=%d queued_before=%d queued_after=%d" % [
			processed,
			queued_before,
			spawner_route_service.queued_flow_request_count(),
		])


func _process_agent_runtime(debug_telemetry: BuildingDebugTelemetry, delta: float) -> void:
	# Per-frame tasks: gate context construction on debug telemetry thresholds so the
	# (string-formatting) context is only built on a real spike, never every frame.
	var t: int = Time.get_ticks_usec()
	_manager._process_eating_agents(delta)
	if debug_telemetry.over_garden_threshold_us(Time.get_ticks_usec() - t):
		debug_telemetry.warn_garden_task_lag_us("_process_eating_agents", Time.get_ticks_usec() - t,
			"eating=%d astar_in=%d escaping=%d" % [
				_manager.eating_agent_count(), _manager.astar_in_agent_count(),
				_manager.escaping_agent_count()])

	# Turret-eating timeline first so the turret-eating set is fresh before the tile
	# pass evaluates turret overlaps (preserves the old scan order).
	t = Time.get_ticks_usec()
	_manager.get_turret_eating_controller().process_turret_eating_agents(delta)
	if debug_telemetry.over_garden_threshold_us(Time.get_ticks_usec() - t):
		debug_telemetry.warn_garden_task_lag_us("_process_turrets_eaten", Time.get_ticks_usec() - t,
			"turret_eating=%d" % _manager.get_turret_eating_controller().turret_eating_count())

	# One lightweight cell-transition pass replacing the four per-frame full-agent
	# scans (drowning start + splash, turret overlap, rose/pasteque trampling).
	t = Time.get_ticks_usec()
	var tracker: AgentCellTracker = _manager.get_agent_cell_tracker()
	tracker.process(delta)
	if debug_telemetry.over_garden_threshold_us(Time.get_ticks_usec() - t):
		var stats: Dictionary = tracker.debug_stats()
		debug_telemetry.warn_garden_task_lag_us("_process_agent_tile_interactions", Time.get_ticks_usec() - t,
			"registered=%d pending_general=%d transitions=%d checked=%d invalidations=%d water_candidates=%d continuous_water=%d state_exit_rechecks=%d stale_water_removed=%d rose=%d pasteque=%d turret=%d drowning=%d" % [
				int(stats.get("registered", 0)), int(stats.get("pending_general_checks", 0)),
				int(stats.get("transitions", 0)), int(stats.get("checked", 0)),
				int(stats.get("invalidations", 0)), int(stats.get("water_candidates", 0)),
				int(stats.get("continuous_water_checks", 0)), int(stats.get("state_exit_rechecks", 0)),
				int(stats.get("stale_water_candidates_removed", 0)), int(stats.get("rose", 0)),
				int(stats.get("pasteque", 0)), int(stats.get("turret", 0)),
				int(stats.get("drowning", 0))])

	# Drowning damage timeline after the tile pass so an agent that started drowning
	# this frame still gets its first timeline tick this frame (matches old order).
	t = Time.get_ticks_usec()
	_manager.get_drowning_controller().process_drowning_timeline(delta)
	_manager.get_sheep_controller().process(delta)
	if debug_telemetry.over_garden_threshold_us(Time.get_ticks_usec() - t):
		debug_telemetry.warn_garden_task_lag_us("_process_drowning_agents", Time.get_ticks_usec() - t,
			"drowning=%d" % _manager.get_drowning_controller().drowning_count())

	t = Time.get_ticks_usec()
	_manager.get_agent_navigation_phase_controller().process_waiting_entry_flows()
	if debug_telemetry.over_garden_threshold_us(Time.get_ticks_usec() - t):
		debug_telemetry.warn_garden_task_lag_us("_process_waiting_entry_flows", Time.get_ticks_usec() - t,
			"waiting=%d" % _manager.get_agent_navigation_phase_controller().waiting_entry_flow_count())

	t = Time.get_ticks_usec()
	_manager._process_astar_in_arrivals()
	if debug_telemetry.over_garden_threshold_us(Time.get_ticks_usec() - t):
		debug_telemetry.warn_garden_task_lag_us("_process_astar_in_arrivals", Time.get_ticks_usec() - t,
			"entry=%d astar_in=%d" % [_manager.entry_path_agent_count(), _manager.astar_in_agent_count()])

	t = Time.get_ticks_usec()
	_manager._process_plant_arrivals()
	if debug_telemetry.over_garden_threshold_us(Time.get_ticks_usec() - t):
		debug_telemetry.warn_garden_task_lag_us("_process_plant_arrivals", Time.get_ticks_usec() - t,
			"astar_in=%d eating=%d" % [_manager.astar_in_agent_count(), _manager.eating_agent_count()])

	t = Time.get_ticks_usec()
	_manager._process_client_counter_arrivals()
	_manager.get_client_tantrum_controller().process(delta)
	_manager.get_seed_merchant_controller().process_proximity()
	_manager.get_seed_merchant_controller().process_arrival()
	if debug_telemetry.over_garden_threshold_us(Time.get_ticks_usec() - t):
		debug_telemetry.warn_garden_task_lag_us("_process_client_counter_arrivals", Time.get_ticks_usec() - t,
			"counter_agents=%d" % _manager.client_counter_agents().size())

	t = Time.get_ticks_usec()
	_manager._process_escape_arrivals()
	if debug_telemetry.over_garden_threshold_us(Time.get_ticks_usec() - t):
		debug_telemetry.warn_garden_task_lag_us("_process_escape_arrivals", Time.get_ticks_usec() - t,
			"escaping=%d" % _manager.escaping_agent_count())


func _process_retarget_runtime(debug_telemetry: BuildingDebugTelemetry) -> void:
	var t: int = Time.get_ticks_usec()
	var retarget_processed: int = _manager._process_garden_retarget_queue()
	var retarget_elapsed_us: int = Time.get_ticks_usec() - t
	if debug_telemetry.over_garden_threshold_us(retarget_elapsed_us):
		debug_telemetry.warn_garden_task_lag_us("_process_garden_retarget_queue", retarget_elapsed_us,
			"processed=%d remaining=%d budget=%dms elapsed=%.1fms" % [
				retarget_processed,
				_manager.garden_retarget_queue_size(),
				int(_manager.garden_retarget_budget_ms),
				float(retarget_elapsed_us) / 1000.0,
			])


func _process_phase_runtime(debug_telemetry: BuildingDebugTelemetry, delta: float) -> void:
	var t: int = Time.get_ticks_usec()
	var spawn_playlist_config: SpawnPlaylistConfigService = _manager.get_spawn_playlist_config()
	var spawn_started_us: int = Time.get_ticks_usec()
	_manager.get_spawn_tick_controller().process(delta, spawn_playlist_config.playlist_spawning_enabled())
	var spawn_elapsed_us: int = Time.get_ticks_usec() - spawn_started_us
	var client_sale_started_us: int = Time.get_ticks_usec()
	_manager.get_client_sale_controller().process(delta)
	var client_sale_elapsed_us: int = Time.get_ticks_usec() - client_sale_started_us
	var merchant_started_us: int = Time.get_ticks_usec()
	_manager.get_seed_merchant_controller().process_phase()
	var merchant_elapsed_us: int = Time.get_ticks_usec() - merchant_started_us
	if debug_telemetry.over_garden_threshold_us(Time.get_ticks_usec() - t):
		# Context (incl. the per-pass count summary) only built when over threshold.
		var stats: Dictionary = _manager.get_spawn_tick_controller().spawn_pass_stats()
		var spawner_route_service: SpawnerRouteService = _manager.get_spawner_route_service()
		debug_telemetry.warn_garden_task_lag_us("_process_phase_runtime", Time.get_ticks_usec() - t,
			"spawn=%.1fms client_sale=%.1fms merchant=%.1fms spawners=%d processed=%d spawned=%d assigned=%d skipped=%d ready_remaining=%d budget_count=%d budget_ms=%.1f elapsed=%.1fms active_monsters=%d route_cache_hits=%d route_cache_misses=%d" % [
				float(spawn_elapsed_us) / 1000.0,
				float(client_sale_elapsed_us) / 1000.0,
				float(merchant_elapsed_us) / 1000.0,
				_manager.get_spawners().size(),
				int(stats.get("processed_spawners", 0)),
				int(stats.get("spawned_count", 0)),
				int(stats.get("assigned_count", 0)),
				int(stats.get("skipped_count", 0)),
				int(stats.get("ready_queue_remaining", 0)),
				_manager.spawner_budget_per_frame,
				_manager.spawner_budget_ms,
				float(stats.get("elapsed_ms", 0.0)),
				int(stats.get("active_monsters", -1)),
				spawner_route_service.route_cache_hits(),
				spawner_route_service.route_cache_misses(),
			])


func _process_debug_runtime(debug_telemetry: BuildingDebugTelemetry) -> void:
	var t: int = Time.get_ticks_usec()
	_manager._sync_plant_zone_debug_visibility()
	debug_telemetry.warn_garden_task_lag_us("_sync_plant_zone_debug_visibility", Time.get_ticks_usec() - t)


func _warn_total_frame_lag(debug_telemetry: BuildingDebugTelemetry, frame_start_us: int) -> void:
	var frame_us: int = Time.get_ticks_usec() - frame_start_us
	var frame_threshold_ms: float = debug_telemetry.frame_lag_threshold_ms()
	if frame_threshold_ms > 0.0 and (float(frame_us) / 1000.0) > frame_threshold_ms:
		push_warning("debug_nav_total_frame_lag: %dms (threshold=%dms) eating=%d astar_in=%d escaping=%d retarget_queue=%d spawners=%d direct_ff_exit_success=%d direct_ff_exit_failed=%d" % [
			int(round(float(frame_us) / 1000.0)),
			int(frame_threshold_ms),
			_manager.eating_agent_count(),
			_manager.astar_in_agent_count(),
			_manager.escaping_agent_count(),
			_manager.garden_retarget_queue_size(),
			_manager.get_spawners().size(),
			_manager.eat_exit_direct_ff_success,
			_manager.eat_exit_direct_ff_failed
		])
