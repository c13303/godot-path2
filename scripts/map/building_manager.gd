extends Node
class_name BuildingManager

signal startup_loading_progress(progress: float, label: String)
signal startup_loading_finished

const AGENT_SCENE: PackedScene = preload("res://scenes/entities/character.tscn")
const CLIENT_TEXTURE: Texture2D = preload("res://assets/sprites/legval/client.png")
const GARDEN_TOPOLOGY_SERVICE_SCRIPT: Script = preload("res://scripts/map/garden_topology_service.gd")
const GARDEN_ACCESS_RESOLVER_SCRIPT: Script = preload("res://scripts/map/garden_access_resolver.gd")
const AGENT_NAVIGATION_PHASE_CONTROLLER_SCRIPT: Script = preload("res://scripts/map/agent_navigation_phase_controller.gd")
const EATING_COOLDOWN: float = 5.0
const IDLE_GROUP: int = 0
const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)
const EXIT_WALL_ATLAS: Vector2i = Vector2i(13, 0)
const PLANT_ZONE_MARGIN: int = 2
const TURRET_ID: String = "turret1"
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
const SPAWNER_KIND_MONSTER: StringName = &"monster"
const SPAWNER_KIND_CLIENT: StringName = &"client"
const SPAWNER_KIND_MERCHANT: StringName = &"merchant"
const DEFAULT_TERRAIN_SPEED_MULTIPLIER: float = 1.0
# A client that has passed within this many tiles of a stocked counter's (walkable)
# access tile grabs its rose right there and leaves, instead of finishing the walk to
# the garden entrance / counter. Keyed off the walkable access tile, so a proximity hit
# means the counter is genuinely reachable.
const EARLY_COUNTER_FETCH_TILE_FACTOR: float = 1.25
const ROSE_SHOP_COUNTER_ID: String = "rose_shop_counter"
# Garden access-cell scoring penalties (ACCESS_*) now live in GardenAccessResolver,
# which owns the garden access scoring / entry selection extracted from this manager.
const PASTEQUE_ITEM_ID: String = "pasteque"
const _SANE_CELL_LIMIT: int = 100000

@export var floorz: TileMapLayer
@export var watersources: WaterSources
@export var wallz: TileMapLayer
@export var plantz: TileMapLayer
# Decorative / passive / walkable placeables (lamps, spawners). Spawner and other
# special tiles are scanned here. Does NOT block agents or affect flowfields.
@export var traversable_buildings: TileMapLayer
# Breakable / obstructing / non-walkable placeables (turret1). These are navigation
# blockers like walls. Their flow-field topology is applied once when night starts,
# never while the player is building during the day.
@export var blocking_buildings: TileMapLayer
# Player-walkable fences. Clients treat them as non-walkable (routing walls); monsters
# ignore them entirely and are only slowed by their 0.3 speed multiplier. Never block
# player collision or projectiles. Fence-vs-agent handling: _fences_block_navigation /
# _has_wall (A*/gardens) and the block_fences flag in _request_group_flow_rebuild (flow).
@export var fences: TileMapLayer
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
# Hard upper bound on queued agents retargeted per frame after a garden rebuild.
# This is now a safety cap only — the *primary* limiter is garden_retarget_budget_ms
# below. Keeps the rebuild frame cheap by spreading the (expensive) re-path/escape
# work over several frames. Raise if reassignment feels too slow, lower if it causes
# frame spikes.
@export_range(1, 64, 1, "or_greater") var garden_retarget_budget_per_frame: int = 8
# Primary limiter: max intended time spent processing the garden retarget queue per
# frame. A single retarget can cost 15-20ms, so a count-based budget alone lets
# several expensive retargets stack into one big spike. With a time budget we always
# do at least one item (so the queue drains), then stop once we've spent this long —
# spreading a burst of waiting agents across several smaller frames instead of one.
# 0 falls back to one item per frame (the safest non-spiking behavior).
@export_range(0.0, 100.0, 0.5, "or_greater") var garden_retarget_budget_ms: float = 4.0
# Main-thread budget used while preparing a night. Garden clustering, geometry,
# reachability, and route request submission yield when this slice is exhausted.
@export_range(0.5, 16.0, 0.5, "or_greater") var night_preparation_budget_ms: float = 3.0
# Spawner processing budget. Playlist requests are queued and drained round-robin:
# at most this many ready spawn requests per frame.
@export_range(1, 32, 1) var spawner_budget_per_frame: int = 1
# Optional time budget for draining the ready-spawner queue. We always process at
# least one request per frame, then stop once this budget is spent.
@export_range(0.0, 100.0, 0.5, "or_greater") var spawner_budget_ms: float = 4.0
@export var debug_show_plantzone: bool = true:
	set(value):
		debug_show_plantzone = value
		if _zone_overlay:
			_zone_overlay.visible = value
			_zone_overlay.queue_redraw()

var _spawners: Dictionary = {}
var _spawner_kind_by_cell: Dictionary = {}  # Vector2i -> StringName
var _spawner_exit_cell_by_cell: Dictionary = {}  # Vector2i -> Vector2i
var _spawner_spot_cell_by_cell: Dictionary = {}  # Vector2i -> Vector2i
var _client_spawners: Dictionary = {}  # Vector2i -> true
var _client_frequency_by_cell: Dictionary = {}  # Vector2i -> float
var _merchant_spawners: Dictionary = {}  # Vector2i -> true
# Side-channel: _sync_pathfinder_zone_tiles writes the time it spent in
# _wall_blockers_for_cells here so the caller can split sync time into
# blocker-construction vs. the rest, without changing the void signature.
var _last_zone_blocker_us: int = 0
var _agent_navigation_phases: Variant = AGENT_NAVIGATION_PHASE_CONTROLLER_SCRIPT.new()
var _eating_agents: Dictionary = _agent_navigation_phases.eating_agents()
var _eating_time: float = EATING_COOLDOWN
var _number_of_roses_before_satiety: int = 3
var _same_garden_only: bool = false
var _paused: bool = false
var _escaping_agents: Dictionary = _agent_navigation_phases.escaping_agents()
var _entry_path_agents: Dictionary = _agent_navigation_phases.entry_path_agents()
var _astar_in_agents: Dictionary = _agent_navigation_phases.astar_in_agents()
var _garden_retarget: GardenRetargetController = GardenRetargetController.new()
# When true, _retarget_agents_targeting_removed_plant_only also runs the old full
# scan and warns on any mismatch with the index. OFF by default (reintroduces the
# very scan cost the index removes); flip on only to debug index consistency.
var _debug_check_retarget_index: bool = false:
	set(value):
		_debug_check_retarget_index = value
		if _garden_retarget != null:
			_garden_retarget.set_debug_check_retarget_index(value)
var _scan_timer: float = 0.0
var _navigation_topology_dirty: bool = true
var _flow_ready: bool = false
var _startup_loading_started: bool = false
var _startup_ready: bool = false
var _night_preparing: bool = false
var _night_preparation_ready: bool = false
var _night_preparation_token: int = 0
var _day_start_pending: bool = false
var _client_preparing: bool = false
var _garden_topology: Variant = GARDEN_TOPOLOGY_SERVICE_SCRIPT.new()
# Eat-exit transition counters: monsters finishing eating attach directly to the
# existing per-exit-wall escape FF (no garden-exit selection, no per-agent A* out).
# A failure is expected to be rare and indicates an FF coverage/walkability bug.
var eat_exit_direct_ff_success: int = 0
var eat_exit_direct_ff_failed: int = 0
# The memoized garden-entry resolve cache and its per-resolve tally counters now
# live in GardenAccessResolver (see _garden_access_resolver below).

var _progression: Node = null
var _level_spawn_playlist: LevelSpawnPlaylist
var _level_spawner_bindings: Array[SpawnerBinding] = []
var _loaded_level_scene_path: String = ""
var _monster_drop_seed_chance_percent: int = 0
var _spawner_bindings_by_id: Dictionary = {}  # StringName -> Vector2i
var _spawn_playlist_controller: SpawnPlaylistController = SpawnPlaylistController.new()
var _spawn_tick_controller: SpawnTickController = SpawnTickController.new()
var _playlist_spawning_enabled: bool = false
var _playlist_spawning_invalid: bool = false
var _playlist_validation_attempted: bool = false
var _current_playlist_night_index: int = -1
var _client_counter_agents: Dictionary = _agent_navigation_phases.client_counter_agents()  # nav_id -> Dictionary
var _damage_number_drawer: DamageNumberDrawer
var _seed_merchant: SeedMerchantController = SeedMerchantController.new()
var _morning_harvest: MorningHarvestController = MorningHarvestController.new()
var _client_tantrum: ClientTantrumController = ClientTantrumController.new()
var _client_sale: ClientSaleController = ClientSaleController.new()
var _drowning_controller: DrowningController = DrowningController.new()
var _turret_eating_controller: TurretEatingController = TurretEatingController.new()
var _agent_suspend: AgentSuspendService = AgentSuspendService.new()
var _building_scan: BuildingScanService = BuildingScanService.new()
var _spawner_route_service: SpawnerRouteService = SpawnerRouteService.new()
var _building_path_service: BuildingPathService = BuildingPathService.new()
var _garden_access_resolver: GardenAccessResolver = GardenAccessResolver.new()
var _debug_telemetry: BuildingDebugTelemetry = BuildingDebugTelemetry.new()
var _monster_death: MonsterDeathController = MonsterDeathController.new()
var _counter_stock_manager: CounterStockManager
var _zone_overlay: Node2D
var _desire: Node
var _show_enters_exits: bool = false
# When on, prints "x gardens recomputed with y entry points" every time gardens
# (and their entry points) are recomputed. Pushed from CppDebugOptions.verbose;
# _verbose_pushed flips true once that push has happened. Until then _is_verbose()
# pulls the value straight off the CPP node so the startup recompute is logged
# even if it runs before CppDebugOptions._ready().
var _verbose: bool = false
var _verbose_pushed: bool = false
var _cpp_debug_options: Node = null

func set_empty_garden_local_retarget_radius(value: int) -> void:
	empty_garden_local_retarget_radius = maxi(0, value)

func set_eating_time(value: float) -> void:
	_eating_time = maxf(0.0, value)

func set_number_of_roses_before_satiety(value: int) -> void:
	_number_of_roses_before_satiety = maxi(1, value)

func set_same_garden_only(value: bool) -> void:
	_same_garden_only = value

func set_paused(value: bool) -> void:
	_paused = value

func _ready() -> void:
	_agent_navigation_phases.setup(self)
	_garden_topology.setup(self)
	_seed_merchant.setup(self)
	_morning_harvest.setup(self)
	_client_tantrum.setup(self)
	_client_sale.setup(self)
	_drowning_controller.setup(self)
	_turret_eating_controller.setup(self)
	_agent_suspend.setup(self)
	_building_scan.setup(self)
	_spawner_route_service.setup(self)
	_building_path_service.setup(self)
	_garden_access_resolver.setup(self)
	_garden_retarget.setup(self)
	_spawn_tick_controller.setup(self)
	_debug_telemetry.setup(self)
	_monster_death.setup(self)
	_resolve_level_layers()
	_resolve_desire()
	_load_level_spawn_config()
	startup_loading_progress.emit(0.48, "Preparing zones")
	_load_tile_definitions()
	_migrate_special_tiles_from_wallz()
	_setup_plant_manager()
	_setup_building_object_manager()
	_setup_counter_stock_manager()
	_setup_zone_overlay()
	_wait_for_flow_ready()
	GameState.mode_changed.connect(_on_game_mode_changed)
	_damage_number_drawer = DamageNumberDrawer.new()
	add_child(_damage_number_drawer)
	set_process_input(true)


func _load_level_spawn_config() -> void:
	var config: LevelSpawnConfigLoader = LevelSpawnConfigLoader.load_from_scene(get_tree().current_scene)
	_level_spawn_playlist = config.playlist
	_level_spawner_bindings = config.spawner_bindings
	_loaded_level_scene_path = config.level_scene_path
	_monster_drop_seed_chance_percent = config.monster_drop_seed_chance_percent

# floor/watersources/wallz belong to the loaded level (see LevelLoader) and are
# injected into MonTilemap before any _ready runs, so they are resolved by path
# here instead of through scene-wired exports.
func _resolve_level_layers() -> void:
	if floorz == null:
		floorz = get_node_or_null("../MonTilemap/floor") as TileMapLayer
	if watersources == null:
		watersources = get_node_or_null("../MonTilemap/watersources") as WaterSources
	if wallz == null:
		wallz = get_node_or_null("../MonTilemap/wallz") as TileMapLayer
	if fences == null:
		fences = get_node_or_null("../MonTilemap/fences") as TileMapLayer


func _resolve_desire() -> void:
	_desire = get_node_or_null("../MonTilemap/Desire")


func _register_desire_agent(agent: Node2D, group_name: StringName) -> void:
	if _desire != null and _desire.has_method("register_agent"):
		_desire.call("register_agent", agent, group_name)


func _unregister_desire_agent(agent: Node2D) -> void:
	if _desire != null and _desire.has_method("unregister_agent"):
		_desire.call("unregister_agent", agent)

func _on_game_mode_changed(is_night: bool) -> void:
	_spawn_tick_controller.reset_empty_night()
	_client_preparing = false
	if is_night:
		_day_start_pending = false
		_client_tantrum.end()
		_client_sale.reset()
		clear_client_counter_agents()
		_seed_merchant.on_night_started()
		GameState.set_building_phase(false)
		_morning_harvest.clear_active()
		# Counters normally empty the moment the last client of the sale leaves (see
		# _dissolve_counter_piles_after_clients). This is only a fallback for days where no
		# client sale ever runs (no client spawners / stock but no buyers): it's idempotent
		# when the piles are already gone, so it never double-animates.
		_counter_stock_manager.dissolve_all_piles()
	if not is_night:
		_day_start_pending = true
		_night_preparation_token += 1
		_night_preparing = false
		_night_preparation_ready = false
		_spawn_tick_controller.clear_legacy_fallback()
		_clear_waterpool_directional_field()
		return
	# Night visuals/build lock become active immediately, but spawning remains gated
	# while all daytime topology is consumed by the capped preparation coroutine.
	if not _playlist_validation_attempted:
		_scan_buildings()
		_validate_playlist_after_spawner_scan()
	_current_playlist_night_index = _get_playlist_night_index_from_progression()
	if _playlist_spawning_enabled:
		if not _spawn_playlist_controller.begin_night(_current_playlist_night_index):
			push_error("BuildingManager: playlist night index %d is invalid; using legacy fallback spawning this night." % (_current_playlist_night_index + 1))
			_playlist_spawning_enabled = false
			_playlist_spawning_invalid = true
		else:
			CppDebugOptions.dlog("BuildingManager: playlist night started: playable_night=%d total=%d" % [
				_current_playlist_night_index + 1,
				_spawn_playlist_controller.get_total_night_count(),
			])
			for line: String in _spawn_playlist_controller.get_current_night_debug_lines():
				CppDebugOptions.dlog("BuildingManager: playlist " + line)
	if _playlist_spawning_enabled:
		_spawn_tick_controller.clear_legacy_fallback()
	else:
		_spawn_tick_controller.begin_legacy_fallback_night()
	if _playlist_spawning_invalid:
		push_error("BuildingManager: assigned spawn playlist is invalid; using legacy fallback spawning this night.")
	elif not _playlist_spawning_enabled:
		push_error("BuildingManager: no valid spawn playlist is enabled; using legacy fallback spawning this night.")
	_spawn_tick_controller.clear_ready_queue()
	_night_preparation_token += 1
	_night_preparing = true
	_night_preparation_ready = false
	call_deferred("_run_night_preparation", _night_preparation_token)


