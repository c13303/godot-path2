extends Node
class_name BuildingManager

signal startup_loading_progress(progress: float, label: String)
signal startup_loading_finished

const AGENT_SCENE: PackedScene = preload("res://scenes/entities/character.tscn")
const BUILD_TILES_INDEX_PATH: String = "res://scripts/map/build_tiles_index.tres"
const DEFAULT_SPAWN_COOLDOWN: float = 2.0
const EATING_COOLDOWN: float = 5.0
const IDLE_GROUP: int = 0
const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)
const EXIT_WALL_ATLAS: Vector2i = Vector2i(13, 0)
const PLANT_ZONE_MARGIN: int = 2
# Max walkable path length (in cells) allowed between two plants for them to share
# a garden, measured through walkable cells so walls split gardens. BFS from a
# seed plant is bounded by this radius and re-seeded from each plant it absorbs,
# so a chain of plants each within this distance forms one connected garden.
#
# Matches the OLD effective merge reach: gardens used to merge when their
# PLANT_ZONE_MARGIN-radius (2) zone boxes were 8-adjacent, i.e. when two plants
# were within Chebyshev distance 2 + 2 + 1 = 5. In open floor a BFS step (incl.
# diagonals) advances Chebyshev distance by 1, so a bound of 5 reproduces that
# reach while remaining wall-aware.
const GARDEN_LINK_DISTANCE: int = PLANT_ZONE_MARGIN * 2 + 1
const SPAWN_FAILURE_WARN_INTERVAL_MS: int = 3000

# Garden access-cell scoring penalties. Distance / escape cost stays the main
# driver; these only nudge selection away from obviously bad local geometry (a
# wall-pocket exit that forces an immediate reversal, a dead-ended outside tile).
# They are deliberately conservative and additive: a valid access cell is never
# rejected outright for being near walls, only ranked slightly lower when its
# continuation geometry is also poor. Tune as needed.
const ACCESS_NO_OUTSIDE_PENALTY: float = 1000.0
const ACCESS_EXIT_WORSE_PENALTY: float = 100.0
const ACCESS_EXIT_FLAT_PENALTY: float = 10.0
const ACCESS_DEAD_CONTINUATION_PENALTY: float = 100.0
const ACCESS_NARROW_CONTINUATION_PENALTY: float = 20.0
const ACCESS_REVERSAL_PENALTY: float = 100.0
const ACCESS_TURN_PENALTY: float = 5.0
const ACCESS_BLOCKED_CARDINAL_PENALTY: float = 2.0
# Enter mode uses softer continuation penalties (the agent is heading inward, so
# outside continuation matters less than for exits).
const ACCESS_ENTER_DEAD_CONTINUATION_PENALTY: float = 30.0
const ACCESS_ENTER_NARROW_CONTINUATION_PENALTY: float = 10.0

@export var floorz: TileMapLayer
@export var wallz: TileMapLayer
@export var plantz: TileMapLayer
@export var buildings: TileMapLayer
@export var plant_manager: Node
@export var flow: Node
@export var agent_manager: Node
@export var pathfinder: Node
@export var parent_for_agents: Node
@export var global_config: Node
@export var debug_logs: bool = false
@export_group("CPP > Gardens")
@export var dont_shrink_gardens: bool = true
@export_group("")
@export_range(0, 32, 1, "or_greater") var empty_garden_local_retarget_radius: int = 5
# How many queued agents are retargeted per frame after a garden rebuild. Keeps the
# rebuild frame cheap by spreading the (expensive) re-path/escape work over several
# frames. Raise if reassignment feels too slow, lower if it causes frame spikes.
@export_range(1, 64, 1, "or_greater") var garden_retarget_budget_per_frame: int = 8
@export var debug_show_plantzone: bool = true:
	set(value):
		debug_show_plantzone = value
		if _zone_overlay:
			_zone_overlay.visible = value
			_zone_overlay.queue_redraw()

var _tile_defs_by_atlas: Dictionary = {}
var _spawners: Dictionary = {}
var _spawn_timers: Dictionary = {}
var _spawner_routes: Dictionary = {}
var _spawner_garden_routes: Dictionary = {}
var _eating_agents: Dictionary = {}
var _eating_time: float = EATING_COOLDOWN
var _escaping_agents: Dictionary = {}
var _entry_path_agents: Dictionary = {}
var _astar_in_agents: Dictionary = {}
var _astar_out_agents: Dictionary = {}
# Budgeted retargeting after a garden topology rebuild. When a rebuild invalidates
# the garden an agent was targeting/eating-in, we cannot afford to re-path every
# affected agent in the same frame (potential large spike). Instead each affected
# agent is detached from its stale path/flow cheaply, parked in "waiting_new_status",
# and queued here; _process_garden_retarget_queue() then re-assigns a bounded number
# of them per frame. Queue items are Dictionaries:
#   { "nav_id": int, "intent": String ("escape"|"retarget"), "spawner_cell": Vector2i }
# _garden_retarget_queued mirrors the queued nav_ids so we never double-enqueue.
var _garden_retarget_queue: Array[Dictionary] = []
var _garden_retarget_queued: Dictionary = {}  # nav_id -> true
var _scan_timer: float = 0.0
var _last_wall_signature: int = 0
var _last_scan_summary: String = ""
var _last_spawn_failure: String = ""
var _last_spawn_failure_at_ms: Dictionary = {}
var _flow_ready: bool = false
var _startup_loading_started: bool = false
var _startup_ready: bool = false
var _dirty_spawner_escapes: Dictionary = {}
# One escape flow field per exit-wall tile, shared by all monsters. Keyed by the
# exit-wall cell. Each value: { "escape_group": int, "escape_target_cell":
# Vector2i, "escape_world": Vector2, "ready": bool }. A finishing monster picks
# the exit with the lowest route cost from its position (FlowFieldNative.
# group_route_cost_at_world), so it leaves through the nearest reachable wall
# exit. Rebuilt only on dirty events (level load / walls changed).
var _exit_wall_escapes: Dictionary = {}  # Vector2i -> Dictionary
var _gardens: Dictionary = {}
var _garden_by_plant_cell: Dictionary = {}
var _dirty_gardens: Dictionary = {}
# Garden ids are monotonic and never reused: a full rebuild keeps climbing instead
# of resetting to 1, so an id from a previous rebuild can never collide with a new
# garden. _gardens_epoch is bumped on every full rebuild and stamped on each garden
# + each spawner route; a route is only current if its epoch matches, so stale
# routes (and their flow-field goals) from a previous night/rebuild are rejected
# even if a garden id/version happens to line up. Fixes night-2 agents flowing to a
# deleted night-1 garden's entry tile and oscillating there.
var _next_garden_id: int = 1
var _gardens_epoch: int = 0
# TEMP DEBUG (garden crash hunt): set true while iterating _gardens or
# _spawner_garden_routes so any erase that happens mid-iteration is reported
# before it can corrupt the iteration. Remove once the silent crash is confirmed
# fixed. See _erase_garden / _warn_if_iterating.
# Depth counter (not a bool) so nested guarded iterations don't clear the guard
# early. Iteration is considered active while _gardens_iter_depth > 0.
var _gardens_iter_depth: int = 0
var _garden_debug_logs: bool = true
# Gardens found empty during a _gardens iteration; erased after the loop ends.
var _pending_empty_gardens: Dictionary = {}  # garden_id -> true
# Cells reachable from any spawner over the walkable map. Recomputed once per
# garden rebuild (single source flood-fill); read when deciding if a garden is
# reachable. A sealed enclosure has no entry cell in this set, so it is ignored.
var _spawner_reachable_cells: Dictionary = {}  # Vector2i -> true
var _walkable_map_tiles: Dictionary = {}  # Vector2i -> true

# Day/night: set true once at least one monster has spawned during the current
# night, so an empty scene can flip back to day only after a real night ran.
var _spawned_this_night: bool = false

# Plant zone compatibility caches. Tiles use the floorz tilemap cell space.
var _plant_zone_tiles: Dictionary = {}  # Vector2i -> true
var _plant_zone_margin_tiles: Dictionary = {}  # Vector2i -> true (entry/exit candidates)
var _plant_zone_built: bool = false
var _zone_overlay: Node2D
var _show_enters_exits: bool = false
# When on, prints "x gardens recomputed with y entry points" every time gardens
# (and their entry points) are recomputed. Pushed from CppDebugOptions.verbose;
# _verbose_pushed flips true once that push has happened. Until then _is_verbose()
# pulls the value straight off the CPP node so the startup recompute is logged
# even if it runs before CppDebugOptions._ready().
var _verbose: bool = false
var _verbose_pushed: bool = false
var _cpp_debug_options: Node = null

const DEBUG_PLANTFF_FRAME_LAG_MS_FALLBACK: float = 100.0
const DEBUG_PLANTFF_FF_LAG_MS_FALLBACK: float = 10.0

func _frame_lag_threshold_ms() -> float:
	if global_config and global_config.has_method("get_debug_nav_frame_lag_ms"):
		return float(global_config.call("get_debug_nav_frame_lag_ms"))
	if global_config and global_config.has_method("get_debug_plantff_frame_lag_ms"):
		return float(global_config.call("get_debug_plantff_frame_lag_ms"))
	return DEBUG_PLANTFF_FRAME_LAG_MS_FALLBACK

func _ff_lag_threshold_ms() -> float:
	if global_config and global_config.has_method("get_debug_flowfield_rebuild_lag_ms"):
		return float(global_config.call("get_debug_flowfield_rebuild_lag_ms"))
	if global_config and global_config.has_method("get_debug_plantff_ff_lag_ms"):
		return float(global_config.call("get_debug_plantff_ff_lag_ms"))
	return DEBUG_PLANTFF_FF_LAG_MS_FALLBACK

func set_empty_garden_local_retarget_radius(value: int) -> void:
	empty_garden_local_retarget_radius = maxi(0, value)

func set_eating_time(value: float) -> void:
	_eating_time = maxf(0.0, value)

func _ready() -> void:
	startup_loading_progress.emit(0.48, "Preparing zones")
	_load_tile_definitions()
	_migrate_special_tiles_from_wallz()
	_setup_plant_manager()
	_setup_zone_overlay()
	_wait_for_flow_ready()
	GameState.mode_changed.connect(_on_game_mode_changed)

func _on_game_mode_changed(is_night: bool) -> void:
	if not is_night:
		return
	# Entering night: start fresh so monsters spawn promptly.
	_validate_dirty_gardens()
	_rebuild_spawner_garden_route_cache()
	_spawned_this_night = false
	for cell in _spawn_timers.keys():
		_spawn_timers[cell] = 0.0

func _monster_count() -> int:
	return get_tree().get_nodes_in_group("monsters").size()

func _wait_for_flow_ready() -> void:
	var code_node: Node = null
	if flow:
		for child in flow.get_children():
			if child.has_signal("flow_field_ready"):
				code_node = child
				break
	if code_node == null:
		_flow_ready = true
		call_deferred("_run_startup_after_flow_ready")
		return
	if bool(code_node.get("is_ready")):
		_flow_ready = true
		call_deferred("_run_startup_after_flow_ready")
		return
	code_node.connect("flow_field_ready", Callable(self, "_on_flow_field_ready"))

func _on_flow_field_ready() -> void:
	_flow_ready = true
	call_deferred("_run_startup_after_flow_ready")

func _run_startup_after_flow_ready() -> void:
	if _startup_loading_started or _startup_ready:
		return
	_startup_loading_started = true
	startup_loading_progress.emit(0.55, "Building plant zone")
	await get_tree().process_frame

	_build_gardens_from_plants()
	_validate_dirty_gardens()
	startup_loading_progress.emit(0.70, "Finding spawner routes")
	await get_tree().process_frame

	await _sync_runtime_state()
	_startup_ready = true
	startup_loading_progress.emit(1.0, "Ready")
	startup_loading_finished.emit()

func _setup_zone_overlay() -> void:
	_zone_overlay = Node2D.new()
	_zone_overlay.name = "PlantZoneOverlay"
	_zone_overlay.z_index = -99
	_zone_overlay.z_as_relative = false
	_zone_overlay.visible = _plant_zone_debug_enabled()
	_zone_overlay.set_script(load("res://scripts/map/plant_zone_overlay.gd"))
	_zone_overlay.set("building_manager", self)
	var overlay_parent: Node = floorz.get_parent() if floorz and floorz.get_parent() else self
	overlay_parent.add_child(_zone_overlay)

func _plant_zone_debug_enabled() -> bool:
	if global_config and global_config.has_method("get_debug_show_zones"):
		return bool(global_config.call("get_debug_show_zones"))
	if global_config and global_config.has_method("get_debug_show_plant_zones"):
		return bool(global_config.call("get_debug_show_plant_zones"))
	return debug_show_plantzone

func _sync_plant_zone_debug_visibility() -> void:
	if not _zone_overlay:
		return
	var show: bool = _plant_zone_debug_enabled()
	if _zone_overlay.visible == show:
		return
	_zone_overlay.visible = show
	_zone_overlay.queue_redraw()

func _process(delta: float) -> void:
	if not _flow_ready or not _startup_ready:
		return
	var frame_start_ms: int = Time.get_ticks_msec()
	_scan_timer -= delta
	if _scan_timer <= 0.0:
		_scan_timer = 0.25
		_scan_buildings()

	if not _dirty_spawner_escapes.is_empty():
		_drain_dirty_routes()

	_process_eating_agents(delta)
	_process_astar_in_arrivals()
	_process_plant_arrivals()
	_process_astar_out_arrivals()
	_process_escape_arrivals()
	_process_garden_retarget_queue()
	_process_spawners(delta)
	_sync_plant_zone_debug_visibility()

	var frame_ms: int = Time.get_ticks_msec() - frame_start_ms
	var frame_threshold_ms: float = _frame_lag_threshold_ms()
	if float(frame_ms) > frame_threshold_ms:
		push_warning("debug_nav_frame_lag: %dms (threshold=%dms) eating=%d escaping=%d spawners=%d" % [
			frame_ms,
			int(frame_threshold_ms),
			_eating_agents.size(),
			_escaping_agents.size(),
			_spawners.size()
		])

func _load_tile_definitions() -> void:
	_tile_defs_by_atlas.clear()
	var res: Resource = load(BUILD_TILES_INDEX_PATH)
	if not (res is JSON):
		return

	for key in res.data.keys():
		var definition: Variant = res.data[key]
		if not (definition is Dictionary):
			continue
		var tile_definition: Dictionary = definition as Dictionary
		var atlas: Array = tile_definition.get("atlas", [])
		if atlas.size() != 2:
			continue
		var atlas_key: String = _atlas_key(Vector2i(int(atlas[0]), int(atlas[1])))
		_tile_defs_by_atlas[atlas_key] = {
			"key": str(key),
			"kind": str(tile_definition.get("kind", "")),
			"cooldown": float(tile_definition.get("cooldown", DEFAULT_SPAWN_COOLDOWN))
		}

func _scan_buildings() -> void:
	if not buildings:
		return

	var migrated: bool = _migrate_special_tiles_from_wallz()

	var wall_signature: int = _tile_layer_signature(wallz)
	var walls_changed: bool = wall_signature != _last_wall_signature or migrated
	_last_wall_signature = wall_signature

	var seen_spawners: Dictionary = {}
	_scan_special_layer(buildings, seen_spawners)
	_scan_special_layer(wallz, seen_spawners)
	_log_scan_summary(seen_spawners, migrated, walls_changed)

	for raw_spawner_cell in _spawners.keys():
		var cell: Vector2i = raw_spawner_cell
		if not seen_spawners.has(cell):
			_spawners.erase(cell)
			_spawn_timers.erase(cell)
			_release_spawner_route(cell)
			_dirty_spawner_escapes.erase(cell)

	if walls_changed:
		_rebuild_walkable_map_cache()
		# Walls change navigation topology: a new wall can split a garden and a
		# removed wall can merge two. Re-cluster plants by walkable reachability
		# from scratch (single cached rebuild), then refresh cached spawner/garden
		# FFs against the new entries.
		if _plant_zone_built:
			_rebuild_plant_zone_from_layer()
		_rebuild_spawner_garden_route_cache()
		for raw_spawner_cell in _spawners.keys():
			_rebuild_spawner_plant_ff(raw_spawner_cell)
			_dirty_spawner_escapes[raw_spawner_cell] = true
		# Exit walls may have been added/removed: refresh per-exit escape FFs.
		_rebuild_exit_wall_escapes()

func _sync_runtime_state() -> void:
	_scan_buildings()
	var spawner_cells: Array = _spawners.keys()
	var total_count: int = spawner_cells.size()
	if total_count == 0:
		startup_loading_progress.emit(0.98, "Ready")
		return
	var index: int = 0
	for raw_spawner_cell in spawner_cells:
		var spawner_cell: Vector2i = raw_spawner_cell
		_initialize_spawner_route(spawner_cell)
		index += 1
		var progress: float = 0.75 + (float(index) / float(total_count)) * 0.23
		startup_loading_progress.emit(progress, "Preparing routes")
		await get_tree().process_frame
	# Per-exit-wall escape FFs (shared by all monsters); built once at startup.
	_rebuild_exit_wall_escapes()

func _setup_plant_manager() -> void:
	if not plant_manager:
		return
	if plant_manager.has_method("initialize_from_layer"):
		plant_manager.call("initialize_from_layer")
	if plant_manager.has_signal("plant_added") and not plant_manager.is_connected("plant_added", Callable(self, "_on_plant_added")):
		plant_manager.connect("plant_added", Callable(self, "_on_plant_added"))
	if plant_manager.has_signal("plant_removed") and not plant_manager.is_connected("plant_removed", Callable(self, "_on_plant_removed")):
		plant_manager.connect("plant_removed", Callable(self, "_on_plant_removed"))

func _on_plant_added(_cell: Vector2i) -> void:
	_add_plant_to_gardens(_cell)
	_retarget_agents_for_garden_topology_change(_cell)
	if _zone_overlay:
		_zone_overlay.queue_redraw()

