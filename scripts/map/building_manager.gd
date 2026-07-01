extends Node
class_name BuildingManager

signal startup_loading_progress(progress: float, label: String)
signal startup_loading_finished
signal level_completed

const AGENT_SCENE: PackedScene = preload("res://scenes/entities/character.tscn")
const CLIENT_TEXTURE: Texture2D = preload("res://assets/sprites/legval/client.png")
const MERCHANT_TEXTURE: Texture2D = preload("res://assets/sprites/legval/merchent.png")
const ROSE_TEXTURE: Texture2D = preload("res://assets/sprites/legval/rose.png")
const MONSTER_CORPSE_SCENE: PackedScene = preload("res://scenes/entities/monster_corpse.tscn")
const BUILD_TILES_INDEX_PATH: String = "res://scripts/map/build_tiles_index.tres"
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
const SPAWN_FAILURE_WARN_INTERVAL_MS: int = 3000
const SPAWNER_KIND_MONSTER: StringName = &"monster"
const SPAWNER_KIND_CLIENT: StringName = &"client"
const SPAWNER_KIND_MERCHANT: StringName = &"merchant"
const MONSTER_DEATH_DROP_SEED: StringName = &"seed"
const MONSTER_DEATH_DROP_GEM: StringName = &"gem"
const CLIENT_PAYMENT_SECONDS: float = 1.0
const ROSE_SHOP_COUNTER_ID: String = "rose_shop_counter"
const CLIENT_COUNTER_RADIUS_TILES: int = 2
const SEED_MERCHANT_INTERACT_RADIUS_TILES: int = 2
const HARVEST_ROSE_FLIGHT_SECONDS: float = 0.65
# Chebyshev tile radius around the player from which grown roses can be harvested
# during the morning walkover. 1 = the player's cell plus the surrounding 3x3 ring.
const PLAYER_HARVEST_RADIUS_TILES: int = 1
# Counter rose pile: roses stack in a single vertical column, each one overlapping
# COUNTER_PILE_OVERLAP of the rose below it (0.66 => 66% covered, 34% visible).
const COUNTER_PILE_ROSE_SCALE: float = 0.56
const COUNTER_PILE_ROSE_FRAME_HEIGHT: float = 64.0  # rose.png is 128x64 with hframes=2
const COUNTER_PILE_OVERLAP: float = 0.66
const COUNTER_PILE_BASE_Y: float = -8.0

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

var _tile_defs_by_atlas: Dictionary = {}
var _spawners: Dictionary = {}
var _spawner_kind_by_cell: Dictionary = {}  # Vector2i -> StringName
var _spawner_exit_cell_by_cell: Dictionary = {}  # Vector2i -> Vector2i
var _client_spawners: Dictionary = {}  # Vector2i -> true
var _client_frequency_by_cell: Dictionary = {}  # Vector2i -> float
# Round-robin queue of playlist spawn requests ready to be drained. The playlist
# controller owns wave timing; this queue only spreads spawn+assign work over frames.
var _ready_spawner_queue: Array[Dictionary] = []
var _ready_spawner_queue_set: Dictionary = {}  # playlist track index -> true
var _spawner_routes: Dictionary = {}
var _spawner_garden_routes: Dictionary = {}
# Route-cache hit/miss counters (lifetime-of-process), bumped in
# _get_or_create_spawner_garden_route. Used by the _process_spawners lag detector
# to attribute time to cache misses vs. hits.
var _route_cache_hits: int = 0
var _route_cache_misses: int = 0
# Per-pass count summary for the _process_spawners lag detector. Filled in during
# _process_spawners() and read by the parent warning at the call site. Pure
# instrumentation; never affects spawn behavior.
var _spawn_pass_stats: Dictionary = {}
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
var _turret_eating_agents: Dictionary = {}
var _drowning_agents: Dictionary = {}
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
var _last_wall_signature: int = 0
var _last_water_signature: int = 0
var _last_blocking_signature: int = 0
var _navigation_topology_dirty: bool = true
var _last_scan_summary: String = ""
var _last_spawn_failure: String = ""
var _last_spawn_failure_at_ms: Dictionary = {}
var _flow_ready: bool = false
var _startup_loading_started: bool = false
var _startup_ready: bool = false
var _night_preparing: bool = false
var _night_preparation_ready: bool = false
var _night_preparation_token: int = 0
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

# Day/night state. A completed playlist night returns to day immediately; a night
# that cannot start because there are no plants remains visible briefly before ending.
const EMPTY_NIGHT_DAY_DELAY_SECONDS: float = 3.0
var _empty_night_elapsed: float = 0.0
var _progression: Node = null
var _level_spawn_playlist: LevelSpawnPlaylist
var _level_spawner_bindings: Array[SpawnerBinding] = []
var _loaded_level_scene_path: String = ""
var _spawner_bindings_by_id: Dictionary = {}  # StringName -> Vector2i
var _spawn_playlist_controller: SpawnPlaylistController = SpawnPlaylistController.new()
var _playlist_spawning_enabled: bool = false
var _playlist_spawning_invalid: bool = false
var _playlist_validation_attempted: bool = false
var _current_playlist_night_index: int = -1
var _client_sale_active: bool = false
var _client_sale_pending_spawners: Array[Vector2i] = []
var _client_sale_spawn_timers: Dictionary = {}  # Vector2i -> float
var _client_paying_agents: Dictionary = {}  # nav_id -> Dictionary
var _client_counter_agents: Dictionary = {}  # nav_id -> Dictionary
var _seed_merchant_active: bool = false
var _seed_merchant_agent: Node2D
var _seed_merchant_nav_id: int = -1
var _seed_merchant_counter_cell: Vector2i = INVALID_CELL
var _seed_merchant_target_cell: Vector2i = INVALID_CELL
var _seed_merchant_waiting: bool = false
# True once the merchant is walking back out to an exit. This now only happens when
# night starts; finishing a merchant visit keeps the sprite parked until nightfall.
var _seed_merchant_leaving: bool = false
var _seed_merchant_leave_at_night_pending: bool = false
# True while the merchant is frozen because the player is within interaction range.
# Mirrors the native per-agent pause; cleared when the player walks away so the
# merchant resumes whatever it was doing (walking in, or walking back out).
var _seed_merchant_paused: bool = false
var _counter_stock_by_cell: Dictionary = {}  # Vector2i -> int
var _counter_pile_nodes_by_cell: Dictionary = {}  # Vector2i -> Array[Node2D]
# Walkable tiles adjacent to a stocked counter, each mapped to its counter cell.
# These are fed into the garden clustering as ordinary "plant cells" so a stocked
# counter becomes a kind of garden: monsters path to one of these tiles and eat a
# rose from the counter (decrementing its stock) instead of a plant. Rebuilt every
# time the gardens are (re)built (see _collect_counter_access_cells).
var _counter_access_cells: Dictionary = {}  # access_cell (Vector2i) -> counter_cell (Vector2i)
var _morning_harvest_active: bool = false

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

# Master gate shared by every lag detector: when "Debug Enabled" is off on the
# CPP node, all lag warnings are suppressed (mirrors _is_verbose()). Returns true
# only when the CPP node exists AND its debug_enabled flag is explicitly false.
func _debug_master_disabled() -> bool:
	if _cpp_debug_options == null:
		_cpp_debug_options = _find_cpp_debug_options()
	if _cpp_debug_options and "debug_enabled" in _cpp_debug_options:
		return not bool(_cpp_debug_options.get("debug_enabled"))
	return false

func _frame_lag_threshold_ms() -> float:
	if _debug_master_disabled():
		return 0.0
	if global_config and global_config.has_method("get_debug_nav_frame_lag_ms"):
		return float(global_config.call("get_debug_nav_frame_lag_ms"))
	if global_config and global_config.has_method("get_debug_plantff_frame_lag_ms"):
		return float(global_config.call("get_debug_plantff_frame_lag_ms"))
	return DEBUG_PLANTFF_FRAME_LAG_MS_FALLBACK

func _ff_lag_threshold_ms() -> float:
	if _debug_master_disabled():
		return 0.0
	if global_config and global_config.has_method("get_debug_flowfield_rebuild_lag_ms"):
		return float(global_config.call("get_debug_flowfield_rebuild_lag_ms"))
	if global_config and global_config.has_method("get_debug_plantff_ff_lag_ms"):
		return float(global_config.call("get_debug_plantff_ff_lag_ms"))
	return DEBUG_PLANTFF_FF_LAG_MS_FALLBACK

# ---------------------------------------------------------------------------
# Granular garden/navigation lag instrumentation. The total-frame detector in
# _process() only says "the frame was slow"; these per-task detectors say WHICH
# garden/nav task spiked. Threshold comes from CppDebugOptions.debug_gardens_lag_ms
# (read directly off the node; not pushed to C++). 0 disables per-task warnings.
#
# Overhead discipline: time with get_ticks_usec() and ONLY build the (potentially
# large) context string when the elapsed time is over threshold. Never construct
# context inside hot per-agent loops unless the individual op itself is over.
# ---------------------------------------------------------------------------
const DEBUG_GARDENS_LAG_MS_FALLBACK: float = 15.0

func _find_cpp_debug_options() -> Node:
	# The node is "CPP" in the current scene (same path _is_verbose() uses).
	if not is_inside_tree():
		return null
	var scene: Node = get_tree().get_current_scene()
	if scene == null:
		return null
	var node: Node = scene.get_node_or_null("CPP")
	if node:
		return node
	node = scene.get_node_or_null("CppDebugOptions")
	if node:
		return node
	node = scene.find_child("CppDebugOptions", true, false)
	if node:
		return node
	return null

func _garden_lag_threshold_ms() -> float:
	# Master gate: when "Debug Enabled" is off on the CPP node, suppress the
	# per-task garden-lag warnings entirely (0 = detector disabled).
	if _debug_master_disabled():
		return 0.0
	if _cpp_debug_options == null:
		_cpp_debug_options = _find_cpp_debug_options()
	if _cpp_debug_options and "debug_gardens_lag_ms" in _cpp_debug_options:
		return float(_cpp_debug_options.get("debug_gardens_lag_ms"))
	return DEBUG_GARDENS_LAG_MS_FALLBACK

# Warn when a timed block exceeds the per-task threshold. `elapsed_us` is in
# microseconds (timed with get_ticks_usec()); output is reported in ms. `extra` is
# pre-built context — callers must build it cheaply (it is unconditional here, so
# only pass strings that are cheap to construct, or use the threshold check at the
# call site to gate expensive context). Use _over_garden_threshold_us() to gate
# heavy context construction before calling this.
func _warn_garden_task_lag_us(task_name: String, elapsed_us: int, extra: String = "") -> void:
	var threshold_ms: float = _garden_lag_threshold_ms()
	if threshold_ms <= 0.0:
		return
	var elapsed_ms: float = float(elapsed_us) / 1000.0
	if elapsed_ms <= threshold_ms:
		return
	var suffix: String = ""
	if extra != "":
		suffix = " " + extra
	push_warning("debug_garden_lag:%s %dms (threshold=%dms)%s" % [
		task_name,
		int(round(elapsed_ms)),
		int(threshold_ms),
		suffix
	])

# True when `elapsed_us` is over the per-task threshold. Lets a call site decide
# whether to spend cycles building an expensive context string before calling
# _warn_garden_task_lag_us(); returns false (and skips) when the detector is
# disabled (threshold <= 0).
func _over_garden_threshold_us(elapsed_us: int) -> bool:
	var threshold_ms: float = _garden_lag_threshold_ms()
	if threshold_ms <= 0.0:
		return false
	return (float(elapsed_us) / 1000.0) > threshold_ms

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
	_resolve_level_layers()
	_load_level_spawn_config()
	startup_loading_progress.emit(0.48, "Preparing zones")
	_load_tile_definitions()
	_migrate_special_tiles_from_wallz()
	_setup_plant_manager()
	_setup_building_object_manager()
	_setup_zone_overlay()
	_wait_for_flow_ready()
	GameState.mode_changed.connect(_on_game_mode_changed)
	set_process_input(true)


func _load_level_spawn_config() -> void:
	_level_spawn_playlist = null
	_level_spawner_bindings.clear()
	_loaded_level_scene_path = ""
	var scene: Node = get_tree().current_scene
	if scene == null:
		return
	var loader: Node = scene.get_node_or_null("LevelLoader")
	if loader == null:
		return
	if loader.has_method("get_loaded_level_scene_path"):
		_loaded_level_scene_path = str(loader.call("get_loaded_level_scene_path"))
	if loader.has_method("get_loaded_spawn_playlist"):
		_level_spawn_playlist = loader.call("get_loaded_spawn_playlist") as LevelSpawnPlaylist
	if _level_spawn_playlist == null:
		_level_spawn_playlist = _load_default_spawn_playlist(_loaded_level_scene_path)
	if loader.has_method("get_loaded_spawner_bindings"):
		var raw_bindings: Array = loader.call("get_loaded_spawner_bindings") as Array
		for raw_binding: Variant in raw_bindings:
			var binding: SpawnerBinding = raw_binding as SpawnerBinding
			if binding != null:
				_level_spawner_bindings.append(binding)


