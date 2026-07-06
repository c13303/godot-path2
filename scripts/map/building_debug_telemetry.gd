extends RefCounted
class_name BuildingDebugTelemetry

# Owns BuildingManager's debug logging and lag-warning thresholds. It deliberately
# keeps only instrumentation state; gameplay systems stay in BuildingManager.

const SPAWN_FAILURE_WARN_INTERVAL_MS: int = 3000
const DEBUG_PLANTFF_FRAME_LAG_MS_FALLBACK: float = 100.0
const DEBUG_PLANTFF_FF_LAG_MS_FALLBACK: float = 10.0
const DEBUG_GARDENS_LAG_MS_FALLBACK: float = 15.0

var _manager: Node
var _cpp_debug_options: Node = null
var _last_scan_summary: String = ""
var _last_spawn_failure: String = ""
var _last_spawn_failure_at_ms: Dictionary = {}


func setup(manager: Node) -> void:
	_manager = manager


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


func log(message: String) -> void:
	if _manager != null and bool(_manager.get("debug_logs")) and CppDebugOptions.logs_enabled:
		print("BuildingManager: ", message)


func log_spawn_failure(message: String) -> void:
	var now_ms: int = Time.get_ticks_msec()
	var last_ms: int = int(_last_spawn_failure_at_ms.get(message, -SPAWN_FAILURE_WARN_INTERVAL_MS))
	if now_ms - last_ms < SPAWN_FAILURE_WARN_INTERVAL_MS:
		return
	_last_spawn_failure = message
	_last_spawn_failure_at_ms[message] = now_ms
	push_warning("BuildingManager: " + message)


func should_warn_spawn_failure_key(warning_key: String) -> bool:
	var now_ms: int = Time.get_ticks_msec()
	var last_ms: int = int(_last_spawn_failure_at_ms.get(warning_key, -SPAWN_FAILURE_WARN_INTERVAL_MS))
	if now_ms - last_ms < SPAWN_FAILURE_WARN_INTERVAL_MS:
		return false
	_last_spawn_failure_at_ms[warning_key] = now_ms
	return true


func log_scan_summary(seen_spawners: Dictionary, migrated: bool, walls_changed: bool) -> void:
	var plant_manager: Node = _manager.get("plant_manager") as Node
	var plant_count: int = int(plant_manager.call("size")) if plant_manager and plant_manager.has_method("size") else 0
	var spawners: Dictionary = _manager.get("_spawners") as Dictionary
	var summary: String = "scan indexed_plants=%d spawners=%d registered_spawners=%d migrated=%s walls_changed=%s" % [
		plant_count,
		seen_spawners.size(),
		spawners.size(),
		migrated,
		walls_changed
	]
	if summary == _last_scan_summary:
		return
	_last_scan_summary = summary
	self.log(summary)


func _global_config() -> Node:
	if _manager == null:
		return null
	return _manager.get("global_config") as Node


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