func _get_playlist_night_index_from_progression() -> int:
	var total_nights: int = _spawn_playlist_controller.get_total_night_count()
	if total_nights <= 0:
		return 0
	var prog: Node = _get_progression()
	if prog == null:
		return 0
	var day_number: int = int(prog.call("get_value", &"nDays"))
	var day_index: int = maxi(0, day_number - 1)
	return day_index % total_nights

func _get_progression() -> Node:
	if _progression != null and is_instance_valid(_progression):
		return _progression
	var scene: Node = get_tree().current_scene
	if scene != null:
		_progression = scene.get_node_or_null("progression")
	return _progression

func _get_steering_system() -> Node:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return null
	return scene.get_node_or_null("CPP/SteeringSystemNative")

func _rebuild_waterpool_directional_field() -> void:
	if watersources == null or not watersources.has_method("rebuild_waterpool_directional_field"):
		return
	var steering: Node = _get_steering_system()
	watersources.call("rebuild_waterpool_directional_field", steering)

func _clear_waterpool_directional_field() -> void:
	if watersources == null or not watersources.has_method("clear_waterpool_directional_field"):
		return
	var steering: Node = _get_steering_system()
	watersources.call("clear_waterpool_directional_field", steering)

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
	startup_loading_progress.emit(0.55, "Reading map")
	await get_tree().process_frame
	# Gardens and monster flow fields intentionally remain dirty during the day.
	# They are prepared from the final built map only when night begins.
	await _sync_runtime_state()
	_startup_ready = true
	startup_loading_progress.emit(1.0, "Ready")
	startup_loading_finished.emit()

func _night_preparation_is_current(token: int) -> bool:
	if token != _night_preparation_token:
		return false
	return GameState.is_night or (_client_preparing and not GameState.is_night)

func _night_preparation_budget_us() -> int:
	return maxi(500, int(night_preparation_budget_ms * 1000.0))

func _flow_uses_async_requests() -> bool:
	return _spawner_route_service.flow_uses_async_requests()

func _flow_supports_sync_assign() -> bool:
	return _spawner_route_service.flow_supports_sync_assign()

func _group_flow_id_is_ready(group_id: int) -> bool:
	return _spawner_route_service.group_flow_id_is_ready(group_id)

func _group_flow_is_ready_at_world(group_id: int, world_pos: Vector2) -> bool:
	return _spawner_route_service.group_flow_is_ready_at_world(group_id, world_pos)

func _run_night_preparation(token: int) -> void:
	# Start on a clean frame; the mode-change input frame performs no navigation.
	await get_tree().process_frame
	if not _night_preparation_is_current(token):
		return

	_scan_buildings()
	_sync_flow_extra_blocking_cells()
	_rebuild_waterpool_directional_field()
	_navigation_topology_dirty = false
	await get_tree().process_frame
	var prep_result: Variant = await _rebuild_walkable_map_cache_budgeted(token)
	if not bool(prep_result):
		return
	prep_result = await _build_gardens_from_plants_budgeted(token)
	if not bool(prep_result):
		return
	prep_result = await _validate_gardens_budgeted(token)
	if not bool(prep_result):
		return

	_rebuild_spawner_garden_route_cache()
	prep_result = await _initialize_spawner_routes_for_kinds([SPAWNER_KIND_MONSTER], token)
	if not bool(prep_result):
		return

	prep_result = await _prewarm_spawner_entry_flows_for_kind(SPAWNER_KIND_MONSTER, token)
	if not bool(prep_result):
		return

	# Exit fields also use the native worker during preparation.
	prep_result = await _rebuild_exit_wall_escapes_budgeted(token)
	if not bool(prep_result):
		return
	await get_tree().process_frame
	if not _night_preparation_is_current(token):
		return

	var scene: Node = get_tree().current_scene
	var fight_system: Node = scene.get_node_or_null("fightSystem") if scene else null
	if fight_system and fight_system.has_method("prepare_night_static_colliders_budgeted"):
		prep_result = await fight_system.call("prepare_night_static_colliders_budgeted", night_preparation_budget_ms)
		if not bool(prep_result):
			return
	elif fight_system and fight_system.has_method("prepare_night_static_colliders"):
		fight_system.call("prepare_night_static_colliders")

	# Do not open the spawn gate until async work has finished. Older exported
	# native DLLs may not expose async status methods; in that case requests are
	# assigned synchronously by _request_group_flow_rebuild().
	if not _flow_uses_async_requests() and not _flow_supports_sync_assign():
		push_error("BuildingManager: FlowFieldNative cannot assign group routes; night preparation cannot spawn monsters.")
		return
	if _flow_uses_async_requests():
		while _night_preparation_is_current(token) and not bool(flow.call("are_async_flows_idle")):
			await get_tree().process_frame
	if not _night_preparation_is_current(token):
		return
	if not _night_flow_fields_are_ready_for_kinds([SPAWNER_KIND_MONSTER], true):
		push_error("BuildingManager: night flow-field preparation completed with an unusable route")
		return

	_night_preparing = false
	_night_preparation_ready = true
	_seed_merchant.start_pending_leave_if_needed()
	CppDebugOptions.dlog("ff & gardens computed, monster night starts now")


func _run_client_preparation(token: int) -> void:
	await get_tree().process_frame
	if not _night_preparation_is_current(token):
		return

	_scan_buildings()
	_sync_flow_extra_blocking_cells()
	_rebuild_waterpool_directional_field()
	_navigation_topology_dirty = false
	await get_tree().process_frame
	var prep_result: Variant = await _rebuild_walkable_map_cache_budgeted(token)
	if not bool(prep_result):
		_abort_client_preparation(token)
		return
	prep_result = await _build_gardens_from_plants_budgeted(token)
	if not bool(prep_result):
		_abort_client_preparation(token)
		return
	prep_result = await _validate_gardens_budgeted(token)
	if not bool(prep_result):
		_abort_client_preparation(token)
		return

	_rebuild_spawner_garden_route_cache()
	prep_result = await _initialize_spawner_routes_for_kinds([SPAWNER_KIND_CLIENT, SPAWNER_KIND_MERCHANT], token)
	if not bool(prep_result):
		_abort_client_preparation(token)
		return

	prep_result = await _prewarm_spawner_entry_flows_for_kind(SPAWNER_KIND_CLIENT, token)
	if not bool(prep_result):
		_abort_client_preparation(token)
		return

	var scene: Node = get_tree().current_scene
	var fight_system: Node = scene.get_node_or_null("fightSystem") if scene else null
	if fight_system and fight_system.has_method("prepare_night_static_colliders_budgeted"):
		prep_result = await fight_system.call("prepare_night_static_colliders_budgeted", night_preparation_budget_ms)
		if not bool(prep_result):
			_abort_client_preparation(token)
			return
	elif fight_system and fight_system.has_method("prepare_night_static_colliders"):
		fight_system.call("prepare_night_static_colliders")

	if not _flow_uses_async_requests() and not _flow_supports_sync_assign():
		push_error("BuildingManager: FlowFieldNative cannot assign group routes; client preparation cannot spawn clients.")
		_abort_client_preparation(token)
		return
	if _flow_uses_async_requests():
		while _night_preparation_is_current(token) and not bool(flow.call("are_async_flows_idle")):
			await get_tree().process_frame
	if not _night_preparation_is_current(token):
		return
	if not _night_flow_fields_are_ready_for_kinds([SPAWNER_KIND_CLIENT, SPAWNER_KIND_MERCHANT], false):
		push_error("BuildingManager: client flow-field preparation completed with an unusable route")
		_abort_client_preparation(token)
		return

	_client_preparing = false
	_client_sale.activate()


func _abort_client_preparation(token: int) -> void:
	if token != _night_preparation_token:
		return
	if GameState.is_night:
		return
	_client_preparing = false
	_client_sale.reset()
	GameState.set_building_phase(true)

func _spawner_is_one_of_kinds(spawner_cell: Vector2i, agent_kinds: Array[StringName]) -> bool:
	var spawner_kind: StringName = _spawner_kind_by_cell.get(spawner_cell, SPAWNER_KIND_MONSTER) as StringName
	return agent_kinds.has(spawner_kind)

func _initialize_spawner_routes_for_kinds(agent_kinds: Array[StringName], token: int) -> bool:
	return bool(await _spawner_route_service.initialize_spawner_routes_for_kinds(agent_kinds, token))

func _night_flow_fields_are_ready_for_kinds(agent_kinds: Array[StringName], check_exit_wall_escapes: bool) -> bool:
	return _spawner_route_service.night_flow_fields_are_ready_for_kinds(agent_kinds, check_exit_wall_escapes)

func _prewarm_spawner_entry_flows_for_kind(agent_kind: StringName, token: int) -> bool:
	return bool(await _spawner_route_service.prewarm_spawner_entry_flows_for_kind(agent_kind, token))

func _mark_spawner_entry_routes_ready_for_groups(group_ids: Dictionary) -> void:
	_spawner_route_service.mark_spawner_entry_routes_ready_for_groups(group_ids)

func _rebuild_exit_wall_escapes_budgeted(token: int) -> bool:
	return bool(await _spawner_route_service.rebuild_exit_wall_escapes_budgeted(token))

func _rebuild_walkable_map_cache_budgeted(token: int) -> bool:
	return bool(await _garden_topology.rebuild_walkable_map_cache_budgeted(token))

func _build_gardens_from_plants_budgeted(token: int) -> bool:
	return bool(await _garden_topology.build_gardens_from_plants_budgeted(token))

func _validate_gardens_budgeted(token: int) -> bool:
	return bool(await _garden_topology.validate_gardens_budgeted(token))

func _recompute_garden_geometry_budgeted(garden_id: int, token: int) -> bool:
	return bool(await _garden_topology.recompute_garden_geometry_budgeted(garden_id, token))

func _recompute_spawner_reachable_cells_budgeted(token: int) -> bool:
	return bool(await _garden_topology.recompute_spawner_reachable_cells_budgeted(token))

func _rebuild_plant_zone_compatibility_cache_budgeted(token: int) -> bool:
	return bool(await _garden_topology.rebuild_plant_zone_compatibility_cache_budgeted(token))

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
	if _paused:
		_sync_plant_zone_debug_visibility()
		return
	if _night_preparing or _client_preparing:
		_sync_plant_zone_debug_visibility()
		return
	if _morning_harvest.is_active():
		_morning_harvest.process_walkover()
	var frame_start_us: int = Time.get_ticks_usec()
	var t: int = 0
	_scan_timer -= delta
	if _scan_timer <= 0.0:
		_scan_timer = 0.25
		t = Time.get_ticks_usec()
		_scan_buildings()
		_debug_telemetry.warn_garden_task_lag_us("_scan_buildings", Time.get_ticks_usec() - t,
			"spawners=%d" % _spawners.size())

	if _spawner_route_service.dirty_spawner_escape_count() > 0:
		# Capture the count before the call: _drain_dirty_routes clears the dict.
		var dirty_escapes_before: int = _spawner_route_service.dirty_spawner_escape_count()
		t = Time.get_ticks_usec()
		_drain_dirty_routes()
		_debug_telemetry.warn_garden_task_lag_us("_drain_dirty_routes", Time.get_ticks_usec() - t,
			"dirty_escapes=%d" % dirty_escapes_before)

	# Per-frame tasks: gate context construction on debug telemetry thresholds so the
	# (string-formatting) context is only built on a real spike, never every frame.
	t = Time.get_ticks_usec()
	_process_eating_agents(delta)
	_process_creature_rose_trampling()
	_process_pasteque_trampling()
	if _debug_telemetry.over_garden_threshold_us(Time.get_ticks_usec() - t):
		_debug_telemetry.warn_garden_task_lag_us("_process_eating_agents", Time.get_ticks_usec() - t,
			"eating=%d astar_in=%d escaping=%d" % [
				_eating_agents.size(), _astar_in_agents.size(),
				_escaping_agents.size()])

	t = Time.get_ticks_usec()
	_turret_eating_controller.process_turret_eating_agents(delta)
	_turret_eating_controller.process_turret_overlaps()
	if _debug_telemetry.over_garden_threshold_us(Time.get_ticks_usec() - t):
		_debug_telemetry.warn_garden_task_lag_us("_process_turrets_eaten", Time.get_ticks_usec() - t,
			"turret_eating=%d" % _turret_eating_controller.turret_eating_count())

	t = Time.get_ticks_usec()
	_drowning_controller.process_drowning_agents(delta)
	if _debug_telemetry.over_garden_threshold_us(Time.get_ticks_usec() - t):
		_debug_telemetry.warn_garden_task_lag_us("_process_drowning_agents", Time.get_ticks_usec() - t,
			"drowning=%d" % _drowning_controller.drowning_count())

	t = Time.get_ticks_usec()
	_process_astar_in_arrivals()
	if _debug_telemetry.over_garden_threshold_us(Time.get_ticks_usec() - t):
		_debug_telemetry.warn_garden_task_lag_us("_process_astar_in_arrivals", Time.get_ticks_usec() - t,
			"entry=%d astar_in=%d" % [_entry_path_agents.size(), _astar_in_agents.size()])

	t = Time.get_ticks_usec()
	_process_plant_arrivals()
	if _debug_telemetry.over_garden_threshold_us(Time.get_ticks_usec() - t):
		_debug_telemetry.warn_garden_task_lag_us("_process_plant_arrivals", Time.get_ticks_usec() - t,
			"astar_in=%d eating=%d" % [_astar_in_agents.size(), _eating_agents.size()])

	t = Time.get_ticks_usec()
	_process_client_counter_arrivals()
	_client_tantrum.process(delta)
	_seed_merchant.process_proximity()
	_seed_merchant.process_arrival()
	if _debug_telemetry.over_garden_threshold_us(Time.get_ticks_usec() - t):
		_debug_telemetry.warn_garden_task_lag_us("_process_client_counter_arrivals", Time.get_ticks_usec() - t,
			"counter_agents=%d" % _client_counter_agents.size())

	t = Time.get_ticks_usec()
	_process_escape_arrivals()
	if _debug_telemetry.over_garden_threshold_us(Time.get_ticks_usec() - t):
		_debug_telemetry.warn_garden_task_lag_us("_process_escape_arrivals", Time.get_ticks_usec() - t,
			"escaping=%d" % _escaping_agents.size())

	t = Time.get_ticks_usec()
	var retarget_processed: int = _process_garden_retarget_queue()
	var retarget_elapsed_us: int = Time.get_ticks_usec() - t
	if _debug_telemetry.over_garden_threshold_us(retarget_elapsed_us):
		_debug_telemetry.warn_garden_task_lag_us("_process_garden_retarget_queue", retarget_elapsed_us,
			"processed=%d remaining=%d budget=%dms elapsed=%.1fms" % [
				retarget_processed,
				_garden_retarget.queue_size(),
				int(garden_retarget_budget_ms),
				float(retarget_elapsed_us) / 1000.0,
			])

	t = Time.get_ticks_usec()
	_spawn_tick_controller.process(delta, _playlist_spawning_enabled)
	_client_sale.process(delta)
	_seed_merchant.process_phase()
	if _debug_telemetry.over_garden_threshold_us(Time.get_ticks_usec() - t):
		# Context (incl. the per-pass count summary) only built when over threshold.
		var stats: Dictionary = _spawn_tick_controller.spawn_pass_stats()
		_debug_telemetry.warn_garden_task_lag_us("_process_spawners", Time.get_ticks_usec() - t,
			"spawners=%d processed=%d spawned=%d assigned=%d skipped=%d ready_remaining=%d budget_count=%d budget_ms=%.1f elapsed=%.1fms active_monsters=%d route_cache_hits=%d route_cache_misses=%d" % [
				_spawners.size(),
				int(stats.get("processed_spawners", 0)),
				int(stats.get("spawned_count", 0)),
				int(stats.get("assigned_count", 0)),
				int(stats.get("skipped_count", 0)),
				int(stats.get("ready_queue_remaining", 0)),
				spawner_budget_per_frame,
				spawner_budget_ms,
				float(stats.get("elapsed_ms", 0.0)),
				int(stats.get("active_monsters", -1)),
				_spawner_route_service.route_cache_hits(),
				_spawner_route_service.route_cache_misses(),
			])

	t = Time.get_ticks_usec()
	_sync_plant_zone_debug_visibility()
	_debug_telemetry.warn_garden_task_lag_us("_sync_plant_zone_debug_visibility", Time.get_ticks_usec() - t)

	var frame_us: int = Time.get_ticks_usec() - frame_start_us
	var frame_threshold_ms: float = _debug_telemetry.frame_lag_threshold_ms()
	if frame_threshold_ms > 0.0 and (float(frame_us) / 1000.0) > frame_threshold_ms:
		push_warning("debug_nav_total_frame_lag: %dms (threshold=%dms) eating=%d astar_in=%d escaping=%d retarget_queue=%d spawners=%d direct_ff_exit_success=%d direct_ff_exit_failed=%d" % [
			int(round(float(frame_us) / 1000.0)),
			int(frame_threshold_ms),
			_eating_agents.size(),
			_astar_in_agents.size(),
			_escaping_agents.size(),
			_garden_retarget.queue_size(),
			_spawners.size(),
			eat_exit_direct_ff_success,
			eat_exit_direct_ff_failed
		])

