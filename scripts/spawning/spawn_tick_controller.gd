extends RefCounted
class_name SpawnTickController

# Owns the per-frame spawn tick: each night it runs playlist-driven spawning,
# drains the ready-spawner queue under a frame
# budget, and tracks the per-pass telemetry the manager's lag warning consumes.
# Mirrors the other manager-owned controllers (SeedMerchantController, etc.): it
# holds a back-reference to BuildingManager and delegates the spawn primitives,
# spawner-registry reads and spawn-failure reporting back to the manager, while
# lag thresholds/output go through BuildingDebugTelemetry. It owns only its
# tick-local state (the ready queue, the empty-night timer and the pass stats);
# the playlist-enabled decision stays in the manager.

const EMPTY_NIGHT_DAY_DELAY_SECONDS: float = 3.0
const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)

var _manager: BuildingManager
var _debug_telemetry: BuildingDebugTelemetry

# Ready playlist spawn requests awaiting a spawn slot this/next frame.
var _ready_spawner_queue: Array[Dictionary] = []
var _ready_spawner_queue_set: Dictionary = {}  # playlist track index -> true

# Seconds the current night has had zero monsters with no plants; flips back to day
# once it passes EMPTY_NIGHT_DAY_DELAY_SECONDS.
var _empty_night_elapsed: float = 0.0

# Per-pass count summary consumed by the manager's lag warning at the call site.
var _spawn_pass_stats: Dictionary = {}


func setup(manager: BuildingManager) -> void:
	_manager = manager
	_debug_telemetry = _manager._debug_telemetry


func spawn_pass_stats() -> Dictionary:
	return _spawn_pass_stats


func increment_assigned_count() -> void:
	_spawn_pass_stats["assigned_count"] = int(_spawn_pass_stats.get("assigned_count", 0)) + 1


func reset_empty_night() -> void:
	_empty_night_elapsed = 0.0


func clear_ready_queue() -> void:
	_ready_spawner_queue.clear()
	_ready_spawner_queue_set.clear()


func serialize_state() -> Dictionary:
	var ready_queue: Array[Dictionary] = []
	for raw_request: Variant in _ready_spawner_queue:
		if raw_request is Dictionary:
			var request: Dictionary = raw_request as Dictionary
			var cell: Vector2i = request.get("spawner_cell", INVALID_CELL) as Vector2i
			ready_queue.append({
				"track_index": int(request.get("track_index", -1)),
				"spawner_id": String(request.get("spawner_id", "")),
				"spawner_cell": {"x": cell.x, "y": cell.y},
				"monster_type": String(request.get("monster_type", "basic")),
				"night_index": int(request.get("night_index", -1)),
				"wave_index": int(request.get("wave_index", 0)),
			})
	return {
		"ready_queue": ready_queue,
		"empty_night_elapsed": _empty_night_elapsed,
	}


func restore_state(data: Dictionary) -> void:
	clear_ready_queue()
	var raw_ready_queue: Variant = data.get("ready_queue", [])
	if raw_ready_queue is Array:
		for raw_request: Variant in raw_ready_queue as Array:
			if not (raw_request is Dictionary):
				continue
			var request: Dictionary = raw_request as Dictionary
			var cell: Vector2i = _cell_from_dict(request.get("spawner_cell", {}))
			var track_index: int = int(request.get("track_index", -1))
			if track_index < 0:
				continue
			_ready_spawner_queue.append({
				"track_index": track_index,
				"spawner_id": StringName(str(request.get("spawner_id", ""))),
				"spawner_cell": cell,
				"monster_type": StringName(str(request.get("monster_type", "basic"))),
				"night_index": int(request.get("night_index", -1)),
				"wave_index": int(request.get("wave_index", 0)),
			})
			_ready_spawner_queue_set[track_index] = true
	_empty_night_elapsed = maxf(0.0, float(data.get("empty_night_elapsed", 0.0)))


