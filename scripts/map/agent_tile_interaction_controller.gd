extends RefCounted
class_name AgentTileInteractionController

# Routes a single "agent (re)entered a relevant cell" event to the tile-based
# interactions that apply to that agent's category, delegating the actual gameplay
# mutation to the existing owning controllers. It owns no interaction rule itself:
#   - turret eating   -> TurretEatingController.evaluate_agent
#   - rose trampling  -> BuildingManager.trample_rose_at_agent
#   - pasteque trample-> BuildingManager.trample_pasteque_at_agent
# Called once per cell transition (and per targeted world-cell invalidation) by
# AgentCellTracker, replacing the four per-frame full-agent scans.

const CATEGORY_MONSTERS: StringName = &"monsters"
const CATEGORY_CLIENTS: StringName = &"clients"
const CATEGORY_MERCHANTS: StringName = &"merchants"
const CATEGORY_SHEEP: StringName = &"sheep"
const KRAKEN_ITEM_ID: String = "kraken"
const KRAKEN_LAYER_NAME: String = "traversable_buildings"

var _manager: BuildingManager = null

# Per-frame interaction-check tallies, only maintained when debug logs are enabled.
var _debug_rose: int = 0
var _debug_pasteque: int = 0
var _debug_turret: int = 0
func setup(manager: BuildingManager) -> void:
	_manager = manager


# Evaluate every tile interaction that applies to this agent's category, preserving
# the original non-drowning interaction order: rose -> pasteque -> turret.
# Drowning is run by AgentCellTracker immediately afterwards so the same central
# water result can drive both the targeted candidate set and the drowning start.
func evaluate(agent: Node2D, category: StringName, cell: Vector2i) -> void:
	if _manager == null or agent == null or not is_instance_valid(agent):
		return
	var debug: bool = CppDebugOptions.logs_enabled
	if category == CATEGORY_MONSTERS:
		_damage_kraken_at_cell(cell)
	if category == CATEGORY_CLIENTS or category == CATEGORY_MERCHANTS:
		_manager.trample_rose_at_agent(agent)
		if debug:
			_debug_rose += 1
	if category == CATEGORY_MONSTERS or category == CATEGORY_CLIENTS:
		_manager.trample_pasteque_at_agent(agent)
		if debug:
			_debug_pasteque += 1
	if category != CATEGORY_SHEEP:
		_manager.get_turret_eating_controller().evaluate_agent(agent)
		if debug:
			_debug_turret += 1
	refresh_contact_dance(agent, category)


func _damage_kraken_at_cell(cell: Vector2i) -> void:
	var item_def: Dictionary = ItemCatalog.get_item_def(KRAKEN_ITEM_ID)
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