func _load_tile_definitions() -> void:
	_building_scan.load_tile_definitions()

func _scan_buildings() -> void:
	_building_scan.scan_buildings()

func _apply_navigation_topology_rebuild() -> void:
	if not _navigation_topology_dirty:
		return
	_navigation_topology_dirty = false
	_sync_flow_extra_blocking_cells()
	_rebuild_waterpool_directional_field()
	_rebuild_walkable_map_cache()
	if _garden_topology.plant_zone_built():
		_rebuild_plant_zone_from_layer()
	_rebuild_spawner_garden_route_cache()
	for raw_spawner_cell: Variant in _spawners.keys():
		var spawner_cell: Vector2i = raw_spawner_cell as Vector2i
		_rebuild_spawner_plant_ff(spawner_cell)
		_spawner_route_service.mark_spawner_escape_dirty(spawner_cell)
	var exits_us: int = Time.get_ticks_usec()
	_rebuild_exit_wall_escapes()
	_debug_telemetry.warn_garden_task_lag_us("_rebuild_exit_wall_escapes", Time.get_ticks_usec() - exits_us,
		"exits=%d" % _spawner_route_service.exit_wall_escape_count())

func _sync_flow_extra_blocking_cells() -> void:
	if flow == null or not flow.has_method("set_extra_blocking_cells"):
		return
	var cells: PackedVector2Array = PackedVector2Array()
	if blocking_buildings != null:
		for raw_cell: Variant in blocking_buildings.get_used_cells():
			var cell: Vector2i = raw_cell as Vector2i
			if not _building_cell_blocks_movement(cell):
				continue
			cells.append(Vector2(float(cell.x), float(cell.y)))
	flow.call("set_extra_blocking_cells", cells)
	# Fences are kept out of extra_blocking_cells (which feeds player collision and every
	# group flow). They are pushed as a separate set that only client/merchant flows bake
	# as walls (block_fences); monster flows ignore fences and are slowed by the fence
	# cells' 0.3 speed multiplier instead. See _request_group_flow_rebuild / _has_wall.
	if flow.has_method("set_fence_blocking_cells"):
		var fence_cells: PackedVector2Array = PackedVector2Array()
		if fences != null:
			for raw_cell: Variant in fences.get_used_cells():
				var fence_cell: Vector2i = raw_cell as Vector2i
				fence_cells.append(Vector2(float(fence_cell.x), float(fence_cell.y)))
		flow.call("set_fence_blocking_cells", fence_cells)

func _sync_runtime_state() -> void:
	_scan_buildings()
	_validate_playlist_after_spawner_scan()
	_apply_navigation_topology_rebuild()
	_sync_player_blocking_cells()
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


func _validate_playlist_after_spawner_scan() -> void:
	if _playlist_validation_attempted:
		return
	_playlist_validation_attempted = true
	_playlist_spawning_enabled = false
	_playlist_spawning_invalid = false
	_spawner_bindings_by_id.clear()
	if _level_spawn_playlist == null:
		_playlist_spawning_invalid = true
		push_error("BuildingManager: no spawn playlist found for '%s'; spawning disabled." % _loaded_level_scene_path)
		return
	if _level_spawner_bindings.is_empty():
		_playlist_spawning_invalid = true
		push_error("BuildingManager: spawn playlist exists for '%s' but the level has no spawner node bindings; spawning disabled." % _loaded_level_scene_path)
		return
	var binding_cells: Dictionary = {}
	var bindings_valid: bool = true
	for binding: SpawnerBinding in _level_spawner_bindings:
		if binding == null:
			push_error("BuildingManager: null spawner binding in level spawn config.")
			bindings_valid = false
			continue
		if binding.kind != SPAWNER_KIND_MONSTER:
			continue
		if binding.spawner_id == &"":
			push_error("BuildingManager: spawner binding has empty spawner_id for cell %s." % str(binding.cell))
			bindings_valid = false
			continue
		if _spawner_bindings_by_id.has(binding.spawner_id):
			push_error("BuildingManager: duplicate spawner binding ID '%s'." % String(binding.spawner_id))
			bindings_valid = false
			continue
		if binding_cells.has(binding.cell):
			push_error("BuildingManager: duplicate spawner binding cell %s." % str(binding.cell))
			bindings_valid = false
			continue
		_spawner_bindings_by_id[binding.spawner_id] = binding.cell
		binding_cells[binding.cell] = true
	if not bindings_valid:
		_playlist_spawning_invalid = true
		push_error("BuildingManager: invalid spawner bindings; playlist spawning disabled for safety.")
		return
	var valid_monster_types: Dictionary = _valid_monster_types()
	var valid: bool = _spawn_playlist_controller.configure(
		_level_spawn_playlist,
		_spawner_bindings_by_id,
		_spawners,
		valid_monster_types
	)
	if not valid:
		for raw_error: Variant in _spawn_playlist_controller.get_last_errors():
			push_error("BuildingManager: " + str(raw_error))
		_playlist_spawning_invalid = true
		push_error("BuildingManager: invalid level spawn playlist; playlist spawning disabled for safety.")
		return
	_playlist_spawning_enabled = true
	CppDebugOptions.dlog("BuildingManager: spawn playlist enabled for '%s' with %d night(s) and %d spawner binding(s)." % [
		_loaded_level_scene_path,
		_spawn_playlist_controller.get_total_night_count(),
		_spawner_bindings_by_id.size(),
	])
	if debug_logs:
		_debug_telemetry.log("Configured spawn playlist nights=%d bindings=%d" % [
			_spawn_playlist_controller.get_total_night_count(),
			_spawner_bindings_by_id.size(),
		])


func _valid_monster_types() -> Dictionary:
	var types: Dictionary = {}
	for monster_id: StringName in MonsterCatalog.get_ids():
		types[monster_id] = true
	return types


func _resolve_monster_scene(monster_type: StringName) -> PackedScene:
	# Every monster type shares character.tscn; MonsterData (applied at spawn via
	# _apply_monster_data) drives the per-type sprite and stats.
	if MonsterCatalog.has_monster(monster_type):
		return AGENT_SCENE
	_debug_telemetry.log_spawn_failure("unknown monster_type '%s'" % String(monster_type))
	return null


# Apply a MonsterData bible entry to a freshly instantiated monster agent: swaps the
# sprite, sets health, and stashes the per-agent stat overrides as metadata that the
# native agent manager reads in spawn_agent (speed/crowd/smash scales). The
# "monster_type" meta is also kept so the corpse can reuse the same sprite.
func _apply_monster_data(agent: Node2D, monster_type: StringName) -> void:
	agent.set_meta("monster_type", monster_type)
	var data: MonsterData = MonsterCatalog.get_monster(monster_type)
	if data == null:
		return
	var sprite: Sprite2D = agent.get_node_or_null("MonsterSprite2D") as Sprite2D
	if sprite != null:
		if data.texture != null:
			sprite.texture = data.texture
		sprite.hframes = data.sprite_hframes
		sprite.scale = data.sprite_scale
		sprite.position = data.sprite_offset
	# _ready() already ran (add_child), so override both the exported cap and the
	# live pool.
	agent.set("max_health", data.max_health)
	agent.set("health", data.max_health)
	agent.set_meta("monster_speed_scale", data.speed_scale)
	agent.set_meta("monster_crowd_resist", data.crowd_resist_scale)
	agent.set_meta("monster_smash_resist", data.smash_resist_scale)

func _setup_plant_manager() -> void:
	if not plant_manager:
		return
	if plant_manager.has_method("initialize_from_layer"):
		plant_manager.call("initialize_from_layer")
	if plant_manager.has_signal("plant_added") and not plant_manager.is_connected("plant_added", Callable(self, "_on_plant_added")):
		plant_manager.connect("plant_added", Callable(self, "_on_plant_added"))
	if plant_manager.has_signal("plant_removed") and not plant_manager.is_connected("plant_removed", Callable(self, "_on_plant_removed")):
		plant_manager.connect("plant_removed", Callable(self, "_on_plant_removed"))
	if plant_manager.has_signal("new_day_finished") and not plant_manager.is_connected("new_day_finished", Callable(self, "_on_new_day_finished")):
		plant_manager.connect("new_day_finished", Callable(self, "_on_new_day_finished"))


func _setup_building_object_manager() -> void:
	var building_objects: BuildingObjectManager = _get_building_object_manager()
	if building_objects == null:
		return
	if building_objects.has_signal("building_added") and not building_objects.is_connected("building_added", Callable(self, "_on_building_added")):
		building_objects.connect("building_added", Callable(self, "_on_building_added"))
	if building_objects.has_signal("building_removed") and not building_objects.is_connected("building_removed", Callable(self, "_on_building_removed")):
		building_objects.connect("building_removed", Callable(self, "_on_building_removed"))


func _setup_counter_stock_manager() -> void:
	if _counter_stock_manager == null:
		_counter_stock_manager = CounterStockManager.new()
		_counter_stock_manager.name = "CounterStockManager"
		add_child(_counter_stock_manager)
	_counter_stock_manager.configure(
		_rose_pile_parent(),
		Callable(self, "_cell_center"),
		Callable(self, "_is_walkable"),
		Callable(self, "_has_plant_cell")
	)


func _on_building_added(cell: Vector2i, item_id: String) -> void:
	if _building_item_blocks_player(item_id):
		_set_player_cell_blocked(cell, true)
	_sync_building_cell_speed(cell, item_id)
	if _building_item_blocks_flow(item_id):
		_navigation_topology_dirty = true
	if item_id != ROSE_SHOP_COUNTER_ID:
		return


func _on_building_removed(cell: Vector2i, item_id: String) -> void:
	if _building_item_blocks_player(item_id):
		_set_player_cell_blocked(cell, false)
	_sync_building_cell_speed(cell, item_id)
	if _building_item_blocks_flow(item_id):
		_navigation_topology_dirty = true
	if item_id != ROSE_SHOP_COUNTER_ID:
		return
	_counter_stock_manager.clear_counter(cell)
	for raw_nav_id: Variant in _client_counter_agents.keys():
		var nav_id: int = int(raw_nav_id)
		var data: Dictionary = _client_counter_agents[nav_id] as Dictionary
		if (data.get("counter_cell", INVALID_CELL) as Vector2i) == cell:
			var raw_agent: Variant = data.get("node", null)
			_client_counter_agents.erase(nav_id)
			if is_instance_valid(raw_agent):
				var agent: Node2D = raw_agent as Node2D
				if agent != null:
					var spawner_cell: Vector2i = agent.get_meta("spawner_cell") as Vector2i if agent.has_meta("spawner_cell") else INVALID_CELL
					_retarget_agent_or_escape(agent, spawner_cell)


func _building_item_blocks_flow(item_id: String) -> bool:
	var item_def: Dictionary = ItemCatalog.get_item_def(item_id)
	if item_def.is_empty():
		return false
	if bool(item_def.get("blocks_agents", false)):
		return true
	if str(item_def.get("target_layer", "")) != "blocking_buildings":
		return false
	return bool(item_def.get("blocks_movement", false)) or bool(item_def.get("isWall", false))

func _building_item_blocks_player(item_id: String) -> bool:
	var item_def: Dictionary = ItemCatalog.get_item_def(item_id)
	if item_def.is_empty():
		return false
	if str(item_def.get("target_layer", "")) != "blocking_buildings":
		return false
	if item_def.has("blocks_player_movement"):
		return bool(item_def.get("blocks_player_movement", false))
	return bool(item_def.get("blocks_movement", false)) or bool(item_def.get("isWall", false))

func _sync_player_blocking_cells() -> void:
	if flow == null or not flow.has_method("set_cell_blocked") or blocking_buildings == null:
		return
	for raw_cell: Variant in blocking_buildings.get_used_cells():
		var cell: Vector2i = raw_cell as Vector2i
		var item_id: String = _blocking_building_item_id_at_cell(cell)
		if item_id == "" or _building_item_blocks_player(item_id):
			_set_player_cell_blocked(cell, true)

func _set_player_cell_blocked(cell: Vector2i, blocked: bool) -> void:
	if flow == null or not flow.has_method("set_cell_blocked"):
		return
	flow.call("set_cell_blocked", cell, blocked)

func _blocking_building_item_id_at_cell(cell: Vector2i) -> String:
	if blocking_buildings == null or blocking_buildings.get_cell_source_id(cell) < 0:
		return ""
	var atlas: Vector2i = blocking_buildings.get_cell_atlas_coords(cell)
	return ItemCatalog.get_placeable_id_for_tile(str(blocking_buildings.name), atlas)

