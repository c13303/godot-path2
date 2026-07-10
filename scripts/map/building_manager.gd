extends Node
class_name BuildingManager

# Coordinator / façade. This file is large by design (see scripts/map/ARCHITECTURE.md).
# It should contain: exported scene references, service/controller setup and wiring,
# Godot lifecycle + day/night orchestration entry points, and thin compatibility
# wrappers kept for scenes, signals, saves, and older callers.
#
# It must NOT grow new gameplay algorithms: garden topology, spawner routing, agent
# navigation phases, retargeting, spawning, counter stock, and debug/telemetry all live
# in focused services under scripts/map/. When adding behavior, extend the owning
# service and expose a thin wrapper here if a scene/signal/save needs it — do not add
# the logic to this file. Do not let this file pass 1000 lines of real logic.

signal startup_loading_progress(progress: float, label: String)
signal startup_loading_finished

const GARDEN_TOPOLOGY_SERVICE_SCRIPT: Script = preload("res://scripts/map/garden_topology_service.gd")
const GARDEN_ACCESS_RESOLVER_SCRIPT: Script = preload("res://scripts/map/garden_access_resolver.gd")
const AGENT_NAVIGATION_PHASE_CONTROLLER_SCRIPT: Script = preload("res://scripts/map/agent_navigation_phase_controller.gd")
const BUILDING_PREPARATION_CONTROLLER_SCRIPT: Script = preload("res://scripts/map/building_preparation_controller.gd")
const AGENT_SPAWN_SERVICE_SCRIPT: Script = preload("res://scripts/map/agent_spawn_service.gd")
const AGENT_SAVE_SERVICE_SCRIPT: Script = preload("res://scripts/map/agent_save_service.gd")
const BUILDING_RUNTIME_TICK_CONTROLLER_SCRIPT: Script = preload("res://scripts/map/building_runtime_tick_controller.gd")
const SHEEP_CONTROLLER_SCRIPT: Script = preload("res://scripts/map/sheep_controller.gd")
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
var _flow_ready: bool = false
var _startup_loading_started: bool = false
var _startup_ready: bool = false
var _night_preparing: bool = false
var _night_preparation_ready: bool = false
var _night_preparation_token: int = 0
var _suppress_next_restored_mode_signal: bool = false
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
var _spawn_playlist_controller: SpawnPlaylistController = SpawnPlaylistController.new()
var _spawn_tick_controller: SpawnTickController = SpawnTickController.new()
# Owns level spawn-playlist config + spawner-binding validation state (playlist,
# bindings, scene path, seed-drop chance, enabled/invalid/validated flags, current
# playlist night index). See SpawnPlaylistConfigService.
var _spawn_playlist_config: SpawnPlaylistConfigService = SpawnPlaylistConfigService.new()
var _client_counter_agents: Dictionary = _agent_navigation_phases.client_counter_agents()  # nav_id -> Dictionary
var _damage_number_drawer: DamageNumberDrawer
var _seed_merchant: SeedMerchantController = SeedMerchantController.new()
var _morning_harvest: MorningHarvestController = MorningHarvestController.new()
var _client_tantrum: ClientTantrumController = ClientTantrumController.new()
var _client_sale: ClientSaleController = ClientSaleController.new()
# Owns run-length + victory decisioning (finite runs, final client day, win latch).
# See RunCompletionController.
var _run_completion: RunCompletionController = RunCompletionController.new()
var _drowning_controller: DrowningController = DrowningController.new()
var _turret_eating_controller: TurretEatingController = TurretEatingController.new()
# Detects agent cell transitions and dispatches tile-based interactions (drowning,
# turret eating, rose/pasteque trampling) only on entry, replacing four per-frame
# full-agent scans. Registration is embedded in _register_desire_agent (see below).
var _agent_cell_tracker: AgentCellTracker = AgentCellTracker.new()
var _agent_suspend: AgentSuspendService = AgentSuspendService.new()
var _building_scan: BuildingScanService = BuildingScanService.new()
var _spawner_route_service: SpawnerRouteService = SpawnerRouteService.new()
var _building_path_service: BuildingPathService = BuildingPathService.new()
var _garden_access_resolver: GardenAccessResolver = GardenAccessResolver.new()
var _debug_telemetry: BuildingDebugTelemetry = BuildingDebugTelemetry.new()
var _debug_query_service: BuildingDebugQueryService = BuildingDebugQueryService.new()
var _monster_death: MonsterDeathController = MonsterDeathController.new()
var _agent_definition_service: AgentDefinitionService = AgentDefinitionService.new()
var _sheep_controller: SheepController = SHEEP_CONTROLLER_SCRIPT.new()
var _building_invalidation_controller: BuildingInvalidationController = BuildingInvalidationController.new()
var _building_navigation_sync: BuildingNavigationSyncService = BuildingNavigationSyncService.new()
var _spawner_garden_selection_service: SpawnerGardenSelectionService = SpawnerGardenSelectionService.new()
var _building_preparation_controller: Variant = BUILDING_PREPARATION_CONTROLLER_SCRIPT.new()
var _agent_spawn_service: Variant = AGENT_SPAWN_SERVICE_SCRIPT.new()
var _agent_save_service: AgentSaveService = AGENT_SAVE_SERVICE_SCRIPT.new()
var _runtime_tick_controller: Variant = BUILDING_RUNTIME_TICK_CONTROLLER_SCRIPT.new()
var _counter_stock_manager: CounterStockManager
var _zone_overlay: Node2D
var _desire: Node

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
	_run_completion.setup(self)
	_drowning_controller.setup(self)
	_turret_eating_controller.setup(self)
	_agent_cell_tracker.setup(self)
	_agent_suspend.setup(self)
	_building_scan.setup(self)
	_spawner_route_service.setup(self)
	_building_path_service.setup(self)
	_garden_access_resolver.setup(self)
	_garden_retarget.setup(self)
	_spawn_tick_controller.setup(self)
	_debug_telemetry.setup(self)
	_debug_query_service.setup(self)
	_monster_death.setup(self)
	_agent_definition_service.setup(self)
	_sheep_controller.setup(self)
	_building_invalidation_controller.setup(self)
	_building_navigation_sync.setup(self)
	_spawner_garden_selection_service.setup(self)
	_building_preparation_controller.setup(self)
	_agent_spawn_service.setup(self)
	_agent_save_service.setup(self)
	_spawn_playlist_config.setup(self)
	_runtime_tick_controller.setup(self)
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
	_setup_construction_overlay()
	_wait_for_flow_ready()
	GameState.mode_changed.connect(_on_game_mode_changed)
	_damage_number_drawer = DamageNumberDrawer.new()
	add_child(_damage_number_drawer)
	set_process_input(true)


