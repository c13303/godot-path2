class_name CppDebugOptions
extends Node

# ---------------------------------------------------------------------------
# Central console-log gate. Every routine/informational print() in the game is
# routed through dlog()/save_log() below. Error/warning-style prints are left
# alone so real failures stay visible even when debug is off.
#
# These mirrors are static so any script can read them via the global class name
# (CppDebugOptions.logs_enabled) without holding a reference to this node, and so
# they survive a scene reload. They are refreshed inside _apply_debug_settings(),
# which the exported setters run at scene-instantiation time (before any _ready),
# so the effective values are already in place when the earliest logs fire.
static var logs_enabled: bool = false
static var save_logs_enabled: bool = false

## Routine/informational log. Printed only while Debug Enabled is ON.
static func dlog(message: String) -> void:
	if logs_enabled:
		print(message)

## Save-system log (the "[SAVE] ..." lines). Printed only while Debug Enabled is
## ON *and* Save Debug Log is ON, so it can be silenced independently.
static func save_log(message: String) -> void:
	if logs_enabled and save_logs_enabled:
		print(message)

@export_group("Debug")
@export var debug_enabled: bool = false:
	set(value):
		debug_enabled = value
		_apply_debug_settings()

## When ON, dev cheat keys are active: Numpad + grants 100 seeds, gems, money, bamboo,
## walls and watermelons and unlocks every Inventor blueprint during the day, and at
## night skips the night while paying out the loot the night's remaining monsters
## would have dropped.
@export var dev_keys: bool = false:
	set(value):
		dev_keys = value
		_apply_debug_settings()

@export var level_selection: bool = false

## When ON, a fullscreen splash (ROSE2COLERE_SPLASH + music) is shown while the
## game (mainRun) loads, for at least 3 seconds. Read from the mainRun scene file
## by the level menu before the game is instantiated, so it has no runtime effect
## on this node.
@export var show_splashscreen: bool = false

## Set just before reload_current_scene() by the ² dev key so the freshly
## reloaded scene comes up with debug_enabled forced ON, regardless of what the
## scene file / editor had. Static so it survives the scene reload.
static var _force_debug_on_restart: bool = false

@export var draw_world_hitboxes: bool = false:
	set(value):
		draw_world_hitboxes = value
		_apply_debug_settings()

@export var draw_combat_hitboxes: bool = false:
	set(value):
		draw_combat_hitboxes = value
		_apply_debug_settings()

@export var draw_bottleneck_zones: bool = true:
	set(value):
		draw_bottleneck_zones = value
		_apply_debug_settings()

@export var disable_bottlenecks: bool = false:
	set(value):
		disable_bottlenecks = value
		_apply_debug_settings()

@export var show_agent_state_labels: bool = true:
	set(value):
		show_agent_state_labels = value
		_apply_debug_settings()

## Seconds between debug overlay redraws (hitboxes, labels, zones).
## 0 = redraw every frame (in sync, full cost). Higher = more optimized, more desync.
@export_range(0.0, 1.0, 0.0166, "or_greater") var refresh_interval: float = 0.2:
	set(value):
		refresh_interval = value
		_apply_debug_settings()

@export var draw_flow_field: bool = false:
	set(value):
		draw_flow_field = value
		_apply_debug_settings()

## When on, BuildingManager prints "x gardens recomputed with y entry points"
## every time gardens (and their entry points) are recomputed.
@export var verbose: bool = false:
	set(value):
		verbose = value
		_apply_debug_settings()

@export_group("Save")
## Gates the "[SAVE] ..." save/progression console logs. When OFF, those lines
## are hidden even while Debug Enabled is ON. (When Debug Enabled is OFF they are
## hidden regardless, like every other debug log.)
@export var save_debug_log: bool = false:
	set(value):
		save_debug_log = value
		_apply_debug_settings()

@export_group("Gardens")
@export var debug_rose_harvest_telemetry: bool = false:
	set(value):
		debug_rose_harvest_telemetry = value
		_apply_debug_settings()

@export_range(0.0, 100.0, 0.1, "or_greater") var debug_rose_harvest_warn_ms: float = 1.0:
	set(value):
		debug_rose_harvest_warn_ms = value
		_apply_debug_settings()

@export var show_gardens: bool = true:
	set(value):
		show_gardens = value
		_apply_debug_settings()

@export var show_monsters_path: bool = false:
	set(value):
		show_monsters_path = value
		_apply_debug_settings()

