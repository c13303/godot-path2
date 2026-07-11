extends Resource
class_name TurretData

@export var id: String = ""

@export_group("Shooting")
@export_range(0.001, 60.0, 0.001, "or_greater") var shoot_frequency: float = 3.0
@export_range(0.0, 60.0, 0.001, "or_greater") var shoot_duration: float = 0.2
@export var weapon: Resource
@export_range(0.0, 10000.0, 1.0, "or_greater") var shooting_range: float = 200.0
@export var directional: bool = false
@export var straight_line_detection: bool = false
@export_range(0.0, 60.0, 0.001, "or_greater") var shot_release_delay: float = 0.0
@export_range(0.0, 60.0, 0.001, "or_greater") var shot_cycle_duration: float = 0.0

@export_group("Building")
@export var build_in_range: bool = false
@export_range(0.0, 10000.0, 1.0, "or_greater") var build_range: float = 200.0
@export var eatable_by_monsters: bool = false
