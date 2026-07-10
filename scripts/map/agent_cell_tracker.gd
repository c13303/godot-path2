extends RefCounted
class_name AgentCellTracker

# Detects when a tracked agent enters a different map cell and queues one tile-based
# environment check for it, replacing four independent per-frame full-agent scans
# (drowning start + splash, turret overlap, rose trampling, pasteque trampling).
#
# One lightweight pass per frame:
#   1. poll every registered agent once, compute its floorz cell, and enqueue it only
#      when that cell changed since last frame (or on its first check after spawn);
#   2. drain the dedup queue, dispatching each agent through
#      AgentTileInteractionController (which delegates to the owning controllers);
#   3. tick the continuous water splash for the small set of agents currently over
#      water (the only genuinely continuous part of the old drowning scan).
#
# A cell->agent index lets a world change (turret/pasteque/rose appearing) re-queue
# only the agents standing on the affected cell, so stationary agents stay correct
# without restoring a global scan.
#
# Agents are keyed by instance_id (stable and available at registration time; nav_id
# is assigned slightly later during spawn) and held via WeakRef so a freed node is
# never kept alive and is discarded safely.

const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)

var _manager: BuildingManager = null
var _interactions: AgentTileInteractionController = AgentTileInteractionController.new()

# instance_id -> { "ref": WeakRef, "category": StringName, "cell": Vector2i }.
var _agents: Dictionary = {}
# Vector2i cell -> Dictionary(instance_id -> true). Only agents with a known cell.
var _cell_to_agents: Dictionary = {}
# instance_id -> true for agents currently over water (splash ticked every frame).
var _over_water: Dictionary = {}
# FIFO dedup queue of instance_ids pending an interaction check.
var _queue: Array[int] = []
var _queued: Dictionary = {}

# Per-frame debug counters, only maintained when debug logs are enabled.
var _debug_transitions: int = 0
var _debug_checked: int = 0
var _debug_invalidations: int = 0


func setup(manager: BuildingManager) -> void:
	_manager = manager
	_interactions.setup(manager)


# Registration is idempotent (dedup on instance_id). The sentinel cell forces the
# first poll to enqueue the agent, guaranteeing an initial interaction check even if
# the agent never moves (e.g. spawned directly on an interactive tile).
func register(agent: Node2D, category: StringName) -> void:
	if agent == null or not is_instance_valid(agent):
		return
	var id: int = agent.get_instance_id()
	if _agents.has(id):
		return
	_agents[id] = {
		"ref": weakref(agent),
		"category": category,
		"cell": INVALID_CELL,
	}


func unregister(agent: Node2D) -> void:
	if agent == null:
		return
	_remove_id(agent.get_instance_id())


func registered_count() -> int:
	return _agents.size()


# The single per-frame pass that replaces the four full-agent scans.
func process(delta: float) -> void:
	if _manager == null:
		return
	if CppDebugOptions.logs_enabled:
		_debug_transitions = 0
		_debug_checked = 0
		_debug_invalidations = 0
		_interactions.reset_debug_counters()
	_poll_transitions()
	_drain_queue()
	_tick_water_splash(delta)


# Re-queue every registered agent standing on a cell that just became interactive
# (turret/pasteque placed, rose planted), so a stationary agent is re-evaluated
# without a global scan. Enqueued agents are processed on the next process() pass.
func invalidate_cell(cell: Vector2i) -> void:
	if not _cell_to_agents.has(cell):
		return
	var bucket: Dictionary = _cell_to_agents[cell] as Dictionary
	for raw_id: Variant in bucket.keys():
		_enqueue(int(raw_id))
		if CppDebugOptions.logs_enabled:
			_debug_invalidations += 1


func invalidate_cells(cells: Array[Vector2i]) -> void:
	for cell: Vector2i in cells:
		invalidate_cell(cell)


# Wipe all state on level unload / bulk agent clear (e.g. save load).
func clear() -> void:
	_agents.clear()
	_cell_to_agents.clear()
	_over_water.clear()
	_queue.clear()
	_queued.clear()


func debug_stats() -> Dictionary:
	var stats: Dictionary = {
		"registered": _agents.size(),
		"transitions": _debug_transitions,
		"checked": _debug_checked,
		"invalidations": _debug_invalidations,
		"over_water": _over_water.size(),
	}
	var by_type: Dictionary = _interactions.debug_stats()
	for key: Variant in by_type.keys():
		stats[key] = by_type[key]
	return stats


# --- internals -----------------------------------------------------------------


