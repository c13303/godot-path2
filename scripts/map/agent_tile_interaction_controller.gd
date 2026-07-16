extends RefCounted
class_name AgentTileInteractionController

# Owns agent/placeable contact rules and repeated stomp damage. AgentCellTracker owns
# authoritative cell transitions; this controller owns what an eligible occupying
# agent does to a stompable target in that cell.

const CATEGORY_MONSTERS: StringName = &"monsters"
# Behaviour flag stamped on the agent by its definition (see AgentDefinitionService): people and
# monsters that crush placeables by walking over them. Reading this per-agent flag — rather than
# matching a hardcoded list of role categories — lets a future villager inherit the shared
# person-crush behaviour purely from its definition. Monsters crush via CATEGORY_MONSTERS.
const CRUSHES_PLACEABLES_META: StringName = &"crushes_placeables"
const KEY_PEOPLE_CRUSH_PLANTS: String = "tutorial.people_crush_plants"

const RECHECK_CELL_ENTERED: int = 1
const RECHECK_WORLD_CHANGED: int = 2
const RECHECK_STATE_CHANGED: int = 4

const STOMP_DAMAGE_INTERVAL_SECONDS: float = 1.0
const NORMAL_STOMP_DAMAGE: int = 20
const BIG_MONSTER_STOMP_DAMAGE: int = 40

var _manager: BuildingManager = null

# agent instance id -> contact record:
# { "agent_ref": WeakRef, "category": StringName, "cell": Vector2i,
#   "target_key": String, "layer_name": StringName, "item_id": String,
#   "elapsed": float }
var _active_contacts: Dictionary = {}

var _debug_stomp: int = 0


func setup(manager: BuildingManager) -> void:
	_manager = manager


func evaluate(agent: Node2D, category: StringName, cell: Vector2i, reasons: int) -> void:
	if _manager == null or agent == null or not is_instance_valid(agent):
		return
	var agent_id: int = agent.get_instance_id()
	if not _agent_can_stomp(agent, category):
		clear_agent_contact(agent_id)
		refresh_contact_dance(agent, category)
		return
	var target: Dictionary = _resolve_stompable_target(cell)
	if target.is_empty():
		clear_agent_contact(agent_id)
		refresh_contact_dance(agent, category)
		return
	var existing: Dictionary = _active_contacts.get(agent_id, {}) as Dictionary
	var is_same_contact: bool = _contact_matches(existing, target, cell)
	if is_same_contact:
		var updated: Dictionary = _record_for(agent, category, cell, target, float(existing.get("elapsed", 0.0)))
		if bool(existing.get("skip_first_process", false)):
			updated["skip_first_process"] = true
		_active_contacts[agent_id] = updated
		refresh_contact_dance(agent, category)
		return
	var should_start_fresh: bool = (reasons & RECHECK_CELL_ENTERED) != 0 or (reasons & RECHECK_WORLD_CHANGED) != 0
	if not should_start_fresh:
		clear_agent_contact(agent_id)
		refresh_contact_dance(agent, category)
		return
	clear_agent_contact(agent_id)
	_start_contact(agent, category, cell, target)
	refresh_contact_dance(agent, category)


func process_active_contacts(delta: float) -> void:
	if _active_contacts.is_empty():
		return
	var interval: float = maxf(0.001, STOMP_DAMAGE_INTERVAL_SECONDS)
	var dead_ids: Array[int] = []
	for raw_id: Variant in _active_contacts.keys():
		var agent_id: int = int(raw_id)
		var record: Dictionary = _active_contacts[agent_id] as Dictionary
		if not _contact_is_valid(agent_id, record):
			dead_ids.append(agent_id)
			continue
		if bool(record.get("skip_first_process", false)):
			record["skip_first_process"] = false
			_active_contacts[agent_id] = record
			continue
		var elapsed: float = float(record.get("elapsed", 0.0)) + maxf(0.0, delta)
		while elapsed >= interval:
			elapsed -= interval
			if not _apply_stomp_damage(record):
				dead_ids.append(agent_id)
				break
			if not _contact_is_valid(agent_id, record):
				dead_ids.append(agent_id)
				break
		if not dead_ids.has(agent_id) and _active_contacts.has(agent_id):
			record["elapsed"] = elapsed
			_active_contacts[agent_id] = record
	for agent_id: int in dead_ids:
		clear_agent_contact(agent_id)


