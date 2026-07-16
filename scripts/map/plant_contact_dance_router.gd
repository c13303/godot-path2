extends RefCounted
class_name PlantContactDanceRouter

# Visual-only router for "an agent is standing on a non-destroyed plant-like tile".
# Detection stays close to AgentCellTracker; plant/building visual owners listen to
# BuildingManager.plant_contact_dance_requested and decide how to animate.

const CONTACT_DANCE_DURATION: float = 0.16
const CATEGORY_CLIENTS: StringName = &"clients"
const CATEGORY_MERCHANTS: StringName = &"merchants"
const CATEGORY_TURRET: String = "turret"
const CONTACT_BEHAVIOR_VISUAL_ONLY: StringName = &"contact_visual_only"

var _manager: BuildingManager


func setup(manager: BuildingManager) -> void:
	_manager = manager


func request_agent_contact(agent: Node2D, category: StringName) -> void:
	if _manager == null or agent == null or not is_instance_valid(agent) or _manager.floorz == null:
		return
	var cell: Vector2i = _manager.floorz.local_to_map(_manager.floorz.to_local(agent.global_position))
	var nav_id: int = int(agent.get("nav_id")) if "nav_id" in agent else -1
	_request_cell_contact(cell, category, nav_id)


func request_player_contact() -> void:
	if _manager == null:
		return
	var player: Node2D = _manager.get_tree().get_first_node_in_group("player") as Node2D
	if player == null:
		return
	request_agent_contact(player, &"player")


func _request_cell_contact(cell: Vector2i, category: StringName, nav_id: int) -> void:
	if _request_live_plant_contact(cell, category, nav_id):
		return
	_request_building_contact(cell)


func _request_live_plant_contact(cell: Vector2i, category: StringName, nav_id: int) -> bool:
	var plant_manager: Node = _manager.get_plant_manager()
	if plant_manager == null:
		return false
	if not plant_manager.has_method("has_plant") or not bool(plant_manager.call("has_plant", cell)):
		return false
	if nav_id >= 0 and _manager.is_agent_destroying_plant_at_cell(nav_id, cell):
		return true
	if category == CATEGORY_CLIENTS or category == CATEGORY_MERCHANTS:
		return true
	var item_id: String = ""
	if plant_manager.has_method("get_plant_item_id"):
		item_id = str(plant_manager.call("get_plant_item_id", cell))
	_manager.plant_contact_dance_requested.emit(&"plantz", cell, item_id, CONTACT_DANCE_DURATION)
	return true


func _request_building_contact(cell: Vector2i) -> bool:
	var building_objects: BuildingObjectManager = _manager.get_building_object_manager()
	if building_objects == null or not building_objects.has_method("get_building"):
		return false
	var building_data: Dictionary = building_objects.call("get_building", cell) as Dictionary
	if building_data.is_empty():
		return false
	var item_id: String = str(building_data.get("item_id", ""))
	var item_def: Dictionary = ItemCatalog.get_item_def(item_id)
	var target_layer: StringName = StringName(building_data.get("target_layer", item_def.get("target_layer", "")))
	if StringName(item_def.get("agent_contact_behavior", &"")) == CONTACT_BEHAVIOR_VISUAL_ONLY:
		_manager.plant_contact_dance_requested.emit(target_layer, cell, item_id, CONTACT_DANCE_DURATION)
		return true
	if str(item_def.get("category", "")) != CATEGORY_TURRET:
		return false
	_manager.plant_contact_dance_requested.emit(target_layer, cell, item_id, CONTACT_DANCE_DURATION)
	if building_objects.has_method("request_contact_dance"):
		building_objects.call("request_contact_dance", cell, CONTACT_DANCE_DURATION)
	return true
