extends RefCounted
class_name AgentTileInteractionController

# Routes a single "agent (re)entered a relevant cell" event to the tile-based
# interactions that apply to that agent's category, delegating the actual gameplay
# mutation to the existing owning controllers. It owns no interaction rule itself:
#   - drowning start  -> DrowningController.evaluate_agent
#   - turret eating   -> TurretEatingController.evaluate_agent
#   - rose trampling  -> BuildingManager.trample_rose_at_agent
#   - pasteque trample-> BuildingManager.trample_pasteque_at_agent
# Called once per cell transition (and per targeted world-cell invalidation) by
# AgentCellTracker, replacing the four per-frame full-agent scans.

const CATEGORY_MONSTERS: StringName = &"monsters"
const CATEGORY_CLIENTS: StringName = &"clients"
const CATEGORY_MERCHANTS: StringName = &"merchants"
const CATEGORY_SHEEP: StringName = &"sheep"

var _manager: BuildingManager = null

# Per-frame interaction-check tallies, only maintained when debug logs are enabled.
var _debug_rose: int = 0
var _debug_pasteque: int = 0
var _debug_turret: int = 0
var _debug_drowning: int = 0


func setup(manager: BuildingManager) -> void:
	_manager = manager


# Evaluate every tile interaction that applies to this agent's category, preserving
# the original per-frame scan order: rose -> pasteque -> turret -> drowning. Each
# delegate re-reads the agent's exact cell/footprint from its own tile layer, so the
# interaction rule stays byte-for-byte identical to the old scans.
func evaluate(agent: Node2D, category: StringName, _cell: Vector2i) -> void:
	if _manager == null or agent == null or not is_instance_valid(agent):
		return
	var debug: bool = CppDebugOptions.logs_enabled
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
	# Drowning applies to every tracked category (monsters/clients/merchants/sheep).
	_manager.get_drowning_controller().evaluate_agent(agent)
	if debug:
		_debug_drowning += 1


func reset_debug_counters() -> void:
	_debug_rose = 0
	_debug_pasteque = 0
	_debug_turret = 0
	_debug_drowning = 0


func debug_stats() -> Dictionary:
	return {
		"rose": _debug_rose,
		"pasteque": _debug_pasteque,
		"turret": _debug_turret,
		"drowning": _debug_drowning,
	}