# Runtime plant removal (an agent ate a plant, or a plant was removed at runtime).
# This is CONTENT-ONLY: it never recomputes garden entry/access points and never
# triggers a full topology rebuild. We only narrow-retarget the agents that were
# specifically targeting the removed plant, and only fall back to the budgeted
# queue when the garden actually became empty. Full rebuilds are reserved for real
# topology changes (plant addition, walls/buildings, level load, manual rebuild).
func _on_plant_removed(cell: Vector2i) -> void:
	var result := _remove_plant_from_garden_content_only(cell)
	if not bool(result.get("was_removed", false)):
		return

	var garden_id := int(result.get("garden_id", 0))
	var became_empty := bool(result.get("became_empty", false))

	if became_empty and garden_id > 0:
		_handle_garden_became_empty(garden_id)
	else:
		_retarget_agents_targeting_removed_plant_only(cell, garden_id)

	if _zone_overlay:
		_zone_overlay.queue_redraw()

	if _no_plants_remaining():
		_queue_escape_for_all_monsters_budgeted()

func _scan_special_layer(layer: TileMapLayer, seen_spawners: Dictionary) -> void:
	if not layer:
		return

	for raw_cell in layer.get_used_cells():
		var map_cell: Vector2i = raw_cell
		var definition: Dictionary = _definition_for_layer_cell(layer, map_cell)
		var kind: String = str(definition.get("kind", ""))
		if kind == "spawner":
			_log("detected spawner layer=%s cell=%s atlas=%s floor=%s wall=%s" % [
				layer.name,
				map_cell,
				layer.get_cell_atlas_coords(map_cell),
				_has_floor(map_cell),
				_has_wall(map_cell)
			])
			seen_spawners[map_cell] = true
			_register_spawner(map_cell, float(definition.get("cooldown", DEFAULT_SPAWN_COOLDOWN)))

func _migrate_special_tiles_from_wallz() -> bool:
	if not wallz or not buildings:
		return false

	var migrated: bool = false
	for raw_cell in wallz.get_used_cells():
		var cell: Vector2i = raw_cell
		var definition: Dictionary = _definition_for_layer_cell(wallz, cell)
		var kind: String = str(definition.get("kind", ""))
		if kind == "" or kind == "wall":
			continue

		var target_layer: TileMapLayer = plantz if kind == "plantsToTarget" else buildings
		if not target_layer:
			continue
		target_layer.set_cell(
			cell,
			wallz.get_cell_source_id(cell),
			wallz.get_cell_atlas_coords(cell),
			wallz.get_cell_alternative_tile(cell)
		)
		wallz.erase_cell(cell)
		migrated = true
		_log("migrated special tile kind=%s cell=%s atlas=%s from wallz to %s" % [
			kind,
			cell,
			target_layer.get_cell_atlas_coords(cell),
			target_layer.name
		])

	if migrated:
		buildings.update_internals()
		if plantz:
			plantz.update_internals()
		wallz.update_internals()
	return migrated

func _definition_for_cell(cell: Vector2i) -> Dictionary:
	return _definition_for_layer_cell(buildings, cell)

func _definition_for_layer_cell(layer: TileMapLayer, cell: Vector2i) -> Dictionary:
	if not layer:
		return {}
	var atlas: Vector2i = layer.get_cell_atlas_coords(cell)
	var atlas_key: String = _atlas_key(atlas)
	return _tile_defs_by_atlas.get(atlas_key, {}) as Dictionary

func _register_spawner(cell: Vector2i, cooldown: float) -> void:
	var is_new: bool = not _spawners.has(cell)
	_spawners[cell] = {
		"cooldown": max(0.05, cooldown)
	}
	if not _spawn_timers.has(cell):
		_spawn_timers[cell] = 0.0
	if is_new and _flow_ready and _plant_zone_built and _startup_ready:
		_initialize_spawner_route(cell)

func _release_spawner_route(spawner_cell: Vector2i) -> void:
	var route: Dictionary = _spawner_routes.get(spawner_cell, {}) as Dictionary
	var escape_group: int = int(route.get("escape_group", -1))
	if agent_manager and agent_manager.has_method("dissolve_group"):
		if escape_group > IDLE_GROUP:
			agent_manager.call("dissolve_group", escape_group)
		if _spawner_garden_routes.has(spawner_cell):
			var garden_routes: Dictionary = _spawner_garden_routes[spawner_cell] as Dictionary
			for raw_route in garden_routes.values():
				var garden_route: Dictionary = raw_route as Dictionary
				var plant_group: int = int(garden_route.get("plant_group", -1))
				if plant_group > IDLE_GROUP:
					agent_manager.call("dissolve_group", plant_group)
	_spawner_routes.erase(spawner_cell)
	_spawner_garden_routes.erase(spawner_cell)

func _drain_dirty_routes() -> void:
	if not _flow_ready:
		return
	if not agent_manager or not agent_manager.has_method("create_group"):
		return
	if not flow or not flow.has_method("assign_flow_to_group"):
		return

	var escape_cells: Array = _dirty_spawner_escapes.keys()
	_dirty_spawner_escapes.clear()

	for raw_cell in escape_cells:
		if _spawners.has(raw_cell):
			_rebuild_spawner_escape_ff(raw_cell)

func _initialize_spawner_route(spawner_cell: Vector2i) -> void:
	# One-shot: compute static escape cells. Plant entry routes use per-agent A*
	# and are created lazily when a spawner needs a target garden.
	if not _flow_ready or not _plant_zone_built:
		return
	if not agent_manager or not flow:
		return

	var route: Dictionary = _spawner_routes.get(spawner_cell, {}) as Dictionary

	# Exit wall tile (nearest atlas (13,0) on wallz by Manhattan distance).
	var exit_wall_cell: Vector2i = _nearest_exit_wall_for_spawner(spawner_cell)
	route["exit_wall_cell"] = exit_wall_cell

	# Floor tile adjacent to the exit wall that the FF can target.
	var escape_wall_target_cell: Vector2i = INVALID_CELL
	if exit_wall_cell != INVALID_CELL:
		escape_wall_target_cell = _nearest_walkable_adjacent(exit_wall_cell)
	if escape_wall_target_cell == INVALID_CELL:
		# Fallback to spawner cell if no walkable adjacency to an exit wall.
		escape_wall_target_cell = _resolve_walkable_goal(spawner_cell, "escape@%s" % spawner_cell)
	route["escape_wall_target_cell"] = escape_wall_target_cell

	# Escape FF: goal = floor tile adjacent to exit wall (static).
	if escape_wall_target_cell != INVALID_CELL:
		var escape_group: int = int(route.get("escape_group", -1))
		if escape_group <= IDLE_GROUP:
			escape_group = int(agent_manager.call("create_group"))
		if escape_group > IDLE_GROUP:
			var escape_world: Vector2 = _cell_center(escape_wall_target_cell)
			if not _is_finite_world(escape_world):
				push_warning("LOST-AGENT-GUARD: insane escape_world %s (cell %s) for spawner %s" % [
					escape_world, escape_wall_target_cell, spawner_cell
				])
				route["escape_ready"] = false
				_spawner_routes[spawner_cell] = route
				return
			flow.call("assign_flow_to_group", escape_group, escape_world)
			route["escape_group"] = escape_group
			route["escape_world"] = escape_world
			route["escape_ready"] = true
		else:
			push_error("BuildingManager: spawner %s could not allocate escape group" % spawner_cell)
			route["escape_ready"] = false
	else:
		route["escape_ready"] = false

	_spawner_routes[spawner_cell] = route
	_log("initialized spawner=%s exit_wall=%s escape_target=%s" % [
		spawner_cell, exit_wall_cell, escape_wall_target_cell
	])

func _rebuild_spawner_plant_ff(spawner_cell: Vector2i) -> void:
	# Plant-entry routing no longer owns flow fields. Route freshness is validated
	# through garden version/epoch and each agent gets a direct A* path to entry.
	if not _spawner_garden_routes.has(spawner_cell):
		return
	var garden_routes: Dictionary = _spawner_garden_routes[spawner_cell] as Dictionary
	for raw_garden_id in garden_routes.keys():
		var garden_id: int = int(raw_garden_id)
		var route: Dictionary = garden_routes[garden_id] as Dictionary
		var entry_cell: Vector2i = route.get("entry_cell", INVALID_CELL) as Vector2i
		if entry_cell == INVALID_CELL:
			continue
		route["entry_world"] = _cell_center(entry_cell)
		garden_routes[garden_id] = route
	_spawner_garden_routes[spawner_cell] = garden_routes

func _rebuild_spawner_escape_ff(spawner_cell: Vector2i) -> void:
	# Re-run escape FF after walls change. Goal is the cached escape_wall_target_cell.
	var route: Dictionary = _spawner_routes.get(spawner_cell, {}) as Dictionary
	var target_cell: Vector2i = route.get("escape_wall_target_cell", INVALID_CELL) as Vector2i
	if target_cell == INVALID_CELL:
		return
	var escape_group: int = int(route.get("escape_group", -1))
	if escape_group <= IDLE_GROUP:
		return
	var escape_world: Vector2 = _cell_center(target_cell)
	_request_group_flow_rebuild(escape_group, escape_world)
	route["escape_world"] = escape_world
	_spawner_routes[spawner_cell] = route

func _rebuild_all_spawner_routes() -> void:
	if not _flow_ready or not _plant_zone_built:
		return
	for raw_cell in _spawners.keys():
		var spawner_cell: Vector2i = raw_cell
		_initialize_spawner_route(spawner_cell)

# Build/refresh one escape flow field per exit-wall tile. Each is a per-group FF
# whose goal is the floor tile adjacent to that exit wall. Runs only on dirty
# events; at runtime a monster reads each group's route cost to pick the nearest
# reachable exit. Stale exits (walls removed) are released.
func _rebuild_exit_wall_escapes() -> void:
	if not _flow_ready:
		return
	if not agent_manager or not agent_manager.has_method("create_group"):
		return
	if not flow:
		return

	var current_exits: Dictionary = {}  # Vector2i -> true
	if wallz:
		for raw_cell in wallz.get_used_cells():
			var c: Vector2i = raw_cell
			if wallz.get_cell_atlas_coords(c) == EXIT_WALL_ATLAS:
				current_exits[c] = true

	# Release escapes whose exit wall no longer exists.
	for raw_exit_cell in _exit_wall_escapes.keys():
		var exit_cell: Vector2i = raw_exit_cell
		if not current_exits.has(exit_cell):
			_release_exit_wall_escape(exit_cell)

	# Create/refresh an escape FF for every current exit wall.
	for raw_exit_cell in current_exits.keys():
		var exit_cell: Vector2i = raw_exit_cell
		var target_cell: Vector2i = _nearest_walkable_adjacent(exit_cell)
		if target_cell == INVALID_CELL:
			# No walkable tile next to this exit wall: drop any stale escape.
			_release_exit_wall_escape(exit_cell)
			continue
		var escape: Dictionary = _exit_wall_escapes.get(exit_cell, {}) as Dictionary
		var escape_group: int = int(escape.get("escape_group", -1))
		if escape_group <= IDLE_GROUP:
			escape_group = int(agent_manager.call("create_group"))
		if escape_group <= IDLE_GROUP:
			push_error("BuildingManager: could not allocate escape group for exit wall %s" % exit_cell)
			continue
		var escape_world: Vector2 = _cell_center(target_cell)
		if not _is_finite_world(escape_world):
			push_warning("LOST-AGENT-GUARD: insane exit-wall escape_world %s (cell %s) for exit %s" % [
				escape_world, target_cell, exit_cell
			])
			_release_exit_wall_escape(exit_cell)
			continue
		# Synchronous assign so the FF (and its route-cost field) is queryable
		# immediately; goals are static and rebuilds are rare (dirty events only).
		if flow.has_method("assign_flow_to_group"):
			flow.call("assign_flow_to_group", escape_group, escape_world)
		else:
			_request_group_flow_rebuild(escape_group, escape_world)
		escape["escape_group"] = escape_group
		escape["escape_target_cell"] = target_cell
		escape["escape_world"] = escape_world
		escape["ready"] = true
		_exit_wall_escapes[exit_cell] = escape

func _release_exit_wall_escape(exit_cell: Vector2i) -> void:
	if not _exit_wall_escapes.has(exit_cell):
		return
	var escape: Dictionary = _exit_wall_escapes[exit_cell] as Dictionary
	var escape_group: int = int(escape.get("escape_group", -1))
	if escape_group > IDLE_GROUP and agent_manager and agent_manager.has_method("dissolve_group"):
		agent_manager.call("dissolve_group", escape_group)
	_exit_wall_escapes.erase(exit_cell)

# Pick the exit-wall escape with the lowest walkable route cost from world_pos.
# Returns {} if none is reachable (caller falls back to the per-spawner escape).
func _nearest_reachable_exit_escape(world_pos: Vector2) -> Dictionary:
	if not flow or not flow.has_method("group_route_cost_at_world"):
		return {}
	var best: Dictionary = {}
	var best_cost: float = INF
	for raw_exit_cell in _exit_wall_escapes.keys():
		var escape: Dictionary = _exit_wall_escapes[raw_exit_cell] as Dictionary
		if not bool(escape.get("ready", false)):
			continue
		var escape_group: int = int(escape.get("escape_group", -1))
		if escape_group <= IDLE_GROUP:
			continue
		var cost: float = float(flow.call("group_route_cost_at_world", escape_group, world_pos))
		if cost < best_cost:
			best_cost = cost
			best = escape
	return best

func _request_group_flow_rebuild(group_id: int, goal_world: Vector2) -> void:
	# TEMP DEBUG (lost-agent guard): never push a non-finite / absurd goal into the
	# flow system — that is what makes agents map out of bounds and go lost.
	if not _is_finite_world(goal_world):
		push_warning("LOST-AGENT-GUARD: refused flow goal %s for group %d" % [goal_world, group_id])
		return
	if flow and flow.has_method("request_flow_to_group"):
		flow.call("request_flow_to_group", group_id, goal_world)
	elif flow and flow.has_method("assign_flow_to_group"):
		flow.call("assign_flow_to_group", group_id, goal_world)

func _is_finite_world(p: Vector2) -> bool:
	if not (is_finite(p.x) and is_finite(p.y)):
		return false
	var limit: float = float(_SANE_CELL_LIMIT) * 64.0
	return abs(p.x) <= limit and abs(p.y) <= limit

func _no_plants_remaining() -> bool:
	if plant_manager and plant_manager.has_method("is_empty"):
		return bool(plant_manager.call("is_empty"))
	return true

func _resolve_walkable_goal(cell: Vector2i, purpose: String) -> Vector2i:
	if _is_walkable(cell):
		return cell
	var fallback: Vector2i = _find_walkable_cell_near(cell)
	if fallback == INVALID_CELL:
		push_error("BuildingManager: %s target cell %s is not walkable and no walkable cell found within range. floor=%s wall=%s" % [
			purpose, cell, _has_floor(cell), _has_wall(cell)
		])
		return INVALID_CELL
	push_error("BuildingManager: %s target cell %s is a wall/non-walkable; falling back to nearest free tile %s" % [
		purpose, cell, fallback
	])
	return fallback

func _process_spawners(delta: float) -> void:
	# Day/night gating: monsters only spawn at night. When the last monster of
	# the night is gone, automatically flip back to day.
	if not GameState.is_night:
		return
	if _monster_count() == 0 and _spawned_this_night:
		GameState.start_day()
		return

	if _no_plants_remaining():
		if debug_logs and not _spawners.is_empty():
			_log("no plants remaining for %d spawner(s)" % _spawners.size())
		return

	for raw_cell in _spawners.keys():
		var cell: Vector2i = raw_cell
		var timer: float = float(_spawn_timers.get(cell, 0.0)) - delta
		if timer > 0.0:
			_spawn_timers[cell] = timer
			continue

		if _spawn_monster_from(cell):
			_spawned_this_night = true
			var spawner: Dictionary = _spawners[cell] as Dictionary
			_spawn_timers[cell] = float(spawner.get("cooldown", DEFAULT_SPAWN_COOLDOWN))
		else:
			_spawn_timers[cell] = 0.25

func _spawn_monster_from(spawner_cell: Vector2i) -> bool:
	var garden_id: int = _select_garden_for_spawner(spawner_cell)
	if garden_id <= 0:
		_log_spawn_failure("spawner %s has no reachable garden" % spawner_cell)
		return false
	var route: Dictionary = _get_or_create_spawner_garden_route(spawner_cell, garden_id)
	if not bool(route.get("ready", false)):
		_log_spawn_failure("spawner %s garden %d route not ready" % [spawner_cell, garden_id])
		return false
	var entry_cell: Vector2i = route.get("entry_cell", INVALID_CELL) as Vector2i
	if entry_cell == INVALID_CELL:
		_log_spawn_failure("spawner %s garden %d has no entry cell" % [spawner_cell, garden_id])
		return false

	if not _is_sane_cell(entry_cell):
		_log_spawn_failure("spawner %s garden %d insane entry_cell %s" % [spawner_cell, garden_id, entry_cell])
		return false

	var occupied: Array[Vector2i] = _occupied_cells()
	var spawn_cell: Vector2i = _find_free_cell_near(spawner_cell, occupied)
	if spawn_cell == INVALID_CELL or not _is_sane_cell(spawn_cell):
		_log_spawn_failure("spawner %s could not find a sane walkable spawn cell (got %s)" % [spawner_cell, spawn_cell])
		return false

	var agent: Node2D = AGENT_SCENE.instantiate() as Node2D
	var parent: Node = parent_for_agents if parent_for_agents else get_tree().current_scene
	parent.add_child(agent)
	agent.global_position = _cell_center(spawn_cell)
	agent.z_index = int(agent.global_position.y)
	agent.add_to_group("monsters")

	if agent_manager and agent_manager.has_method("spawn_agent"):
		var nav_id: int = int(agent_manager.call("spawn_agent", agent, IDLE_GROUP))
		agent.set("nav_id", nav_id)
		if agent_manager.has_method("set_agent_never_rest"):
			agent_manager.call("set_agent_never_rest", nav_id, true)
		if not _assign_agent_to_garden_entry_path(agent, spawner_cell, garden_id, entry_cell):
			if agent_manager.has_method("unregister_agent"):
				agent_manager.call("unregister_agent", nav_id)
			agent.remove_from_group("monsters")
			agent.queue_free()
			_log_spawn_failure("spawner %s garden %d entry path not ready" % [spawner_cell, garden_id])
			return false
		_log("spawned monster nav_id=%d spawn_cell=%s entry=%s spawner=%s garden=%d" % [
			nav_id, spawn_cell, entry_cell, spawner_cell, garden_id
		])

	return true

