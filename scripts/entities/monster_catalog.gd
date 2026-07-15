extends RefCounted
class_name MonsterCatalog

## Runtime-safe registry of spawnable monster definitions. The exported console
## build can load .tres monster resources as plain Resource objects when their
## script attachment is unavailable, so the current built-in entries are created
## directly here instead of reading exported fields from those resources.

const BASIC_ID: StringName = &"basic"
const BIG_MONSTER_ID: StringName = &"bigmonster"
const FRAME_LAYOUT_DIRECTIONAL_4_HORIZONTAL: StringName = &"directional_4_horizontal"
const BASIC_TEXTURE: Texture2D = preload("res://assets/sprites/legval/monster.png")
const BIG_MONSTER_TEXTURE: Texture2D = preload("res://assets/sprites/legval/bigmonster.png")
const BIG_MONSTER_SPRITE_SCALE: Vector2 = Vector2(0.75, 0.75)
const BIG_MONSTER_SPRITE_OFFSET: Vector2 = Vector2(0.0, -48.0)


static func get_all() -> Array[MonsterData]:
	return [_make_basic(), _make_bigmonster()]


## Ordered list of catalog IDs, suitable for editor dropdowns and validation.
static func get_ids() -> Array[StringName]:
	return [BASIC_ID, BIG_MONSTER_ID]


static func get_monster(id: StringName) -> MonsterData:
	match id:
		BASIC_ID:
			return _make_basic()
		BIG_MONSTER_ID:
			return _make_bigmonster()
		_:
			return null


static func has_monster(id: StringName) -> bool:
	return id == BASIC_ID or id == BIG_MONSTER_ID


static func _make_basic() -> MonsterData:
	var data: MonsterData = MonsterData.new()
	data.id = BASIC_ID
	data.display_name = "Monster"
	data.is_small = true
	data.texture = BASIC_TEXTURE
	data.sprite_hframes = 4
	data.sprite_frame_layout = FRAME_LAYOUT_DIRECTIONAL_4_HORIZONTAL
	data.sprite_scale = Vector2(0.75, 0.75)
	data.sprite_offset = Vector2(0.0, -16.0)
	data.max_health = 100
	data.speed_scale = 1.0
	data.crowd_resist_scale = 1.0
	data.contact_push_power = 0.0
	data.contact_push_resist = 1.0
	data.contact_push_cooldown = 0.2
	data.smash_resist_scale = 1.0
	return data


static func _make_bigmonster() -> MonsterData:
	var data: MonsterData = MonsterData.new()
	data.id = BIG_MONSTER_ID
	data.display_name = "Big Monster"
	data.is_small = false
	data.texture = BIG_MONSTER_TEXTURE
	data.sprite_hframes = 4
	data.sprite_frame_layout = FRAME_LAYOUT_DIRECTIONAL_4_HORIZONTAL
	data.sprite_scale = BIG_MONSTER_SPRITE_SCALE
	data.sprite_offset = BIG_MONSTER_SPRITE_OFFSET
	data.max_health = 200
	data.speed_scale = 0.5
	data.crowd_resist_scale = 2.0
	data.contact_push_power = 520.0
	data.contact_push_resist = 8.0
	data.contact_push_cooldown = 0.2
	data.smash_resist_scale = 2.0
	return data