func _sync_building_cell_speed(cell: Vector2i, item_id: String) -> void:
	if flow == null or not flow.has_method("set_cell_speed_multiplier"):
		return
	var item_def: Dictionary = ItemCatalog.get_item_def(item_id)
	if item_def.is_empty() or not item_def.has("speed_multiplier"):
		return
	# The buildsystem's terrain-speed refresh and this signal-driven sync both write
	# the same flow-field cell. A fence carries a speed_multiplier but lives on the
	# `fences` layer, so if we only inspected blocking_buildings we'd reset the cell to
	# 1.0 and clobber the fence slow the buildsystem just applied. Recompute the
	# effective multiplier across every speed-carrying layer instead.
	flow.call("set_cell_speed_multiplier", cell, _effective_cell_speed_multiplier(cell))

func _effective_cell_speed_multiplier(cell: Vector2i) -> float:
	var speed_multiplier: float = DEFAULT_TERRAIN_SPEED_MULTIPLIER
	for layer: TileMapLayer in [plantz, traversable_buildings, blocking_buildings, fences]:
		if layer == null or layer.get_cell_source_id(cell) < 0:
			continue
		var layer_item_id: String = ItemCatalog.get_placeable_id_for_tile(str(layer.name), layer.get_cell_atlas_coords(cell))
		if layer_item_id == "":
			continue
		var layer_item_def: Dictionary = ItemCatalog.get_item_def(layer_item_id)
		var layer_multiplier: float = clampf(float(layer_item_def.get("speed_multiplier", DEFAULT_TERRAIN_SPEED_MULTIPLIER)), 0.01, 1.0)
		speed_multiplier = minf(speed_multiplier, layer_multiplier)
	return speed_multiplier

func _on_plant_added(_cell: Vector2i) -> void:
	if not GameState.is_night:
		# Day/client placement only dirties the next prepared snapshot. Freshly planted
		# roses are not valid client targets, so client sale must not rebuild every
		# existing garden per rose during rectangle placement.
		_garden_topology.set_plant_zone_built(false)
		_navigation_topology_dirty = true
		if _zone_overlay:
			_zone_overlay.queue_redraw()
		return
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
	_sync_building_cell_speed(cell, "debris")
	if not _runtime_agents_active():
		_garden_topology.set_plant_zone_built(false)
		_navigation_topology_dirty = true
		if _zone_overlay:
			_zone_overlay.queue_redraw()
		return
	var removed_us: int = Time.get_ticks_usec()
	var result: Dictionary = _remove_plant_from_garden_content_only(cell)
	if not bool(result.get("was_removed", false)):
		return

	var garden_id: int = int(result.get("garden_id", 0))
	var became_empty: bool = bool(result.get("became_empty", false))

	if became_empty and garden_id > 0:
		var empty_us: int = Time.get_ticks_usec()
		_handle_garden_became_empty(garden_id)
		_debug_telemetry.warn_garden_task_lag_us("_handle_garden_became_empty", Time.get_ticks_usec() - empty_us,
			"garden=%d retarget_queue=%d" % [garden_id, _garden_retarget.queue_size()])
	else:
		var rt_us: int = Time.get_ticks_usec()
		_retarget_agents_targeting_removed_plant_only(cell, garden_id)
		_debug_telemetry.warn_garden_task_lag_us("_retarget_agents_targeting_removed_plant_only", Time.get_ticks_usec() - rt_us,
			"garden=%d plant=%s astar_in=%d bucket_size=%d valid_affected=%d queued=%d already_queued=%d stale=%d indexed_targets=%d" % [
				garden_id, str(cell), _garden_retarget.last_plant_retarget_astar_in(),
				_garden_retarget.last_plant_retarget_bucket(), _garden_retarget.last_plant_retarget_affected(),
				_garden_retarget.last_plant_retarget_queued(), _garden_retarget.last_plant_retarget_already_queued(),
				_garden_retarget.last_plant_retarget_stale(), _garden_retarget.target_index_size()])

	if _zone_overlay:
		_zone_overlay.queue_redraw()

	if _no_plants_remaining():
		_queue_escape_for_all_monsters_budgeted()
	_debug_telemetry.warn_garden_task_lag_us("_on_plant_removed", Time.get_ticks_usec() - removed_us,
		"garden=%d empty=%s" % [garden_id, str(became_empty)])


func _runtime_agents_active() -> bool:
	return GameState.is_night or _client_sale.is_active()

func _scan_special_layer(layer: TileMapLayer, _seen_spawners: Dictionary) -> void:
	_building_scan.scan_special_layer(layer, _seen_spawners)


func _scan_configured_spawner_nodes(seen_spawners: Dictionary) -> void:
	_building_scan.scan_configured_spawner_nodes(seen_spawners)

func _migrate_special_tiles_from_wallz() -> bool:
	return _building_scan.migrate_special_tiles_from_wallz()

func _definition_for_cell(cell: Vector2i) -> Dictionary:
	return _building_scan.definition_for_cell(cell)

# Cheap local-obstacle query for later monster local movement / combat. Returns true
# when `cell` holds a breakable blocking building (e.g. turret1). This is intentionally
# decoupled from walls and flowfields: global pathfinding still routes through these
# cells; only local agent movement should treat them as soft round blockers. Placement
# of a blocking building never triggers a wall/FF topology rebuild.
func is_blocking_building_cell(cell: Vector2i) -> bool:
	return _building_cell_blocks_movement(cell)

func _building_cell_blocks_movement(cell: Vector2i) -> bool:
	if blocking_buildings == null or blocking_buildings.get_cell_source_id(cell) < 0:
		return false
	var atlas: Vector2i = blocking_buildings.get_cell_atlas_coords(cell)
	for raw_item_def: Variant in ItemCatalog.ITEM_DEFS.values():
		var item_def: Dictionary = raw_item_def as Dictionary
		if str(item_def.get("type", "")) != "placeable":
			continue
		if str(item_def.get("target_layer", "")) != "blocking_buildings":
			continue
		var raw_atlas: Variant = item_def.get("atlas", Vector2i(-1, -1))
		if not raw_atlas is Vector2i:
			continue
		if (raw_atlas as Vector2i) != atlas:
			continue
		return bool(item_def.get("blocks_movement", false)) or bool(item_def.get("isWall", false))
	return true

func _definition_for_layer_cell(layer: TileMapLayer, cell: Vector2i) -> Dictionary:
	return _building_scan.definition_for_layer_cell(layer, cell)

func _register_spawner(cell: Vector2i, kind: StringName = SPAWNER_KIND_MONSTER, exit_cell: Vector2i = INVALID_CELL, frequency_client: float = 1.0, spot_cell: Vector2i = INVALID_CELL) -> void:
	var is_new: bool = not _spawners.has(cell)
	_spawners[cell] = true
	_spawner_kind_by_cell[cell] = kind
	if exit_cell != INVALID_CELL:
		_spawner_exit_cell_by_cell[cell] = exit_cell
	else:
		_spawner_exit_cell_by_cell.erase(cell)
	if spot_cell != INVALID_CELL:
		_spawner_spot_cell_by_cell[cell] = spot_cell
	else:
		_spawner_spot_cell_by_cell.erase(cell)
	if kind == SPAWNER_KIND_CLIENT:
		_client_spawners[cell] = true
		_client_frequency_by_cell[cell] = maxf(0.0, frequency_client)
	else:
		_client_spawners.erase(cell)
		_client_frequency_by_cell.erase(cell)
	if kind == SPAWNER_KIND_MERCHANT:
		_merchant_spawners[cell] = true
	else:
		_merchant_spawners.erase(cell)
	if is_new and GameState.is_night and _night_preparation_ready and _flow_ready and _garden_topology.plant_zone_built() and _startup_ready:
		_initialize_spawner_route(cell)

func _remove_missing_scanned_spawner(cell: Vector2i) -> void:
	_spawners.erase(cell)
	_release_spawner_route(cell)
	_spawner_route_service.clear_dirty_spawner_escape(cell)

func _release_spawner_route(spawner_cell: Vector2i) -> void:
	_spawner_route_service.release_spawner_route(spawner_cell)
	_spawner_kind_by_cell.erase(spawner_cell)
	_spawner_exit_cell_by_cell.erase(spawner_cell)
	_spawner_spot_cell_by_cell.erase(spawner_cell)
	_client_spawners.erase(spawner_cell)
	_client_frequency_by_cell.erase(spawner_cell)
	_merchant_spawners.erase(spawner_cell)

func _drain_dirty_routes() -> void:
	_spawner_route_service.drain_dirty_routes()

func _initialize_spawner_route(spawner_cell: Vector2i) -> void:
	_spawner_route_service.initialize_spawner_route(spawner_cell)

func _rebuild_spawner_plant_ff(spawner_cell: Vector2i) -> void:
	_spawner_route_service.rebuild_spawner_plant_ff(spawner_cell)

func _rebuild_spawner_escape_ff(spawner_cell: Vector2i) -> void:
	_spawner_route_service.rebuild_spawner_escape_ff(spawner_cell)

func _rebuild_all_spawner_routes() -> void:
	_spawner_route_service.rebuild_all_spawner_routes()

# Build/refresh one escape flow field per exit-wall tile. Each is a per-group FF
# whose goal is the floor tile adjacent to that exit wall. Runs only on dirty
# events; at runtime a monster reads each group's route cost to pick the nearest
# reachable exit. Stale exits (walls removed) are released.
func _rebuild_exit_wall_escapes(use_async_requests: bool = false) -> void:
	_spawner_route_service.rebuild_exit_wall_escapes(use_async_requests)

func _release_exit_wall_escape(exit_cell: Vector2i) -> void:
	_spawner_route_service.release_exit_wall_escape(exit_cell)

# Pick the exit-wall escape with the lowest walkable route cost from world_pos.
# Returns {} if none is reachable (caller falls back to the per-spawner escape).
func _nearest_reachable_exit_escape(world_pos: Vector2) -> Dictionary:
	return _spawner_route_service.nearest_reachable_exit_escape(world_pos)

func _request_group_flow_rebuild(group_id: int, goal_world: Vector2) -> void:
	_spawner_route_service.request_group_flow_rebuild(group_id, goal_world)

func _is_finite_world(p: Vector2) -> bool:
	if not (is_finite(p.x) and is_finite(p.y)):
		return false
	var limit: float = float(_SANE_CELL_LIMIT) * 64.0
	return abs(p.x) <= limit and abs(p.y) <= limit

func _no_plants_remaining() -> bool:
	if _total_counter_stock() > 0:
		return false
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


func _on_new_day_finished() -> void:
	if GameState.is_night:
		return
	_day_start_pending = false
	_begin_seed_merchant_phase()
	_begin_morning_phase()


func _begin_morning_phase() -> void:
	await _morning_harvest.begin_phase()


func _process_morning_harvest_walkover() -> void:
	_morning_harvest.process_walkover()


# Clients and merchants crush any rose they walk over, leaving debris behind.
# Monsters reach roses through the garden targeting/eating system; this covers the
# shop-bound creatures that cross the garden without ever targeting a plant. The
# player is exempt (it harvests roses instead). consume_plant() swaps the rose tile
# for the debris tile and fires plant_removed, so any monster targeting that cell
# retargets synchronously — the same path a normal eat takes.
func _process_creature_rose_trampling() -> void:
	if plant_manager == null or floorz == null:
		return
	if not plant_manager.has_method("is_rose_cell") or not plant_manager.has_method("consume_plant"):
		return
	for group_name: StringName in [&"clients", &"merchants"]:
		for raw_agent: Node in get_tree().get_nodes_in_group(group_name):
			var agent: Node2D = raw_agent as Node2D
			if not is_instance_valid(agent):
				continue
			var cell: Vector2i = floorz.local_to_map(floorz.to_local(agent.global_position))
			if bool(plant_manager.call("is_rose_cell", cell)):
				plant_manager.call("consume_plant", cell)


func _process_pasteque_trampling() -> void:
	var pasteque_def: Dictionary = ItemCatalog.get_item_def(PASTEQUE_ITEM_ID)
	if not bool(pasteque_def.get("destroyed_by_creatures", false)):
		return
	if traversable_buildings == null:
		return
	var building_objects: BuildingObjectManager = _get_building_object_manager()
	if building_objects == null or not building_objects.has_method("get_building"):
		return
	var checked_cells: Dictionary = {}
	for group_name: StringName in [&"monsters", &"clients"]:
		for raw_agent: Node in get_tree().get_nodes_in_group(group_name):
			var agent: Node2D = raw_agent as Node2D
			if not is_instance_valid(agent):
				continue
			var cell: Vector2i = traversable_buildings.local_to_map(traversable_buildings.to_local(agent.global_position))
			if checked_cells.has(cell):
				continue
			checked_cells[cell] = true
			var building_data: Dictionary = building_objects.call("get_building", cell) as Dictionary
			if str(building_data.get("item_id", "")) == PASTEQUE_ITEM_ID:
				_destroy_pasteque_cell(cell)


func has_grownup_roses_to_harvest() -> bool:
	return _morning_harvest.has_grownup_roses_to_harvest()


func restore_day_phase(phase: String) -> void:
	if GameState.is_night:
		return
	_morning_harvest.clear_active()
	_reset_client_sale_state()
	match phase:
		"morning":
			call_deferred("_begin_morning_phase")
		"client":
			call_deferred("_begin_client_sale_phase")
		"seed_merchant":
			call_deferred("_begin_seed_merchant_phase")
		_:
			GameState.set_building_phase(true)


func _check_morning_harvest_finished() -> void:
	_morning_harvest.check_finished()


func reset_client_state_for_morning() -> void:
	_reset_client_sale_state()


# Single reset path for the manager-owned client-sale state: the deferred-preparation
# flag (_client_preparing) plus the counter-agent registry (_client_counter_agents),
# alongside the controller's own sale-local reset. Kept here (not in the controller)
# because both pieces are owned by the manager per the client-sale boundary rules.
func _reset_client_sale_state() -> void:
	_client_preparing = false
	_client_sale.reset()
	clear_client_counter_agents()


func begin_client_sale_phase() -> void:
	_begin_client_sale_phase()


func _begin_client_sale_phase() -> void:
	_client_sale.reset()
	_client_tantrum.end()
	var client_total: int = _client_sale.current_night_client_count()
	if client_total <= 0 or _client_spawners.is_empty() or not _has_client_targets_remaining():
		GameState.set_building_phase(true)
		return
	_night_preparation_token += 1
	_client_preparing = true
	_night_preparation_ready = false
	call_deferred("_run_client_preparation", _night_preparation_token)


func can_start_night_after_clients() -> bool:
	# Gate on "no client sale is still pending" rather than "a client actually
	# visited": on days with no counter stock the sale is skipped and no client ever
	# spawns, yet the player must still be able to water their roses and end the day.
	# _client_preparing covers the deferred window before clients spawn, so night
	# can't jump ahead of a sale that is genuinely coming.
	return not _day_start_pending and not _client_preparing and _client_sale.clients_finished_for_day() and _client_sale.all_planted_roses_are_wet()


