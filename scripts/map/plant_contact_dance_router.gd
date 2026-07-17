extends RefCounted
class_name PlantContactDanceRouter

# Owns visual plant/building contact lifecycle. AgentCellTracker supplies the already
# computed cell; this router never reads an agent transform or performs map conversion.

const CONTACT_DANCE_DURATION: float = 0.16
const CATEGORY_CLIENTS: StringName = &"clients"
const CATEGORY_MERCHANTS: StringName = &"merchants"
const CATEGORY_TURRET: String = "turret"
const CONTACT_BEHAVIOR_VISUAL_ONLY: StringName = &"contact_visual_only"

var _manager: BuildingManager = null
# agent instance id -> contact record.
var _contacts_by_agent: Dictionary = {}
# target key -> number of occupying eligible agents.
var _occupant_counts: Dictionary = {}
var _evaluation_count: int = 0


func setup(manager: BuildingManager) -> void:
	_manager = manager


func update_agent_contact(agent: Node2D, category: StringName, cell: Vector2i) -> void:
	if _manager == null or agent == null or not is_instance_valid(agent):
		return
	_evaluation_count += 1
	var agent_id: int = agent.get_instance_id()
	var next_contact: Dictionary = _resolve_contact(agent, category, cell)
	var previous: Dictionary = _contacts_by_agent.get(agent_id, {}) as Dictionary
	if _same_contact(previous, next_contact):
		return
	_remove_agent_contact(agent_id)
	if next_contact.is_empty():
		return
	_contacts_by_agent[agent_id] = next_contact
	var key: String = str(next_contact.get("key", ""))
	var count: int = int(_occupant_counts.get(key, 0)) + 1
	_occupant_counts[key] = count
	if count == 1:
		_publish_contact(next_contact, true)


func clear_agent_contact(agent_id: int) -> void:
	_remove_agent_contact(agent_id)


func clear() -> void:
	var active_contacts: Array = _contacts_by_agent.values()
	_contacts_by_agent.clear()
	_occupant_counts.clear()
	var published: Dictionary = {}
	for raw_contact: Variant in active_contacts:
		var contact: Dictionary = raw_contact as Dictionary
		var key: String = str(contact.get("key", ""))
		if key == "" or published.has(key):
			continue
		published[key] = true
		_publish_contact(contact, false)


func evaluation_count() -> int:
	return _evaluation_count


func active_contact_count() -> int:
	return _contacts_by_agent.size()


func _remove_agent_contact(agent_id: int) -> void:
	var previous: Dictionary = _contacts_by_agent.get(agent_id, {}) as Dictionary
	if previous.is_empty():
		return
	_contacts_by_agent.erase(agent_id)
	var key: String = str(previous.get("key", ""))
	var remaining: int = maxi(0, int(_occupant_counts.get(key, 0)) - 1)
	if remaining > 0:
		_occupant_counts[key] = remaining
		return
	_occupant_counts.erase(key)
	_publish_contact(previous, false)


func _resolve_contact(agent: Node2D, category: StringName, cell: Vector2i) -> Dictionary:
	var plant_contact: Dictionary = _resolve_live_plant_contact(agent, category, cell)
	if not plant_contact.is_empty():
		return plant_contact
	return _resolve_building_contact(cell)


func _resolve_live_plant_contact(agent: Node2D, category: StringName, cell: Vector2i) -> Dictionary:
	var plant_manager: Node = _manager.get_plant_manager()
	if plant_manager == null or not plant_manager.has_method("has_plant"):
		return {}
	if not bool(plant_manager.call("has_plant", cell)):
		return {}
	var nav_id: int = int(agent.get("nav_id")) if "nav_id" in agent else -1
	if nav_id >= 0 and _manager.is_agent_destroying_plant_at_cell(nav_id, cell):
		return {}
	if category == CATEGORY_CLIENTS or category == CATEGORY_MERCHANTS:
		return {}
	var item_id: String = ""
	if plant_manager.has_method("get_plant_item_id"):
		item_id = str(plant_manager.call("get_plant_item_id", cell))
	return _contact_record(&"plantz", cell, item_id, false)


func _resolve_building_contact(cell: Vector2i) -> Dictionary:
	var building_objects: BuildingObjectManager = _manager.get_building_object_manager()
	if building_objects == null:
		return {}
	var building_data: Dictionary = building_objects.get_building(cell)
	if building_data.is_empty():
		return {}
	var item_id: String = str(building_data.get("item_id", ""))
	var item_def: Dictionary = ItemCatalog.get_item_def(item_id)
	var behavior: StringName = StringName(item_def.get("agent_contact_behavior", &""))
	if behavior != CONTACT_BEHAVIOR_VISUAL_ONLY and str(item_def.get("category", "")) != CATEGORY_TURRET:
		return {}
	var layer_name: StringName = StringName(building_data.get("target_layer", item_def.get("target_layer", "")))
	return _contact_record(layer_name, cell, item_id, true)


func _contact_record(layer_name: StringName, cell: Vector2i, item_id: String, runtime_visual: bool) -> Dictionary:
	return {
		"key": "%s:%d:%d" % [String(layer_name), cell.x, cell.y],
		"layer_name": layer_name,
		"cell": cell,
		"item_id": item_id,
		"runtime_visual": runtime_visual,
	}


func _same_contact(first: Dictionary, second: Dictionary) -> bool:
	if first.is_empty() or second.is_empty():
		return first.is_empty() and second.is_empty()
	return str(first.get("key", "")) == str(second.get("key", "")) \
		and str(first.get("item_id", "")) == str(second.get("item_id", ""))


func _publish_contact(contact: Dictionary, active: bool) -> void:
	var layer_name: StringName = StringName(contact.get("layer_name", &""))
	var cell: Vector2i = contact.get("cell", Vector2i.ZERO) as Vector2i
	var item_id: String = str(contact.get("item_id", ""))
	_manager.plant_contact_dance_state_changed.emit(layer_name, cell, item_id, active)
	if active:
		# Compatibility pulse for damage/legacy listeners; lifecycle-aware visuals use
		# plant_contact_dance_state_changed and do not require repeated refreshes.
		_manager.plant_contact_dance_requested.emit(layer_name, cell, item_id, CONTACT_DANCE_DURATION)
	if bool(contact.get("runtime_visual", false)):
		var building_objects: BuildingObjectManager = _manager.get_building_object_manager()
		if building_objects != null:
			building_objects.set_contact_dance_active(cell, active)