func _load_level_spawn_config() -> void:
	_spawn_playlist_config.load_level_spawn_config()

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


# Authoritative Godot-side agent registration choke for monsters/clients/merchants:
# every spawn (agent_spawn_service, agent_save_service) and removal path routes
# through here, so besides the desire ground-marker it also (un)registers the agent
# with the cell tracker. Sheep don't use desire; they register via the public
# register_tracked_agent below.
func _register_desire_agent(agent: Node2D, group_name: StringName) -> void:
	if _desire != null and _desire.has_method("register_agent"):
		_desire.call("register_agent", agent, group_name)
	_agent_cell_tracker.register(agent, group_name)


func _unregister_desire_agent(agent: Node2D) -> void:
	if _desire != null and _desire.has_method("unregister_agent"):
		_desire.call("unregister_agent", agent)
	_agent_cell_tracker.unregister(agent)


# Cell-tracker registration for agents that do not go through the desire system
# (sheep). Kept separate so the desire wrapper's contract stays unchanged.
func register_tracked_agent(agent: Node2D, category: StringName) -> void:
	_agent_cell_tracker.register(agent, category)


func unregister_tracked_agent(agent: Node2D) -> void:
	_agent_cell_tracker.unregister(agent)

func _on_game_mode_changed(is_night: bool) -> void:
	if _suppress_next_restored_mode_signal:
		_suppress_next_restored_mode_signal = false
		return
	_spawn_tick_controller.reset_empty_night()
	_client_preparing = false
	if is_night:
		_day_start_pending = false
		_sheep_controller.on_game_mode_changed(true)
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
		_sheep_controller.on_game_mode_changed(false)
		_day_start_pending = true
		_night_preparation_token += 1
		_night_preparing = false
		_night_preparation_ready = false
		_spawn_tick_controller.clear_legacy_fallback()
		_clear_waterpool_directional_field()
		return
	# Night visuals/build lock become active immediately, but spawning remains gated
	# while all daytime topology is consumed by the capped preparation coroutine.
	if not _spawn_playlist_config.playlist_validation_attempted():
		_scan_buildings()
		_validate_playlist_after_spawner_scan()
	_spawn_playlist_config.set_current_playlist_night_index(
		_spawn_playlist_config.get_playlist_night_index_from_progression()
	)
	var night_index: int = _spawn_playlist_config.current_playlist_night_index()
	if _spawn_playlist_config.playlist_spawning_enabled():
		if not _spawn_playlist_controller.begin_night(night_index):
			push_error("BuildingManager: playlist night index %d is invalid; using legacy fallback spawning this night." % (night_index + 1))
			_spawn_playlist_config.set_playlist_spawning_enabled(false)
			_spawn_playlist_config.set_playlist_spawning_invalid(true)
		else:
			CppDebugOptions.dlog("BuildingManager: playlist night started: playable_night=%d total=%d" % [
				night_index + 1,
				_spawn_playlist_controller.get_total_night_count(),
			])
			for line: String in _spawn_playlist_controller.get_current_night_debug_lines():
				CppDebugOptions.dlog("BuildingManager: playlist " + line)
	if _spawn_playlist_config.playlist_spawning_enabled():
		_spawn_tick_controller.clear_legacy_fallback()
	else:
		_spawn_tick_controller.begin_legacy_fallback_night()
	if _spawn_playlist_config.playlist_spawning_invalid():
		push_error("BuildingManager: assigned spawn playlist is invalid; using legacy fallback spawning this night.")
	elif not _spawn_playlist_config.playlist_spawning_enabled():
		push_error("BuildingManager: no valid spawn playlist is enabled; using legacy fallback spawning this night.")
	_spawn_tick_controller.clear_ready_queue()
	_night_preparation_token += 1
	_night_preparing = true
	_night_preparation_ready = false
	call_deferred("_run_night_preparation", _night_preparation_token)


func _get_playlist_night_index_from_progression() -> int:
	return _spawn_playlist_config.get_playlist_night_index_from_progression()

func get_playlist_night_index_from_progression() -> int:
	return _get_playlist_night_index_from_progression()

func _get_progression() -> Node:
	if _progression != null and is_instance_valid(_progression):
		return _progression
	var scene: Node = get_tree().current_scene
	if scene != null:
		_progression = scene.get_node_or_null("progression")
	return _progression

func get_progression() -> Node:
	return _get_progression()


