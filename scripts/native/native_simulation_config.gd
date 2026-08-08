extends Resource
class_name NativeSimulationConfig

## Project-owned defaults formerly stored in a process-wide native singleton.
## Values are copied explicitly into each CPathLib world or agent at creation.

@export_group("Navigation")
@export_range(1.0, 256.0, 1.0) var tile_size: float = 32.0
@export_range(0.0, 10.0, 0.05) var flow_wall_clearance_weight: float = 0.5
@export_range(0, 2, 1) var bottleneck_zone_radius_tiles: int = 2
@export_range(0.0, 10.0, 0.05) var bottleneck_reservation_seconds: float = 1.0

@export_group("Agent Profile")
@export_range(0.0, 1000.0, 1.0) var agent_maximum_speed: float = 150.0
@export_range(0.0, 5000.0, 1.0) var agent_acceleration: float = 900.0
@export_range(0.0, 5000.0, 1.0) var agent_deceleration: float = 1200.0
@export_range(0.0, 2.0, 0.01) var agent_diameter_tile_ratio: float = 0.9
@export_range(0.0, 256.0, 1.0) var separation_radius: float = 32.0
@export_range(0.0, 1000.0, 1.0) var separation_weight: float = 600.0
@export_range(0.0, 256.0, 1.0) var arrival_radius: float = 16.0

@export_group("Interactions")
@export var contact_push_enabled: bool = true
@export var right_of_way_enabled: bool = true
@export_range(0.0, 2000.0, 1.0) var right_of_way_push_speed: float = 216.0
@export_range(0.0, 5.0, 0.01) var right_of_way_cooldown: float = 0.18
@export_range(0.0, 5.0, 0.01) var right_of_way_control_suppression: float = 0.18
@export_range(0.0, 5000.0, 1.0) var static_obstacle_repulsion_strength: float = 400.0
@export_range(0.0, 256.0, 1.0) var static_obstacle_query_padding: float = 32.0

@export_group("Gameplay Forces")
@export_range(0.0, 5000.0, 1.0) var impulse_speed_cap: float = 500.0
@export_range(0.0, 1.0, 0.01) var impulse_decay: float = 0.91
@export_range(0.0, 20.0, 0.1) var impulse_feedback_duration: float = 8.0
@export_range(0.0, 10.0, 0.05) var radial_falloff_exponent: float = 0.1

@export_group("Diagnostics")
@export var draw_flow_field: bool = false
@export var show_navigation_zones: bool = true
@export_range(0.0, 1000.0, 1.0) var navigation_frame_warning_ms: float = 35.0
@export_range(0.0, 1000.0, 1.0) var flow_build_warning_ms: float = 35.0


func agent_radius() -> float:
	return tile_size * agent_diameter_tile_ratio * 0.5


func default_agent_profile() -> Dictionary:
	return {
		"radius": agent_radius(),
		"maximum_speed": agent_maximum_speed,
		"acceleration": agent_acceleration,
		"deceleration": agent_deceleration,
		"separation_radius": separation_radius,
		"separation_weight": separation_weight,
		"arrival_radius": arrival_radius,
	}


func apply_to_navigation(navigation_world: Node) -> bool:
	if navigation_world == null or not navigation_world.has_method(&"configure_flow"):
		return false
	navigation_world.call(
		&"configure_flow", flow_wall_clearance_weight, true,
		bottleneck_zone_radius_tiles
	)
	return true


func apply_to_crowd(crowd_world: Node) -> bool:
	if crowd_world == null or not crowd_world.has_method(&"configure_default_profile"):
		return false
	crowd_world.call(
		&"configure_default_profile", agent_radius(), agent_maximum_speed,
		agent_acceleration, agent_deceleration, separation_radius,
		separation_weight, arrival_radius, 0, -1
	)
	crowd_world.call(
		&"configure_static_obstacle_avoidance",
		static_obstacle_repulsion_strength, static_obstacle_query_padding
	)
	crowd_world.call(
		&"configure_agent_interactions", contact_push_enabled,
		right_of_way_enabled, right_of_way_push_speed,
		right_of_way_cooldown, right_of_way_control_suppression
	)
	return true