func _cell_from_dict(raw_value: Variant) -> Vector2i:
	if raw_value is Dictionary:
		var data: Dictionary = raw_value as Dictionary
		return Vector2i(int(data.get("x", 0)), int(data.get("y", 0)))
	return INVALID_CELL


func process(delta: float, playlist_enabled: bool) -> void:
	# Reset the per-pass count summary consumed by the parent lag warning. Cheap;
	# always done so the caller never reads a stale dictionary.
	_spawn_pass_stats = {
		"processed_spawners": 0,
		"spawned_count": 0,
		"assigned_count": 0,
		"skipped_count": 0,
		"active_monsters": -1,
		"ready_queue_remaining": 0,
		"elapsed_ms": 0.0,
	}

	# Day/night gating: monsters only spawn at night. When the last monster of the
	# night is gone, the spawn passes flip back to day.
	if not GameState.is_night:
		return
	if not _manager._night_preparation_ready:
		return
	if _manager.is_night_start_cutscene_active():
		if playlist_enabled:
			_process_revealed_playlist_spawners(delta)
		return
	var t_mc: int = Time.get_ticks_usec()
	var mc: int = _manager._monster_count()
	_warn_garden_task_lag_us("_process_spawners.monster_count", Time.get_ticks_usec() - t_mc)
	_spawn_pass_stats["active_monsters"] = mc
	if playlist_enabled:
		_process_playlist_spawners(delta, mc)
		return
	# Invalid/missing playlists must fail loudly at night start and must not fall
	# through to any generated monster schedule.


func _process_playlist_spawners(delta: float, active_monsters: int) -> void:
	var playlist: SpawnPlaylistController = _manager._spawn_playlist_controller
	if playlist.is_current_night_schedule_complete():
		if active_monsters == 0:
			GameState.start_day()
		return
	var t_np: int = Time.get_ticks_usec()
	var no_plants: bool = _manager._no_plants_remaining()
	_warn_garden_task_lag_us("_process_spawners.no_plants_remaining", Time.get_ticks_usec() - t_np)
	if no_plants:
		if active_monsters == 0:
			_empty_night_elapsed += delta
			if _empty_night_elapsed >= EMPTY_NIGHT_DAY_DELAY_SECONDS:
				_log("Playlist night stalled because no plants remain; leaving schedule unfinished.")
				GameState.start_day()
				return
		else:
			_empty_night_elapsed = 0.0
		if _manager.debug_logs and not _manager._spawners.is_empty():
			_log("no plants remaining for playlist spawners")
		return
	_empty_night_elapsed = 0.0
	_enqueue_playlist_spawn_requests(delta)
	_drain_ready_spawner_queue_budgeted()


func _process_revealed_playlist_spawners(delta: float) -> void:
	var released_track_indices: Dictionary = _manager.released_night_reveal_track_indices()
	if released_track_indices.is_empty():
		return
	var t_mc: int = Time.get_ticks_usec()
	var mc: int = _manager._monster_count()
	_warn_garden_task_lag_us("_process_spawners.monster_count", Time.get_ticks_usec() - t_mc)
	_spawn_pass_stats["active_monsters"] = mc
	var t_np: int = Time.get_ticks_usec()
	var no_plants: bool = _manager._no_plants_remaining()
	_warn_garden_task_lag_us("_process_spawners.no_plants_remaining", Time.get_ticks_usec() - t_np)
	if no_plants:
		return
	_enqueue_playlist_spawn_requests(delta, released_track_indices, true)
	_drain_ready_spawner_queue_budgeted(released_track_indices, true)


func clear_legacy_fallback() -> void:
	# Kept as a compatibility no-op for manager/save-load call sites. Legacy spawning
	# is intentionally disabled: invalid playlists must report errors, not spawn.
	pass


