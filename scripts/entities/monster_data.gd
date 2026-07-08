extends Resource
class_name MonsterData

## One entry in the "monster bible": a tunable definition for a spawnable monster
## type. Referenced by SpawnWave.monster_type (a StringName equal to `id`) and
## enumerated by MonsterCatalog. Mirrors the WeaponData/.tres pattern used for
## weapons — one .tres per monster under scripts/entities/monsters/.

## Stable catalog ID. Must match the StringName used in SpawnWave.monster_type and
## be unique across the catalog.
@export var id: StringName = &"basic"
@export var display_name: String = ""

@export_group("Sprite")
## Horizontal spritesheet, same 4-frame layout as monster.png
## (idle / eating / corpse / drowning). See character.gd MONSTER_FRAME_* consts.
@export var texture: Texture2D
@export var sprite_hframes: int = 4
@export var sprite_scale: Vector2 = Vector2(0.75, 0.75)
## Local position of MonsterSprite2D relative to the agent origin. Tune this so the
## sprite's feet sit on the agent's ground point (larger sprites need a lower offset).
@export var sprite_offset: Vector2 = Vector2(0.0, -16.0)

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
## Resistance to smash / knockback impulses. 1.0 = normal,
## 2.0 = receives half the knockback velocity (twice the inertia).
@export_range(0.05, 100.0, 0.01, "or_greater") var smash_resist_scale: float = 1.0
