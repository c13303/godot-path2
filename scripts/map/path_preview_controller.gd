extends Node2D
class_name PathPreviewController

const RUNNER_SCRIPT: Script = preload("res://scripts/map/path_preview_runner.gd")
const IDLE_GROUP: int = 0
const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)
const KIND_NONE: StringName = &""
const KIND_CLIENT: StringName = &"client"
const KIND_MONSTER: StringName = &"monster"

@export var building_manager_path: NodePath = NodePath("../../BuildingManager")
@export var flow_path: NodePath = NodePath("../../../CPP/FlowFieldNative")
@export var preview_z_index: int = -50
@export var client_color: Color = Color(0.25, 0.58, 1.0, 0.58)
@export var monster_color: Color = Color(1.0, 0.22, 0.16, 0.58)
@export_range(30.0, 600.0, 5.0, "or_greater") var runner_speed: float = 190.0
@export_range(0.05, 3.0, 0.05, "or_greater") var emission_interval: float = 0.55
@export_range(2.0, 24.0, 0.5, "or_greater") var star_radius: float = 5.0
@export_range(4.0, 64.0, 1.0, "or_greater") var arrival_radius: float = 12.0
@export_range(1.0, 30.0, 0.5, "or_greater") var max_runner_lifetime: float = 8.0
@export_range(1, 128, 1, "or_greater") var max_runner_count: int = 48
@export_range(0.1, 2.0, 0.05, "or_greater") var refresh_interval: float = 0.35
@export var debug_logs: bool = true

var _manager: BuildingManager
var _flow: Node
var _current_kind: StringName = KIND_NONE
var _routes: Array[Dictionary] = []
var _signature: String = ""
var _refresh_timer: float = 0.0
var _runners: Array[PathPreviewRunner] = []
var _dependencies_ready: bool = false
var _last_state_log_key: String = ""
var _last_dependency_log_msec: int = 0
var _last_wait_log_msec_by_group: Dictionary = {}
var _started_group_logged: Dictionary = {}
var _skip_detail_log_keys: Dictionary = {}


func _ready() -> void:
	z_index = preview_z_index
	_log("ready z_index=%d manager_path=%s flow_path=%s" % [z_index, str(building_manager_path), str(flow_path)])
	if not GameState.gameplay_phase_changed.is_connected(_on_gameplay_phase_changed):
		GameState.gameplay_phase_changed.connect(_on_gameplay_phase_changed)
	set_process(true)


func _exit_tree() -> void:
	_clear_routes()


func _process(delta: float) -> void:
	if not _ensure_dependencies_ready():
		return
	var invalidation: BuildingInvalidationController = _manager.get_building_invalidation_controller()
	if invalidation != null and invalidation.runtime_rebuild_active():
		_set_active_runners_visible(false)
		_refresh_timer = 0.0
		return
	_set_active_runners_visible(true)
	_refresh_timer -= delta
	if _refresh_timer <= 0.0:
		_refresh_timer = refresh_interval
		_refresh_now()
	_emit_due_runners(delta)


func _on_gameplay_phase_changed(_phase: int) -> void:
	if not _ensure_dependencies_ready():
		return
	_refresh_now()


func _ensure_dependencies_ready() -> bool:
	if _dependencies_ready:
		return true
	_manager = get_node_or_null(building_manager_path) as BuildingManager
	_flow = get_node_or_null(flow_path)
	if _manager == null or _flow == null:
		var now_msec: int = Time.get_ticks_msec()
		if now_msec - _last_dependency_log_msec >= 1000:
			_last_dependency_log_msec = now_msec
			_log("waiting dependencies manager=%s flow=%s" % [str(_manager != null), str(_flow != null)])
		return false
	_dependencies_ready = true
	_refresh_timer = 0.0
	_log("dependencies ready manager=%s flow=%s supports_dir=%s supports_cost=%s" % [
		str(_manager.get_path()),
		str(_flow.get_path()),
		str(_flow.has_method("compute_group_flow_dir")),
		str(_flow.has_method("group_route_cost_at_world")),
	])
	_refresh_now()
	return true