func auto_save_after_rose_harvest() -> bool:
	var progression_node: Node = _get_progression()
	if progression_node == null or not progression_node.has_method("auto_save"):
		CppDebugOptions.save_log("[SAVE] BuildingManager: rose-harvest auto-save blocked: progression node missing")
		return false
	return bool(progression_node.call("auto_save"))


func get_plant_manager() -> Node:
	return plant_manager

func _plant_manager_can_check_plants() -> bool:
	return plant_manager != null and plant_manager.has_method("has_plant")

func _plant_manager_consume_plant_cell(plant_cell: Vector2i) -> bool:
	if plant_manager == null or not plant_manager.has_method("consume_plant"):
		return false
	plant_manager.call("consume_plant", plant_cell)
	return true

func get_flow() -> Node:
	return flow

func get_agent_manager() -> Node:
	return agent_manager


func get_building_object_manager() -> BuildingObjectManager:
	return _get_building_object_manager()


func _agent_manager_can_assign_agent() -> bool:
	return agent_manager != null and agent_manager.has_method("assign_agent")

func _agent_manager_detach_agent_flow(nav_id: int) -> void:
	if agent_manager != null and agent_manager.has_method("detach_agent_flow"):
		agent_manager.call("detach_agent_flow", nav_id)

func _agent_manager_detach_agent_path(nav_id: int) -> void:
	if agent_manager != null and agent_manager.has_method("detach_agent_path"):
		agent_manager.call("detach_agent_path", nav_id)

func _agent_manager_assign_agent(agent: Node2D, group_id: int) -> void:
	if agent_manager != null and agent_manager.has_method("assign_agent"):
		agent_manager.call("assign_agent", agent, group_id)

func _agent_manager_assign_agent_path(nav_id: int, path_world: PackedVector2Array) -> void:
	if agent_manager != null and agent_manager.has_method("assign_agent_path"):
		agent_manager.call("assign_agent_path", nav_id, path_world)

func _agent_manager_agent_path_arrived(nav_id: int) -> bool:
	if agent_manager == null or not agent_manager.has_method("agent_path_arrived"):
		return false
	return bool(agent_manager.call("agent_path_arrived", nav_id))

func _agent_manager_set_agent_never_rest(nav_id: int, value: bool) -> void:
	if agent_manager != null and agent_manager.has_method("set_agent_never_rest"):
		agent_manager.call("set_agent_never_rest", nav_id, value)

func can_assign_agent_navigation() -> bool:
	return _agent_manager_can_assign_agent()

func detach_agent_flow(nav_id: int) -> void:
	_agent_manager_detach_agent_flow(nav_id)

func detach_agent_path(nav_id: int) -> void:
	_agent_manager_detach_agent_path(nav_id)

func assign_agent_to_group(agent: Node2D, group_id: int) -> void:
	_agent_manager_assign_agent(agent, group_id)

func assign_agent_path(nav_id: int, path_world: PackedVector2Array) -> void:
	_agent_manager_assign_agent_path(nav_id, path_world)

func agent_path_arrived(nav_id: int) -> bool:
	return _agent_manager_agent_path_arrived(nav_id)

func set_agent_never_rest(nav_id: int, value: bool) -> void:
	_agent_manager_set_agent_never_rest(nav_id, value)

# Lazy flow fields: stamp the group whose flow field this spawn-waiting agent depends on,
# so native freezes it and shows "ff wait"/"ff being computed". Pass 0 to clear. Guarded so
# older exported DLLs without the method simply keep the previous (moving) behavior.
func set_agent_waiting_flow_group(nav_id: int, group_id: int) -> void:
	if agent_manager != null and agent_manager.has_method("set_agent_waiting_flow_group"):
		agent_manager.call("set_agent_waiting_flow_group", nav_id, group_id)

func registered_spawner_count() -> int:
	return _spawners.size()

func get_parent_for_agents() -> Node:
	return parent_for_agents

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
	# The runtime walkability rebuild (wall built mid-day/mid-night) reuses the
	# budgeted preparation passes outside night/client preparation; while it is
	# active its token is valid regardless of the game phase.
	if _building_invalidation_controller != null and _building_invalidation_controller.runtime_rebuild_active():
		return true
	return GameState.is_night or (_client_preparing and not GameState.is_night)

func _night_preparation_budget_us() -> int:
	return maxi(500, int(night_preparation_budget_ms * 1000.0))

# Claims a fresh preparation token, invalidating any in-flight budgeted pass
# (night/client preparation or runtime walkability rebuild) at its next slice.
func advance_preparation_token() -> int:
	_night_preparation_token += 1
	return _night_preparation_token

func _flow_uses_async_requests() -> bool:
	return _spawner_route_service.flow_uses_async_requests()

func _flow_supports_sync_assign() -> bool:
	return _spawner_route_service.flow_supports_sync_assign()

func _group_flow_id_is_ready(group_id: int) -> bool:
	return _spawner_route_service.group_flow_id_is_ready(group_id)

func _group_flow_is_ready_at_world(group_id: int, world_pos: Vector2) -> bool:
	return _spawner_route_service.group_flow_is_ready_at_world(group_id, world_pos)

func _run_night_preparation(token: int) -> void:
	await _building_preparation_controller.run_night_preparation(token)


func _run_client_preparation(token: int) -> void:
	await _building_preparation_controller.run_client_preparation(token)


func _abort_client_preparation(token: int) -> void:
	if token != _night_preparation_token:
		return
	if GameState.is_night:
		return
	_client_preparing = false
	_client_sale.reset()
	GameState.set_building_phase(true)


# Preparation-success transitions. The manager owns these flags and the
# tightly-coupled follow-up service call; the preparation controller requests
# the transition instead of mutating the flags directly.
func finish_night_preparation_success() -> void:
	_night_preparing = false
	_night_preparation_ready = true
	_seed_merchant.start_pending_leave_if_needed()


