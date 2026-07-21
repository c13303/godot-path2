extends RefCounted
class_name MonsterCatalog

## Runtime-safe registry of spawnable monster definitions, and the single authority
## for monster stats: every entry is built in code below.
##
## Do not move these definitions back into .tres resources. The exported console
## build loads them as plain Resource objects when their script attachment is
## unavailable, so the exported fields cannot be read back there.

const BASIC_ID: StringName = &"basic"
const GREEN_MONSTER_ID: StringName = &"greenmonster"
const BIG_MONSTER_ID: StringName = &"bigmonster"
const FRAME_LAYOUT_DIRECTIONAL_4_HORIZONTAL: StringName = &"directional_4_horizontal"
const BASIC_TEXTURE: Texture2D = preload("res://assets/sprites/legval/monster.png")
const GREEN_MONSTER_TEXTURE: Texture2D = preload("res://assets/sprites/legval/speedmonster.png")
const BIG_MONSTER_TEXTURE: Texture2D = preload("res://assets/sprites/legval/bigmonster.png")
const BASIC_MAX_HEALTH: int = 500
const GREEN_MONSTER_HEALTH_SCALE: float = 0.5
const GREEN_MONSTER_SPEED_SCALE: float = 1.5
const BIG_MONSTER_SPRITE_SCALE: Vector2 = Vector2(0.75, 0.75)
const BIG_MONSTER_SPRITE_OFFSET: Vector2 = Vector2(0.0, -48.0)
const SMALL_CONTACT_PUSH_RESIST: float = 2.0
const SMALL_CONTACT_PUSH_COOLDOWN: float = 0.2
const SMALL_CONTACT_PUSH_FRICTION_LOSS: float = 0.995
const SMALL_CONTACT_CONTROL_SUPPRESSION_SECONDS: float = 0.1
const MONSTER_ID_ORDER: Array[StringName] = [BASIC_ID, GREEN_MONSTER_ID, BIG_MONSTER_ID]


static func get_all() -> Array[MonsterData]:
	var monsters: Array[MonsterData] = []
	for monster_id: StringName in MONSTER_ID_ORDER:
		var data: MonsterData = get_monster(monster_id)
		if data != null:
			monsters.append(data)
	return monsters


## Ordered list of catalog IDs, suitable for editor dropdowns and validation.
static func get_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for monster_id: StringName in MONSTER_ID_ORDER:
		ids.append(monster_id)
	return ids


static func get_monster(id: StringName) -> MonsterData:
	match id:
		BASIC_ID:
			return _make_basic()
		GREEN_MONSTER_ID:
			return _make_greenmonster()
		BIG_MONSTER_ID:
			return _make_bigmonster()
		_:
			return null


static func has_monster(id: StringName) -> bool:
	return MONSTER_ID_ORDER.has(id)


static func _make_basic() -> MonsterData:
	return _make_ordinary_monster(BASIC_ID, "Monster", BASIC_TEXTURE)


static func _make_greenmonster() -> MonsterData:
	var data: MonsterData = _make_ordinary_monster(
		GREEN_MONSTER_ID,
		"Greenmonster",
		GREEN_MONSTER_TEXTURE
	)
	data.max_health = int(float(BASIC_MAX_HEALTH) * GREEN_MONSTER_HEALTH_SCALE)
	data.speed_scale = GREEN_MONSTER_SPEED_SCALE
	return data


static func _make_ordinary_monster(id: StringName, display_name: String, texture: Texture2D) -> MonsterData:
	var data: MonsterData = MonsterData.new()
	data.id = id
	data.display_name = display_name
	data.is_small = true
	data.texture = texture
	data.sprite_hframes = 4
	data.sprite_frame_layout = FRAME_LAYOUT_DIRECTIONAL_4_HORIZONTAL
	data.sprite_scale = Vector2(0.75, 0.75)
	data.sprite_offset = Vector2(0.0, -16.0)
	data.max_health = BASIC_MAX_HEALTH
	data.speed_scale = 1.0
	data.crowd_resist_scale = 1.0
	data.contact_push_power = 0.0
	data.contact_push_resist = SMALL_CONTACT_PUSH_RESIST
	data.contact_push_cooldown = SMALL_CONTACT_PUSH_COOLDOWN
	data.contact_push_friction_loss = SMALL_CONTACT_PUSH_FRICTION_LOSS
	data.contact_control_suppression_seconds = SMALL_CONTACT_CONTROL_SUPPRESSION_SECONDS
	data.smash_resist_scale = 1.0
	return data


static func _make_bigmonster() -> MonsterData:
	var data: MonsterData = MonsterData.new()
	data.id = BIG_MONSTER_ID
	data.display_name = "Big Monster"
	data.is_small = false
	data.drownable = false
	data.texture = BIG_MONSTER_TEXTURE
	data.sprite_hframes = 4
	data.sprite_frame_layout = FRAME_LAYOUT_DIRECTIONAL_4_HORIZONTAL
	data.sprite_scale = BIG_MONSTER_SPRITE_SCALE
	data.sprite_offset = BIG_MONSTER_SPRITE_OFFSET
	data.max_health = 2000
	data.speed_scale = 1.0
	data.crowd_resist_scale = 2.0
	data.contact_push_power = 520.0
	data.contact_push_resist = 8.0
	data.contact_push_cooldown = 0.2
	data.smash_resist_scale = 2.0
	return data
