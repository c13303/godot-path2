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
@export_range(1.0, 128.0, 1.0, "or_greater") var footstep_stride_distance: float = 16.0
@export_range(1.0, 128.0, 1.0, "or_greater") var walk_speed: float = 128.0
@export_range(0.0, 24.0, 0.5, "or_greater") var footstep_side_offset: float = 6.0
@export_range(0.05, 2.0, 0.05, "or_greater") var footstep_fade_duration: float = 0.45
@export_range(2, 12, 2, "or_greater") var steps_per_nominal_animation: int = 6
@export_range(1, 8, 1, "or_greater") var walk_animation_density_reduction: int = 4
@export_range(0.1, 4.0, 0.05, "or_greater") var footprint_scale: float = 1.0
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
			"owned_segments": {},
		}))
	_rebuild_segment_ownership()


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
	var ownership_dirty: bool = false
	for index: int in range(_routes.size()):
		var route: Dictionary = _routes[index]
		var group_id: int = int(route.get("group_id", IDLE_GROUP))
		route["ready"] = bool(ready_by_group.get(group_id, false))
		var was_planned: bool = bool(route.get("planned", false))
		_routes[index] = _plan_route_path(route)
		if not was_planned and bool((_routes[index] as Dictionary).get("planned", false)):
			ownership_dirty = true
	if ownership_dirty:
		_rebuild_segment_ownership()


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


func _rebuild_segment_ownership() -> void:
	for runner: PathPreviewRunner in _runners:
		runner.recycle()
	var edge_owner: Dictionary = {}
	for route_index: int in range(_routes.size()):
		var route: Dictionary = _routes[route_index]
		var path: PackedVector2Array = route.get("path", PackedVector2Array()) as PackedVector2Array
		var owned_segments: Dictionary = {}
		for segment_index: int in range(path.size() - 1):
			var edge_key: String = _canonical_edge_key(path[segment_index], path[segment_index + 1])
			if edge_key == "":
				continue
			if not edge_owner.has(edge_key):
				edge_owner[edge_key] = route_index
			if int(edge_owner.get(edge_key, -1)) == route_index:
				owned_segments[segment_index] = true
		route["owned_segments"] = owned_segments
		route["walkers_started"] = false
		_routes[route_index] = route


func _canonical_edge_key(first: Vector2, second: Vector2) -> String:
	if first.is_equal_approx(second):
		return ""
	var first_cell_center: Vector2i = Vector2i(roundi(first.x), roundi(first.y))
	var second_cell_center: Vector2i = Vector2i(roundi(second.x), roundi(second.y))
	if _point_sorts_before(first_cell_center, second_cell_center):
		return "%s|%s" % [_point_key(first_cell_center), _point_key(second_cell_center)]
	return "%s|%s" % [_point_key(second_cell_center), _point_key(first_cell_center)]


func _point_sorts_before(first: Vector2i, second: Vector2i) -> bool:
	if first.x != second.x:
		return first.x < second.x
	return first.y < second.y


func _point_key(point: Vector2i) -> String:
	return "%d,%d" % [point.x, point.y]


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
		var owned_segments: Dictionary = route.get("owned_segments", {}) as Dictionary
		if owned_segments.is_empty():
			route["walkers_started"] = true
			_routes[index] = route
			continue
		_start_route_walkers(route, path)
		route["walkers_started"] = true
		_routes[index] = route


func _start_route_walkers(route: Dictionary, path: PackedVector2Array) -> void:
	var total_line_length: float = PathPreviewRunner.measure_path_length(path)
	if total_line_length <= 0.0:
		return
	var sections: Array[Dictionary] = _build_walk_animation_sections(total_line_length)
	for section: Dictionary in sections:
		var runner: PathPreviewRunner = _idle_runner()
		runner.start(
			path,
			route.get("owned_segments", {}) as Dictionary,
			int(route.get("footprint_frame", PathPreviewRunner.FOOTPRINT_FRAME_MONSTER)),
			walk_speed,
			footstep_stride_distance,
			footstep_side_offset,
			footstep_fade_duration,
			footprint_scale,
			float(section.get("start_distance", 0.0)),
			float(section.get("boundary_distance", 0.0)),
			int(section.get("step_count", 0))
		)


func _build_walk_animation_sections(total_line_length: float) -> Array[Dictionary]:
	var sections: Array[Dictionary] = []
	var stride_distance: float = maxf(1.0, footstep_stride_distance)
	var nominal_section_length: float = stride_distance * float(maxi(2, steps_per_nominal_animation))
	var target_section_length: float = nominal_section_length * float(maxi(1, walk_animation_density_reduction))
	var full_step_count: int = int(floor(total_line_length / stride_distance))
	var usable_step_count: int = full_step_count - (full_step_count % 2)
	if usable_step_count < 2:
		return sections
	var total_pair_count: int = usable_step_count / 2
	var wanted_animation_count: int = int(ceil(total_line_length / target_section_length))
	var maximum_animation_count: int = maxi(1, total_pair_count / 2)
	var animation_count: int = clampi(wanted_animation_count, 1, maximum_animation_count)
	var base_pairs: int = total_pair_count / animation_count
	var remainder_pairs: int = total_pair_count % animation_count
	var start_distance: float = 0.0
	for index: int in range(animation_count):
		var pairs_for_animation: int = base_pairs
		if index < remainder_pairs:
			pairs_for_animation += 1
		var steps_for_animation: int = pairs_for_animation * 2
		var boundary_distance: float = start_distance + float(steps_for_animation) * stride_distance
		if index == animation_count - 1:
			boundary_distance = total_line_length
		sections.append({
			"start_distance": start_distance,
			"boundary_distance": boundary_distance,
			"step_count": steps_for_animation,
		})
		start_distance += float(steps_for_animation) * stride_distance
	return sections


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