func _load_default_spawn_playlist(level_scene_path: String) -> LevelSpawnPlaylist:
	if level_scene_path == "":
		return null
	var playlist_path: String = "res://scenes/levels/playlists/%s_spawn_playlist.tres" % level_scene_path.get_file().get_basename()
	if not ResourceLoader.exists(playlist_path):
		return null
	var resource: Resource = load(playlist_path)
	return resource as LevelSpawnPlaylist

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

func _on_game_mode_changed(is_night: bool) -> void:
	_empty_night_elapsed = 0.0
	_client_preparing = false
	if is_night:
		_client_sale_active = false
		_client_sale_pending_spawners.clear()
		_client_sale_spawn_timers.clear()
		_client_counter_agents.clear()
		_seed_merchant_leave_at_night_pending = _seed_merchant_active and is_instance_valid(_seed_merchant_agent)
		GameState.set_seed_merchant_phase(false)
		GameState.set_building_phase(false)
		_morning_harvest_active = false
		# Roses left on the counters are NOT cleared at nightfall: they persist as
		# edible targets monsters can eat during the night (see the monster-counter
		# logic), and any survivors carry over as sellable stock into the next morning.
	if not is_night:
		_night_preparation_token += 1
		_night_preparing = false
		_night_preparation_ready = false
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
			push_error("BuildingManager: playlist night index %d is invalid; spawning disabled for this night." % (_current_playlist_night_index + 1))
			_playlist_spawning_enabled = false
			_playlist_spawning_invalid = true
		else:
			print("BuildingManager: playlist night started: playable_night=%d total=%d" % [
				_current_playlist_night_index + 1,
				_spawn_playlist_controller.get_total_night_count(),
			])
			for line: String in _spawn_playlist_controller.get_current_night_debug_lines():
				print("BuildingManager: playlist " + line)
	if _playlist_spawning_invalid:
		push_error("BuildingManager: assigned spawn playlist is invalid; spawning remains disabled this night.")
	elif not _playlist_spawning_enabled:
		push_error("BuildingManager: no valid spawn playlist is enabled; spawning remains disabled this night.")
	_ready_spawner_queue.clear()
	_ready_spawner_queue_set.clear()
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
	var slice_started_us: int = Time.get_ticks_usec()
	for raw_spawner_cell: Variant in _spawners.keys():
		if not _night_preparation_is_current(token):
			return
		var spawner_cell: Vector2i = raw_spawner_cell as Vector2i
		_initialize_spawner_route(spawner_cell)
		if Time.get_ticks_usec() - slice_started_us >= _night_preparation_budget_us():
			await get_tree().process_frame
			slice_started_us = Time.get_ticks_usec()

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

	# Do not open the spawn gate until the worker has finished and the native
	# node's process callback has applied every completed field to its group.
	if not flow or not flow.has_method("are_async_flows_idle"):
		push_error("BuildingManager: rebuilt FlowFieldNative is required for safe night preparation")
		return
	while _night_preparation_is_current(token) and not bool(flow.call("are_async_flows_idle")):
		await get_tree().process_frame
	if not _night_preparation_is_current(token):
		return
	if not _night_flow_fields_are_ready():
		push_error("BuildingManager: night flow-field preparation completed with an unusable route")
		return

	_night_preparing = false
	_night_preparation_ready = true
	if _seed_merchant_leave_at_night_pending:
		_start_seed_merchant_leave_for_night()
	print("ff & gardens computed, monster night starts now")


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
	var slice_started_us: int = Time.get_ticks_usec()
	for raw_spawner_cell: Variant in _spawners.keys():
		if not _night_preparation_is_current(token):
			return
		var spawner_cell: Vector2i = raw_spawner_cell as Vector2i
		_initialize_spawner_route(spawner_cell)
		if Time.get_ticks_usec() - slice_started_us >= _night_preparation_budget_us():
			await get_tree().process_frame
			slice_started_us = Time.get_ticks_usec()

	prep_result = await _rebuild_exit_wall_escapes_budgeted(token)
	if not bool(prep_result):
		_abort_client_preparation(token)
		return
	await get_tree().process_frame
	if not _night_preparation_is_current(token):
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

	if not flow or not flow.has_method("are_async_flows_idle"):
		push_error("BuildingManager: rebuilt FlowFieldNative is required for safe client preparation")
		_abort_client_preparation(token)
		return
	while _night_preparation_is_current(token) and not bool(flow.call("are_async_flows_idle")):
		await get_tree().process_frame
	if not _night_preparation_is_current(token):
		return
	if not _night_flow_fields_are_ready():
		push_error("BuildingManager: client flow-field preparation completed with an unusable route")
		_abort_client_preparation(token)
		return

	_client_preparing = false
	_activate_client_sale_phase()


func _abort_client_preparation(token: int) -> void:
	if token != _night_preparation_token:
		return
	if GameState.is_night:
		return
	_client_preparing = false
	_client_sale_active = false
	_client_sale_pending_spawners.clear()
	_client_sale_spawn_timers.clear()
	GameState.set_building_phase(true)

func _night_flow_fields_are_ready() -> bool:
	if not flow or not flow.has_method("group_route_cost_at_world") or not flow.has_method("is_group_flow_request_ready"):
		return false
	for raw_spawner_cell: Variant in _spawners.keys():
		var spawner_cell: Vector2i = raw_spawner_cell as Vector2i
		if not _spawner_routes.has(spawner_cell):
			return false
		var route: Dictionary = _spawner_routes[spawner_cell] as Dictionary
		if not bool(route.get("escape_ready", false)):
			return false
		var group_id: int = int(route.get("escape_group", -1))
		var goal_world: Vector2 = route.get("escape_world", Vector2.ZERO) as Vector2
		if group_id <= IDLE_GROUP or not bool(flow.call("is_group_flow_request_ready", group_id)):
			return false
		var cost: float = float(flow.call("group_route_cost_at_world", group_id, goal_world))
		if not is_finite(cost):
			return false
	for raw_escape: Variant in _exit_wall_escapes.values():
		var escape: Dictionary = raw_escape as Dictionary
		var exit_group_id: int = int(escape.get("escape_group", -1))
		var exit_goal_world: Vector2 = escape.get("escape_world", Vector2.ZERO) as Vector2
		if exit_group_id > IDLE_GROUP:
			if not bool(flow.call("is_group_flow_request_ready", exit_group_id)):
				return false
			var exit_cost: float = float(flow.call("group_route_cost_at_world", exit_group_id, exit_goal_world))
			if not is_finite(exit_cost):
				return false
	return true

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
	if _morning_harvest_active:
		_process_morning_harvest_walkover()
	var frame_start_us: int = Time.get_ticks_usec()
	var t: int = 0
	_scan_timer -= delta
	if _scan_timer <= 0.0:
		_scan_timer = 0.25
		t = Time.get_ticks_usec()
		_scan_buildings()
		_warn_garden_task_lag_us("_scan_buildings", Time.get_ticks_usec() - t,
			"spawners=%d" % _spawners.size())

	if not _dirty_spawner_escapes.is_empty():
		# Capture the count before the call: _drain_dirty_routes clears the dict.
		var dirty_escapes_before: int = _dirty_spawner_escapes.size()
		t = Time.get_ticks_usec()
		_drain_dirty_routes()
		_warn_garden_task_lag_us("_drain_dirty_routes", Time.get_ticks_usec() - t,
			"dirty_escapes=%d" % dirty_escapes_before)

	# Per-frame tasks: gate context construction on _over_garden_threshold_us so the
	# (string-formatting) context is only built on a real spike, never every frame.
	t = Time.get_ticks_usec()
	_process_eating_agents(delta)
	_process_client_paying_agents(delta)
	if _over_garden_threshold_us(Time.get_ticks_usec() - t):
		_warn_garden_task_lag_us("_process_eating_agents", Time.get_ticks_usec() - t,
			"eating=%d astar_in=%d escaping=%d" % [
				_eating_agents.size(), _astar_in_agents.size(),
				_escaping_agents.size()])

	t = Time.get_ticks_usec()
	_process_turret_eating_agents(delta)
	_process_turret_overlaps()
	if _over_garden_threshold_us(Time.get_ticks_usec() - t):
		_warn_garden_task_lag_us("_process_turrets_eaten", Time.get_ticks_usec() - t,
			"turret_eating=%d" % _turret_eating_agents.size())

	t = Time.get_ticks_usec()
	_process_drowning_agents(delta)
	if _over_garden_threshold_us(Time.get_ticks_usec() - t):
		_warn_garden_task_lag_us("_process_drowning_agents", Time.get_ticks_usec() - t,
			"drowning=%d" % _drowning_agents.size())

	t = Time.get_ticks_usec()
	_process_astar_in_arrivals()
	if _over_garden_threshold_us(Time.get_ticks_usec() - t):
		_warn_garden_task_lag_us("_process_astar_in_arrivals", Time.get_ticks_usec() - t,
			"entry=%d astar_in=%d" % [_entry_path_agents.size(), _astar_in_agents.size()])

	t = Time.get_ticks_usec()
	_process_plant_arrivals()
	if _over_garden_threshold_us(Time.get_ticks_usec() - t):
		_warn_garden_task_lag_us("_process_plant_arrivals", Time.get_ticks_usec() - t,
			"astar_in=%d eating=%d" % [_astar_in_agents.size(), _eating_agents.size()])

	t = Time.get_ticks_usec()
	_process_client_counter_arrivals()
	_process_seed_merchant_proximity()
	_process_seed_merchant_arrival()
	if _over_garden_threshold_us(Time.get_ticks_usec() - t):
		_warn_garden_task_lag_us("_process_client_counter_arrivals", Time.get_ticks_usec() - t,
			"counter_agents=%d paying=%d" % [_client_counter_agents.size(), _client_paying_agents.size()])

	t = Time.get_ticks_usec()
	_process_escape_arrivals()
	if _over_garden_threshold_us(Time.get_ticks_usec() - t):
		_warn_garden_task_lag_us("_process_escape_arrivals", Time.get_ticks_usec() - t,
			"escaping=%d" % _escaping_agents.size())

	t = Time.get_ticks_usec()
	var retarget_processed: int = _process_garden_retarget_queue()
	var retarget_elapsed_us: int = Time.get_ticks_usec() - t
	if _over_garden_threshold_us(retarget_elapsed_us):
		_warn_garden_task_lag_us("_process_garden_retarget_queue", retarget_elapsed_us,
			"processed=%d remaining=%d budget=%dms elapsed=%.1fms" % [
				retarget_processed,
				_garden_retarget_queue.size(),
				int(garden_retarget_budget_ms),
				float(retarget_elapsed_us) / 1000.0,
			])

	t = Time.get_ticks_usec()
	_process_spawners(delta)
	_process_client_sale(delta)
	_process_seed_merchant_phase()
	if _over_garden_threshold_us(Time.get_ticks_usec() - t):
		# Context (incl. the per-pass count summary) only built when over threshold.
		_warn_garden_task_lag_us("_process_spawners", Time.get_ticks_usec() - t,
			"spawners=%d processed=%d spawned=%d assigned=%d skipped=%d ready_remaining=%d budget_count=%d budget_ms=%.1f elapsed=%.1fms active_monsters=%d route_cache_hits=%d route_cache_misses=%d" % [
				_spawners.size(),
				int(_spawn_pass_stats.get("processed_spawners", 0)),
				int(_spawn_pass_stats.get("spawned_count", 0)),
				int(_spawn_pass_stats.get("assigned_count", 0)),
				int(_spawn_pass_stats.get("skipped_count", 0)),
				int(_spawn_pass_stats.get("ready_queue_remaining", 0)),
				spawner_budget_per_frame,
				spawner_budget_ms,
				float(_spawn_pass_stats.get("elapsed_ms", 0.0)),
				int(_spawn_pass_stats.get("active_monsters", -1)),
				_route_cache_hits,
				_route_cache_misses,
			])

	t = Time.get_ticks_usec()
	_sync_plant_zone_debug_visibility()
	_warn_garden_task_lag_us("_sync_plant_zone_debug_visibility", Time.get_ticks_usec() - t)

	var frame_us: int = Time.get_ticks_usec() - frame_start_us
	var frame_threshold_ms: float = _frame_lag_threshold_ms()
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
			"kind": str(tile_definition.get("kind", ""))
		}