func finish_client_preparation_success() -> void:
	_client_preparing = false
	_client_sale.activate()

func _initialize_spawner_routes_for_kinds(agent_kinds: Array[StringName], token: int) -> bool:
	return bool(await _spawner_route_service.initialize_spawner_routes_for_kinds(agent_kinds, token))

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

var _construction_overlay: BuildingConstructionOverlay = null

func _setup_construction_overlay() -> void:
	_construction_overlay = BuildingConstructionOverlay.new()
	_construction_overlay.name = "BuildingConstructionOverlay"
	_construction_overlay.building_manager = self
	var overlay_parent: Node = floorz.get_parent() if floorz and floorz.get_parent() else self
	overlay_parent.add_child(_construction_overlay)

# Called by BuildSystem when a navigation-blocking placeable (wall/fence/blocking
# building) is placed or removed. With agents active, navigation catches up over
# several budgeted frames: the cell is shown as under construction until then.
func notify_blocking_placeable_placed(cell: Vector2i) -> void:
	if _construction_overlay != null and _runtime_agents_active():
		_construction_overlay.track_cell(cell)

func notify_blocking_placeable_removed(cell: Vector2i) -> void:
	if _construction_overlay != null:
		_construction_overlay.untrack_cell(cell)

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
	if _runtime_tick_controller == null:
		return
	_runtime_tick_controller.process(delta)

func _load_tile_definitions() -> void:
	_building_scan.load_tile_definitions()

func _scan_buildings() -> void:
	_building_scan.scan_buildings()

func _apply_navigation_topology_rebuild() -> void:
	_building_invalidation_controller.apply_navigation_topology_rebuild()

func _sync_flow_extra_blocking_cells() -> void:
	_building_navigation_sync.sync_flow_extra_blocking_cells()

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
	_spawn_playlist_config.validate_after_spawner_scan()


func _valid_monster_types() -> Dictionary:
	return _spawn_playlist_config.valid_monster_types()


# Compatibility wrappers: agent definition resolution and visual/stat setup now live
# in AgentDefinitionService. Other code may still reach these via _manager.call(...).
func _resolve_monster_scene(monster_type: StringName) -> PackedScene:
	return _agent_definition_service.resolve_monster_scene(monster_type)


func _apply_monster_data(agent: Node, monster_type: StringName) -> void:
	_agent_definition_service.apply_monster_data(agent, monster_type)


func _apply_client_data(agent: Node) -> void:
	_agent_definition_service.apply_client_data(agent)


func apply_merchant_data(agent: Node) -> void:
	_agent_definition_service.apply_merchant_data(agent)


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
	_counter_stock_manager.setup(self)
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
	var impact: PlaceableNavImpact.Impact = _building_item_nav_impact(item_id)
	var fences_block: bool = _fences_block_navigation()
	if PlaceableNavImpact.requires_hard_topology(impact, fences_block):
		_building_invalidation_controller.mark_after_blocking_building_added()
		_log_nav_invalidation("building_added:%s" % item_id, cell)
	elif PlaceableNavImpact.is_speed_only(impact, fences_block):
		_log_nav_speed("building_added:%s" % item_id, cell)
	# A turret or pasteque just appeared: re-check any agent already standing on the
	# cell so a stationary agent still triggers the interaction (removal makes a cell
	# non-interactive, so no invalidation is needed there).
	if item_id == TURRET_ID or item_id == PASTEQUE_ITEM_ID:
		_agent_cell_tracker.invalidate_cell(cell)
	if item_id != ROSE_SHOP_COUNTER_ID:
		return


func _on_building_removed(cell: Vector2i, item_id: String) -> void:
	if _building_item_blocks_player(item_id):
		_set_player_cell_blocked(cell, false)
	_sync_building_cell_speed(cell, item_id)
	var impact: PlaceableNavImpact.Impact = _building_item_nav_impact(item_id)
	var fences_block: bool = _fences_block_navigation()
	if PlaceableNavImpact.requires_hard_topology(impact, fences_block):
		_building_invalidation_controller.mark_after_blocking_building_removed()
		notify_blocking_placeable_removed(cell)
		_log_nav_invalidation("building_removed:%s" % item_id, cell)
	elif PlaceableNavImpact.is_speed_only(impact, fences_block):
		_log_nav_speed("building_removed:%s" % item_id, cell)
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


# Authoritative navigation impact for a building item. Turrets and other speed-only items
# classify as SPEED_ONLY (slowdown applied live, no rebuild); fences resolve by the current
# phase at the call site via requires_hard_topology / is_speed_only.
func _building_item_nav_impact(item_id: String) -> PlaceableNavImpact.Impact:
	var item_def: Dictionary = ItemCatalog.get_item_def(item_id)
	var impact: PlaceableNavImpact.Impact = PlaceableNavImpact.classify_item(item_def)
	PlaceableNavImpact.debug_assert_not_hard(item_id, impact)
	return impact


func _log_nav_invalidation(source: String, cell: Vector2i) -> void:
	CppDebugOptions.dlog("[NAV_INVALIDATION] impact=HARD_TOPOLOGY source=%s cell=%s" % [source, str(cell)])


func _log_nav_speed(source: String, cell: Vector2i) -> void:
	CppDebugOptions.dlog("[NAV_SPEED] source=%s cell=%s new=%.2f" % [source, str(cell), _effective_cell_speed_multiplier(cell)])

func _building_item_blocks_player(item_id: String) -> bool:
	return _building_navigation_sync.building_item_blocks_player(item_id)

