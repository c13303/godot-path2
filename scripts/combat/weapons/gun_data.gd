extends Resource
class_name GunData

@export var id: String = ""

@export var fire_delay_ms: float = 50.0

@export var projectile_speed: float = 600.0
@export var projectile_lifetime: float = 0.6
@export var projectile_size: float = 16.0
@export var projectile_sprite: Texture2D

# Spawn the projectile this many pixels from the origin along the aim direction
# (0 = spawn exactly at origin).
@export var throw_offset: float = 0.0

# --- Visual altitude / shadow (visual-only; does NOT affect collision or simulation) ---
# The native projectile position is the GROUND position (single source of truth).
# The sprite is drawn lifted by `projectile_altitude_px` along -Y, but z-ordering
# and the shadow always use the ground position.
@export_group("Projectile Visual")
@export var projectile_altitude_px: float = 10.0
@export var projectile_shadow_enabled: bool = true
@export var projectile_shadow_color: Color = Color(0.0, 0.0, 0.0, 0.3)
@export var projectile_shadow_size: Vector2 = Vector2(8.0, 3.0)
@export var projectile_shadow_offset: Vector2 = Vector2.ZERO
# Optional: if set, the shadow is drawn using this texture instead of a procedural oval.
@export var projectile_shadow_texture: Texture2D

@export var aoe_radius: float = 18.0
@export var smash_force: float = 120.0
@export_range(0.0, 1.0, 0.01) var smash_friction_loss: float = 0.5
@export var smash_falloff: float = 1.0
@export var smash_detach_flow: bool = false
@export_range(0.0, 1.0, 0.01) var smash_control_suppression: float = 0.0
@export var smash_control_suppression_duration: float = 0.0

# Projectiles are stopped by walls (collision uses the ground position only;
# visual altitude is never physical).
@export var stopped_by_walls: bool = true

# End-of-life AoE: a smash applied when the projectile despawns *without* hitting
# an agent — i.e. on wall impact or lifetime expiry. A direct agent hit still
# uses the smash_* params above. Leave disabled for a silent fizzle.
@export_group("End-of-life AoE")
@export var end_of_life_aoe_enabled: bool = false
@export var end_aoe_radius: float = 18.0
@export var end_aoe_force: float = 120.0
@export_range(0.0, 1.0, 0.01) var end_aoe_friction_loss: float = 0.5
@export var end_aoe_falloff: float = 1.0
@export var end_aoe_detach_flow: bool = false
@export_range(0.0, 1.0, 0.01) var end_aoe_control_suppression: float = 0.0
@export var end_aoe_control_suppression_duration: float = 0.0

# --- Impact AoE visual (rendered by the same WeaponAOEDrawer as melee weapons) ---
# Shown wherever a projectile AoE actually fires: wall hit, lifetime expiry, or a
# direct agent hit. The ring radius matches the simulated AoE radius; the display
# duration just keeps the instantaneous impulse on screen long enough to read.
@export_group("Impact AoE Visual")
@export var impact_visual_enabled: bool = true
@export var impact_display_duration: float = 0.18
@export var impact_fill_color: Color = Color(0.3, 0.6, 1.0, 0.22)
@export var impact_stroke_color: Color = Color(0.5, 0.8, 1.0, 0.9)
@export var impact_stroke_width: float = 2.0
# Extra fine-tune on top of the automatic altitude lift (negative Y = up). Leave
# at zero unless the sprite art isn't centered on its ground point.
@export var impact_visual_offset: Vector2 = Vector2.ZERO

@export var pool_size: int = 128

@export_flags("Player", "MainChar", "Monster") var affected_smash_classes: int = 4