@export var show_enters_exits: bool = false:
	set(value):
		show_enters_exits = value
		_apply_debug_settings()

@export var click_log_agents: bool = true
@export_range(1.0, 128.0, 1.0, "or_greater") var click_agent_radius: float = 32.0

@export_group("Monsters")
## Seconds a monster spends eating a plant before leaving the garden.
@export_range(0.0, 60.0, 0.1, "or_greater") var monster_eating_time: float = 5.0:
	set(value):
		monster_eating_time = value
		_apply_debug_settings()

## Number of roses a monster eats before it becomes full and leaves.
@export_range(1, 64, 1, "or_greater") var number_of_roses_before_satiety: int = 3:
	set(value):
		number_of_roses_before_satiety = value
		_apply_debug_settings()

## When enabled, a monster leaves once its current garden is empty.
@export var same_garden_only: bool = false:
	set(value):
		same_garden_only = value
		_apply_debug_settings()

## Global speed multiplier applied at startup. 1.0 = no change.
## Scales monster movement speed and player speed (x mult), and the
## eating delay (/ mult, so >1 eats faster). Weapons are unaffected.
## Read once when the scene starts; only affects monsters spawned afterwards.
@export_range(0.1, 10.0, 0.1, "or_greater") var speed_multiplier: float = 1.0:
	set(value):
		speed_multiplier = value
		_apply_debug_settings()

@export_group("Pathfinding Garden")
@export_range(0, 32, 1, "or_greater") var empty_garden_local_retarget_radius: int = 5:
	set(value):
		empty_garden_local_retarget_radius = value
		_apply_debug_settings()

@export_group("Movement Tuning")
@export_range(0.0, 1.0, 0.01, "or_greater") var bottleneck_wait_speed_ratio: float = 0.05:
	set(value):
		bottleneck_wait_speed_ratio = value
		_apply_debug_settings()

@export_range(0.0, 1.0, 0.01, "or_greater") var bottleneck_backward_push_ratio: float = 0.15:
	set(value):
		bottleneck_backward_push_ratio = value
		_apply_debug_settings()

@export_range(0.0, 3.0, 0.05, "or_greater") var bottleneck_lateral_push_ratio: float = 1.0:
	set(value):
		bottleneck_lateral_push_ratio = value
		_apply_debug_settings()

@export_range(0.0, 1.0, 0.01, "or_greater") var priority_separation_bias: float = 0.30:
	set(value):
		priority_separation_bias = value
		_apply_debug_settings()

@export_group("Navigation Debug")
## Threshold (ms) for the TOTAL BuildingManager navigation/gameplay frame cost.
## If BuildingManager._process() exceeds this duration, a "debug_nav_total_frame_lag"
## warning is pushed. This is the broad whole-frame detector — it tells you the frame
## was slow, not which task caused it (use debug_gardens_lag_ms for that).
@export_range(0.0, 1000.0, 1.0, "or_greater") var lag_detect_fps_threshold_ms: float = 35.0:
	set(value):
		lag_detect_fps_threshold_ms = value
		_apply_debug_settings()

@export_range(0.0, 1000.0, 1.0, "or_greater") var debug_flowfield_rebuild_lag_ms: float = 35.0:
	set(value):
		debug_flowfield_rebuild_lag_ms = value
		_apply_debug_settings()

@export_group("Garden Lag Debug")
## Threshold (ms) for an INDIVIDUAL garden/navigation task inside BuildingManager
## (eating, plant removal, retargeting, A* out, pathfinder zone sync, find_path,
## scan buildings, route rebuilds, etc.). When one of those blocks exceeds this, a
## granular "debug_garden_lag:<task>" warning identifies the exact expensive task.
## BuildingManager reads this value directly off this node. 0 disables the per-task
## warnings. Read directly (not pushed to C++).
@export_range(0.0, 1000.0, 1.0, "or_greater") var debug_gardens_lag_ms: float = 15.0:
	set(value):
		debug_gardens_lag_ms = value
		_apply_debug_settings()

@onready var tile_hover_info: TileHoverInfo = get_node_or_null("TileHoverInfo") as TileHoverInfo
var _building_manager: Node
## Cached PlayerController, used to allow click-log-agent while the game is paused.
var _player_controller: Node
## The top-left FPS/agent-count debug label, gated by debug_enabled.
var _fps_label: Label
## Unmultiplied agent_max_speed, captured once before the multiplier is applied.
var _base_agent_max_speed: float = -1.0


