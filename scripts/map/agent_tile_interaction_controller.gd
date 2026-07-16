extends RefCounted
class_name AgentTileInteractionController

# Routes a single "agent (re)entered a relevant cell" event to the tile-based
# interactions that apply to that agent's category, delegating the actual gameplay
# mutation to the existing owning controllers:
#   - turret eating    -> TurretEatingController.evaluate_agent
#   - plant trampling  -> BuildingManager.trample_plant_at_agent
#   - pasteque trample -> BuildingManager.trample_pasteque_at_agent
# Called once per cell transition (and per targeted world-cell invalidation) by
# AgentCellTracker, replacing the four per-frame full-agent scans.
#
# It owns exactly one rule of its own: which categories crush what. Villagers crush every
# crushable placeable, monsters crush only what their own systems allow, sheep crush
# nothing. Being the only place that knows both the agent's category and whether that
# agent actually crushed something, it also raises the trampling alert.

const CATEGORY_MONSTERS: StringName = &"monsters"
const CATEGORY_CLIENTS: StringName = &"clients"
const CATEGORY_MERCHANTS: StringName = &"merchants"
const CATEGORY_BUILDERS: StringName = &"builders"
const CATEGORY_SHEEP: StringName = &"sheep"
const KRAKEN_ITEM_ID: String = "kraken"
const KRAKEN_LAYER_NAME: String = "traversable_buildings"
# The "people agents" crush grouping. Clients, merchants and builders all crush every
# crushable placeable they walk over — plants (roses and imperials alike), pasteques and
# turrets — and warn the player when they do.
# This is a movement/crush rule and is BROADER than the game's "villager" (house-resident
# ally) concept, whose canonical definition lives on AllyHousingController: it also includes
# clients, who are visiting customers and never live in a house. So "villager" here means
# "person who crushes by walking", not "house resident" — the two overlap but are not equal.
# Sheep are deliberately excluded: they are the player's own debris-eating animals, and
# trampling creates the very debris they walk to, so letting them crush would feed itself.
# Monsters are excluded too; they destroy the garden through their own targeting/eating
# systems.
const VILLAGER_CATEGORIES: Array[StringName] = [CATEGORY_CLIENTS, CATEGORY_MERCHANTS, CATEGORY_BUILDERS]
# Raised when a crushing people-agent destroys anything by walking over it. Monsters never raise it:
# wrecking the garden is what they are there for, so it is not worth warning about.
const KEY_PEOPLE_CRUSH_PLANTS: String = "tutorial.people_crush_plants"

var _manager: BuildingManager = null

# Per-frame interaction-check tallies, only maintained when debug logs are enabled.
var _debug_rose: int = 0
var _debug_pasteque: int = 0
var _debug_turret: int = 0
func setup(manager: BuildingManager) -> void:
	_manager = manager


# Evaluate every tile interaction that applies to this agent's category, preserving
# the original non-drowning interaction order: plant -> building-layer placeable.
# Drowning is run by AgentCellTracker immediately afterwards so the same central
# water result can drive both the targeted candidate set and the drowning start.
func evaluate(agent: Node2D, category: StringName, cell: Vector2i) -> void:
	if _manager == null or agent == null or not is_instance_valid(agent):
		return
	var debug: bool = CppDebugOptions.logs_enabled
	var is_villager: bool = VILLAGER_CATEGORIES.has(category)
	var is_monster: bool = category == CATEGORY_MONSTERS
	var crushed_something: bool = false
	if _plant_contact_applies(is_villager):
		if _manager.trample_plant_at_agent(agent):
			crushed_something = true
		if debug:
			_debug_rose += 1
	crushed_something = _evaluate_placeable_contact(agent, category, cell, is_villager, is_monster, debug) or crushed_something
	if crushed_something and is_villager:
		_manager.show_tutorial_alert_once(KEY_PEOPLE_CRUSH_PLANTS)
	refresh_contact_dance(agent, category)


func _evaluate_placeable_contact(
	agent: Node2D,
	category: StringName,
	cell: Vector2i,
	is_villager: bool,
	is_monster: bool,
	debug: bool
) -> bool:
	var placeable: Dictionary = _placeable_at_cell(cell)
	if placeable.is_empty():
		return false
	var item_id: String = str(placeable.get("item_id", ""))
	var item_def: Dictionary = ItemCatalog.get_item_def(item_id)
	if not bool(item_def.get("agent_contact_enabled", false)):
		return _dispatch_scene_contact(placeable, agent, category)
	var behavior: StringName = StringName(item_def.get("agent_contact_behavior", &""))
	var changed: bool = false
	match behavior:
		&"kraken_walkover_damage":
			if is_monster:
				_damage_kraken_at_cell(cell, item_def)
		&"pasteque_trample":
			if is_villager or is_monster:
				if _manager.trample_pasteque_at_agent(agent):
					changed = true
				if debug:
					_debug_pasteque += 1
		&"turret_eating":
			if is_villager or is_monster:
				if _manager.get_turret_eating_controller().evaluate_agent(agent):
					changed = true
				if debug:
					_debug_turret += 1
		&"contact_visual_only":
			pass
		_:
			pass
	if _dispatch_scene_contact(placeable, agent, category):
		changed = true
	return changed


func _plant_contact_applies(is_villager: bool) -> bool:
	return is_villager


func _placeable_at_cell(cell: Vector2i) -> Dictionary:
	var building_objects: BuildingObjectManager = _manager.get_building_object_manager()
	if building_objects == null:
		return {}
	if building_objects.has_method("get_placeable_instance"):
		return building_objects.call("get_placeable_instance", cell) as Dictionary
	if building_objects.has_method("get_building"):
		return building_objects.call("get_building", cell) as Dictionary
	return {}


func _dispatch_scene_contact(placeable: Dictionary, agent: Node2D, category: StringName) -> bool:
	var runtime_node: Node = null
	var raw_cell: Variant = placeable.get("cell", null)
	var cell: Vector2i = Vector2i.ZERO
	if raw_cell is Vector2i:
		cell = raw_cell as Vector2i
	var building_objects: BuildingObjectManager = _manager.get_building_object_manager()
	if building_objects != null and building_objects.has_method("get_runtime_node"):
		runtime_node = building_objects.call("get_runtime_node", cell) as Node
	if runtime_node == null or not is_instance_valid(runtime_node):
		return false
	if not runtime_node.has_method("on_agent_entered_placeable"):
		return false
	var result: Variant = runtime_node.call("on_agent_entered_placeable", agent, category)
	return bool(result) if result is bool else false


func _damage_kraken_at_cell(cell: Vector2i, item_def: Dictionary) -> void:
	var damage: int = maxi(0, int(item_def.get("walkover_damage_by_monsters", 0)))
	if damage <= 0:
		return
	if _manager.has_method("damage_player_placeable_at"):
		_manager.call("damage_player_placeable_at", cell, KRAKEN_LAYER_NAME, KRAKEN_ITEM_ID, damage)


func refresh_contact_dance(agent: Node2D, category: StringName) -> void:
	if _manager == null or agent == null or not is_instance_valid(agent):
		return
	if _manager.has_method("request_agent_plant_contact_dance"):
		_manager.call("request_agent_plant_contact_dance", agent, category)


func reset_debug_counters() -> void:
	_debug_rose = 0
	_debug_pasteque = 0
	_debug_turret = 0


func debug_stats() -> Dictionary:
	return {
		"rose": _debug_rose,
		"pasteque": _debug_pasteque,
		"turret": _debug_turret,
	}