func _sync_player_blocking_cells() -> void:
	_building_navigation_sync.sync_player_blocking_cells()

func _set_player_cell_blocked(cell: Vector2i, blocked: bool) -> void:
	_building_navigation_sync.set_player_cell_blocked(cell, blocked)

func _blocking_building_item_id_at_cell(cell: Vector2i) -> String:
	return _building_navigation_sync.blocking_building_item_id_at_cell(cell)

func _sync_building_cell_speed(cell: Vector2i, item_id: String) -> void:
	_building_navigation_sync.sync_building_cell_speed(cell, item_id)

func _effective_cell_speed_multiplier(cell: Vector2i) -> float:
	return _building_navigation_sync.effective_cell_speed_multiplier(cell)

func refresh_runtime_cell_speed(cell: Vector2i) -> void:
	_building_navigation_sync.refresh_cell_speed(cell)

func _on_plant_added(_cell: Vector2i) -> void:
	# A rose just appeared: re-check any client/merchant already standing on the cell
	# so a stationary agent still tramples it (agent-movement alone would miss this).
	_agent_cell_tracker.invalidate_cell(_cell)
	if not GameState.is_night:
		# Day/client placement only dirties the next prepared snapshot. Freshly planted
		# roses are not valid client targets, so client sale must not rebuild every
		# existing garden per rose during rectangle placement.
		_building_invalidation_controller.after_plant_layout_changed("plant_added")
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
		_building_invalidation_controller.after_plant_layout_changed("plant_removed")
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


# Clients and merchants crush any plant they walk over, leaving debris behind.
# Monsters reach plants through the garden targeting/eating system; this covers the
# shop-bound creatures that cross the garden without ever targeting a plant. The
# player is exempt (it harvests roses instead). consume_plant() swaps to debris and
# fires plant_removed, so any monster targeting that cell retargets synchronously.
# Called per-agent by AgentTileInteractionController when the agent enters a new cell
# (was a per-frame full-agent scan over clients/merchants).
func trample_rose_at_agent(agent: Node2D) -> void:
	if plant_manager == null or floorz == null:
		return
	if not is_instance_valid(agent):
		return
	if not plant_manager.has_method("has_plant") or not plant_manager.has_method("consume_plant"):
		return
	var cell: Vector2i = floorz.local_to_map(floorz.to_local(agent.global_position))
	if bool(plant_manager.call("has_plant", cell)):
		plant_manager.call("consume_plant", cell)


# Called per-agent by AgentTileInteractionController when the agent enters a new cell
# (was a per-frame full-agent scan over monsters/clients).
func trample_pasteque_at_agent(agent: Node2D) -> void:
	if traversable_buildings == null or not is_instance_valid(agent):
		return
	var pasteque_def: Dictionary = ItemCatalog.get_item_def(PASTEQUE_ITEM_ID)
	if not bool(pasteque_def.get("destroyed_by_creatures", false)):
		return
	var building_objects: BuildingObjectManager = _get_building_object_manager()
	if building_objects == null or not building_objects.has_method("get_building"):
		return
	var cell: Vector2i = traversable_buildings.local_to_map(traversable_buildings.to_local(agent.global_position))
	var building_data: Dictionary = building_objects.call("get_building", cell) as Dictionary
	if str(building_data.get("item_id", "")) == PASTEQUE_ITEM_ID:
		_destroy_pasteque_cell(cell)


func has_grownup_roses_to_harvest() -> bool:
	return _morning_harvest.has_grownup_roses_to_harvest()


func restore_day_phase(phase: String) -> void:
	if phase == "night":
		_morning_harvest.clear_active()
		_reset_client_sale_state()
		_night_preparing = false
		_client_preparing = false
		_night_preparation_ready = true
		return
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
		on_client_sale_skipped()
		return
	_night_preparation_token += 1
	_client_preparing = true
	_night_preparation_ready = false
	call_deferred("_run_client_preparation", _night_preparation_token)


# Run-length + victory seam. The decisioning lives in RunCompletionController; these
# stay as thin delegates because progression.gd, tutorial.gd and the sibling day-phase
# controllers reach them through the manager's public API.
func total_run_days() -> int:
	return _run_completion.total_run_days()


func start_night_after_clients() -> void:
	_run_completion.start_night_after_clients()


func on_client_sale_skipped() -> void:
	_run_completion.on_client_sale_skipped()


func try_finish_final_day() -> bool:
	return _run_completion.try_finish_final_day()


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


# True during the day when no client is present, preparing to spawn, or throwing a
# tantrum — i.e. the present day's clients are gone (or have not arrived yet). The
# planificator preview polls this so it shows at day start and after the sale, but
# hides while clients are on the map.
func day_clients_gone() -> bool:
	return not _client_preparing and _client_sale.clients_finished_for_day()


func is_runtime_ready_for_building_tick() -> bool:
	return _flow_ready and _startup_ready


func should_skip_building_runtime_tick() -> bool:
	if _paused:
		return true
	# The runtime walkability rebuild pauses decision ticks exactly like night
	# preparation does: native steering keeps agents moving on their current flow
	# fields while gardens/routes are rebuilt over several budgeted frames.
	if _building_invalidation_controller != null and _building_invalidation_controller.runtime_rebuild_active():
		return true
	return _night_preparing or _client_preparing


func get_client_tantrum_controller() -> ClientTantrumController:
	return _client_tantrum


func get_client_sale_controller() -> ClientSaleController:
	return _client_sale


func get_seed_merchant_controller() -> SeedMerchantController:
	return _seed_merchant


func get_sheep_controller() -> SheepController:
	return _sheep_controller