# Phase 1 -> 2: agent reached its assigned garden entry via A*. Compute A* to a
# plant target inside that garden and attach that path.
func _process_astar_in_arrivals() -> void:
	var finished: Array[int] = []
	var entry_ids: Array = _entry_path_agents.keys()
	for raw_nav_id in entry_ids:
		var nav_id: int = int(raw_nav_id)
		if not _entry_path_agents.has(nav_id):
			continue
		var data: Dictionary = _entry_path_agents[nav_id] as Dictionary
		var raw_agent: Variant = data.get("node", null)
		if not is_instance_valid(raw_agent):
			finished.append(nav_id)
			continue
		var agent: Node2D = raw_agent as Node2D
		if agent == null:
			finished.append(nav_id)
			continue
		if _eating_agents.has(nav_id) or _escaping_agents.has(nav_id):
			finished.append(nav_id)
			continue
		if _astar_in_agents.has(nav_id) or _astar_out_agents.has(nav_id):
			continue
		if not (agent_manager and agent_manager.has_method("agent_path_arrived")):
			continue
		if not bool(agent_manager.call("agent_path_arrived", nav_id)):
			continue
		var spawner_cell: Vector2i = data.get("spawner_cell", INVALID_CELL) as Vector2i
		var garden_id: int = int(data.get("garden_id", 0))
		if not _garden_has_edible_plants(garden_id):
			_entry_path_agents.erase(nav_id)
			_retarget_agent_or_escape(agent, spawner_cell)
			continue
		_entry_path_agents.erase(nav_id)
		_start_astar_in(agent, spawner_cell)
	for nav_id in finished:
		_entry_path_agents.erase(nav_id)
	# _garden_has_edible_plants may have queued stale-empty gardens; this loop
	# iterates monsters, not _gardens, so draining here is safe.
	_drain_pending_empty_gardens()

func _start_astar_in(agent: Node2D, spawner_cell: Vector2i) -> void:
	var nav_id: int = int(agent.get("nav_id"))
	var agent_cell: Vector2i = floorz.local_to_map(floorz.to_local(agent.global_position))
	var garden_id: int = int(agent.get_meta("garden_id")) if agent.has_meta("garden_id") else 0
	if not _garden_has_edible_plants(garden_id):
		_retarget_agent_or_escape(agent, spawner_cell)
		return
	var target_plant_cell: Vector2i = _resolve_plant_target_for_agent_in_garden(agent_cell, garden_id)
	if target_plant_cell == INVALID_CELL:
		_retarget_agent_or_escape(agent, spawner_cell)
		return
	var path_cells: PackedVector2Array = _find_path_in_zone(agent_cell, target_plant_cell, garden_id)
	if path_cells.is_empty():
		_retarget_agent_or_escape(agent, spawner_cell)
		return
	if agent_manager and agent_manager.has_method("detach_agent_flow"):
		agent_manager.call("detach_agent_flow", nav_id)
	var path_world: PackedVector2Array = _path_cells_to_world(path_cells)
	if agent_manager and agent_manager.has_method("assign_agent_path"):
		agent_manager.call("assign_agent_path", nav_id, path_world)
	_entry_path_agents.erase(nav_id)
	_astar_in_agents[nav_id] = {
		"node": agent,
		"plant_cell": target_plant_cell,
		"spawner_cell": spawner_cell,
		"garden_id": garden_id,
		"path_world": path_world
	}
	if agent.has_method("start_astar_in"):
		agent.call("start_astar_in")

# Phase 2 -> 3: astar_in path complete. Verify plant still exists; consume it.
func _process_plant_arrivals() -> void:
	var finished: Array[int] = []
	var astar_ids: Array = _astar_in_agents.keys()
	for raw_nav_id in astar_ids:
		var nav_id: int = int(raw_nav_id)
		if not _astar_in_agents.has(nav_id):
			continue
		var data: Dictionary = _astar_in_agents[nav_id] as Dictionary
		var raw_agent: Variant = data.get("node", null)
		if not is_instance_valid(raw_agent):
			finished.append(nav_id)
			continue
		var agent: Node2D = raw_agent as Node2D
		if agent == null:
			finished.append(nav_id)
			continue
		if not (agent_manager and agent_manager.has_method("agent_path_arrived")):
			continue
		if not bool(agent_manager.call("agent_path_arrived", nav_id)):
			continue
		var plant_cell: Vector2i = data.get("plant_cell", INVALID_CELL) as Vector2i
		var spawner_cell: Vector2i = data.get("spawner_cell", INVALID_CELL) as Vector2i
		if agent.has_method("stop_astar_in"):
			agent.call("stop_astar_in")
		if plant_cell == INVALID_CELL:
			finished.append(nav_id)
			continue
		if plant_manager and plant_manager.has_method("has_plant") and not bool(plant_manager.call("has_plant", plant_cell)):
			_astar_in_agents.erase(nav_id)
			_retarget_agent_or_escape(agent, spawner_cell)
			continue
		_astar_in_agents.erase(nav_id)
		_consume_plant(agent, spawner_cell, plant_cell)
	for nav_id in finished:
		_astar_in_agents.erase(nav_id)

func _retarget_agents_for_garden_topology_change(changed_cell: Vector2i) -> void:
	var astar_ids: Array = _astar_in_agents.keys()
	for raw_nav_id in astar_ids:
		var nav_id: int = int(raw_nav_id)
		if not _astar_in_agents.has(nav_id):
			continue
		var data: Dictionary = _astar_in_agents[nav_id] as Dictionary
		var plant_cell: Vector2i = data.get("plant_cell", INVALID_CELL) as Vector2i
		var garden_id: int = int(data.get("garden_id", 0))
		if plant_cell != changed_cell and not _garden_target_is_stale(garden_id):
			continue
		_clear_stale_garden_path(nav_id, data)

	var entry_ids: Array = _entry_path_agents.keys()
	for raw_nav_id in entry_ids:
		var nav_id: int = int(raw_nav_id)
		if not _entry_path_agents.has(nav_id):
			continue
		var data: Dictionary = _entry_path_agents[nav_id] as Dictionary
		var garden_id: int = int(data.get("garden_id", 0))
		if not _garden_target_is_stale(garden_id):
			continue
		_clear_stale_garden_path(nav_id, data)
	_drain_pending_empty_gardens()

func _garden_target_is_stale(garden_id: int) -> bool:
	if garden_id <= 0:
		return true
	if not _gardens.has(garden_id):
		return true
	return not _garden_has_edible_plants(garden_id)

func _clear_stale_garden_path(nav_id: int, data: Dictionary) -> void:
	_entry_path_agents.erase(nav_id)
	_astar_in_agents.erase(nav_id)
	if agent_manager and agent_manager.has_method("detach_agent_path"):
		agent_manager.call("detach_agent_path", nav_id)
	var raw_agent: Variant = data.get("node", null)
	if not is_instance_valid(raw_agent):
		return
	var agent: Node2D = raw_agent as Node2D
	if agent == null:
		return
	if agent.has_method("stop_astar_in"):
		agent.call("stop_astar_in")
	var spawner_cell: Vector2i = data.get("spawner_cell", INVALID_CELL) as Vector2i
	if spawner_cell == INVALID_CELL and agent.has_meta("spawner_cell"):
		spawner_cell = agent.get_meta("spawner_cell") as Vector2i
	_retarget_agent_or_escape(agent, spawner_cell)

# NARROW retarget for content-only plant removal. Only handles agents whose A*-in
# target was the exact removed plant; it does NOT broad-retarget the garden, does
# NOT rebuild routes, and does NOT recompute entry points. _entry_path_agents and
# _astar_out_agents are deliberately left alone (their garden is still alive with
# other plants, or it became empty — and the empty case is handled separately by
# _handle_garden_became_empty). The eater that just consumed the plant is already
# in _eating_agents (not _astar_in_agents), so it is never disturbed here.
func _retarget_agents_targeting_removed_plant_only(cell: Vector2i, garden_id: int) -> void:
	var garden_still_edible: bool = garden_id > 0 and _garden_has_edible_plants(garden_id)
	# Snapshot keys: _retarget_agent_or_escape / queueing mutate _astar_in_agents.
	for raw_nav_id in _astar_in_agents.keys():
		var nav_id: int = int(raw_nav_id)
		if not _astar_in_agents.has(nav_id):
			continue
		var data: Dictionary = _astar_in_agents[nav_id] as Dictionary
		var plant_cell: Vector2i = data.get("plant_cell", INVALID_CELL) as Vector2i
		if plant_cell != cell:
			continue
		var raw_agent: Variant = data.get("node", null)
		var spawner_cell: Vector2i = data.get("spawner_cell", INVALID_CELL) as Vector2i
		# Detach the stale A*-in path and forget the phase before reassigning.
		if agent_manager and agent_manager.has_method("detach_agent_path"):
			agent_manager.call("detach_agent_path", nav_id)
		_astar_in_agents.erase(nav_id)
		if not is_instance_valid(raw_agent):
			continue
		var agent: Node2D = raw_agent as Node2D
		if agent == null:
			continue
		if agent.has_method("stop_astar_in"):
			agent.call("stop_astar_in")
		if spawner_cell == INVALID_CELL and agent.has_meta("spawner_cell"):
			spawner_cell = agent.get_meta("spawner_cell") as Vector2i
		if garden_still_edible:
			# Cheap, synchronous: the garden still has plants, so this agent can pick a
			# fresh in-garden target (or escape if none is reachable) right now.
			_retarget_agent_or_escape(agent, spawner_cell)
		else:
			# Garden has no edible plants left (but wasn't flagged empty for the queue
			# path): defer through the budgeted queue so we don't spike this frame.
			_queue_agent_for_garden_retarget(nav_id, agent, "retarget", spawner_cell, garden_id)
	# A stale-empty garden may have been flagged by _garden_has_edible_plants above;
	# this function does not iterate _gardens, so draining now is safe.
	_drain_pending_empty_gardens()

func _consume_plant(eater: Node2D, _spawner_cell: Vector2i, plant_cell: Vector2i) -> void:
	_start_agent_eating(eater, _eating_time, plant_cell)
	if plant_manager and plant_manager.has_method("remove_plant"):
		plant_manager.call("remove_plant", plant_cell, true)
	elif plantz:
		plantz.erase_cell(plant_cell)
		_flush_plant_layer_visuals()
	if plantz and plantz.get_cell_source_id(plant_cell) >= 0:
		plantz.erase_cell(plant_cell)
		_flush_plant_layer_visuals()
		call_deferred("_flush_plant_layer_visuals")

func _flush_plant_layer_visuals() -> void:
	if not plantz:
		return
	if _no_plants_remaining():
		plantz.clear()
	plantz.update_internals()
	plantz.queue_redraw()

func _process_eating_agents(delta: float) -> void:
	var finished: Array[int] = []
	var eating_ids: Array = _eating_agents.keys()
	for raw_nav_id in eating_ids:
		var nav_id: int = int(raw_nav_id)
		if not _eating_agents.has(nav_id):
			continue
		var data: Dictionary = _eating_agents[nav_id] as Dictionary
		var timer: float = float(data.get("timer", 0.0)) - delta
		data["timer"] = timer
		_eating_agents[nav_id] = data
		if timer <= 0.0:
			finished.append(nav_id)

	for nav_id in finished:
		var data: Dictionary = _eating_agents.get(nav_id, {}) as Dictionary
		_erase_eating_agent(nav_id)
		var raw_agent: Variant = data.get("node", null)
		if is_instance_valid(raw_agent):
			var agent: Node2D = raw_agent as Node2D
			if agent == null:
				continue
			if agent.has_method("stop_eating"):
				agent.call("stop_eating")
			var spawner_cell: Vector2i = INVALID_CELL
			if agent.has_meta("spawner_cell"):
				spawner_cell = agent.get_meta("spawner_cell") as Vector2i
			_start_astar_out(agent, spawner_cell)

func _erase_eating_agent(nav_id: int) -> void:
	_eating_agents.erase(nav_id)

func _start_agent_eating(agent: Node2D, seconds: float, plant_cell: Vector2i = INVALID_CELL) -> void:
	var nav_id: int = int(agent.get("nav_id"))
	# Carry the garden/spawner/plant context so an empty-garden event can find this
	# eater and queue it for escape without a full rebuild (see _agent_referenced_
	# garden_id / _handle_garden_became_empty).
	var garden_id: int = int(agent.get_meta("garden_id")) if agent.has_meta("garden_id") else 0
	var spawner_cell: Vector2i = agent.get_meta("spawner_cell") as Vector2i if agent.has_meta("spawner_cell") else INVALID_CELL
	_eating_agents[nav_id] = {
		"node": agent,
		"timer": seconds,
		"garden_id": garden_id,
		"spawner_cell": spawner_cell,
		"plant_cell": plant_cell
	}
	if agent_manager and agent_manager.has_method("detach_agent_flow"):
		agent_manager.call("detach_agent_flow", nav_id)
	if agent_manager and agent_manager.has_method("detach_agent_path"):
		agent_manager.call("detach_agent_path", nav_id)
	_entry_path_agents.erase(nav_id)
	_astar_in_agents.erase(nav_id)
	_astar_out_agents.erase(nav_id)
	if agent.has_method("start_eating"):
		agent.call("start_eating", seconds)

func _start_escape_for_all_monsters() -> void:
	for node in get_tree().get_nodes_in_group("monsters"):
		if node is Node2D:
			var agent: Node2D = node
			var nav_id: int = int(agent.get("nav_id"))
			if _escaping_agents.has(nav_id) or _eating_agents.has(nav_id):
				continue
			_assign_agent_to_escape(agent)

func _start_astar_out(agent: Node2D, spawner_cell: Vector2i) -> void:
	if not is_instance_valid(agent):
		return
	if spawner_cell == INVALID_CELL or not _spawner_routes.has(spawner_cell):
		var from_cell: Vector2i = floorz.local_to_map(floorz.to_local(agent.global_position))
		spawner_cell = _nearest_spawner_cell(from_cell)
	if spawner_cell == INVALID_CELL or not _spawner_routes.has(spawner_cell):
		return
	var garden_id: int = int(agent.get_meta("garden_id")) if agent.has_meta("garden_id") else 0
	# The tile this monster entered through; we avoid reusing it as the exit tile
	# so entering and exiting agents don't fight over the same border cell.
	var original_entry_cell: Vector2i = INVALID_CELL
	if agent.has_meta("garden_entry_cell"):
		original_entry_cell = agent.get_meta("garden_entry_cell") as Vector2i
	# Aim the in-garden A* at the border tile nearest the exit the monster will
	# actually use: the nearest reachable wall exit by route cost. Fall back to
	# the spawner's exit when no per-exit escape applies. In both cases prefer a
	# tile different from the one the monster entered through.
	var exit_escape: Dictionary = _nearest_reachable_exit_escape(agent.global_position)
	var exit_cell: Vector2i = INVALID_CELL
	if not exit_escape.is_empty():
		var exit_target: Vector2i = exit_escape.get("escape_target_cell", INVALID_CELL) as Vector2i
		var escape_group: int = int(exit_escape.get("escape_group", -1))
		if exit_target != INVALID_CELL:
			# Exit-after-eating: score with the real escape flow so the chosen
			# access cell leads toward the map exit, not just nearest by Manhattan.
			exit_cell = _select_scored_garden_entry(garden_id, exit_target, "exit", original_entry_cell, escape_group)
	if exit_cell == INVALID_CELL:
		exit_cell = _nearest_garden_entry_to_exit_excluding(garden_id, spawner_cell, original_entry_cell)
	if exit_cell == INVALID_CELL:
		# No distinct garden exit exists. Safest fallback: skip the internal
		# garden-exit path entirely and route the monster straight to its escape /
		# map-exit target via the existing escape behavior. (No same-tile reuse,
		# no rebuild, no desync.)
		_assign_agent_to_escape(agent)
		return
	var agent_cell: Vector2i = floorz.local_to_map(floorz.to_local(agent.global_position))
	var path_cells: PackedVector2Array = _find_path_in_zone(agent_cell, exit_cell, garden_id)
	if path_cells.is_empty():
		_assign_agent_to_escape(agent)
		return
	var nav_id: int = int(agent.get("nav_id"))
	if agent_manager and agent_manager.has_method("detach_agent_flow"):
		agent_manager.call("detach_agent_flow", nav_id)
	var path_world: PackedVector2Array = _path_cells_to_world(path_cells)
	if agent_manager and agent_manager.has_method("assign_agent_path"):
		agent_manager.call("assign_agent_path", nav_id, path_world)
	_entry_path_agents.erase(nav_id)
	_astar_out_agents[nav_id] = {
		"node": agent,
		"spawner_cell": spawner_cell,
		"garden_id": garden_id,
		"exit_cell": exit_cell,
		"path_world": path_world
	}
	if agent.has_method("start_astar_out"):
		agent.call("start_astar_out")

func _process_astar_out_arrivals() -> void:
	var finished: Array[int] = []
	var astar_out_ids: Array = _astar_out_agents.keys()
	for raw_nav_id in astar_out_ids:
		var nav_id: int = int(raw_nav_id)
		if not _astar_out_agents.has(nav_id):
			continue
		var data: Dictionary = _astar_out_agents[nav_id] as Dictionary
		var raw_agent: Variant = data.get("node", null)
		if not is_instance_valid(raw_agent):
			finished.append(nav_id)
			continue
		var agent: Node2D = raw_agent as Node2D
		if agent == null:
			finished.append(nav_id)
			continue
		if not (agent_manager and agent_manager.has_method("agent_path_arrived")):
			continue
		if not bool(agent_manager.call("agent_path_arrived", nav_id)):
			continue
		finished.append(nav_id)
		if agent.has_method("stop_astar_out"):
			agent.call("stop_astar_out")
		_assign_agent_to_escape(agent)
	for nav_id in finished:
		_astar_out_agents.erase(nav_id)

