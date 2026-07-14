extends Node2D
class_name PathPreviewController

const RUNNER_SCRIPT: Script = preload("res://scripts/map/path_preview_runner.gd")
const IDLE_GROUP: int = 0

@export var building_manager_path: NodePath = NodePath("../../BuildingManager")
@export var flow_path: NodePath = NodePath("../../../CPP/FlowFieldNative")
@export var preview_z_index: int = -50
@export var monster_color: Color = Color(1.0, 0.22, 0.16, 0.58)
@export_range(30.0, 600.0, 5.0, "or_greater") var runner_speed: float = 190.0
@export_range(0.05, 3.0, 0.05, "or_greater") var emission_interval: float = 0.5
@export_range(2.0, 24.0, 0.5, "or_greater") var star_radius: float = 5.0
@export_range(4.0, 64.0, 1.0, "or_greater") var arrival_radius: float = 12.0
@export_range(1.0, 30.0, 0.5, "or_greater") var stalled_runner_timeout: float = 5.0
@export_range(0.1, 2.0, 0.05, "or_greater") var refresh_interval: float = 0.35

var _manager: BuildingManager = null
var _flow: Node = null
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
	if GameState.gameplay_phase != GameState.GameplayPhase.AFTERNOON:
		_signature = ""
		_clear_routes()
		return
	var invalidation: BuildingInvalidationController = _manager.get_building_invalidation_controller()
	if invalidation != null and (
		invalidation.navigation_topology_dirty()
		or invalidation.plant_layout_dirty()
		or invalidation.runtime_rebuild_active()
	):
		_signature = ""
		_clear_routes()
		return
	var route_service: SpawnerRouteService = _manager.get_spawner_route_service()
	var descriptors: Array[Dictionary] = route_service.prepared_upcoming_monster_routes()
	var next_signature: String = _route_signature(descriptors)
	if next_signature == _signature:
		_update_route_readiness(descriptors)
		return
	_clear_routes()
	_signature = next_signature
	for descriptor: Dictionary in descriptors:
		var group_id: int = int(descriptor.get("group_id", IDLE_GROUP))
		if group_id <= IDLE_GROUP:
			continue
		_routes.append({
			"group_id": group_id,
			"start_world": _manager.cell_center(descriptor.get("spawner_cell", Vector2i.ZERO) as Vector2i),
			"goal_world": descriptor.get("entry_world", Vector2.ZERO) as Vector2,
			"ready": bool(descriptor.get("ready", false)),
			"emit_timer": 0.0,
		})


func _route_signature(descriptors: Array[Dictionary]) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for descriptor: Dictionary in descriptors:
		parts.append("%s:%d:%s:%d:%d" % [
			str(descriptor.get("spawner_cell", Vector2i.ZERO)),
			int(descriptor.get("garden_id", 0)),
			str(descriptor.get("entry_cell", Vector2i.ZERO)),
			int(descriptor.get("topology_revision", -1)),
			int(descriptor.get("group_id", IDLE_GROUP)),
		])
	return "|".join(parts)


func _update_route_readiness(descriptors: Array[Dictionary]) -> void:
	var ready_by_group: Dictionary = {}
	for descriptor: Dictionary in descriptors:
		ready_by_group[int(descriptor.get("group_id", IDLE_GROUP))] = bool(descriptor.get("ready", false))
	for index: int in range(_routes.size()):
		var route: Dictionary = _routes[index]
		var group_id: int = int(route.get("group_id", IDLE_GROUP))
		route["ready"] = bool(ready_by_group.get(group_id, false))
		_routes[index] = route


func _emit_due_runners(delta: float) -> void:
	for index: int in range(_routes.size()):
		var route: Dictionary = _routes[index]
		if not bool(route.get("ready", false)):
			continue
		var timer: float = maxf(0.0, float(route.get("emit_timer", 0.0)) - delta)
		if timer > 0.0:
			route["emit_timer"] = timer
			_routes[index] = route
			continue
		var runner: PathPreviewRunner = _idle_runner()
		runner.start(
			int(route.get("group_id", IDLE_GROUP)),
			route.get("start_world", Vector2.ZERO) as Vector2,
			route.get("goal_world", Vector2.ZERO) as Vector2,
			monster_color,
			runner_speed,
			arrival_radius,
			stalled_runner_timeout,
			8.0,
			8,
			8,
			star_radius
		)
		route["emit_timer"] = emission_interval
		_routes[index] = route


func _idle_runner() -> PathPreviewRunner:
	for runner: PathPreviewRunner in _runners:
		if not runner.is_active():
			return runner
	var runner: PathPreviewRunner = RUNNER_SCRIPT.new() as PathPreviewRunner
	add_child(runner)
	runner.configure(_flow, preview_z_index)
	_runners.append(runner)
	return runner


func _clear_routes() -> void:
	for runner: PathPreviewRunner in _runners:
		runner.recycle()
	_routes.clear()
