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

var _manager: BuildingManager
var _flow: Node
var _current_kind: StringName = KIND_NONE
var _routes: Array[Dictionary] = []
var _signature: String = ""
var _refresh_timer: float = 0.0
var _runners: Array[PathPreviewRunner] = []
var _dependencies_ready: bool = false


func _ready() -> void:
	z_index = preview_z_index
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
		return false
	_dependencies_ready = true
	_refresh_timer = 0.0
	_refresh_now()
	return true


func _refresh_now() -> void:
	var next_kind: StringName = _preview_kind_for_phase()
	if next_kind == KIND_NONE:
		_current_kind = KIND_NONE
		_signature = ""
		_clear_routes()
		return
	_manager.ensure_path_preview_topology_ready()
	var built: Dictionary = _build_route_set(next_kind)
	var next_signature: String = String(built.get("signature", ""))
	if next_signature == _signature and next_kind == _current_kind:
		return
	_clear_routes()
	_current_kind = next_kind
	_signature = next_signature
	_routes.clear()
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
	var topology: GardenTopologyService = _manager.get_garden_topology_service()
	var garden_count: int = topology.gardens().size()
	var signature_parts: PackedStringArray = PackedStringArray([String(preview_kind), str(revision)])
	var legs: Array[Dictionary] = []
	if garden_count <= 0:
		signature_parts.append("gardens:0")
		return {
			"signature": "|".join(signature_parts),
			"legs": legs,
		}
	var block_fences: bool = preview_kind == KIND_CLIENT
	var route_color: Color = client_color if preview_kind == KIND_CLIENT else monster_color
	for spawner_cell: Vector2i in spawner_cells:
		var selected: Dictionary = _manager.select_garden_entry_for_preview(spawner_cell, preview_kind)
		if selected.is_empty():
			continue
		var garden_id: int = int(selected.get("garden_id", 0))
		var entry_cell: Vector2i = selected.get("entry_cell", INVALID_CELL) as Vector2i
		if garden_id <= 0 or entry_cell == INVALID_CELL:
			continue
		signature_parts.append("%s:%d:%s" % [str(spawner_cell), garden_id, str(entry_cell)])
		_append_leg_plan(legs, spawner_cell, spawner_cell, entry_cell, block_fences, route_color, &"inbound")
	return {
		"signature": "|".join(signature_parts),
		"legs": legs,
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
	for raw_leg: Variant in legs:
		if not (raw_leg is Dictionary):
			continue
		var leg: Dictionary = raw_leg as Dictionary
		var group_id: int = _manager.create_preview_flow_group()
		if group_id <= IDLE_GROUP:
			push_warning("PathPreview failed to create preview flow group.")
			continue
		var start_cell: Vector2i = leg.get("start_cell", INVALID_CELL) as Vector2i
		var goal_cell: Vector2i = leg.get("goal_cell", INVALID_CELL) as Vector2i
		if start_cell == INVALID_CELL or goal_cell == INVALID_CELL:
			_manager.dissolve_preview_flow_group(group_id)
			push_warning("PathPreview refused a preview route with invalid cells.")
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
			"emit_timer": 0.0,
		})


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


func _group_is_ready_at(group_id: int, world_pos: Vector2) -> bool:
	if group_id <= IDLE_GROUP or _manager == null:
		return false
	var spawner_routes: SpawnerRouteService = _manager.get_spawner_route_service()
	return spawner_routes.group_flow_is_ready_at_world(group_id, world_pos)


func _idle_runner() -> PathPreviewRunner:
	for runner: PathPreviewRunner in _runners:
		if not runner.is_active():
			return runner
	if _runners.size() >= max_runner_count:
		return null
	var runner: PathPreviewRunner = RUNNER_SCRIPT.new() as PathPreviewRunner
	add_child(runner)
	runner.configure(_flow, preview_z_index)
	_runners.append(runner)
	return runner


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