# Returns true only when an escape group/path was actually assigned (i.e.
# _attach_agent_to_escape ran). Every early return is a failure (false) so the
# budgeted queue can keep the agent in "waiting_new_status" and requeue it instead
# of stranding it with no nav state.
func _assign_agent_to_escape(agent: Node2D) -> bool:
	if not agent_manager or not agent_manager.has_method("assign_agent"):
		return false
	# Prefer the nearest reachable per-exit-wall escape (chosen by walkable route
	# cost from the monster), so monsters leave through the closest wall exit.
	var exit_escape: Dictionary = _nearest_reachable_exit_escape(agent.global_position)
	if not exit_escape.is_empty():
		var exit_group: int = int(exit_escape.get("escape_group", -1))
		var exit_target: Vector2i = exit_escape.get("escape_target_cell", INVALID_CELL) as Vector2i
		if exit_group > IDLE_GROUP and exit_target != INVALID_CELL:
			return _attach_agent_to_escape(agent, exit_group, exit_target)

	# Fallback: the per-spawner escape (single shared exit for that spawner).
	var spawner_cell: Vector2i = INVALID_CELL
	if agent.has_meta("spawner_cell"):
		var pre_linked: Vector2i = agent.get_meta("spawner_cell") as Vector2i
		if _spawner_routes.has(pre_linked):
			spawner_cell = pre_linked
	if spawner_cell == INVALID_CELL:
		var from_cell: Vector2i = floorz.local_to_map(floorz.to_local(agent.global_position))
		spawner_cell = _nearest_spawner_cell(from_cell)
	if spawner_cell == INVALID_CELL or not _spawner_routes.has(spawner_cell):
		return false
	var route: Dictionary = _spawner_routes[spawner_cell] as Dictionary
	if not bool(route.get("escape_ready", false)):
		return false
	var escape_group: int = int(route.get("escape_group", -1))
	if escape_group <= IDLE_GROUP:
		return false
	var escape_target_cell: Vector2i = route.get("escape_wall_target_cell", spawner_cell) as Vector2i
	return _attach_agent_to_escape(agent, escape_group, escape_target_cell, spawner_cell)

# Returns true once the agent has been switched to the escape flow group. Only
# fails (false) if agent_manager is missing assign_agent — i.e. nav is unusable.
func _attach_agent_to_escape(agent: Node2D, escape_group: int, escape_target_cell: Vector2i, spawner_cell: Vector2i = INVALID_CELL) -> bool:
	if not agent_manager or not agent_manager.has_method("assign_agent"):
		return false
	var nav_id: int = int(agent.get("nav_id"))
	# Ensure path-follow is cleared before switching to FF group.
	if agent_manager.has_method("detach_agent_path"):
		agent_manager.call("detach_agent_path", nav_id)
	agent_manager.call("assign_agent", agent, escape_group)
	_entry_path_agents.erase(nav_id)
	_astar_in_agents.erase(nav_id)
	_astar_out_agents.erase(nav_id)
	_erase_eating_agent(nav_id)
	if agent_manager.has_method("set_agent_never_rest"):
		agent_manager.call("set_agent_never_rest", nav_id, true)
	if spawner_cell != INVALID_CELL:
		agent.set_meta("spawner_cell", spawner_cell)
	_escaping_agents[nav_id] = {
		"node": agent,
		"target_cell": escape_target_cell,
		"spawner_cell": spawner_cell
	}
	if agent.has_method("stop_eating"):
		agent.call("stop_eating")
	if agent.has_method("start_escape"):
		agent.call("start_escape")
	return true

func _process_escape_arrivals() -> void:
	var arrived: Array[int] = []
	var escaping_ids: Array = _escaping_agents.keys()
	for raw_nav_id in escaping_ids:
		var nav_id: int = int(raw_nav_id)
		if not _escaping_agents.has(nav_id):
			continue
		var data: Dictionary = _escaping_agents[nav_id] as Dictionary
		var raw_agent: Variant = data.get("node", null)
		if not is_instance_valid(raw_agent):
			arrived.append(nav_id)
			continue
		var agent: Node2D = raw_agent as Node2D
		if agent == null:
			arrived.append(nav_id)
			continue
		var target_cell: Vector2i = data.get("target_cell", INVALID_CELL) as Vector2i
		if target_cell != INVALID_CELL and _agent_within_tiles(agent, target_cell, 1):
			_remove_escaped_monster(agent)
			arrived.append(nav_id)

	for nav_id in arrived:
		_escaping_agents.erase(nav_id)
		_erase_eating_agent(nav_id)

func _remove_escaped_monster(agent: Node2D) -> void:
	var nav_id: int = int(agent.get("nav_id"))
	if agent_manager and agent_manager.has_method("unregister_agent"):
		agent_manager.call("unregister_agent", nav_id)
	_entry_path_agents.erase(nav_id)
	if agent.has_method("stop_escape"):
		agent.call("stop_escape")
	agent.remove_from_group("monsters")
	agent.queue_free()

func _nearest_spawner_cell(from_cell: Vector2i) -> Vector2i:
	var best_cell: Vector2i = INVALID_CELL
	var best_dist_sq: int = 2147483647
	for raw_spawner_cell in _spawners.keys():
		var spawner_cell: Vector2i = raw_spawner_cell
		var d: Vector2i = spawner_cell - from_cell
		var dist_sq: int = d.x * d.x + d.y * d.y
		if dist_sq < best_dist_sq:
			best_dist_sq = dist_sq
			best_cell = spawner_cell
	return best_cell

func _agent_reached_cell(agent: Node2D, cell: Vector2i) -> bool:
	var agent_cell: Vector2i = floorz.local_to_map(floorz.to_local(agent.global_position))
	if agent_cell == cell:
		return true
	var tile_size: Vector2 = Vector2(32, 32)
	if floorz and floorz.tile_set:
		var raw_tile_size: Vector2i = floorz.tile_set.get_tile_size()
		tile_size = Vector2(float(raw_tile_size.x), float(raw_tile_size.y))
	return agent.global_position.distance_to(_cell_center(cell)) <= max(tile_size.x, tile_size.y) * 0.5

func _agent_within_tiles(agent: Node2D, cell: Vector2i, tiles: int) -> bool:
	if cell == INVALID_CELL:
		return false
	var agent_cell: Vector2i = floorz.local_to_map(floorz.to_local(agent.global_position))
	var d: Vector2i = agent_cell - cell
	return abs(d.x) <= tiles and abs(d.y) <= tiles

func _occupied_cells() -> Array[Vector2i]:
	var occupied: Array[Vector2i] = []
	for group_name in ["main_chars", "monsters", "player"]:
		for node in get_tree().get_nodes_in_group(group_name):
			if node is Node2D:
				var unit: Node2D = node
				occupied.append(floorz.local_to_map(floorz.to_local(unit.global_position)))
	return occupied

func _find_free_cell_near(start_cell: Vector2i, occupied: Array[Vector2i], max_radius: int = 8) -> Vector2i:
	if start_cell not in occupied and _is_walkable(start_cell):
		return start_cell
	for r in range(1, max_radius + 1):
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				var cell: Vector2i = start_cell + Vector2i(dx, dy)
				if cell not in occupied and _is_walkable(cell):
					return cell
	return INVALID_CELL

func _find_walkable_cell_near(start_cell: Vector2i, max_radius: int = 8) -> Vector2i:
	if _is_walkable(start_cell):
		return start_cell
	for r in range(1, max_radius + 1):
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				var cell: Vector2i = start_cell + Vector2i(dx, dy)
				if _is_walkable(cell):
					return cell
	return INVALID_CELL

func _is_walkable(cell: Vector2i) -> bool:
	return _has_floor(cell) and not _has_wall(cell)

func _rebuild_walkable_map_cache() -> void:
	_walkable_map_tiles.clear()
	if floorz == null:
		return
	for raw_cell in floorz.get_used_cells():
		var cell: Vector2i = raw_cell
		if _is_walkable(cell):
			_walkable_map_tiles[cell] = true

func _has_floor(cell: Vector2i) -> bool:
	return floorz != null and floorz.get_cell_tile_data(cell) != null

func _has_wall(cell: Vector2i) -> bool:
	return wallz != null and wallz.get_cell_tile_data(cell) != null

func _cell_center(cell: Vector2i) -> Vector2:
	return floorz.to_global(floorz.map_to_local(cell))

func _atlas_key(atlas: Vector2i) -> String:
	return "%d,%d" % [atlas.x, atlas.y]

func _tile_layer_signature(layer: TileMapLayer) -> int:
	if not layer:
		return 0
	var signature: int = 17
	for raw_cell in layer.get_used_cells():
		var cell: Vector2i = raw_cell
		var atlas: Vector2i = layer.get_cell_atlas_coords(cell)
		signature += int(cell.x * 73856093 + cell.y * 19349663)
		signature += int(atlas.x * 83492791 + atlas.y * 2654435761)
	return signature

# ---------------------------------------------------------------------------
# Plant zone.
# ---------------------------------------------------------------------------
func _build_plant_zone() -> void:
	if _plant_zone_built:
		return
	_build_gardens_from_plants()
	_validate_dirty_gardens()

func _rebuild_plant_zone_from_layer() -> void:
	_build_gardens_from_plants()
	_validate_dirty_gardens()
	_rebuild_spawner_garden_route_cache()
	# Garden ids/topology just changed: cheaply detect agents now pointing at a
	# deleted/empty garden, park them in "waiting_new_status", and queue them for
	# budgeted retargeting over the next frames. No pathfinding happens here.
	_queue_agents_after_garden_rebuild()

func _build_gardens_from_plants() -> void:
	if _gardens_iter_depth > 0:
		push_warning("GARDEN-CRASH-GUARD: full rebuild requested mid-iteration (depth=%d)!" % _gardens_iter_depth)
	_gardens.clear()
	_garden_by_plant_cell.clear()
	_dirty_gardens.clear()
	_pending_empty_gardens.clear()
	# Do NOT reset _next_garden_id: ids must stay monotonic across rebuilds so a new
	# garden can never reuse a previous garden's id (which would let a stale route
	# falsely match). Bump the epoch so every route from a prior rebuild is stale.
	_gardens_epoch += 1
	if plant_manager == null or not plant_manager.has_method("get_plant_cells"):
		_rebuild_plant_zone_compatibility_cache()
		_plant_zone_built = true
		return
	var plant_cells_from_manager: Array = plant_manager.call("get_plant_cells") as Array
	_cluster_plants_by_walkable_reachability(plant_cells_from_manager)
	_plant_zone_built = true

# Wall-aware clustering. Plants share a garden only if they are walkably
# connected within GARDEN_LINK_DISTANCE. A bounded BFS over walkable cells runs
# once per unassigned seed plant; plants it reaches join the seed's garden and
# are themselves re-seeded so a chain of close, walkably-connected plants forms
# one garden. Walls (non-walkable cells) are never traversed, so they split
# gardens automatically. This is the single cached rebuild used on dirty events.
func _cluster_plants_by_walkable_reachability(plant_cells_from_manager: Array) -> void:
	var unassigned: Dictionary = {}  # Vector2i -> true
	for raw_cell in plant_cells_from_manager:
		var cell: Vector2i = raw_cell
		unassigned[cell] = true

	while not unassigned.is_empty():
		var seed_cell: Vector2i = unassigned.keys()[0] as Vector2i
		var garden_id: int = _create_garden()
		var garden: Dictionary = _gardens[garden_id] as Dictionary
		var plant_cells: Dictionary = garden.get("plant_cells", {}) as Dictionary

		# Plants pending re-seed (BFS bound is measured from each of these).
		var frontier_plants: Array[Vector2i] = [seed_cell]
		unassigned.erase(seed_cell)
		plant_cells[seed_cell] = true
		_garden_by_plant_cell[seed_cell] = garden_id

		while not frontier_plants.is_empty():
			var from_plant: Vector2i = frontier_plants.pop_back()
			var reached: Array[Vector2i] = _bounded_walkable_plant_search(from_plant, unassigned)
			for reached_cell in reached:
				unassigned.erase(reached_cell)
				plant_cells[reached_cell] = true
				_garden_by_plant_cell[reached_cell] = garden_id
				frontier_plants.append(reached_cell)

		garden["plant_cells"] = plant_cells
		garden["edible_count"] = plant_cells.size()
		garden["targetable"] = false
		_gardens[garden_id] = garden
		_mark_garden_dirty(garden_id, false)

# Bounded BFS through walkable cells from a seed plant cell. Returns every cell in
# `unassigned` reachable within GARDEN_LINK_DISTANCE walkable steps. The seed cell
# itself is treated as the start even though plant cells must be walkable to be
# eaten; only walkable cells are expanded so walls cannot be crossed.
func _bounded_walkable_plant_search(seed_cell: Vector2i, unassigned: Dictionary) -> Array[Vector2i]:
	var found: Array[Vector2i] = []
	var visited: Dictionary = {seed_cell: 0}
	var queue: Array[Vector2i] = [seed_cell]
	var head: int = 0
	while head < queue.size():
		var cell: Vector2i = queue[head]
		head += 1
		var dist: int = int(visited[cell])
		if dist >= GARDEN_LINK_DISTANCE:
			continue
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if dx == 0 and dy == 0:
					continue
				var neighbor: Vector2i = cell + Vector2i(dx, dy)
				if visited.has(neighbor):
					continue
				if not _is_walkable(neighbor):
					continue
				# Match the pathfinder: no diagonal corner-cutting through walls.
				# A diagonal step is only valid if both orthogonal neighbors are
				# walkable, otherwise two plants tucked behind a wall corner would
				# look connected here but be unreachable to a monster.
				if dx != 0 and dy != 0:
					if not _is_walkable(cell + Vector2i(dx, 0)) or not _is_walkable(cell + Vector2i(0, dy)):
						continue
				visited[neighbor] = dist + 1
				queue.append(neighbor)
				if unassigned.has(neighbor):
					found.append(neighbor)
	return found

# A new plant invalidates clustering near it (it may bridge or seed a garden).
# Plant counts are small, so a single cached rebuild is the clean, correct path.
func _add_plant_to_gardens(cell: Vector2i) -> void:
	if _garden_by_plant_cell.has(cell):
		return
	_rebuild_plant_zone_from_layer()

# Canonical runtime plant-removal mutation. CONTENT-ONLY: it edits the garden's
# plant set and derived counts and nothing else. It deliberately does NOT touch
# zone_tiles / margin_tiles / entry_cells / reachable, and never triggers a full
# rebuild, geometry recompute, or dirty-garden validation. Garden doors stay
# stable while monsters eat plants. Returns a small status dictionary so the
# caller can decide how (and whether) to retarget agents — see _on_plant_removed.
#
# Accepted compromise: removing a plant never splits a garden. If the removed
# plant was the bridge between two walkable clusters, the survivors stay in the
# same historical garden (same id, same entry cells) until the next FULL topology
# rebuild. This is intentional: stable entry points + no per-eat rebuild cost.
func _remove_plant_from_garden_content_only(cell: Vector2i) -> Dictionary:
	if not _garden_by_plant_cell.has(cell):
		return {
			"garden_id": 0,
			"was_removed": false,
			"became_empty": false,
			"remaining_count": 0
		}
	var garden_id: int = int(_garden_by_plant_cell[cell])
	_garden_by_plant_cell.erase(cell)
	if not _gardens.has(garden_id):
		# Mapping pointed at a garden that no longer exists. Treat it as removed and
		# empty so the caller still gives bound agents a fresh target.
		return {
			"garden_id": garden_id,
			"was_removed": true,
			"became_empty": true,
			"remaining_count": 0
		}
	var garden: Dictionary = _gardens[garden_id] as Dictionary
	var plant_cells: Dictionary = garden.get("plant_cells", {}) as Dictionary
	plant_cells.erase(cell)
	var remaining_count: int = plant_cells.size()
	# Content-only updates. zone_tiles / margin_tiles / entry_cells / reachable are
	# intentionally left untouched so the garden keeps its stable doors.
	garden["plant_cells"] = plant_cells
	garden["edible_count"] = remaining_count
	if remaining_count == 0:
		garden["targetable"] = false
	else:
		garden["targetable"] = bool(garden.get("reachable", false))
	_gardens[garden_id] = garden
	# When the garden just went empty we DON'T erase it here: the caller must first
	# queue the agents bound to it (it still needs the garden's data) and then call
	# _handle_garden_became_empty(), which releases routes and erases the garden.
	return {
		"garden_id": garden_id,
		"was_removed": true,
		"became_empty": remaining_count == 0,
		"remaining_count": remaining_count
	}

# TEMP DEBUG (garden crash hunt) -------------------------------------------
# Centralized garden erase. Empty gardens are allowed to disappear immediately;
# other mid-iteration erases still log because they are harder to reason about.
func _erase_garden(garden_id: int, reason: String) -> void:
	if _gardens_iter_depth > 0 and reason != "mark_empty":
		push_warning("GARDEN-CRASH-GUARD: _gardens erased during iteration! id=%d reason=%s depth=%d size_before=%d" % [
			garden_id, reason, _gardens_iter_depth, _gardens.size()
		])
	if _garden_debug_logs:
		_log("garden erase id=%d reason=%s gardens_now=%d" % [garden_id, reason, _gardens.size() - 1])
	_pending_empty_gardens.erase(garden_id)
	_gardens.erase(garden_id)
	_dirty_gardens.erase(garden_id)
	if _plant_zone_built:
		_rebuild_plant_zone_compatibility_cache()
	if _zone_overlay:
		_zone_overlay.queue_redraw()

# TEMP DEBUG (lost-agent / OUT OF BOUNDS hunt): a cell is "sane" only if it is a
# real, finite, in-a-reasonable-range tile. A bad cell (INVALID_CELL sentinel,
# max_cell sentinel, or anything absurd) fed to _cell_center yields a huge finite
# world pos; assigning that as a flow goal or an agent position makes the agent
# map to an out-of-bounds cell and go "lost" forever. Reject + log instead.
const _SANE_CELL_LIMIT: int = 100000
func _is_sane_cell(cell: Vector2i) -> bool:
	if cell == INVALID_CELL:
		return false
	if abs(cell.x) > _SANE_CELL_LIMIT or abs(cell.y) > _SANE_CELL_LIMIT:
		return false
	return true
# --------------------------------------------------------------------------

func _create_garden() -> int:
	var garden_id: int = _next_garden_id
	_next_garden_id += 1
	_gardens[garden_id] = {
		"id": garden_id,
		"epoch": _gardens_epoch,
		"plant_cells": {},
		"zone_tiles": {},
		"margin_tiles": {},
		"entry_cells": [],
		"edible_count": 0,
		"targetable": false,
		"dirty": true,
		"reachable": false,
		"version": 0
	}
	_dirty_gardens[garden_id] = true
	return garden_id