func _ready() -> void:
	if _force_debug_on_restart:
		_force_debug_on_restart = false
		debug_enabled = true
	_apply_debug_settings()
	_setup_tile_hover_info()
	_setup_registration_watcher()


## Creates the single agent-registration consistency watcher as a child beside
## the native nodes. All consistency logic lives in the watcher; it self-gates on
## CppDebugOptions.logs_enabled, so nothing extra is wired here.
func _setup_registration_watcher() -> void:
	if get_node_or_null("AgentRegistrationConsistencyWatcher") != null:
		return
	var watcher: AgentRegistrationConsistencyWatcher = AgentRegistrationConsistencyWatcher.new()
	watcher.name = "AgentRegistrationConsistencyWatcher"
	add_child(watcher)


func _setup_tile_hover_info() -> void:
	if not tile_hover_info:
		return
	var scene: Node = get_tree().get_current_scene()
	if not scene:
		return
	var floorz: TileMapLayer = scene.get_node_or_null("Map/MonTilemap/floor") as TileMapLayer
	var steering: Node = get_node_or_null("CrowdRuntime")
	var flow: Node = get_node_or_null("NavigationRuntime")
	var fps_label: Label = scene.get_node_or_null("GameUI/CanvasLayer/CPP_Debug_Label") as Label
	_fps_label = fps_label
	var game_ui: Node = scene.get_node_or_null("GameUI")
	var building_manager: Node = scene.get_node_or_null("Map/BuildingManager")
	_building_manager = building_manager
	tile_hover_info.setup(floorz, steering, fps_label, flow, game_ui, building_manager)
	tile_hover_info.set_enabled(debug_enabled)
	tile_hover_info.set_show_monster_paths(show_monsters_path)


func _process(_delta: float) -> void:
	if tile_hover_info:
		tile_hover_info.process()

func _input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mouse_event: InputEventMouseButton = event as InputEventMouseButton
	if not mouse_event.pressed or mouse_event.button_index != MOUSE_BUTTON_LEFT:
		return
	if get_viewport().gui_get_hovered_control() != null:
		return
	# Draw Flow Field is per-agent: clicking an agent selects its flow field to render
	# (clicking empty space clears it). Only while Debug Enabled + Draw Flow Field are on.
	if debug_enabled and draw_flow_field:
		_select_flow_field_for_clicked_agent()
	# The click-log normally requires Debug Enabled, but it is also allowed while the game
	# is paused so an agent can be inspected on a frozen frame even with debug off.
	if click_log_agents and (debug_enabled or _is_game_paused()):
		_log_clicked_agent_debug_snapshot()


## Point the flow-field debug overlay at the clicked agent's group (0 = clear). Falls back
## to the group the agent is waiting on when it has not been attached to a routing group yet.
func _select_flow_field_for_clicked_agent() -> void:
	var flow: Node = get_node_or_null("NavigationRuntime")
	if flow == null or not flow.has_method("set_debug_draw_group"):
		return
	var clicked_agent: Node2D = _nearest_clicked_agent()
	if clicked_agent == null:
		flow.call("set_debug_draw_group", 0)
		return
	var nav_id: int = int(clicked_agent.get("nav_id"))
	if nav_id < 0:
		return
	var group_id: int = 0
	var steering: Node = get_node_or_null("CrowdRuntime")
	if steering and steering.has_method("get_agent_debug_snapshot"):
		var snapshot: Dictionary = steering.call("get_agent_debug_snapshot", nav_id) as Dictionary
		group_id = int(snapshot.get("group", 0))
		if group_id <= 0:
			group_id = int(snapshot.get("waiting_flow_group", 0))
	flow.call("set_debug_draw_group", group_id)


## True while the game is paused, resolved via the PlayerController. Used so the
## click-log-agent event stays available on a paused frame even when debug is off.
func _is_game_paused() -> bool:
	if _player_controller == null or not is_instance_valid(_player_controller):
		var scene: Node = get_tree().get_current_scene() if is_inside_tree() else null
		if scene:
			_player_controller = scene.get_node_or_null("Player/PlayerController")
	if _player_controller and _player_controller.has_method("is_paused"):
		return bool(_player_controller.call("is_paused"))
	return false