func _enqueue_playlist_spawn_requests(delta: float, allowed_track_indices: Dictionary = {}, restrict_to_allowed: bool = false) -> void:
	var playlist: SpawnPlaylistController = _manager._spawn_playlist_controller
	var requests: Array[Dictionary] = playlist.advance(delta, allowed_track_indices, restrict_to_allowed)
	for request: Dictionary in requests:
		var track_index: int = int(request.get("track_index", -1))
		if track_index < 0:
			continue
		if _ready_spawner_queue_set.has(track_index):
			continue
		_ready_spawner_queue.append(request)
		_ready_spawner_queue_set[track_index] = true


# Spawn from at most spawner_budget_per_frame ready playlist requests (and, if a
# time budget is set, stop early once we exceed it — but always do at least one so
# the queue drains). Remaining ready spawners are processed on following frames.
func _drain_ready_spawner_queue_budgeted(allowed_track_indices: Dictionary = {}, restrict_to_allowed: bool = false) -> void:
	var start_us: int = Time.get_ticks_usec()
	var budget_us: int = int(_manager.spawner_budget_ms * 1000.0)
	var budget_per_frame: int = _manager.spawner_budget_per_frame
	var spawners: Dictionary = _manager._spawners
	var processed: int = 0
	var blocked_requests: Array[Dictionary] = []

	while not _ready_spawner_queue.is_empty():
		if processed >= budget_per_frame:
			break
		# Time budget only applies after the first spawn this frame, so a single
		# expensive spawner can't starve the queue entirely.
		if processed > 0 and budget_us > 0:
			if Time.get_ticks_usec() - start_us >= budget_us:
				break

		var request: Dictionary = _ready_spawner_queue.pop_front()
		var track_index: int = int(request.get("track_index", -1))
		if restrict_to_allowed and not allowed_track_indices.has(track_index):
			blocked_requests.append(request)
			continue
		var cell: Vector2i = request.get("spawner_cell", INVALID_CELL) as Vector2i
		_ready_spawner_queue_set.erase(track_index)
		# A spawner may have been removed (rescan) while queued; skip stale entries
		# without counting them against the budget.
		if not spawners.has(cell):
			_manager._report_playlist_spawn_result(request, false, "physical spawner cell is missing")
			continue

		var spawner_us: int = Time.get_ticks_usec()
		_spawn_pass_stats["processed_spawners"] = int(_spawn_pass_stats["processed_spawners"]) + 1
		processed += 1

		var monster_type: StringName = StringName(str(request.get("monster_type", "basic")))
		var spawned: bool = _manager._spawn_monster_from(cell, monster_type)
		if spawned:
			_spawn_pass_stats["spawned_count"] = int(_spawn_pass_stats["spawned_count"]) + 1
			_manager._report_playlist_spawn_result(request, true)
		else:
			_manager._report_playlist_spawn_result(request, false, _manager.last_spawn_failure())

		# Whole spawner iteration. Build the (small) context only when over threshold.
		var spawner_elapsed_us: int = Time.get_ticks_usec() - spawner_us
		if _over_garden_threshold_us(spawner_elapsed_us):
			_warn_garden_task_lag_us("_process_spawners.spawner_total", spawner_elapsed_us,
				"spawner_cell=%s spawned=%s" % [str(cell), str(spawned)])

	for index: int in range(blocked_requests.size() - 1, -1, -1):
		_ready_spawner_queue.push_front(blocked_requests[index])
	_spawn_pass_stats["ready_queue_remaining"] = _ready_spawner_queue.size()
	_spawn_pass_stats["elapsed_ms"] = float(Time.get_ticks_usec() - start_us) / 1000.0


func _warn_garden_task_lag_us(task_name: String, elapsed_us: int, extra: String = "") -> void:
	if _debug_telemetry == null:
		return
	_debug_telemetry.warn_garden_task_lag_us(task_name, elapsed_us, extra)


func _over_garden_threshold_us(elapsed_us: int) -> bool:
	if _debug_telemetry == null:
		return false
	return _debug_telemetry.over_garden_threshold_us(elapsed_us)


func _log(message: String) -> void:
	if _debug_telemetry == null:
		return
	_debug_telemetry.log(message)
