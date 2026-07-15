extends Node2D
class_name PathPreviewController

# Shows where the upcoming night's monsters, and the clients of the day after it, will walk.
# A pure consumer: SpawnerRouteService owns the routes and their flow groups, this node only
# reads the prepared descriptors, turns each ready one into a chain of tile centers once,
# and feeds pooled invisible footprint walkers along it.

const RUNNER_SCRIPT: Script = preload("res://scripts/map/path_preview_runner.gd")
const IDLE_GROUP: int = 0

@export var building_manager_path: NodePath = NodePath("../../BuildingManager")
@export var flow_path: NodePath = NodePath("../../../CPP/FlowFieldNative")
@export var preview_z_index: int = -50
@export_range(30.0, 900.0, 5.0, "or_greater") var walker_speed: float = 380.0
@export_range(0.05, 3.0, 0.05, "or_greater") var walker_departure_interval: float = 0.5
@export_range(4.0, 96.0, 1.0, "or_greater") var footprint_stride_distance: float = 28.0
@export_range(0.0, 24.0, 0.5, "or_greater") var footprint_lateral_offset: float = 5.0
@export_range(0.1, 4.0, 0.05, "or_greater") var footprint_scale: float = 1.0
@export_range(0.1, 8.0, 0.05, "or_greater") var footprint_fade_seconds: float = 2.2
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
	_start_ready_route_walkers()


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
	var descriptors: Array[Dictionary] = _prepared_descriptors()
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
		var route_kind: StringName = descriptor.get("route_kind", SpawnerRouteService.ROUTE_KIND_MONSTER_INBOUND) as StringName
		var is_client: bool = route_kind == SpawnerRouteService.ROUTE_KIND_CLIENT_INBOUND
		_routes.append(_plan_route_path({
			"group_id": group_id,
			"spawner_cell": descriptor.get("spawner_cell", Vector2i.ZERO) as Vector2i,
			"entry_cell": descriptor.get("entry_cell", Vector2i.ZERO) as Vector2i,
			"footprint_frame": PathPreviewRunner.FOOTPRINT_FRAME_CLIENT if is_client else PathPreviewRunner.FOOTPRINT_FRAME_MONSTER,
			"ready": bool(descriptor.get("ready", false)),
			"planned": false,
			"walkers_started": false,
			"path": PackedVector2Array(),
		}))


func _prepared_descriptors() -> Array[Dictionary]:
	var route_service: SpawnerRouteService = _manager.get_spawner_route_service()
	var descriptors: Array[Dictionary] = route_service.prepared_upcoming_monster_routes()
	descriptors.append_array(route_service.prepared_upcoming_client_routes())
	return descriptors


func _route_signature(descriptors: Array[Dictionary]) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for descriptor: Dictionary in descriptors:
		parts.append("%s:%d:%s:%d:%d:%s" % [
			str(descriptor.get("spawner_cell", Vector2i.ZERO)),
			int(descriptor.get("garden_id", 0)),
			str(descriptor.get("entry_cell", Vector2i.ZERO)),
			int(descriptor.get("topology_revision", -1)),
			int(descriptor.get("group_id", IDLE_GROUP)),
			String(descriptor.get("route_kind", &"") as StringName),
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
		_routes[index] = _plan_route_path(route)


# The chain of tile centers is planned once per route identity, on the first refresh where
# its flow group is ready, and then reused by that route's preview walkers. A route whose
# flow is still computing has no path yet and shows nothing; one that plans to nothing stays
# silent until the identity changes, rather than re-walking the field on every refresh.
func _plan_route_path(route: Dictionary) -> Dictionary:
	if bool(route.get("planned", false)) or not bool(route.get("ready", false)):
		return route
	route["planned"] = true
	route["path"] = PathPreviewRoutePlanner.build_cell_center_path(
		_flow,
		_manager,
		int(route.get("group_id", IDLE_GROUP)),
		route.get("spawner_cell", Vector2i.ZERO) as Vector2i,
		route.get("entry_cell", Vector2i.ZERO) as Vector2i
	)
	route["walkers_started"] = false
	return route


func _start_ready_route_walkers() -> void:
	for index: int in range(_routes.size()):
		var route: Dictionary = _routes[index]
		if not bool(route.get("ready", false)):
			continue
		var path: PackedVector2Array = route.get("path", PackedVector2Array()) as PackedVector2Array
		if path.size() < 2:
			continue
		if bool(route.get("walkers_started", false)):
			continue
		_start_route_walkers(route, path)
		route["walkers_started"] = true
		_routes[index] = route


func _start_route_walkers(route: Dictionary, path: PackedVector2Array) -> void:
	var total_line_length: float = PathPreviewRunner.measure_path_length(path)
	if total_line_length <= 0.0:
		return
	var walker_spacing: float = maxf(1.0, walker_speed * walker_departure_interval)
	var walker_count: int = maxi(1, ceili(total_line_length / walker_spacing))
	for walker_index: int in range(walker_count):
		var walker_start_distance: float = total_line_length * float(walker_index) / float(walker_count)
		var runner: PathPreviewRunner = _idle_runner()
		runner.start(
			path,
			int(route.get("footprint_frame", PathPreviewRunner.FOOTPRINT_FRAME_MONSTER)),
			walker_speed,
			footprint_stride_distance,
			footprint_lateral_offset,
			footprint_scale,
			footprint_fade_seconds,
			walker_start_distance
		)


func _idle_runner() -> PathPreviewRunner:
	for runner: PathPreviewRunner in _runners:
		if not runner.is_active():
			return runner
	var runner: PathPreviewRunner = RUNNER_SCRIPT.new() as PathPreviewRunner
	add_child(runner)
	runner.configure()
	_runners.append(runner)
	return runner


func _clear_routes() -> void:
	for runner: PathPreviewRunner in _runners:
		runner.recycle()
	_routes.clear()