## Dev cheat keys, gated behind dev_keys. Numpad + resolves to exactly one of three
## exclusive actions depending on the phase: at night it skips the night (removes
## every monster, ends the night) and pays out the loot the night would still have
## produced, so skipping does not cost the run its drops; while the day's client step
## is pending or active it only skips that step (see _skip_dev_client_sale); outside
## both it refills the water reserve, grants 100 seeds/gems/money/bamboo plus 100 walls
## and 100 watermelons, and unlocks every Inventor blueprint.
## Any of those cases first instantly ends a running night/client reveal cutscene and
## snaps the camera back to the player.
## Numpad 1/2 spawn one monster on the mouse tile, attributed to the first
## registered enemy spawner. Numpad 0 spawns one client from each client spawner.
## K completes every WIP house.
## F1 advances the current day, but only while daytime is active.
## ² (top-left key) restarts the level with debug forced ON.
func _unhandled_input(event: InputEvent) -> void:
	if not dev_keys or not (event is InputEventKey):
		return
	var key_event: InputEventKey = event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return
	if key_event.keycode == KEY_KP_ADD:
		get_viewport().set_input_as_handled()
		_handle_dev_skip_key()
	elif _is_key(key_event, KEY_KP_1):
		get_viewport().set_input_as_handled()
		_spawn_dev_monster_at_mouse(&"basic")
	elif _is_key(key_event, KEY_KP_2):
		get_viewport().set_input_as_handled()
		_spawn_dev_monster_at_mouse(&"bigmonster")
	elif _is_key(key_event, KEY_KP_0):
		get_viewport().set_input_as_handled()
		_spawn_dev_agents_from_spawners(&"client", &"basic")
	elif _is_key(key_event, KEY_K):
		get_viewport().set_input_as_handled()
		_complete_dev_wip_houses()
	elif key_event.keycode == KEY_F1 and not GameState.is_night:
		get_viewport().set_input_as_handled()
		_advance_dev_day()
	elif _is_restart_debug_key(key_event):
		get_viewport().set_input_as_handled()
		_restart_level_with_debug()


## True for the ² key. Matched by physical position (grave/tilde key on US
## layouts, ² on French AZERTY) so it works regardless of keyboard layout, with
## the ² unicode (178) as a fallback.
func _is_restart_debug_key(key_event: InputEventKey) -> bool:
	return key_event.physical_keycode == KEY_QUOTELEFT \
		or key_event.keycode == KEY_QUOTELEFT \
		or key_event.unicode == 0xB2


func _is_key(key_event: InputEventKey, key: Key) -> bool:
	return key_event.physical_keycode == key or key_event.keycode == key


## Reloads the current scene with debug_enabled forced ON in the reloaded scene.
func _restart_level_with_debug() -> void:
	_force_debug_on_restart = true
	get_tree().reload_current_scene()


func _get_progression() -> Node:
	var scene: Node = get_tree().current_scene if is_inside_tree() else null
	return scene.get_node_or_null("progression") if scene else null


## The three Numpad + actions are exclusive and resolved in phase order: skip the
## night, else skip the day's client step, else grant the plain day cheats.
func _handle_dev_skip_key() -> void:
	# A running spawner-reveal cutscene (night or client) is ended instantly first, so the
	# camera snaps back to the player before the skip runs instead of finishing its pan.
	_abort_active_reveal_cutscene()
	if GameState.is_night:
		# The night loot must be counted before _end_dev_night() clears the monsters.
		_grant_skipped_night_loot()
		_refill_dev_water_reserve()
		_end_dev_night()
		return
	if _skip_dev_client_sale():
		return
	_grant_dev_currency()
	_refill_dev_water_reserve()


## Ends the day's client step: every remaining client is consumed for 1 money and
## removed, the counters are emptied and the morning is completed. True once the key
## was consumed here, i.e. a client step was pending or active; false on any other day
## frame, where the caller falls back to the plain day cheats.
func _skip_dev_client_sale() -> bool:
	var manager: Node = _get_building_manager()
	if manager == null or not manager.has_method("skip_current_client_sale_for_dev"):
		return false
	var consumed: int = int(manager.call("skip_current_client_sale_for_dev"))
	if consumed < 0:
		return false
	CppDebugOptions.dlog("dev_keys: client skip consumed %d client(s) for %d money" % [consumed, consumed])
	return true


