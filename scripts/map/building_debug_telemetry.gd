extends RefCounted
class_name BuildingDebugTelemetry

# Owns BuildingManager's debug logging and lag-warning thresholds. It deliberately
# keeps only instrumentation state; gameplay systems stay in BuildingManager.

const SPAWN_FAILURE_WARN_INTERVAL_MS: int = 3000
const DEBUG_PLANTFF_FRAME_LAG_MS_FALLBACK: float = 100.0
const DEBUG_PLANTFF_FF_LAG_MS_FALLBACK: float = 10.0
const DEBUG_GARDENS_LAG_MS_FALLBACK: float = 15.0

var _manager: BuildingManager
var _cpp_debug_options: Node = null
var _cached_global_config: Node = null
var _last_scan_summary: String = ""
var _last_spawn_failure: String = ""
var _last_spawn_failure_at_ms: Dictionary = {}
var _garden_astar_batch: Dictionary = {}
var _garden_astar_flush_queued: bool = false


func setup(manager: BuildingManager) -> void:
	_manager = manager
	_cached_global_config = manager.global_config


func frame_lag_threshold_ms() -> float:
	if _debug_master_disabled():
		return 0.0
	var global_config: Node = _global_config()
	if global_config and global_config.has_method("get_debug_nav_frame_lag_ms"):
		var nav_frame_lag: Variant = global_config.call("get_debug_nav_frame_lag_ms")
		return float(nav_frame_lag)
	if global_config and global_config.has_method("get_debug_plantff_frame_lag_ms"):
		var plantff_frame_lag: Variant = global_config.call("get_debug_plantff_frame_lag_ms")
		return float(plantff_frame_lag)
	return DEBUG_PLANTFF_FRAME_LAG_MS_FALLBACK


func ff_lag_threshold_ms() -> float:
	if _debug_master_disabled():
		return 0.0
	var global_config: Node = _global_config()
	if global_config and global_config.has_method("get_debug_flowfield_rebuild_lag_ms"):
		var flowfield_lag: Variant = global_config.call("get_debug_flowfield_rebuild_lag_ms")
		return float(flowfield_lag)
	if global_config and global_config.has_method("get_debug_plantff_ff_lag_ms"):
		var plantff_lag: Variant = global_config.call("get_debug_plantff_ff_lag_ms")
		return float(plantff_lag)
	return DEBUG_PLANTFF_FF_LAG_MS_FALLBACK


func garden_lag_threshold_ms() -> float:
	# Master gate: when "Debug Enabled" is off on the CPP node, suppress the
	# per-task garden-lag warnings entirely (0 = detector disabled).
	if _debug_master_disabled():
		return 0.0
	if _cpp_debug_options == null:
		_cpp_debug_options = _find_cpp_debug_options()
	if _cpp_debug_options and "debug_gardens_lag_ms" in _cpp_debug_options:
		return float(_cpp_debug_options.get("debug_gardens_lag_ms"))
	return DEBUG_GARDENS_LAG_MS_FALLBACK


func warn_garden_task_lag_us(task_name: String, elapsed_us: int, extra: String = "") -> void:
	var threshold_ms: float = garden_lag_threshold_ms()
	if threshold_ms <= 0.0:
		return
	var elapsed_ms: float = float(elapsed_us) / 1000.0
	if elapsed_ms <= threshold_ms:
		return
	var suffix: String = ""
	if extra != "":
		suffix = " " + extra
	push_warning("debug_garden_lag:%s %dms (threshold=%dms)%s" % [
		task_name,
		int(round(elapsed_ms)),
		int(threshold_ms),
		suffix
	])


func over_garden_threshold_us(elapsed_us: int) -> bool:
	var threshold_ms: float = garden_lag_threshold_ms()
	if threshold_ms <= 0.0:
		return false
	return (float(elapsed_us) / 1000.0) > threshold_ms


# Garden A* queries are synchronous and can arrive in a burst when several agents reach
# an entry together. Count every native computation, but emit one compact line per frame
# so enabling diagnostics does not add one print call per agent.
func record_garden_astar(
	garden_id: int,
	from_tile: Vector2i,
	to_tile: Vector2i,
	zone_tiles: int,
	path_length: int,
	total_us: int,
	sync_us: int,
	blocker_us: int,
	find_us: int
) -> void:
	if _debug_master_disabled():
		return
	if _garden_astar_batch.is_empty():
		_garden_astar_batch = {
			"frame": Engine.get_process_frames(),
			"count": 0,
			"total_us": 0,
			"sync_us": 0,
			"blocker_us": 0,
			"find_us": 0,
			"empty_paths": 0,
			"max_total_us": 0,
			"max_garden_id": 0,
			"max_from": Vector2i.ZERO,
			"max_to": Vector2i.ZERO,
			"max_path_length": 0,
			"max_zone_tiles": 0,
			"garden_counts": {},
		}
	var batch: Dictionary = _garden_astar_batch
	batch["count"] = int(batch.get("count", 0)) + 1
	batch["total_us"] = int(batch.get("total_us", 0)) + total_us
	batch["sync_us"] = int(batch.get("sync_us", 0)) + sync_us
	batch["blocker_us"] = int(batch.get("blocker_us", 0)) + blocker_us
	batch["find_us"] = int(batch.get("find_us", 0)) + find_us
	if path_length <= 0:
		batch["empty_paths"] = int(batch.get("empty_paths", 0)) + 1
	if total_us > int(batch.get("max_total_us", 0)):
		batch["max_total_us"] = total_us
		batch["max_garden_id"] = garden_id
		batch["max_from"] = from_tile
		batch["max_to"] = to_tile
		batch["max_path_length"] = path_length
	batch["max_zone_tiles"] = maxi(int(batch.get("max_zone_tiles", 0)), zone_tiles)
	var garden_counts: Dictionary = batch.get("garden_counts", {}) as Dictionary
	garden_counts[garden_id] = int(garden_counts.get(garden_id, 0)) + 1
	batch["garden_counts"] = garden_counts
	_garden_astar_batch = batch
	_queue_garden_astar_flush()