func _refresh_now() -> void:
	var next_kind: StringName = _preview_kind_for_phase()
	if next_kind == KIND_NONE:
		_log_state_once("inactive:%d" % GameState.gameplay_phase, "inactive phase=%d day=%d completed_clients=%d upcoming_night=%d authored_nights=%d" % [
			GameState.gameplay_phase,
			_manager.current_day_number(),
			_manager.completed_night_client_count_for_day(),
			_manager.upcoming_authored_night_index_for_preview(),
			_manager.authored_night_count(),
		])
		_current_kind = KIND_NONE
		_signature = ""
		_clear_routes()
		return
	_manager.ensure_path_preview_topology_ready()
	var built: Dictionary = _build_route_set(next_kind)
	var next_signature: String = String(built.get("signature", ""))
	if next_signature == _signature and next_kind == _current_kind:
		if _routes.is_empty():
			_log_state_once("unchanged-empty:%s" % next_signature, "unchanged empty preview kind=%s stats=%s" % [String(next_kind), str(built.get("stats", {}))])
		return
	_clear_routes()
	_current_kind = next_kind
	_signature = next_signature
	_routes.clear()
	_log("refresh kind=%s signature=%s stats=%s" % [String(next_kind), next_signature, str(built.get("stats", {}))])
	var raw_legs: Variant = built.get("legs", [])
	if raw_legs is Array:
		_allocate_routes(raw_legs as Array)


func _preview_kind_for_phase() -> StringName:
	match GameState.gameplay_phase:
		GameState.GameplayPhase.DAWN:
			if _manager.completed_night_client_count_for_day() <= 0:
				return KIND_NONE
			return KIND_CLIENT
		GameState.GameplayPhase.AFTERNOON:
			var night_index: int = _manager.upcoming_authored_night_index_for_preview()
			if night_index < 0 or night_index >= _manager.authored_night_count():
				return KIND_NONE
			return KIND_MONSTER
		_:
			return KIND_NONE


func _build_route_set(preview_kind: StringName) -> Dictionary:
	var spawner_cells: Array[Vector2i] = _preview_spawner_cells(preview_kind)
	_sort_cells(spawner_cells)
	var invalidation: BuildingInvalidationController = _manager.get_building_invalidation_controller()
	var revision: int = invalidation.navigation_revision() if invalidation != null else 0
	var signature_parts: PackedStringArray = PackedStringArray([String(preview_kind), str(revision)])
	var legs: Array[Dictionary] = []
	var stats: Dictionary = {
		"spawners": spawner_cells.size(),
		"selected": 0,
		"legs": 0,
		"skip_no_selection": 0,
		"skip_invalid": 0,
		"revision": revision,
		"plant_zone_built": _manager.get_garden_topology_service().plant_zone_built(),
		"gardens": _manager.get_garden_topology_service().gardens().size(),
		"source_plants": _manager.preview_source_plant_count(),
	}
	var block_fences: bool = preview_kind == KIND_CLIENT
	var route_color: Color = client_color if preview_kind == KIND_CLIENT else monster_color
	for spawner_cell: Vector2i in spawner_cells:
		var selected: Dictionary = _manager.select_garden_entry_for_preview(spawner_cell, preview_kind)
		if selected.is_empty():
			stats["skip_no_selection"] = int(stats["skip_no_selection"]) + 1
			_log_selection_skip(spawner_cell, preview_kind, revision)
			continue
		var garden_id: int = int(selected.get("garden_id", 0))
		var entry_cell: Vector2i = selected.get("entry_cell", INVALID_CELL) as Vector2i
		var escape_cell: Vector2i = _manager.resolve_spawner_escape_target_cell(spawner_cell)
		if garden_id <= 0 or entry_cell == INVALID_CELL or escape_cell == INVALID_CELL:
			stats["skip_invalid"] = int(stats["skip_invalid"]) + 1
			_log("skip spawner=%s kind=%s reason=invalid_route garden=%d entry=%s escape=%s" % [
				str(spawner_cell), String(preview_kind), garden_id, str(entry_cell), str(escape_cell)
			])
			continue
		stats["selected"] = int(stats["selected"]) + 1
		signature_parts.append("%s:%d:%s:%s" % [str(spawner_cell), garden_id, str(entry_cell), str(escape_cell)])
		_append_leg_plan(legs, spawner_cell, spawner_cell, entry_cell, block_fences, route_color, &"inbound")
		_append_leg_plan(legs, spawner_cell, entry_cell, escape_cell, block_fences, route_color, &"outbound")
		stats["legs"] = int(stats["legs"]) + 2
	return {
		"signature": "|".join(signature_parts),
		"legs": legs,
		"stats": stats,
	}