func _grant_dev_currency() -> void:
	var progression: Node = _get_progression()
	if progression == null:
		push_warning("dev_keys: progression node not found")
		return
	_call_if_available(progression, "update_seeds", 100)
	_call_if_available(progression, "update_gems", 100)
	_call_if_available(progression, "update_money", 100)
	_call_if_available(progression, "update_bamboo", 100)
	_grant_dev_inventory_item("wall", 100)
	_grant_dev_inventory_item("pasteque", 100)
	_unlock_all_dev_blueprints(progression)


## Grants an inventory-backed item straight into the player's inventory. Silently
## no-ops when the GameUI or its inventory API is missing, or when the inventory is full.
func _grant_dev_inventory_item(item_id: String, count: int) -> void:
	var game_ui: Node = _get_game_ui()
	if game_ui == null or not game_ui.has_method("add_inventory"):
		push_warning("dev_keys: GameUI inventory API not found")
		return
	game_ui.call("add_inventory", item_id, count)


## Unlocks every Inventor blueprint. Progression owns the blueprint list, so blueprints
## added later are covered without touching this cheat.
func _unlock_all_dev_blueprints(progression: Node) -> void:
	if not progression.has_method("unlock_all_blueprints_for_dev"):
		push_warning("dev_keys: progression blueprint unlock API not found")
		return
	if bool(progression.call("unlock_all_blueprints_for_dev")):
		CppDebugOptions.dlog("dev_keys: unlocked all Inventor blueprints")


func _get_game_ui() -> Node:
	var scene: Node = get_tree().current_scene if is_inside_tree() else null
	return scene.get_node_or_null("GameUI") if scene else null


## Pays out the loot the current night would still have produced, so a skipped
## night is worth the same as a fought one. A monster drops exactly one seed or
## gem when it dies, so the payout is one drop per remaining monster: those alive
## on the map plus those the playlist has not spawned yet.
##
## Unlike a real death, the seed/gem mix is a deterministic split on the night's
## seed-drop chance instead of a per-monster roll, so the key pays the same every
## time. Currency is credited directly rather than dropped as collectibles.
##
## Must be called before the night is ended, while the monsters still exist.
func _grant_skipped_night_loot() -> void:
	var manager: Node = _get_building_manager()
	if manager == null:
		push_warning("dev_keys: BuildingManager node not found")
		return
	if not manager.has_method("remaining_planificator_enemy_count") \
		or not manager.has_method("monster_death_drop_seed_chance_percent"):
		push_warning("dev_keys: BuildingManager night-loot queries not found")
		return
	var monster_count: int = int(manager.call("remaining_planificator_enemy_count"))
	if monster_count <= 0:
		return
	var progression: Node = _get_progression()
	if progression == null:
		push_warning("dev_keys: progression node not found")
		return
	var seed_chance_percent: int = clampi(int(manager.call("monster_death_drop_seed_chance_percent")), 0, 100)
	@warning_ignore("integer_division")
	var seed_count: int = monster_count * seed_chance_percent / 100
	var gem_count: int = monster_count - seed_count
	if seed_count > 0:
		_call_if_available(progression, "update_seeds", seed_count)
	if gem_count > 0:
		_call_if_available(progression, "update_gems", gem_count)
	CppDebugOptions.dlog("dev_keys: night skip paid %d seed(s) + %d gem(s) for %d remaining monster(s)" % [seed_count, gem_count, monster_count])


## Instantly ends any running night/client reveal cutscene and returns the camera to the
## player. Safe no-op when no cutscene is playing or the command is unavailable.
func _abort_active_reveal_cutscene() -> void:
	var manager: Node = _get_building_manager()
	if manager != null and manager.has_method("abort_active_reveal_cutscene_for_dev"):
		manager.call("abort_active_reveal_cutscene_for_dev")


func _complete_dev_wip_houses() -> void:
	var manager: Node = _get_building_manager()
	if manager == null:
		push_warning("dev_keys: BuildingManager node not found")
		return
	if not manager.has_method("complete_all_wip_houses_for_dev"):
		push_warning("dev_keys: BuildingManager house completion command not found")
		return
	var completed: int = int(manager.call("complete_all_wip_houses_for_dev"))
	CppDebugOptions.dlog("dev_keys: completed %d WIP house(s)" % completed)


func _advance_dev_day() -> void:
	var progression: Node = _get_progression()
	if progression == null:
		push_warning("dev_keys: progression node not found")
		return
	if progression.has_method("advance_day"):
		progression.call("advance_day")