func has_clients_for_save_load() -> bool:
	return _client_preparing or not _client_sale.clients_finished_for_day()


func save_load_client_block_reason() -> String:
	if _client_preparing:
		return "client preparation active"
	if _client_sale.is_active():
		return "client sale active"
	if GameState.is_client_phase:
		return "client phase active"
	if _client_sale.has_pending_spawners():
		return "incoming clients pending"
	if _client_sale.client_count() > 0:
		return "clients on map"
	if not _client_counter_agents.is_empty():
		return "clients walking to counters"
	return ""


func _begin_seed_merchant_phase() -> void:
	_seed_merchant.begin_phase(_merchant_spawners)


func _process_seed_merchant_arrival() -> void:
	_seed_merchant.process_arrival()


func _process_seed_merchant_phase() -> void:
	_seed_merchant.process_phase()


# True whenever the player is within interaction range of the merchant, no matter what
# the merchant is doing (walking in, parked at the spot, or walking back out). This
# drives both the toolbuild picker visibility (toolbuild.gd) and the movement pause below.
func is_player_near_seed_merchant() -> bool:
	return _seed_merchant.is_player_near()


# Freezes the merchant while the player is close and lets it resume the moment they
# leave, so getting near always stops it (and opens the shop, via is_player_near_...).
func _process_seed_merchant_proximity() -> void:
	_seed_merchant.process_proximity()


func request_seed_merchant_leave() -> void:
	_seed_merchant.request_leave()


func _start_seed_merchant_leave_for_night() -> void:
	_seed_merchant.start_leave_for_night()


func _clear_seed_merchant_phase(free_agent: bool) -> void:
	_seed_merchant.clear_phase(free_agent)


func _end_seed_merchant_phase() -> void:
	_seed_merchant.end_phase()


func is_client_sale_active() -> bool:
	return _client_sale.is_active()


func is_night_preparation_ready() -> bool:
	return _night_preparation_ready


func occupied_cells_for_spawning() -> Array[Vector2i]:
	return _occupied_cells()


func find_free_cell_near_spawner(spawner_cell: Vector2i, occupied: Array[Vector2i]) -> Vector2i:
	return _find_free_cell_near(spawner_cell, occupied)


func seed_merchant_spot_cell(spawner_cell: Vector2i) -> Vector2i:
	return _spawner_spot_cell_by_cell.get(spawner_cell, INVALID_CELL) as Vector2i


func is_walkable_cell(cell: Vector2i) -> bool:
	return _is_walkable(cell)


func find_path_on_walkable_map(from_cell: Vector2i, to_cell: Vector2i) -> PackedVector2Array:
	return _find_path_on_walkable_map(from_cell, to_cell)


func cell_center(cell: Vector2i) -> Vector2:
	return _cell_center(cell)


func register_desire_agent(agent: Node2D, group_name: StringName) -> void:
	_register_desire_agent(agent, group_name)


func path_cells_to_world(path_cells: PackedVector2Array, nav_id: int = -1, disperse_endpoint: bool = false) -> PackedVector2Array:
	return _path_cells_to_world(path_cells, nav_id, disperse_endpoint)


func assign_agent_to_escape(agent: Node2D) -> bool:
	return _assign_agent_to_escape(agent)


func grownup_rose_count() -> int:
	if plant_manager != null and plant_manager.has_method("grownup_rose_count"):
		return int(plant_manager.call("grownup_rose_count"))
	return 0


func _grownup_rose_count() -> int:
	return grownup_rose_count()


func _rose_shop_counter_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var building_objects: BuildingObjectManager = _get_building_object_manager()
	if building_objects != null and building_objects.has_method("get_building_cells_by_item_id"):
		var raw_cells: Array = building_objects.call("get_building_cells_by_item_id", ROSE_SHOP_COUNTER_ID) as Array
		for raw_cell: Variant in raw_cells:
			cells.append(raw_cell as Vector2i)
		return cells
	var item_def: Dictionary = ItemCatalog.get_item_def(ROSE_SHOP_COUNTER_ID)
	var atlas: Vector2i = item_def.get("atlas", Vector2i(-1, -1)) as Vector2i
	for layer: TileMapLayer in [traversable_buildings, blocking_buildings]:
		if layer == null:
			continue
		for raw_cell: Variant in layer.get_used_cells():
			var cell: Vector2i = raw_cell as Vector2i
			if layer.get_cell_atlas_coords(cell) == atlas and not cells.has(cell):
				cells.append(cell)
	return cells


func _rose_shop_counter_cells_with_room() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for counter_cell: Vector2i in _rose_shop_counter_cells():
		if _counter_stock_manager.has_room(counter_cell):
			cells.append(counter_cell)
	return cells


func rose_shop_counter_count() -> int:
	return _rose_shop_counter_cells().size()


func has_counter_room_for_harvest() -> bool:
	return not _rose_shop_counter_cells_with_room().is_empty()


func rose_shop_counter_cells_with_room() -> Array[Vector2i]:
	return _rose_shop_counter_cells_with_room()


func counter_room_for_harvest() -> int:
	var total: int = 0
	for counter_cell: Vector2i in _rose_shop_counter_cells():
		total += _counter_stock_manager.remaining_capacity(counter_cell)
	return total


func _total_counter_stock() -> int:
	return _counter_stock_manager.total_stock()


## Public accessor: total number of harvested roses waiting on shop counters.
func total_counter_stock() -> int:
	return _total_counter_stock()


func serialize_counter_stock() -> Array[Dictionary]:
	return _counter_stock_manager.serialize(_rose_shop_counter_cells())


func restore_counter_stock(saved_stock: Array) -> void:
	_counter_stock_manager.restore(saved_stock, _rose_shop_counter_cells())
	_garden_topology.counter_access_cells().clear()
	_garden_topology.set_plant_zone_built(false)
	_navigation_topology_dirty = true


func _counter_stock(counter_cell: Vector2i) -> int:
	return _counter_stock_manager.stock(counter_cell)


func _add_counter_stock(counter_cell: Vector2i, amount: int) -> void:
	var change: Dictionary = _counter_stock_manager.add_stock(counter_cell, amount)
	_after_counter_stock_changed(int(change.get("previous", 0)), int(change.get("value", 0)))


func add_counter_stock(counter_cell: Vector2i, amount: int) -> void:
	_add_counter_stock(counter_cell, amount)


func _set_counter_stock(counter_cell: Vector2i, amount: int) -> void:
	var change: Dictionary = _counter_stock_manager.set_stock(counter_cell, amount)
	var previous: int = int(change.get("previous", 0))
	var value: int = int(change.get("value", 0))
	_after_counter_stock_changed(previous, value)


func _after_counter_stock_changed(previous: int, value: int) -> void:
	# A counter gaining its first rose turns it into an edible garden, which requires
	# folding its access tiles into the garden topology (a full rebuild). Depletion
	# (positive -> 0) needs no rebuild: the access tiles simply stop being edible and
	# the empty-garden machinery removes a counter-only garden like any other.
	if previous == 0 and value > 0 and _garden_topology.plant_zone_built():
		_rebuild_plant_zone_from_layer()
	elif previous > 0 and value == 0 and _no_plants_remaining():
		_force_escape_for_all_monsters()


# Populates _garden_topology.counter_access_cells() from every stocked counter and returns the access
# tiles as an array to seed the garden clustering. An access tile is a walkable cell
# 8-adjacent to the counter that does not already hold a plant (the flower keeps its
# own cell). Called from _build_gardens_from_plants, which clears the map first.
func _collect_counter_access_cells() -> Array[Vector2i]:
	return _garden_topology.collect_counter_access_cells()

func _collect_counter_access_cells_into(counter_access_cells: Dictionary) -> Array[Vector2i]:
	return _counter_stock_manager.collect_access_cells(counter_access_cells)

func _is_eatable_for_monster(cell: Vector2i) -> bool:
	return _garden_topology.is_eatable_for_monster(cell)

func _consume_counter_rose(eater: Node2D, _spawner_cell: Vector2i, access_cell: Vector2i) -> void:
	var counter_cell: Vector2i = _garden_topology.counter_access_cells()[access_cell] as Vector2i
	_start_agent_eating(eater, _eating_time, access_cell)
	Sfx.play_sound(&"crunsh")
	_set_counter_stock(counter_cell, _counter_stock(counter_cell) - 1)



func _select_stocked_counter_target(from_cell: Vector2i) -> Dictionary:
	return _counter_stock_manager.select_stocked_counter_target(from_cell)


func _nearest_counter_access_cell(counter_cell: Vector2i, from_cell: Vector2i) -> Vector2i:
	return _counter_stock_manager.nearest_counter_access_cell(counter_cell, from_cell)


func _animate_harvested_rose_to_counter(start_world: Vector2, counter_cell: Vector2i) -> void:
	_counter_stock_manager.animate_harvested_rose(start_world, counter_cell)


func animate_harvested_rose_to_counter(start_world: Vector2, counter_cell: Vector2i) -> void:
	_animate_harvested_rose_to_counter(start_world, counter_cell)


func _animate_counter_rose_to_client(counter_cell: Vector2i, pile_index: int, client: Node2D) -> void:
	_counter_stock_manager.animate_counter_rose_to_client(
		counter_cell, pile_index, client, Callable(self, "_on_client_rose_arrived").bind(client))


# Called when the rose that left the counter pile reaches the buying client: only now
# does the client show the carry-rose frame (character.gd gates flow_out on this meta).
func _on_client_rose_arrived(client: Node2D) -> void:
	if client != null and is_instance_valid(client):
		client.set_meta("client_rose_visible", true)


func _rose_pile_parent() -> Node:
	if parent_for_agents != null:
		return parent_for_agents
	var scene: Node = get_tree().current_scene
	return scene if scene != null else self


func _auto_select_hammer() -> void:
	var scene: Node = get_tree().current_scene
	var game_ui: Node = scene.get_node_or_null("GameUI") if scene != null else null
	if game_ui != null and game_ui.has_method("is_build_tool_selected") and bool(game_ui.call("is_build_tool_selected")):
		return
	if game_ui != null and game_ui.has_method("select_build_tool"):
		game_ui.call("select_build_tool", "hammer")


func auto_select_hammer() -> void:
	_auto_select_hammer()


func _can_install_new_counter() -> bool:
	var scene: Node = get_tree().current_scene
	var game_ui: Node = scene.get_node_or_null("GameUI") if scene != null else null
	if game_ui == null:
		return false
	if game_ui.has_method("get_inventory_item_quantity"):
		var owned_counters: int = int(game_ui.call("get_inventory_item_quantity", ROSE_SHOP_COUNTER_ID))
		if owned_counters > 0:
			return true
	if game_ui.has_method("can_afford_merchant_item"):
		return bool(game_ui.call("can_afford_merchant_item", ROSE_SHOP_COUNTER_ID, 1))
	return false


func can_install_new_counter() -> bool:
	return _can_install_new_counter()


func _report_playlist_spawn_result(request: Dictionary, success: bool, failure_reason: String = "") -> void:
	var track_index: int = int(request.get("track_index", -1))
	_spawn_playlist_controller.mark_spawn_result(track_index, success, failure_reason)
	if not success:
		var warning_key: String = "playlist:%d" % track_index
		if _debug_telemetry.should_warn_spawn_failure_key(warning_key):
			push_warning("BuildingManager: playlist spawn failed: %s reason=%s" % [
				_spawn_playlist_controller.get_track_debug_context(track_index),
				failure_reason,
			])


func _spawn_monster_from(spawner_cell: Vector2i, monster_type: StringName = &"basic") -> bool:
	return _spawn_agent_from(spawner_cell, monster_type, SPAWNER_KIND_MONSTER)


func _spawn_client_from(spawner_cell: Vector2i) -> bool:
	return _spawn_agent_from(spawner_cell, &"basic", SPAWNER_KIND_CLIENT)