func _preview_spawner_cells(preview_kind: StringName) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	if preview_kind == KIND_CLIENT:
		for raw_cell: Variant in _manager.client_spawners().keys():
			cells.append(raw_cell as Vector2i)
		return cells
	return _manager.night_active_spawner_cells(_manager.upcoming_authored_night_index_for_preview())


func _sort_cells(cells: Array[Vector2i]) -> void:
	cells.sort_custom(Callable(self, "_cell_less_than"))


func _cell_less_than(a: Vector2i, b: Vector2i) -> bool:
	if a.y == b.y:
		return a.x < b.x
	return a.y < b.y


func _append_leg_plan(
		legs: Array[Dictionary],
		spawner_cell: Vector2i,
		start_cell: Vector2i,
		goal_cell: Vector2i,
		block_fences: bool,
		route_color: Color,
		direction: StringName
) -> void:
	legs.append({
		"start_cell": start_cell,
		"goal_cell": goal_cell,
		"spawner_cell": spawner_cell,
		"direction": direction,
		"block_fences": block_fences,
		"color": route_color,
	})


func _allocate_routes(legs: Array) -> void:
	var allocated_count: int = 0
	for raw_leg: Variant in legs:
		if not (raw_leg is Dictionary):
			continue
		var leg: Dictionary = raw_leg as Dictionary
		var group_id: int = _manager.create_preview_flow_group()
		if group_id <= IDLE_GROUP:
			_log("allocate failed reason=create_group returned %d leg=%s" % [group_id, str(leg)])
			continue
		var start_cell: Vector2i = leg.get("start_cell", INVALID_CELL) as Vector2i
		var goal_cell: Vector2i = leg.get("goal_cell", INVALID_CELL) as Vector2i
		if start_cell == INVALID_CELL or goal_cell == INVALID_CELL:
			_manager.dissolve_preview_flow_group(group_id)
			_log("allocate failed reason=invalid_cells group=%d start=%s goal=%s" % [group_id, str(start_cell), str(goal_cell)])
			continue
		var goal_world: Vector2 = _manager.cell_center(goal_cell)
		var start_world: Vector2 = _manager.cell_center(start_cell)
		var spawner_cell: Vector2i = leg.get("spawner_cell", INVALID_CELL) as Vector2i
		var direction: StringName = leg.get("direction", &"") as StringName
		var block_fences: bool = bool(leg.get("block_fences", false))
		_manager.request_group_flow_rebuild_with_policy(group_id, goal_world, block_fences, "preview %s %s" % [String(direction), str(spawner_cell)])
		_routes.append({
			"group_id": group_id,
			"start_world": start_world,
			"goal_world": goal_world,
			"spawner_cell": spawner_cell,
			"direction": direction,
			"color": leg.get("color", Color.WHITE) as Color,
			"emit_timer": randf() * emission_interval,
		})
		allocated_count += 1
		_log("allocated group=%d spawner=%s dir=%s start=%s goal=%s block_fences=%s color=%s" % [
			group_id, str(spawner_cell), String(direction), str(start_cell), str(goal_cell), str(block_fences), str(leg.get("color", Color.WHITE))
		])
	_log("allocated_routes=%d requested_legs=%d total_routes=%d" % [allocated_count, legs.size(), _routes.size()])


func _emit_due_runners(delta: float) -> void:
	for index: int in range(_routes.size()):
		var route: Dictionary = _routes[index] as Dictionary
		var timer: float = maxf(0.0, float(route.get("emit_timer", 0.0)) - delta)
		if timer > 0.0:
			route["emit_timer"] = timer
			_routes[index] = route
			continue
		route["emit_timer"] = emission_interval
		_routes[index] = route
		_try_start_runner(route)