func clear_agent_contact(agent_id: int) -> void:
	_active_contacts.erase(agent_id)


func clear() -> void:
	_active_contacts.clear()


func refresh_contact_dance(agent: Node2D, category: StringName) -> void:
	if _manager == null or agent == null or not is_instance_valid(agent):
		return
	if _manager.has_method("request_agent_plant_contact_dance"):
		_manager.call("request_agent_plant_contact_dance", agent, category)


func reset_debug_counters() -> void:
	_debug_stomp = 0


func debug_stats() -> Dictionary:
	return {
		"stomp": _debug_stomp,
		"active_stomp_contacts": _active_contacts.size(),
	}


func _start_contact(agent: Node2D, category: StringName, cell: Vector2i, target: Dictionary) -> void:
	var record: Dictionary = _record_for(agent, category, cell, target, 0.0)
	if _apply_stomp_damage(record):
		record["skip_first_process"] = true
		_active_contacts[agent.get_instance_id()] = record


func _record_for(agent: Node2D, category: StringName, cell: Vector2i, target: Dictionary, elapsed: float) -> Dictionary:
	return {
		"agent_ref": weakref(agent),
		"category": category,
		"cell": cell,
		"target_key": str(target.get("target_key", "")),
		"layer_name": StringName(target.get("layer_name", &"")),
		"item_id": str(target.get("item_id", "")),
		"elapsed": elapsed,
	}


func _apply_stomp_damage(record: Dictionary) -> bool:
	var cell: Vector2i = record.get("cell", Vector2i.ZERO) as Vector2i
	var layer_name: StringName = StringName(record.get("layer_name", &""))
	var item_id: String = str(record.get("item_id", ""))
	if not _target_still_matches(record):
		return false
	var category: StringName = StringName(record.get("category", &""))
	var damage: int = _stomp_damage_for(record.get("agent_ref", null) as WeakRef, category)
	if damage <= 0:
		return false
	var destroyed: bool = _manager.damage_player_placeable_at(cell, String(layer_name), item_id, damage)
	_debug_stomp += 1
	# "People crush plants" alert: only non-monster crushers (people) reach here as non-monsters,
	# so gating on "not a monster" reproduces the old clients/merchants/builders trigger set.
	if category != CATEGORY_MONSTERS:
		_manager.show_tutorial_alert_once(KEY_PEOPLE_CRUSH_PLANTS)
	return not destroyed


func _contact_is_valid(agent_id: int, record: Dictionary) -> bool:
	var agent_ref: WeakRef = record.get("agent_ref", null) as WeakRef
	if agent_ref == null:
		return false
	var agent: Node2D = agent_ref.get_ref() as Node2D
	if agent == null or not is_instance_valid(agent) or agent.is_queued_for_deletion():
		return false
	if agent.get_instance_id() != agent_id:
		return false
	var category: StringName = StringName(record.get("category", &""))
	if not _agent_can_stomp(agent, category):
		return false
	var cell: Vector2i = record.get("cell", Vector2i.ZERO) as Vector2i
	if _manager.floorz == null:
		return false
	var current_cell: Vector2i = _manager.floorz.local_to_map(_manager.floorz.to_local(agent.global_position))
	if current_cell != cell:
		return false
	return _target_still_matches(record)


func _target_still_matches(record: Dictionary) -> bool:
	var target_key: String = str(record.get("target_key", ""))
	var durability: PlayerPlaceableDurabilityService = _manager.get_player_placeable_durability_service()
	if durability == null or target_key == "" or not durability.is_target_valid(target_key):
		return false
	var target: Dictionary = _resolve_stompable_target(record.get("cell", Vector2i.ZERO) as Vector2i)
	if target.is_empty():
		return false
	return _contact_matches(record, target, record.get("cell", Vector2i.ZERO) as Vector2i)


