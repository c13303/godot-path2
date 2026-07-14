extends Node2D
class_name PathPreviewController

# Shows where the upcoming night's monsters, and the clients of the day after it, will walk.
# A pure consumer: SpawnerRouteService owns the routes and their flow groups, this node only
# reads the prepared descriptors, turns each ready one into a chain of tile centers once,
# and feeds pooled arrows along it.

const RUNNER_SCRIPT: Script = preload("res://scripts/map/path_preview_runner.gd")
const IDLE_GROUP: int = 0

@export var building_manager_path: NodePath = NodePath("../../BuildingManager")
@export var flow_path: NodePath = NodePath("../../../CPP/FlowFieldNative")
@export var preview_z_index: int = -50
# Tints multiply the sprite sheet's authored arrow colors, so values above 1 brighten the
# arrow without shifting its hue. They are drawn additively (see PathPreviewRunner).
@export var monster_tint: Color = Color(1.35, 1.1, 1.0, 1.0)
@export var client_tint: Color = Color(1.1, 1.2, 1.35, 1.0)
@export_range(30.0, 900.0, 5.0, "or_greater") var runner_speed: float = 380.0
@export_range(0.05, 3.0, 0.05, "or_greater") var emission_interval: float = 0.5
@export_range(0.1, 4.0, 0.05, "or_greater") var arrow_scale: float = 1.25
@export_range(2, 64, 1, "or_greater") var trail_point_limit: int = 18
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
			"arrow_frame": PathPreviewRunner.ARROW_FRAME_CLIENT if is_client else PathPreviewRunner.ARROW_FRAME_MONSTER,
			"tint": client_tint if is_client else monster_tint,
			"ready": bool(descriptor.get("ready", false)),
			"planned": false,
			"path": PackedVector2Array(),
			"emit_timer": 0.0,
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
# its flow group is ready, and then reused by every arrow that route emits. A route whose
# flow is still computing has no path yet and emits nothing; one that plans to nothing stays
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
	return route


func _emit_due_runners(delta: float) -> void:
	for index: int in range(_routes.size()):
		var route: Dictionary = _routes[index]
		if not bool(route.get("ready", false)):
			continue
		var path: PackedVector2Array = route.get("path", PackedVector2Array()) as PackedVector2Array
		if path.size() < 2:
			continue
		var timer: float = maxf(0.0, float(route.get("emit_timer", 0.0)) - delta)
		if timer > 0.0:
			route["emit_timer"] = timer
			_routes[index] = route
			continue
		var runner: PathPreviewRunner = _idle_runner()
		runner.start(
			path,
			route.get("tint", Color.WHITE) as Color,
			int(route.get("arrow_frame", PathPreviewRunner.ARROW_FRAME_MONSTER)),
			runner_speed,
			arrow_scale,
			trail_point_limit
		)
		route["emit_timer"] = emission_interval
		_routes[index] = route


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