func _scan_buildings() -> void:
	if not traversable_buildings:
		return

	var t: int = Time.get_ticks_usec()
	var migrated: bool = _migrate_special_tiles_from_wallz()
	_warn_garden_task_lag_us("_migrate_special_tiles_from_wallz", Time.get_ticks_usec() - t,
		"migrated=%s" % str(migrated))

	t = Time.get_ticks_usec()
	var wall_signature: int = _tile_layer_signature(wallz)
	var water_signature: int = _tile_layer_signature(watersources)
	var blocking_signature: int = _tile_layer_signature(blocking_buildings)
	_warn_garden_task_lag_us("_tile_layer_signature", Time.get_ticks_usec() - t,
		"wall_cells=%d water_cells=%d" % [
			wallz.get_used_cells().size() if wallz else 0,
			watersources.get_used_cells().size() if watersources else 0,
		])
	var walls_changed: bool = (
		wall_signature != _last_wall_signature
		or water_signature != _last_water_signature
		or blocking_signature != _last_blocking_signature
		or migrated
	)
	_last_wall_signature = wall_signature
	_last_water_signature = water_signature
	_last_blocking_signature = blocking_signature

	var seen_spawners: Dictionary = {}
	t = Time.get_ticks_usec()
	# Spawners are authored as child nodes in the loaded level's spawner/spawners
	# container. Tile special scanning is kept only for non-spawner legacy markers.
	_scan_configured_spawner_nodes(seen_spawners)
	_scan_special_layer(traversable_buildings, seen_spawners)
	_scan_special_layer(wallz, seen_spawners)
	_warn_garden_task_lag_us("_scan_special_layer", Time.get_ticks_usec() - t,
		"seen_spawners=%d" % seen_spawners.size())
	_log_scan_summary(seen_spawners, migrated, walls_changed)

	for raw_spawner_cell in _spawners.keys():
		var cell: Vector2i = raw_spawner_cell
		if not seen_spawners.has(cell):
			_spawners.erase(cell)
			_release_spawner_route(cell)
			_dirty_spawner_escapes.erase(cell)

	if walls_changed:
		_navigation_topology_dirty = true

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
	_warn_garden_task_lag_us("_rebuild_exit_wall_escapes", Time.get_ticks_usec() - exits_us,
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

func _sync_runtime_state() -> void:
	_scan_buildings()
	_validate_playlist_after_spawner_scan()
	_apply_navigation_topology_rebuild()
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
	print("BuildingManager: spawn playlist enabled for '%s' with %d night(s) and %d spawner binding(s)." % [
		_loaded_level_scene_path,
		_spawn_playlist_controller.get_total_night_count(),
		_spawner_bindings_by_id.size(),
	])
	if debug_logs:
		_log("Configured spawn playlist nights=%d bindings=%d" % [
			_spawn_playlist_controller.get_total_night_count(),
			_spawner_bindings_by_id.size(),
		])


func _valid_monster_types() -> Dictionary:
	return {
		&"basic": true,
	}


func _resolve_monster_scene(monster_type: StringName) -> PackedScene:
	if monster_type == &"basic":
		return AGENT_SCENE
	_log_spawn_failure("unknown monster_type '%s'" % String(monster_type))
	return null

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


func _on_building_added(_cell: Vector2i, item_id: String) -> void:
	if _building_item_blocks_flow(item_id):
		_navigation_topology_dirty = true
	if item_id != ROSE_SHOP_COUNTER_ID:
		return


func _on_building_removed(cell: Vector2i, item_id: String) -> void:
	if _building_item_blocks_flow(item_id):
		_navigation_topology_dirty = true
	if item_id != ROSE_SHOP_COUNTER_ID:
		return
	_counter_stock_by_cell.erase(cell)
	_clear_counter_pile(cell)
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
	if str(item_def.get("target_layer", "")) != "blocking_buildings":
		return false
	return bool(item_def.get("blocks_movement", false)) or bool(item_def.get("isWall", false))

func _on_plant_added(_cell: Vector2i) -> void:
	if not _runtime_agents_active():
		# Daytime placement only dirties the next night's snapshot. In particular,
		# rectangle placement must not rebuild every existing garden per rose.
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
		_warn_garden_task_lag_us("_handle_garden_became_empty", Time.get_ticks_usec() - empty_us,
			"garden=%d retarget_queue=%d" % [garden_id, _garden_retarget_queue.size()])
	else:
		var rt_us: int = Time.get_ticks_usec()
		_retarget_agents_targeting_removed_plant_only(cell, garden_id)
		_warn_garden_task_lag_us("_retarget_agents_targeting_removed_plant_only", Time.get_ticks_usec() - rt_us,
			"garden=%d plant=%s astar_in=%d bucket_size=%d valid_affected=%d queued=%d already_queued=%d stale=%d indexed_targets=%d" % [
				garden_id, str(cell), _last_plant_retarget_astar_in,
				_last_plant_retarget_bucket, _last_plant_retarget_affected,
				_last_plant_retarget_queued, _last_plant_retarget_already_queued,
				_last_plant_retarget_stale, _astar_in_agents_by_target_plant.size()])

	if _zone_overlay:
		_zone_overlay.queue_redraw()

	if _no_plants_remaining():
		_queue_escape_for_all_monsters_budgeted()
	_warn_garden_task_lag_us("_on_plant_removed", Time.get_ticks_usec() - removed_us,
		"garden=%d empty=%s" % [garden_id, str(became_empty)])


func _runtime_agents_active() -> bool:
	return GameState.is_night or _client_sale_active

func _scan_special_layer(layer: TileMapLayer, _seen_spawners: Dictionary) -> void:
	if not layer:
		return

	for raw_cell in layer.get_used_cells():
		var map_cell: Vector2i = raw_cell
		var definition: Dictionary = _definition_for_layer_cell(layer, map_cell)
		var kind: String = str(definition.get("kind", ""))
		if kind == "spawner":
			continue


func _scan_configured_spawner_nodes(seen_spawners: Dictionary) -> void:
	for binding: SpawnerBinding in _level_spawner_bindings:
		if binding == null:
			continue
		if binding.kind != SPAWNER_KIND_MONSTER and binding.kind != SPAWNER_KIND_CLIENT:
			continue
		_log("detected spawner node id=%s cell=%s floor=%s wall=%s" % [
			String(binding.spawner_id),
			binding.cell,
			_has_floor(binding.cell),
			_has_wall(binding.cell),
		])
		seen_spawners[binding.cell] = true
		_register_spawner(binding.cell, binding.kind, binding.exit_cell, binding.frequency_client)

func _migrate_special_tiles_from_wallz() -> bool:
	if not wallz or not traversable_buildings:
		return false

	var migrated: bool = false
	for raw_cell in wallz.get_used_cells():
		var cell: Vector2i = raw_cell
		var definition: Dictionary = _definition_for_layer_cell(wallz, cell)
		var kind: String = str(definition.get("kind", ""))
		if kind == "" or kind == "wall":
			continue
		if kind == "spawner":
			var legacy_atlas: Vector2i = wallz.get_cell_atlas_coords(cell)
			wallz.erase_cell(cell)
			migrated = true
			_log("removed legacy spawner tile cell=%s atlas=%s from wallz; level spawner nodes are used instead" % [
				cell,
				legacy_atlas,
			])
			continue

		var target_layer: TileMapLayer = plantz if kind == "plantsToTarget" else traversable_buildings
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
		traversable_buildings.update_internals()
		if plantz:
			plantz.update_internals()
		wallz.update_internals()
	return migrated

func _definition_for_cell(cell: Vector2i) -> Dictionary:
	return _definition_for_layer_cell(traversable_buildings, cell)

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
	if not layer:
		return {}
	var atlas: Vector2i = layer.get_cell_atlas_coords(cell)
	var atlas_key: String = _atlas_key(atlas)
	return _tile_defs_by_atlas.get(atlas_key, {}) as Dictionary

func _register_spawner(cell: Vector2i, kind: StringName = SPAWNER_KIND_MONSTER, exit_cell: Vector2i = INVALID_CELL, frequency_client: float = 1.0) -> void:
	var is_new: bool = not _spawners.has(cell)
	_spawners[cell] = true
	_spawner_kind_by_cell[cell] = kind
	if exit_cell != INVALID_CELL:
		_spawner_exit_cell_by_cell[cell] = exit_cell
	if kind == SPAWNER_KIND_CLIENT:
		_client_spawners[cell] = true
		_client_frequency_by_cell[cell] = maxf(0.0, frequency_client)
	else:
		_client_spawners.erase(cell)
		_client_frequency_by_cell.erase(cell)
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
	_client_spawners.erase(spawner_cell)
	_client_frequency_by_cell.erase(spawner_cell)

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
	_log("initialized spawner=%s exit_wall=%s escape_target=%s" % [
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
		if use_async_requests:
			_request_group_flow_rebuild(escape_group, escape_world)
		elif flow.has_method("assign_flow_to_group"):
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

func _process_spawners(delta: float) -> void:
	# Reset the per-pass count summary consumed by the parent lag warning. Cheap;
	# always done so the caller never reads a stale dictionary.
	_spawn_pass_stats = {
		"processed_spawners": 0,
		"spawned_count": 0,
		"assigned_count": 0,
		"skipped_count": 0,
		"active_monsters": -1,
		"ready_queue_remaining": 0,
		"elapsed_ms": 0.0,
	}

	# Day/night gating: monsters only spawn at night. When the last monster of
	# the night is gone, automatically flip back to day. _monster_count() scans a
	# scene group (get_nodes_in_group), so time it as a potential offender.
	if not GameState.is_night:
		return
	if not _night_preparation_ready:
		return
	var t_mc: int = Time.get_ticks_usec()
	var mc: int = _monster_count()
	_warn_garden_task_lag_us("_process_spawners.monster_count", Time.get_ticks_usec() - t_mc)
	_spawn_pass_stats["active_monsters"] = mc
	if _playlist_spawning_invalid:
		if mc == 0:
			_empty_night_elapsed += delta
			if _empty_night_elapsed >= EMPTY_NIGHT_DAY_DELAY_SECONDS:
				GameState.start_day()
		return
	if _playlist_spawning_enabled:
		_process_playlist_spawners(delta, mc)
		return
	return


func _process_playlist_spawners(delta: float, active_monsters: int) -> void:
	if _spawn_playlist_controller.is_current_night_schedule_complete():
		if active_monsters == 0:
			GameState.start_day()
		return
	var t_np: int = Time.get_ticks_usec()
	var no_plants: bool = _no_plants_remaining()
	_warn_garden_task_lag_us("_process_spawners.no_plants_remaining", Time.get_ticks_usec() - t_np)
	if no_plants:
		if active_monsters == 0:
			_empty_night_elapsed += delta
			if _empty_night_elapsed >= EMPTY_NIGHT_DAY_DELAY_SECONDS:
				_log("Playlist night stalled because no plants remain; leaving schedule unfinished.")
				GameState.start_day()
				return
		else:
			_empty_night_elapsed = 0.0
		if debug_logs and not _spawners.is_empty():
			_log("no plants remaining for playlist spawners")
		return
	_empty_night_elapsed = 0.0
	_enqueue_playlist_spawn_requests(delta)
	_drain_ready_spawner_queue_budgeted()


func _on_new_day_finished() -> void:
	if GameState.is_night:
		return
	_begin_morning_phase()


func _begin_morning_phase() -> void:
	_client_preparing = false
	_client_sale_active = false
	_client_sale_pending_spawners.clear()
	_client_sale_spawn_timers.clear()
	_client_counter_agents.clear()
	_client_paying_agents.clear()
	_morning_harvest_active = _grownup_rose_count() > 0
	if not _morning_harvest_active:
		_begin_client_sale_phase()
		return
	# Green (watered) roses only open into full-bloom "rose-rose" now, at the start
	# of the harvest phase, so they must become full grown before being harvested.
	if plant_manager != null and plant_manager.has_method("bloom_grownup_roses"):
		plant_manager.call("bloom_grownup_roses")
	GameState.set_morning_phase(true)


func _process_morning_harvest_walkover() -> void:
	if not _morning_harvest_active:
		return
	if plant_manager == null or not plant_manager.has_method("harvest_grownup_rose"):
		return
	var counter_cells: Array[Vector2i] = _rose_shop_counter_cells()
	if counter_cells.is_empty():
		return
	var rose_cell: Vector2i = _player_grownup_rose_cell()
	if rose_cell == INVALID_CELL:
		return
	var target_counter: Vector2i = counter_cells[randi_range(0, counter_cells.size() - 1)]
	var rose_world: Vector2 = _cell_center(rose_cell)
	if not bool(plant_manager.call("harvest_grownup_rose", rose_cell)):
		return
	_add_counter_stock(target_counter, 1)
	_animate_harvested_rose_to_counter(rose_world, target_counter)
	_check_morning_harvest_finished()


func _player_grownup_rose_cell() -> Vector2i:
	var player: Node2D = get_tree().get_first_node_in_group("player") as Node2D
	if player == null or floorz == null:
		return INVALID_CELL
	if plant_manager == null or not plant_manager.has_method("is_rose_grownup"):
		return INVALID_CELL
	var player_cell: Vector2i = floorz.local_to_map(floorz.to_local(player.global_position))
	# Reach extends PLAYER_HARVEST_RADIUS_TILES tiles around the player: prefer the
	# cell the player stands on, then scan the surrounding ring so grown roses can be
	# picked up without standing exactly on them.
	if bool(plant_manager.call("is_rose_grownup", player_cell)):
		return player_cell
	for dy in range(-PLAYER_HARVEST_RADIUS_TILES, PLAYER_HARVEST_RADIUS_TILES + 1):
		for dx in range(-PLAYER_HARVEST_RADIUS_TILES, PLAYER_HARVEST_RADIUS_TILES + 1):
			if dx == 0 and dy == 0:
				continue
			var cell: Vector2i = player_cell + Vector2i(dx, dy)
			if bool(plant_manager.call("is_rose_grownup", cell)):
				return cell
	return INVALID_CELL


func has_grownup_roses_to_harvest() -> bool:
	return _morning_harvest_active and _grownup_rose_count() > 0


func _check_morning_harvest_finished() -> void:
	if _grownup_rose_count() > 0:
		return
	_morning_harvest_active = false
	GameState.set_morning_phase(false)
	_begin_client_sale_phase()


func _begin_client_sale_phase() -> void:
	_client_sale_active = false
	_client_sale_pending_spawners.clear()
	_client_sale_spawn_timers.clear()
	var sale_stock: int = _total_counter_stock()
	if sale_stock <= 0 or _client_spawners.is_empty():
		GameState.set_building_phase(true)
		return
	_night_preparation_token += 1
	_client_preparing = true
	_night_preparation_ready = false
	call_deferred("_run_client_preparation", _night_preparation_token)


func _activate_client_sale_phase() -> void:
	if GameState.is_night:
		return
	_client_sale_active = false
	_client_sale_pending_spawners.clear()
	_client_sale_spawn_timers.clear()
	var sale_stock: int = _total_counter_stock()
	if sale_stock <= 0 or _client_spawners.is_empty():
		GameState.set_building_phase(true)
		return
	var client_cells: Array[Vector2i] = []
	for raw_cell: Variant in _client_spawners.keys():
		client_cells.append(raw_cell as Vector2i)
	if client_cells.is_empty():
		GameState.set_building_phase(true)
		return
	for index: int in range(sale_stock):
		var random_index: int = randi_range(0, client_cells.size() - 1)
		_client_sale_pending_spawners.append(client_cells[random_index])
	for cell: Vector2i in client_cells:
		_client_sale_spawn_timers[cell] = 0.0
	_client_sale_active = true
	GameState.set_client_phase(true)


func _process_client_sale(delta: float) -> void:
	if GameState.is_night or not _client_sale_active:
		return
	if _total_counter_stock() <= 0:
		_client_sale_pending_spawners.clear()
	for raw_cell: Variant in _client_sale_spawn_timers.keys():
		var cell: Vector2i = raw_cell as Vector2i
		var time_left: float = maxf(0.0, float(_client_sale_spawn_timers[cell]) - delta)
		_client_sale_spawn_timers[cell] = time_left
	var spawned_this_frame: bool = false
	for index: int in range(_client_sale_pending_spawners.size() - 1, -1, -1):
		var spawner_cell: Vector2i = _client_sale_pending_spawners[index]
		if float(_client_sale_spawn_timers.get(spawner_cell, 0.0)) > 0.0:
			continue
		if _spawn_client_from(spawner_cell):
			_client_sale_pending_spawners.remove_at(index)
			_client_sale_spawn_timers[spawner_cell] = maxf(0.0, float(_client_frequency_by_cell.get(spawner_cell, 1.0)))
			spawned_this_frame = true
			break
		_client_sale_spawn_timers[spawner_cell] = SpawnPlaylistController.RETRY_DELAY_SECONDS
	if spawned_this_frame:
		return
	if _client_sale_pending_spawners.is_empty() and _client_count() == 0 and _client_paying_agents.is_empty() and _client_counter_agents.is_empty():
		_client_sale_active = false
		GameState.set_client_phase(false)
		_begin_seed_merchant_phase()


func _client_count() -> int:
	return get_tree().get_nodes_in_group("clients").size()


func _begin_seed_merchant_phase() -> void:
	_clear_seed_merchant_phase(false)
	if GameState.is_night or _client_spawners.is_empty() or _rose_shop_counter_cells().is_empty():
		GameState.set_building_phase(true)
		return
	var client_cells: Array[Vector2i] = []
	for raw_cell: Variant in _client_spawners.keys():
		client_cells.append(raw_cell as Vector2i)
	if client_cells.is_empty():
		GameState.set_building_phase(true)
		return
	var spawner_cell: Vector2i = client_cells[randi_range(0, client_cells.size() - 1)]
	if not _spawn_seed_merchant_from(spawner_cell):
		GameState.set_building_phase(true)
		return
	_seed_merchant_active = true
	GameState.set_seed_merchant_phase(true)


func _spawn_seed_merchant_from(spawner_cell: Vector2i) -> bool:
	if agent_manager == null or not agent_manager.has_method("spawn_agent") or not agent_manager.has_method("assign_agent_path"):
		return false
	var occupied: Array[Vector2i] = _occupied_cells()
	var spawn_cell: Vector2i = _find_free_cell_near(spawner_cell, occupied)
	if spawn_cell == INVALID_CELL:
		return false
	var target: Dictionary = _select_counter_target(spawn_cell)
	if target.is_empty():
		return false
	var target_cell: Vector2i = target.get("target_cell", INVALID_CELL) as Vector2i
	var counter_cell: Vector2i = target.get("counter_cell", INVALID_CELL) as Vector2i
	if target_cell == INVALID_CELL or counter_cell == INVALID_CELL:
		return false
	var path_cells: PackedVector2Array = _find_path_on_walkable_map(spawn_cell, target_cell)
	if path_cells.is_empty():
		return false
	var agent: Node2D = AGENT_SCENE.instantiate() as Node2D
	var parent: Node = parent_for_agents if parent_for_agents else get_tree().current_scene
	if parent == null:
		agent.queue_free()
		return false
	parent.add_child(agent)
	agent.global_position = _cell_center(spawn_cell)
	agent.z_index = int(agent.global_position.y)
	agent.add_to_group("merchants")
	agent.set_meta("agent_kind", SPAWNER_KIND_MERCHANT)
	agent.set_meta("spawner_cell", spawner_cell)
	var sprite: Sprite2D = agent.get_node_or_null("MonsterSprite2D") as Sprite2D
	if sprite != null:
		sprite.texture = MERCHANT_TEXTURE
	var nav_id: int = int(agent_manager.call("spawn_agent", agent, IDLE_GROUP))
	agent.set("nav_id", nav_id)
	if agent_manager.has_method("set_agent_never_rest"):
		agent_manager.call("set_agent_never_rest", nav_id, true)
	var path_world: PackedVector2Array = _path_cells_to_world(path_cells, nav_id, true)
	agent_manager.call("assign_agent_path", nav_id, path_world)
	_seed_merchant_agent = agent
	_seed_merchant_nav_id = nav_id
	_seed_merchant_counter_cell = counter_cell
	_seed_merchant_target_cell = target_cell
	_seed_merchant_waiting = false
	_seed_merchant_leaving = false
	_seed_merchant_paused = false
	if agent.has_method("start_astar_in"):
		agent.call("start_astar_in")
	return true


func _select_counter_target(from_cell: Vector2i) -> Dictionary:
	var best: Dictionary = {}
	var best_dist: int = 2147483647
	for counter_cell: Vector2i in _rose_shop_counter_cells():
		var target_cell: Vector2i = _nearest_counter_access_cell(counter_cell, from_cell)
		if target_cell == INVALID_CELL:
			continue
		var delta: Vector2i = target_cell - from_cell
		var manhattan: int = abs(delta.x) + abs(delta.y)
		if manhattan < best_dist:
			best_dist = manhattan
			best = {
				"counter_cell": counter_cell,
				"target_cell": target_cell,
			}
	return best


func _process_seed_merchant_arrival() -> void:
	# Only the walk-IN toward the counter uses the A* path; while leaving (escape flow)
	# or already parked at the counter there is nothing to arrive at here.
	if not _seed_merchant_active or _seed_merchant_waiting or _seed_merchant_leaving:
		return
	if not is_instance_valid(_seed_merchant_agent):
		_end_seed_merchant_phase()
		return
	if _seed_merchant_nav_id < 0 or not (agent_manager and agent_manager.has_method("agent_path_arrived")):
		return
	if not bool(agent_manager.call("agent_path_arrived", _seed_merchant_nav_id)):
		return
	if agent_manager.has_method("detach_agent_path"):
		agent_manager.call("detach_agent_path", _seed_merchant_nav_id)
	if _seed_merchant_agent.has_method("stop_astar_in"):
		_seed_merchant_agent.call("stop_astar_in")
	_seed_merchant_waiting = true


func _process_seed_merchant_phase() -> void:
	if not _seed_merchant_active:
		return
	if not is_instance_valid(_seed_merchant_agent):
		_end_seed_merchant_phase()
		return
	if GameState.is_seed_merchant_phase and GameState.seed_merchant_purchase_made and not is_player_near_seed_merchant():
		GameState.set_seed_merchant_phase(false)
		GameState.set_building_phase(true)


# True whenever the player is within interaction range of the merchant, no matter what
# the merchant is doing (walking in, parked at the counter, or walking back out). This
# drives both the shop visibility (shop.gd) and the movement pause below.
func is_player_near_seed_merchant() -> bool:
	if not _seed_merchant_active or not is_instance_valid(_seed_merchant_agent):
		return false
	var player: Node2D = get_tree().get_first_node_in_group("player") as Node2D
	if player == null or floorz == null:
		return false
	var player_cell: Vector2i = floorz.local_to_map(floorz.to_local(player.global_position))
	var merchant_cell: Vector2i = floorz.local_to_map(floorz.to_local(_seed_merchant_agent.global_position))
	var delta: Vector2i = player_cell - merchant_cell
	return abs(delta.x) <= SEED_MERCHANT_INTERACT_RADIUS_TILES and abs(delta.y) <= SEED_MERCHANT_INTERACT_RADIUS_TILES


# Freezes the merchant while the player is close and lets it resume the moment they
# leave, so getting near always stops it (and opens the shop, via is_player_near_...).
func _process_seed_merchant_proximity() -> void:
	# Once the merchant is leaving it must never re-pause: night has already started,
	# and walking back into the departing merchant should not freeze it.
	if not _seed_merchant_active or _seed_merchant_leaving or not is_instance_valid(_seed_merchant_agent):
		return
	var near: bool = is_player_near_seed_merchant()
	if near == _seed_merchant_paused:
		return
	_set_seed_merchant_paused(near)


func _set_seed_merchant_paused(value: bool) -> void:
	_seed_merchant_paused = value
	if _seed_merchant_nav_id >= 0 and agent_manager and agent_manager.has_method("set_agent_paused"):
		agent_manager.call("set_agent_paused", _seed_merchant_nav_id, value)


func request_seed_merchant_leave() -> void:
	if not _seed_merchant_active or not is_instance_valid(_seed_merchant_agent):
		_end_seed_merchant_phase()
		return
	if not GameState.is_night:
		GameState.set_seed_merchant_phase(false)
		GameState.set_building_phase(true)
		return
	_start_seed_merchant_leave_for_night()


func _start_seed_merchant_leave_for_night() -> void:
	if not _seed_merchant_active:
		_seed_merchant_leave_at_night_pending = false
		GameState.set_seed_merchant_phase(false)
		return
	if not is_instance_valid(_seed_merchant_agent):
		_seed_merchant_leave_at_night_pending = false
		_clear_seed_merchant_phase(false)
		return
	if GameState.is_night and not _night_preparation_ready:
		_seed_merchant_leave_at_night_pending = true
		GameState.set_seed_merchant_phase(false)
		return
	_seed_merchant_leave_at_night_pending = false
	# Unfreeze first so the merchant can actually walk out if the player paused it.
	if _seed_merchant_paused:
		_set_seed_merchant_paused(false)
	_seed_merchant_leaving = true
	_seed_merchant_waiting = false
	GameState.set_seed_merchant_phase(false)
	if not _assign_agent_to_escape(_seed_merchant_agent):
		remove_dead_monster(_seed_merchant_agent, false)


func _clear_seed_merchant_phase(free_agent: bool) -> void:
	if free_agent and is_instance_valid(_seed_merchant_agent):
		remove_dead_monster(_seed_merchant_agent, false)
	_seed_merchant_active = false
	_seed_merchant_agent = null
	_seed_merchant_nav_id = -1
	_seed_merchant_counter_cell = INVALID_CELL
	_seed_merchant_target_cell = INVALID_CELL
	_seed_merchant_waiting = false
	_seed_merchant_leaving = false
	_seed_merchant_leave_at_night_pending = false
	_seed_merchant_paused = false
	GameState.set_seed_merchant_phase(false)


func _end_seed_merchant_phase() -> void:
	_clear_seed_merchant_phase(false)
	GameState.set_building_phase(true)


func _grownup_rose_count() -> int:
	if plant_manager != null and plant_manager.has_method("grownup_rose_count"):
		return int(plant_manager.call("grownup_rose_count"))
	return 0


func _rose_shop_counter_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var building_objects: BuildingObjectManager = _get_building_object_manager()
	if building_objects != null and building_objects.has_method("get_building_cells_by_item_id"):
		var raw_cells: Array = building_objects.call("get_building_cells_by_item_id", ROSE_SHOP_COUNTER_ID) as Array
		for raw_cell: Variant in raw_cells:
			cells.append(raw_cell as Vector2i)
		return cells
	if traversable_buildings == null:
		return cells
	var item_def: Dictionary = ItemCatalog.get_item_def(ROSE_SHOP_COUNTER_ID)
	var atlas: Vector2i = item_def.get("atlas", Vector2i(-1, -1)) as Vector2i
	for raw_cell: Variant in traversable_buildings.get_used_cells():
		var cell: Vector2i = raw_cell as Vector2i
		if traversable_buildings.get_cell_atlas_coords(cell) == atlas:
			cells.append(cell)
	return cells


func _total_counter_stock() -> int:
	var total: int = 0
	for raw_count: Variant in _counter_stock_by_cell.values():
		total += int(raw_count)
	return total


## Public accessor: total number of harvested roses waiting on shop counters.
func total_counter_stock() -> int:
	return _total_counter_stock()


func _counter_stock(counter_cell: Vector2i) -> int:
	return int(_counter_stock_by_cell.get(counter_cell, 0))


func _add_counter_stock(counter_cell: Vector2i, amount: int) -> void:
	_set_counter_stock(counter_cell, _counter_stock(counter_cell) + amount)


func _set_counter_stock(counter_cell: Vector2i, amount: int) -> void:
	var previous: int = _counter_stock(counter_cell)
	var value: int = maxi(0, amount)
	if value <= 0:
		_counter_stock_by_cell.erase(counter_cell)
	else:
		_counter_stock_by_cell[counter_cell] = value
	_rebuild_counter_pile(counter_cell)
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
	var access_cells: Array[Vector2i] = []
	for raw_counter: Variant in _counter_stock_by_cell.keys():
		var counter_cell: Vector2i = raw_counter as Vector2i
		if _counter_stock(counter_cell) <= 0:
			continue
		for dy: int in range(-1, 2):
			for dx: int in range(-1, 2):
				if dx == 0 and dy == 0:
					continue
				var cell: Vector2i = counter_cell + Vector2i(dx, dy)
				if _counter_access_cells.has(cell):
					continue
				if not _is_walkable(cell):
					continue
				if plant_manager != null and plant_manager.has_method("has_plant") and bool(plant_manager.call("has_plant", cell)):
					continue
				_counter_access_cells[cell] = counter_cell
				access_cells.append(cell)
	return access_cells


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
	var best: Dictionary = {}
	var best_dist: int = 2147483647
	for raw_cell: Variant in _counter_stock_by_cell.keys():
		var counter_cell: Vector2i = raw_cell as Vector2i
		if _counter_stock(counter_cell) <= 0:
			continue
		var target_cell: Vector2i = _nearest_counter_access_cell(counter_cell, from_cell)
		if target_cell == INVALID_CELL:
			continue
		var delta: Vector2i = target_cell - from_cell
		var manhattan: int = abs(delta.x) + abs(delta.y)
		if manhattan < best_dist:
			best_dist = manhattan
			best = {
				"counter_cell": counter_cell,
				"target_cell": target_cell,
			}
	return best


func _nearest_counter_access_cell(counter_cell: Vector2i, from_cell: Vector2i) -> Vector2i:
	var best_cell: Vector2i = INVALID_CELL
	var best_dist: int = 2147483647
	for y: int in range(counter_cell.y - CLIENT_COUNTER_RADIUS_TILES, counter_cell.y + CLIENT_COUNTER_RADIUS_TILES + 1):
		for x: int in range(counter_cell.x - CLIENT_COUNTER_RADIUS_TILES, counter_cell.x + CLIENT_COUNTER_RADIUS_TILES + 1):
			var cell: Vector2i = Vector2i(x, y)
			var to_counter: Vector2i = cell - counter_cell
			if abs(to_counter.x) + abs(to_counter.y) > CLIENT_COUNTER_RADIUS_TILES:
				continue
			if not _is_walkable(cell):
				continue
			var from_delta: Vector2i = cell - from_cell
			var manhattan: int = abs(from_delta.x) + abs(from_delta.y)
			if manhattan < best_dist:
				best_dist = manhattan
				best_cell = cell
	return best_cell


func _animate_harvested_rose_to_counter(start_world: Vector2, counter_cell: Vector2i) -> void:
	var sprite: Sprite2D = Sprite2D.new()
	sprite.texture = ROSE_TEXTURE
	sprite.hframes = 2
	sprite.frame = 0
	sprite.centered = true
	sprite.scale = Vector2(0.75, 0.75)
	sprite.global_position = start_world
	sprite.z_index = int(start_world.y) + 10
	_rose_pile_parent().add_child(sprite)
	var end_world: Vector2 = _cell_center(counter_cell) + _counter_pile_offset(counter_cell, maxi(0, _counter_stock(counter_cell) - 1))
	var mid_world: Vector2 = (start_world + end_world) * 0.5 + Vector2(0.0, -64.0)
	var tween: Tween = create_tween()
	tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_method(
		Callable(self, "_update_harvest_rose_flight").bind(sprite, start_world, mid_world, end_world),
		0.0,
		1.0,
		HARVEST_ROSE_FLIGHT_SECONDS
	)
	tween.parallel().tween_property(sprite, "rotation", TAU, HARVEST_ROSE_FLIGHT_SECONDS)
	tween.tween_callback(Callable(sprite, "queue_free"))


func _update_harvest_rose_flight(progress: float, sprite: Sprite2D, start_world: Vector2, mid_world: Vector2, end_world: Vector2) -> void:
	if not is_instance_valid(sprite):
		return
	var inverse_progress: float = 1.0 - progress
	var pos: Vector2 = (
		inverse_progress * inverse_progress * start_world
		+ 2.0 * inverse_progress * progress * mid_world
		+ progress * progress * end_world
	)
	sprite.global_position = pos
	sprite.z_index = int(pos.y) + 10


func _rebuild_counter_pile(counter_cell: Vector2i) -> void:
	_clear_counter_pile(counter_cell)
	var count: int = _counter_stock(counter_cell)
	if count <= 0:
		return
	var nodes: Array[Node2D] = []
	for index: int in range(count):
		var sprite: Sprite2D = Sprite2D.new()
		sprite.texture = ROSE_TEXTURE
		sprite.hframes = 2
		sprite.frame = 0
		sprite.centered = true
		sprite.scale = Vector2(COUNTER_PILE_ROSE_SCALE, COUNTER_PILE_ROSE_SCALE)
		sprite.global_position = _cell_center(counter_cell) + _counter_pile_offset(counter_cell, index)
		# Base the whole column at the counter's depth, then stack front-to-back by
		# index so each higher rose draws in front of the one it overlaps.
		sprite.z_index = int(_cell_center(counter_cell).y) + index
		_rose_pile_parent().add_child(sprite)
		nodes.append(sprite)
	_counter_pile_nodes_by_cell[counter_cell] = nodes


func _clear_counter_pile(counter_cell: Vector2i) -> void:
	var nodes: Array = _counter_pile_nodes_by_cell.get(counter_cell, []) as Array
	for raw_node: Variant in nodes:
		var node: Node = raw_node as Node
		if node != null and is_instance_valid(node):
			node.queue_free()
	_counter_pile_nodes_by_cell.erase(counter_cell)


func _clear_all_counter_piles() -> void:
	var cells: Array = _counter_pile_nodes_by_cell.keys()
	for raw_cell: Variant in cells:
		var cell: Vector2i = raw_cell as Vector2i
		_clear_counter_pile(cell)
	_counter_pile_nodes_by_cell.clear()


func _rose_pile_parent() -> Node:
	if parent_for_agents != null:
		return parent_for_agents
	var scene: Node = get_tree().current_scene
	return scene if scene != null else self


func _counter_pile_offset(_counter_cell: Vector2i, index: int) -> Vector2:
	var step: float = COUNTER_PILE_ROSE_FRAME_HEIGHT * COUNTER_PILE_ROSE_SCALE * (1.0 - COUNTER_PILE_OVERLAP)
	return Vector2(0.0, COUNTER_PILE_BASE_Y - float(index) * step)


func _auto_select_shop_tool() -> void:
	var scene: Node = get_tree().current_scene
	var game_ui: Node = scene.get_node_or_null("GameUI") if scene != null else null
	if game_ui != null and game_ui.has_method("select_build_tool"):
		game_ui.call("select_build_tool")


func _enqueue_playlist_spawn_requests(delta: float) -> void:
	var requests: Array[Dictionary] = _spawn_playlist_controller.advance(delta)
	for request: Dictionary in requests:
		var track_index: int = int(request.get("track_index", -1))
		if track_index < 0:
			continue
		if _ready_spawner_queue_set.has(track_index):
			continue
		_ready_spawner_queue.append(request)
		_ready_spawner_queue_set[track_index] = true

# Spawn from at most spawner_budget_per_frame ready playlist requests (and, if a
# time budget is set, stop early once we exceed it — but always do at least one so
# the queue drains). Remaining ready spawners are processed on following frames.
func _drain_ready_spawner_queue_budgeted() -> void:
	var start_us: int = Time.get_ticks_usec()
	var budget_us: int = int(spawner_budget_ms * 1000.0)
	var processed: int = 0

	while not _ready_spawner_queue.is_empty():
		if processed >= spawner_budget_per_frame:
			break
		# Time budget only applies after the first spawn this frame, so a single
		# expensive spawner can't starve the queue entirely.
		if processed > 0 and budget_us > 0:
			if Time.get_ticks_usec() - start_us >= budget_us:
				break

		var request: Dictionary = _ready_spawner_queue.pop_front()
		var cell: Vector2i = request.get("spawner_cell", INVALID_CELL) as Vector2i
		_ready_spawner_queue_set.erase(int(request.get("track_index", -1)))
		# A spawner may have been removed (rescan) while queued; skip stale entries
		# without counting them against the budget.
		if not _spawners.has(cell):
			_report_playlist_spawn_result(request, false, "physical spawner cell is missing")
			continue

		var spawner_us: int = Time.get_ticks_usec()
		_spawn_pass_stats["processed_spawners"] = int(_spawn_pass_stats["processed_spawners"]) + 1
		processed += 1

		var monster_type: StringName = StringName(str(request.get("monster_type", "basic")))
		var spawned: bool = _spawn_monster_from(cell, monster_type)
		if spawned:
			_spawn_pass_stats["spawned_count"] = int(_spawn_pass_stats["spawned_count"]) + 1
			_report_playlist_spawn_result(request, true)
		else:
			_report_playlist_spawn_result(request, false, _last_spawn_failure)

		# Whole spawner iteration. Build the (small) context only when over threshold.
		var spawner_elapsed_us: int = Time.get_ticks_usec() - spawner_us
		if _over_garden_threshold_us(spawner_elapsed_us):
			_warn_garden_task_lag_us("_process_spawners.spawner_total", spawner_elapsed_us,
				"spawner_cell=%s spawned=%s" % [str(cell), str(spawned)])

	_spawn_pass_stats["ready_queue_remaining"] = _ready_spawner_queue.size()
	_spawn_pass_stats["elapsed_ms"] = float(Time.get_ticks_usec() - start_us) / 1000.0


func _report_playlist_spawn_result(request: Dictionary, success: bool, failure_reason: String = "") -> void:
	var track_index: int = int(request.get("track_index", -1))
	_spawn_playlist_controller.mark_spawn_result(track_index, success, failure_reason)
	if not success:
		var warning_key: String = "playlist:%d" % track_index
		var now_ms: int = Time.get_ticks_msec()
		var last_ms: int = int(_last_spawn_failure_at_ms.get(warning_key, -SPAWN_FAILURE_WARN_INTERVAL_MS))
		if now_ms - last_ms >= SPAWN_FAILURE_WARN_INTERVAL_MS:
			_last_spawn_failure_at_ms[warning_key] = now_ms
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
	if _over_garden_threshold_us(sel_us):
		_warn_garden_task_lag_us("_process_spawners.select_garden", sel_us,
			"spawner_cell=%s gardens=%d garden=%d" % [str(spawner_cell), _gardens.size(), garden_id])
	if garden_id <= 0:
		_log_spawn_failure("spawner %s has no reachable garden" % spawner_cell)
		return false

	# Route/cache lookup (+ entry-cell resolution). Hits are O(1); misses recompute
	# the nearest garden entry. Hit/miss counters live in the called function.
	var t_route: int = Time.get_ticks_usec()
	var route: Dictionary = _get_or_create_spawner_garden_route(spawner_cell, garden_id)
	var route_us: int = Time.get_ticks_usec() - t_route
	if _over_garden_threshold_us(route_us):
		_warn_garden_task_lag_us("_process_spawners.route_lookup", route_us,
			"spawner_cell=%s garden=%d ready=%s" % [str(spawner_cell), garden_id, str(route.get("ready", false))])
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

	# Occupied-cell scan: walks the main_chars/monsters/player scene groups every
	# spawn. Grows with active unit count.
	var t_occ: int = Time.get_ticks_usec()
	var occupied: Array[Vector2i] = _occupied_cells()
	var occ_us: int = Time.get_ticks_usec() - t_occ
	if _over_garden_threshold_us(occ_us):
		_warn_garden_task_lag_us("_process_spawners.occupied_cells", occ_us,
			"spawner_cell=%s occupied=%d" % [str(spawner_cell), occupied.size()])

	# Free-cell search: spirals out from the spawner doing per-cell walkable/wall
	# (TileMap) lookups until a free cell is found. Can spike when the spawner is
	# boxed in.
	var t_free: int = Time.get_ticks_usec()
	var spawn_cell: Vector2i = _find_free_cell_near(spawner_cell, occupied)
	var free_us: int = Time.get_ticks_usec() - t_free
	if _over_garden_threshold_us(free_us):
		_warn_garden_task_lag_us("_process_spawners.find_free_cell", free_us,
			"spawner_cell=%s spawn_cell=%s" % [str(spawner_cell), str(spawn_cell)])
	if spawn_cell == INVALID_CELL or not _is_sane_cell(spawn_cell):
		_log_spawn_failure("spawner %s could not find a sane walkable spawn cell (got %s)" % [spawner_cell, spawn_cell])
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
		var sprite: Sprite2D = agent.get_node_or_null("MonsterSprite2D") as Sprite2D
		if sprite != null:
			sprite.texture = CLIENT_TEXTURE
	else:
		agent.add_to_group("monsters")
	agent.set_meta("agent_kind", agent_kind)
	var inst_us: int = Time.get_ticks_usec() - t_inst
	if _over_garden_threshold_us(inst_us):
		_warn_garden_task_lag_us("_process_spawners.instantiate_agent", inst_us,
			"spawner_cell=%s spawn_cell=%s" % [str(spawner_cell), str(spawn_cell)])

	if agent_manager and agent_manager.has_method("spawn_agent"):
		# Register the agent with the nav/agent manager (flowfield/pathfinder side).
		var t_reg: int = Time.get_ticks_usec()
		var nav_id: int = int(agent_manager.call("spawn_agent", agent, IDLE_GROUP))
		agent.set("nav_id", nav_id)
		if agent_manager.has_method("set_agent_never_rest"):
			agent_manager.call("set_agent_never_rest", nav_id, true)
		var reg_us: int = Time.get_ticks_usec() - t_reg
		if _over_garden_threshold_us(reg_us):
			_warn_garden_task_lag_us("_process_spawners.register_agent", reg_us,
				"spawner_cell=%s nav_id=%d" % [str(spawner_cell), nav_id])

			# Assign the garden-entry route: attaches the monster to the entry flow
			# group. Usually the heaviest leg when the route/flow is first created.
		var t_assign: int = Time.get_ticks_usec()
		var assigned: bool = _assign_agent_to_garden_entry_flow(agent, spawner_cell, garden_id, entry_cell)
		var assign_us: int = Time.get_ticks_usec() - t_assign
		if _over_garden_threshold_us(assign_us):
			_warn_garden_task_lag_us("_process_spawners.assign_route", assign_us,
				"spawner_cell=%s garden=%d entry=%s assigned=%s" % [
					str(spawner_cell), garden_id, str(entry_cell), str(assigned)])
		if not assigned:
			if agent_manager.has_method("unregister_agent"):
				agent_manager.call("unregister_agent", nav_id)
			var failed_group: StringName = &"clients" if agent_kind == SPAWNER_KIND_CLIENT else &"monsters"
			agent.remove_from_group(failed_group)
			agent.queue_free()
			_log_spawn_failure("spawner %s garden %d entry flow not ready" % [spawner_cell, garden_id])
			return false
		_spawn_pass_stats["assigned_count"] = int(_spawn_pass_stats.get("assigned_count", 0)) + 1
		var kind_label: String = "client" if agent_kind == SPAWNER_KIND_CLIENT else "monster"
		_log("spawned %s nav_id=%d spawn_cell=%s entry=%s spawner=%s garden=%d" % [
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
		_warn_garden_task_lag_us("_consume_plant", Time.get_ticks_usec() - consume_us,
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
		_warn_garden_task_lag_us("_consume_plant.remove_plant", Time.get_ticks_usec() - remove_us,
			"plant=%s" % str(plant_cell))
	elif plantz:
		var source_id: int = plantz.get_cell_source_id(plant_cell)
		var alternative_tile: int = plantz.get_cell_alternative_tile(plant_cell)
		plantz.set_cell(plant_cell, source_id, PlantManager.DEBRIS_ATLAS, alternative_tile)
		_flush_plant_layer_visuals()
	_warn_garden_task_lag_us("_consume_plant", Time.get_ticks_usec() - consume_us,
		"plant=%s" % str(plant_cell))


func _start_client_payment(agent: Node2D, plant_cell: Vector2i) -> void:
	var nav_id: int = int(agent.get("nav_id"))
	_client_paying_agents[nav_id] = {
		"node": agent,
		"timer": CLIENT_PAYMENT_SECONDS,
		"plant_cell": plant_cell,
	}
	if agent_manager and agent_manager.has_method("detach_agent_flow"):
		agent_manager.call("detach_agent_flow", nav_id)
	if agent_manager and agent_manager.has_method("detach_agent_path"):
		agent_manager.call("detach_agent_path", nav_id)
	_entry_path_agents.erase(nav_id)
	_erase_astar_in_agent(nav_id)
	_spawn_client_payment_money(agent.global_position)
	if plant_manager and plant_manager.has_method("remove_plant"):
		plant_manager.call("remove_plant", plant_cell, true)
	elif plantz:
		plantz.erase_cell(plant_cell)
		_flush_plant_layer_visuals()
	if agent.has_method("start_eating"):
		agent.call("start_eating", CLIENT_PAYMENT_SECONDS)


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
			var spawner_cell: Vector2i = agent.get_meta("spawner_cell") as Vector2i if agent.has_meta("spawner_cell") else INVALID_CELL
			_retarget_agent_or_escape(agent, spawner_cell)
			continue
		_start_client_counter_payment(agent, counter_cell)


func _start_client_counter_payment(agent: Node2D, counter_cell: Vector2i) -> void:
	if _counter_stock(counter_cell) <= 0:
		var spawner_cell: Vector2i = agent.get_meta("spawner_cell") as Vector2i if agent.has_meta("spawner_cell") else INVALID_CELL
		_retarget_agent_or_escape(agent, spawner_cell)
		return
	var nav_id: int = int(agent.get("nav_id"))
	_set_counter_stock(counter_cell, _counter_stock(counter_cell) - 1)
	_client_paying_agents[nav_id] = {
		"node": agent,
		"timer": CLIENT_PAYMENT_SECONDS,
		"counter_cell": counter_cell,
	}
	if agent_manager and agent_manager.has_method("detach_agent_flow"):
		agent_manager.call("detach_agent_flow", nav_id)
	if agent_manager and agent_manager.has_method("detach_agent_path"):
		agent_manager.call("detach_agent_path", nav_id)
	_spawn_client_payment_money(agent.global_position)
	if agent.has_method("start_eating"):
		agent.call("start_eating", CLIENT_PAYMENT_SECONDS)


func _spawn_client_payment_money(world_position: Vector2) -> void:
	var scene: Node = get_tree().current_scene
	var money_icon: Node = scene.get_node_or_null("GameUI/top right/moneyIcon") if scene != null else null
	if money_icon != null and money_icon.has_method("animate_money_harvest"):
		var started: bool = bool(money_icon.call("animate_money_harvest", world_position, 0))
		if started:
			return
	var progression_node: Node = scene.get_node_or_null("progression") if scene != null else null
	if progression_node != null and progression_node.has_method("update_money"):
		progression_node.call("update_money", 1)


func _process_client_paying_agents(delta: float) -> void:
	var finished: Array[int] = []
	for raw_nav_id: Variant in _client_paying_agents.keys():
		var nav_id: int = int(raw_nav_id)
		var data: Dictionary = _client_paying_agents[nav_id] as Dictionary
		var timer: float = float(data.get("timer", 0.0)) - delta
		data["timer"] = timer
		_client_paying_agents[nav_id] = data
		if timer <= 0.0:
			finished.append(nav_id)
	for nav_id: int in finished:
		var data: Dictionary = _client_paying_agents.get(nav_id, {}) as Dictionary
		_client_paying_agents.erase(nav_id)
		var raw_agent: Variant = data.get("node", null)
		if not is_instance_valid(raw_agent):
			continue
		var agent: Node2D = raw_agent as Node2D
		if agent != null:
			_assign_agent_to_escape(agent)

func _process_turret_overlaps() -> void:
	if blocking_buildings == null:
		return
	for raw_node: Node in get_tree().get_nodes_in_group("monsters"):
		var agent: Node2D = raw_node as Node2D
		if agent == null or not is_instance_valid(agent):
			continue
		var nav_id: int = int(agent.get("nav_id"))
		if nav_id < 0 or _eating_agents.has(nav_id) or _turret_eating_agents.has(nav_id) or _drowning_agents.has(nav_id):
			continue
		var agent_cell: Vector2i = blocking_buildings.local_to_map(blocking_buildings.to_local(agent.global_position))
		if not _is_turret_cell(agent_cell):
			continue
		_consume_turret(agent, agent_cell)

func _consume_turret(agent: Node2D, turret_cell: Vector2i) -> void:
	var nav_id: int = int(agent.get("nav_id"))
	if nav_id < 0:
		return
	var resume_state: Dictionary = _capture_agent_resume_state(nav_id, agent)
	_turret_eating_agents[nav_id] = {
		"node": agent,
		"timer": _eating_time,
		"resume_state": resume_state,
	}
	_suspend_agent_for_turret_eating(nav_id)
	_leave_turret_debris(turret_cell)
	_remove_turret_cell(turret_cell)
	Sfx.play_sound(&"crunsh")
	if agent.has_method("start_eating"):
		agent.call("start_eating", _eating_time)

func _process_turret_eating_agents(delta: float) -> void:
	var finished: Array[int] = []
	for raw_nav_id: Variant in _turret_eating_agents.keys():
		var nav_id: int = int(raw_nav_id)
		if not _turret_eating_agents.has(nav_id):
			continue
		var data: Dictionary = _turret_eating_agents[nav_id] as Dictionary
		var timer: float = float(data.get("timer", 0.0)) - delta
		data["timer"] = timer
		_turret_eating_agents[nav_id] = data
		if timer <= 0.0:
			finished.append(nav_id)

	for nav_id: int in finished:
		var data: Dictionary = _turret_eating_agents.get(nav_id, {}) as Dictionary
		_turret_eating_agents.erase(nav_id)
		var raw_agent: Variant = data.get("node", null)
		if not is_instance_valid(raw_agent):
			continue
		var agent: Node2D = raw_agent as Node2D
		if agent == null:
			continue
		if agent.has_method("stop_eating"):
			agent.call("stop_eating")
		var resume_state: Dictionary = data.get("resume_state", {}) as Dictionary
		_resume_agent_after_turret_eating(nav_id, agent, resume_state)

func _process_drowning_agents(delta: float) -> void:
	if watersources == null:
		return

	for group_name: String in ["monsters", "clients", "merchants"]:
		for raw_node: Node in get_tree().get_nodes_in_group(group_name):
			var agent: Node2D = raw_node as Node2D
			if agent == null or not is_instance_valid(agent):
				continue
			var nav_id: int = int(agent.get("nav_id"))
			if nav_id < 0:
				continue
			_update_monster_splash(agent, delta)
			if _turret_eating_agents.has(nav_id):
				continue
			var in_water: bool = _agent_over_drowning_water(agent)
			if _drowning_agents.has(nav_id):
				continue
			if in_water and _agent_can_drown(agent):
				_start_agent_drowning(nav_id, agent)

	var dead_agents: Array[Node2D] = []
	var drowning_ids: Array = _drowning_agents.keys()
	for raw_nav_id: Variant in drowning_ids:
		var nav_id: int = int(raw_nav_id)
		if not _drowning_agents.has(nav_id):
			continue
		var data: Dictionary = _drowning_agents[nav_id] as Dictionary
		var raw_agent: Variant = data.get("node", null)
		if not is_instance_valid(raw_agent):
			_drowning_agents.erase(nav_id)
			continue
		var agent: Node2D = raw_agent as Node2D
		if agent == null:
			_drowning_agents.erase(nav_id)
			continue
		var duration: float = maxf(float(data.get("duration", 0.0)), 0.001)
		var update_freq: float = maxf(float(data.get("update_freq", 0.1)), 0.01)
		var tick_timer: float = float(data.get("tick_timer", update_freq)) - delta
		var elapsed: float = minf(float(data.get("elapsed", 0.0)) + delta, duration)
		var dealt_damage: int = int(data.get("dealt_damage", 0))
		var total_damage: int = int(data.get("total_damage", 0))
		var damage_target: int = int(floor((elapsed / duration) * float(total_damage)))
		if tick_timer <= 0.0 or elapsed >= duration:
			var damage: int = maxi(0, damage_target - dealt_damage)
			if damage > 0 and agent.has_method("take_damage"):
				var died: bool = bool(agent.call("take_damage", damage))
				dealt_damage += damage
				if died:
					dead_agents.append(agent)
			tick_timer = update_freq
		data["elapsed"] = elapsed
		data["tick_timer"] = tick_timer
		data["dealt_damage"] = dealt_damage
		_drowning_agents[nav_id] = data

	for agent: Node2D in dead_agents:
		remove_dead_monster(agent, false)

func _update_monster_splash(agent: Node2D, delta: float) -> void:
	# Any monster over the water emits a pooled splash, throttled per-monster.
	# The timer lives on the node itself (meta) so it is freed with the monster
	# and never accumulates stale entries.
	if watersources == null:
		return
	if not watersources.has_water_at_foot_position(agent.global_position):
		if agent.has_meta(&"water_splash_timer"):
			agent.remove_meta(&"water_splash_timer")
		return
	var time_left: float = float(agent.get_meta(&"water_splash_timer", 0.0)) - delta
	if time_left <= 0.0:
		watersources.play_splash_at(agent.global_position)
		time_left = maxf(watersources.splash_repeat_seconds, 0.0)
	agent.set_meta(&"water_splash_timer", time_left)

func _agent_can_drown(agent: Node2D) -> bool:
	var drownable_value: Variant = agent.get("drownable")
	var duration_value: Variant = agent.get("drowning")
	return drownable_value is bool and bool(drownable_value) and duration_value != null and float(duration_value) > 0.0

func _agent_over_drowning_water(agent: Node2D) -> bool:
	if watersources == null:
		return false
	var threshold: float = clampf(watersources.drowning_coverage_threshold, 0.0, 1.0)
	if threshold <= 0.0:
		return watersources.has_water_at_foot_position(agent.global_position)
	return _agent_water_coverage(agent) >= threshold

func _agent_water_coverage(agent: Node2D) -> float:
	if watersources == null:
		return 0.0
	var footprint: Rect2 = _agent_water_footprint_rect(agent)
	return watersources.water_coverage_of_world_rect(footprint)

func _agent_water_footprint_rect(agent: Node2D) -> Rect2:
	var radius: float = maxf(1.0, _agent_world_radius())
	var size: Vector2 = Vector2(radius * 2.0, radius * 2.0)
	return Rect2(agent.global_position - size * 0.5, size)

func _agent_world_radius() -> float:
	if global_config and global_config.has_method("get_agent_world_radius"):
		return float(global_config.call("get_agent_world_radius"))
	return 12.0

func _start_agent_drowning(nav_id: int, agent: Node2D) -> void:
	var duration: float = maxf(float(agent.get("drowning")), 0.001)
	var raw_update_freq: Variant = agent.get("drowning_update_freq")
	var update_freq: float = maxf(float(raw_update_freq) if raw_update_freq != null else 0.1, 0.01)
	var resume_state: Dictionary = _capture_agent_resume_state(nav_id, agent)
	_drowning_agents[nav_id] = {
		"node": agent,
		"duration": duration,
		"update_freq": update_freq,
		"tick_timer": update_freq,
		"elapsed": 0.0,
		"total_damage": maxi(1, int(agent.get("health"))),
		"dealt_damage": 0,
		"resume_state": resume_state,
	}
	_suspend_agent_for_drowning(nav_id)
	if agent.has_method("start_drowning"):
		agent.call("start_drowning", duration)

func _stop_agent_drowning(nav_id: int, agent: Node2D) -> void:
	var data: Dictionary = _drowning_agents.get(nav_id, {}) as Dictionary
	_drowning_agents.erase(nav_id)
	if agent.has_method("stop_drowning"):
		agent.call("stop_drowning")
	var resume_state: Dictionary = data.get("resume_state", {}) as Dictionary
	_resume_agent_after_drowning(nav_id, agent, resume_state)

func _suspend_agent_for_drowning(nav_id: int) -> void:
	if agent_manager and agent_manager.has_method("detach_agent_flow"):
		agent_manager.call("detach_agent_flow", nav_id)
	if agent_manager and agent_manager.has_method("detach_agent_path"):
		agent_manager.call("detach_agent_path", nav_id)
	_entry_path_agents.erase(nav_id)
	_erase_astar_in_agent(nav_id)
	_erase_eating_agent(nav_id)
	_escaping_agents.erase(nav_id)
	_client_counter_agents.erase(nav_id)

func _resume_agent_after_drowning(nav_id: int, agent: Node2D, resume_state: Dictionary) -> void:
	_resume_agent_after_turret_eating(nav_id, agent, resume_state)

func _capture_agent_resume_state(nav_id: int, agent: Node2D) -> Dictionary:
	if _entry_path_agents.has(nav_id):
		return {
			"kind": "entry",
			"data": (_entry_path_agents[nav_id] as Dictionary).duplicate(),
		}
	if _astar_in_agents.has(nav_id):
		return {
			"kind": "astar",
			"data": (_astar_in_agents[nav_id] as Dictionary).duplicate(),
		}
	if _escaping_agents.has(nav_id):
		return {
			"kind": "escape",
			"data": (_escaping_agents[nav_id] as Dictionary).duplicate(),
		}
	if _client_counter_agents.has(nav_id):
		return {
			"kind": "client_counter",
			"data": (_client_counter_agents[nav_id] as Dictionary).duplicate(),
		}
	var spawner_cell: Vector2i = agent.get_meta("spawner_cell") as Vector2i if agent.has_meta("spawner_cell") else INVALID_CELL
	var garden_id: int = int(agent.get_meta("garden_id")) if agent.has_meta("garden_id") else 0
	return {
		"kind": "retarget",
		"spawner_cell": spawner_cell,
		"garden_id": garden_id,
	}

func _suspend_agent_for_turret_eating(nav_id: int) -> void:
	if agent_manager and agent_manager.has_method("detach_agent_flow"):
		agent_manager.call("detach_agent_flow", nav_id)
	if agent_manager and agent_manager.has_method("detach_agent_path"):
		agent_manager.call("detach_agent_path", nav_id)
	_entry_path_agents.erase(nav_id)
	_erase_astar_in_agent(nav_id)
	_escaping_agents.erase(nav_id)
	_client_counter_agents.erase(nav_id)

func _resume_agent_after_turret_eating(nav_id: int, agent: Node2D, resume_state: Dictionary) -> void:
	var kind: String = str(resume_state.get("kind", "retarget"))
	var data: Dictionary = resume_state.get("data", {}) as Dictionary
	if kind == "entry":
		if _resume_agent_entry_flow(nav_id, agent, data):
			_entry_path_agents[nav_id] = data
			_erase_astar_in_agent(nav_id)
			_escaping_agents.erase(nav_id)
			if agent.has_method("start_flow_in"):
				agent.call("start_flow_in")
			return
	elif kind == "astar":
		if _resume_agent_path(nav_id, agent, data):
			_entry_path_agents.erase(nav_id)
			_set_astar_in_agent(nav_id, data)
			_escaping_agents.erase(nav_id)
			if agent.has_method("start_astar_in"):
				agent.call("start_astar_in")
			return
	elif kind == "escape":
		if _assign_agent_to_escape(agent):
			return
	elif kind == "client_counter":
		if _resume_agent_path(nav_id, agent, data):
			_client_counter_agents[nav_id] = data
			_entry_path_agents.erase(nav_id)
			_erase_astar_in_agent(nav_id)
			_escaping_agents.erase(nav_id)
			if agent.has_method("start_astar_in"):
				agent.call("start_astar_in")
			return

	var spawner_cell: Vector2i = resume_state.get("spawner_cell", INVALID_CELL) as Vector2i
	if spawner_cell == INVALID_CELL and agent.has_meta("spawner_cell"):
		spawner_cell = agent.get_meta("spawner_cell") as Vector2i
	if _agent_kind(agent) == SPAWNER_KIND_CLIENT:
		if not _retarget_agent_or_escape(agent, spawner_cell) and agent.has_method("start_waiting_new_status"):
			agent.call("start_waiting_new_status")
		return
	if not _retarget_agent_or_escape(agent, spawner_cell) and agent.has_method("start_waiting_new_status"):
		agent.call("start_waiting_new_status")

func _resume_agent_entry_flow(nav_id: int, agent: Node2D, data: Dictionary) -> bool:
	if agent_manager == null or not agent_manager.has_method("assign_agent"):
		return false
	var plant_group: int = int(data.get("plant_group", -1))
	if plant_group <= IDLE_GROUP:
		return false
	if agent_manager.has_method("detach_agent_path"):
		agent_manager.call("detach_agent_path", nav_id)
	agent_manager.call("assign_agent", agent, plant_group)
	return true

func _resume_agent_path(nav_id: int, agent: Node2D, data: Dictionary) -> bool:
	if agent_manager == null or not agent_manager.has_method("assign_agent_path"):
		return false
	var path_world: PackedVector2Array = data.get("path_world", PackedVector2Array()) as PackedVector2Array
	if path_world.is_empty():
		return false
	if agent_manager.has_method("detach_agent_flow"):
		agent_manager.call("detach_agent_flow", nav_id)
	if agent_manager.has_method("detach_agent_path"):
		agent_manager.call("detach_agent_path", nav_id)
	data["node"] = agent
	agent_manager.call("assign_agent_path", nav_id, path_world)
	return true

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
			if _escaping_agents.has(nav_id) or _eating_agents.has(nav_id) or _drowning_agents.has(nav_id):
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
		if agent == _seed_merchant_agent and _seed_merchant_paused:
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
	agent.remove_from_group("clients")
	agent.remove_from_group("merchants")
	agent.remove_from_group("monsters")
	agent.queue_free()
	if is_merchant:
		_seed_merchant_active = false
		_seed_merchant_agent = null
		_seed_merchant_nav_id = -1
		_seed_merchant_counter_cell = INVALID_CELL
		_seed_merchant_target_cell = INVALID_CELL
		_seed_merchant_waiting = false
		_seed_merchant_leaving = false
		_seed_merchant_leave_at_night_pending = false
		_seed_merchant_paused = false
		GameState.set_seed_merchant_phase(false)
		if not GameState.is_night:
			GameState.set_building_phase(true)

# Monster death uses the same authoritative owner that created and routed monsters.
# Clear every phase/index before unregistering the native agent so no deferred
# garden work can retain or later re-route a dead nav_id.
func remove_dead_monster(agent: Node2D, spawn_corpse: bool = true) -> void:
	if not is_instance_valid(agent):
		return
	var is_client: bool = agent.is_in_group("clients")
	var is_merchant: bool = agent.is_in_group("merchants")
	var awards_monster_drop: bool = agent.is_in_group("monsters") and not is_client and not is_merchant
	var death_position: Vector2 = agent.global_position
	if spawn_corpse and not is_client and not is_merchant:
		_spawn_monster_corpse(agent)
	if awards_monster_drop:
		_spawn_monster_death_drop(death_position)
	var nav_id: int = int(agent.get("nav_id"))
	_entry_path_agents.erase(nav_id)
	_erase_astar_in_agent(nav_id)
	_erase_eating_agent(nav_id)
	_drowning_agents.erase(nav_id)
	_escaping_agents.erase(nav_id)
	_client_counter_agents.erase(nav_id)
	_client_paying_agents.erase(nav_id)
	_garden_retarget_queued.erase(nav_id)
	for index: int in range(_garden_retarget_queue.size() - 1, -1, -1):
		var item: Dictionary = _garden_retarget_queue[index]
		if int(item.get("nav_id", -1)) == nav_id:
			_garden_retarget_queue.remove_at(index)
	if agent_manager and agent_manager.has_method("unregister_agent") and nav_id >= 0:
		agent_manager.call("unregister_agent", nav_id)
	agent.remove_from_group("monsters")
	agent.remove_from_group("clients")
	agent.remove_from_group("merchants")
	agent.queue_free()
	if is_merchant:
		_seed_merchant_active = false
		_seed_merchant_agent = null
		_seed_merchant_nav_id = -1
		_seed_merchant_counter_cell = INVALID_CELL
		_seed_merchant_target_cell = INVALID_CELL
		_seed_merchant_waiting = false
		_seed_merchant_leaving = false
		_seed_merchant_leave_at_night_pending = false
		_seed_merchant_paused = false
		GameState.set_seed_merchant_phase(false)
		if not GameState.is_night:
			GameState.set_building_phase(true)

func _spawn_monster_death_drop(world_position: Vector2) -> void:
	var drop_type: StringName = MONSTER_DEATH_DROP_SEED if randf() < 0.5 else MONSTER_DEATH_DROP_GEM
	var scene: Node = get_tree().current_scene
	var icon: Node = null
	var animate_method: String = ""
	if scene != null:
		if drop_type == MONSTER_DEATH_DROP_SEED:
			icon = scene.get_node_or_null("GameUI/top right/seedIcon")
			animate_method = "animate_seed_harvest"
		else:
			icon = scene.get_node_or_null("GameUI/top right/gemIcon")
			animate_method = "animate_gem_harvest"
	if icon != null and icon.has_method(animate_method):
		var animation_started: bool = bool(icon.call(animate_method, world_position))
		if animation_started:
			if drop_type == MONSTER_DEATH_DROP_GEM:
				Sfx.play_sound(&"gem")
			return
	_credit_monster_death_drop(drop_type)

func _credit_monster_death_drop(drop_type: StringName) -> void:
	var scene: Node = get_tree().current_scene
	var progression_node: Node = scene.get_node_or_null("progression") if scene != null else null
	if progression_node == null:
		return
	if drop_type == MONSTER_DEATH_DROP_SEED:
		if progression_node.has_method("update_seeds"):
			progression_node.call("update_seeds", 1)
	elif drop_type == MONSTER_DEATH_DROP_GEM:
		if progression_node.has_method("update_gems"):
			progression_node.call("update_gems", 1)

func _spawn_monster_corpse(agent: Node2D) -> void:
	var corpse: Node2D = MONSTER_CORPSE_SCENE.instantiate() as Node2D
	if corpse == null:
		return
	var parent: Node = parent_for_agents if parent_for_agents else get_tree().current_scene
	if parent == null:
		corpse.queue_free()
		return
	parent.add_child(corpse)
	corpse.global_position = agent.global_position
	var corpse_sprite: Sprite2D = corpse.get_node_or_null("Sprite2D") as Sprite2D
	if corpse_sprite:
		corpse_sprite.rotation = randf() * TAU

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
	if wallz != null and wallz.get_cell_tile_data(cell) != null:
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
	# Full topology rebuild (plant added, walls changed, etc.). Each phase is timed
	# separately so a rebuild spike points at clustering vs geometry vs route cache.
	var rebuild_us: int = Time.get_ticks_usec()
	var t: int = Time.get_ticks_usec()
	_build_gardens_from_plants()
	_warn_garden_task_lag_us("_build_gardens_from_plants", Time.get_ticks_usec() - t,
		"gardens=%d" % _gardens.size())
	t = Time.get_ticks_usec()
	_validate_dirty_gardens()
	_warn_garden_task_lag_us("_validate_dirty_gardens", Time.get_ticks_usec() - t,
		"gardens=%d" % _gardens.size())
	t = Time.get_ticks_usec()
	_rebuild_spawner_garden_route_cache()
	_warn_garden_task_lag_us("_rebuild_spawner_garden_route_cache", Time.get_ticks_usec() - t,
		"spawners=%d" % _spawner_garden_routes.size())
	# Garden ids/topology just changed: cheaply detect agents now pointing at a
	# deleted/empty garden, park them in "waiting_new_status", and queue them for
	# budgeted retargeting over the next frames. No pathfinding happens here.
	t = Time.get_ticks_usec()
	_queue_agents_after_garden_rebuild()
	_warn_garden_task_lag_us("_queue_agents_after_garden_rebuild", Time.get_ticks_usec() - t,
		"retarget_queue=%d" % _garden_retarget_queue.size())
	_warn_garden_task_lag_us("_rebuild_plant_zone_from_layer", Time.get_ticks_usec() - rebuild_us,
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
		var delta: Vector2i = entry_cell - from_cell
		var manhattan: int = abs(delta.x) + abs(delta.y)
		if manhattan < best_dist:
			best_dist = manhattan
			best_spawner_cell = spawner_cell
	if best_spawner_cell == INVALID_CELL and fallback_spawner_cell != INVALID_CELL and _spawner_routes.has(fallback_spawner_cell):
		if (_spawner_kind_by_cell.get(fallback_spawner_cell, SPAWNER_KIND_MONSTER) as StringName) != agent_kind:
			return INVALID_CELL
		if _nearest_garden_entry(garden_id, fallback_spawner_cell) != INVALID_CELL:
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
			if _over_garden_threshold_us(this_check_us):
				_warn_garden_task_lag_us("_find_local_retarget_plant.path_check", this_check_us,
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
	if _over_garden_threshold_us(path_checks_us):
		_warn_garden_task_lag_us("_find_local_retarget_plant.path_checks_total", path_checks_us,
			"path_checks=%d failures=%d" % [path_checks, path_failures])
	if _over_garden_threshold_us(total_us):
		push_warning("debug_garden_lag_breakdown:_find_local_retarget_plant total=%.1fms threshold=%dms from=%s radius=%d cells_checked=%d candidates=%d wrong_garden=%d not_edible=%d path_checks=%d path_fail=%d path_checks_total=%.1fms success=%s" % [
			float(total_us) / 1000.0, int(_garden_lag_threshold_ms()), str(from_cell),
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
	_warn_garden_task_lag_us("_try_local_retarget_agent.candidate_search", search_elapsed,
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
	_warn_garden_task_lag_us("_try_local_retarget_agent.assignment", assignment_elapsed,
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
	if not _over_garden_threshold_us(total_us):
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

func _get_or_create_spawner_garden_route(spawner_cell: Vector2i, garden_id: int) -> Dictionary:
	if not _spawner_garden_routes.has(spawner_cell):
		_spawner_garden_routes[spawner_cell] = {}
	var routes: Dictionary = _spawner_garden_routes[spawner_cell] as Dictionary
	var existing_route: Dictionary = routes.get(garden_id, {}) as Dictionary
	if bool(existing_route.get("ready", false)) and int(existing_route.get("plant_group", -1)) > IDLE_GROUP and _garden_route_is_current(existing_route, garden_id):
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
		"ready": true,
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
	if _over_garden_threshold_us(total_us):
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
	var threshold_ms: float = _garden_lag_threshold_ms()
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

# Sub-detectors (all gated on debug_gardens_lag_ms via _warn_garden_task_lag_us) are
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
	_warn_garden_task_lag_us("_retarget_agent_or_escape.validity", lookup_us,
		"nav_id=%d no_plants=%s" % [nav_id_dbg, str(no_plants)])
	if no_plants:
		_last_retarget_profile["reason"] = "no_plants"
		var t_esc0: int = Time.get_ticks_usec()
		var esc0: bool = _assign_agent_to_escape(agent)
		var esc0_us: int = Time.get_ticks_usec() - t_esc0
		_last_retarget_profile["escape_us"] = esc0_us
		_warn_garden_task_lag_us("_retarget_agent_or_escape.escape", esc0_us,
			"nav_id=%d reason=no_plants assigned=%s" % [nav_id_dbg, str(esc0)])
		return esc0

	# Local retarget attempt: radius scan around the agent + per-candidate path checks.
	var local_us: int = Time.get_ticks_usec()
	var local_ok: bool = _try_local_retarget_agent(agent, from_cell, spawner_cell)
	var local_retarget_us: int = Time.get_ticks_usec() - local_us
	_last_retarget_profile["local_retarget_us"] = local_retarget_us
	_warn_garden_task_lag_us("_retarget_agent_or_escape.local_retarget", local_retarget_us,
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
		_warn_garden_task_lag_us("_retarget_agent_or_escape.target_resolve", int(_last_retarget_profile["resolve_us"]),
			"nav_id=%d pair=empty" % nav_id_dbg)
		return _escape_with_detector(agent, nav_id_dbg, "no_pair")
	spawner_cell = pair.get("spawner_cell", INVALID_CELL) as Vector2i
	var garden_id: int = int(pair.get("garden_id", 0))
	if garden_id <= 0:
		_last_retarget_profile["resolve_us"] = Time.get_ticks_usec() - t_res
		_warn_garden_task_lag_us("_retarget_agent_or_escape.target_resolve", int(_last_retarget_profile["resolve_us"]),
			"nav_id=%d garden=0" % nav_id_dbg)
		return _escape_with_detector(agent, nav_id_dbg, "garden<=0")
	var route: Dictionary = _get_or_create_spawner_garden_route(spawner_cell, garden_id)
	if not bool(route.get("ready", false)):
		_last_retarget_profile["resolve_us"] = Time.get_ticks_usec() - t_res
		_warn_garden_task_lag_us("_retarget_agent_or_escape.target_resolve", int(_last_retarget_profile["resolve_us"]),
			"nav_id=%d garden=%d route_not_ready" % [nav_id_dbg, garden_id])
		return _escape_with_detector(agent, nav_id_dbg, "route_not_ready")
	var entry_cell: Vector2i = route.get("entry_cell", INVALID_CELL) as Vector2i
	if entry_cell == INVALID_CELL:
		_last_retarget_profile["resolve_us"] = Time.get_ticks_usec() - t_res
		_warn_garden_task_lag_us("_retarget_agent_or_escape.target_resolve", int(_last_retarget_profile["resolve_us"]),
			"nav_id=%d garden=%d no_entry" % [nav_id_dbg, garden_id])
		return _escape_with_detector(agent, nav_id_dbg, "no_entry")
	var resolve_us: int = Time.get_ticks_usec() - t_res
	_last_retarget_profile["resolve_us"] = resolve_us
	_warn_garden_task_lag_us("_retarget_agent_or_escape.target_resolve", resolve_us,
		"nav_id=%d garden=%d entry=%s" % [nav_id_dbg, garden_id, str(entry_cell)])

	# Final assignment section: attach the garden-entry flow leg.
	var t_fin: int = Time.get_ticks_usec()
	var assigned: bool = _assign_agent_to_garden_entry_flow(agent, spawner_cell, garden_id, entry_cell)
	var fin_us: int = Time.get_ticks_usec() - t_fin
	_last_retarget_profile["assign_us"] = fin_us
	_warn_garden_task_lag_us("_retarget_agent_or_escape.final_assign", fin_us,
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
	_warn_garden_task_lag_us("_retarget_agent_or_escape.escape", esc_us,
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
		if nav_id < 0 or _drowning_agents.has(nav_id) or _escaping_agents.has(nav_id):
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
	_warn_garden_task_lag_us("_retarget_single_waiting_agent", Time.get_ticks_usec() - single_us,
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
	# Sub-warnings are gated on _over_garden_threshold_us so the context string is
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
	if _over_garden_threshold_us(Time.get_ticks_usec() - prep_us):
		_warn_garden_task_lag_us("_find_path_in_zone.prep", Time.get_ticks_usec() - prep_us,
			"garden=%d zone_tiles=%d from=%s to=%s" % [garden_id, zone_tiles.size(), str(from_tile), str(to_tile)])
	# .sync_zone: pushes the walkable set + wall blockers into the pathfinder.
	var sync_us: int = Time.get_ticks_usec()
	_sync_pathfinder_zone_tiles(path_tiles)
	var sync_elapsed: int = Time.get_ticks_usec() - sync_us
	if _over_garden_threshold_us(sync_elapsed):
		_warn_garden_task_lag_us("_find_path_in_zone.sync_zone", sync_elapsed,
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
	if _over_garden_threshold_us(find_elapsed):
		_warn_garden_task_lag_us("_find_path_in_zone.find_path", find_elapsed,
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
		if _over_garden_threshold_us(blocker_elapsed):
			_warn_garden_task_lag_us("_wall_blockers_for_cells", blocker_elapsed,
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