func _mark_garden_dirty(garden_id: int, invalidate_routes: bool) -> void:
	if not _gardens.has(garden_id):
		return
	var garden: Dictionary = _gardens[garden_id] as Dictionary
	garden["dirty"] = true
	if invalidate_routes:
		garden["reachable"] = false
		garden["targetable"] = false
		garden["version"] = int(garden.get("version", 0)) + 1
	_gardens[garden_id] = garden
	_dirty_gardens[garden_id] = true

func _validate_dirty_gardens() -> void:
	if _dirty_gardens.is_empty():
		_rebuild_plant_zone_compatibility_cache()
		return
	var dirty_ids: Array = _dirty_gardens.keys()
	_dirty_gardens.clear()
	for raw_garden_id in dirty_ids:
		var garden_id: int = int(raw_garden_id)
		if not _gardens.has(garden_id):
			continue
		var garden: Dictionary = _gardens[garden_id] as Dictionary
		var plant_cells: Dictionary = garden.get("plant_cells", {}) as Dictionary
		if plant_cells.is_empty():
			_release_garden_routes(garden_id)
			_erase_garden(garden_id, "validate_empty")
			continue
		_recompute_garden_geometry(garden_id)
	# No proximity-based merge step: garden identity comes from walkable BFS
	# clustering in _build_gardens_from_plants. Merging by margin/zone-tile
	# adjacency here would re-join gardens separated by a thin wall (their
	# wall-skipping margin tiles can meet around a corner), which is exactly the
	# bug this change fixes. Geometry below is per-cluster only.
	# A sealed enclosure has walkable interior tiles, so entry_cells alone is not
	# enough to call it reachable. Flood from spawners once and gate every garden
	# on whether an entry cell is reachable from a spawner.
	_recompute_spawner_reachable_cells()
	_gardens_iter_depth += 1
	var total_entry_points: int = 0
	for raw_garden_id in _gardens.keys():
		var gid: int = int(raw_garden_id)
		_apply_spawner_reachability(gid)
		total_entry_points += (_gardens[gid] as Dictionary).get("entry_cells", []).size()
	_gardens_iter_depth -= 1
	_rebuild_plant_zone_compatibility_cache()
	_plant_zone_built = true
	if _zone_overlay:
		_zone_overlay.queue_redraw()
	if _is_verbose():
		print("BuildingManager: %d gardens recomputed with %d entry points" % [_gardens.size(), total_entry_points])

# Garden geometry is navigation-aware, not box-geometry. A bounded walkable BFS
# from the plant cells (same 8-conn, no-corner-cut rules as the pathfinder/cluster
# BFS) defines the interior `zone_tiles`, so a thin wall or corner can never leak a
# zone tile to the far side of a wall (fix: the old Chebyshev margin box only
# skipped cells that *were* walls). Access cells (`entry_cells`) are the INTERIOR
# cells that border the outside through a valid no-corner-cut transition — they are
# in zone_tiles so the monster's flow field can settle on one (an outside goal at a
# 1-tile chokepoint makes agents oscillate, status "flow osc"). Access cells are
# non-exclusive and may overlap spawners/exits/markers; only non-walkability rejects.
func _recompute_garden_geometry(garden_id: int) -> void:
	var garden: Dictionary = _gardens[garden_id] as Dictionary
	var plant_cells: Dictionary = garden.get("plant_cells", {}) as Dictionary

	# Interior: walkable cells reachable from any plant within PLANT_ZONE_MARGIN
	# walkable steps. Plant cells seed the BFS and are always part of the interior.
	var zone_tiles: Dictionary = {}  # Vector2i -> true (interior, incl. plant cells)
	var dist: Dictionary = {}  # Vector2i -> walkable steps from nearest plant
	var queue: Array[Vector2i] = []
	var head: int = 0
	for raw_cell in plant_cells.keys():
		var plant_cell: Vector2i = raw_cell
		zone_tiles[plant_cell] = true
		dist[plant_cell] = 0
		queue.append(plant_cell)

	# Access detection: an access transition is a walkable interior cell that has a
	# valid step to a walkable cell *outside* the bounded interior. We record the
	# INSIDE cell of each such transition as the entry cell, not the outside cell:
	# the monster's flow field aims here and it must be a tile the agent can settle
	# on (surrounded by interior), otherwise it oscillates against the wall/gap at a
	# one-tile chokepoint and never hands off to A*. The inside cell is in
	# zone_tiles, so A* in/out, arrival, and pathing all work without snapping.
	var entry_inside: Dictionary = {}  # Vector2i -> true (interior cells that touch outside)

	while head < queue.size():
		var cell: Vector2i = queue[head]
		head += 1
		var cell_dist: int = int(dist[cell])
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if dx == 0 and dy == 0:
					continue
				var neighbor: Vector2i = cell + Vector2i(dx, dy)
				if not _is_walkable(neighbor):
					continue
				# No diagonal corner-cutting through walls (matches the pathfinder),
				# so a transition is only valid when a monster could really take it.
				if dx != 0 and dy != 0:
					if not _is_walkable(cell + Vector2i(dx, 0)) or not _is_walkable(cell + Vector2i(0, dy)):
						continue
				if zone_tiles.has(neighbor):
					continue
				var next_dist: int = cell_dist + 1
				if next_dist <= PLANT_ZONE_MARGIN:
					# Still inside the bounded interior.
					if not dist.has(neighbor) or next_dist < int(dist[neighbor]):
						dist[neighbor] = next_dist
						zone_tiles[neighbor] = true
						queue.append(neighbor)
				else:
					# `cell` (interior) has a valid transition to `neighbor`, a
					# walkable cell beyond the interior: `cell` is an access cell.
					entry_inside[cell] = true

	# margin_tiles keeps its prior meaning for the overlay/compat cache: interior
	# tiles that are not plant cells. Entry cells are the interior access cells
	# (cells that border the outside through a valid transition); the flow field
	# and arrival target these.
	var margin_tiles: Dictionary = {}
	for raw_cell in zone_tiles.keys():
		var zone_cell: Vector2i = raw_cell
		if not plant_cells.has(zone_cell):
			margin_tiles[zone_cell] = true
	var entry_cells: Array[Vector2i] = []
	for raw_cell in entry_inside.keys():
		var access_cell: Vector2i = raw_cell
		entry_cells.append(access_cell)

	garden["zone_tiles"] = zone_tiles
	garden["margin_tiles"] = margin_tiles
	garden["entry_cells"] = entry_cells
	# Provisional: refined by _apply_spawner_reachability once the spawner flood
	# is available. A garden with no walkable access tile can never be reachable.
	garden["reachable"] = not entry_cells.is_empty()
	garden["edible_count"] = plant_cells.size()
	garden["targetable"] = plant_cells.size() > 0 and not entry_cells.is_empty()
	garden["dirty"] = false
	_gardens[garden_id] = garden

# Single source flood-fill from every spawner cell over the walkable map (same
# walkability + diagonal corner rules as the pathfinder). Bounded by the floor
# tilemap because expansion requires _has_floor. Runs once per garden rebuild.
func _recompute_spawner_reachable_cells() -> void:
	_spawner_reachable_cells.clear()
	if _spawners.is_empty():
		return
	var queue: Array[Vector2i] = []
	var head: int = 0
	for raw_spawner_cell in _spawners.keys():
		var spawner_cell: Vector2i = raw_spawner_cell
		# Start from the spawner's walkable footprint; spawners may sit on a
		# non-walkable special tile, so seed from walkable neighbors too.
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var myseed: Vector2i = spawner_cell + Vector2i(dx, dy)
				if _spawner_reachable_cells.has(myseed):
					continue
				if not _is_walkable(myseed):
					continue
				_spawner_reachable_cells[myseed] = true
				queue.append(myseed)
	while head < queue.size():
		var cell: Vector2i = queue[head]
		head += 1
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if dx == 0 and dy == 0:
					continue
				var neighbor: Vector2i = cell + Vector2i(dx, dy)
				if _spawner_reachable_cells.has(neighbor):
					continue
				if not _is_walkable(neighbor):
					continue
				if dx != 0 and dy != 0:
					if not _is_walkable(cell + Vector2i(dx, 0)) or not _is_walkable(cell + Vector2i(0, dy)):
						continue
				_spawner_reachable_cells[neighbor] = true
				queue.append(neighbor)

# A garden is reachable only if one of its walkable entry cells is in the spawner
# flood. Sealed enclosures (no entry cell connects out to a spawner) become
# unreachable and non-targetable, so outside monsters ignore them.
func _apply_spawner_reachability(garden_id: int) -> void:
	if not _gardens.has(garden_id):
		return
	var garden: Dictionary = _gardens[garden_id] as Dictionary
	var entry_cells: Array = garden.get("entry_cells", []) as Array
	# With no spawners, fall back to "has entry cell" so editor/preview still
	# shows gardens instead of marking everything unreachable.
	var reachable: bool = false
	if _spawners.is_empty():
		reachable = not entry_cells.is_empty()
	else:
		for raw_cell in entry_cells:
			var entry_cell: Vector2i = raw_cell
			if _spawner_reachable_cells.has(entry_cell):
				reachable = true
				break
	garden["reachable"] = reachable
	var plant_cells: Dictionary = garden.get("plant_cells", {}) as Dictionary
	garden["targetable"] = reachable and plant_cells.size() > 0
	_gardens[garden_id] = garden

func _rebuild_plant_zone_compatibility_cache() -> void:
	_plant_zone_tiles.clear()
	_plant_zone_margin_tiles.clear()
	for raw_garden in _gardens.values():
		var garden: Dictionary = raw_garden as Dictionary
		var zone_tiles: Dictionary = garden.get("zone_tiles", {}) as Dictionary
		var margin_tiles: Dictionary = garden.get("margin_tiles", {}) as Dictionary
		var plant_cells: Dictionary = garden.get("plant_cells", {}) as Dictionary
		for raw_cell in zone_tiles.keys():
			var zone_cell: Vector2i = raw_cell
			_plant_zone_tiles[zone_cell] = true
		for raw_cell in margin_tiles.keys():
			var margin_cell: Vector2i = raw_cell
			_plant_zone_margin_tiles[margin_cell] = true
		if bool(garden.get("dirty", false)):
			for raw_cell in plant_cells.keys():
				var plant_cell: Vector2i = raw_cell
				_plant_zone_tiles[plant_cell] = true

# Snapshot both key sets: _release_spawner_garden_route erases from `routes` (inner)
# and can erase from _spawner_garden_routes (outer) when a spawner's routes empty.
# Iterating live .keys() while erasing is the Dictionary-mutation-during-iteration
# that can silently crash; .duplicate() decouples the iteration from the mutation.
func _rebuild_spawner_garden_route_cache() -> void:
	for raw_spawner_cell in _spawner_garden_routes.keys().duplicate():
		var spawner_cell: Vector2i = raw_spawner_cell
		if not _spawner_garden_routes.has(spawner_cell):
			continue
		var routes: Dictionary = _spawner_garden_routes[spawner_cell] as Dictionary
		for raw_garden_id in routes.keys().duplicate():
			var garden_id: int = int(raw_garden_id)
			if not routes.has(garden_id):
				continue
			var route: Dictionary = routes[garden_id] as Dictionary
			if not _garden_route_is_current(route, garden_id):
				_release_spawner_garden_route(spawner_cell, garden_id)

func _release_garden_routes(garden_id: int) -> void:
	# Snapshot: _release_spawner_garden_route can erase from _spawner_garden_routes.
	for raw_spawner_cell in _spawner_garden_routes.keys().duplicate():
		var spawner_cell: Vector2i = raw_spawner_cell
		_release_spawner_garden_route(spawner_cell, garden_id)

func _release_spawner_garden_route(spawner_cell: Vector2i, garden_id: int) -> void:
	if not _spawner_garden_routes.has(spawner_cell):
		return
	var routes: Dictionary = _spawner_garden_routes[spawner_cell] as Dictionary
	if not routes.has(garden_id):
		return
	var route: Dictionary = routes[garden_id] as Dictionary
	var plant_group: int = int(route.get("plant_group", -1))
	if plant_group > IDLE_GROUP and agent_manager and agent_manager.has_method("dissolve_group"):
		agent_manager.call("dissolve_group", plant_group)
	routes.erase(garden_id)
	if routes.is_empty():
		_spawner_garden_routes.erase(spawner_cell)
	else:
		_spawner_garden_routes[spawner_cell] = routes

func _garden_route_is_current(route: Dictionary, garden_id: int) -> bool:
	if not _gardens.has(garden_id):
		return false
	var garden: Dictionary = _gardens[garden_id] as Dictionary
	if not bool(garden.get("reachable", false)):
		return false
	# Epoch first: a route from a previous full rebuild can never be current even if
	# its (id, version) coincidentally matches a new garden. This is what stops
	# night-2 agents from flowing to a deleted night-1 garden's entry tile.
	if int(route.get("garden_epoch", -1)) != int(garden.get("epoch", -2)):
		return false
	return int(route.get("garden_version", -1)) == int(garden.get("version", 0))

func _select_garden_for_spawner(spawner_cell: Vector2i) -> int:
	var best_garden_id: int = 0
	var best_dist: int = 2147483647
	_gardens_iter_depth += 1
	for raw_garden_id in _gardens.keys():
		var garden_id: int = int(raw_garden_id)
		var garden: Dictionary = _gardens[garden_id] as Dictionary
		if not bool(garden.get("targetable", false)):
			continue
		if not _garden_has_edible_plants(garden_id):
			continue
		var entry_cell: Vector2i = _nearest_garden_entry(garden_id, spawner_cell)
		if entry_cell == INVALID_CELL:
			continue
		var delta: Vector2i = entry_cell - spawner_cell
		var manhattan: int = abs(delta.x) + abs(delta.y)
		if manhattan < best_dist:
			best_dist = manhattan
			best_garden_id = garden_id
	_gardens_iter_depth -= 1
	_drain_pending_empty_gardens()
	# The chosen garden may have just been drained as empty; fall through to 0.
	if best_garden_id > 0 and not _gardens.has(best_garden_id):
		return 0
	return best_garden_id

func _select_spawner_garden_for_agent(from_cell: Vector2i) -> Dictionary:
	var best_pair: Dictionary = {}
	var best_dist: int = 2147483647
	_gardens_iter_depth += 1
	for raw_spawner_cell in _spawners.keys():
		var spawner_cell: Vector2i = raw_spawner_cell
		if not _spawner_routes.has(spawner_cell):
			continue
		for raw_garden_id in _gardens.keys():
			var garden_id: int = int(raw_garden_id)
			var garden: Dictionary = _gardens[garden_id] as Dictionary
			if not bool(garden.get("targetable", false)):
				continue
			if not _garden_has_edible_plants(garden_id):
				continue
			var entry_cell: Vector2i = _nearest_garden_entry(garden_id, spawner_cell)
			if entry_cell == INVALID_CELL:
				continue
			var delta: Vector2i = entry_cell - from_cell
			var manhattan: int = abs(delta.x) + abs(delta.y)
			if manhattan < best_dist:
				best_dist = manhattan
				best_pair = {
					"spawner_cell": spawner_cell,
					"garden_id": garden_id
				}
	_gardens_iter_depth -= 1
	_drain_pending_empty_gardens()
	# The chosen garden may have just been drained as empty; drop the stale pair.
	if not best_pair.is_empty() and not _gardens.has(int(best_pair.get("garden_id", 0))):
		return {}
	return best_pair

func _select_spawner_for_garden_from_cell(garden_id: int, from_cell: Vector2i, fallback_spawner_cell: Vector2i) -> Vector2i:
	var best_spawner_cell: Vector2i = INVALID_CELL
	var best_dist: int = 2147483647
	for raw_spawner_cell in _spawners.keys():
		var spawner_cell: Vector2i = raw_spawner_cell
		if not _spawner_routes.has(spawner_cell):
			continue
		var entry_cell: Vector2i = _nearest_garden_entry(garden_id, spawner_cell)
		if entry_cell == INVALID_CELL:
			continue
		var delta: Vector2i = entry_cell - from_cell
		var manhattan: int = abs(delta.x) + abs(delta.y)
		if manhattan < best_dist:
			best_dist = manhattan
			best_spawner_cell = spawner_cell
	if best_spawner_cell == INVALID_CELL and fallback_spawner_cell != INVALID_CELL and _spawner_routes.has(fallback_spawner_cell):
		if _nearest_garden_entry(garden_id, fallback_spawner_cell) != INVALID_CELL:
			best_spawner_cell = fallback_spawner_cell
	return best_spawner_cell

func _find_local_retarget_plant(from_cell: Vector2i) -> Dictionary:
	if empty_garden_local_retarget_radius <= 0:
		return {}
	if plant_manager == null or not plant_manager.has_method("has_plant"):
		return {}
	var radius: int = maxi(0, empty_garden_local_retarget_radius)
	var best_target: Dictionary = {}
	var best_path_len: int = 2147483647
	var best_dist: int = 2147483647
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var manhattan: int = abs(dx) + abs(dy)
			if manhattan > radius:
				continue
			var plant_cell: Vector2i = from_cell + Vector2i(dx, dy)
			if not bool(plant_manager.call("has_plant", plant_cell)):
				continue
			if not _garden_by_plant_cell.has(plant_cell):
				continue
			var garden_id: int = int(_garden_by_plant_cell[plant_cell])
			if not _garden_has_edible_plants(garden_id):
				continue
			var path_cells: PackedVector2Array = _find_path_in_zone(from_cell, plant_cell, garden_id)
			if path_cells.is_empty():
				continue
			var path_len: int = path_cells.size()
			if path_len < best_path_len or (path_len == best_path_len and manhattan < best_dist):
				best_path_len = path_len
				best_dist = manhattan
				best_target = {
					"plant_cell": plant_cell,
					"garden_id": garden_id,
					"path_cells": path_cells
				}
	# _garden_has_edible_plants may have queued stale-empty gardens; this search
	# does not iterate _gardens, so draining here is safe.
	_drain_pending_empty_gardens()
	if not best_target.is_empty() and not _gardens.has(int(best_target.get("garden_id", 0))):
		return {}
	return best_target

