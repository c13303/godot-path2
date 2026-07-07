extends RefCounted
class_name BuildingRuntimeTickController

# Owns BuildingManager's frame-by-frame runtime sequence. This is an extraction
# only: guard order, task order, telemetry labels, and debug context are preserved.

var _manager: BuildingManager = null


func setup(manager: BuildingManager) -> void:
	_manager = manager


func process(delta: float) -> void:
	if _manager == null:
		return
	if not _manager._flow_ready or not _manager._startup_ready:
		return
	if _manager._paused:
		_manager._sync_plant_zone_debug_visibility()
		return
	if _manager._night_preparing or _manager._client_preparing:
		_manager._sync_plant_zone_debug_visibility()
		return
	if _manager._morning_harvest.is_active():
		_manager._morning_harvest.process_walkover()
	var frame_start_us: int = Time.get_ticks_usec()
	var t: int = 0
	_manager._scan_timer -= delta
	if _manager._scan_timer <= 0.0:
		_manager._scan_timer = 0.25
		t = Time.get_ticks_usec()
		_manager._scan_buildings()
		_manager._debug_telemetry.warn_garden_task_lag_us("_scan_buildings", Time.get_ticks_usec() - t,
			"spawners=%d" % _manager._spawners.size())

	if _manager._spawner_route_service.dirty_spawner_escape_count() > 0:
		# Capture the count before the call: _drain_dirty_routes clears the dict.
		var dirty_escapes_before: int = _manager._spawner_route_service.dirty_spawner_escape_count()
		t = Time.get_ticks_usec()
		_manager._drain_dirty_routes()
		_manager._debug_telemetry.warn_garden_task_lag_us("_drain_dirty_routes", Time.get_ticks_usec() - t,
			"dirty_escapes=%d" % dirty_escapes_before)

	# Per-frame tasks: gate context construction on debug telemetry thresholds so the
	# (string-formatting) context is only built on a real spike, never every frame.
	t = Time.get_ticks_usec()
	_manager._process_eating_agents(delta)
	_manager._process_creature_rose_trampling()
	_manager._process_pasteque_trampling()
	if _manager._debug_telemetry.over_garden_threshold_us(Time.get_ticks_usec() - t):
		_manager._debug_telemetry.warn_garden_task_lag_us("_process_eating_agents", Time.get_ticks_usec() - t,
			"eating=%d astar_in=%d escaping=%d" % [
				_manager._eating_agents.size(), _manager._astar_in_agents.size(),
				_manager._escaping_agents.size()])

	t = Time.get_ticks_usec()
	_manager._turret_eating_controller.process_turret_eating_agents(delta)
	_manager._turret_eating_controller.process_turret_overlaps()
	if _manager._debug_telemetry.over_garden_threshold_us(Time.get_ticks_usec() - t):
		_manager._debug_telemetry.warn_garden_task_lag_us("_process_turrets_eaten", Time.get_ticks_usec() - t,
			"turret_eating=%d" % _manager._turret_eating_controller.turret_eating_count())

	t = Time.get_ticks_usec()
	_manager._drowning_controller.process_drowning_agents(delta)
	if _manager._debug_telemetry.over_garden_threshold_us(Time.get_ticks_usec() - t):
		_manager._debug_telemetry.warn_garden_task_lag_us("_process_drowning_agents", Time.get_ticks_usec() - t,
			"drowning=%d" % _manager._drowning_controller.drowning_count())

	t = Time.get_ticks_usec()
	_manager._process_astar_in_arrivals()
	if _manager._debug_telemetry.over_garden_threshold_us(Time.get_ticks_usec() - t):
		_manager._debug_telemetry.warn_garden_task_lag_us("_process_astar_in_arrivals", Time.get_ticks_usec() - t,
			"entry=%d astar_in=%d" % [_manager._entry_path_agents.size(), _manager._astar_in_agents.size()])

	t = Time.get_ticks_usec()
	_manager._process_plant_arrivals()
	if _manager._debug_telemetry.over_garden_threshold_us(Time.get_ticks_usec() - t):
		_manager._debug_telemetry.warn_garden_task_lag_us("_process_plant_arrivals", Time.get_ticks_usec() - t,
			"astar_in=%d eating=%d" % [_manager._astar_in_agents.size(), _manager._eating_agents.size()])

	t = Time.get_ticks_usec()
	_manager._process_client_counter_arrivals()
	_manager._client_tantrum.process(delta)
	_manager._seed_merchant.process_proximity()
	_manager._seed_merchant.process_arrival()
	if _manager._debug_telemetry.over_garden_threshold_us(Time.get_ticks_usec() - t):
		_manager._debug_telemetry.warn_garden_task_lag_us("_process_client_counter_arrivals", Time.get_ticks_usec() - t,
			"counter_agents=%d" % _manager._client_counter_agents.size())

	t = Time.get_ticks_usec()
	_manager._process_escape_arrivals()
	if _manager._debug_telemetry.over_garden_threshold_us(Time.get_ticks_usec() - t):
		_manager._debug_telemetry.warn_garden_task_lag_us("_process_escape_arrivals", Time.get_ticks_usec() - t,
			"escaping=%d" % _manager._escaping_agents.size())

	t = Time.get_ticks_usec()
	var retarget_processed: int = _manager._process_garden_retarget_queue()
	var retarget_elapsed_us: int = Time.get_ticks_usec() - t
	if _manager._debug_telemetry.over_garden_threshold_us(retarget_elapsed_us):
		_manager._debug_telemetry.warn_garden_task_lag_us("_process_garden_retarget_queue", retarget_elapsed_us,
			"processed=%d remaining=%d budget=%dms elapsed=%.1fms" % [
				retarget_processed,
				_manager._garden_retarget.queue_size(),
				int(_manager.garden_retarget_budget_ms),
				float(retarget_elapsed_us) / 1000.0,
			])

	t = Time.get_ticks_usec()
	_manager._spawn_tick_controller.process(delta, _manager._spawn_playlist_config.playlist_spawning_enabled())
	_manager._client_sale.process(delta)
	_manager._seed_merchant.process_phase()
	if _manager._debug_telemetry.over_garden_threshold_us(Time.get_ticks_usec() - t):
		# Context (incl. the per-pass count summary) only built when over threshold.
		var stats: Dictionary = _manager._spawn_tick_controller.spawn_pass_stats()
		_manager._debug_telemetry.warn_garden_task_lag_us("_process_spawners", Time.get_ticks_usec() - t,
			"spawners=%d processed=%d spawned=%d assigned=%d skipped=%d ready_remaining=%d budget_count=%d budget_ms=%.1f elapsed=%.1fms active_monsters=%d route_cache_hits=%d route_cache_misses=%d" % [
				_manager._spawners.size(),
				int(stats.get("processed_spawners", 0)),
				int(stats.get("spawned_count", 0)),
				int(stats.get("assigned_count", 0)),
				int(stats.get("skipped_count", 0)),
				int(stats.get("ready_queue_remaining", 0)),
				_manager.spawner_budget_per_frame,
				_manager.spawner_budget_ms,
				float(stats.get("elapsed_ms", 0.0)),
				int(stats.get("active_monsters", -1)),
				_manager._spawner_route_service.route_cache_hits(),
				_manager._spawner_route_service.route_cache_misses(),
			])

	t = Time.get_ticks_usec()
	_manager._sync_plant_zone_debug_visibility()
	_manager._debug_telemetry.warn_garden_task_lag_us("_sync_plant_zone_debug_visibility", Time.get_ticks_usec() - t)

	var frame_us: int = Time.get_ticks_usec() - frame_start_us
	var frame_threshold_ms: float = _manager._debug_telemetry.frame_lag_threshold_ms()
	if frame_threshold_ms > 0.0 and (float(frame_us) / 1000.0) > frame_threshold_ms:
		push_warning("debug_nav_total_frame_lag: %dms (threshold=%dms) eating=%d astar_in=%d escaping=%d retarget_queue=%d spawners=%d direct_ff_exit_success=%d direct_ff_exit_failed=%d" % [
			int(round(float(frame_us) / 1000.0)),
			int(frame_threshold_ms),
			_manager._eating_agents.size(),
			_manager._astar_in_agents.size(),
			_manager._escaping_agents.size(),
			_manager._garden_retarget.queue_size(),
			_manager._spawners.size(),
			_manager.eat_exit_direct_ff_success,
			_manager.eat_exit_direct_ff_failed
		])
