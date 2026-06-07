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

@export_group("Gardens")
@export var show_gardens: bool = true:
	set(value):
		show_gardens = value
		_apply_debug_settings()

@export var show_monsters_path: bool = false:
	set(value):
		show_monsters_path = value
		_apply_debug_settings()

@onready var tile_hover_info: TileHoverInfo = get_node_or_null("TileHoverInfo") as TileHoverInfo


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
	tile_hover_info.setup(floorz, steering, fps_label, flow, game_ui, building_manager)
	tile_hover_info.set_enabled(debug_enabled)
	tile_hover_info.set_show_monster_paths(show_monsters_path)


func _process(_delta: float) -> void:
	if tile_hover_info:
		tile_hover_info.process()


func _apply_debug_settings() -> void:
	var steering: Node = get_node_or_null("SteeringSystemNative")
	if steering:
		_call_if_available(steering, "set_debug_disable_all_debug", not debug_enabled)
		_call_if_available(steering, "set_debug_draw_world_hitbox", draw_world_hitboxes)
		_call_if_available(steering, "set_debug_draw_fight_hitbox", draw_combat_hitboxes)
		_call_if_available(steering, "set_debug_draw_bottleneck_zones", draw_bottleneck_zones)
		_call_if_available(steering, "set_debug_disable_bottlenecks", disable_bottlenecks)
		_call_if_available(steering, "set_debug_show_agent_state_labels", show_agent_state_labels)
		_call_if_available(steering, "set_debug_redraw_interval", refresh_interval)

	var global_config: Node = get_node_or_null("GlobalConfigNative")
	if global_config:
		_call_if_available(global_config, "set_draw_flow_field", draw_flow_field)
		_call_if_available(global_config, "set_debug_show_plant_zones", show_gardens)

	var flow: Node = get_node_or_null("FlowFieldNative")
	if flow:
		_call_if_available(flow, "set_debug_draw", draw_flow_field)

	if tile_hover_info:
		tile_hover_info.set_enabled(debug_enabled)
		tile_hover_info.set_show_monster_paths(show_monsters_path)


func _call_if_available(target: Node, method_name: StringName, value: Variant) -> void:
	if target.has_method(method_name):
		target.call(method_name, value)
