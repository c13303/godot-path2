extends RefCounted
class_name MonsterCatalog

## Runtime-safe registry of spawnable monster definitions. The .tres resources are
## the authority for tunable stats; built-in construction is only a last-resort
## fallback if a resource cannot be loaded.

const BASIC_ID: StringName = &"basic"
const BIG_MONSTER_ID: StringName = &"bigmonster"
const BASIC_RESOURCE_PATH: String = "res://scripts/entities/monsters/basic.tres"
const BIG_MONSTER_RESOURCE_PATH: String = "res://scripts/entities/monsters/bigmonster.tres"
const BASIC_TEXTURE: Texture2D = preload("res://assets/sprites/legval/monster.png")
const BIG_MONSTER_TEXTURE: Texture2D = preload("res://assets/sprites/legval/bigmonster.png")


static func get_all() -> Array[MonsterData]:
	return [_monster_or_fallback(BASIC_RESOURCE_PATH, BASIC_ID), _monster_or_fallback(BIG_MONSTER_RESOURCE_PATH, BIG_MONSTER_ID)]


## Ordered list of catalog IDs, suitable for editor dropdowns and validation.
static func get_ids() -> Array[StringName]:
	return [BASIC_ID, BIG_MONSTER_ID]


static func get_monster(id: StringName) -> MonsterData:
	match id:
		BASIC_ID:
			return _monster_or_fallback(BASIC_RESOURCE_PATH, BASIC_ID)
		BIG_MONSTER_ID:
			return _monster_or_fallback(BIG_MONSTER_RESOURCE_PATH, BIG_MONSTER_ID)
		_:
			return null


static func has_monster(id: StringName) -> bool:
	return id == BASIC_ID or id == BIG_MONSTER_ID


static func _monster_or_fallback(resource_path: String, id: StringName) -> MonsterData:
	var resource: MonsterData = load(resource_path) as MonsterData
	if resource != null:
		return resource
	match id:
		BASIC_ID:
			return _make_basic()
		BIG_MONSTER_ID:
			return _make_bigmonster()
		_:
			return null


static func _make_basic() -> MonsterData:
	var data: MonsterData = MonsterData.new()
	data.id = BASIC_ID
	data.display_name = "Monster"
	data.texture = BASIC_TEXTURE
	data.sprite_hframes = 4
	data.sprite_scale = Vector2(0.75, 0.75)
	data.sprite_offset = Vector2(0.0, -16.0)
	data.max_health = 100
	data.speed_scale = 1.0
	data.crowd_push_scale = 1.5
	data.crowd_resist_scale = 2.0
	data.smash_resist_scale = 1.0
	return data


static func _make_bigmonster() -> MonsterData:
	var data: MonsterData = MonsterData.new()
	data.id = BIG_MONSTER_ID
	data.display_name = "Big Monster"
	data.texture = BIG_MONSTER_TEXTURE
	data.sprite_hframes = 4
	data.sprite_scale = Vector2(0.75, 0.75)
	data.sprite_offset = Vector2(0.0, -28.0)
	data.max_health = 300
	data.speed_scale = 0.5
	data.crowd_push_scale = 6.0
	data.crowd_resist_scale = 75.0
	data.smash_resist_scale = 3.0
	return data
