extends Resource
class_name MonsterData

## One entry in the "monster bible": a tunable definition for a spawnable monster
## type. Referenced by SpawnWave.monster_type (a StringName equal to `id`) and
## enumerated by MonsterCatalog, which builds every entry in code — unlike
## WeaponData, there are no monster .tres resources to edit. Tune stats in
## MonsterCatalog's focused factory methods.

## Stable catalog ID. Must match the StringName used in SpawnWave.monster_type and
## be unique across the catalog.
@export var id: StringName = &"basic"
@export var display_name: String = ""

@export_group("Sprite")
## Horizontal spritesheet frame count. Directional monster sheets use 4 frames:
## south / east / north / drowning.
## Legacy 4-frame monster sheets are still supported by character.gd.
@export var texture: Texture2D
@export var sprite_hframes: int = 4
## How character.gd should interpret sprite frames for this monster agent. This is
## explicit because clients, merchants, sheep, and player visuals use different
## sprite systems even when they share some frame counts.
@export var sprite_frame_layout: StringName = &"legacy_4_horizontal"
@export var sprite_scale: Vector2 = Vector2(0.75, 0.75)
## Local position of MonsterSprite2D relative to the agent origin. Tune this so the
## sprite's feet sit on the agent's ground point (larger sprites need a lower offset).
@export var sprite_offset: Vector2 = Vector2(0.0, -16.0)

@export_group("Traits")
## Small monsters can be grabbed and eaten whole by capture buildings (kraken).
## Large monsters are too heavy to be lifted.
@export var is_small: bool = true
## Whether deep water drowns this monster. When false the monster only slows down
## in water (via the shared terrain-speed multiplier) like the player, and never
## takes drowning damage. Large monsters are too big to drown.
@export var drownable: bool = true

@export_group("Stats")
@export_range(1, 100000, 1, "or_greater") var max_health: int = 100
## Movement speed as a fraction of the global agent speed. 1.0 = normal,
## 0.5 = twice as slow.
@export_range(0.05, 10.0, 0.01, "or_greater") var speed_scale: float = 1.0
## Resistance to neighbor crowd/separation push. 1.0 = normal,
## 2.0 = pushed half as much by neighbours (twice the inertia).
@export_range(0.05, 100.0, 0.01, "or_greater") var crowd_resist_scale: float = 1.0
## Discrete physical bump strength used only on direct contact. 0.0 disables
## contact pushing for this monster type.
@export_range(0.0, 1000.0, 1.0, "or_greater") var contact_push_power: float = 0.0
## Resistance against another agent's contact push. 2.0 receives half the contact
## pressure before normal smash resistance is applied.
@export_range(0.05, 100.0, 0.01, "or_greater") var contact_push_resist: float = 1.0
@export_range(0.0, 2.0, 0.01, "or_greater") var contact_push_cooldown: float = 0.2
## Fraction of contact impulse velocity removed per second. This applies only to
## direct agent contact and does not affect weapon or explosion knockback.
@export_range(0.0, 1.0, 0.001) var contact_push_friction_loss: float = 0.65
## Time autonomous steering yields after direct contact. This is intentionally
## independent from the interval before another contact impulse may be applied.
@export_range(0.0, 2.0, 0.01, "or_greater") var contact_control_suppression_seconds: float = 0.2
## Resistance to smash / knockback impulses. 1.0 = normal,
## 2.0 = receives half the knockback velocity (twice the inertia).
@export_range(0.05, 100.0, 0.01, "or_greater") var smash_resist_scale: float = 1.0
