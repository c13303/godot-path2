extends Resource
class_name WeaponData

@export var id: String = ""
@export var directional_area_angle: float = 360.0
@export var radius: float = 0.0
@export var aoe_duration: float = 0.0
@export var smash_force: float = 0.0
@export_range(0.0, 1.0, 0.01) var control_suppression: float = 1.0
@export var control_suppression_duration: float = 0.0
@export var damage: int = 1
@export_range(0.0, 1.0, 0.01) var friction: float = 0.91
@export var falloff: float = 0.0
@export var radial: bool = false
@export var detach_flow: bool = false
@export_flags("Player", "MainChar", "Monster") var affected_smash_classes: int = 4