func _try_start_runner(route: Dictionary) -> void:
	if _active_runner_count() >= max_runner_count:
		return
	var group_id: int = int(route.get("group_id", IDLE_GROUP))
	var start_world: Vector2 = route.get("start_world", Vector2.ZERO) as Vector2
	if not _group_is_ready_at(group_id, start_world):
		_log_group_wait(group_id, start_world)
		return
	var runner: PathPreviewRunner = _idle_runner()
	if runner == null:
		return
	runner.start(
		group_id,
		start_world,
		route.get("goal_world", Vector2.ZERO) as Vector2,
		route.get("color", Color.WHITE) as Color,
		runner_speed,
		arrival_radius,
		max_runner_lifetime,
		0.35,
		8.0,
		8,
		8,
		star_radius
	)
	if not _started_group_logged.has(group_id):
		_started_group_logged[group_id] = true
		_log("runner started group=%d spawner=%s dir=%s start_world=%s goal_world=%s active_runners=%d z=%d" % [
			group_id,
			str(route.get("spawner_cell", INVALID_CELL)),
			String(route.get("direction", &"")),
			str(start_world),
			str(route.get("goal_world", Vector2.ZERO)),
			_active_runner_count(),
			z_index,
		])


func _group_is_ready_at(group_id: int, world_pos: Vector2) -> bool:
	if group_id <= IDLE_GROUP or _flow == null or not _flow.has_method("group_route_cost_at_world"):
		return false
	var cost: float = float(_flow.call("group_route_cost_at_world", group_id, world_pos))
	return is_finite(cost)


func _log_group_wait(group_id: int, world_pos: Vector2) -> void:
	if not debug_logs:
		return
	var now_msec: int = Time.get_ticks_msec()
	var last_msec: int = int(_last_wait_log_msec_by_group.get(group_id, 0))
	if now_msec - last_msec < 1500:
		return
	_last_wait_log_msec_by_group[group_id] = now_msec
	var cost_text: String = "<no cost method>"
	if _flow != null and _flow.has_method("group_route_cost_at_world"):
		cost_text = str(float(_flow.call("group_route_cost_at_world", group_id, world_pos)))
	_log("waiting flow group=%d world=%s cost=%s queued_routes=%d active_runners=%d" % [
		group_id, str(world_pos), cost_text, _routes.size(), _active_runner_count()
	])


func _idle_runner() -> PathPreviewRunner:
	for runner: PathPreviewRunner in _runners:
		if not runner.is_active():
			return runner
	if _runners.size() >= max_runner_count:
		return null
	var runner: PathPreviewRunner = RUNNER_SCRIPT.new() as PathPreviewRunner
	add_child(runner)
	runner.configure(_flow, debug_logs)
	runner.finished.connect(_on_runner_finished)
	_runners.append(runner)
	return runner


func _on_runner_finished(_runner: PathPreviewRunner) -> void:
	pass


func _active_runner_count() -> int:
	var count: int = 0
	for runner: PathPreviewRunner in _runners:
		if runner.is_active():
			count += 1
	return count


func _set_active_runners_visible(value: bool) -> void:
	for runner: PathPreviewRunner in _runners:
		if runner.is_active():
			runner.visible = value


func _clear_routes() -> void:
	for runner: PathPreviewRunner in _runners:
		runner.recycle()
	for route: Dictionary in _routes:
		var group_id: int = int(route.get("group_id", IDLE_GROUP))
		if _manager != null:
			_manager.dissolve_preview_flow_group(group_id)
	_routes.clear()
	_started_group_logged.clear()
	_last_wait_log_msec_by_group.clear()
	_skip_detail_log_keys.clear()


func _log(message: String) -> void:
	if debug_logs:
		print("[PathPreview] " + message)


func _log_selection_skip(spawner_cell: Vector2i, preview_kind: StringName, revision: int) -> void:
	if not debug_logs:
		return
	var garden_count: int = _manager.get_garden_topology_service().gardens().size()
	var key: String = "%s:%s:%d:%d" % [String(preview_kind), str(spawner_cell), revision, garden_count]
	if _skip_detail_log_keys.has(key):
		return
	_skip_detail_log_keys[key] = true
	var summary: Dictionary = {}
	if _manager.has_method("preview_selection_debug_summary"):
		summary = _manager.preview_selection_debug_summary(spawner_cell, preview_kind)
	_log("skip spawner=%s kind=%s reason=no_selected_garden_entry debug=%s" % [
		str(spawner_cell),
		String(preview_kind),
		str(summary),
	])


func _log_state_once(key: String, message: String) -> void:
	if key == _last_state_log_key:
		return
	_last_state_log_key = key
	_log(message)
