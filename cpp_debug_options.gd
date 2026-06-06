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

@export var draw_flow_field: bool = false:
	set(value):
		draw_flow_field = value
		_apply_debug_settings()

@export var show_plant_zones: bool = true:
	set(value):
		show_plant_zones = value
		_apply_debug_settings()


func _ready() -> void:
	_apply_debug_settings()


func _apply_debug_settings() -> void:
	var steering: Node = get_node_or_null("SteeringSystemNative")
	if steering:
		_call_if_available(steering, "set_debug_disable_all_debug", not debug_enabled)
		_call_if_available(steering, "set_debug_draw_world_hitbox", draw_world_hitboxes)
		_call_if_available(steering, "set_debug_draw_fight_hitbox", draw_combat_hitboxes)
		_call_if_available(steering, "set_debug_draw_bottleneck_zones", draw_bottleneck_zones)
		_call_if_available(steering, "set_debug_disable_bottlenecks", disable_bottlenecks)
		_call_if_available(steering, "set_debug_show_agent_state_labels", show_agent_state_labels)

	var global_config: Node = get_node_or_null("GlobalConfigNative")
	if global_config:
		_call_if_available(global_config, "set_draw_flow_field", draw_flow_field)
		_call_if_available(global_config, "set_debug_show_plant_zones", show_plant_zones)

	var flow: Node = get_node_or_null("FlowFieldNative")
	if flow:
		_call_if_available(flow, "set_debug_draw", draw_flow_field)


func _call_if_available(target: Node, method_name: StringName, value: bool) -> void:
	if target.has_method(method_name):
		target.call(method_name, value)
