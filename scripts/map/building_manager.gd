extends Node
class_name BuildingManager

signal startup_loading_progress(progress: float, label: String)
signal startup_loading_finished

const AGENT_SCENE: PackedScene = preload("res://scenes/entities/character.tscn")
const CLIENT_TEXTURE: Texture2D = preload("res://assets/sprites/legval/client.png")
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
const PASTEQUE_ITEM_ID: String = "pasteque"
# Enter mode uses softer continuation penalties (the agent is heading inward, so
# outside continuation matters less than for exits).
const ACCESS_ENTER_DEAD_CONTINUATION_PENALTY: float = 30.0
const ACCESS_ENTER_NARROW_CONTINUATION_PENALTY: float = 10.0

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
var _spawner_routes: Dictionary = {}
var _spawner_garden_routes: Dictionary = {}
# Route-cache hit/miss counters (lifetime-of-process), bumped in
# _get_or_create_spawner_garden_route. Used by the _process_spawners lag detector
# to attribute time to cache misses vs. hits.
var _route_cache_hits: int = 0
var _route_cache_misses: int = 0
# Parent-triggered retarget breakdown profiling. Child functions always fill these
# (cheap int writes) so the parent _retarget_agent_or_escape can emit ONE consolidated
# "debug_garden_lag_breakdown" line when it exceeds threshold — even when every inner
# section is individually below threshold and so wouldn't self-report. Pure
# instrumentation; never read by gameplay. See _reset_retarget_profile().
#   _last_local_retarget_profile      - filled by _try_local_retarget_agent
#   _last_find_local_retarget_profile - filled by _find_local_retarget_plant
#   _find_path_in_zone_accum          - per-retarget accumulator across every
#                                       _find_path_in_zone call (reset by the plant
#                                       search, added to by each path query).
var _last_retarget_profile: Dictionary = {}
var _last_local_retarget_profile: Dictionary = {}
var _last_find_local_retarget_profile: Dictionary = {}
var _find_path_in_zone_accum: Dictionary = {}
# Side-channel: _sync_pathfinder_zone_tiles writes the time it spent in
# _wall_blockers_for_cells here so the caller can split sync time into
# blocker-construction vs. the rest, without changing the void signature.
var _last_zone_blocker_us: int = 0
var _eating_agents: Dictionary = {}
var _eating_time: float = EATING_COOLDOWN
var _number_of_roses_before_satiety: int = 3
var _same_garden_only: bool = false
var _paused: bool = false
var _escaping_agents: Dictionary = {}
var _entry_path_agents: Dictionary = {}
var _astar_in_agents: Dictionary = {}
# Reverse index: target plant cell -> { nav_id -> true }, plus nav_id -> target cell.
# Lets plant removal find the (usually 0-2) agents heading for that exact plant in
# O(agents_targeting_this_plant) instead of scanning every _astar_in_agents entry.
# Maintained exclusively by _set_astar_in_agent / _erase_astar_in_agent (which call
# _register_/_unregister_astar_in_target). _register ALWAYS unregisters the nav_id
# from its previous bucket first, so a nav_id is in at most one bucket and the two
# dictionaries can never disagree. The plant-removal retarget additionally validates
# every bucket entry against the live record and scrubs any that don't match, so even
# a stale entry that slipped in can never be double-counted across removals.
var _astar_in_agents_by_target_plant: Dictionary = {}  # Vector2i -> { nav_id -> true }
var _astar_in_target_by_nav_id: Dictionary = {}        # nav_id -> Vector2i
# When true, _retarget_agents_targeting_removed_plant_only also runs the old full
# scan and warns on any mismatch with the index. OFF by default (reintroduces the
# very scan cost the index removes); flip on only to debug index consistency.
var _debug_check_retarget_index: bool = false
# Side-channel counts from the last _retarget_agents_targeting_removed_plant_only
# call, so the caller's lag warning can report what the index touched without the
# function having to return anything.
var _last_plant_retarget_astar_in: int = 0       # _astar_in_agents.size() at entry
var _last_plant_retarget_bucket: int = 0         # raw bucket entries for the cell
var _last_plant_retarget_affected: int = 0       # valid agents actually retargeted
var _last_plant_retarget_queued: int = 0         # of those, deferred to the queue
var _last_plant_retarget_stale: int = 0          # bucket entries dropped as invalid
var _last_plant_retarget_already_queued: int = 0 # valid but already in retarget queue
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
var _navigation_topology_dirty: bool = true
var _flow_ready: bool = false
var _startup_loading_started: bool = false
var _startup_ready: bool = false
var _night_preparing: bool = false
var _night_preparation_ready: bool = false
var _night_preparation_token: int = 0
var _day_start_pending: bool = false
var _client_preparing: bool = false
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
# Eat-exit transition counters: monsters finishing eating attach directly to the
# existing per-exit-wall escape FF (no garden-exit selection, no per-agent A* out).
# A failure is expected to be rare and indicates an FF coverage/walkability bug.
var eat_exit_direct_ff_success: int = 0
var eat_exit_direct_ff_failed: int = 0
# Gardens found empty during a _gardens iteration; erased after the loop ends.
var _pending_empty_gardens: Dictionary = {}  # garden_id -> true
# Memoizes the expensive scored garden-entry selection (_nearest_garden_entry =
# _select_scored_garden_entry in "enter" mode, no escape group). The chosen entry
# depends only on (garden_id, source/spawner cell): scoring runs flow lookups +
# per-candidate neighbor/walkability scans over every entry cell, and the retarget
# path calls it once per (spawner, garden) pair for every agent, so many agents
# targeting the same routes recompute identical results. Keyed by "spawner|garden"
# so different spawners never share a (possibly far/bad) entry — the result is
# source-dependent, never cached by garden_id alone. Value: the selected entry
# Vector2i (may be INVALID_CELL — cached too, that "no entry" result is also reused).
# Invalidated wholesale on any topology/wall/entry rebuild (see
# _clear_garden_entry_resolve_cache call sites); plain plant eating that leaves the
# garden connected with the same entries does NOT touch it.
var _garden_entry_resolve_cache: Dictionary = {}  # "spawner|garden" -> Vector2i
# Retarget breakdown debug counters (read into the consolidated profile line).
# Per-call flag set by _nearest_garden_entry; per-resolve tallies accumulated by
# _select_spawner_garden_for_agent (which calls _nearest_garden_entry many times).
var _garden_entry_resolve_cache_hit: bool = false
var _garden_entry_resolve_hits: int = 0
var _garden_entry_resolve_misses: int = 0
# Cells reachable from any spawner over the walkable map. Recomputed once per
# garden rebuild (single source flood-fill); read when deciding if a garden is
# reachable. A sealed enclosure has no entry cell in this set, so it is ignored.
var _spawner_reachable_cells: Dictionary = {}  # Vector2i -> true
var _walkable_map_tiles: Dictionary = {}  # Vector2i -> true

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
var _client_counter_agents: Dictionary = {}  # nav_id -> Dictionary
var _damage_number_drawer: DamageNumberDrawer
var _seed_merchant: SeedMerchantController = SeedMerchantController.new()
var _morning_harvest: MorningHarvestController = MorningHarvestController.new()
var _client_tantrum: ClientTantrumController = ClientTantrumController.new()
var _client_sale: ClientSaleController = ClientSaleController.new()
var _drowning_controller: DrowningController = DrowningController.new()
var _turret_eating_controller: TurretEatingController = TurretEatingController.new()
var _agent_suspend: AgentSuspendService = AgentSuspendService.new()
var _building_scan: BuildingScanService = BuildingScanService.new()
var _debug_telemetry: BuildingDebugTelemetry = BuildingDebugTelemetry.new()
var _monster_death: MonsterDeathController = MonsterDeathController.new()
var _counter_stock_manager: CounterStockManager
# Walkable tiles adjacent to a stocked counter, each mapped to its counter cell.
# These are fed into the garden clustering as ordinary "plant cells" so a stocked
# counter becomes a kind of garden: monsters path to one of these tiles and eat a
# rose from the counter (decrementing its stock) instead of a plant. Rebuilt every
# time the gardens are (re)built (see _collect_counter_access_cells).
var _counter_access_cells: Dictionary = {}  # access_cell (Vector2i) -> counter_cell (Vector2i)
# Plant zone compatibility caches. Tiles use the floorz tilemap cell space.
var _plant_zone_tiles: Dictionary = {}  # Vector2i -> true
var _plant_zone_margin_tiles: Dictionary = {}  # Vector2i -> true (entry/exit candidates)
var _plant_zone_built: bool = false
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
	_seed_merchant.setup(self)
	_morning_harvest.setup(self)
	_client_tantrum.setup(self)
	_client_sale.setup(self)
	_drowning_controller.setup(self)
	_turret_eating_controller.setup(self)
	_agent_suspend.setup(self)
	_building_scan.setup(self)
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
		_client_counter_agents.clear()
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
	return (
		flow != null
		and flow.has_method("request_flow_to_group")
		and flow.has_method("are_async_flows_idle")
		and flow.has_method("is_group_flow_request_ready")
	)

func _flow_supports_sync_assign() -> bool:
	return flow != null and flow.has_method("assign_flow_to_group")

func _group_flow_id_is_ready(group_id: int) -> bool:
	if group_id <= IDLE_GROUP:
		return false
	if flow == null:
		return false
	if flow.has_method("is_group_flow_request_ready"):
		return bool(flow.call("is_group_flow_request_ready", group_id))
	return flow.has_method("group_route_cost_at_world")

func _group_flow_is_ready_at_world(group_id: int, world_pos: Vector2) -> bool:
	if group_id <= IDLE_GROUP:
		return false
	if flow == null or not flow.has_method("group_route_cost_at_world"):
		return false
	if not _group_flow_id_is_ready(group_id):
		return false
	var cost: float = float(flow.call("group_route_cost_at_world", group_id, world_pos))
	return is_finite(cost)

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
	var slice_started_us: int = Time.get_ticks_usec()
	for raw_spawner_cell: Variant in _spawners.keys():
		if not _night_preparation_is_current(token):
			return false
		var spawner_cell: Vector2i = raw_spawner_cell as Vector2i
		if not _spawner_is_one_of_kinds(spawner_cell, agent_kinds):
			continue
		_initialize_spawner_route(spawner_cell)
		if Time.get_ticks_usec() - slice_started_us >= _night_preparation_budget_us():
			await get_tree().process_frame
			slice_started_us = Time.get_ticks_usec()
	return true

func _night_flow_fields_are_ready_for_kinds(agent_kinds: Array[StringName], check_exit_wall_escapes: bool) -> bool:
	if not flow or not flow.has_method("group_route_cost_at_world"):
		return false
	for raw_spawner_cell: Variant in _spawners.keys():
		var spawner_cell: Vector2i = raw_spawner_cell as Vector2i
		if not _spawner_is_one_of_kinds(spawner_cell, agent_kinds):
			continue
		if not _spawner_routes.has(spawner_cell):
			return false
		var route: Dictionary = _spawner_routes[spawner_cell] as Dictionary
		if not bool(route.get("escape_ready", false)):
			return false
		var group_id: int = int(route.get("escape_group", -1))
		var goal_world: Vector2 = route.get("escape_world", Vector2.ZERO) as Vector2
		if not _group_flow_is_ready_at_world(group_id, goal_world):
			return false
	if not check_exit_wall_escapes:
		return true
	for raw_escape: Variant in _exit_wall_escapes.values():
		var escape: Dictionary = raw_escape as Dictionary
		var exit_group_id: int = int(escape.get("escape_group", -1))
		var exit_goal_world: Vector2 = escape.get("escape_world", Vector2.ZERO) as Vector2
		if exit_group_id > IDLE_GROUP and not _group_flow_is_ready_at_world(exit_group_id, exit_goal_world):
			return false
	return true

func _prewarm_spawner_entry_flows_for_kind(agent_kind: StringName, token: int) -> bool:
	if not _flow_ready or not agent_manager or not flow:
		return true
	if not flow.has_method("group_route_cost_at_world"):
		return false
	var requested_groups: Dictionary = {}
	var slice_started_us: int = Time.get_ticks_usec()
	for raw_spawner_cell: Variant in _spawners.keys():
		if not _night_preparation_is_current(token):
			return false
		var spawner_cell: Vector2i = raw_spawner_cell as Vector2i
		if (_spawner_kind_by_cell.get(spawner_cell, SPAWNER_KIND_MONSTER) as StringName) != agent_kind:
			continue
		for raw_garden_id: Variant in _gardens.keys():
			if not _night_preparation_is_current(token):
				return false
			var garden_id: int = int(raw_garden_id)
			var garden: Dictionary = _gardens[garden_id] as Dictionary
			if not bool(garden.get("targetable", false)):
				continue
			if not _garden_has_target_for_kind(garden_id, agent_kind):
				continue
			var route: Dictionary = _get_or_create_spawner_garden_route(spawner_cell, garden_id)
			var group_id: int = int(route.get("plant_group", -1))
			if group_id > IDLE_GROUP:
				requested_groups[group_id] = true
			if Time.get_ticks_usec() - slice_started_us >= _night_preparation_budget_us():
				await get_tree().process_frame
				slice_started_us = Time.get_ticks_usec()
	if _flow_uses_async_requests():
		while _night_preparation_is_current(token) and not bool(flow.call("are_async_flows_idle")):
			await get_tree().process_frame
	if not _night_preparation_is_current(token):
		return false
	for raw_group_id: Variant in requested_groups.keys():
		var group_id: int = int(raw_group_id)
		if not _group_flow_id_is_ready(group_id):
			return false
	_mark_spawner_entry_routes_ready_for_groups(requested_groups)
	return true

func _mark_spawner_entry_routes_ready_for_groups(group_ids: Dictionary) -> void:
	for raw_spawner_cell: Variant in _spawner_garden_routes.keys():
		var spawner_cell: Vector2i = raw_spawner_cell as Vector2i
		var routes: Dictionary = _spawner_garden_routes[spawner_cell] as Dictionary
		for raw_garden_id: Variant in routes.keys():
			var garden_id: int = int(raw_garden_id)
			var route: Dictionary = routes[garden_id] as Dictionary
			var group_id: int = int(route.get("plant_group", -1))
			if group_ids.has(group_id) and _garden_route_is_current(route, garden_id):
				route["ready"] = _spawner_garden_route_flow_ready(route, spawner_cell)
				routes[garden_id] = route
		_spawner_garden_routes[spawner_cell] = routes

