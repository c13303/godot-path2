extends Resource
class_name TurretData

enum Behavior {
	WEAPON,
	WIND,
}

@export var id: String = ""
@export var behavior: Behavior = Behavior.WEAPON

@export_group("Shooting")
@export_range(0.001, 60.0, 0.001, "or_greater") var shoot_frequency: float = 3.0
@export_range(0.0, 60.0, 0.001, "or_greater") var shoot_duration: float = 0.2
@export var weapon: Resource
@export_range(0.0, 10000.0, 1.0, "or_greater") var shooting_range: float = 200.0
@export var directional: bool = false
@export var straight_line_detection: bool = false
@export_range(0.0, 60.0, 0.001, "or_greater") var shot_release_delay: float = 0.0
@export_range(0.0, 60.0, 0.001, "or_greater") var shot_cycle_duration: float = 0.0

@export_group("Wind")
@export_range(0.0, 360.0, 0.1) var activation_angle_degrees: float = 360.0
@export_range(0.0, 60.0, 0.001, "or_greater") var wind_active_duration: float = 1.0
@export_range(0.0, 60.0, 0.001, "or_greater") var wind_cooldown_duration: float = 3.0
@export_range(0.0, 10000.0, 1.0, "or_greater") var wind_force: float = 220.0
@export_range(0.0, 1.0, 0.01) var wind_friction_loss: float = 0.9
@export_range(0.01, 60.0, 0.001, "or_greater") var wind_repulse_frequency: float = 0.5
@export_range(0.01, 60.0, 0.001, "or_greater") var wind_query_interval: float = 0.1

@export_group("Building")
@export var build_in_range: bool = false
@export_range(0.0, 10000.0, 1.0, "or_greater") var build_range: float = 200.0
@export var eatable_by_monsters: bool = false