func _spawn_agent_from(spawner_cell: Vector2i, monster_type: StringName = &"basic", agent_kind: StringName = SPAWNER_KIND_MONSTER) -> bool:
	var agent_scene: PackedScene = _resolve_monster_scene(monster_type)
	if agent_scene == null:
		return false
	# Select target garden: iterates all gardens, checks targetable / edible plants,
	# and runs _nearest_garden_entry per garden. Prime suspect for select-garden lag.
	var t_sel: int = Time.get_ticks_usec()
	var garden_id: int = _select_garden_for_client_spawner(spawner_cell) if agent_kind == SPAWNER_KIND_CLIENT else _select_garden_for_spawner(spawner_cell)
	var sel_us: int = Time.get_ticks_usec() - t_sel
	if _debug_telemetry.over_garden_threshold_us(sel_us):
		_debug_telemetry.warn_garden_task_lag_us("_process_spawners.select_garden", sel_us,
			"spawner_cell=%s gardens=%d garden=%d" % [str(spawner_cell), _garden_topology.gardens().size(), garden_id])
	if garden_id <= 0:
		_debug_telemetry.log_spawn_failure("spawner %s has no reachable garden" % spawner_cell)
		return false

	# Route/cache lookup (+ entry-cell resolution). Hits are O(1); misses recompute
	# the nearest garden entry. Hit/miss counters live in the called function.
	var t_route: int = Time.get_ticks_usec()
	var route: Dictionary = _get_or_create_spawner_garden_route(spawner_cell, garden_id)
	var route_us: int = Time.get_ticks_usec() - t_route
	if _debug_telemetry.over_garden_threshold_us(route_us):
		_debug_telemetry.warn_garden_task_lag_us("_process_spawners.route_lookup", route_us,
			"spawner_cell=%s garden=%d ready=%s" % [str(spawner_cell), garden_id, str(route.get("ready", false))])
	if not bool(route.get("ready", false)):
		_debug_telemetry.log_spawn_failure("spawner %s garden %d route not ready" % [spawner_cell, garden_id])
		return false
	var entry_cell: Vector2i = route.get("entry_cell", INVALID_CELL) as Vector2i
	if entry_cell == INVALID_CELL:
		_debug_telemetry.log_spawn_failure("spawner %s garden %d has no entry cell" % [spawner_cell, garden_id])
		return false

	if not _is_sane_cell(entry_cell):
		_debug_telemetry.log_spawn_failure("spawner %s garden %d insane entry_cell %s" % [spawner_cell, garden_id, entry_cell])
		return false

	# Occupied-cell scan: walks the main_chars/monsters/player scene groups every
	# spawn. Grows with active unit count.
	var t_occ: int = Time.get_ticks_usec()
	var occupied: Array[Vector2i] = _occupied_cells()
	var occ_us: int = Time.get_ticks_usec() - t_occ
	if _debug_telemetry.over_garden_threshold_us(occ_us):
		_debug_telemetry.warn_garden_task_lag_us("_process_spawners.occupied_cells", occ_us,
			"spawner_cell=%s occupied=%d" % [str(spawner_cell), occupied.size()])

	# Free-cell search: spirals out from the spawner doing per-cell walkable/wall
	# (TileMap) lookups until a free cell is found. Can spike when the spawner is
	# boxed in.
	var t_free: int = Time.get_ticks_usec()
	var spawn_cell: Vector2i = _find_free_cell_near(spawner_cell, occupied)
	var free_us: int = Time.get_ticks_usec() - t_free
	if _debug_telemetry.over_garden_threshold_us(free_us):
		_debug_telemetry.warn_garden_task_lag_us("_process_spawners.find_free_cell", free_us,
			"spawner_cell=%s spawn_cell=%s" % [str(spawner_cell), str(spawn_cell)])
	if spawn_cell == INVALID_CELL or not _is_sane_cell(spawn_cell):
		_debug_telemetry.log_spawn_failure("spawner %s could not find a sane walkable spawn cell (got %s)" % [spawner_cell, spawn_cell])
		return false

	# Instantiate + add_child + group registration of the agent scene.
	var t_inst: int = Time.get_ticks_usec()
	var agent: Node2D = agent_scene.instantiate() as Node2D
	var parent: Node = parent_for_agents if parent_for_agents else get_tree().current_scene
	parent.add_child(agent)
	agent.global_position = _cell_center(spawn_cell)
	agent.z_index = int(agent.global_position.y)
	if agent_kind == SPAWNER_KIND_CLIENT:
		agent.add_to_group("clients")
		_register_desire_agent(agent, &"clients")
		var sprite: Sprite2D = agent.get_node_or_null("MonsterSprite2D") as Sprite2D
		if sprite != null:
			sprite.texture = CLIENT_TEXTURE
			sprite.hframes = 5
	else:
		agent.add_to_group("monsters")
		_register_desire_agent(agent, &"monsters")
		# Apply the monster bible entry (sprite + health + speed/inertia metas)
		# before the agent is registered with the native manager, which reads the
		# metas in spawn_agent.
		_apply_monster_data(agent, monster_type)
	agent.set_meta("agent_kind", agent_kind)
	var inst_us: int = Time.get_ticks_usec() - t_inst
	if _debug_telemetry.over_garden_threshold_us(inst_us):
		_debug_telemetry.warn_garden_task_lag_us("_process_spawners.instantiate_agent", inst_us,
			"spawner_cell=%s spawn_cell=%s" % [str(spawner_cell), str(spawn_cell)])

	if agent_manager and agent_manager.has_method("spawn_agent"):
		# Register the agent with the nav/agent manager (flowfield/pathfinder side).
		var t_reg: int = Time.get_ticks_usec()
		var nav_id: int = int(agent_manager.call("spawn_agent", agent, IDLE_GROUP))
		agent.set("nav_id", nav_id)
		if agent_manager.has_method("set_agent_never_rest"):
			agent_manager.call("set_agent_never_rest", nav_id, true)
		var reg_us: int = Time.get_ticks_usec() - t_reg
		if _debug_telemetry.over_garden_threshold_us(reg_us):
			_debug_telemetry.warn_garden_task_lag_us("_process_spawners.register_agent", reg_us,
				"spawner_cell=%s nav_id=%d" % [str(spawner_cell), nav_id])

		# Assign the garden-entry route: attaches the monster to the entry flow
		# group. Usually the heaviest leg when the route/flow is first created.
		var t_assign: int = Time.get_ticks_usec()
		var assigned: bool = _assign_agent_to_garden_entry_flow(agent, spawner_cell, garden_id, entry_cell)
		var assign_us: int = Time.get_ticks_usec() - t_assign
		if _debug_telemetry.over_garden_threshold_us(assign_us):
			_debug_telemetry.warn_garden_task_lag_us("_process_spawners.assign_route", assign_us,
				"spawner_cell=%s garden=%d entry=%s assigned=%s" % [
					str(spawner_cell), garden_id, str(entry_cell), str(assigned)])
		if not assigned:
			if agent_manager.has_method("unregister_agent"):
				agent_manager.call("unregister_agent", nav_id)
			var failed_group: StringName = &"clients" if agent_kind == SPAWNER_KIND_CLIENT else &"monsters"
			_unregister_desire_agent(agent)
			agent.remove_from_group(failed_group)
			agent.queue_free()
			_debug_telemetry.log_spawn_failure("spawner %s garden %d entry flow not ready" % [spawner_cell, garden_id])
			return false
		_spawn_tick_controller.increment_assigned_count()
		var kind_label: String = "client" if agent_kind == SPAWNER_KIND_CLIENT else "monster"
		_debug_telemetry.log("spawned %s nav_id=%d spawn_cell=%s entry=%s spawner=%s garden=%d" % [
			kind_label, nav_id, spawn_cell, entry_cell, spawner_cell, garden_id
		])

	return true


# Phase 1 -> 2: agent reached its assigned garden entry via flow field. Compute
# A* to a plant target inside that garden and attach that path.
func _process_astar_in_arrivals() -> void:
	_agent_navigation_phases.process_astar_in_arrivals()

func _start_astar_in(agent: Node2D, spawner_cell: Vector2i) -> void:
	_agent_navigation_phases.start_astar_in(agent, spawner_cell)

# Phase 2 -> 3: astar_in path complete. Verify plant still exists; consume it.
func _process_plant_arrivals() -> void:
	_agent_navigation_phases.process_plant_arrivals()

func _retarget_agents_for_garden_topology_change(changed_cell: Vector2i) -> void:
	_garden_retarget.retarget_agents_for_garden_topology_change(changed_cell)

# --- _astar_in_agents mutation funnel + target-plant reverse index --------------
# All inserts into / erasures from _astar_in_agents go through these two helpers so
# GardenRetargetController's target-plant reverse index stays in lock-step.
func _set_astar_in_agent(nav_id: int, data: Dictionary) -> void:
	_agent_navigation_phases.set_astar_in_agent(nav_id, data)

func _erase_astar_in_agent(nav_id: int) -> void:
	_agent_navigation_phases.erase_astar_in_agent(nav_id)

func _register_astar_in_target(nav_id: int, target_cell: Vector2i) -> void:
	_garden_retarget.register_astar_in_target(nav_id, target_cell)

func _unregister_astar_in_target(nav_id: int) -> void:
	_garden_retarget.unregister_astar_in_target(nav_id)

# NARROW retarget for content-only plant removal. Only handles agents whose A*-in
# target was the exact removed plant; it does NOT broad-retarget the garden, does
# NOT rebuild routes, and does NOT recompute entry points. _entry_path_agents is
# deliberately left alone (the garden is still alive with other plants, or it
# became empty — and the empty case is handled separately by
# _handle_garden_became_empty). The eater that just consumed the plant is already
# in _eating_agents (not _astar_in_agents), so it is never disturbed here.
func _retarget_agents_targeting_removed_plant_only(cell: Vector2i, garden_id: int) -> void:
	_garden_retarget.retarget_agents_targeting_removed_plant_only(cell, garden_id)

func _consume_plant(eater: Node2D, _spawner_cell: Vector2i, plant_cell: Vector2i) -> void:
	_agent_navigation_phases.consume_plant(eater, _spawner_cell, plant_cell)


func _start_client_payment(agent: Node2D, plant_cell: Vector2i) -> void:
	agent.set_meta("client_has_rose", true)
	# Garden plant purchase has no counter-pile flight, so the carry frame shows at once.
	agent.set_meta("client_rose_visible", true)
	_spawn_client_payment_money(agent.global_position)
	if plant_manager and plant_manager.has_method("remove_plant"):
		plant_manager.call("remove_plant", plant_cell, true)
	elif plantz:
		plantz.erase_cell(plant_cell)
		_flush_plant_layer_visuals()
	_finish_client_purchase(agent)


func _process_client_counter_arrivals() -> void:
	_agent_navigation_phases.process_client_counter_arrivals()


func _begin_client_tantrum() -> void:
	_client_tantrum.begin()


func _start_client_counter_payment(agent: Node2D, counter_cell: Vector2i) -> void:
	if _counter_stock(counter_cell) <= 0:
		var spawner_cell: Vector2i = agent.get_meta("spawner_cell") as Vector2i if agent.has_meta("spawner_cell") else INVALID_CELL
		_retarget_agent_or_escape(agent, spawner_cell)
		return
	# Index of the pile rose about to be popped (top == stock - 1); the flying rose
	# launches from exactly that pile position before the stock decrement rebuilds it.
	var pile_index: int = _counter_stock(counter_cell) - 1
	_set_counter_stock(counter_cell, _counter_stock(counter_cell) - 1)
	# Logical purchase is complete immediately (night-start gating, tantrum eligibility),
	# but the visible "carrying a rose" frame is withheld until the flown rose reaches the
	# client — _on_client_rose_arrived flips client_rose_visible on arrival.
	agent.set_meta("client_has_rose", true)
	_animate_counter_rose_to_client(counter_cell, pile_index, agent)
	_spawn_client_payment_money(agent.global_position)
	_finish_client_purchase(agent)


func _spawn_client_payment_money(world_position: Vector2) -> void:
	var scene: Node = get_tree().current_scene
	var money_icon: Node = scene.get_node_or_null("GameUI/currenciesUI/moneyIcon") if scene != null else null
	if money_icon != null and money_icon.has_method("animate_money_harvest"):
		var started: bool = bool(money_icon.call("animate_money_harvest", world_position, 0))
		if started:
			return
	var progression_node: Node = scene.get_node_or_null("progression") if scene != null else null
	if progression_node != null and progression_node.has_method("update_money"):
		progression_node.call("update_money", 1)


# A client that has taken its rose (from a counter or a garden plant) leaves the map
# immediately — there is no eating/paying delay. The money pickup and the "carrying a
# rose" look are already set up by the caller; start_escape's flow_out status drives the
# carry sprite frame. _assign_agent_to_escape detaches the current path/flow and clears
# the entry/astar/eating bookkeeping, so we only need to drop the counter-walk entry.
func _finish_client_purchase(agent: Node2D) -> void:
	_agent_navigation_phases.finish_client_purchase(agent)


# Opportunistic counter grab: a client still walking toward the garden entrance (flow-in)
# or toward a counter access tile (A*-in) that passes within EARLY_COUNTER_FETCH_TILE_FACTOR
# tiles of a stocked counter's access tile grabs its rose there and leaves — no need to
# finish the walk. Returns true when the client fetched (and is now escaping) so the caller
# skips its normal arrival handling for this agent. Cheap: monsters bail on the kind check,
# and clients only run the nearest-counter lookup while some counter actually holds stock.
func _try_client_early_counter_fetch(agent: Node2D) -> bool:
	return _agent_navigation_phases.try_client_early_counter_fetch(agent)


func nearest_live_reservoir(from_world: Vector2, use_distance: bool) -> Node2D:
	var best: Node2D = null
	var best_distance: float = INF
	for reservoir_node: Node in get_tree().get_nodes_in_group("reservoirs"):
		var reservoir: Node2D = reservoir_node as Node2D
		if reservoir == null or not is_instance_valid(reservoir) or reservoir_is_destroyed(reservoir):
			continue
		var distance: float = from_world.distance_squared_to(reservoir.global_position) if use_distance else 0.0
		if best == null or distance < best_distance:
			best = reservoir
			best_distance = distance
	return best


func _nearest_live_reservoir(from_world: Vector2, use_distance: bool) -> Node2D:
	return nearest_live_reservoir(from_world, use_distance)


func reservoir_is_destroyed(reservoir: Node) -> bool:
	return reservoir != null and reservoir.has_method("is_destroyed") and bool(reservoir.call("is_destroyed"))


func _reservoir_is_destroyed(reservoir: Node) -> bool:
	return reservoir_is_destroyed(reservoir)


func clear_client_sale_spawns() -> void:
	_client_sale.clear_spawns()


func clear_client_counter_agents() -> void:
	_agent_navigation_phases.clear_client_counter_agents()


func clear_agent_navigation_records(nav_id: int) -> void:
	_agent_navigation_phases.clear_agent_navigation_records(nav_id)


func show_damage_number(world_position: Vector2, damage: int) -> void:
	if _damage_number_drawer != null:
		_damage_number_drawer.show_damage(world_position, damage)


func tile_size() -> Vector2:
	return _tile_size()

func _suspend_agent_for_drowning(nav_id: int) -> void:
	_agent_suspend.suspend_agent_for_drowning(nav_id)

func _resume_agent_after_drowning(nav_id: int, agent: Node2D, resume_state: Dictionary) -> void:
	_agent_suspend.resume_agent_after_drowning(nav_id, agent, resume_state)

func _capture_agent_resume_state(nav_id: int, agent: Node2D) -> Dictionary:
	return _agent_suspend.capture_agent_resume_state(nav_id, agent)

func _suspend_agent_for_turret_eating(nav_id: int) -> void:
	_agent_suspend.suspend_agent_for_turret_eating(nav_id)

func _resume_agent_after_turret_eating(nav_id: int, agent: Node2D, resume_state: Dictionary) -> void:
	_agent_suspend.resume_agent_after_turret_eating(nav_id, agent, resume_state)

# A devoured turret leaves the same debris tile a consumed rose does, so the cell
# reads as "something was eaten here". plantz/blocking_buildings share one TileSet
# and transform (see mainRun.tscn), so the turret cell maps directly and its source
# id is the shared atlas source we need for the debris tile. Capture it before the
# turret is erased.
func _leave_turret_debris(turret_cell: Vector2i) -> void:
	if plantz == null or blocking_buildings == null:
		return
	# Don't stomp an existing rose/debris occupant on the plant layer.
	if plantz.get_cell_source_id(turret_cell) >= 0:
		return
	var source_id: int = blocking_buildings.get_cell_source_id(turret_cell)
	if source_id < 0:
		return
	var alternative_tile: int = blocking_buildings.get_cell_alternative_tile(turret_cell)
	plantz.set_cell(turret_cell, source_id, PlantManager.DEBRIS_ATLAS, alternative_tile)
	_flush_plant_layer_visuals()
	_sync_building_cell_speed(turret_cell, "debris")

func _destroy_pasteque_cell(pasteque_cell: Vector2i) -> void:
	if traversable_buildings == null:
		return
	var source_id: int = traversable_buildings.get_cell_source_id(pasteque_cell)
	var alternative_tile: int = traversable_buildings.get_cell_alternative_tile(pasteque_cell)
	_clear_pasteque_irrigation(pasteque_cell)
	_leave_pasteque_debris(pasteque_cell, source_id, alternative_tile)
	var building_objects: BuildingObjectManager = _get_building_object_manager()
	if building_objects != null and building_objects.has_method("remove_building"):
		building_objects.call("remove_building", pasteque_cell, true)
	elif traversable_buildings.get_cell_source_id(pasteque_cell) >= 0:
		traversable_buildings.erase_cell(pasteque_cell)
		traversable_buildings.update_internals()
	Sfx.play_sound(&"crunsh")

func _clear_pasteque_irrigation(pasteque_cell: Vector2i) -> void:
	var reservoir_system: Node = get_node_or_null("../ReservoirSystem")
	if reservoir_system == null or not reservoir_system.has_method("clear_pasteque_irrigation_from_cell"):
		return
	reservoir_system.call("clear_pasteque_irrigation_from_cell", pasteque_cell)