func _rebuild_exit_wall_escapes_budgeted(token: int) -> bool:
	if not _flow_ready or not agent_manager or not flow:
		return true
	if not agent_manager.has_method("create_group"):
		return true
	_clear_garden_entry_resolve_cache("night_prepare_exit_escapes")
	var current_exits: Dictionary = {}
	if wallz:
		for raw_cell: Variant in wallz.get_used_cells():
			var wall_cell: Vector2i = raw_cell as Vector2i
			if wallz.get_cell_atlas_coords(wall_cell) == EXIT_WALL_ATLAS:
				current_exits[wall_cell] = true
	for raw_exit_cell: Variant in _exit_wall_escapes.keys().duplicate():
		var old_exit_cell: Vector2i = raw_exit_cell as Vector2i
		if not current_exits.has(old_exit_cell):
			_release_exit_wall_escape(old_exit_cell)

	var slice_started_us: int = Time.get_ticks_usec()
	for raw_exit_cell: Variant in current_exits.keys():
		if not _night_preparation_is_current(token):
			return false
		var exit_cell: Vector2i = raw_exit_cell as Vector2i
		var target_cell: Vector2i = _nearest_walkable_adjacent(exit_cell)
		if target_cell == INVALID_CELL:
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
			_release_exit_wall_escape(exit_cell)
			continue
		_request_group_flow_rebuild(escape_group, escape_world)
		escape["escape_group"] = escape_group
		escape["escape_target_cell"] = target_cell
		escape["escape_world"] = escape_world
		escape["ready"] = true
		_exit_wall_escapes[exit_cell] = escape
		if Time.get_ticks_usec() - slice_started_us >= _night_preparation_budget_us():
			await get_tree().process_frame
			slice_started_us = Time.get_ticks_usec()
	return true

func _rebuild_walkable_map_cache_budgeted(token: int) -> bool:
	_walkable_map_tiles.clear()
	if floorz == null:
		return true
	var slice_started_us: int = Time.get_ticks_usec()
	var floor_cells: Array[Vector2i] = floorz.get_used_cells()
	for cell: Vector2i in floor_cells:
		if not _night_preparation_is_current(token):
			return false
		if _is_walkable(cell):
			_walkable_map_tiles[cell] = true
		if Time.get_ticks_usec() - slice_started_us >= _night_preparation_budget_us():
			await get_tree().process_frame
			slice_started_us = Time.get_ticks_usec()
	return true

func _build_gardens_from_plants_budgeted(token: int) -> bool:
	_gardens.clear()
	_garden_by_plant_cell.clear()
	_counter_access_cells.clear()
	_dirty_gardens.clear()
	_pending_empty_gardens.clear()
	_clear_garden_entry_resolve_cache("night_prepare_gardens")
	_gardens_epoch += 1
	if plant_manager == null or not plant_manager.has_method("get_plant_cells"):
		_plant_zone_built = true
		return true

	var unassigned: Dictionary = {}
	var source_cells: Array = plant_manager.call("get_plant_cells") as Array
	source_cells.append_array(_collect_counter_access_cells())
	for raw_cell: Variant in source_cells:
		var source_cell: Vector2i = raw_cell as Vector2i
		if not _is_walkable(source_cell):
			continue
		unassigned[source_cell] = true

	var slice_started_us: int = Time.get_ticks_usec()
	while not unassigned.is_empty():
		if not _night_preparation_is_current(token):
			return false
		var seed_cell: Vector2i = unassigned.keys()[0] as Vector2i
		var garden_id: int = _create_garden()
		var garden: Dictionary = _gardens[garden_id] as Dictionary
		var garden_plants: Dictionary = garden.get("plant_cells", {}) as Dictionary
		var frontier_plants: Array[Vector2i] = [seed_cell]
		unassigned.erase(seed_cell)
		garden_plants[seed_cell] = true
		_garden_by_plant_cell[seed_cell] = garden_id

		while not frontier_plants.is_empty():
			var from_plant: Vector2i = frontier_plants.pop_back()
			var visited: Dictionary = {from_plant: 0}
			var queue: Array[Vector2i] = [from_plant]
			var head: int = 0
			while head < queue.size():
				if not _night_preparation_is_current(token):
					return false
				var cell: Vector2i = queue[head]
				head += 1
				var distance: int = int(visited[cell])
				if distance < GARDEN_LINK_DISTANCE:
					for dy: int in range(-1, 2):
						for dx: int in range(-1, 2):
							if dx == 0 and dy == 0:
								continue
							var neighbor: Vector2i = cell + Vector2i(dx, dy)
							if visited.has(neighbor) or not _is_walkable(neighbor):
								continue
							if dx != 0 and dy != 0:
								if not _is_walkable(cell + Vector2i(dx, 0)) or not _is_walkable(cell + Vector2i(0, dy)):
									continue
							visited[neighbor] = distance + 1
							queue.append(neighbor)
							if unassigned.has(neighbor):
								unassigned.erase(neighbor)
								garden_plants[neighbor] = true
								_garden_by_plant_cell[neighbor] = garden_id
								frontier_plants.append(neighbor)
				if Time.get_ticks_usec() - slice_started_us >= _night_preparation_budget_us():
					await get_tree().process_frame
					slice_started_us = Time.get_ticks_usec()

		garden["plant_cells"] = garden_plants
		garden["edible_count"] = garden_plants.size()
		garden["targetable"] = false
		_gardens[garden_id] = garden
		_mark_garden_dirty(garden_id, false)
	_plant_zone_built = true
	return true

func _validate_gardens_budgeted(token: int) -> bool:
	var dirty_ids: Array = _dirty_gardens.keys()
	_dirty_gardens.clear()
	_clear_garden_entry_resolve_cache("night_prepare_validate")
	for raw_garden_id: Variant in dirty_ids:
		if not _night_preparation_is_current(token):
			return false
		var garden_id: int = int(raw_garden_id)
		if not _gardens.has(garden_id):
			continue
		var garden: Dictionary = _gardens[garden_id] as Dictionary
		var plant_cells: Dictionary = garden.get("plant_cells", {}) as Dictionary
		if plant_cells.is_empty():
			_release_garden_routes(garden_id)
			_erase_garden(garden_id, "night_prepare_empty")
			continue
		var geometry_result: Variant = await _recompute_garden_geometry_budgeted(garden_id, token)
		if not bool(geometry_result):
			return false

	var reachable_result: Variant = await _recompute_spawner_reachable_cells_budgeted(token)
	if not bool(reachable_result):
		return false
	_gardens_iter_depth += 1
	var total_entry_points: int = 0
	var slice_started_us: int = Time.get_ticks_usec()
	for raw_garden_id: Variant in _gardens.keys():
		if not _night_preparation_is_current(token):
			_gardens_iter_depth -= 1
			return false
		var garden_id: int = int(raw_garden_id)
		_apply_spawner_reachability(garden_id)
		total_entry_points += (_gardens[garden_id] as Dictionary).get("entry_cells", []).size()
		if Time.get_ticks_usec() - slice_started_us >= _night_preparation_budget_us():
			await get_tree().process_frame
			slice_started_us = Time.get_ticks_usec()
	_gardens_iter_depth -= 1
	var cache_result: Variant = await _rebuild_plant_zone_compatibility_cache_budgeted(token)
	if not bool(cache_result):
		return false
	_plant_zone_built = true
	if _zone_overlay:
		_zone_overlay.queue_redraw()
	if _is_verbose():
		print("BuildingManager: %d gardens recomputed with %d entry points" % [_gardens.size(), total_entry_points])
	return true

func _recompute_garden_geometry_budgeted(garden_id: int, token: int) -> bool:
	if not _gardens.has(garden_id):
		return true
	var garden: Dictionary = _gardens[garden_id] as Dictionary
	var plant_cells: Dictionary = garden.get("plant_cells", {}) as Dictionary
	var zone_tiles: Dictionary = {}
	var distances: Dictionary = {}
	var queue: Array[Vector2i] = []
	var head: int = 0
	for raw_cell: Variant in plant_cells.keys():
		var plant_cell: Vector2i = raw_cell as Vector2i
		zone_tiles[plant_cell] = true
		distances[plant_cell] = 0
		queue.append(plant_cell)
	var entry_inside: Dictionary = {}
	var slice_started_us: int = Time.get_ticks_usec()
	while head < queue.size():
		if not _night_preparation_is_current(token):
			return false
		var cell: Vector2i = queue[head]
		head += 1
		var cell_distance: int = int(distances[cell])
		for dy: int in range(-1, 2):
			for dx: int in range(-1, 2):
				if dx == 0 and dy == 0:
					continue
				var neighbor: Vector2i = cell + Vector2i(dx, dy)
				if not _is_walkable(neighbor):
					continue
				if dx != 0 and dy != 0:
					if not _is_walkable(cell + Vector2i(dx, 0)) or not _is_walkable(cell + Vector2i(0, dy)):
						continue
				if zone_tiles.has(neighbor):
					continue
				var next_distance: int = cell_distance + 1
				if next_distance <= PLANT_ZONE_MARGIN:
					if not distances.has(neighbor) or next_distance < int(distances[neighbor]):
						distances[neighbor] = next_distance
						zone_tiles[neighbor] = true
						queue.append(neighbor)
				else:
					entry_inside[cell] = true
		if Time.get_ticks_usec() - slice_started_us >= _night_preparation_budget_us():
			await get_tree().process_frame
			slice_started_us = Time.get_ticks_usec()

	var margin_tiles: Dictionary = {}
	for raw_cell: Variant in zone_tiles.keys():
		var zone_cell: Vector2i = raw_cell as Vector2i
		if not plant_cells.has(zone_cell):
			margin_tiles[zone_cell] = true
	var entry_cells: Array[Vector2i] = []
	for raw_cell: Variant in entry_inside.keys():
		entry_cells.append(raw_cell as Vector2i)
	garden["zone_tiles"] = zone_tiles
	garden["margin_tiles"] = margin_tiles
	garden["entry_cells"] = entry_cells
	garden["reachable"] = not entry_cells.is_empty()
	garden["edible_count"] = plant_cells.size()
	garden["targetable"] = plant_cells.size() > 0 and not entry_cells.is_empty()
	garden["dirty"] = false
	_gardens[garden_id] = garden
	return true

func _recompute_spawner_reachable_cells_budgeted(token: int) -> bool:
	_spawner_reachable_cells.clear()
	if _spawners.is_empty():
		return true
	var queue: Array[Vector2i] = []
	var head: int = 0
	for raw_spawner_cell: Variant in _spawners.keys():
		var spawner_cell: Vector2i = raw_spawner_cell as Vector2i
		for dy: int in range(-1, 2):
			for dx: int in range(-1, 2):
				var candidate_cell: Vector2i = spawner_cell + Vector2i(dx, dy)
				if _spawner_reachable_cells.has(candidate_cell) or not _is_walkable(candidate_cell):
					continue
				_spawner_reachable_cells[candidate_cell] = true
				queue.append(candidate_cell)
	var slice_started_us: int = Time.get_ticks_usec()
	while head < queue.size():
		if not _night_preparation_is_current(token):
			return false
		var cell: Vector2i = queue[head]
		head += 1
		for dy: int in range(-1, 2):
			for dx: int in range(-1, 2):
				if dx == 0 and dy == 0:
					continue
				var neighbor: Vector2i = cell + Vector2i(dx, dy)
				if _spawner_reachable_cells.has(neighbor) or not _is_walkable(neighbor):
					continue
				if dx != 0 and dy != 0:
					if not _is_walkable(cell + Vector2i(dx, 0)) or not _is_walkable(cell + Vector2i(0, dy)):
						continue
				_spawner_reachable_cells[neighbor] = true
				queue.append(neighbor)
		if Time.get_ticks_usec() - slice_started_us >= _night_preparation_budget_us():
			await get_tree().process_frame
			slice_started_us = Time.get_ticks_usec()
	return true