func _contact_matches(record: Dictionary, target: Dictionary, cell: Vector2i) -> bool:
	if record.is_empty():
		return false
	return record.get("cell", Vector2i.ZERO) == cell \
		and str(record.get("target_key", "")) == str(target.get("target_key", "")) \
		and StringName(record.get("layer_name", &"")) == StringName(target.get("layer_name", &"")) \
		and str(record.get("item_id", "")) == str(target.get("item_id", ""))


func _resolve_stompable_target(cell: Vector2i) -> Dictionary:
	var plant_target: Dictionary = _resolve_plant_target(cell)
	if not plant_target.is_empty():
		return plant_target
	return _resolve_building_target(cell)


func _resolve_plant_target(cell: Vector2i) -> Dictionary:
	var plant_manager: Node = _manager.get_plant_manager()
	if plant_manager == null or not plant_manager.has_method("has_plant"):
		return {}
	if not bool(plant_manager.call("has_plant", cell)):
		return {}
	var item_id: String = ""
	if plant_manager.has_method("get_plant_item_id"):
		item_id = str(plant_manager.call("get_plant_item_id", cell))
	if item_id == "" or not ItemCatalog.is_stompable(item_id):
		return {}
	return _target_from_durability(cell, &"plantz", item_id)


func _resolve_building_target(cell: Vector2i) -> Dictionary:
	var building_objects: BuildingObjectManager = _manager.get_building_object_manager()
	if building_objects == null:
		return {}
	var placeable: Dictionary = building_objects.get_placeable_instance(cell)
	if placeable.is_empty():
		return {}
	var item_id: String = str(placeable.get("item_id", ""))
	if not ItemCatalog.is_stompable(item_id):
		return {}
	var item_def: Dictionary = ItemCatalog.get_item_def(item_id)
	var layer_name: StringName = StringName(placeable.get("target_layer", item_def.get("target_layer", "")))
	if layer_name == &"buildings":
		layer_name = &"traversable_buildings"
	return _target_from_durability(cell, layer_name, item_id)


func _target_from_durability(cell: Vector2i, layer_name: StringName, item_id: String) -> Dictionary:
	var durability: PlayerPlaceableDurabilityService = _manager.get_player_placeable_durability_service()
	if durability == null:
		return {}
	var key: String = "%s:%d,%d" % [String(layer_name), cell.x, cell.y]
	var record: Dictionary = durability.target_record(key)
	if record.is_empty() and ItemCatalog.is_destructible_placeable(item_id):
		_manager.register_player_placeable(cell, item_id, String(layer_name))
		record = durability.target_record(key)
	if record.is_empty() or not durability.is_target_valid(key):
		return {}
	if str(record.get("item_id", "")) != item_id:
		return {}
	return {
		"target_key": key,
		"cell": cell,
		"layer_name": layer_name,
		"item_id": item_id,
	}


## An agent crushes placeables if it is a monster (via its category) or its definition flagged it
## as a person-type crusher. Behaviour-oriented: unrelated to house residency, includes clients.
func _agent_can_stomp(agent: Node2D, category: StringName) -> bool:
	return category == CATEGORY_MONSTERS or _agent_crushes_placeables(agent)


func _agent_crushes_placeables(agent: Node2D) -> bool:
	return agent != null and is_instance_valid(agent) \
		and agent.has_meta(CRUSHES_PLACEABLES_META) and bool(agent.get_meta(CRUSHES_PLACEABLES_META))


func _stomp_damage_for(agent_ref: WeakRef, category: StringName) -> int:
	# Only agents that already passed a crush gate reach here, so a non-monster is a person and
	# deals normal damage; big monsters hit harder.
	if category != CATEGORY_MONSTERS:
		return NORMAL_STOMP_DAMAGE
	var agent: Node = agent_ref.get_ref() as Node if agent_ref != null else null
	if agent != null and is_instance_valid(agent) and agent.has_meta("monster_type"):
		var monster_type: StringName = StringName(str(agent.get_meta("monster_type")))
		if monster_type == MonsterCatalog.BIG_MONSTER_ID:
			return BIG_MONSTER_STOMP_DAMAGE
	return NORMAL_STOMP_DAMAGE