func _try_local_retarget_agent(agent: Node2D, from_cell: Vector2i, spawner_cell: Vector2i) -> bool:
	var target: Dictionary = _find_local_retarget_plant(from_cell)
	if target.is_empty():
		return false
	var plant_cell: Vector2i = target.get("plant_cell", INVALID_CELL) as Vector2i
	var garden_id: int = int(target.get("garden_id", 0))
	var path_cells: PackedVector2Array = target.get("path_cells", PackedVector2Array()) as PackedVector2Array
	if plant_cell == INVALID_CELL or garden_id <= 0 or path_cells.is_empty():
		return false
	var route_spawner_cell: Vector2i = _select_spawner_for_garden_from_cell(garden_id, from_cell, spawner_cell)
	if route_spawner_cell == INVALID_CELL:
		return false
	var nav_id: int = int(agent.get("nav_id"))
	if agent_manager and agent_manager.has_method("detach_agent_flow"):
		agent_manager.call("detach_agent_flow", nav_id)
	var path_world: PackedVector2Array = _path_cells_to_world(path_cells)
	if agent_manager and agent_manager.has_method("assign_agent_path"):
		agent_manager.call("assign_agent_path", nav_id, path_world)
	_entry_path_agents.erase(nav_id)
	_astar_in_agents[nav_id] = {
		"node": agent,
		"plant_cell": plant_cell,
		"spawner_cell": route_spawner_cell,
		"garden_id": garden_id,
		"path_world": path_world
	}
	_astar_out_agents.erase(nav_id)
	agent.set_meta("spawner_cell", route_spawner_cell)
	agent.set_meta("garden_id", garden_id)
	# Only record the entry tile once it is known valid, so the later exit-tile
	# exclusion in _start_astar_out has a trustworthy reference.
	var in_entry_cell: Vector2i = _nearest_garden_entry(garden_id, route_spawner_cell)
	if in_entry_cell != INVALID_CELL:
		agent.set_meta("garden_entry_cell", in_entry_cell)
	if agent.has_method("start_astar_in"):
		agent.call("start_astar_in")
	return true

func _assign_agent_to_garden_entry_path(agent: Node2D, spawner_cell: Vector2i, garden_id: int, entry_cell: Vector2i) -> bool:
	if not is_instance_valid(agent):
		return false
	if entry_cell == INVALID_CELL or not _is_sane_cell(entry_cell):
		return false
	if agent_manager == null or not agent_manager.has_method("assign_agent_path"):
		return false
	var nav_id: int = int(agent.get("nav_id"))
	var from_cell: Vector2i = floorz.local_to_map(floorz.to_local(agent.global_position))
	var path_cells: PackedVector2Array = _find_path_on_walkable_map(from_cell, entry_cell)
	if path_cells.is_empty():
		return false
	if agent_manager.has_method("detach_agent_flow"):
		agent_manager.call("detach_agent_flow", nav_id)
	if agent_manager.has_method("detach_agent_path"):
		agent_manager.call("detach_agent_path", nav_id)
	var path_world: PackedVector2Array = _path_cells_to_world(path_cells)
	agent_manager.call("assign_agent_path", nav_id, path_world)
	_entry_path_agents[nav_id] = {
		"node": agent,
		"spawner_cell": spawner_cell,
		"garden_id": garden_id,
		"entry_cell": entry_cell,
		"path_world": path_world
	}
	_astar_in_agents.erase(nav_id)
	_astar_out_agents.erase(nav_id)
	_escaping_agents.erase(nav_id)
	agent.set_meta("spawner_cell", spawner_cell)
	agent.set_meta("garden_id", garden_id)
	agent.set_meta("garden_entry_cell", entry_cell)
	# Heading toward the garden, not yet eaten: "flow in". The inside-garden A* leg
	# transitions to "astar in" in _start_astar_in once the entry is reached.
	if agent.has_method("start_flow_in"):
		agent.call("start_flow_in")
	return true

func _get_or_create_spawner_garden_route(spawner_cell: Vector2i, garden_id: int) -> Dictionary:
	if not _spawner_garden_routes.has(spawner_cell):
		_spawner_garden_routes[spawner_cell] = {}
	var routes: Dictionary = _spawner_garden_routes[spawner_cell] as Dictionary
	var existing_route: Dictionary = routes.get(garden_id, {}) as Dictionary
	if bool(existing_route.get("ready", false)) and _garden_route_is_current(existing_route, garden_id):
		return existing_route
	if not _gardens.has(garden_id):
		return {"ready": false}
	var garden: Dictionary = _gardens[garden_id] as Dictionary
	var entry_cell: Vector2i = _nearest_garden_entry(garden_id, spawner_cell)
	if entry_cell == INVALID_CELL:
		return {"ready": false}
	if not _is_sane_cell(entry_cell):
		push_warning("LOST-AGENT-GUARD: garden %d gave insane entry_cell %s for spawner %s; route refused" % [
			garden_id, entry_cell, spawner_cell
		])
		return {"ready": false}
	var entry_world: Vector2 = _cell_center(entry_cell)
	if not _is_finite_world(entry_world):
		push_warning("LOST-AGENT-GUARD: insane entry_world %s (cell %s) for spawner %s garden %d; route refused" % [
			entry_world, entry_cell, spawner_cell, garden_id
		])
		return {"ready": false}
	var route: Dictionary = {
		"entry_cell": entry_cell,
		"entry_world": entry_world,
		"ready": true,
		"garden_version": int(garden.get("version", 0)),
		"garden_epoch": int(garden.get("epoch", -1))
	}
	routes[garden_id] = route
	_spawner_garden_routes[spawner_cell] = routes
	return route

# Returns true once the agent has a real new nav state (a garden entry path, or a
# successfully assigned escape). Returns false only when neither a garden route nor
# an escape could be assigned, so the budgeted queue can requeue it. Every escape
# fallback below propagates _assign_agent_to_escape's own success/failure.
func _retarget_agent_or_escape(agent: Node2D, spawner_cell: Vector2i) -> bool:
	if not is_instance_valid(agent):
		return false
	if _no_plants_remaining():
		return _assign_agent_to_escape(agent)
	var from_cell: Vector2i = floorz.local_to_map(floorz.to_local(agent.global_position))
	if _try_local_retarget_agent(agent, from_cell, spawner_cell):
		return true
	var pair: Dictionary = _select_spawner_garden_for_agent(from_cell)
	if pair.is_empty():
		if spawner_cell == INVALID_CELL:
			spawner_cell = _nearest_spawner_cell(from_cell)
		if spawner_cell != INVALID_CELL and _spawner_routes.has(spawner_cell):
			agent.set_meta("spawner_cell", spawner_cell)
		return _assign_agent_to_escape(agent)
	spawner_cell = pair.get("spawner_cell", INVALID_CELL) as Vector2i
	var garden_id: int = int(pair.get("garden_id", 0))
	if garden_id <= 0:
		return _assign_agent_to_escape(agent)
	var route: Dictionary = _get_or_create_spawner_garden_route(spawner_cell, garden_id)
	if not bool(route.get("ready", false)):
		return _assign_agent_to_escape(agent)
	var entry_cell: Vector2i = route.get("entry_cell", INVALID_CELL) as Vector2i
	if entry_cell == INVALID_CELL:
		return _assign_agent_to_escape(agent)
	if not _assign_agent_to_garden_entry_path(agent, spawner_cell, garden_id, entry_cell):
		return _assign_agent_to_escape(agent)
	var nav_id: int = int(agent.get("nav_id"))
	if agent_manager.has_method("set_agent_never_rest"):
		agent_manager.call("set_agent_never_rest", nav_id, true)
	return true

# ---------------------------------------------------------------------------
# Budgeted retargeting after a garden topology rebuild.
#
# A rebuild clears _gardens and bumps the epoch, so any agent still holding a
# garden_id from before can be referencing a deleted/empty garden. Re-pathing all
# of them in the rebuild frame risks a large spike, so we split the work:
#   1. _queue_agents_after_garden_rebuild() — one-shot, cheap. Detects affected
#      agents, detaches their stale path/flow, parks them in "waiting_new_status",
#      and queues them. NO pathfinding here.
#   2. _process_garden_retarget_queue() — runs each frame, capped at
#      garden_retarget_budget_per_frame, doing the expensive re-path/escape.
# ---------------------------------------------------------------------------

# Resolve the agent node for a nav_id without scanning the monsters group.
# AgentManagerNative keeps an id -> node map, so find_node_by_agent is O(1).
func _agent_from_nav_id(nav_id: int) -> Node2D:
	if agent_manager and agent_manager.has_method("find_node_by_agent"):
		var node: Variant = agent_manager.call("find_node_by_agent", nav_id)
		if is_instance_valid(node) and node is Node2D:
			return node as Node2D
	return null

# A garden assignment is stale (needs retargeting) when:
#   - the garden no longer exists in _gardens, or
#   - it exists but has no edible plants (matches the route-validity logic used
#     elsewhere). garden_id <= 0 means "no garden assigned" and is never stale.
func _garden_assignment_is_stale(garden_id: int) -> bool:
	if garden_id <= 0:
		return false
	if not _gardens.has(garden_id):
		return true
	if not _garden_has_edible_plants(garden_id):
		return true
	return false

# Cheapest available view of which garden an agent is currently bound to, checked
# in phase priority order (the dictionaries reflect the agent's live phase, the
# meta is the last-known fallback). Returns 0 when no garden is referenced.
func _agent_referenced_garden_id(nav_id: int, agent: Node2D) -> int:
	if _entry_path_agents.has(nav_id):
		return int((_entry_path_agents[nav_id] as Dictionary).get("garden_id", 0))
	if _astar_in_agents.has(nav_id):
		return int((_astar_in_agents[nav_id] as Dictionary).get("garden_id", 0))
	if _astar_out_agents.has(nav_id):
		return int((_astar_out_agents[nav_id] as Dictionary).get("garden_id", 0))
	if _eating_agents.has(nav_id):
		var eat_garden: int = int((_eating_agents[nav_id] as Dictionary).get("garden_id", 0))
		if eat_garden > 0:
			return eat_garden
		# garden_id missing/0 on the eating entry: fall through to the meta below.
	if is_instance_valid(agent) and agent.has_meta("garden_id"):
		return int(agent.get_meta("garden_id"))
	return 0

# Shared enqueue path for ALL budgeted retargeting (full rebuild, empty-garden,
# escape-all). Cheaply detaches the agent's stale path/flow, forgets its current
# phase, parks it in "waiting_new_status", and appends one queue item. NO new
# path/flow is computed here — that is deferred to _process_garden_retarget_queue.
# Dedups on _garden_retarget_queued so an agent is never enqueued twice. Keeping
# this in one place guarantees identical queue behaviour across every caller.
func _queue_agent_for_garden_retarget(nav_id: int, agent: Node2D, intent: String, spawner_cell: Vector2i, garden_id: int) -> void:
	if nav_id < 0 or not is_instance_valid(agent):
		return
	if _garden_retarget_queued.has(nav_id):
		return
	# Cheaply detach stale path/flow so the agent stops following an invalid route
	# immediately. The real re-route happens later in the budgeted queue.
	if agent_manager and agent_manager.has_method("detach_agent_path"):
		agent_manager.call("detach_agent_path", nav_id)
	if agent_manager and agent_manager.has_method("detach_agent_flow"):
		agent_manager.call("detach_agent_flow", nav_id)
	_entry_path_agents.erase(nav_id)
	_astar_in_agents.erase(nav_id)
	_astar_out_agents.erase(nav_id)
	_escaping_agents.erase(nav_id)
	if _eating_agents.has(nav_id):
		_erase_eating_agent(nav_id)
		if agent.has_method("stop_eating"):
			agent.call("stop_eating")
	if agent.has_method("start_waiting_new_status"):
		agent.call("start_waiting_new_status")
	_garden_retarget_queue.append({
		"nav_id": nav_id,
		"intent": intent,
		"spawner_cell": spawner_cell,
		"garden_id": garden_id
	})
	_garden_retarget_queued[nav_id] = true

# One-shot scan after a FULL garden rebuild. Cheap checks only: detect agents whose
# garden reference is now stale, enqueue each via the shared helper. The expensive
# re-path/escape is deferred to the budgeted queue. Iterates a snapshot of the
# monsters group so the helper's per-agent erases never mutate a live iteration.
func _queue_agents_after_garden_rebuild() -> void:
	for node in get_tree().get_nodes_in_group("monsters"):
		if not (node is Node2D):
			continue
		var agent: Node2D = node
		var nav_id: int = int(agent.get("nav_id"))
		if nav_id < 0:
			continue
		if _garden_retarget_queued.has(nav_id):
			continue
		var garden_id: int = _agent_referenced_garden_id(nav_id, agent)
		if not _garden_assignment_is_stale(garden_id):
			continue
		# Decide intent BEFORE the helper clears the agent's phase dictionaries:
		# agents that were leaving or eating should head for the exit, everyone else
		# retargets.
		var intent: String = "retarget"
		if _astar_out_agents.has(nav_id) or _eating_agents.has(nav_id):
			intent = "escape"
		var spawner_cell: Vector2i = INVALID_CELL
		if agent.has_meta("spawner_cell"):
			spawner_cell = agent.get_meta("spawner_cell") as Vector2i
		_queue_agent_for_garden_retarget(nav_id, agent, intent, spawner_cell, garden_id)
	# _garden_has_edible_plants (via _garden_assignment_is_stale) may have queued
	# stale-empty gardens; this loop iterates monsters, not _gardens, so draining
	# here is safe.
	_drain_pending_empty_gardens()

# Content-only removal emptied a garden. Queue every agent bound to it through the
# existing budgeted queue, then release the garden's routes and erase it. We must
# queue the agents FIRST (or at least before _erase_garden runs), because the
# queue helper reads the agent's phase, and because the affected-agent scan relies
# on the live phase dictionaries that still carry this garden_id. No new path/flow
# is computed here — that is the budgeted queue's job. We do NOT rebuild gardens
# and do NOT recompute entry cells.
func _handle_garden_became_empty(garden_id: int) -> void:
	if garden_id <= 0:
		return
	# Intent per phase: agents heading in (entry/astar_in) look for another garden
	# (retarget); agents already inside leaving/eating head for the exit (escape).
	for raw_nav_id in _entry_path_agents.keys():
		var nav_id: int = int(raw_nav_id)
		if not _entry_path_agents.has(nav_id):
			continue
		if int((_entry_path_agents[nav_id] as Dictionary).get("garden_id", 0)) != garden_id:
			continue
		_queue_affected_empty_garden_agent(nav_id, "retarget", garden_id)
	for raw_nav_id in _astar_in_agents.keys():
		var nav_id: int = int(raw_nav_id)
		if not _astar_in_agents.has(nav_id):
			continue
		if int((_astar_in_agents[nav_id] as Dictionary).get("garden_id", 0)) != garden_id:
			continue
		_queue_affected_empty_garden_agent(nav_id, "retarget", garden_id)
	for raw_nav_id in _astar_out_agents.keys():
		var nav_id: int = int(raw_nav_id)
		if not _astar_out_agents.has(nav_id):
			continue
		if int((_astar_out_agents[nav_id] as Dictionary).get("garden_id", 0)) != garden_id:
			continue
		_queue_affected_empty_garden_agent(nav_id, "escape", garden_id)
	for raw_nav_id in _eating_agents.keys():
		var nav_id: int = int(raw_nav_id)
		if not _eating_agents.has(nav_id):
			continue
		if int((_eating_agents[nav_id] as Dictionary).get("garden_id", 0)) != garden_id:
			continue
		_queue_affected_empty_garden_agent(nav_id, "escape", garden_id)
	# Meta-only fallback: agents that lost their phase entry but still carry this
	# garden in meta (e.g. mid-transition). Scan the monsters group once.
	for node in get_tree().get_nodes_in_group("monsters"):
		if not (node is Node2D):
			continue
		var agent: Node2D = node
		var nav_id: int = int(agent.get("nav_id"))
		if nav_id < 0 or _garden_retarget_queued.has(nav_id):
			continue
		if not agent.has_meta("garden_id"):
			continue
		if int(agent.get_meta("garden_id")) != garden_id:
			continue
		var spawner_cell: Vector2i = INVALID_CELL
		if agent.has_meta("spawner_cell"):
			spawner_cell = agent.get_meta("spawner_cell") as Vector2i
		_queue_agent_for_garden_retarget(nav_id, agent, "retarget", spawner_cell, garden_id)
	# Now that affected agents are parked/queued, release routes and erase the
	# garden. _mark_garden_empty clears plant_cells, releases routes, and erases.
	_mark_garden_empty(garden_id)

# Helper for _handle_garden_became_empty: resolve the agent node + spawner_cell
# for a queued nav_id and hand it to the shared queue helper. Reads spawner_cell
# from the phase entry if present, else from meta.
func _queue_affected_empty_garden_agent(nav_id: int, intent: String, garden_id: int) -> void:
	if _garden_retarget_queued.has(nav_id):
		return
	var agent: Node2D = _agent_from_nav_id(nav_id)
	if not is_instance_valid(agent):
		# Agent is gone; still drop its stale phase entries so nothing dangles.
		_entry_path_agents.erase(nav_id)
		_astar_in_agents.erase(nav_id)
		_astar_out_agents.erase(nav_id)
		_erase_eating_agent(nav_id)
		return
	var spawner_cell: Vector2i = INVALID_CELL
	if _entry_path_agents.has(nav_id):
		spawner_cell = (_entry_path_agents[nav_id] as Dictionary).get("spawner_cell", INVALID_CELL) as Vector2i
	elif _astar_in_agents.has(nav_id):
		spawner_cell = (_astar_in_agents[nav_id] as Dictionary).get("spawner_cell", INVALID_CELL) as Vector2i
	elif _astar_out_agents.has(nav_id):
		spawner_cell = (_astar_out_agents[nav_id] as Dictionary).get("spawner_cell", INVALID_CELL) as Vector2i
	elif _eating_agents.has(nav_id):
		spawner_cell = (_eating_agents[nav_id] as Dictionary).get("spawner_cell", INVALID_CELL) as Vector2i
	if spawner_cell == INVALID_CELL and agent.has_meta("spawner_cell"):
		spawner_cell = agent.get_meta("spawner_cell") as Vector2i
	_queue_agent_for_garden_retarget(nav_id, agent, intent, spawner_cell, garden_id)