func get_morning_harvest_controller() -> MorningHarvestController:
	return _morning_harvest


func get_drowning_controller() -> DrowningController:
	return _drowning_controller


func get_turret_eating_controller() -> TurretEatingController:
	return _turret_eating_controller


func get_agent_cell_tracker() -> AgentCellTracker:
	return _agent_cell_tracker


func get_spawn_tick_controller() -> SpawnTickController:
	return _spawn_tick_controller


func get_spawn_playlist_controller() -> SpawnPlaylistController:
	return _spawn_playlist_controller


func get_counter_stock_manager() -> CounterStockManager:
	return _counter_stock_manager


func get_spawn_playlist_config() -> SpawnPlaylistConfigService:
	return _spawn_playlist_config


func get_building_invalidation_controller() -> BuildingInvalidationController:
	return _building_invalidation_controller


func get_building_scan_service() -> BuildingScanService:
	return _building_scan


func get_building_object_manager() -> BuildingObjectManager:
	return _get_building_object_manager()


func get_agent_navigation_phase_controller() -> AgentNavigationPhaseController:
	return _agent_navigation_phases as AgentNavigationPhaseController


func get_garden_retarget_controller() -> GardenRetargetController:
	return _garden_retarget


func get_building_debug_telemetry() -> BuildingDebugTelemetry:
	return _debug_telemetry


func last_spawn_failure() -> String:
	return _debug_telemetry.last_spawn_failure()


func get_spawner_route_service() -> SpawnerRouteService:
	return _spawner_route_service


func get_building_path_service() -> BuildingPathService:
	return _building_path_service


func get_garden_topology_service() -> GardenTopologyService:
	return _garden_topology


func get_garden_access_resolver() -> GardenAccessResolver:
	return _garden_access_resolver


func debug_logs_enabled() -> bool:
	return debug_logs


func get_spawners() -> Dictionary:
	return _spawners


func spawner_kind_by_cell() -> Dictionary:
	return _spawner_kind_by_cell


func client_counter_agents() -> Dictionary:
	return _client_counter_agents


func eating_agent_count() -> int:
	return _eating_agents.size()


func astar_in_agent_count() -> int:
	return _astar_in_agents.size()


func escaping_agent_count() -> int:
	return _escaping_agents.size()


func entry_path_agent_count() -> int:
	return _entry_path_agents.size()


func garden_retarget_queue_size() -> int:
	return _garden_retarget.queue_size()


func client_spawners() -> Dictionary:
	return _client_spawners


func client_frequency_by_cell() -> Dictionary:
	return _client_frequency_by_cell


func is_night_preparation_ready() -> bool:
	return _night_preparation_ready


func serialize_runtime_agents_for_save() -> Dictionary:
	return _agent_save_service.serialize_state()


func restore_runtime_agents_from_save(data: Dictionary) -> void:
	_night_preparing = false
	_client_preparing = false
	if GameState.is_night:
		_night_preparation_token += 1
		_night_preparing = true
		_night_preparation_ready = false
		await _run_night_preparation(_night_preparation_token)
		_agent_save_service.restore_state(data, true)
		_notify_restored_phase()
		return
	if GameState.is_client_phase:
		_night_preparation_token += 1
		_client_preparing = true
		_night_preparation_ready = false
		await _run_client_preparation(_night_preparation_token)
		_agent_save_service.restore_state(data, true)
		_purge_day_phase_monsters_after_load()
		_notify_restored_phase()
		return
	_night_preparation_ready = bool(data.get("night_preparation_ready", true))
	_agent_save_service.restore_state(data, false)
	_purge_day_phase_monsters_after_load()
	_notify_restored_phase()


# Save/load safety net: monsters only exist at night, so any monster present after a
# day-phase restore is a corrupted/stale save. Log the error the design calls for and
# despawn it cleanly instead of letting a phantom monster roam a peaceful day.
func _purge_day_phase_monsters_after_load() -> void:
	if GameState.is_night:
		return
	var removed: int = _agent_save_service.purge_day_phase_monsters()
	if removed > 0:
		push_error("[LOAD GAME ERROR] Monster when its day.")
		CppDebugOptions.save_log("[SAVE] Progression: removed %d day-phase monster(s) on load" % removed)


func _notify_restored_phase() -> void:
	_suppress_next_restored_mode_signal = true
	GameState.emit_restored_phase_signals()


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
	return _counter_stock_manager.rose_shop_counter_cells()


func _rose_shop_counter_cells_with_room() -> Array[Vector2i]:
	return _counter_stock_manager.rose_shop_counter_cells_with_room()


func rose_shop_counter_count() -> int:
	return _counter_stock_manager.rose_shop_counter_count()


func has_counter_room_for_harvest() -> bool:
	return _counter_stock_manager.has_counter_room_for_harvest()


func rose_shop_counter_cells_with_room() -> Array[Vector2i]:
	return _counter_stock_manager.rose_shop_counter_cells_with_room()


func counter_room_for_harvest() -> int:
	return _counter_stock_manager.counter_room_for_harvest()


func _total_counter_stock() -> int:
	return _counter_stock_manager.total_stock()


## Public accessor: total number of harvested roses waiting on shop counters.
func total_counter_stock() -> int:
	return _total_counter_stock()


func serialize_counter_stock() -> Array[Dictionary]:
	return _counter_stock_manager.serialize_counter_stock()


func restore_counter_stock(saved_stock: Array) -> void:
	_counter_stock_manager.restore_counter_stock(saved_stock)


func _counter_stock(counter_cell: Vector2i) -> int:
	return _counter_stock_manager.stock(counter_cell)