func _spawn_dev_monster_at_mouse(monster_type: StringName) -> void:
	var manager: Node = _get_building_manager()
	if manager == null:
		push_warning("dev_keys: BuildingManager node not found")
		return
	if not manager.has_method("get_spawners") \
		or not manager.has_method("spawner_kind_by_cell") \
		or not manager.has_method("world_to_cell") \
		or not manager.has_method("spawn_monster_at_cell"):
		push_warning("dev_keys: BuildingManager mouse-spawn API not found")
		return
	var spawners: Dictionary = manager.call("get_spawners") as Dictionary
	var spawner_kind_by_cell: Dictionary = manager.call("spawner_kind_by_cell") as Dictionary
	for raw_cell: Variant in spawners.keys():
		var spawner_cell: Vector2i = raw_cell as Vector2i
		var kind: StringName = spawner_kind_by_cell.get(spawner_cell, &"monster") as StringName
		if kind != &"monster":
			continue
		var spawn_cell: Vector2i = manager.call("world_to_cell", _mouse_world_position()) as Vector2i
		var spawned: bool = bool(manager.call("spawn_monster_at_cell", spawner_cell, spawn_cell, monster_type))
		CppDebugOptions.dlog("dev_keys: mouse-spawned %s=%s at %s from spawner %s" % [
			String(monster_type),
			str(spawned),
			str(spawn_cell),
			str(spawner_cell),
		])
		return
	push_warning("dev_keys: no registered monster spawner found")


func _spawn_dev_agents_from_spawners(spawner_kind: StringName, monster_type: StringName) -> void:
	var manager: Node = _get_building_manager()
	if manager == null:
		push_warning("dev_keys: BuildingManager node not found")
		return
	if not manager.has_method("get_spawners") or not manager.has_method("spawner_kind_by_cell"):
		push_warning("dev_keys: BuildingManager spawner query methods not found")
		return
	var spawners: Dictionary = manager.call("get_spawners") as Dictionary
	var spawner_kind_by_cell: Dictionary = manager.call("spawner_kind_by_cell") as Dictionary
	var attempted: int = 0
	var spawned: int = 0
	for raw_cell: Variant in spawners.keys():
		var spawner_cell: Vector2i = raw_cell as Vector2i
		var kind: StringName = spawner_kind_by_cell.get(spawner_cell, &"monster") as StringName
		if kind != spawner_kind:
			continue
		attempted += 1
		if _spawn_dev_agent_from_spawner(manager, spawner_cell, spawner_kind, monster_type):
			spawned += 1
	CppDebugOptions.dlog("dev_keys: spawned %d/%d %s agents from registered spawners" % [
		spawned,
		attempted,
		String(spawner_kind)
	])


func _spawn_dev_agent_from_spawner(manager: Node, spawner_cell: Vector2i, spawner_kind: StringName, monster_type: StringName) -> bool:
	if spawner_kind == &"client":
		if manager.has_method("spawn_client_from_spawner"):
			return bool(manager.call("spawn_client_from_spawner", spawner_cell))
		return false
	if manager.has_method("spawn_monster_from_spawner"):
		return bool(manager.call("spawn_monster_from_spawner", spawner_cell, monster_type))
	return false


func _get_building_manager() -> Node:
	if _building_manager != null and is_instance_valid(_building_manager):
		return _building_manager
	var scene: Node = get_tree().get_current_scene() if is_inside_tree() else null
	if scene:
		_building_manager = scene.get_node_or_null("Map/BuildingManager")
	return _building_manager


## Tops the player's water reserve back up to its current maximum.
func _refill_dev_water_reserve() -> void:
	var scene: Node = get_tree().current_scene if is_inside_tree() else null
	var progression: Node = scene.get_node_or_null("progression") if scene else null
	if progression == null:
		push_warning("dev_keys: progression node not found")
		return
	if not progression.has_method("get_value") or not progression.has_method("update_value"):
		return
	var current: int = int(progression.call("get_value", &"water_reserve"))
	var maximum: int = int(progression.call("get_value", &"water_reserve_max"))
	if current < maximum:
		progression.call("update_value", &"water_reserve", maximum - current, 0, maximum)


## When night is active, removes every monster (no death drop) and flips back to
## day. No-op during daytime. Uses the same authoritative despawn path as combat
## deaths so native agents are unregistered cleanly.
func _end_dev_night() -> void:
	if not GameState.is_night:
		return
	var manager: Node = _get_building_manager()
	if manager and manager.has_method("skip_current_night_for_dev"):
		manager.call("skip_current_night_for_dev")
		return
	for node: Node in get_tree().get_nodes_in_group(&"monsters"):
		var agent: Node2D = node as Node2D
		if agent != null and is_instance_valid(agent):
			agent.queue_free()
	GameState.start_day()