func _rebuild_plant_zone_compatibility_cache_budgeted(token: int) -> bool:
	_plant_zone_tiles.clear()
	_plant_zone_margin_tiles.clear()
	var slice_started_us: int = Time.get_ticks_usec()
	for raw_garden: Variant in _gardens.values():
		if not _night_preparation_is_current(token):
			return false
		var garden: Dictionary = raw_garden as Dictionary
		var zone_tiles: Dictionary = garden.get("zone_tiles", {}) as Dictionary
		var margin_tiles: Dictionary = garden.get("margin_tiles", {}) as Dictionary
		for raw_cell: Variant in zone_tiles.keys():
			var zone_cell: Vector2i = raw_cell as Vector2i
			_plant_zone_tiles[zone_cell] = true
		for raw_cell: Variant in margin_tiles.keys():
			var margin_cell: Vector2i = raw_cell as Vector2i
			_plant_zone_margin_tiles[margin_cell] = true
		if Time.get_ticks_usec() - slice_started_us >= _night_preparation_budget_us():
			await get_tree().process_frame
			slice_started_us = Time.get_ticks_usec()
	return true

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

	if not _dirty_spawner_escapes.is_empty():
		# Capture the count before the call: _drain_dirty_routes clears the dict.
		var dirty_escapes_before: int = _dirty_spawner_escapes.size()
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
				_garden_retarget_queue.size(),
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
				_route_cache_hits,
				_route_cache_misses,
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
			_garden_retarget_queue.size(),
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
	if _plant_zone_built:
		_rebuild_plant_zone_from_layer()
	_rebuild_spawner_garden_route_cache()
	for raw_spawner_cell: Variant in _spawners.keys():
		var spawner_cell: Vector2i = raw_spawner_cell as Vector2i
		_rebuild_spawner_plant_ff(spawner_cell)
		_dirty_spawner_escapes[spawner_cell] = true
	var exits_us: int = Time.get_ticks_usec()
	_rebuild_exit_wall_escapes()
	_debug_telemetry.warn_garden_task_lag_us("_rebuild_exit_wall_escapes", Time.get_ticks_usec() - exits_us,
		"exits=%d" % _exit_wall_escapes.size())

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
		_plant_zone_built = false
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
		_plant_zone_built = false
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
			"garden=%d retarget_queue=%d" % [garden_id, _garden_retarget_queue.size()])
	else:
		var rt_us: int = Time.get_ticks_usec()
		_retarget_agents_targeting_removed_plant_only(cell, garden_id)
		_debug_telemetry.warn_garden_task_lag_us("_retarget_agents_targeting_removed_plant_only", Time.get_ticks_usec() - rt_us,
			"garden=%d plant=%s astar_in=%d bucket_size=%d valid_affected=%d queued=%d already_queued=%d stale=%d indexed_targets=%d" % [
				garden_id, str(cell), _last_plant_retarget_astar_in,
				_last_plant_retarget_bucket, _last_plant_retarget_affected,
				_last_plant_retarget_queued, _last_plant_retarget_already_queued,
				_last_plant_retarget_stale, _astar_in_agents_by_target_plant.size()])

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
	if is_new and GameState.is_night and _night_preparation_ready and _flow_ready and _plant_zone_built and _startup_ready:
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
	_spawner_kind_by_cell.erase(spawner_cell)
	_spawner_exit_cell_by_cell.erase(spawner_cell)
	_spawner_spot_cell_by_cell.erase(spawner_cell)
	_client_spawners.erase(spawner_cell)
	_client_frequency_by_cell.erase(spawner_cell)
	_merchant_spawners.erase(spawner_cell)

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
	# One-shot: compute static escape cells. Plant-entry flow routes are created
	# lazily when a spawner needs a target garden.
	if not _flow_ready or not _plant_zone_built:
		return
	if not agent_manager or not flow:
		return

	var route: Dictionary = _spawner_routes.get(spawner_cell, {}) as Dictionary

	var bound_exit_cell: Vector2i = _spawner_exit_cell_by_cell.get(spawner_cell, INVALID_CELL) as Vector2i
	# New authored spawners own a child "exit" marker. Legacy levels without that
	# marker still fall back to the nearest exit-wall tile.
	var exit_wall_cell: Vector2i = bound_exit_cell
	if exit_wall_cell == INVALID_CELL:
		exit_wall_cell = _nearest_exit_wall_for_spawner(spawner_cell)
	route["exit_wall_cell"] = exit_wall_cell
	route["has_bound_exit"] = bound_exit_cell != INVALID_CELL

	# Floor tile adjacent to the exit wall that the FF can target.
	var escape_wall_target_cell: Vector2i = INVALID_CELL
	if exit_wall_cell != INVALID_CELL:
		if bound_exit_cell != INVALID_CELL and _is_walkable(exit_wall_cell):
			escape_wall_target_cell = exit_wall_cell
		else:
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
			_request_group_flow_rebuild(escape_group, escape_world)
			route["escape_group"] = escape_group
			route["escape_world"] = escape_world
			route["escape_ready"] = true
		else:
			push_error("BuildingManager: spawner %s could not allocate escape group" % spawner_cell)
			route["escape_ready"] = false
	else:
		route["escape_ready"] = false

	_spawner_routes[spawner_cell] = route
	_debug_telemetry.log("initialized spawner=%s exit_wall=%s escape_target=%s" % [
		spawner_cell, exit_wall_cell, escape_wall_target_cell
	])

func _rebuild_spawner_plant_ff(spawner_cell: Vector2i) -> void:
	if not _spawner_garden_routes.has(spawner_cell):
		return
	var garden_routes: Dictionary = _spawner_garden_routes[spawner_cell] as Dictionary
	for raw_garden_id in garden_routes.keys():
		var garden_id: int = int(raw_garden_id)
		var route: Dictionary = garden_routes[garden_id] as Dictionary
		var entry_cell: Vector2i = route.get("entry_cell", INVALID_CELL) as Vector2i
		if entry_cell == INVALID_CELL:
			continue
		var plant_group: int = int(route.get("plant_group", -1))
		if plant_group <= IDLE_GROUP:
			continue
		var entry_world: Vector2 = _cell_center(entry_cell)
		route["entry_world"] = entry_world
		route["ready"] = false
		route["flow_requested"] = true
		_request_group_flow_rebuild(plant_group, entry_world)
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
func _rebuild_exit_wall_escapes(use_async_requests: bool = false) -> void:
	if not _flow_ready:
		return
	if not agent_manager or not agent_manager.has_method("create_group"):
		return
	# Exit walls are only rebuilt on wall changes (which also re-cluster gardens and
	# rebuild routes), but clear here too so this invalidation point is explicit.
	_clear_garden_entry_resolve_cache("rebuild_exit_escapes")
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
		# Night preparation submits these to the native worker and holds spawning
		# until every result is applied. Runtime fallback keeps the prior synchronous
		# behavior for callers that explicitly need an immediately queryable field.
		if use_async_requests and _flow_uses_async_requests():
			_request_group_flow_rebuild(escape_group, escape_world)
		elif flow.has_method("assign_flow_to_group"):
			flow.call("assign_flow_to_group", escape_group, escape_world, _fences_block_navigation())
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
	# Monster and client agents never coexist: monster flows are (re)built during night,
	# client/merchant flows during the client-sale (day) phase. Fences are walls only for
	# the client side, so the per-request block flag keys straight off the phase. Monster
	# flows ignore fences entirely (slowed by the fence speed multiplier), client flows
	# treat them as impassable.
	var block_fences: bool = _fences_block_navigation()
	if _flow_uses_async_requests():
		flow.call("request_flow_to_group", group_id, goal_world, block_fences)
	elif _flow_supports_sync_assign():
		flow.call("assign_flow_to_group", group_id, goal_world, block_fences)

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
	_client_counter_agents.clear()


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
	_counter_access_cells.clear()
	_plant_zone_built = false
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
	if previous == 0 and value > 0 and _plant_zone_built:
		_rebuild_plant_zone_from_layer()
	elif previous > 0 and value == 0 and _no_plants_remaining():
		_force_escape_for_all_monsters()


# Populates _counter_access_cells from every stocked counter and returns the access
# tiles as an array to seed the garden clustering. An access tile is a walkable cell
# 8-adjacent to the counter that does not already hold a plant (the flower keeps its
# own cell). Called from _build_gardens_from_plants, which clears the map first.
func _collect_counter_access_cells() -> Array[Vector2i]:
	return _counter_stock_manager.collect_access_cells(_counter_access_cells)


# A cell a monster can eat from: a real plant, or an access tile of a still-stocked
# counter. This is the counter-aware generalization of plant_manager.has_plant used
# throughout monster garden targeting so a stocked counter behaves like a garden.
func _is_eatable_for_monster(cell: Vector2i) -> bool:
	if _counter_access_cells.has(cell):
		return _counter_stock(_counter_access_cells[cell] as Vector2i) > 0
	return plant_manager != null and plant_manager.has_method("has_plant") and bool(plant_manager.call("has_plant", cell))


# Eating from a counter: the monster grabs one rose off the counter (decrementing its
# sellable stock) and chews at the access tile. No plant is removed; when the counter
# hits zero its access tiles stop being edible and its garden empties out normally.
func _consume_counter_rose(eater: Node2D, _spawner_cell: Vector2i, access_cell: Vector2i) -> void:
	var counter_cell: Vector2i = _counter_access_cells[access_cell] as Vector2i
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
			"spawner_cell=%s gardens=%d garden=%d" % [str(spawner_cell), _gardens.size(), garden_id])
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
		if _astar_in_agents.has(nav_id):
			continue
		# Grab a nearby counter's rose on the way to the garden entrance and leave early.
		if _try_client_early_counter_fetch(agent):
			continue
		var entry_cell: Vector2i = data.get("entry_cell", INVALID_CELL) as Vector2i
		if entry_cell == INVALID_CELL:
			finished.append(nav_id)
			continue
		if not _agent_reached_cell(agent, entry_cell):
			continue
		var spawner_cell: Vector2i = data.get("spawner_cell", INVALID_CELL) as Vector2i
		var garden_id: int = int(data.get("garden_id", 0))
		if not _garden_has_target_for_kind(garden_id, _agent_kind(agent)):
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
	var agent_kind: StringName = _agent_kind(agent)
	if not _garden_has_target_for_kind(garden_id, agent_kind):
		_retarget_agent_or_escape(agent, spawner_cell)
		return
	var target_plant_cell: Vector2i = _resolve_plant_target_for_agent_in_garden(agent_cell, garden_id, agent_kind)
	if target_plant_cell == INVALID_CELL:
		_retarget_agent_or_escape(agent, spawner_cell)
		return
	var path_cells: PackedVector2Array = _find_path_in_zone(agent_cell, target_plant_cell, garden_id)
	if path_cells.is_empty():
		_retarget_agent_or_escape(agent, spawner_cell)
		return
	if agent_manager and agent_manager.has_method("detach_agent_flow"):
		agent_manager.call("detach_agent_flow", nav_id)
	var path_world: PackedVector2Array = _path_cells_to_world(path_cells, nav_id, true)
	if agent_manager and agent_manager.has_method("assign_agent_path"):
		agent_manager.call("assign_agent_path", nav_id, path_world)
	_entry_path_agents.erase(nav_id)
	_set_astar_in_agent(nav_id, {
		"node": agent,
		"plant_cell": target_plant_cell,
		"spawner_cell": spawner_cell,
		"garden_id": garden_id,
		"path_world": path_world
	})
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
		# Grab a nearby counter's rose before the full A* path completes and leave early.
		if _try_client_early_counter_fetch(agent):
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
		# Counter access tile: grab a rose if the counter still has stock, otherwise
		# retarget (another monster emptied it first) — same "arrive, check, retarget"
		# contract as an already-eaten plant.
		if _counter_access_cells.has(plant_cell):
			_erase_astar_in_agent(nav_id)
			var counter_cell: Vector2i = _counter_access_cells[plant_cell] as Vector2i
			if _counter_stock(counter_cell) <= 0:
				_retarget_agent_or_escape(agent, spawner_cell)
			elif _agent_kind(agent) == SPAWNER_KIND_CLIENT:
				_start_client_counter_payment(agent, counter_cell)
			else:
				_consume_counter_rose(agent, spawner_cell, plant_cell)
			continue
		if plant_manager and plant_manager.has_method("has_plant") and not bool(plant_manager.call("has_plant", plant_cell)):
			_erase_astar_in_agent(nav_id)
			_retarget_agent_or_escape(agent, spawner_cell)
			continue
		_erase_astar_in_agent(nav_id)
		_consume_plant(agent, spawner_cell, plant_cell)
	for nav_id in finished:
		_erase_astar_in_agent(nav_id)

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
	_erase_astar_in_agent(nav_id)
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

# --- _astar_in_agents mutation funnel + target-plant reverse index --------------
# All inserts into / erasures from _astar_in_agents go through these two helpers so
# _astar_in_agents_by_target_plant and _astar_in_target_by_nav_id stay in lock-step.
func _set_astar_in_agent(nav_id: int, data: Dictionary) -> void:
	_astar_in_agents[nav_id] = data
	var target_cell: Vector2i = data.get("plant_cell", INVALID_CELL) as Vector2i
	_register_astar_in_target(nav_id, target_cell)

func _erase_astar_in_agent(nav_id: int) -> void:
	_astar_in_agents.erase(nav_id)
	_unregister_astar_in_target(nav_id)

func _register_astar_in_target(nav_id: int, target_cell: Vector2i) -> void:
	_unregister_astar_in_target(nav_id)
	if target_cell == INVALID_CELL:
		return
	_astar_in_target_by_nav_id[nav_id] = target_cell
	if not _astar_in_agents_by_target_plant.has(target_cell):
		_astar_in_agents_by_target_plant[target_cell] = {}
	var bucket: Dictionary = _astar_in_agents_by_target_plant[target_cell] as Dictionary
	bucket[nav_id] = true

func _unregister_astar_in_target(nav_id: int) -> void:
	if not _astar_in_target_by_nav_id.has(nav_id):
		return
	var target_cell: Vector2i = _astar_in_target_by_nav_id[nav_id] as Vector2i
	_astar_in_target_by_nav_id.erase(nav_id)
	if not _astar_in_agents_by_target_plant.has(target_cell):
		return
	var bucket: Dictionary = _astar_in_agents_by_target_plant[target_cell] as Dictionary
	bucket.erase(nav_id)
	if bucket.is_empty():
		_astar_in_agents_by_target_plant.erase(target_cell)