func _queue_garden_astar_flush() -> void:
	if _garden_astar_flush_queued:
		return
	if _manager == null or not _manager.is_inside_tree():
		_flush_garden_astar_batch()
		return
	_garden_astar_flush_queued = true
	_manager.get_tree().process_frame.connect(Callable(self, "_flush_garden_astar_batch"), Object.CONNECT_ONE_SHOT)


func _flush_garden_astar_batch() -> void:
	_garden_astar_flush_queued = false
	if _garden_astar_batch.is_empty():
		return
	var batch: Dictionary = _garden_astar_batch
	_garden_astar_batch = {}
	if _debug_master_disabled():
		return
	CppDebugOptions.dlog("%d garden A* path(s) computed in frame %d! Time: %.1fms (sync=%.1fms, blockers=%.1fms subset, native_astar=%.1fms, empty=%d, gardens=%s, max=%.1fms garden=%d from=%s to=%s path_len=%d, max_zone_tiles=%d)" % [
		int(batch.get("count", 0)),
		int(batch.get("frame", 0)),
		float(batch.get("total_us", 0)) / 1000.0,
		float(batch.get("sync_us", 0)) / 1000.0,
		float(batch.get("blocker_us", 0)) / 1000.0,
		float(batch.get("find_us", 0)) / 1000.0,
		int(batch.get("empty_paths", 0)),
		str(batch.get("garden_counts", {})),
		float(batch.get("max_total_us", 0)) / 1000.0,
		int(batch.get("max_garden_id", 0)),
		str(batch.get("max_from", Vector2i.ZERO)),
		str(batch.get("max_to", Vector2i.ZERO)),
		int(batch.get("max_path_length", 0)),
		int(batch.get("max_zone_tiles", 0)),
	])


func log(message: String) -> void:
	if _manager != null and _manager.debug_logs and CppDebugOptions.logs_enabled:
		print("BuildingManager: ", message)


func log_spawn_failure(message: String) -> void:
	var now_ms: int = Time.get_ticks_msec()
	var last_ms: int = int(_last_spawn_failure_at_ms.get(message, -SPAWN_FAILURE_WARN_INTERVAL_MS))
	if now_ms - last_ms < SPAWN_FAILURE_WARN_INTERVAL_MS:
		return
	_last_spawn_failure = message
	_last_spawn_failure_at_ms[message] = now_ms
	push_warning("BuildingManager: " + message)


# Expected gameplay states (e.g. every garden eaten out or deliberately walled off
# from a spawner) are not anomalies: record them for spawn reporting like a failure,
# but log them debug-gated instead of pushing an engine warning.
func log_expected_spawn_skip(message: String) -> void:
	var now_ms: int = Time.get_ticks_msec()
	var last_ms: int = int(_last_spawn_failure_at_ms.get(message, -SPAWN_FAILURE_WARN_INTERVAL_MS))
	_last_spawn_failure = message
	if now_ms - last_ms < SPAWN_FAILURE_WARN_INTERVAL_MS:
		return
	_last_spawn_failure_at_ms[message] = now_ms
	CppDebugOptions.dlog("BuildingManager: " + message)


func last_spawn_failure() -> String:
	return _last_spawn_failure


func should_warn_spawn_failure_key(warning_key: String) -> bool:
	var now_ms: int = Time.get_ticks_msec()
	var last_ms: int = int(_last_spawn_failure_at_ms.get(warning_key, -SPAWN_FAILURE_WARN_INTERVAL_MS))
	if now_ms - last_ms < SPAWN_FAILURE_WARN_INTERVAL_MS:
		return false
	_last_spawn_failure_at_ms[warning_key] = now_ms
	return true


func log_scan_summary(seen_spawners: Dictionary, migrated: bool, hard_topology_changed: bool) -> void:
	var plant_manager: Node = _manager.get_plant_manager()
	var plant_count: int = int(plant_manager.call("size")) if plant_manager and plant_manager.has_method("size") else 0
	var summary: String = "scan indexed_plants=%d spawners=%d registered_spawners=%d migrated=%s hard_topology_changed=%s" % [
		plant_count,
		seen_spawners.size(),
		_manager.registered_spawner_count(),
		migrated,
		hard_topology_changed
	]
	if summary == _last_scan_summary:
		return
	_last_scan_summary = summary
	self.log(summary)


func _global_config() -> Node:
	if _cached_global_config != null and is_instance_valid(_cached_global_config):
		return _cached_global_config
	if _manager == null:
		return null
	_cached_global_config = _manager.global_config
	return _cached_global_config


func _debug_master_disabled() -> bool:
	if _cpp_debug_options == null:
		_cpp_debug_options = _find_cpp_debug_options()
	if _cpp_debug_options and "debug_enabled" in _cpp_debug_options:
		return not bool(_cpp_debug_options.get("debug_enabled"))
	return false


func _find_cpp_debug_options() -> Node:
	# The node is "CPP" in the current scene (same path BuildingManager._is_verbose() uses).
	if _manager == null or not _manager.is_inside_tree():
		return null
	var scene: Node = _manager.get_tree().get_current_scene()
	if scene == null:
		return null
	var node: Node = scene.get_node_or_null("CPP")
	if node:
		return node
	node = scene.get_node_or_null("CppDebugOptions")
	if node:
		return node
	node = scene.find_child("CppDebugOptions", true, false)
	if node:
		return node
	return null