# Budgeted "everyone escape" for the no-plants-left case. One scan of the monsters
# group enqueues each valid agent (intent="escape") through the shared queue, so
# the actual escape assignment is spread across frames by the budgeted queue
# instead of being applied synchronously in a single frame.
func _queue_escape_for_all_monsters_budgeted() -> void:
	for node in get_tree().get_nodes_in_group("monsters"):
		if not (node is Node2D):
			continue
		var agent: Node2D = node
		var nav_id: int = int(agent.get("nav_id"))
		if nav_id < 0 or _garden_retarget_queued.has(nav_id):
			continue
		# Already escaping (and not eating): leave it alone, it has a valid exit route.
		if _escaping_agents.has(nav_id) and not _eating_agents.has(nav_id):
			continue
		var spawner_cell: Vector2i = INVALID_CELL
		if agent.has_meta("spawner_cell"):
			spawner_cell = agent.get_meta("spawner_cell") as Vector2i
		var garden_id: int = 0
		if agent.has_meta("garden_id"):
			garden_id = int(agent.get_meta("garden_id"))
		_queue_agent_for_garden_retarget(nav_id, agent, "escape", spawner_cell, garden_id)

# Budgeted: re-assign at most garden_retarget_budget_per_frame queued agents per
# frame. The expensive A*/escape work lives in _retarget_single_waiting_agent.
func _process_garden_retarget_queue() -> void:
	if _garden_retarget_queue.is_empty():
		return
	var budget: int = garden_retarget_budget_per_frame
	while budget > 0 and not _garden_retarget_queue.is_empty():
		var item: Dictionary = _garden_retarget_queue.pop_front() as Dictionary
		var nav_id: int = int(item.get("nav_id", -1))
		_garden_retarget_queued.erase(nav_id)
		budget -= 1
		if nav_id < 0:
			continue
		var agent: Node2D = _agent_from_nav_id(nav_id)
		if not is_instance_valid(agent):
			# Agent was freed before we got to it: nothing to do.
			continue
		# If the agent already received a newer valid state (e.g. another path was
		# re-issued by other logic), it is no longer waiting — don't override it.
		if str(agent.get("status")) != "waiting_new_status":
			continue
		_retarget_single_waiting_agent(nav_id, agent, item)

# Re-assign one parked agent. intent "escape" routes it to a map exit; intent
# "retarget" finds a new valid garden if one exists, otherwise escapes.
#
# CRITICAL: "waiting_new_status" is only cleared AFTER the assignment actually
# succeeds. The assignment functions return bool now, so on failure we keep the
# agent waiting and requeue it (bounded retries) instead of stranding it with no
# nav state. This fixes the old bug where stop_waiting_new_status() ran first and
# a silently-failing assignment left the agent in a dead empty status.
func _retarget_single_waiting_agent(nav_id: int, agent: Node2D, item: Dictionary) -> void:
	if not is_instance_valid(agent):
		return
	var intent: String = str(item.get("intent", "retarget"))
	var spawner_cell: Vector2i = item.get("spawner_cell", INVALID_CELL) as Vector2i

	var assigned: bool = false
	if intent == "escape":
		assigned = _assign_agent_to_escape(agent)
	else:
		assigned = _retarget_agent_or_escape(agent, spawner_cell)

	if assigned:
		if agent.has_method("stop_waiting_new_status"):
			agent.call("stop_waiting_new_status")
		return
	# Assignment failed (no escape route / garden route ready yet). Keep the agent
	# parked in waiting_new_status and requeue it for a later frame.
	_requeue_waiting_agent(item)

# Max times a single agent is retried through the budgeted queue before we give
# up. Prevents an unroutable agent (e.g. no escape ready at all) from being
# requeued forever every frame. After the cap we clear waiting so it falls back to
# the normal idle/arrival logic rather than spinning.
const _GARDEN_RETARGET_MAX_RETRIES: int = 30

func _requeue_waiting_agent(item: Dictionary) -> void:
	var nav_id: int = int(item.get("nav_id", -1))
	if nav_id < 0:
		return
	var retries: int = int(item.get("retries", 0)) + 1
	if retries > _GARDEN_RETARGET_MAX_RETRIES:
		# Give up requeuing; let the agent leave waiting so other systems can act on
		# it. It keeps whatever (empty) status it has; arrival/idle logic recovers it.
		var agent: Node2D = _agent_from_nav_id(nav_id)
		if is_instance_valid(agent) and agent.has_method("stop_waiting_new_status"):
			agent.call("stop_waiting_new_status")
		return
	if _garden_retarget_queued.has(nav_id):
		return
	item["retries"] = retries
	_garden_retarget_queue.append(item)
	_garden_retarget_queued[nav_id] = true

func get_plant_zone_tiles() -> Array:
	return _plant_zone_tiles.keys()

func get_plant_zone_margin_tiles() -> Array:
	return _plant_zone_margin_tiles.keys()

func get_plant_zone_route_tiles() -> Array:
	var route_tiles: Dictionary = {}
	for raw_garden in _gardens.values():
		var garden: Dictionary = raw_garden as Dictionary
		var entry_cells: Array = garden.get("entry_cells", []) as Array
		for raw_entry_cell in entry_cells:
			var entry_cell: Vector2i = raw_entry_cell
			route_tiles[entry_cell] = true
	return route_tiles.keys()

func get_garden_entry_cells() -> Array:
	return get_plant_zone_route_tiles()

func set_show_enters_exits(value: bool) -> void:
	_show_enters_exits = value
	if _zone_overlay:
		_zone_overlay.queue_redraw()

func get_show_enters_exits() -> bool:
	return _show_enters_exits

func set_verbose(value: bool) -> void:
	_verbose = value
	_verbose_pushed = true

# True when verbose garden logging is on. Once CppDebugOptions has pushed a value
# via set_verbose() we trust that (it is already gated by debug_enabled there);
# before that push (e.g. the startup recompute, which can run before
# CppDebugOptions._ready()) we pull the value straight from the CPP node AND its
# debug_enabled flag, so the master debug gate holds even for the first recompute.
func _is_verbose() -> bool:
	if _verbose_pushed:
		return _verbose
	if _cpp_debug_options == null and is_inside_tree():
		var scene: Node = get_tree().get_current_scene()
		if scene:
			_cpp_debug_options = scene.get_node_or_null("CPP")
	if _cpp_debug_options and "verbose" in _cpp_debug_options and "debug_enabled" in _cpp_debug_options:
		return bool(_cpp_debug_options.get("verbose")) and bool(_cpp_debug_options.get("debug_enabled"))
	return _verbose

# Garden border tiles a monster crosses to ENTER: per spawner, the garden
# entry cell nearest that spawner. Aggregated across all spawners/gardens.
func get_garden_enter_tiles() -> Array:
	var tiles: Dictionary = {}
	for raw_spawner_cell in _spawners.keys():
		var spawner_cell: Vector2i = raw_spawner_cell
		for raw_garden_id in _gardens.keys():
			var garden_id: int = int(raw_garden_id)
			var enter_cell: Vector2i = _nearest_garden_entry(garden_id, spawner_cell)
			if enter_cell != INVALID_CELL:
				tiles[enter_cell] = true
	return tiles.keys()

# Garden border tiles a monster crosses to EXIT: per spawner, the garden
# entry cell nearest that spawner's exit-wall. Aggregated across all spawners.
func get_garden_exit_tiles() -> Array:
	var tiles: Dictionary = {}
	for raw_spawner_cell in _spawners.keys():
		var spawner_cell: Vector2i = raw_spawner_cell
		for raw_garden_id in _gardens.keys():
			var garden_id: int = int(raw_garden_id)
			var exit_cell: Vector2i = _nearest_garden_entry_to_exit(garden_id, spawner_cell)
			if exit_cell != INVALID_CELL:
				tiles[exit_cell] = true
	return tiles.keys()

func get_unreachable_garden_cells() -> Array:
	var cells: Dictionary = {}
	for raw_garden in _gardens.values():
		var garden: Dictionary = raw_garden as Dictionary
		if bool(garden.get("reachable", false)):
			continue
		var plant_cells: Dictionary = garden.get("plant_cells", {}) as Dictionary
		var zone_tiles: Dictionary = garden.get("zone_tiles", {}) as Dictionary
		for raw_cell in zone_tiles.keys():
			var zone_cell: Vector2i = raw_cell
			cells[zone_cell] = true
		for raw_cell in plant_cells.keys():
			var plant_cell: Vector2i = raw_cell
			cells[plant_cell] = true
	return cells.keys()

func get_dirty_garden_cells() -> Array:
	var cells: Dictionary = {}
	for raw_garden in _gardens.values():
		var garden: Dictionary = raw_garden as Dictionary
		if not bool(garden.get("dirty", false)):
			continue
		var plant_cells: Dictionary = garden.get("plant_cells", {}) as Dictionary
		var zone_tiles: Dictionary = garden.get("zone_tiles", {}) as Dictionary
		for raw_cell in zone_tiles.keys():
			var zone_cell: Vector2i = raw_cell
			cells[zone_cell] = true
		for raw_cell in plant_cells.keys():
			var plant_cell: Vector2i = raw_cell
			cells[plant_cell] = true
	return cells.keys()

func get_debug_monster_path(nav_id: int) -> PackedVector2Array:
	if _entry_path_agents.has(nav_id):
		var entry_data: Dictionary = _entry_path_agents[nav_id] as Dictionary
		return entry_data.get("path_world", PackedVector2Array()) as PackedVector2Array
	if _astar_in_agents.has(nav_id):
		var astar_in_data: Dictionary = _astar_in_agents[nav_id] as Dictionary
		return astar_in_data.get("path_world", PackedVector2Array()) as PackedVector2Array
	if _astar_out_agents.has(nav_id):
		var astar_out_data: Dictionary = _astar_out_agents[nav_id] as Dictionary
		return astar_out_data.get("path_world", PackedVector2Array()) as PackedVector2Array
	if _escaping_agents.has(nav_id):
		var escape_data: Dictionary = _escaping_agents[nav_id] as Dictionary
		var escape_target: Vector2i = escape_data.get("target_cell", INVALID_CELL) as Vector2i
		return _debug_path_to_cell(escape_target)
	for node in get_tree().get_nodes_in_group("monsters"):
		if not (node is Node2D):
			continue
		var agent: Node2D = node
		if int(agent.get("nav_id")) != nav_id:
			continue
		var status: String = str(agent.get("status"))
		if status == "eating" and agent.has_meta("garden_id") and agent.has_meta("spawner_cell"):
			var garden_id: int = int(agent.get_meta("garden_id"))
			var spawner_cell: Vector2i = agent.get_meta("spawner_cell") as Vector2i
			# Mirror _start_astar_out: exclude the entered tile so the debug path
			# does not misleadingly show the same entry/exit when an alternative exists.
			var dbg_entry_cell: Vector2i = INVALID_CELL
			if agent.has_meta("garden_entry_cell"):
				dbg_entry_cell = agent.get_meta("garden_entry_cell") as Vector2i
			var exit_cell: Vector2i = _nearest_garden_entry_to_exit_excluding(garden_id, spawner_cell, dbg_entry_cell)
			if exit_cell == INVALID_CELL:
				exit_cell = _nearest_garden_entry_to_exit(garden_id, spawner_cell)
			return _debug_path_to_cell(exit_cell)
		if agent.has_meta("garden_entry_cell"):
			var entry_cell: Vector2i = agent.get_meta("garden_entry_cell") as Vector2i
			return _debug_path_to_cell(entry_cell)
		break
	return PackedVector2Array()

func _debug_path_to_cell(cell: Vector2i) -> PackedVector2Array:
	var path: PackedVector2Array = PackedVector2Array()
	if cell == INVALID_CELL:
		return path
	path.append(_cell_center(cell))
	return path

func get_floorz() -> TileMapLayer:
	return floorz

func _wall_blockers_for_zone_bounds() -> PackedVector2Array:
	return _wall_blockers_for_cells(_plant_zone_tiles)

func _wall_blockers_for_cells(cells: Dictionary) -> PackedVector2Array:
	var blockers: PackedVector2Array = PackedVector2Array()
	if not wallz or cells.is_empty():
		return blockers
	var min_cell: Vector2i = INVALID_CELL
	var max_cell: Vector2i = Vector2i(-2147483648, -2147483648)
	for raw_cell in cells.keys():
		var c: Vector2i = raw_cell
		if min_cell == INVALID_CELL:
			min_cell = c
			max_cell = c
		else:
			min_cell.x = mini(min_cell.x, c.x)
			min_cell.y = mini(min_cell.y, c.y)
			max_cell.x = maxi(max_cell.x, c.x)
			max_cell.y = maxi(max_cell.y, c.y)

	for raw_cell in wallz.get_used_cells():
		var c: Vector2i = raw_cell
		if c.x < min_cell.x or c.x > max_cell.x or c.y < min_cell.y or c.y > max_cell.y:
			continue
		blockers.append(Vector2(float(c.x), float(c.y)))
	return blockers

# ---------------------------------------------------------------------------
# Exit-wall & adjacency helpers.
# ---------------------------------------------------------------------------
func _nearest_exit_wall_for_spawner(spawner_cell: Vector2i) -> Vector2i:
	if not wallz:
		return INVALID_CELL
	var best_cell: Vector2i = INVALID_CELL
	var best_dist: int = 2147483647
	for raw_cell in wallz.get_used_cells():
		var c: Vector2i = raw_cell
		if wallz.get_cell_atlas_coords(c) != EXIT_WALL_ATLAS:
			continue
		var d: Vector2i = c - spawner_cell
		var manhattan: int = abs(d.x) + abs(d.y)
		if manhattan < best_dist:
			best_dist = manhattan
			best_cell = c
	return best_cell

func _nearest_walkable_adjacent(cell: Vector2i) -> Vector2i:
	var best_cell: Vector2i = INVALID_CELL
	var best_dist: int = 2147483647
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			var n: Vector2i = cell + Vector2i(dx, dy)
			if not _is_walkable(n):
				continue
			var manhattan: int = abs(dx) + abs(dy)
			if manhattan < best_dist:
				best_dist = manhattan
				best_cell = n
	return best_cell

func _nearest_margin_tile(from_cell: Vector2i) -> Vector2i:
	var best_cell: Vector2i = INVALID_CELL
	var best_dist: int = 2147483647
	for raw_cell in _plant_zone_margin_tiles.keys():
		var c: Vector2i = raw_cell
		var d: Vector2i = c - from_cell
		var manhattan: int = abs(d.x) + abs(d.y)
		if manhattan < best_dist:
			best_dist = manhattan
			best_cell = c
	return best_cell

# ---------------------------------------------------------------------------
# A* glue: find paths via PathfinderNative.
# ---------------------------------------------------------------------------
func _find_path_on_walkable_map(from_tile: Vector2i, to_tile: Vector2i) -> PackedVector2Array:
	if pathfinder == null or not pathfinder.has_method("find_path"):
		return PackedVector2Array()
	if _walkable_map_tiles.is_empty():
		_rebuild_walkable_map_cache()
	if _walkable_map_tiles.is_empty():
		return PackedVector2Array()
	var path_tiles: Dictionary = _walkable_map_tiles
	var path_tiles_copied: bool = false
	if _is_walkable(from_tile) and not path_tiles.has(from_tile):
		path_tiles = _walkable_map_tiles.duplicate()
		path_tiles_copied = true
		path_tiles[from_tile] = true
	if _is_walkable(to_tile) and not path_tiles.has(to_tile):
		if not path_tiles_copied:
			path_tiles = _walkable_map_tiles.duplicate()
			path_tiles_copied = true
		path_tiles[to_tile] = true
	_sync_pathfinder_zone_tiles(path_tiles)
	var start_tile: Vector2i = from_tile if path_tiles.has(from_tile) else _nearest_zone_tile_to(from_tile, path_tiles)
	var end_tile: Vector2i = to_tile if path_tiles.has(to_tile) else _nearest_zone_tile_to(to_tile, path_tiles)
	if start_tile == INVALID_CELL or end_tile == INVALID_CELL:
		return PackedVector2Array()
	return pathfinder.call("find_path", start_tile, end_tile) as PackedVector2Array

func _find_path_in_zone(from_tile: Vector2i, to_tile: Vector2i, garden_id: int = 0) -> PackedVector2Array:
	if pathfinder == null or not pathfinder.has_method("find_path"):
		return PackedVector2Array()
	var zone_tiles: Dictionary = _plant_zone_tiles
	if garden_id > 0 and _gardens.has(garden_id):
		var garden: Dictionary = _gardens[garden_id] as Dictionary
		zone_tiles = garden.get("zone_tiles", {}) as Dictionary
	if zone_tiles.is_empty():
		return PackedVector2Array()
	# An agent arriving via the flow field can settle one tile *outside* the
	# interior (FF overshoot at the entry), so its actual cell may not be in
	# zone_tiles. Add any walkable endpoint to the A* walkable set so the path
	# starts/ends where the agent really stands instead of snapping a tile short.
	# Use a local copy so the cached garden zone_tiles is not mutated.
	var path_tiles: Dictionary = zone_tiles
	if _is_walkable(from_tile) and not zone_tiles.has(from_tile):
		path_tiles = zone_tiles.duplicate()
		path_tiles[from_tile] = true
	if _is_walkable(to_tile) and not path_tiles.has(to_tile):
		if path_tiles == zone_tiles:
			path_tiles = zone_tiles.duplicate()
		path_tiles[to_tile] = true
	_sync_pathfinder_zone_tiles(path_tiles)
	# Snap endpoints to walkable tiles if needed (non-walkable endpoints only).
	var start_tile: Vector2i = from_tile if path_tiles.has(from_tile) else _nearest_zone_tile_to(from_tile, path_tiles)
	var end_tile: Vector2i = to_tile if path_tiles.has(to_tile) else _nearest_zone_tile_to(to_tile, path_tiles)
	if start_tile == INVALID_CELL or end_tile == INVALID_CELL:
		return PackedVector2Array()
	return pathfinder.call("find_path", start_tile, end_tile) as PackedVector2Array

func _sync_pathfinder_zone_tiles(zone_tiles: Dictionary) -> void:
	if pathfinder == null:
		return
	var zone_arr: PackedVector2Array = PackedVector2Array()
	zone_arr.resize(zone_tiles.size())
	var i: int = 0
	for raw_cell in zone_tiles.keys():
		var cell: Vector2i = raw_cell
		zone_arr[i] = Vector2(float(cell.x), float(cell.y))
		i += 1
	if pathfinder.has_method("set_walkable_tiles"):
		pathfinder.call("set_walkable_tiles", zone_arr)
	if pathfinder.has_method("set_blockers"):
		pathfinder.call("set_blockers", _wall_blockers_for_cells(zone_tiles))