func _log_clicked_agent_debug_snapshot() -> void:
	var steering: Node = get_node_or_null("CrowdRuntime")
	if steering == null or not steering.has_method("get_agent_debug_snapshot"):
		return
	var clicked_agent: Node2D = _nearest_clicked_agent()
	if clicked_agent == null:
		return
	var nav_id: int = int(clicked_agent.get("nav_id"))
	if nav_id < 0:
		return
	var snapshot: Dictionary = steering.call("get_agent_debug_snapshot", nav_id) as Dictionary
	if snapshot.is_empty():
		print("Agent debug click: no native snapshot for nav_id=", nav_id, " node=", clicked_agent.name)
		return
	snapshot["node"] = clicked_agent.name
	snapshot["node_status"] = str(clicked_agent.get("status"))
	snapshot["node_position"] = clicked_agent.global_position
	snapshot["click_world"] = _mouse_world_position()
	print("Agent debug click:\n", JSON.stringify(snapshot, "\t"))

func _nearest_clicked_agent() -> Node2D:
	var scene: Node = get_tree().get_current_scene()
	if scene == null:
		return null
	var click_world: Vector2 = _mouse_world_position()
	var best_agent: Node2D = null
	var best_distance_squared: float = click_agent_radius * click_agent_radius
	var inspected_agents: Dictionary = {}
	var inspect_groups: Array[StringName] = [&"monsters", AgentDefinitionService.VILLAGERS_GROUP]
	for group_name: StringName in inspect_groups:
		for raw_agent: Node in get_tree().get_nodes_in_group(group_name):
			var agent: Node2D = raw_agent as Node2D
			if agent == null or not is_instance_valid(agent):
				continue
			var instance_id: int = agent.get_instance_id()
			if inspected_agents.has(instance_id):
				continue
			inspected_agents[instance_id] = true
			var distance_squared: float = agent.global_position.distance_squared_to(click_world)
			if distance_squared <= best_distance_squared:
				best_distance_squared = distance_squared
				best_agent = agent
	return best_agent

func _mouse_world_position() -> Vector2:
	var viewport: Viewport = get_viewport()
	var camera: Camera2D = viewport.get_camera_2d()
	if camera:
		return camera.get_global_mouse_position()
	var scene: Node = get_tree().get_current_scene()
	if scene is CanvasItem:
		var canvas_scene: CanvasItem = scene as CanvasItem
		return canvas_scene.get_global_mouse_position()
	return viewport.get_mouse_position()


