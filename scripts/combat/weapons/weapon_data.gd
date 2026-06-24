extends Resource
class_name WeaponData

@export var id: String = ""

# Spawn the AoE this many pixels from the origin along the aim direction
# (0 = spawn exactly at origin).
@export var throw_offset: float = 0.0

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

@export_group("Continuous Use")
@export var continuous: bool = false
# Rotation response time in seconds for the collision cone. Zero follows the
# aim immediately.
@export_range(0.0, 2.0, 0.001, "or_greater") var aim_inertia: float = 0.0
@export var damage_frequency: float = 0.0
@export var repulse_frequency: float = 0.0
@export var reserve_id: StringName = &""
@export var reserve_cost: int = 0
@export var reserve_cost_interval: float = 0.0
@export var waters_reactive_plants: bool = false
@export var continuous_sound: StringName = &""

# --- AoE visual appearance (per-weapon; rendered by WeaponAOEDrawer) ---
# The FightSystem.visualize_AOE_weapons flag is the global on/off; aoe_visual_enabled
# lets an individual weapon opt out without disabling the rest.
@export_group("AoE Visual")
@export var aoe_visual_enabled: bool = true
@export var aoe_fill_color: Color = Color(1.0, 0.0, 0.0, 0.18)
@export var aoe_stroke_color: Color = Color(1.0, 0.0, 0.0, 0.85)
@export var aoe_stroke_width: float = 2.0
