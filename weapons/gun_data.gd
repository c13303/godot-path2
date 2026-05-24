extends Resource
class_name GunData

@export var id: String = ""

@export var fire_delay_ms: float = 50.0

@export var projectile_speed: float = 600.0
@export var projectile_lifetime: float = 0.6
@export var projectile_size: float = 16.0
@export var projectile_sprite: Texture2D

@export var aoe_radius: float = 18.0
@export var smash_force: float = 120.0
@export_range(0.0, 1.0, 0.01) var smash_friction_loss: float = 0.5
@export var smash_falloff: float = 1.0
@export var smash_detach_flow: bool = false
@export_range(0.0, 1.0, 0.01) var smash_control_suppression: float = 0.0
@export var smash_control_suppression_duration: float = 0.0

@export var pool_size: int = 128

@export_flags("Player", "MainChar", "Monster") var affected_smash_classes: int = 4
