extends RefCounted
class_name MonsterCatalog

## Central registry of spawnable monster definitions (the "monster bible"). Mirrors
## the weapon .tres pattern: each monster is a MonsterData resource under
## scripts/entities/monsters/. Both the runtime (building_manager) and the spawn
## playlist editor enumerate types from here, so adding a monster is a one-line
## change plus a new .tres.
const _MONSTERS: Array[MonsterData] = [
	preload("res://scripts/entities/monsters/basic.tres"),
	preload("res://scripts/entities/monsters/bigmonster.tres"),
]


static func get_all() -> Array[MonsterData]:
	return _MONSTERS


## Ordered list of catalog IDs, suitable for editor dropdowns and validation.
static func get_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for monster: MonsterData in _MONSTERS:
		if monster != null and monster.id != &"":
			ids.append(monster.id)
	return ids


static func get_monster(id: StringName) -> MonsterData:
	for monster: MonsterData in _MONSTERS:
		if monster != null and monster.id == id:
			return monster
	return null


static func has_monster(id: StringName) -> bool:
	return get_monster(id) != null
