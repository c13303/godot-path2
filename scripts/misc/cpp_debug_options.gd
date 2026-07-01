extends Node

@export_group("Debug")
@export var debug_enabled: bool = false:
	set(value):
		debug_enabled = value
		_apply_debug_settings()

## When ON, dev cheat keys are active: Numpad + grants 100 seeds, gems, and money.
@export var dev_keys: bool = false:
	set(value):
		dev_keys = value
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
## The top-left FPS/agent-count debug label, gated by debug_enabled.
var _fps_label: Label
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
	if not debug_enabled or not click_log_agents:
		return
	if not (event is InputEventMouseButton):
		return
	var mouse_event: InputEventMouseButton = event as InputEventMouseButton
	if not mouse_event.pressed or mouse_event.button_index != MOUSE_BUTTON_LEFT:
		return
	if get_viewport().gui_get_hovered_control() != null:
		return
	_log_clicked_agent_debug_snapshot()


## Dev cheat keys, gated behind dev_keys. Numpad + grants 100 seeds, gems, and money.
func _unhandled_input(event: InputEvent) -> void:
	if not dev_keys or not (event is InputEventKey):
		return
	var key_event: InputEventKey = event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return
	if key_event.keycode == KEY_KP_ADD:
		get_viewport().set_input_as_handled()
		_grant_dev_currency()


func _grant_dev_currency() -> void:
	var scene: Node = get_tree().current_scene if is_inside_tree() else null
	var progression: Node = scene.get_node_or_null("progression") if scene else null
	if progression == null:
		push_warning("dev_keys: progression node not found")
		return
	_call_if_available(progression, "update_seeds", 100)
	_call_if_available(progression, "update_gems", 100)
	_call_if_available(progression, "update_money", 100)

func _log_clicked_agent_debug_snapshot() -> void:
	var steering: Node = get_node_or_null("SteeringSystemNative")
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
	for raw_agent: Node in get_tree().get_nodes_in_group(&"monsters"):
		var agent: Node2D = raw_agent as Node2D
		if agent == null or not is_instance_valid(agent):
			continue
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
		_call_if_available(global_config, "set_bottleneck_wait_speed_ratio", bottleneck_wait_speed_ratio)
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