func _poll_transitions() -> void:
	var floor_layer: TileMapLayer = _manager.floorz
	if floor_layer == null:
		return
	var debug: bool = CppDebugOptions.logs_enabled
	var dead: Array[int] = []
	# Safe to iterate _agents directly: the body never adds/removes its keys (dead
	# ids are collected and removed after the loop); only value dicts and the sibling
	# index/queue dictionaries are mutated.
	for raw_id: Variant in _agents:
		var id: int = int(raw_id)
		var record: Dictionary = _agents[id] as Dictionary
		var agent: Node2D = (record["ref"] as WeakRef).get_ref() as Node2D
		if agent == null or not is_instance_valid(agent) or agent.is_queued_for_deletion():
			dead.append(id)
			continue
		var cell: Vector2i = floor_layer.local_to_map(floor_layer.to_local(agent.global_position))
		var last_cell: Vector2i = record["cell"] as Vector2i
		if cell != last_cell:
			_reindex(id, last_cell, cell)
			record["cell"] = cell
			_enqueue(id)
			if debug:
				_debug_transitions += 1
	for id: int in dead:
		_remove_id(id)


func _drain_queue() -> void:
	var debug: bool = CppDebugOptions.logs_enabled
	# Snapshot the length: interactions never enqueue new work (agents don't move
	# here), so a single index pass over the current queue is deterministic (FIFO).
	var count: int = _queue.size()
	for i: int in range(count):
		var id: int = _queue[i]
		if not _queued.has(id):
			continue
		var record: Dictionary = _agents.get(id, {}) as Dictionary
		if record.is_empty():
			continue
		var agent: Node2D = (record["ref"] as WeakRef).get_ref() as Node2D
		if agent == null or not is_instance_valid(agent) or agent.is_queued_for_deletion():
			_remove_id(id)
			continue
		var category: StringName = record["category"] as StringName
		var cell: Vector2i = record["cell"] as Vector2i
		_interactions.evaluate(agent, category, cell)
		_update_over_water(id, agent)
		if debug:
			_debug_checked += 1
	_queue.clear()
	_queued.clear()


func _tick_water_splash(delta: float) -> void:
	if _over_water.is_empty():
		return
	var drowning: DrowningController = _manager.get_drowning_controller()
	if drowning == null:
		return
	var dead: Array[int] = []
	for raw_id: Variant in _over_water:
		var id: int = int(raw_id)
		var record: Dictionary = _agents.get(id, {}) as Dictionary
		if record.is_empty():
			dead.append(id)
			continue
		var agent: Node2D = (record["ref"] as WeakRef).get_ref() as Node2D
		if agent == null or not is_instance_valid(agent):
			dead.append(id)
			continue
		# tick_splash keeps its own foot-position water guard, so a sub-cell move off
		# water without a transition still stops splashing (and cleans its meta timer).
		drowning.tick_splash(agent, delta)
	for id: int in dead:
		_over_water.erase(id)


func _update_over_water(id: int, agent: Node2D) -> void:
	var drowning: DrowningController = _manager.get_drowning_controller()
	if drowning != null and drowning.is_over_water(agent):
		_over_water[id] = true
	else:
		_over_water.erase(id)


func _reindex(id: int, old_cell: Vector2i, new_cell: Vector2i) -> void:
	if old_cell != INVALID_CELL and _cell_to_agents.has(old_cell):
		var old_bucket: Dictionary = _cell_to_agents[old_cell] as Dictionary
		old_bucket.erase(id)
		if old_bucket.is_empty():
			_cell_to_agents.erase(old_cell)
	if new_cell != INVALID_CELL:
		var new_bucket: Dictionary = _cell_to_agents.get(new_cell, {}) as Dictionary
		new_bucket[id] = true
		_cell_to_agents[new_cell] = new_bucket


func _enqueue(id: int) -> void:
	if _queued.has(id):
		return
	_queue.append(id)
	_queued[id] = true


func _remove_id(id: int) -> void:
	var record: Dictionary = _agents.get(id, {}) as Dictionary
	if not record.is_empty():
		var cell: Vector2i = record["cell"] as Vector2i
		if cell != INVALID_CELL and _cell_to_agents.has(cell):
			var bucket: Dictionary = _cell_to_agents[cell] as Dictionary
			bucket.erase(id)
			if bucket.is_empty():
				_cell_to_agents.erase(cell)
	_agents.erase(id)
	_over_water.erase(id)
	_queued.erase(id)