func _leave_pasteque_debris(pasteque_cell: Vector2i, source_id: int, alternative_tile: int) -> void:
	if plantz == null or source_id < 0:
		return
	if plantz.get_cell_source_id(pasteque_cell) >= 0:
		return
	plantz.set_cell(pasteque_cell, source_id, PlantManager.DEBRIS_ATLAS, alternative_tile)
	_flush_plant_layer_visuals()
	_sync_building_cell_speed(pasteque_cell, "debris")

func _remove_turret_cell(turret_cell: Vector2i) -> void:
	var building_objects: BuildingObjectManager = _get_building_object_manager()
	if building_objects != null and building_objects.has_method("remove_building"):
		building_objects.call("remove_building", turret_cell, true)
		return
	if blocking_buildings != null and blocking_buildings.get_cell_source_id(turret_cell) >= 0:
		blocking_buildings.erase_cell(turret_cell)
		blocking_buildings.update_internals()

func _get_building_object_manager() -> BuildingObjectManager:
	var manager: BuildingObjectManager = get_node_or_null("../BuildingObjectManager") as BuildingObjectManager
	return manager

func _is_turret_cell(cell: Vector2i) -> bool:
	if blocking_buildings == null or blocking_buildings.get_cell_source_id(cell) < 0:
		return false
	var turret_def: Dictionary = ItemCatalog.get_item_def(TURRET_ID)
	var raw_atlas: Variant = turret_def.get("atlas", Vector2i(-1, -1))
	var turret_atlas: Vector2i = raw_atlas as Vector2i
	return blocking_buildings.get_cell_atlas_coords(cell) == turret_atlas

func _flush_plant_layer_visuals() -> void:
	if not plantz:
		return
	plantz.update_internals()
	plantz.queue_redraw()

func _process_eating_agents(delta: float) -> void:
	_agent_navigation_phases.process_eating_agents(delta)

func _decide_after_eating(nav_id: int, agent: Node2D, data: Dictionary) -> void:
	_agent_navigation_phases.decide_after_eating(nav_id, agent, data)

func _escape_finished_eater(nav_id: int, agent: Node2D) -> void:
	_agent_navigation_phases.escape_finished_eater(nav_id, agent)

func _erase_eating_agent(nav_id: int) -> void:
	_agent_navigation_phases.erase_eating_agent(nav_id)

func _start_agent_eating(agent: Node2D, seconds: float, plant_cell: Vector2i = INVALID_CELL) -> void:
	_agent_navigation_phases.start_agent_eating(agent, seconds, plant_cell)

func _start_escape_for_all_monsters() -> void:
	for node in get_tree().get_nodes_in_group("monsters"):
		if node is Node2D:
			var agent: Node2D = node
			var nav_id: int = int(agent.get("nav_id"))
			if _escaping_agents.has(nav_id) or _eating_agents.has(nav_id) or _drowning_controller.is_drowning(nav_id):
				continue
			_assign_agent_to_escape(agent)

# Returns true only when an escape group/path was actually assigned (i.e.
# _attach_agent_to_escape ran). Every early return is a failure (false) so the
# budgeted queue can keep the agent in "waiting_new_status" and requeue it instead
# of stranding it with no nav state.
func _assign_agent_to_escape(agent: Node2D) -> bool:
	return _agent_navigation_phases.assign_agent_to_escape(agent)

# Returns true once the agent has been switched to the escape flow group. Only
# fails (false) if agent_manager is missing assign_agent — i.e. nav is unusable.
func _attach_agent_to_escape(agent: Node2D, escape_group: int, escape_target_cell: Vector2i, spawner_cell: Vector2i = INVALID_CELL) -> bool:
	return _agent_navigation_phases.attach_agent_to_escape(agent, escape_group, escape_target_cell, spawner_cell)

func _process_escape_arrivals() -> void:
	_agent_navigation_phases.process_escape_arrivals()


func _is_seed_merchant_paused_agent(agent: Node2D) -> bool:
	return _seed_merchant.is_paused_agent(agent)

func _remove_escaped_monster(agent: Node2D) -> void:
	var is_merchant: bool = agent.is_in_group("merchants")
	var nav_id: int = int(agent.get("nav_id"))
	if agent_manager and agent_manager.has_method("unregister_agent"):
		agent_manager.call("unregister_agent", nav_id)
	_entry_path_agents.erase(nav_id)
	if agent.has_method("stop_escape"):
		agent.call("stop_escape")
	_unregister_desire_agent(agent)
	agent.remove_from_group("clients")
	agent.remove_from_group("merchants")
	agent.remove_from_group("monsters")
	agent.queue_free()
	if is_merchant:
		_seed_merchant.on_agent_removed(agent)

func skip_current_night_for_dev() -> bool:
	if not GameState.is_night:
		return false
	_night_preparation_token += 1
	_night_preparing = false
	_night_preparation_ready = false
	_spawn_tick_controller.reset_empty_night()
	_spawn_tick_controller.clear_ready_queue()
	_spawn_tick_controller.clear_legacy_fallback()
	_current_playlist_night_index = -1
	if _spawn_playlist_controller != null:
		_spawn_playlist_controller.abort_current_night()
	for node: Node in get_tree().get_nodes_in_group(&"monsters"):
		var agent: Node2D = node as Node2D
		if agent == null or not is_instance_valid(agent):
			continue
		remove_dead_monster(agent, false)
	GameState.start_day()
	return true


# Monster death uses the same authoritative owner that created and routed monsters.
# Clear every phase/index before unregistering the native agent so no deferred
# garden work can retain or later re-route a dead nav_id.
func remove_dead_monster(agent: Node2D, spawn_corpse: bool = true) -> void:
	_monster_death.remove_dead_monster(agent, spawn_corpse)


func _clear_removed_agent_state(nav_id: int) -> void:
	_entry_path_agents.erase(nav_id)
	_erase_astar_in_agent(nav_id)
	_erase_eating_agent(nav_id)
	_drowning_controller.clear_agent(nav_id)
	_escaping_agents.erase(nav_id)
	_client_counter_agents.erase(nav_id)
	_client_tantrum.clear_hostile(nav_id)
	_garden_retarget.remove_queued_agent(nav_id)


func _unregister_nav_agent(nav_id: int) -> void:
	if agent_manager and agent_manager.has_method("unregister_agent") and nav_id >= 0:
		agent_manager.call("unregister_agent", nav_id)


func _on_removed_merchant_agent(agent: Node2D) -> void:
	_seed_merchant.on_agent_removed(agent)


func _monster_death_drop_seed_chance_percent() -> int:
	return _monster_drop_seed_chance_percent

func _nearest_spawner_cell(from_cell: Vector2i) -> Vector2i:
	var best_cell: Vector2i = INVALID_CELL
	var best_dist_sq: int = 2147483647
	for raw_spawner_cell in _spawners.keys():
		var spawner_cell: Vector2i = raw_spawner_cell
		if (_spawner_kind_by_cell.get(spawner_cell, SPAWNER_KIND_MONSTER) as StringName) != SPAWNER_KIND_MONSTER:
			continue
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
	for group_name in ["main_chars", "monsters", "clients", "merchants", "player"]:
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
	return _has_floor(cell) and not _has_wall(cell) and not _has_water(cell)

func _has_plant_cell(cell: Vector2i) -> bool:
	return plant_manager != null and plant_manager.has_method("has_plant") and bool(plant_manager.call("has_plant", cell))

func _rebuild_walkable_map_cache() -> void:
	_garden_topology.rebuild_walkable_map_cache()

func _has_floor(cell: Vector2i) -> bool:
	return floorz != null and floorz.get_cell_tile_data(cell) != null

# Fences are non-walkable for clients but not for monsters. Monster and client agents are
# phase-separated (monsters at night, clients during the day sale), and the walkable-map /
# garden geometry / A* are rebuilt from _is_walkable each phase, so a single phase check is
# the source of truth for both the flow field (see _request_group_flow_rebuild) and A*.
func _fences_block_navigation() -> bool:
	return not GameState.is_night and not _client_tantrum.is_active()

func _has_wall(cell: Vector2i) -> bool:
	if wallz != null and wallz.get_cell_tile_data(cell) != null:
		return true
	if _fences_block_navigation() and fences != null and fences.get_cell_tile_data(cell) != null:
		return true
	return _building_cell_blocks_movement(cell)

# Water tiles are impassable for all gameplay navigation and garden geometry.
# Keeping this inside _is_walkable ensures garden interiors, borders, entry/exit
# cells, client A* paths, spawner reachability, and fallback targets all reject
# water from the same source of truth.
func _has_water(cell: Vector2i) -> bool:
	return watersources != null and watersources.get_cell_source_id(cell) != -1

func _cell_center(cell: Vector2i) -> Vector2:
	return floorz.to_global(floorz.map_to_local(cell))

# ---------------------------------------------------------------------------
# Plant zone.
# ---------------------------------------------------------------------------
func _build_plant_zone() -> void:
	_garden_topology.build_plant_zone()

func _rebuild_plant_zone_from_layer() -> void:
	_garden_topology.rebuild_plant_zone_from_layer()

func _build_gardens_from_plants() -> void:
	_garden_topology.build_gardens_from_plants()

func _add_plant_to_gardens(cell: Vector2i) -> void:
	_garden_topology.add_plant_to_gardens(cell)

func _remove_plant_from_garden_content_only(cell: Vector2i) -> Dictionary:
	return _garden_topology.remove_plant_from_garden_content_only(cell)

func _erase_garden(garden_id: int, reason: String) -> void:
	_garden_topology.erase_garden(garden_id, reason)

func _is_sane_cell(cell: Vector2i) -> bool:
	if cell == INVALID_CELL:
		return false
	if abs(cell.x) > _SANE_CELL_LIMIT or abs(cell.y) > _SANE_CELL_LIMIT:
		return false
	return true
# --------------------------------------------------------------------------

func _create_garden() -> int:
	return _garden_topology.create_garden()

func _mark_garden_dirty(garden_id: int, invalidate_routes: bool) -> void:
	_garden_topology.mark_garden_dirty(garden_id, invalidate_routes)

func _validate_dirty_gardens() -> void:
	_garden_topology.validate_dirty_gardens()

func _recompute_garden_geometry(garden_id: int) -> void:
	_garden_topology.recompute_garden_geometry(garden_id)

func _recompute_spawner_reachable_cells() -> void:
	_garden_topology.recompute_spawner_reachable_cells()

func _apply_spawner_reachability(garden_id: int) -> void:
	_garden_topology.apply_spawner_reachability(garden_id)

func _rebuild_plant_zone_compatibility_cache() -> void:
	_garden_topology.rebuild_plant_zone_compatibility_cache()

func _rebuild_spawner_garden_route_cache() -> void:
	_spawner_route_service.rebuild_spawner_garden_route_cache()

func _release_garden_routes(garden_id: int) -> void:
	_spawner_route_service.release_garden_routes(garden_id)

func _get_gardens() -> Dictionary:
	return _garden_topology.gardens()

func _plant_zone_is_built() -> bool:
	return _garden_topology.plant_zone_built()

func _spawner_garden_route_count() -> int:
	return _spawner_route_service.spawner_garden_route_count()

func _garden_retarget_queue_size() -> int:
	return _garden_retarget.queue_size()

func _queue_zone_overlay_redraw() -> void:
	if _zone_overlay:
		_zone_overlay.queue_redraw()

func _release_spawner_garden_route(spawner_cell: Vector2i, garden_id: int) -> void:
	_spawner_route_service.release_spawner_garden_route(spawner_cell, garden_id)

func _garden_route_is_current(route: Dictionary, garden_id: int) -> bool:
	return _spawner_route_service.garden_route_is_current(route, garden_id)

func _select_garden_for_spawner(spawner_cell: Vector2i) -> int:
	var best_garden_id: int = 0
	var best_dist: int = 2147483647
	_garden_topology.begin_garden_iteration()
	for raw_garden_id in _garden_topology.gardens().keys():
		var garden_id: int = int(raw_garden_id)
		var garden: Dictionary = _garden_topology.gardens()[garden_id] as Dictionary
		if not bool(garden.get("targetable", false)):
			continue
		if not _garden_has_edible_plants(garden_id):
			continue
		var entry_cell: Vector2i = _nearest_garden_entry(garden_id, spawner_cell)
		if entry_cell == INVALID_CELL:
			continue
		var route: Dictionary = _get_or_create_spawner_garden_route(spawner_cell, garden_id)
		if not bool(route.get("ready", false)):
			continue
		var delta: Vector2i = entry_cell - spawner_cell
		var manhattan: int = abs(delta.x) + abs(delta.y)
		if manhattan < best_dist:
			best_dist = manhattan
			best_garden_id = garden_id
	_garden_topology.end_garden_iteration()
	_drain_pending_empty_gardens()
	# The chosen garden may have just been drained as empty; fall through to 0.
	if best_garden_id > 0 and not _garden_topology.gardens().has(best_garden_id):
		return 0
	return best_garden_id


func _select_garden_for_client_spawner(spawner_cell: Vector2i) -> int:
	var best_garden_id: int = 0
	var best_dist: int = 2147483647
	_garden_topology.begin_garden_iteration()
	for raw_garden_id: Variant in _garden_topology.gardens().keys():
		var garden_id: int = int(raw_garden_id)
		var garden: Dictionary = _garden_topology.gardens()[garden_id] as Dictionary
		if not bool(garden.get("targetable", false)):
			continue
		if not _garden_has_target_for_kind(garden_id, SPAWNER_KIND_CLIENT):
			continue
		var entry_cell: Vector2i = _nearest_garden_entry(garden_id, spawner_cell)
		if entry_cell == INVALID_CELL:
			continue
		var route: Dictionary = _get_or_create_spawner_garden_route(spawner_cell, garden_id)
		if not bool(route.get("ready", false)):
			continue
		var delta: Vector2i = entry_cell - spawner_cell
		var manhattan: int = abs(delta.x) + abs(delta.y)
		if manhattan < best_dist:
			best_dist = manhattan
			best_garden_id = garden_id
	_garden_topology.end_garden_iteration()
	if best_garden_id > 0 and not _garden_topology.gardens().has(best_garden_id):
		return 0
	return best_garden_id

func _select_spawner_garden_for_agent(from_cell: Vector2i, agent_kind: StringName = SPAWNER_KIND_MONSTER) -> Dictionary:
	var best_pair: Dictionary = {}
	var best_dist: int = 2147483647
	# Reset the per-resolve cache tallies; each _nearest_garden_entry below adds in.
	_garden_access_resolver.reset_resolve_counters()
	_garden_topology.begin_garden_iteration()
	for raw_spawner_cell in _spawners.keys():
		var spawner_cell: Vector2i = raw_spawner_cell
		if (_spawner_kind_by_cell.get(spawner_cell, SPAWNER_KIND_MONSTER) as StringName) != agent_kind:
			continue
		if not _spawner_route_service.has_spawner_route(spawner_cell):
			continue
		for raw_garden_id in _garden_topology.gardens().keys():
			var garden_id: int = int(raw_garden_id)
			var garden: Dictionary = _garden_topology.gardens()[garden_id] as Dictionary
			if not bool(garden.get("targetable", false)):
				continue
			if not _garden_has_target_for_kind(garden_id, agent_kind):
				continue
			var entry_cell: Vector2i = _nearest_garden_entry(garden_id, spawner_cell)
			_garden_access_resolver.record_resolve_result()
			if entry_cell == INVALID_CELL:
				continue
			var route: Dictionary = _get_or_create_spawner_garden_route(spawner_cell, garden_id)
			if not bool(route.get("ready", false)):
				continue
			var delta: Vector2i = entry_cell - from_cell
			var manhattan: int = abs(delta.x) + abs(delta.y)
			if manhattan < best_dist:
				best_dist = manhattan
				best_pair = {
					"spawner_cell": spawner_cell,
					"garden_id": garden_id
				}
	_garden_topology.end_garden_iteration()
	_drain_pending_empty_gardens()
	# The chosen garden may have just been drained as empty; drop the stale pair.
	if not best_pair.is_empty() and not _garden_topology.gardens().has(int(best_pair.get("garden_id", 0))):
		return {}
	return best_pair

