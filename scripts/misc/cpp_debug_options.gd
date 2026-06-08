extends Node

@export_group("Debug")
@export var debug_enabled: bool = false:
	set(value):
		debug_enabled = value
		_apply_debug_settings()

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

@export_group("Gardens")
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

@export_group("Monsters")
## Seconds a monster spends eating a plant before leaving the garden.
@export_range(0.0, 60.0, 0.1, "or_greater") var monster_eating_time: float = 5.0:
	set(value):
		monster_eating_time = value
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
## Unmultiplied agent_max_speed, captured once before the multiplier is applied.
var _base_agent_max_speed: float = -1.0


func _ready() -> void:
	_apply_debug_settings()
	_setup_tile_hover_info()


func _setup_tile_hover_info() -> void:
	if not tile_hover_info:
		return
	var scene: Node = get_tree().get_current_scene()
	if not scene:
		return
	var floorz: TileMapLayer = scene.get_node_or_null("Map/MonTilemap/floor") as TileMapLayer
	var steering: Node = get_node_or_null("SteeringSystemNative")
	var flow: Node = get_node_or_null("FlowFieldNative")
	var fps_label: Label = scene.get_node_or_null("GameUI/CanvasLayer/Label") as Label
	var game_ui: Node = scene.get_node_or_null("GameUI")
	var building_manager: Node = scene.get_node_or_null("Map/BuildingManager")
	_building_manager = building_manager
	tile_hover_info.setup(floorz, steering, fps_label, flow, game_ui, building_manager)
	tile_hover_info.set_enabled(debug_enabled)
	tile_hover_info.set_show_monster_paths(show_monsters_path)


func _process(_delta: float) -> void:
	if tile_hover_info:
		tile_hover_info.process()


func _apply_debug_settings() -> void:
	# Master gate: when debug_enabled is OFF, every debug DRAW / overlay / console
	# option in every section is forced off, regardless of its own value. Only
	# pure gameplay/AI tuning (eating time, speed multiplier, retarget radius, lag
	# thresholds, refresh interval) is left untouched so disabling debug never
	# changes how the game actually plays. Compute the effective (gated) value of
	# each debug-only flag once, here.
	var dbg: bool = debug_enabled
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

	var steering: Node = get_node_or_null("SteeringSystemNative")
	if steering:
		_call_if_available(steering, "set_debug_disable_all_debug", not dbg)
		_call_if_available(steering, "set_debug_draw_world_hitbox", eff_world_hitboxes)
		_call_if_available(steering, "set_debug_draw_fight_hitbox", eff_combat_hitboxes)
		_call_if_available(steering, "set_debug_draw_bottleneck_zones", eff_bottleneck_zones)
		_call_if_available(steering, "set_debug_disable_bottlenecks", eff_disable_bottlenecks)
		_call_if_available(steering, "set_debug_show_agent_state_labels", eff_agent_labels)
		_call_if_available(steering, "set_debug_redraw_interval", refresh_interval)

	var global_config: Node = get_node_or_null("GlobalConfigNative")
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
		_call_if_available(global_config, "set_bottleneck_backward_push_ratio", bottleneck_backward_push_ratio)
		_call_if_available(global_config, "set_bottleneck_lateral_push_ratio", bottleneck_lateral_push_ratio)
		_call_if_available(global_config, "set_priority_separation_bias", priority_separation_bias)
		_apply_speed_multiplier(global_config)

	var flow: Node = get_node_or_null("FlowFieldNative")
	if flow:
		_call_if_available(flow, "set_debug_draw", eff_flow_field)

	if tile_hover_info:
		tile_hover_info.set_enabled(dbg)
		tile_hover_info.set_show_monster_paths(eff_monsters_path)

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