# NARROW retarget for content-only plant removal. Only handles agents whose A*-in
# target was the exact removed plant; it does NOT broad-retarget the garden, does
# NOT rebuild routes, and does NOT recompute entry points. _entry_path_agents is
# deliberately left alone (the garden is still alive with other plants, or it
# became empty — and the empty case is handled separately by
# _handle_garden_became_empty). The eater that just consumed the plant is already
# in _eating_agents (not _astar_in_agents), so it is never disturbed here.
func _retarget_agents_targeting_removed_plant_only(cell: Vector2i, garden_id: int) -> void:
	_last_plant_retarget_astar_in = _astar_in_agents.size()
	_last_plant_retarget_bucket = 0
	_last_plant_retarget_affected = 0
	_last_plant_retarget_queued = 0
	_last_plant_retarget_stale = 0
	_last_plant_retarget_already_queued = 0
	# Side-effect call: _garden_has_edible_plants flags a now-empty garden into the
	# pending-empty set, which _drain_pending_empty_gardens() (at the end of this func)
	# acts on. The boolean result is no longer needed for branching — every affected
	# agent is deferred to the budgeted queue regardless — but the call must stay.
	if garden_id > 0:
		_garden_has_edible_plants(garden_id)
	# Reverse index lookup: only the agents heading for THIS exact plant, not a scan
	# over every A*-in agent. Usually 0-2 entries. Snapshot the bucket keys first
	# because _retarget_agent_or_escape / queueing mutate the index underneath us.
	if _astar_in_agents_by_target_plant.has(cell):
		var bucket: Dictionary = _astar_in_agents_by_target_plant[cell] as Dictionary
		var nav_ids: Array = bucket.keys()
		_last_plant_retarget_bucket = nav_ids.size()
		for raw_nav_id in nav_ids:
			var nav_id: int = int(raw_nav_id)
			# --- Strict validation. A bucket entry is only "affected" if the live
			# record agrees on every axis. Any disagreement is stale: unregister it so
			# the same dirty entry can never be counted twice across removals. ---
			if not _astar_in_agents.has(nav_id):
				# No longer in A*-in (already retargeted/ate/escaped/freed elsewhere).
				_unregister_astar_in_target(nav_id)
				_last_plant_retarget_stale += 1
				continue
			if (_astar_in_target_by_nav_id.get(nav_id, INVALID_CELL) as Vector2i) != cell:
				# Reverse map no longer points this nav_id at `cell` — the bucket entry
				# is a leftover. Drop it; the nav_id (if still A*-in) is correctly
				# bucketed under its real target by _astar_in_target_by_nav_id.
				bucket.erase(nav_id)
				if bucket.is_empty():
					_astar_in_agents_by_target_plant.erase(cell)
				_last_plant_retarget_stale += 1
				continue
			var data: Dictionary = _astar_in_agents[nav_id] as Dictionary
			var plant_cell: Vector2i = data.get("plant_cell", INVALID_CELL) as Vector2i
			if plant_cell != cell:
				# Live record disagrees with the index: trust the record, re-sync the
				# index to it, and treat this bucket entry as stale.
				_register_astar_in_target(nav_id, plant_cell)
				_last_plant_retarget_stale += 1
				continue
			var raw_agent: Variant = data.get("node", null)
			if not is_instance_valid(raw_agent):
				# Agent freed without going through the funnel: scrub and skip.
				_erase_astar_in_agent(nav_id)
				_last_plant_retarget_stale += 1
				continue
			var agent: Node2D = raw_agent as Node2D
			if agent == null:
				_erase_astar_in_agent(nav_id)
				_last_plant_retarget_stale += 1
				continue
			# Validated: this agent is genuinely A*-in toward the removed plant.
			_last_plant_retarget_affected += 1
			var spawner_cell: Vector2i = data.get("spawner_cell", INVALID_CELL) as Vector2i
			# Detach the stale A*-in path and forget the phase before reassigning.
			if agent_manager and agent_manager.has_method("detach_agent_path"):
				agent_manager.call("detach_agent_path", nav_id)
			_erase_astar_in_agent(nav_id)
			if agent.has_method("stop_astar_in"):
				agent.call("stop_astar_in")
			if spawner_cell == INVALID_CELL and agent.has_meta("spawner_cell"):
				spawner_cell = agent.get_meta("spawner_cell") as Vector2i
			# Always defer through the budgeted queue. Per-agent retarget is "cheap" only
			# in isolation: _retarget_agent_or_escape runs a radius scan + per-candidate
			# path validation (~ms each). When a single plant removal frees a whole bucket
			# (e.g. 5 agents all heading for the same plant), retargeting them all
			# synchronously here spikes the frame to 15-20ms. The budgeted queue spreads
			# that same work across frames at garden_retarget_budget_ms/frame. Whether the
			# garden still has edible plants only affects what the queued retarget resolves
			# to (a fresh plant vs. an escape) — not whether it must run this frame.
			if _queue_agent_for_garden_retarget(nav_id, agent, "retarget", spawner_cell, garden_id):
				_last_plant_retarget_queued += 1
			else:
				_last_plant_retarget_already_queued += 1
	# Optional consistency check: replay the old full scan and warn on any mismatch.
	# OFF by default — it reintroduces the very O(all A*-in) cost the index removes.
	if _debug_check_retarget_index:
		_assert_retarget_index_matches_scan(cell)
	# A stale-empty garden may have been flagged by _garden_has_edible_plants above;
	# this function does not iterate _gardens, so draining now is safe.
	_drain_pending_empty_gardens()

# Debug-only: confirm the reverse index would have found exactly the agents the old
# full scan would have. Runs only when _debug_check_retarget_index is set. NOTE: this
# is called AFTER the affected agents have already been erased, so the live scan
# should find none of them; we instead verify no A*-in agent still claims `cell`.
func _assert_retarget_index_matches_scan(cell: Vector2i) -> void:
	var leftover: int = 0
	for raw_nav_id in _astar_in_agents.keys():
		var nav_id: int = int(raw_nav_id)
		var data: Dictionary = _astar_in_agents[nav_id] as Dictionary
		if (data.get("plant_cell", INVALID_CELL) as Vector2i) == cell:
			leftover += 1
	if leftover > 0:
		push_warning("debug_garden_lag:retarget_index_mismatch plant=%s leftover_astar_in_targeting_cell=%d (index missed them)" % [str(cell), leftover])

func _consume_plant(eater: Node2D, _spawner_cell: Vector2i, plant_cell: Vector2i) -> void:
	var consume_us: int = Time.get_ticks_usec()
	if _agent_kind(eater) == SPAWNER_KIND_CLIENT:
		_start_client_payment(eater, plant_cell)
		_debug_telemetry.warn_garden_task_lag_us("_consume_plant", Time.get_ticks_usec() - consume_us,
			"client plant=%s" % str(plant_cell))
		return
	_start_agent_eating(eater, _eating_time, plant_cell)
	Sfx.play_sound(&"crunsh")
	# plant_manager.consume_plant() fires _on_plant_removed synchronously (garden
	# content update + narrow retarget / empty handling), so it is the prime suspect
	# for an eat-triggered spike. Time it on its own.
	if plant_manager and plant_manager.has_method("consume_plant"):
		var remove_us: int = Time.get_ticks_usec()
		plant_manager.call("consume_plant", plant_cell)
		_debug_telemetry.warn_garden_task_lag_us("_consume_plant.remove_plant", Time.get_ticks_usec() - remove_us,
			"plant=%s" % str(plant_cell))
	elif plantz:
		var source_id: int = plantz.get_cell_source_id(plant_cell)
		var alternative_tile: int = plantz.get_cell_alternative_tile(plant_cell)
		plantz.set_cell(plant_cell, source_id, PlantManager.DEBRIS_ATLAS, alternative_tile)
		_flush_plant_layer_visuals()
	_debug_telemetry.warn_garden_task_lag_us("_consume_plant", Time.get_ticks_usec() - consume_us,
		"plant=%s" % str(plant_cell))


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
	for raw_nav_id: Variant in _client_counter_agents.keys():
		var nav_id: int = int(raw_nav_id)
		if not _client_counter_agents.has(nav_id):
			continue
		var data: Dictionary = _client_counter_agents[nav_id] as Dictionary
		var raw_agent: Variant = data.get("node", null)
		if not is_instance_valid(raw_agent):
			_client_counter_agents.erase(nav_id)
			continue
		if not (agent_manager and agent_manager.has_method("agent_path_arrived")):
			continue
		if not bool(agent_manager.call("agent_path_arrived", nav_id)):
			continue
		var agent: Node2D = raw_agent as Node2D
		if agent == null:
			_client_counter_agents.erase(nav_id)
			continue
		var counter_cell: Vector2i = data.get("counter_cell", INVALID_CELL) as Vector2i
		_client_counter_agents.erase(nav_id)
		if agent.has_method("stop_astar_in"):
			agent.call("stop_astar_in")
		if _counter_stock(counter_cell) <= 0:
			_client_tantrum.begin()
			continue
		_start_client_counter_payment(agent, counter_cell)


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
	var nav_id: int = int(agent.get("nav_id"))
	_client_counter_agents.erase(nav_id)
	_assign_agent_to_escape(agent)


# Opportunistic counter grab: a client still walking toward the garden entrance (flow-in)
# or toward a counter access tile (A*-in) that passes within EARLY_COUNTER_FETCH_TILE_FACTOR
# tiles of a stocked counter's access tile grabs its rose there and leaves — no need to
# finish the walk. Returns true when the client fetched (and is now escaping) so the caller
# skips its normal arrival handling for this agent. Cheap: monsters bail on the kind check,
# and clients only run the nearest-counter lookup while some counter actually holds stock.
func _try_client_early_counter_fetch(agent: Node2D) -> bool:
	if _agent_kind(agent) != SPAWNER_KIND_CLIENT:
		return false
	if _total_counter_stock() <= 0:
		return false
	var agent_cell: Vector2i = floorz.local_to_map(floorz.to_local(agent.global_position))
	var target: Dictionary = _select_stocked_counter_target(agent_cell)
	if target.is_empty():
		return false
	var access_cell: Vector2i = target.get("target_cell", INVALID_CELL) as Vector2i
	var counter_cell: Vector2i = target.get("counter_cell", INVALID_CELL) as Vector2i
	if access_cell == INVALID_CELL or counter_cell == INVALID_CELL:
		return false
	var tile_dimensions: Vector2 = _tile_size()
	var reach: float = maxf(tile_dimensions.x, tile_dimensions.y) * EARLY_COUNTER_FETCH_TILE_FACTOR
	if agent.global_position.distance_to(_cell_center(access_cell)) > reach:
		return false
	_start_client_counter_payment(agent, counter_cell)
	return true


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
	_client_counter_agents.clear()


func clear_agent_navigation_records(nav_id: int) -> void:
	_entry_path_agents.erase(nav_id)
	_erase_astar_in_agent(nav_id)
	_escaping_agents.erase(nav_id)
	_client_counter_agents.erase(nav_id)


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
			_decide_after_eating(nav_id, agent, data)

func _decide_after_eating(nav_id: int, agent: Node2D, data: Dictionary) -> void:
	if not is_instance_valid(agent):
		return
	var roses_eaten: int = int(data.get("roses_eaten", 1))
	var garden_id: int = int(data.get("garden_id", 0))
	var spawner_cell: Vector2i = data.get("spawner_cell", INVALID_CELL) as Vector2i
	if spawner_cell == INVALID_CELL and agent.has_meta("spawner_cell"):
		spawner_cell = agent.get_meta("spawner_cell") as Vector2i
	if garden_id <= 0 and agent.has_meta("garden_id"):
		garden_id = int(agent.get_meta("garden_id"))

	if roses_eaten >= _number_of_roses_before_satiety:
		_escape_finished_eater(nav_id, agent)
		return

	if garden_id > 0 and _garden_has_target_for_kind(garden_id, _agent_kind(agent)):
		agent.set_meta("garden_id", garden_id)
		if spawner_cell != INVALID_CELL:
			agent.set_meta("spawner_cell", spawner_cell)
		_start_astar_in(agent, spawner_cell)
		_drain_pending_empty_gardens()
		return
	_drain_pending_empty_gardens()

	if _same_garden_only:
		_escape_finished_eater(nav_id, agent)
		return

	var retarget_garden_id: int = int(agent.get_meta("garden_id")) if agent.has_meta("garden_id") else garden_id
	if _queue_agent_for_garden_retarget(nav_id, agent, "retarget", spawner_cell, retarget_garden_id):
		return
	_escape_finished_eater(nav_id, agent)

func _escape_finished_eater(nav_id: int, agent: Node2D) -> void:
	# Direct wallexit-FF escape is the ONLY post-eating escape path. Every real
	# exit wall already has a flow field covering the whole walkable map (floor
	# minus walls; plant/garden cells are normal walkable cells), so a finished
	# eater attaches straight to the nearest reachable escape FF — no garden-exit
	# selection, no per-agent A* out of the garden.
	if _assign_agent_to_escape(agent):
		eat_exit_direct_ff_success += 1
		return
	eat_exit_direct_ff_failed += 1
	# Should be rare: a walkable plant cell with no covering exit-wall FF means FF
	# coverage/walkability is wrong and must be fixed there, not papered over with
	# an A*-out fallback. Park the agent safely and warn.
	var fb_cell: Vector2i = floorz.local_to_map(floorz.to_local(agent.global_position)) if floorz else INVALID_CELL
	push_warning("direct_wallexit_ff_escape_failed nav_id=%d cell=%s" % [nav_id, fb_cell])
	var fb_spawner: Vector2i = agent.get_meta("spawner_cell") as Vector2i if agent.has_meta("spawner_cell") else INVALID_CELL
	var fb_garden: int = int(agent.get_meta("garden_id")) if agent.has_meta("garden_id") else 0
	_queue_agent_for_garden_retarget(nav_id, agent, "escape", fb_spawner, fb_garden)

func _erase_eating_agent(nav_id: int) -> void:
	_eating_agents.erase(nav_id)

func _start_agent_eating(agent: Node2D, seconds: float, plant_cell: Vector2i = INVALID_CELL) -> void:
	var nav_id: int = int(agent.get("nav_id"))
	# Carry the garden/spawner/plant context so an empty-garden event can find this
	# eater and queue it for escape without a full rebuild (see _agent_referenced_
	# garden_id / _handle_garden_became_empty).
	var garden_id: int = int(agent.get_meta("garden_id")) if agent.has_meta("garden_id") else 0
	var spawner_cell: Vector2i = agent.get_meta("spawner_cell") as Vector2i if agent.has_meta("spawner_cell") else INVALID_CELL
	var roses_eaten: int = int(agent.get_meta("roses_eaten")) if agent.has_meta("roses_eaten") else 0
	roses_eaten += 1
	agent.set_meta("roses_eaten", roses_eaten)
	_eating_agents[nav_id] = {
		"node": agent,
		"timer": seconds,
		"garden_id": garden_id,
		"spawner_cell": spawner_cell,
		"plant_cell": plant_cell,
		"roses_eaten": roses_eaten
	}
	if agent_manager and agent_manager.has_method("detach_agent_flow"):
		agent_manager.call("detach_agent_flow", nav_id)
	if agent_manager and agent_manager.has_method("detach_agent_path"):
		agent_manager.call("detach_agent_path", nav_id)
	_entry_path_agents.erase(nav_id)
	_erase_astar_in_agent(nav_id)
	if agent.has_method("start_eating"):
		agent.call("start_eating", seconds)

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
	if not agent_manager or not agent_manager.has_method("assign_agent"):
		return false
	var linked_spawner_cell: Vector2i = INVALID_CELL
	if agent.has_meta("spawner_cell"):
		linked_spawner_cell = agent.get_meta("spawner_cell") as Vector2i
	if linked_spawner_cell != INVALID_CELL and _spawner_routes.has(linked_spawner_cell):
		var linked_route: Dictionary = _spawner_routes[linked_spawner_cell] as Dictionary
		if bool(linked_route.get("has_bound_exit", false)) and bool(linked_route.get("escape_ready", false)):
			var linked_group: int = int(linked_route.get("escape_group", -1))
			var linked_target: Vector2i = linked_route.get("escape_wall_target_cell", linked_spawner_cell) as Vector2i
			if linked_group > IDLE_GROUP and linked_target != INVALID_CELL:
				return _attach_agent_to_escape(agent, linked_group, linked_target, linked_spawner_cell)
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
	_erase_astar_in_agent(nav_id)
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
		# A paused merchant is frozen by the player standing next to it; never let it
		# reach/vanish at the exit while held (that would end the phase behind the shop).
		if _seed_merchant.is_paused_agent(agent):
			continue
		var target_cell: Vector2i = data.get("target_cell", INVALID_CELL) as Vector2i
		if target_cell != INVALID_CELL and _agent_within_tiles(agent, target_cell, 1):
			_remove_escaped_monster(agent)
			arrived.append(nav_id)

	for nav_id in arrived:
		_escaping_agents.erase(nav_id)
		_erase_eating_agent(nav_id)

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
	_garden_retarget_queued.erase(nav_id)
	for index: int in range(_garden_retarget_queue.size() - 1, -1, -1):
		var item: Dictionary = _garden_retarget_queue[index]
		if int(item.get("nav_id", -1)) == nav_id:
			_garden_retarget_queue.remove_at(index)


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
	_walkable_map_tiles.clear()
	if floorz == null:
		return
	for raw_cell in floorz.get_used_cells():
		var cell: Vector2i = raw_cell
		if _is_walkable(cell):
			_walkable_map_tiles[cell] = true

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
	if _plant_zone_built:
		return
	_build_gardens_from_plants()
	_validate_dirty_gardens()