func _select_spawner_for_garden_from_cell(garden_id: int, from_cell: Vector2i, fallback_spawner_cell: Vector2i, agent_kind: StringName = SPAWNER_KIND_MONSTER) -> Vector2i:
	var best_spawner_cell: Vector2i = INVALID_CELL
	var best_dist: int = 2147483647
	for raw_spawner_cell in _spawners.keys():
		var spawner_cell: Vector2i = raw_spawner_cell
		if (_spawner_kind_by_cell.get(spawner_cell, SPAWNER_KIND_MONSTER) as StringName) != agent_kind:
			continue
		if not _spawner_route_service.has_spawner_route(spawner_cell):
			continue
		var entry_cell: Vector2i = _nearest_garden_entry(garden_id, spawner_cell)
		if entry_cell == INVALID_CELL:
			continue
		var route: Dictionary = _get_or_create_spawner_garden_route(spawner_cell, garden_id)
		if not bool(route.get("ready", false)):
			continue
		var delta: Vector2i = entry_cell - from_cell
		var manhattan: int = abs(delta.x) + abs(delta.y)
		if manhattan < best_dist:
			best_dist = manhattan
			best_spawner_cell = spawner_cell
	if best_spawner_cell == INVALID_CELL and fallback_spawner_cell != INVALID_CELL and _spawner_route_service.has_spawner_route(fallback_spawner_cell):
		if (_spawner_kind_by_cell.get(fallback_spawner_cell, SPAWNER_KIND_MONSTER) as StringName) != agent_kind:
			return INVALID_CELL
		var fallback_route: Dictionary = _get_or_create_spawner_garden_route(fallback_spawner_cell, garden_id)
		if _nearest_garden_entry(garden_id, fallback_spawner_cell) != INVALID_CELL and bool(fallback_route.get("ready", false)):
			best_spawner_cell = fallback_spawner_cell
	return best_spawner_cell

func _assign_agent_to_garden_entry_flow(agent: Node2D, spawner_cell: Vector2i, garden_id: int, entry_cell: Vector2i) -> bool:
	return _agent_navigation_phases.assign_agent_to_garden_entry_flow(agent, spawner_cell, garden_id, entry_cell)

func _spawner_garden_route_flow_ready(route: Dictionary, spawner_cell: Vector2i) -> bool:
	return _spawner_route_service.spawner_garden_route_flow_ready(route, spawner_cell)

func _get_or_create_spawner_garden_route(spawner_cell: Vector2i, garden_id: int) -> Dictionary:
	return _spawner_route_service.get_or_create_spawner_garden_route(spawner_cell, garden_id)

# Returns true once the agent has a real new nav state (a garden entry flow, or a
# successfully assigned escape). Returns false only when neither a garden route nor
# an escape could be assigned, so the budgeted queue can requeue it. Every escape
# fallback below propagates _assign_agent_to_escape's own success/failure.
#
# GardenRetargetController owns the breakdown profiling and emits the consolidated
# "debug_garden_lag_breakdown" line when this path exceeds the debug threshold.
func _retarget_agent_or_escape(agent: Node2D, spawner_cell: Vector2i) -> bool:
	return _garden_retarget.retarget_agent_or_escape(agent, spawner_cell)

# ---------------------------------------------------------------------------
# Budgeted retargeting after a garden topology rebuild.
#
# A rebuild clears _garden_topology.gardens() and bumps the epoch, so any agent still holding a
# garden_id from before can be referencing a deleted/empty garden. Re-pathing all
# of them in the rebuild frame risks a large spike, so we split the work:
#   1. _queue_agents_after_garden_rebuild() — one-shot, cheap. Detects affected
#      agents, detaches their stale path/flow, parks them in "waiting_new_status",
#      and queues them. NO pathfinding here.
#   2. _process_garden_retarget_queue() — runs each frame, time-budgeted by
#      garden_retarget_budget_ms (with garden_retarget_budget_per_frame as a hard
#      count cap), doing the expensive re-path/escape.
# ---------------------------------------------------------------------------

func _queue_agent_for_garden_retarget(nav_id: int, agent: Node2D, intent: String, spawner_cell: Vector2i, garden_id: int) -> bool:
	return _garden_retarget.queue_agent_for_garden_retarget(nav_id, agent, intent, spawner_cell, garden_id)

# One-shot scan after a FULL garden rebuild. Cheap checks only: detect agents whose
# garden reference is now stale, enqueue each via the shared helper. The expensive
# re-path/escape is deferred to the budgeted queue. Iterates a snapshot of the
# monsters group so the helper's per-agent erases never mutate a live iteration.
func _queue_agents_after_garden_rebuild() -> void:
	_garden_retarget.queue_agents_after_garden_rebuild()

# Content-only removal emptied a garden. Queue every agent bound to it through the
# existing budgeted queue, then release the garden's routes and erase it. We must
# queue the agents FIRST (or at least before _erase_garden runs), because the
# queue helper reads the agent's phase, and because the affected-agent scan relies
# on the live phase dictionaries that still carry this garden_id. No new path/flow
# is computed here — that is the budgeted queue's job. We do NOT rebuild gardens
# and do NOT recompute entry cells.
func _handle_garden_became_empty(garden_id: int) -> void:
	_garden_retarget.handle_garden_became_empty(garden_id)

# Budgeted "everyone escape" for the no-plants-left case. One scan of the monsters
# group enqueues each valid agent (intent="escape") through the shared queue, so
# the actual escape assignment is spread across frames by the budgeted queue
# instead of being applied synchronously in a single frame.
func _queue_escape_for_all_monsters_budgeted() -> void:
	_garden_retarget.queue_escape_for_all_monsters_budgeted()


func _force_escape_for_all_monsters() -> void:
	for node: Node in get_tree().get_nodes_in_group("monsters"):
		var agent: Node2D = node as Node2D
		if agent == null or not is_instance_valid(agent):
			continue
		var nav_id: int = int(agent.get("nav_id"))
		if nav_id < 0 or _drowning_controller.is_drowning(nav_id) or _escaping_agents.has(nav_id):
			continue
		_garden_retarget.remove_queued_agent(nav_id)
		_assign_agent_to_escape(agent)

# Time-budgeted: spend at most garden_retarget_budget_ms per frame on the expensive
# A*/escape work (in _retarget_single_waiting_agent), falling back on the count cap
# garden_retarget_budget_per_frame as a hard upper bound. Because a single retarget
# can exceed the whole time budget by itself, we always do at least one *expensive*
# retarget per frame (so the queue keeps draining) and then stop once the elapsed
# time crosses the budget. Cheap skips (invalid/freed/stale agents) do NOT count
# against either budget so they can't stall the queue. Returns the number of agents
# actually retargeted (expensive work done) for debug context.
func _process_garden_retarget_queue() -> int:
	return _garden_retarget.process_queue()

func get_plant_zone_tiles() -> Array:
	return _garden_topology.plant_zone_tiles().keys()

func get_plant_zone_margin_tiles() -> Array:
	return _garden_topology.plant_zone_margin_tiles().keys()

func get_plant_zone_route_tiles() -> Array:
	var route_tiles: Dictionary = {}
	for raw_garden in _garden_topology.gardens().values():
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
		for raw_garden_id in _garden_topology.gardens().keys():
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
		for raw_garden_id in _garden_topology.gardens().keys():
			var garden_id: int = int(raw_garden_id)
			var exit_cell: Vector2i = _nearest_garden_entry_to_exit(garden_id, spawner_cell)
			if exit_cell != INVALID_CELL:
				tiles[exit_cell] = true
	return tiles.keys()

func get_unreachable_garden_cells() -> Array:
	var cells: Dictionary = {}
	for raw_garden in _garden_topology.gardens().values():
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
	for raw_garden in _garden_topology.gardens().values():
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
		var entry_cell: Vector2i = entry_data.get("entry_cell", INVALID_CELL) as Vector2i
		return _debug_path_to_cell(entry_cell)
	if _astar_in_agents.has(nav_id):
		var astar_in_data: Dictionary = _astar_in_agents[nav_id] as Dictionary
		return astar_in_data.get("path_world", PackedVector2Array()) as PackedVector2Array
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
	return _wall_blockers_for_cells(_garden_topology.plant_zone_tiles())

func _wall_blockers_for_cells(cells: Dictionary) -> PackedVector2Array:
	return _building_path_service.wall_blockers_for_cells(cells)

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
	for raw_cell in _garden_topology.plant_zone_margin_tiles().keys():
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
	return _building_path_service.find_path_on_walkable_map(from_tile, to_tile)

func _find_path_in_zone(from_tile: Vector2i, to_tile: Vector2i, garden_id: int = 0) -> PackedVector2Array:
	return _building_path_service.find_path_in_zone(from_tile, to_tile, garden_id)

# Fold one _find_path_in_zone call's timings into the per-retarget accumulator (reset
# at the start of the local plant search). Tracks totals + the single most expensive
# call so the parent breakdown can show whether the path cost is spread across many
# calls or dominated by one. Cheap; no per-call warning here.
func _accumulate_find_path_in_zone(call_start_us: int, sync_elapsed: int, find_elapsed: int, from_tile: Vector2i, to_tile: Vector2i, zone_tiles: int) -> void:
	_garden_retarget.accumulate_find_path_in_zone(call_start_us, sync_elapsed, find_elapsed, from_tile, to_tile, zone_tiles)

func _sync_pathfinder_zone_tiles(zone_tiles: Dictionary) -> void:
	_building_path_service.sync_pathfinder_zone_tiles(zone_tiles)

func _path_cells_to_world(path_cells: PackedVector2Array, nav_id: int = -1, disperse_endpoint: bool = false) -> PackedVector2Array:
	return _building_path_service.path_cells_to_world(path_cells, nav_id, disperse_endpoint)

func _tile_size() -> Vector2:
	if floorz and floorz.tile_set:
		var raw_tile_size: Vector2i = floorz.tile_set.get_tile_size()
		return Vector2(float(raw_tile_size.x), float(raw_tile_size.y))
	return Vector2(32, 32)

func _resolve_plant_target_for_agent_in_garden(from_cell: Vector2i, garden_id: int, agent_kind: StringName = SPAWNER_KIND_MONSTER) -> Vector2i:
	if not _garden_topology.gardens().has(garden_id):
		return INVALID_CELL
	var garden: Dictionary = _garden_topology.gardens()[garden_id] as Dictionary
	var plant_cells: Dictionary = garden.get("plant_cells", {}) as Dictionary
	var zone_tiles: Dictionary = garden.get("zone_tiles", {}) as Dictionary
	var best_cell: Vector2i = INVALID_CELL
	var best_dist: int = 2147483647
	for raw_cell in plant_cells.keys():
		var c: Vector2i = raw_cell
		if not zone_tiles.has(c):
			continue
		if agent_kind == SPAWNER_KIND_CLIENT:
			if not _is_client_target_cell(c):
				continue
		elif not _is_eatable_for_monster(c):
			continue
		var d: Vector2i = c - from_cell
		var manhattan: int = abs(d.x) + abs(d.y)
		if manhattan < best_dist:
			best_dist = manhattan
			best_cell = c
	return best_cell


func _agent_kind(agent: Node) -> StringName:
	if agent != null and agent.has_meta("agent_kind"):
		return StringName(str(agent.get_meta("agent_kind")))
	return SPAWNER_KIND_MONSTER


func _garden_has_target_for_kind(garden_id: int, agent_kind: StringName) -> bool:
	return _garden_topology.garden_has_target_for_kind(garden_id, agent_kind)

func _no_targets_remaining_for_kind(agent_kind: StringName) -> bool:
	if agent_kind == SPAWNER_KIND_CLIENT:
		return not _has_client_targets_remaining()
	return _no_plants_remaining()


func _has_client_targets_remaining() -> bool:
	return _garden_topology.has_client_targets_remaining()

func _garden_has_client_targets(garden_id: int) -> bool:
	return _garden_topology.garden_has_client_targets(garden_id)

func _is_client_target_cell(cell: Vector2i) -> bool:
	return _garden_topology.is_client_target_cell(cell)

func _garden_has_grownup_roses(garden_id: int) -> bool:
	return _garden_topology.garden_has_grownup_roses(garden_id)

func _is_grownup_rose_cell(cell: Vector2i) -> bool:
	return plant_manager != null and plant_manager.has_method("is_rose_grownup") and bool(plant_manager.call("is_rose_grownup", cell))

# Truth is plant_cells (cross-checked against the plant_manager), never the cached
# edible_count: that counter drifts on incremental removal and was flagging
# non-empty gardens as empty. This predicate may be called while iterating
# _garden_topology.gardens(), so it only queues stale-empty gardens; callers drain after scans.
func _garden_has_edible_plants(garden_id: int) -> bool:
	return _garden_topology.garden_has_edible_plants(garden_id)

func _drain_pending_empty_gardens() -> void:
	_garden_topology.drain_pending_empty_gardens()

func _mark_garden_empty(garden_id: int) -> void:
	_garden_topology.mark_garden_empty(garden_id)

# Garden access scoring / entry selection + resolve cache now live in
# GardenAccessResolver. These stay as thin wrappers so existing callers and other
# controllers (SpawnerRouteService, GardenRetargetController, GardenTopologyService)
# can keep using the old private method names via _manager.call(...).
func _nearest_garden_entry(garden_id: int, from_cell: Vector2i) -> Vector2i:
	return _garden_access_resolver.nearest_garden_entry(garden_id, from_cell)

func _nearest_garden_entry_to_exit(garden_id: int, spawner_cell: Vector2i) -> Vector2i:
	return _garden_access_resolver.nearest_garden_entry_to_exit(garden_id, spawner_cell)

func _clear_garden_entry_resolve_cache(reason: String = "") -> void:
	_garden_access_resolver.clear_cache(reason)

# Resolve-cache profiling accessors (read into GardenRetargetController's
# consolidated retarget profile line). The counters and cache live in the resolver.
func _garden_entry_resolve_hits() -> int:
	return _garden_access_resolver.resolve_hits()

func _garden_entry_resolve_misses() -> int:
	return _garden_access_resolver.resolve_misses()

func _garden_entry_resolve_cache_size() -> int:
	return _garden_access_resolver.cache_size()
