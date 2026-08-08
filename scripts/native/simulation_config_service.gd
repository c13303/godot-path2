extends Node
class_name SimulationConfigService

## Project-owned runtime configuration. Values are applied explicitly to CPathLib
## instances; no process-wide native singleton is involved.

@export var flow_weight: float = 5.0
@export var center_pull: float = 5.0
@export var agent_max_speed: float = 150.0
@export var tile_size: float = 32.0
@export var agent_world_diameter_ratio: float = 0.9
@export var flow_field_wall_clearance: float = 0.5
@export var bottleneck_zone_radius_tiles: int = 2
@export var debug_show_zones: bool = true
@export var debug_nav_frame_lag_ms: float = 35.0
@export var debug_flowfield_rebuild_lag_ms: float = 35.0
@export var draw_flow_field: bool = false


func get_agent_max_speed() -> float:
	return agent_max_speed


func set_agent_max_speed(value: float) -> void:
	agent_max_speed = maxf(value, 0.0)


func get_agent_world_radius() -> float:
	return tile_size * agent_world_diameter_ratio * 0.5


func get_debug_show_zones() -> bool:
	return debug_show_zones


func get_debug_show_plant_zones() -> bool:
	return debug_show_zones


func set_debug_show_zones(value: bool) -> void:
	debug_show_zones = value


func set_debug_show_plant_zones(value: bool) -> void:
	debug_show_zones = value


func get_debug_nav_frame_lag_ms() -> float:
	return debug_nav_frame_lag_ms


func get_debug_plantff_frame_lag_ms() -> float:
	return debug_nav_frame_lag_ms


func set_debug_nav_frame_lag_ms(value: float) -> void:
	debug_nav_frame_lag_ms = maxf(value, 0.0)


func set_debug_plantff_frame_lag_ms(value: float) -> void:
	set_debug_nav_frame_lag_ms(value)


func get_debug_flowfield_rebuild_lag_ms() -> float:
	return debug_flowfield_rebuild_lag_ms


func get_debug_plantff_ff_lag_ms() -> float:
	return debug_flowfield_rebuild_lag_ms


func set_debug_flowfield_rebuild_lag_ms(value: float) -> void:
	debug_flowfield_rebuild_lag_ms = maxf(value, 0.0)


func set_debug_plantff_ff_lag_ms(value: float) -> void:
	set_debug_flowfield_rebuild_lag_ms(value)


func set_draw_flow_field(value: bool) -> void:
	draw_flow_field = value


func get_draw_flow_field() -> bool:
	return draw_flow_field