func _apply_debug_settings() -> void:
	# Master gate: when debug_enabled is OFF, every debug DRAW / overlay / console
	# option in every section is forced off, regardless of its own value. Only
	# pure gameplay/AI tuning (eating time, speed multiplier, retarget radius, lag
	# thresholds, refresh interval) is left untouched so disabling debug never
	# changes how the game actually plays. Compute the effective (gated) value of
	# each debug-only flag once, here.
	var dbg: bool = debug_enabled
	# Refresh the static console-log gates read by dlog()/save_log() everywhere.
	logs_enabled = dbg
	save_logs_enabled = save_debug_log
	var eff_world_hitboxes: bool = draw_world_hitboxes and dbg
	var eff_combat_hitboxes: bool = draw_combat_hitboxes and dbg
	var eff_bottleneck_zones: bool = draw_bottleneck_zones and dbg
	var eff_disable_bottlenecks: bool = disable_bottlenecks
	var eff_agent_labels: bool = show_agent_state_labels and dbg
	var eff_flow_field: bool = draw_flow_field and dbg
	var eff_gardens: bool = show_gardens and dbg
	var eff_monsters_path: bool = show_monsters_path and dbg
	var eff_enters_exits: bool = show_enters_exits and dbg
	var eff_verbose: bool = verbose and dbg

	var steering: Node = get_node_or_null("CrowdRuntime")
	if steering:
		_call_if_available(steering, "set_debug_disable_all_debug", not dbg)
		_call_if_available(steering, "set_debug_draw_world_hitbox", eff_world_hitboxes)
		_call_if_available(steering, "set_debug_draw_fight_hitbox", eff_combat_hitboxes)
		_call_if_available(steering, "set_debug_draw_bottleneck_zones", eff_bottleneck_zones)
		_call_if_available(steering, "set_debug_disable_bottlenecks", eff_disable_bottlenecks)
		_call_if_available(steering, "set_debug_show_agent_state_labels", eff_agent_labels)
		_call_if_available(steering, "set_debug_redraw_interval", refresh_interval)

	var global_config: Node = get_node_or_null("SimulationConfig")
	if global_config:
		_call_if_available(global_config, "set_draw_flow_field", eff_flow_field)
		_call_first_available(global_config, [
			&"set_debug_show_zones",
			&"set_debug_show_plant_zones"
		], eff_gardens)
		# Lag thresholds are tuning, not visuals: applied regardless of debug_enabled.
		# The native method names are kept (set_debug_nav_frame_lag_ms) for compat;
		# only the exported variable was renamed to lag_detect_fps_threshold_ms.
		_call_first_available(global_config, [
			&"set_debug_nav_frame_lag_ms",
			&"set_debug_plantff_frame_lag_ms"
		], lag_detect_fps_threshold_ms)
		_call_first_available(global_config, [
			&"set_debug_flowfield_rebuild_lag_ms",
			&"set_debug_plantff_ff_lag_ms"
		], debug_flowfield_rebuild_lag_ms)
		_call_if_available(global_config, "set_bottleneck_wait_speed_ratio", bottleneck_wait_speed_ratio)
		_call_if_available(global_config, "set_bottleneck_backward_push_ratio", bottleneck_backward_push_ratio)
		_call_if_available(global_config, "set_bottleneck_lateral_push_ratio", bottleneck_lateral_push_ratio)
		_call_if_available(global_config, "set_priority_separation_bias", priority_separation_bias)
		_apply_speed_multiplier(global_config)

	var flow: Node = get_node_or_null("NavigationRuntime")
	if flow:
		_call_if_available(flow, "set_debug_draw", eff_flow_field)

	if tile_hover_info:
		tile_hover_info.set_enabled(dbg)
		tile_hover_info.set_show_monster_paths(eff_monsters_path)

	if _fps_label == null:
		var label_scene: Node = get_tree().get_current_scene() if is_inside_tree() else null
		if label_scene:
			_fps_label = label_scene.get_node_or_null("GameUI/CanvasLayer/CPP_Debug_Label") as Label
	if _fps_label:
		_fps_label.set_enabled(dbg)

	if _building_manager == null:
		var scene: Node = get_tree().get_current_scene() if is_inside_tree() else null
		if scene:
			_building_manager = scene.get_node_or_null("Map/BuildingManager")
	if _building_manager:
		_call_if_available(_building_manager, "set_show_enters_exits", eff_enters_exits)
		_call_if_available(_building_manager, "set_verbose", eff_verbose)
		# Gameplay/AI tuning: applied regardless of debug_enabled.
		_call_if_available(_building_manager, "set_empty_garden_local_retarget_radius", empty_garden_local_retarget_radius)
		# Eating delay is divided by the multiplier so >1 means "eats faster".
		var mult: float = maxf(0.0001, speed_multiplier)
		_call_if_available(_building_manager, "set_eating_time", monster_eating_time / mult)
		_call_if_available(_building_manager, "set_number_of_roses_before_satiety", number_of_roses_before_satiety)
		_call_if_available(_building_manager, "set_same_garden_only", same_garden_only)


## Pushes agent_max_speed = base * speed_multiplier to the native global config.
## Captures the unmultiplied base the first time so re-applies don't compound.
func _apply_speed_multiplier(global_config: Node) -> void:
	if not global_config.has_method("get_agent_max_speed") or not global_config.has_method("set_agent_max_speed"):
		return
	if _base_agent_max_speed < 0.0:
		_base_agent_max_speed = float(global_config.call("get_agent_max_speed"))
	global_config.call("set_agent_max_speed", _base_agent_max_speed * maxf(0.0001, speed_multiplier))


## Effective speed multiplier, read by other systems (e.g. the player) so they
## can scale their own speed consistently with the monsters.
func get_speed_multiplier() -> float:
	return maxf(0.0001, speed_multiplier)


func _call_if_available(target: Node, method_name: StringName, value: Variant) -> void:
	if target.has_method(method_name):
		target.call(method_name, value)


func _call_first_available(target: Node, method_names: Array[StringName], value: Variant) -> void:
	for method_name in method_names:
		if target.has_method(method_name):
			target.call(method_name, value)
			return