func _add_counter_stock(counter_cell: Vector2i, amount: int) -> void:
	_counter_stock_manager.add_counter_stock(counter_cell, amount)


func add_counter_stock(counter_cell: Vector2i, amount: int) -> void:
	_add_counter_stock(counter_cell, amount)


func _set_counter_stock(counter_cell: Vector2i, amount: int) -> void:
	_counter_stock_manager.set_counter_stock(counter_cell, amount)


func _after_counter_stock_changed(previous: int, value: int) -> void:
	notify_counter_stock_changed(previous, value)


func notify_counter_stock_changed(previous: int, value: int) -> void:
	# A counter gaining its first rose turns it into an edible garden, which requires
	# folding its access tiles into the garden topology (a full rebuild). Depletion
	# (positive -> 0) needs no rebuild: the access tiles simply stop being edible and
	# the empty-garden machinery removes a counter-only garden like any other.
	if previous == 0 and value > 0 and _garden_topology.plant_zone_built():
		_rebuild_plant_zone_from_layer()
	elif previous > 0 and value == 0 and _no_plants_remaining():
		_force_escape_for_all_monsters()


func mark_counter_stock_restored_for_navigation() -> void:
	_building_invalidation_controller.mark_after_counter_stock_restored()


func counter_cell_for_access_cell(access_cell: Vector2i) -> Vector2i:
	return _garden_topology.counter_access_cells()[access_cell] as Vector2i


func start_agent_eating_counter_rose(agent: Node2D, access_cell: Vector2i) -> void:
	_start_agent_eating(agent, _eating_time, access_cell)


func queue_plant_zone_overlay_redraw() -> void:
	if _zone_overlay:
		_zone_overlay.queue_redraw()


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
	_counter_stock_manager.consume_counter_rose(eater, access_cell)



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
	return _counter_stock_manager.can_install_new_counter()


func can_install_new_counter() -> bool:
	return _can_install_new_counter()


func _report_playlist_spawn_result(request: Dictionary, success: bool, failure_reason: String = "") -> void:
	var track_index: int = int(request.get("track_index", -1))
	_spawn_playlist_controller.mark_spawn_result(track_index, success, failure_reason)
	if not success:
		var warning_key: String = "playlist:%d" % track_index
		if _debug_telemetry.should_warn_spawn_failure_key(warning_key):
			var message: String = "BuildingManager: playlist spawn failed: %s reason=%s" % [
				_spawn_playlist_controller.get_track_debug_context(track_index),
				failure_reason,
			]
			# "No reachable garden" is an expected gameplay state (everything eaten,
			# sold, or walled off), not an anomaly: log it debug-gated only.
			if failure_reason.contains("has no reachable garden"):
				CppDebugOptions.dlog(message)
			else:
				push_warning(message)


func _spawn_monster_from(spawner_cell: Vector2i, monster_type: StringName = &"basic") -> bool:
	return _spawn_agent_from(spawner_cell, monster_type, SPAWNER_KIND_MONSTER)


func _spawn_client_from(spawner_cell: Vector2i) -> bool:
	return _spawn_agent_from(spawner_cell, &"basic", SPAWNER_KIND_CLIENT)


func spawn_client_from_spawner(spawner_cell: Vector2i) -> bool:
	return _spawn_client_from(spawner_cell)


func _spawn_agent_from(spawner_cell: Vector2i, monster_type: StringName = &"basic", agent_kind: StringName = SPAWNER_KIND_MONSTER) -> bool:
	return _agent_spawn_service.spawn_agent_from(spawner_cell, monster_type, agent_kind)


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
	return _client_tantrum.nearest_live_reservoir(from_world, use_distance)


func _nearest_live_reservoir(from_world: Vector2, use_distance: bool) -> Node2D:
	return nearest_live_reservoir(from_world, use_distance)


func reservoir_is_destroyed(reservoir: Node) -> bool:
	return _client_tantrum.reservoir_is_destroyed(reservoir)


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

# Owns the direct-exit-FF escape telemetry tally so callers do not read-modify-write
# these counters by string name. See eat_exit_direct_ff_success/_failed above.
func note_eat_exit_direct_ff(success: bool) -> void:
	if success:
		eat_exit_direct_ff_success += 1
	else:
		eat_exit_direct_ff_failed += 1

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
	_spawn_playlist_config.set_current_playlist_night_index(-1)
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
	_turret_eating_controller.clear_agent(nav_id)
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
	return _spawn_playlist_config.monster_drop_seed_chance_percent()

func _nearest_spawner_cell(from_cell: Vector2i) -> Vector2i:
	return _spawner_garden_selection_service.nearest_spawner_cell(from_cell)

func _agent_reached_cell(agent: Node2D, cell: Vector2i) -> bool:
	var agent_cell: Vector2i = floorz.local_to_map(floorz.to_local(agent.global_position))
	if agent_cell == cell:
		return true
	var cell_size: Vector2 = Vector2(32, 32)
	if floorz and floorz.tile_set:
		var raw_tile_size: Vector2i = floorz.tile_set.get_tile_size()
		cell_size = Vector2(float(raw_tile_size.x), float(raw_tile_size.y))
	return agent.global_position.distance_to(_cell_center(cell)) <= max(cell_size.x, cell_size.y) * 0.5

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

func get_gardens() -> Dictionary:
	return _get_gardens()

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

# Garden/spawner target-selection scoring now lives in SpawnerGardenSelectionService.
# These stay as thin compatibility wrappers: _spawn_agent_from calls the first two
# directly, and GardenRetargetController calls the last two directly on its typed
# BuildingManager reference.
func _select_garden_for_spawner(spawner_cell: Vector2i) -> int:
	return _spawner_garden_selection_service.select_garden_for_spawner(spawner_cell)