func _rebuild_plant_zone_from_layer() -> void:
	# Full topology rebuild (plant added, walls changed, etc.). Each phase is timed
	# separately so a rebuild spike points at clustering vs geometry vs route cache.
	var rebuild_us: int = Time.get_ticks_usec()
	var t: int = Time.get_ticks_usec()
	_build_gardens_from_plants()
	_debug_telemetry.warn_garden_task_lag_us("_build_gardens_from_plants", Time.get_ticks_usec() - t,
		"gardens=%d" % _gardens.size())
	t = Time.get_ticks_usec()
	_validate_dirty_gardens()
	_debug_telemetry.warn_garden_task_lag_us("_validate_dirty_gardens", Time.get_ticks_usec() - t,
		"gardens=%d" % _gardens.size())
	t = Time.get_ticks_usec()
	_rebuild_spawner_garden_route_cache()
	_debug_telemetry.warn_garden_task_lag_us("_rebuild_spawner_garden_route_cache", Time.get_ticks_usec() - t,
		"spawners=%d" % _spawner_garden_routes.size())
	# Garden ids/topology just changed: cheaply detect agents now pointing at a
	# deleted/empty garden, park them in "waiting_new_status", and queue them for
	# budgeted retargeting over the next frames. No pathfinding happens here.
	t = Time.get_ticks_usec()
	_queue_agents_after_garden_rebuild()
	_debug_telemetry.warn_garden_task_lag_us("_queue_agents_after_garden_rebuild", Time.get_ticks_usec() - t,
		"retarget_queue=%d" % _garden_retarget_queue.size())
	_debug_telemetry.warn_garden_task_lag_us("_rebuild_plant_zone_from_layer", Time.get_ticks_usec() - rebuild_us,
		"gardens=%d" % _gardens.size())

func _build_gardens_from_plants() -> void:
	if _gardens_iter_depth > 0:
		push_warning("GARDEN-CRASH-GUARD: full rebuild requested mid-iteration (depth=%d)!" % _gardens_iter_depth)
	_gardens.clear()
	_garden_by_plant_cell.clear()
	_counter_access_cells.clear()
	_dirty_gardens.clear()
	_pending_empty_gardens.clear()
	_clear_garden_entry_resolve_cache("build_gardens")
	# Do NOT reset _next_garden_id: ids must stay monotonic across rebuilds so a new
	# garden can never reuse a previous garden's id (which would let a stale route
	# falsely match). Bump the epoch so every route from a prior rebuild is stale.
	_gardens_epoch += 1
	if plant_manager == null or not plant_manager.has_method("get_plant_cells"):
		_rebuild_plant_zone_compatibility_cache()
		_plant_zone_built = true
		return
	var plant_cells_from_manager: Array = plant_manager.call("get_plant_cells") as Array
	# Stocked counters join the same clustering as flowers, so their access tiles merge
	# generically into nearby gardens (and nearby counters into one garden).
	var eatable_cells: Array = plant_cells_from_manager.duplicate()
	eatable_cells.append_array(_collect_counter_access_cells())
	_cluster_plants_by_walkable_reachability(eatable_cells)
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
		if not _is_walkable(cell):
			continue
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
		_debug_telemetry.log("garden erase id=%d reason=%s gardens_now=%d" % [garden_id, reason, _gardens.size() - 1])
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
	# Dirty gardens get their geometry (incl. entry_cells) recomputed below, which
	# can change scored entry selection, so the memoized resolution is stale.
	_clear_garden_entry_resolve_cache("validate_dirty_gardens")
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
	# Routes are rebuilt against current entries; drop the memoized entry resolution
	# so retargets after this re-score against the refreshed topology.
	_clear_garden_entry_resolve_cache("rebuild_route_cache")
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
		var route: Dictionary = _get_or_create_spawner_garden_route(spawner_cell, garden_id)
		if not bool(route.get("ready", false)):
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


func _select_garden_for_client_spawner(spawner_cell: Vector2i) -> int:
	var best_garden_id: int = 0
	var best_dist: int = 2147483647
	_gardens_iter_depth += 1
	for raw_garden_id: Variant in _gardens.keys():
		var garden_id: int = int(raw_garden_id)
		var garden: Dictionary = _gardens[garden_id] as Dictionary
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
	_gardens_iter_depth -= 1
	if best_garden_id > 0 and not _gardens.has(best_garden_id):
		return 0
	return best_garden_id

func _select_spawner_garden_for_agent(from_cell: Vector2i, agent_kind: StringName = SPAWNER_KIND_MONSTER) -> Dictionary:
	var best_pair: Dictionary = {}
	var best_dist: int = 2147483647
	# Reset the per-resolve cache tallies; each _nearest_garden_entry below adds in.
	_garden_entry_resolve_hits = 0
	_garden_entry_resolve_misses = 0
	_gardens_iter_depth += 1
	for raw_spawner_cell in _spawners.keys():
		var spawner_cell: Vector2i = raw_spawner_cell
		if (_spawner_kind_by_cell.get(spawner_cell, SPAWNER_KIND_MONSTER) as StringName) != agent_kind:
			continue
		if not _spawner_routes.has(spawner_cell):
			continue
		for raw_garden_id in _gardens.keys():
			var garden_id: int = int(raw_garden_id)
			var garden: Dictionary = _gardens[garden_id] as Dictionary
			if not bool(garden.get("targetable", false)):
				continue
			if not _garden_has_target_for_kind(garden_id, agent_kind):
				continue
			var entry_cell: Vector2i = _nearest_garden_entry(garden_id, spawner_cell)
			if _garden_entry_resolve_cache_hit:
				_garden_entry_resolve_hits += 1
			else:
				_garden_entry_resolve_misses += 1
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
	_gardens_iter_depth -= 1
	_drain_pending_empty_gardens()
	# The chosen garden may have just been drained as empty; drop the stale pair.
	if not best_pair.is_empty() and not _gardens.has(int(best_pair.get("garden_id", 0))):
		return {}
	return best_pair

func _select_spawner_for_garden_from_cell(garden_id: int, from_cell: Vector2i, fallback_spawner_cell: Vector2i, agent_kind: StringName = SPAWNER_KIND_MONSTER) -> Vector2i:
	var best_spawner_cell: Vector2i = INVALID_CELL
	var best_dist: int = 2147483647
	for raw_spawner_cell in _spawners.keys():
		var spawner_cell: Vector2i = raw_spawner_cell
		if (_spawner_kind_by_cell.get(spawner_cell, SPAWNER_KIND_MONSTER) as StringName) != agent_kind:
			continue
		if not _spawner_routes.has(spawner_cell):
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
	if best_spawner_cell == INVALID_CELL and fallback_spawner_cell != INVALID_CELL and _spawner_routes.has(fallback_spawner_cell):
		if (_spawner_kind_by_cell.get(fallback_spawner_cell, SPAWNER_KIND_MONSTER) as StringName) != agent_kind:
			return INVALID_CELL
		var fallback_route: Dictionary = _get_or_create_spawner_garden_route(fallback_spawner_cell, garden_id)
		if _nearest_garden_entry(garden_id, fallback_spawner_cell) != INVALID_CELL and bool(fallback_route.get("ready", false)):
			best_spawner_cell = fallback_spawner_cell
	return best_spawner_cell

func _find_local_retarget_plant(from_cell: Vector2i, agent_kind: StringName = SPAWNER_KIND_MONSTER) -> Dictionary:
	# Start fresh so the parent breakdown never reads a stale plant/path profile when
	# this returns early (or isn't reached at all this retarget).
	_last_find_local_retarget_profile = {}
	if empty_garden_local_retarget_radius <= 0:
		return {}
	if plant_manager == null or not plant_manager.has_method("has_plant"):
		return {}
	# This scans a radius around from_cell and runs _find_path_in_zone per candidate,
	# so it can spike when the radius is large or many candidates path. The path checks
	# are the prime suspect, so we aggregate counts (NO per-candidate arrays/logs) and
	# the total time spent in path checks, and warn on those separately. A single
	# per-candidate path check is logged only if it alone exceeds the threshold.
	# This is the only place that loops _find_path_in_zone during a retarget, so reset
	# its accumulator here; each path query below adds into it for the parent breakdown.
	_reset_find_path_in_zone_accum()
	var local_us: int = Time.get_ticks_usec()
	var radius: int = maxi(0, empty_garden_local_retarget_radius)
	var best_target: Dictionary = {}
	var best_path_len: int = 2147483647
	var best_dist: int = 2147483647
	# Aggregate counters only — cheap ints, no growing collections.
	var cells_scanned: int = 0          # cells visited inside the manhattan disc
	var plant_candidates: int = 0       # cells that actually held a plant
	var rejected_no_garden: int = 0     # plant cell not mapped to a garden
	var rejected_not_edible: int = 0    # garden has no edible plants
	var path_checks: int = 0            # _find_path_in_zone calls made
	var path_failures: int = 0          # path checks that returned empty
	var path_checks_us: int = 0         # total time spent in path checks
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var manhattan: int = abs(dx) + abs(dy)
			if manhattan > radius:
				continue
			cells_scanned += 1
			var plant_cell: Vector2i = from_cell + Vector2i(dx, dy)
			if agent_kind == SPAWNER_KIND_CLIENT:
				if not _is_client_target_cell(plant_cell):
					continue
			elif not _is_eatable_for_monster(plant_cell):
				continue
			plant_candidates += 1
			if not _garden_by_plant_cell.has(plant_cell):
				rejected_no_garden += 1
				continue
			var garden_id: int = int(_garden_by_plant_cell[plant_cell])
			if not _garden_has_target_for_kind(garden_id, agent_kind):
				rejected_not_edible += 1
				continue
			# Per-candidate path check. Time each one so a single dominating check is
			# attributable; only log the individual check when it alone spikes.
			var check_us: int = Time.get_ticks_usec()
			var path_cells: PackedVector2Array = _find_path_in_zone(from_cell, plant_cell, garden_id)
			var this_check_us: int = Time.get_ticks_usec() - check_us
			path_checks += 1
			path_checks_us += this_check_us
			if _debug_telemetry.over_garden_threshold_us(this_check_us):
				_debug_telemetry.warn_garden_task_lag_us("_find_local_retarget_plant.path_check", this_check_us,
					"from=%s to=%s garden=%d len=%d" % [str(from_cell), str(plant_cell), garden_id, path_cells.size()])
			if path_cells.is_empty():
				path_failures += 1
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
	var total_us: int = Time.get_ticks_usec() - local_us
	var found: bool = not best_target.is_empty()
	# Stash the aggregate profile for the parent breakdown (cheap int writes; read by
	# _try_local_retarget_agent and the consolidated _retarget_agent_or_escape line).
	_last_find_local_retarget_profile = {
		"radius": radius,
		"cells_checked": cells_scanned,
		"candidates_found": plant_candidates,
		"rejected_wrong_garden": rejected_no_garden,
		"rejected_not_edible": rejected_not_edible,
		"path_checks": path_checks,
		"path_failures": path_failures,
		"path_checks_total_us": path_checks_us,
		"total_us": total_us,
		"success": found,
	}
	# Aggregate path-check total: when this dominates, the cost is the repeated
	# _find_path_in_zone calls rather than the candidate scan itself. Both summary
	# warnings build their context only on a real spike (this runs in a tight retarget
	# loop, so unconditional formatting would be the wrong kind of overhead).
	if _debug_telemetry.over_garden_threshold_us(path_checks_us):
		_debug_telemetry.warn_garden_task_lag_us("_find_local_retarget_plant.path_checks_total", path_checks_us,
			"path_checks=%d failures=%d" % [path_checks, path_failures])
	if _debug_telemetry.over_garden_threshold_us(total_us):
		push_warning("debug_garden_lag_breakdown:_find_local_retarget_plant total=%.1fms threshold=%dms from=%s radius=%d cells_checked=%d candidates=%d wrong_garden=%d not_edible=%d path_checks=%d path_fail=%d path_checks_total=%.1fms success=%s" % [
			float(total_us) / 1000.0, int(_debug_telemetry.garden_lag_threshold_ms()), str(from_cell),
			radius, cells_scanned, plant_candidates,
			rejected_no_garden, rejected_not_edible, path_checks, path_failures,
			float(path_checks_us) / 1000.0, str(found)
		])
	if not best_target.is_empty() and not _gardens.has(int(best_target.get("garden_id", 0))):
		return {}
	return best_target