func _nearest_zone_tile_to(cell: Vector2i, zone_tiles: Dictionary) -> Vector2i:
	var best_cell: Vector2i = INVALID_CELL
	var best_dist: int = 2147483647
	for raw_cell in zone_tiles.keys():
		var c: Vector2i = raw_cell
		var d: Vector2i = c - cell
		var manhattan: int = abs(d.x) + abs(d.y)
		if manhattan < best_dist:
			best_dist = manhattan
			best_cell = c
	return best_cell

func _path_cells_to_world(path_cells: PackedVector2Array) -> PackedVector2Array:
	var out: PackedVector2Array = PackedVector2Array()
	out.resize(path_cells.size())
	for i in range(path_cells.size()):
		var v: Vector2 = path_cells[i]
		out[i] = _cell_center(Vector2i(int(v.x), int(v.y)))
	return out

func _resolve_plant_target_for_agent_in_garden(from_cell: Vector2i, garden_id: int) -> Vector2i:
	if not _gardens.has(garden_id):
		return INVALID_CELL
	var garden: Dictionary = _gardens[garden_id] as Dictionary
	var plant_cells: Dictionary = garden.get("plant_cells", {}) as Dictionary
	var zone_tiles: Dictionary = garden.get("zone_tiles", {}) as Dictionary
	var best_cell: Vector2i = INVALID_CELL
	var best_dist: int = 2147483647
	for raw_cell in plant_cells.keys():
		var c: Vector2i = raw_cell
		if not zone_tiles.has(c):
			continue
		if plant_manager and plant_manager.has_method("has_plant") and not bool(plant_manager.call("has_plant", c)):
			continue
		var d: Vector2i = c - from_cell
		var manhattan: int = abs(d.x) + abs(d.y)
		if manhattan < best_dist:
			best_dist = manhattan
			best_cell = c
	return best_cell

# Truth is plant_cells (cross-checked against the plant_manager), never the cached
# edible_count: that counter drifts on incremental removal and was flagging
# non-empty gardens as empty. This predicate may be called while iterating
# _gardens, so it only queues stale-empty gardens; callers drain after scans.
func _garden_has_edible_plants(garden_id: int) -> bool:
	if not _gardens.has(garden_id):
		return false
	var garden: Dictionary = _gardens[garden_id] as Dictionary
	var plant_cells: Dictionary = garden.get("plant_cells", {}) as Dictionary
	if plant_cells.is_empty():
		_pending_empty_gardens[garden_id] = true
		return false
	if plant_manager == null or not plant_manager.has_method("has_plant"):
		return true
	for raw_cell in plant_cells.keys():
		var cell: Vector2i = raw_cell
		if bool(plant_manager.call("has_plant", cell)):
			return true
	# plant_cells is non-empty but the plant_manager confirms none survive: stale
	# cache, genuinely empty. Queue for removal outside any garden iteration.
	_pending_empty_gardens[garden_id] = true
	return false

# Drain gardens flagged empty by _garden_has_edible_plants. Plant removal still
# removes its own empty garden immediately; this catches stale caches found by
# route/retarget scans without mutating _gardens mid-iteration.
func _drain_pending_empty_gardens() -> void:
	if _pending_empty_gardens.is_empty():
		return
	if _gardens_iter_depth > 0:
		push_warning("GARDEN-CRASH-GUARD: drain requested mid-iteration; deferring %d" % _pending_empty_gardens.size())
		return
	var ids: Array = _pending_empty_gardens.keys()
	_pending_empty_gardens.clear()
	for raw_id in ids:
		_mark_garden_empty(int(raw_id))

func _mark_garden_empty(garden_id: int) -> void:
	if not _gardens.has(garden_id):
		return
	var garden: Dictionary = _gardens[garden_id] as Dictionary
	var plant_cells: Dictionary = garden.get("plant_cells", {}) as Dictionary
	for raw_cell in plant_cells.keys():
		var cell: Vector2i = raw_cell
		_garden_by_plant_cell.erase(cell)
	garden["plant_cells"] = {}
	garden["edible_count"] = 0
	garden["targetable"] = false
	_gardens[garden_id] = garden
	_pending_empty_gardens.erase(garden_id)
	_release_garden_routes(garden_id)
	_erase_garden(garden_id, "mark_empty")

func _manhattan_cell(a: Vector2i, b: Vector2i) -> int:
	var delta: Vector2i = a - b
	return abs(delta.x) + abs(delta.y)

# Walkable cells *outside* the garden that a monster could actually step to from
# this interior access cell. "Outside" = not in zone_tiles. Uses the same
# walkability + diagonal no-corner-cut rules as _recompute_garden_geometry(), so
# the neighbors returned mirror the transitions that made access_cell an access
# cell in the first place.
func _garden_access_outside_neighbors(garden: Dictionary, access_cell: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var zone_tiles: Dictionary = garden.get("zone_tiles", {}) as Dictionary
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			var neighbor: Vector2i = access_cell + Vector2i(dx, dy)
			if not _is_walkable(neighbor):
				continue
			if zone_tiles.has(neighbor):
				continue
			if dx != 0 and dy != 0:
				if not _is_walkable(access_cell + Vector2i(dx, 0)) or not _is_walkable(access_cell + Vector2i(0, dy)):
					continue
			out.append(neighbor)
	return out

# Walkable neighbors of a cell using the same no-corner-cut rule. Pure local
# geometry (no zone awareness): used to gauge whether an outside tile is cramped
# or dead-ended for continuation scoring.
func _valid_walkable_neighbors_no_corner_cut(cell: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			var neighbor: Vector2i = cell + Vector2i(dx, dy)
			if not _is_walkable(neighbor):
				continue
			if dx != 0 and dy != 0:
				if not _is_walkable(cell + Vector2i(dx, 0)) or not _is_walkable(cell + Vector2i(0, dy)):
					continue
			out.append(neighbor)
	return out

# Route cost for a group at a cell center, or INF when flow / the group is not
# available. Wraps the optional flow.group_route_cost_at_world cache so callers
# can compare inside vs outside cost along the real escape flow.
func _group_route_cost_at_cell(escape_group: int, cell: Vector2i) -> float:
	if escape_group <= IDLE_GROUP:
		return INF
	if not flow or not flow.has_method("group_route_cost_at_world"):
		return INF
	return float(flow.call("group_route_cost_at_world", escape_group, _cell_center(cell)))

# Low-cost score for a garden access (entry/exit) cell. Lower is better. The base
# is Manhattan distance to target_cell so behavior stays close to the old
# nearest-entry selection; penalties are purely additive and only discourage
# obviously bad local geometry. Wall proximity alone is never enough to reject a
# cell — it only adds a small cramped penalty, which doors naturally incur.
func _score_garden_access_cell(
	garden_id: int,
	access_cell: Vector2i,
	target_cell: Vector2i,
	mode: String,
	forbidden_cell: Vector2i = INVALID_CELL,
	escape_group: int = -1
) -> float:
	if not _gardens.has(garden_id):
		return INF
	if access_cell == forbidden_cell:
		return INF
	if not _is_walkable(access_cell):
		return INF
	var garden: Dictionary = _gardens[garden_id] as Dictionary

	var score: float = float(_manhattan_cell(access_cell, target_cell))

	var outside_neighbors: Array[Vector2i] = _garden_access_outside_neighbors(garden, access_cell)
	if outside_neighbors.is_empty():
		# Degenerate: an access cell with no reachable outside step. Penalize
		# heavily but never crash — the cell may still be the only option.
		return score + ACCESS_NO_OUTSIDE_PENALTY

	# Pick the outside neighbor that best follows the target / escape flow.
	var use_flow: bool = escape_group > IDLE_GROUP and flow and flow.has_method("group_route_cost_at_world")
	var outside_neighbor: Vector2i = outside_neighbors[0]
	var best_outside_metric: float = INF
	for candidate in outside_neighbors:
		var metric: float
		if use_flow:
			metric = _group_route_cost_at_cell(escape_group, candidate)
			if not is_finite(metric):
				metric = float(_manhattan_cell(candidate, target_cell))
		else:
			metric = float(_manhattan_cell(candidate, target_cell))
		if metric < best_outside_metric:
			best_outside_metric = metric
			outside_neighbor = candidate

	if mode == "exit":
		# Stepping outside should not lose progress toward the target. Prefer the
		# real escape flow when available, fall back to Manhattan otherwise.
		var compared: bool = false
		if use_flow:
			var inside_cost: float = _group_route_cost_at_cell(escape_group, access_cell)
			var outside_cost: float = _group_route_cost_at_cell(escape_group, outside_neighbor)
			if is_finite(inside_cost) and is_finite(outside_cost):
				compared = true
				if outside_cost > inside_cost:
					score += ACCESS_EXIT_WORSE_PENALTY
				elif outside_cost == inside_cost:
					score += ACCESS_EXIT_FLAT_PENALTY
		if not compared:
			var inside_dist: int = _manhattan_cell(access_cell, target_cell)
			var outside_dist: int = _manhattan_cell(outside_neighbor, target_cell)
			if outside_dist > inside_dist:
				score += ACCESS_EXIT_WORSE_PENALTY
			elif outside_dist == inside_dist:
				score += ACCESS_EXIT_FLAT_PENALTY

		# Continuation: how many ways out of the outside tile, excluding stepping
		# straight back inside. A dead end forces an immediate reversal.
		var continuations: Array[Vector2i] = []
		for cont in _valid_walkable_neighbors_no_corner_cut(outside_neighbor):
			if cont == access_cell:
				continue
			continuations.append(cont)
		if continuations.is_empty():
			score += ACCESS_DEAD_CONTINUATION_PENALTY
		elif continuations.size() == 1:
			score += ACCESS_NARROW_CONTINUATION_PENALTY

		# Immediate reversal: if the best next step from the outside tile heads
		# back the way we came, the exit geometry is awkward (wall pocket).
		if not continuations.is_empty():
			var best_next: Vector2i = continuations[0]
			var best_next_metric: float = INF
			for cont in continuations:
				var cont_metric: float
				if use_flow:
					cont_metric = _group_route_cost_at_cell(escape_group, cont)
					if not is_finite(cont_metric):
						cont_metric = float(_manhattan_cell(cont, target_cell))
				else:
					cont_metric = float(_manhattan_cell(cont, target_cell))
				if cont_metric < best_next_metric:
					best_next_metric = cont_metric
					best_next = cont
			var exit_dir: Vector2i = outside_neighbor - access_cell
			var best_dir: Vector2i = best_next - outside_neighbor
			var dot: int = signi(exit_dir.x) * signi(best_dir.x) + signi(exit_dir.y) * signi(best_dir.y)
			if dot < 0:
				score += ACCESS_REVERSAL_PENALTY
			elif dot == 0:
				score += ACCESS_TURN_PENALTY

		# Small cramped penalty: blocked cardinal tiles around the outside cell.
		# Kept tiny so it can never dominate a real door's distance advantage.
		score += float(_blocked_cardinal_count(outside_neighbor)) * ACCESS_BLOCKED_CARDINAL_PENALTY
	else:
		# Enter mode: agent heads inward, so outside continuation matters less and
		# we do not penalize "outside farther than inside" (direction is reversed).
		var enter_continuations: int = 0
		for cont in _valid_walkable_neighbors_no_corner_cut(outside_neighbor):
			if cont == access_cell:
				continue
			enter_continuations += 1
		if enter_continuations == 0:
			score += ACCESS_ENTER_DEAD_CONTINUATION_PENALTY
		elif enter_continuations == 1:
			score += ACCESS_ENTER_NARROW_CONTINUATION_PENALTY
		score += float(_blocked_cardinal_count(outside_neighbor)) * ACCESS_BLOCKED_CARDINAL_PENALTY

	return score

# Count of the 4 cardinal neighbors of `cell` that are not walkable.
func _blocked_cardinal_count(cell: Vector2i) -> int:
	var blocked: int = 0
	if not _is_walkable(cell + Vector2i(1, 0)):
		blocked += 1
	if not _is_walkable(cell + Vector2i(-1, 0)):
		blocked += 1
	if not _is_walkable(cell + Vector2i(0, 1)):
		blocked += 1
	if not _is_walkable(cell + Vector2i(0, -1)):
		blocked += 1
	return blocked

# Shared scored selector for garden access cells. Loops entry_cells, scores each
# candidate, and returns the lowest-scoring one, tie-broken by old Manhattan
# distance to target_cell for predictable behavior. If every candidate scores INF
# (or scoring finds nothing usable), falls back to the old pure-Manhattan logic.
func _select_scored_garden_entry(
	garden_id: int,
	target_cell: Vector2i,
	mode: String,
	forbidden_cell: Vector2i = INVALID_CELL,
	escape_group: int = -1
) -> Vector2i:
	if not _gardens.has(garden_id):
		return INVALID_CELL
	var garden: Dictionary = _gardens[garden_id] as Dictionary
	var entry_cells: Array = garden.get("entry_cells", []) as Array
	var best_cell: Vector2i = INVALID_CELL
	var best_score: float = INF
	var best_tiebreak: int = 2147483647
	for raw_cell in entry_cells:
		var cell: Vector2i = raw_cell
		var score: float = _score_garden_access_cell(garden_id, cell, target_cell, mode, forbidden_cell, escape_group)
		if not is_finite(score):
			continue
		var tiebreak: int = _manhattan_cell(cell, target_cell)
		if score < best_score or (score == best_score and tiebreak < best_tiebreak):
			best_score = score
			best_tiebreak = tiebreak
			best_cell = cell
	if best_cell != INVALID_CELL:
		# Gated on the opt-in export (defaults off) so the debug overlay's
		# per-frame path queries can't spam this; selection itself is rare.
		if debug_logs:
			print("BuildingManager: garden %d %s access %s score=%.1f target=%s" % [garden_id, mode, str(best_cell), best_score, str(target_cell)])
		return best_cell
	# Nothing scored finite: fall back to the old Manhattan nearest logic so
	# behavior is never worse than before.
	return _nearest_garden_entry_manhattan(garden_id, target_cell, forbidden_cell)

# Old pure-Manhattan nearest-entry selection, preserved as the fallback for the
# scored selector. Honors forbidden_cell (pass INVALID_CELL to disable).
func _nearest_garden_entry_manhattan(garden_id: int, from_cell: Vector2i, forbidden_cell: Vector2i = INVALID_CELL) -> Vector2i:
	if not _gardens.has(garden_id):
		return INVALID_CELL
	var garden: Dictionary = _gardens[garden_id] as Dictionary
	var entry_cells: Array = garden.get("entry_cells", []) as Array
	var best_cell: Vector2i = INVALID_CELL
	var best_dist: int = 2147483647
	for raw_cell in entry_cells:
		var cell: Vector2i = raw_cell
		if cell == forbidden_cell:
			continue
		if not _is_walkable(cell):
			continue
		var manhattan: int = _manhattan_cell(cell, from_cell)
		if manhattan < best_dist:
			best_dist = manhattan
			best_cell = cell
	return best_cell

func _nearest_garden_entry(garden_id: int, from_cell: Vector2i) -> Vector2i:
	return _select_scored_garden_entry(garden_id, from_cell, "enter")

func _nearest_garden_entry_to_exit(garden_id: int, spawner_cell: Vector2i) -> Vector2i:
	var exit_wall_cell: Vector2i = INVALID_CELL
	var spawner_route: Dictionary = _spawner_routes.get(spawner_cell, {}) as Dictionary
	exit_wall_cell = spawner_route.get("exit_wall_cell", INVALID_CELL) as Vector2i
	var escape_group: int = int(spawner_route.get("escape_group", -1))
	if exit_wall_cell == INVALID_CELL:
		return _select_scored_garden_entry(garden_id, spawner_cell, "exit", INVALID_CELL, escape_group)
	return _select_scored_garden_entry(garden_id, exit_wall_cell, "exit", INVALID_CELL, escape_group)

# Like _nearest_garden_entry, but never returns forbidden_cell. Used so a route's
# garden exit tile differs from the tile the monster entered through, whenever a
# different valid entry exists. Returns INVALID_CELL if the only option is the
# forbidden tile (or none are valid).
func _nearest_garden_entry_excluding(garden_id: int, from_cell: Vector2i, forbidden_cell: Vector2i) -> Vector2i:
	return _select_scored_garden_entry(garden_id, from_cell, "enter", forbidden_cell)

# Like _nearest_garden_entry_to_exit, but never returns forbidden_cell. Prefers
# the garden entry closest to the spawner's wall-exit target. Returns
# INVALID_CELL when no valid entry other than forbidden_cell exists.
func _nearest_garden_entry_to_exit_excluding(garden_id: int, spawner_cell: Vector2i, forbidden_cell: Vector2i) -> Vector2i:
	var exit_wall_cell: Vector2i = INVALID_CELL
	var spawner_route: Dictionary = _spawner_routes.get(spawner_cell, {}) as Dictionary
	exit_wall_cell = spawner_route.get("exit_wall_cell", INVALID_CELL) as Vector2i
	var escape_group: int = int(spawner_route.get("escape_group", -1))
	if exit_wall_cell == INVALID_CELL:
		return _select_scored_garden_entry(garden_id, spawner_cell, "exit", forbidden_cell, escape_group)
	return _select_scored_garden_entry(garden_id, exit_wall_cell, "exit", forbidden_cell, escape_group)

func _log(message: String) -> void:
	if debug_logs:
		print("BuildingManager: ", message)

func _log_spawn_failure(message: String) -> void:
	var now_ms: int = Time.get_ticks_msec()
	var last_ms: int = int(_last_spawn_failure_at_ms.get(message, -SPAWN_FAILURE_WARN_INTERVAL_MS))
	if now_ms - last_ms < SPAWN_FAILURE_WARN_INTERVAL_MS:
		return
	_last_spawn_failure = message
	_last_spawn_failure_at_ms[message] = now_ms
	push_warning("BuildingManager: " + message)

func _log_scan_summary(seen_spawners: Dictionary, migrated: bool, walls_changed: bool) -> void:
	var plant_count: int = int(plant_manager.call("size")) if plant_manager and plant_manager.has_method("size") else 0
	var summary: String = "scan indexed_plants=%d spawners=%d registered_spawners=%d migrated=%s walls_changed=%s" % [
		plant_count,
		seen_spawners.size(),
		_spawners.size(),
		migrated,
		walls_changed
	]
	if summary == _last_scan_summary:
		return
	_last_scan_summary = summary
	_log(summary)