func _select_garden_for_client_spawner(spawner_cell: Vector2i) -> int:
	return _spawner_garden_selection_service.select_garden_for_client_spawner(spawner_cell)


func _select_spawner_garden_for_agent(from_cell: Vector2i, agent_kind: StringName = SPAWNER_KIND_MONSTER) -> Dictionary:
	return _spawner_garden_selection_service.select_spawner_garden_for_agent(from_cell, agent_kind)


func _select_spawner_for_garden_from_cell(garden_id: int, from_cell: Vector2i, fallback_spawner_cell: Vector2i, agent_kind: StringName = SPAWNER_KIND_MONSTER) -> Vector2i:
	return _spawner_garden_selection_service.select_spawner_for_garden_from_cell(garden_id, from_cell, fallback_spawner_cell, agent_kind)

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
	return _debug_query_service.get_plant_zone_tiles()

func get_plant_zone_margin_tiles() -> Array:
	return _debug_query_service.get_plant_zone_margin_tiles()

func get_plant_zone_route_tiles() -> Array:
	return _debug_query_service.get_plant_zone_route_tiles()

func get_garden_entry_cells() -> Array:
	return _debug_query_service.get_garden_entry_cells()

func set_show_enters_exits(value: bool) -> void:
	_debug_query_service.set_show_enters_exits(value)

func get_show_enters_exits() -> bool:
	return _debug_query_service.get_show_enters_exits()

func set_verbose(value: bool) -> void:
	_debug_query_service.set_verbose(value)

# True when verbose garden logging is on. Once CppDebugOptions has pushed a value
# via set_verbose() we trust that (it is already gated by debug_enabled there);
# before that push (e.g. the startup recompute, which can run before
# CppDebugOptions._ready()) we pull the value straight from the CPP node AND its
# debug_enabled flag, so the master debug gate holds even for the first recompute.
func _is_verbose() -> bool:
	return _debug_query_service.is_verbose()

# Garden border tiles a monster crosses to ENTER: per spawner, the garden
# entry cell nearest that spawner. Aggregated across all spawners/gardens.
func get_garden_enter_tiles() -> Array:
	return _debug_query_service.get_garden_enter_tiles()

# Garden border tiles a monster crosses to EXIT: per spawner, the garden
# entry cell nearest that spawner's exit-wall. Aggregated across all spawners.
func get_garden_exit_tiles() -> Array:
	return _debug_query_service.get_garden_exit_tiles()

func get_unreachable_garden_cells() -> Array:
	return _debug_query_service.get_unreachable_garden_cells()

func get_dirty_garden_cells() -> Array:
	return _debug_query_service.get_dirty_garden_cells()

func get_debug_monster_path(nav_id: int) -> PackedVector2Array:
	return _debug_query_service.get_debug_monster_path(nav_id)

func _debug_path_to_cell(cell: Vector2i) -> PackedVector2Array:
	return _debug_query_service._debug_path_to_cell(cell)

func get_floorz() -> TileMapLayer:
	return _debug_query_service.get_floorz()


func get_plantz() -> TileMapLayer:
	return plantz

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


func find_sheep_path(from_tile: Vector2i, to_tile: Vector2i) -> PackedVector2Array:
	return _building_path_service.find_sheep_path(from_tile, to_tile)

func _find_path_in_zone(from_tile: Vector2i, to_tile: Vector2i, garden_id: int = 0) -> PackedVector2Array:
	return _building_path_service.find_path_in_zone(from_tile, to_tile, garden_id)

# Fold one _find_path_in_zone call's timings into the per-retarget accumulator (reset
# at the start of the local plant search). Tracks totals + the single most expensive
# call so the parent breakdown can show whether the path cost is spread across many
# calls or dominated by one. Cheap; no per-call warning here.
func _accumulate_find_path_in_zone(call_start_us: int, sync_elapsed: int, blocker_elapsed: int, find_elapsed: int, from_tile: Vector2i, to_tile: Vector2i, zone_tiles: int) -> void:
	_garden_retarget.accumulate_find_path_in_zone(call_start_us, sync_elapsed, blocker_elapsed, find_elapsed, from_tile, to_tile, zone_tiles)

func _sync_pathfinder_zone_tiles(zone_tiles: Dictionary) -> void:
	_building_path_service.sync_pathfinder_zone_tiles(zone_tiles)

func _path_cells_to_world(path_cells: PackedVector2Array, nav_id: int = -1, disperse_endpoint: bool = false) -> PackedVector2Array:
	return _building_path_service.path_cells_to_world(path_cells, nav_id, disperse_endpoint)

func _tile_size() -> Vector2:
	if floorz and floorz.tile_set:
		var raw_tile_size: Vector2i = floorz.tile_set.get_tile_size()
		return Vector2(float(raw_tile_size.x), float(raw_tile_size.y))
	return Vector2(32, 32)


func is_sheep_walkable_cell(cell: Vector2i) -> bool:
	if not _has_floor(cell):
		return false
	if wallz != null and wallz.get_cell_tile_data(cell) != null:
		return false
	return not _building_cell_blocks_movement(cell)

func _resolve_plant_target_for_agent_in_garden(from_cell: Vector2i, garden_id: int, agent_kind: StringName = SPAWNER_KIND_MONSTER) -> Vector2i:
	return _garden_topology.resolve_plant_target_for_agent_in_garden(from_cell, garden_id, agent_kind)


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


func has_client_targets_remaining() -> bool:
	return _has_client_targets_remaining()

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