# Fills _last_local_retarget_profile at every exit so the parent breakdown can show
# the local-retarget split (candidate search vs. path validation vs. assignment, plus
# candidate/path-check counts) even when this whole call is below threshold. The
# per-section .candidate_search / .assignment warnings are kept for the case where one
# section alone spikes; this function also emits its own consolidated breakdown line
# when its total exceeds threshold.
# Sub-sections:
#   candidate_search - radius scan + plant/garden filtering (search minus path checks)
#   path_validation  - the per-candidate _find_path_in_zone calls
#   assignment       - detach + assign_agent_path + phase-dict bookkeeping
func _try_local_retarget_agent(agent: Node2D, from_cell: Vector2i, spawner_cell: Vector2i) -> bool:
	var total_us: int = Time.get_ticks_usec()
	var nav_id_dbg: int = int(agent.get("nav_id"))
	_last_local_retarget_profile = {
		"candidates": 0,
		"path_checks": 0,
		"candidate_search_us": 0,
		"path_validation_us": 0,
		"assignment_us": 0,
		"success": false,
	}
	var search_us: int = Time.get_ticks_usec()
	var target: Dictionary = _find_local_retarget_plant(from_cell, _agent_kind(agent))
	var search_elapsed: int = Time.get_ticks_usec() - search_us
	# Split the search time: path validation (the find_path calls) vs. the rest of the
	# scan. Counts/path-check time come from the plant-search profile filled just above.
	var fl: Dictionary = _last_find_local_retarget_profile
	var path_validation_us: int = int(fl.get("path_checks_total_us", 0))
	_last_local_retarget_profile["candidates"] = int(fl.get("candidates_found", 0))
	_last_local_retarget_profile["path_checks"] = int(fl.get("path_checks", 0))
	_last_local_retarget_profile["path_validation_us"] = path_validation_us
	_last_local_retarget_profile["candidate_search_us"] = maxi(0, search_elapsed - path_validation_us)
	_debug_telemetry.warn_garden_task_lag_us("_try_local_retarget_agent.candidate_search", search_elapsed,
		"nav_id=%d from=%s found=%s" % [nav_id_dbg, str(from_cell), str(not target.is_empty())])
	if target.is_empty():
		_finish_local_retarget_profile(nav_id_dbg, from_cell, total_us, false)
		return false
	var plant_cell: Vector2i = target.get("plant_cell", INVALID_CELL) as Vector2i
	var garden_id: int = int(target.get("garden_id", 0))
	var path_cells: PackedVector2Array = target.get("path_cells", PackedVector2Array()) as PackedVector2Array
	if plant_cell == INVALID_CELL or garden_id <= 0 or path_cells.is_empty():
		_finish_local_retarget_profile(nav_id_dbg, from_cell, total_us, false)
		return false
	var route_spawner_cell: Vector2i = _select_spawner_for_garden_from_cell(garden_id, from_cell, spawner_cell, _agent_kind(agent))
	if route_spawner_cell == INVALID_CELL:
		_finish_local_retarget_profile(nav_id_dbg, from_cell, total_us, false)
		return false
	var assign_us: int = Time.get_ticks_usec()
	var nav_id: int = int(agent.get("nav_id"))
	if agent_manager and agent_manager.has_method("detach_agent_flow"):
		agent_manager.call("detach_agent_flow", nav_id)
	var path_world: PackedVector2Array = _path_cells_to_world(path_cells, nav_id, true)
	if agent_manager and agent_manager.has_method("assign_agent_path"):
		agent_manager.call("assign_agent_path", nav_id, path_world)
	_entry_path_agents.erase(nav_id)
	_set_astar_in_agent(nav_id, {
		"node": agent,
		"plant_cell": plant_cell,
		"spawner_cell": route_spawner_cell,
		"garden_id": garden_id,
		"path_world": path_world
	})
	agent.set_meta("spawner_cell", route_spawner_cell)
	agent.set_meta("garden_id", garden_id)
	# Record the entry tile once it is known valid so the in-garden entry is tracked.
	var in_entry_cell: Vector2i = _nearest_garden_entry(garden_id, route_spawner_cell)
	if in_entry_cell != INVALID_CELL:
		agent.set_meta("garden_entry_cell", in_entry_cell)
	if agent.has_method("start_astar_in"):
		agent.call("start_astar_in")
	var assignment_elapsed: int = Time.get_ticks_usec() - assign_us
	_last_local_retarget_profile["assignment_us"] = assignment_elapsed
	_debug_telemetry.warn_garden_task_lag_us("_try_local_retarget_agent.assignment", assignment_elapsed,
		"nav_id=%d garden=%d plant=%s path_len=%d" % [nav_id, garden_id, str(plant_cell), path_cells.size()])
	_finish_local_retarget_profile(nav_id_dbg, from_cell, total_us, true)
	return true

# Stamp the local-retarget total + success and emit a consolidated breakdown line when
# this attempt alone exceeds threshold. (The parent reads _last_local_retarget_profile
# directly for its own line, so this is only for the local-spike case.)
func _finish_local_retarget_profile(nav_id: int, from_cell: Vector2i, total_start_us: int, success: bool) -> void:
	var total_us: int = Time.get_ticks_usec() - total_start_us
	_last_local_retarget_profile["success"] = success
	_last_local_retarget_profile["total_us"] = total_us
	if not _debug_telemetry.over_garden_threshold_us(total_us):
		return
	var p: Dictionary = _last_local_retarget_profile
	push_warning("debug_garden_lag_breakdown:_try_local_retarget_agent total=%.1fms nav_id=%d from=%s success=%s candidates=%d path_checks=%d candidate_search=%.1fms path_validation=%.1fms assign=%.1fms" % [
		float(total_us) / 1000.0, nav_id, str(from_cell), str(success),
		int(p.get("candidates", 0)), int(p.get("path_checks", 0)),
		float(p.get("candidate_search_us", 0)) / 1000.0,
		float(p.get("path_validation_us", 0)) / 1000.0,
		float(p.get("assignment_us", 0)) / 1000.0,
	])

func _assign_agent_to_garden_entry_flow(agent: Node2D, spawner_cell: Vector2i, garden_id: int, entry_cell: Vector2i) -> bool:
	if not is_instance_valid(agent):
		return false
	if entry_cell == INVALID_CELL or not _is_sane_cell(entry_cell):
		return false
	if agent_manager == null or not agent_manager.has_method("assign_agent"):
		return false
	var nav_id: int = int(agent.get("nav_id"))
	var route: Dictionary = _get_or_create_spawner_garden_route(spawner_cell, garden_id)
	if not bool(route.get("ready", false)):
		return false
	var plant_group: int = int(route.get("plant_group", -1))
	if plant_group <= IDLE_GROUP:
		return false
	if agent_manager.has_method("detach_agent_flow"):
		agent_manager.call("detach_agent_flow", nav_id)
	if agent_manager.has_method("detach_agent_path"):
		agent_manager.call("detach_agent_path", nav_id)
	agent_manager.call("assign_agent", agent, plant_group)
	_entry_path_agents[nav_id] = {
		"node": agent,
		"spawner_cell": spawner_cell,
		"garden_id": garden_id,
		"entry_cell": entry_cell,
		"plant_group": plant_group
	}
	_erase_astar_in_agent(nav_id)
	_escaping_agents.erase(nav_id)
	agent.set_meta("spawner_cell", spawner_cell)
	agent.set_meta("garden_id", garden_id)
	agent.set_meta("garden_entry_cell", entry_cell)
	if agent.has_method("start_flow_in"):
		agent.call("start_flow_in")
	return true

func _spawner_garden_route_flow_ready(route: Dictionary, spawner_cell: Vector2i) -> bool:
	var plant_group: int = int(route.get("plant_group", -1))
	if plant_group <= IDLE_GROUP:
		return false
	return _group_flow_is_ready_at_world(plant_group, _cell_center(spawner_cell))

func _get_or_create_spawner_garden_route(spawner_cell: Vector2i, garden_id: int) -> Dictionary:
	if not _spawner_garden_routes.has(spawner_cell):
		_spawner_garden_routes[spawner_cell] = {}
	var routes: Dictionary = _spawner_garden_routes[spawner_cell] as Dictionary
	var existing_route: Dictionary = routes.get(garden_id, {}) as Dictionary
	if int(existing_route.get("plant_group", -1)) > IDLE_GROUP and _garden_route_is_current(existing_route, garden_id):
		existing_route["ready"] = _spawner_garden_route_flow_ready(existing_route, spawner_cell)
		routes[garden_id] = existing_route
		_spawner_garden_routes[spawner_cell] = routes
		_route_cache_hits += 1
		return existing_route
	# Cache miss: recompute the route (nearest garden entry + sanity checks) below.
	_route_cache_misses += 1
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
	if agent_manager == null or not agent_manager.has_method("create_group"):
		return {"ready": false}
	var plant_group: int = int(existing_route.get("plant_group", -1))
	if plant_group <= IDLE_GROUP:
		plant_group = int(agent_manager.call("create_group"))
	if plant_group <= IDLE_GROUP:
		return {"ready": false}
	_request_group_flow_rebuild(plant_group, entry_world)
	var route: Dictionary = {
		"entry_cell": entry_cell,
		"entry_world": entry_world,
		"plant_group": plant_group,
		"ready": _spawner_garden_route_flow_ready({"plant_group": plant_group}, spawner_cell),
		"flow_requested": true,
		"garden_version": int(garden.get("version", 0)),
		"garden_epoch": int(garden.get("epoch", -1))
	}
	routes[garden_id] = route
	_spawner_garden_routes[spawner_cell] = routes
	return route

# Returns true once the agent has a real new nav state (a garden entry flow, or a
# successfully assigned escape). Returns false only when neither a garden route nor
# an escape could be assigned, so the budgeted queue can requeue it. Every escape
# fallback below propagates _assign_agent_to_escape's own success/failure.
#
# Parent-triggered breakdown: _impl accumulates every inner section's time into a
# fresh _last_retarget_profile (cheap int writes, no per-section warnings). Here, when
# the total exceeds threshold, we emit ONE "debug_garden_lag_breakdown" line with the
# full section split — so a 16-18ms total whose cost is spread across several
# sub-threshold sections is still fully explained on a single line.
func _retarget_agent_or_escape(agent: Node2D, spawner_cell: Vector2i) -> bool:
	if not is_instance_valid(agent):
		return false
	var retarget_us: int = Time.get_ticks_usec()
	var nav_id_dbg: int = int(agent.get("nav_id"))
	var assigned: bool = _retarget_agent_or_escape_impl(agent, spawner_cell)
	var total_us: int = Time.get_ticks_usec() - retarget_us
	if _debug_telemetry.over_garden_threshold_us(total_us):
		_emit_retarget_breakdown(nav_id_dbg, assigned, total_us)
	return assigned

# Build and push the single consolidated breakdown line. Reads the section timings
# accumulated by _impl (_last_retarget_profile) plus the local-retarget and path-zone
# profiles filled by the child functions. Only called when over threshold, so the
# (larger) string is built only on a real spike.
func _emit_retarget_breakdown(nav_id: int, assigned: bool, total_us: int) -> void:
	var p: Dictionary = _last_retarget_profile
	var lr: Dictionary = _last_local_retarget_profile
	var fpz: Dictionary = _find_path_in_zone_accum
	var entry_cache_misses: int = int(p.get("entry_cache_misses", 0))
	var msg: String = "nav_id=%d assigned=%s reason=%s lookup=%.1fms resolve=%.1fms local_retarget=%.1fms escape=%.1fms assign=%.1fms entry_cache_hit=%s entry_cache_hits=%d entry_cache_misses=%d entry_cache_size=%d" % [
		nav_id, str(assigned), str(p.get("reason", "")),
		float(p.get("lookup_us", 0)) / 1000.0,
		float(p.get("resolve_us", 0)) / 1000.0,
		float(p.get("local_retarget_us", 0)) / 1000.0,
		float(p.get("escape_us", 0)) / 1000.0,
		float(p.get("assign_us", 0)) / 1000.0,
		str(entry_cache_misses == 0),
		int(p.get("entry_cache_hits", 0)),
		entry_cache_misses,
		int(p.get("entry_cache_size", 0)),
	]
	# Local-retarget detail (filled only when the local attempt actually ran).
	if not lr.is_empty():
		msg += " local_candidates=%d local_path_checks=%d local_search=%.1fms local_path_validation=%.1fms local_assign=%.1fms local_success=%s" % [
			int(lr.get("candidates", 0)), int(lr.get("path_checks", 0)),
			float(lr.get("candidate_search_us", 0)) / 1000.0,
			float(lr.get("path_validation_us", 0)) / 1000.0,
			float(lr.get("assignment_us", 0)) / 1000.0,
			str(lr.get("success", false)),
		]
	# Path-in-zone aggregate (across every _find_path_in_zone call this retarget).
	if int(fpz.get("call_count", 0)) > 0:
		msg += " path_calls=%d path_total=%.1fms path_sync=%.1fms path_blockers=%.1fms path_find=%.1fms max_path=%.1fms max_path_from=%s max_path_to=%s max_zone_tiles=%d" % [
			int(fpz.get("call_count", 0)),
			float(fpz.get("total_us", 0)) / 1000.0,
			float(fpz.get("sync_zone_total_us", 0)) / 1000.0,
			float(fpz.get("blocker_total_us", 0)) / 1000.0,
			float(fpz.get("find_path_total_us", 0)) / 1000.0,
			float(fpz.get("max_single_call_us", 0)) / 1000.0,
			str(fpz.get("max_single_call_from", INVALID_CELL)),
			str(fpz.get("max_single_call_to", INVALID_CELL)),
			int(fpz.get("max_zone_tiles", 0)),
		]
	var threshold_ms: float = _debug_telemetry.garden_lag_threshold_ms()
	push_warning("debug_garden_lag_breakdown:_retarget_agent_or_escape total=%.1fms threshold=%dms %s" % [
		float(total_us) / 1000.0, int(threshold_ms), msg
	])

# Reset all retarget profiling accumulators at the start of a retarget. Cheap; keeps a
# stale profile from a previous (possibly different code path) retarget out of the next
# breakdown line.
func _reset_retarget_profile() -> void:
	_last_retarget_profile = {
		"reason": "",
		"lookup_us": 0,
		"resolve_us": 0,
		"local_retarget_us": 0,
		"escape_us": 0,
		"assign_us": 0,
		"entry_cache_hits": 0,
		"entry_cache_misses": 0,
		"entry_cache_size": 0,
	}
	_last_local_retarget_profile = {}
	_last_find_local_retarget_profile = {}
	_reset_find_path_in_zone_accum()

# The path-zone accumulator is reset at the start of the local plant search (the only
# place that loops _find_path_in_zone during retarget) so its aggregate reflects just
# that retarget's path queries.
func _reset_find_path_in_zone_accum() -> void:
	_find_path_in_zone_accum = {
		"call_count": 0,
		"total_us": 0,
		"sync_zone_total_us": 0,
		"blocker_total_us": 0,
		"find_path_total_us": 0,
		"max_single_call_us": 0,
		"max_single_call_from": INVALID_CELL,
		"max_single_call_to": INVALID_CELL,
		"max_zone_tiles": 0,
	}

# Sub-detectors (all gated on debug_gardens_lag_ms via debug telemetry) are
# kept for the case where ONE section alone spikes. The accumulated section timings in
# _last_retarget_profile are what feed the consolidated parent breakdown above.
#   .validity       - is_instance_valid + no_plants_remaining gate + from_cell resolve
#   .local_retarget - _try_local_retarget_agent (radius scan + per-candidate paths)
#   .target_resolve - _select_spawner_garden_for_agent + route lookup/entry resolution
#   .escape         - _assign_agent_to_escape fallback (whichever branch reaches it)
#   .final_assign   - _assign_agent_to_garden_entry_flow + set_agent_never_rest
func _retarget_agent_or_escape_impl(agent: Node2D, spawner_cell: Vector2i) -> bool:
	_reset_retarget_profile()
	var t_val: int = Time.get_ticks_usec()
	if not is_instance_valid(agent):
		return false
	var nav_id_dbg: int = int(agent.get("nav_id"))
	var agent_kind: StringName = _agent_kind(agent)
	# Agent validity / target precondition: no valid targets left -> straight to escape.
	var no_plants: bool = _no_targets_remaining_for_kind(agent_kind)
	var from_cell: Vector2i = INVALID_CELL
	if not no_plants:
		from_cell = floorz.local_to_map(floorz.to_local(agent.global_position))
	var lookup_us: int = Time.get_ticks_usec() - t_val
	_last_retarget_profile["lookup_us"] = lookup_us
	_debug_telemetry.warn_garden_task_lag_us("_retarget_agent_or_escape.validity", lookup_us,
		"nav_id=%d no_plants=%s" % [nav_id_dbg, str(no_plants)])
	if no_plants:
		_last_retarget_profile["reason"] = "no_plants"
		var t_esc0: int = Time.get_ticks_usec()
		var esc0: bool = _assign_agent_to_escape(agent)
		var esc0_us: int = Time.get_ticks_usec() - t_esc0
		_last_retarget_profile["escape_us"] = esc0_us
		_debug_telemetry.warn_garden_task_lag_us("_retarget_agent_or_escape.escape", esc0_us,
			"nav_id=%d reason=no_plants assigned=%s" % [nav_id_dbg, str(esc0)])
		return esc0

	# Local retarget attempt: radius scan around the agent + per-candidate path checks.
	var local_us: int = Time.get_ticks_usec()
	var local_ok: bool = _try_local_retarget_agent(agent, from_cell, spawner_cell)
	var local_retarget_us: int = Time.get_ticks_usec() - local_us
	_last_retarget_profile["local_retarget_us"] = local_retarget_us
	_debug_telemetry.warn_garden_task_lag_us("_retarget_agent_or_escape.local_retarget", local_retarget_us,
		"nav_id=%d from=%s ok=%s" % [nav_id_dbg, str(from_cell), str(local_ok)])
	if local_ok:
		_last_retarget_profile["reason"] = "local_retarget"
		return true

	# Current garden / target resolution: pick a (spawner, garden) pair and resolve its
	# entry route. Cheap normally, but timed so a slow _select_spawner_garden_for_agent
	# or route recompute is attributable rather than lumped into the parent total.
	var t_res: int = Time.get_ticks_usec()
	var pair: Dictionary = _select_spawner_garden_for_agent(from_cell, agent_kind)
	# Cache stats for this resolve (set by _select_spawner_garden_for_agent's loop).
	_last_retarget_profile["entry_cache_hits"] = _garden_entry_resolve_hits
	_last_retarget_profile["entry_cache_misses"] = _garden_entry_resolve_misses
	_last_retarget_profile["entry_cache_size"] = _garden_entry_resolve_cache.size()
	if pair.is_empty():
		if spawner_cell == INVALID_CELL:
			spawner_cell = _nearest_spawner_cell(from_cell)
		if spawner_cell != INVALID_CELL and _spawner_routes.has(spawner_cell):
			agent.set_meta("spawner_cell", spawner_cell)
		_last_retarget_profile["resolve_us"] = Time.get_ticks_usec() - t_res
		_debug_telemetry.warn_garden_task_lag_us("_retarget_agent_or_escape.target_resolve", int(_last_retarget_profile["resolve_us"]),
			"nav_id=%d pair=empty" % nav_id_dbg)
		return _escape_with_detector(agent, nav_id_dbg, "no_pair")
	spawner_cell = pair.get("spawner_cell", INVALID_CELL) as Vector2i
	var garden_id: int = int(pair.get("garden_id", 0))
	if garden_id <= 0:
		_last_retarget_profile["resolve_us"] = Time.get_ticks_usec() - t_res
		_debug_telemetry.warn_garden_task_lag_us("_retarget_agent_or_escape.target_resolve", int(_last_retarget_profile["resolve_us"]),
			"nav_id=%d garden=0" % nav_id_dbg)
		return _escape_with_detector(agent, nav_id_dbg, "garden<=0")
	var route: Dictionary = _get_or_create_spawner_garden_route(spawner_cell, garden_id)
	if not bool(route.get("ready", false)):
		_last_retarget_profile["resolve_us"] = Time.get_ticks_usec() - t_res
		_debug_telemetry.warn_garden_task_lag_us("_retarget_agent_or_escape.target_resolve", int(_last_retarget_profile["resolve_us"]),
			"nav_id=%d garden=%d route_not_ready" % [nav_id_dbg, garden_id])
		return _escape_with_detector(agent, nav_id_dbg, "route_not_ready")
	var entry_cell: Vector2i = route.get("entry_cell", INVALID_CELL) as Vector2i
	if entry_cell == INVALID_CELL:
		_last_retarget_profile["resolve_us"] = Time.get_ticks_usec() - t_res
		_debug_telemetry.warn_garden_task_lag_us("_retarget_agent_or_escape.target_resolve", int(_last_retarget_profile["resolve_us"]),
			"nav_id=%d garden=%d no_entry" % [nav_id_dbg, garden_id])
		return _escape_with_detector(agent, nav_id_dbg, "no_entry")
	var resolve_us: int = Time.get_ticks_usec() - t_res
	_last_retarget_profile["resolve_us"] = resolve_us
	_debug_telemetry.warn_garden_task_lag_us("_retarget_agent_or_escape.target_resolve", resolve_us,
		"nav_id=%d garden=%d entry=%s" % [nav_id_dbg, garden_id, str(entry_cell)])

	# Final assignment section: attach the garden-entry flow leg.
	var t_fin: int = Time.get_ticks_usec()
	var assigned: bool = _assign_agent_to_garden_entry_flow(agent, spawner_cell, garden_id, entry_cell)
	var fin_us: int = Time.get_ticks_usec() - t_fin
	_last_retarget_profile["assign_us"] = fin_us
	_debug_telemetry.warn_garden_task_lag_us("_retarget_agent_or_escape.final_assign", fin_us,
		"nav_id=%d garden=%d entry=%s assigned=%s" % [nav_id_dbg, garden_id, str(entry_cell), str(assigned)])
	if not assigned:
		return _escape_with_detector(agent, nav_id_dbg, "entry_flow_failed")
	_last_retarget_profile["reason"] = "garden_entry"
	var nav_id: int = int(agent.get("nav_id"))
	if agent_manager.has_method("set_agent_never_rest"):
		agent_manager.call("set_agent_never_rest", nav_id, true)
	return true

# Escape fallback wrapped with its own sub-detector so a slow _assign_agent_to_escape
# is attributed to .escape (with the branch reason) instead of the parent total. Also
# accumulates the escape time + reason into the parent breakdown profile.
func _escape_with_detector(agent: Node2D, nav_id_dbg: int, reason: String) -> bool:
	var t_esc: int = Time.get_ticks_usec()
	var esc: bool = _assign_agent_to_escape(agent)
	var esc_us: int = Time.get_ticks_usec() - t_esc
	_last_retarget_profile["escape_us"] = esc_us
	_last_retarget_profile["reason"] = "escape:" + reason
	_debug_telemetry.warn_garden_task_lag_us("_retarget_agent_or_escape.escape", esc_us,
		"nav_id=%d reason=%s assigned=%s" % [nav_id_dbg, reason, str(esc)])
	return esc

# ---------------------------------------------------------------------------
# Budgeted retargeting after a garden topology rebuild.
#
# A rebuild clears _gardens and bumps the epoch, so any agent still holding a
# garden_id from before can be referencing a deleted/empty garden. Re-pathing all
# of them in the rebuild frame risks a large spike, so we split the work:
#   1. _queue_agents_after_garden_rebuild() — one-shot, cheap. Detects affected
#      agents, detaches their stale path/flow, parks them in "waiting_new_status",
#      and queues them. NO pathfinding here.
#   2. _process_garden_retarget_queue() — runs each frame, time-budgeted by
#      garden_retarget_budget_ms (with garden_retarget_budget_per_frame as a hard
#      count cap), doing the expensive re-path/escape.
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
# Returns true if the agent was newly enqueued this call, false if it was already
# queued or could not be queued (invalid nav_id/agent). Callers use this to keep
# accurate queued-vs-already-queued bookkeeping.
func _queue_agent_for_garden_retarget(nav_id: int, agent: Node2D, intent: String, spawner_cell: Vector2i, garden_id: int) -> bool:
	if nav_id < 0 or not is_instance_valid(agent):
		return false
	if _garden_retarget_queued.has(nav_id):
		return false
	# Cheaply detach stale path/flow so the agent stops following an invalid route
	# immediately. The real re-route happens later in the budgeted queue.
	if agent_manager and agent_manager.has_method("detach_agent_path"):
		agent_manager.call("detach_agent_path", nav_id)
	if agent_manager and agent_manager.has_method("detach_agent_flow"):
		agent_manager.call("detach_agent_flow", nav_id)
	_entry_path_agents.erase(nav_id)
	_erase_astar_in_agent(nav_id)
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
	return true

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
		# agents that were eating should head for the exit, everyone else retargets.
		var intent: String = "retarget"
		if _eating_agents.has(nav_id):
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
	# (retarget). Agents mid-eat are intentionally left untouched (see below) so they
	# finish their eating delay before self-escaping.
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
	# Agents mid-eat are deliberately NOT touched here. A garden empties precisely
	# because an eater consumed its last plant (see _consume_plant: start_eating runs,
	# then remove_plant fires this synchronously while the eater sits in _eating_agents).
	# Pulling them out now would abort the eating delay and make the final eater leave
	# instantly. Instead they finish their timer and self-escape via _process_eating_
	# agents, whose exit-wall FF escape does not depend on the garden still existing.
	# Meta-only fallback: agents that lost their phase entry but still carry this
	# garden in meta (e.g. mid-transition). Scan the monsters group once.
	for node in get_tree().get_nodes_in_group("monsters"):
		if not (node is Node2D):
			continue
		var agent: Node2D = node
		var nav_id: int = int(agent.get("nav_id"))
		if nav_id < 0 or _garden_retarget_queued.has(nav_id):
			continue
		# Same rule as above: never disturb an agent that is currently eating.
		if _eating_agents.has(nav_id):
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
		_erase_astar_in_agent(nav_id)
		_erase_eating_agent(nav_id)
		return
	var spawner_cell: Vector2i = INVALID_CELL
	if _entry_path_agents.has(nav_id):
		spawner_cell = (_entry_path_agents[nav_id] as Dictionary).get("spawner_cell", INVALID_CELL) as Vector2i
	elif _astar_in_agents.has(nav_id):
		spawner_cell = (_astar_in_agents[nav_id] as Dictionary).get("spawner_cell", INVALID_CELL) as Vector2i
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
		# Eating agents finish their delay and self-escape via _process_eating_agents;
		# queueing them here would abort the eating timer (the last-plant case).
		if _eating_agents.has(nav_id):
			continue
		# Already escaping (and not eating): leave it alone, it has a valid exit route.
		if _escaping_agents.has(nav_id):
			continue
		var spawner_cell: Vector2i = INVALID_CELL
		if agent.has_meta("spawner_cell"):
			spawner_cell = agent.get_meta("spawner_cell") as Vector2i
		var garden_id: int = 0
		if agent.has_meta("garden_id"):
			garden_id = int(agent.get_meta("garden_id"))
		_queue_agent_for_garden_retarget(nav_id, agent, "escape", spawner_cell, garden_id)


func _force_escape_for_all_monsters() -> void:
	for node: Node in get_tree().get_nodes_in_group("monsters"):
		var agent: Node2D = node as Node2D
		if agent == null or not is_instance_valid(agent):
			continue
		var nav_id: int = int(agent.get("nav_id"))
		if nav_id < 0 or _drowning_controller.is_drowning(nav_id) or _escaping_agents.has(nav_id):
			continue
		_garden_retarget_queued.erase(nav_id)
		for index: int in range(_garden_retarget_queue.size() - 1, -1, -1):
			var item: Dictionary = _garden_retarget_queue[index]
			if int(item.get("nav_id", -1)) == nav_id:
				_garden_retarget_queue.remove_at(index)
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
	if _garden_retarget_queue.is_empty():
		return 0
	var start_us: int = Time.get_ticks_usec()
	var budget_us: int = int(garden_retarget_budget_ms * 1000.0)
	var count_cap: int = garden_retarget_budget_per_frame
	var processed: int = 0
	while not _garden_retarget_queue.is_empty():
		# Hard upper bound on expensive retargets per frame.
		if processed >= count_cap:
			break
		# Time budget is the primary limiter: once we've done at least one expensive
		# retarget and spent the budget, stop. When budget_us <= 0 this collapses to
		# "one expensive retarget per frame" — the safest non-spiking fallback.
		if processed > 0:
			if budget_us <= 0:
				break
			if Time.get_ticks_usec() - start_us >= budget_us:
				break
		var item: Dictionary = _garden_retarget_queue.pop_front() as Dictionary
		var nav_id: int = int(item.get("nav_id", -1))
		_garden_retarget_queued.erase(nav_id)
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
		processed += 1
	return processed

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
	var single_us: int = Time.get_ticks_usec()
	var intent: String = str(item.get("intent", "retarget"))
	var spawner_cell: Vector2i = item.get("spawner_cell", INVALID_CELL) as Vector2i

	var assigned: bool = false
	if intent == "escape":
		assigned = _assign_agent_to_escape(agent)
	else:
		assigned = _retarget_agent_or_escape(agent, spawner_cell)
	_debug_telemetry.warn_garden_task_lag_us("_retarget_single_waiting_agent", Time.get_ticks_usec() - single_us,
		"nav_id=%d intent=%s assigned=%s" % [nav_id, intent, str(assigned)])

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
	return _wall_blockers_for_cells(_plant_zone_tiles)

func _wall_blockers_for_cells(cells: Dictionary) -> PackedVector2Array:
	var blockers: PackedVector2Array = PackedVector2Array()
	if cells.is_empty():
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

	var blocker_layers: Array[TileMapLayer] = [wallz, blocking_buildings]
	for layer: TileMapLayer in blocker_layers:
		if layer == null:
			continue
		for raw_cell: Variant in layer.get_used_cells():
			var c: Vector2i = raw_cell as Vector2i
			if c.x < min_cell.x or c.x > max_cell.x or c.y < min_cell.y or c.y > max_cell.y:
				continue
			if layer == blocking_buildings and not _building_cell_blocks_movement(c):
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
	# .prep: endpoint handling + zone duplicate cost (the duplicate can be the cost
	# when a garden's zone_tiles dictionary is large and both endpoints are outside).
	# Sub-warnings are gated on debug telemetry thresholds so the context string is
	# built only on a real spike — _find_path_in_zone is called in tight retarget
	# loops, so unconditional formatting here would be the wrong kind of overhead.
	var call_start_us: int = Time.get_ticks_usec()
	var prep_us: int = Time.get_ticks_usec()
	var path_tiles: Dictionary = zone_tiles
	if _is_walkable(from_tile) and not zone_tiles.has(from_tile):
		path_tiles = zone_tiles.duplicate()
		path_tiles[from_tile] = true
	if _is_walkable(to_tile) and not path_tiles.has(to_tile):
		if path_tiles == zone_tiles:
			path_tiles = zone_tiles.duplicate()
		path_tiles[to_tile] = true
	if _debug_telemetry.over_garden_threshold_us(Time.get_ticks_usec() - prep_us):
		_debug_telemetry.warn_garden_task_lag_us("_find_path_in_zone.prep", Time.get_ticks_usec() - prep_us,
			"garden=%d zone_tiles=%d from=%s to=%s" % [garden_id, zone_tiles.size(), str(from_tile), str(to_tile)])
	# .sync_zone: pushes the walkable set + wall blockers into the pathfinder.
	var sync_us: int = Time.get_ticks_usec()
	_sync_pathfinder_zone_tiles(path_tiles)
	var sync_elapsed: int = Time.get_ticks_usec() - sync_us
	if _debug_telemetry.over_garden_threshold_us(sync_elapsed):
		_debug_telemetry.warn_garden_task_lag_us("_find_path_in_zone.sync_zone", sync_elapsed,
			"garden=%d zone_tiles=%d from=%s to=%s" % [garden_id, path_tiles.size(), str(from_tile), str(to_tile)])
	# Snap endpoints to walkable tiles if needed (non-walkable endpoints only).
	var start_tile: Vector2i = from_tile if path_tiles.has(from_tile) else _nearest_zone_tile_to(from_tile, path_tiles)
	var end_tile: Vector2i = to_tile if path_tiles.has(to_tile) else _nearest_zone_tile_to(to_tile, path_tiles)
	if start_tile == INVALID_CELL or end_tile == INVALID_CELL:
		_accumulate_find_path_in_zone(call_start_us, sync_elapsed, 0, from_tile, to_tile, path_tiles.size())
		return PackedVector2Array()
	# .find_path: the pathfinder A* itself.
	var find_us: int = Time.get_ticks_usec()
	var result: PackedVector2Array = pathfinder.call("find_path", start_tile, end_tile) as PackedVector2Array
	var find_elapsed: int = Time.get_ticks_usec() - find_us
	if _debug_telemetry.over_garden_threshold_us(find_elapsed):
		_debug_telemetry.warn_garden_task_lag_us("_find_path_in_zone.find_path", find_elapsed,
			"garden=%d from=%s to=%s len=%d" % [garden_id, str(start_tile), str(end_tile), result.size()])
	_accumulate_find_path_in_zone(call_start_us, sync_elapsed, find_elapsed, from_tile, to_tile, path_tiles.size())
	return result

# Fold one _find_path_in_zone call's timings into the per-retarget accumulator (reset
# at the start of the local plant search). Tracks totals + the single most expensive
# call so the parent breakdown can show whether the path cost is spread across many
# calls or dominated by one. Cheap; no per-call warning here.
func _accumulate_find_path_in_zone(call_start_us: int, sync_elapsed: int, find_elapsed: int, from_tile: Vector2i, to_tile: Vector2i, zone_tiles: int) -> void:
	var call_us: int = Time.get_ticks_usec() - call_start_us
	var a: Dictionary = _find_path_in_zone_accum
	a["call_count"] = int(a.get("call_count", 0)) + 1
	a["total_us"] = int(a.get("total_us", 0)) + call_us
	a["sync_zone_total_us"] = int(a.get("sync_zone_total_us", 0)) + sync_elapsed
	a["blocker_total_us"] = int(a.get("blocker_total_us", 0)) + _last_zone_blocker_us
	a["find_path_total_us"] = int(a.get("find_path_total_us", 0)) + find_elapsed
	if call_us > int(a.get("max_single_call_us", 0)):
		a["max_single_call_us"] = call_us
		a["max_single_call_from"] = from_tile
		a["max_single_call_to"] = to_tile
	if zone_tiles > int(a.get("max_zone_tiles", 0)):
		a["max_zone_tiles"] = zone_tiles

func _sync_pathfinder_zone_tiles(zone_tiles: Dictionary) -> void:
	_last_zone_blocker_us = 0
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
		# _wall_blockers_for_cells scans every wall tile against the zone bbox; time it
		# separately since it can dominate sync on a large wall layer. Gated so context
		# is built only on a spike (this runs once per path query). The time is also
		# stashed in _last_zone_blocker_us so the caller can split it out of sync time.
		var blockers_us: int = Time.get_ticks_usec()
		var blockers: PackedVector2Array = _wall_blockers_for_cells(zone_tiles)
		var blocker_elapsed: int = Time.get_ticks_usec() - blockers_us
		_last_zone_blocker_us = blocker_elapsed
		if _debug_telemetry.over_garden_threshold_us(blocker_elapsed):
			_debug_telemetry.warn_garden_task_lag_us("_wall_blockers_for_cells", blocker_elapsed,
				"zone_tiles=%d blockers=%d" % [zone_tiles.size(), blockers.size()])
		pathfinder.call("set_blockers", blockers)

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

func _path_cells_to_world(path_cells: PackedVector2Array, nav_id: int = -1, disperse_endpoint: bool = false) -> PackedVector2Array:
	var out: PackedVector2Array = PackedVector2Array()
	out.resize(path_cells.size())
	var last_index: int = path_cells.size() - 1
	for i in range(path_cells.size()):
		var v: Vector2 = path_cells[i]
		var cell: Vector2i = Vector2i(int(v.x), int(v.y))
		if disperse_endpoint and i == last_index and nav_id >= 0:
			out[i] = _cell_center_with_local_offset(cell, _path_endpoint_local_offset(cell, nav_id))
		else:
			out[i] = _cell_center(cell)
	return out

func _cell_center_with_local_offset(cell: Vector2i, local_offset: Vector2) -> Vector2:
	return floorz.to_global(floorz.map_to_local(cell) + local_offset)

func _path_endpoint_local_offset(cell: Vector2i, nav_id: int) -> Vector2:
	var tile_size: Vector2 = _tile_size()
	var radius: float = min(tile_size.x, tile_size.y) * 0.28
	var h: int = nav_id * 1103515245 + cell.x * 73856093 + cell.y * 19349663
	var slot: int = _positive_mod(h, 12)
	@warning_ignore("integer_division")
	var ring: int = _positive_mod(h / 12, 2)
	var angle: float = (PI * 2.0 * float(slot)) / 12.0
	var ring_scale: float = 0.65 + 0.35 * float(ring)
	return Vector2(cos(angle), sin(angle)) * radius * ring_scale

func _positive_mod(value: int, divisor: int) -> int:
	var r: int = value % divisor
	if r < 0:
		r += divisor
	return r

func _tile_size() -> Vector2:
	if floorz and floorz.tile_set:
		var raw_tile_size: Vector2i = floorz.tile_set.get_tile_size()
		return Vector2(float(raw_tile_size.x), float(raw_tile_size.y))
	return Vector2(32, 32)

func _resolve_plant_target_for_agent_in_garden(from_cell: Vector2i, garden_id: int, agent_kind: StringName = SPAWNER_KIND_MONSTER) -> Vector2i:
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
	if agent_kind == SPAWNER_KIND_CLIENT:
		return _garden_has_client_targets(garden_id)
	return _garden_has_edible_plants(garden_id)


func _no_targets_remaining_for_kind(agent_kind: StringName) -> bool:
	if agent_kind == SPAWNER_KIND_CLIENT:
		return not _has_client_targets_remaining()
	return _no_plants_remaining()


func _has_client_targets_remaining() -> bool:
	if _total_counter_stock() > 0:
		return true
	for raw_garden_id: Variant in _gardens.keys():
		if _garden_has_client_targets(int(raw_garden_id)):
			return true
	return false


func _garden_has_client_targets(garden_id: int) -> bool:
	if not _gardens.has(garden_id):
		return false
	var garden: Dictionary = _gardens[garden_id] as Dictionary
	var plant_cells: Dictionary = garden.get("plant_cells", {}) as Dictionary
	if plant_cells.is_empty():
		return false
	for raw_cell: Variant in plant_cells.keys():
		var cell: Vector2i = raw_cell as Vector2i
		if _is_client_target_cell(cell):
			return true
	return false


func _is_client_target_cell(cell: Vector2i) -> bool:
	if _counter_access_cells.has(cell):
		return _counter_stock(_counter_access_cells[cell] as Vector2i) > 0
	if plant_manager and plant_manager.has_method("has_plant") and not bool(plant_manager.call("has_plant", cell)):
		return false
	return _is_grownup_rose_cell(cell)


func _garden_has_grownup_roses(garden_id: int) -> bool:
	if not _gardens.has(garden_id):
		return false
	var garden: Dictionary = _gardens[garden_id] as Dictionary
	var plant_cells: Dictionary = garden.get("plant_cells", {}) as Dictionary
	if plant_cells.is_empty():
		return false
	for raw_cell: Variant in plant_cells.keys():
		var cell: Vector2i = raw_cell as Vector2i
		if _is_grownup_rose_cell(cell):
			return true
	return false


func _is_grownup_rose_cell(cell: Vector2i) -> bool:
	return plant_manager != null and plant_manager.has_method("is_rose_grownup") and bool(plant_manager.call("is_rose_grownup", cell))

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
		if _is_eatable_for_monster(cell):
			return true
	# plant_cells is non-empty but nothing edible survives (plants eaten, counters
	# emptied): stale cache, genuinely empty. Queue for removal outside iteration.
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
		if debug_logs and CppDebugOptions.logs_enabled:
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

# Clears the memoized garden-entry resolution. Called from every rebuild path
# that can change garden topology, entries, walls, or routes. Cheap (a dict
# clear); the optional reason is only for tracing if we ever log it.
func _clear_garden_entry_resolve_cache(_reason: String = "") -> void:
	_garden_entry_resolve_cache.clear()

func _garden_entry_resolve_cache_key(garden_id: int, from_cell: Vector2i) -> String:
	# Source cell + garden fully determine the scored "enter" entry, so the key
	# includes the spawner/source context (never garden_id alone — that would let
	# monsters from different spawners share a far/bad entry).
	return "%s|%d" % [str(from_cell), garden_id]

func _nearest_garden_entry(garden_id: int, from_cell: Vector2i) -> Vector2i:
	# Memoized: the retarget path calls this once per (spawner, garden) for every
	# agent, and the scored selection is the dominant cost in target_resolve.
	var cache_key: String = _garden_entry_resolve_cache_key(garden_id, from_cell)
	if _garden_entry_resolve_cache.has(cache_key):
		var cached: Vector2i = _garden_entry_resolve_cache[cache_key] as Vector2i
		# Cheap validation before trusting the cached entry. A real INVALID_CELL is a
		# legitimate cached "no entry" result and is reused as-is; only a finite cell
		# is re-checked for garden existence + membership + walkability.
		if cached == INVALID_CELL:
			_garden_entry_resolve_cache_hit = true
			return cached
		if _gardens.has(garden_id):
			var garden: Dictionary = _gardens[garden_id] as Dictionary
			var entry_cells: Array = garden.get("entry_cells", []) as Array
			if entry_cells.has(cached) and _is_walkable(cached):
				_garden_entry_resolve_cache_hit = true
				return cached
		# Stale (garden gone, entry no longer listed, or no longer walkable): drop it
		# and fall through to recompute.
		_garden_entry_resolve_cache.erase(cache_key)
	_garden_entry_resolve_cache_hit = false
	var entry: Vector2i = _select_scored_garden_entry(garden_id, from_cell, "enter")
	_garden_entry_resolve_cache[cache_key] = entry
	return entry

func _nearest_garden_entry_to_exit(garden_id: int, spawner_cell: Vector2i) -> Vector2i:
	var exit_wall_cell: Vector2i = INVALID_CELL
	var spawner_route: Dictionary = _spawner_routes.get(spawner_cell, {}) as Dictionary
	exit_wall_cell = spawner_route.get("exit_wall_cell", INVALID_CELL) as Vector2i
	var escape_group: int = int(spawner_route.get("escape_group", -1))
	if exit_wall_cell == INVALID_CELL:
		return _select_scored_garden_entry(garden_id, spawner_cell, "exit", INVALID_CELL, escape_group)
	return _select_scored_garden_entry(garden_id, exit_wall_cell, "exit", INVALID_CELL, escape_group)
