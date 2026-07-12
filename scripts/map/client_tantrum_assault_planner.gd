extends RefCounted
class_name ClientTantrumAssaultPlanner

# Owns the spatial "who attacks where" bookkeeping for a client tantrum so the
# crowd spreads across nearby buildings instead of stacking onto one endpoint.
#
# Responsibilities (and nothing else):
#   * generate attack slots around each destructible target;
#   * reserve one logical slot per hostile client;
#   * count reservations per target and per world attack-cell;
#   * score and pick the best available target/slot for a client;
#   * release reservations;
#   * expose an availability revision so waiting clients can wake when a slot frees.
#
# It does NOT own attack timers, animation, damage, client lifecycle, pathfinding,
# target health, or building destruction. ClientTantrumController owns all of that
# and owns this planner directly. Target structure/health stays in
# PlayerPlaceableDurabilityService; this planner only reads it.

const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)

# Two clients may share one attack tile; endpoint dispersion + native separation
# keep their exact positions distinct.
const SLOTS_PER_ATTACK_CELL: int = 2
# Global cap per world attack cell, applied across neighboring buildings too, so two
# adjacent structures cannot both jam two clients into the same shared walkable cell.
const MAX_RESERVATIONS_PER_ATTACK_CELL: int = 2
# Extra "distance" (in tiles) charged per client already assigned to a target, so the
# crowd spreads to nearby targets instead of dogpiling the closest one.
const TARGET_LOAD_PENALTY_TILES: float = 1.5

const NEIGHBOR_OFFSETS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
]

var _manager: BuildingManager = null
var _durability: PlayerPlaceableDurabilityService = null

# Slot cache, rebuilt only when the durability target revision changes.
var _cache_target_revision: int = -1
# slot_id(String) -> { "target_key": String, "attack_cell": Vector2i,
#                      "slot_id": String, "instant_destroy": bool }
var _slots_by_id: Dictionary = {}
# target_key(String) -> Array[String] slot_ids (deterministic order)
var _slot_ids_by_target: Dictionary = {}

# Reservation ownership. Every reservation has exactly one owner.
var _reservation_by_nav_id: Dictionary = {}       # nav_id(int) -> slot_id(String)
var _reserved_nav_id_by_slot_id: Dictionary = {}  # slot_id(String) -> nav_id(int)
var _reservation_count_by_target: Dictionary = {} # target_key(String) -> int
var _reservation_count_by_cell: Dictionary = {}   # cell_key(String) -> int

# Increases when free perimeter increases (release, invalid-reservation pruning,
# clear). It does NOT increase when a new reservation merely consumes a free slot.
var _availability_revision: int = 0


func setup(manager: BuildingManager, durability: PlayerPlaceableDurabilityService) -> void:
	_manager = manager
	_durability = durability


# Rebuilds the slot cache if the target structure changed. Cheap when unchanged
# (single int compare). The controller calls this once per frame before its stage
# loop so queries below read a current cache.
func sync() -> void:
	_ensure_cache()


func availability_revision() -> int:
	return _availability_revision


func clear() -> void:
	_slots_by_id.clear()
	_slot_ids_by_target.clear()
	_reservation_by_nav_id.clear()
	_reserved_nav_id_by_slot_id.clear()
	_reservation_count_by_target.clear()
	_reservation_count_by_cell.clear()
	_cache_target_revision = -1
	_bump_availability()


# ---------------------------------------------------------------------------
# Reservation queries.
# ---------------------------------------------------------------------------
func has_valid_reservation(nav_id: int) -> bool:
	if not _reservation_by_nav_id.has(nav_id):
		return false
	var slot_id: String = str(_reservation_by_nav_id[nav_id])
	if not _slots_by_id.has(slot_id):
		return false
	var slot: Dictionary = _slots_by_id[slot_id] as Dictionary
	return _durability.is_target_valid(str(slot.get("target_key", "")))


func reservation(nav_id: int) -> Dictionary:
	if not _reservation_by_nav_id.has(nav_id):
		return {}
	var slot_id: String = str(_reservation_by_nav_id[nav_id])
	if not _slots_by_id.has(slot_id):
		return {}
	return _assignment_from_slot(_slots_by_id[slot_id] as Dictionary)


# ---------------------------------------------------------------------------
# Reservation mutation.
# ---------------------------------------------------------------------------
# Picks the best available target/slot for this client and reserves it. Returns an
# explicit assignment { target_key, attack_cell, slot_id, instant_destroy } or {}
# when nothing is currently available (all useful perimeter occupied / rejected).
func reserve_best_assignment(nav_id: int, from_world: Vector2, rejected_slot_ids: Dictionary) -> Dictionary:
	_ensure_cache()
	# Free this client's own slot first so it never competes with itself; a matching
	# re-reservation below keeps net availability unchanged (no availability bump).
	_release_internal(nav_id, false)

	var tile_scale: float = _tile_scale()
	var best_slot_id: String = ""
	var best_score: float = INF
	for raw_target_key: Variant in _slot_ids_by_target.keys():
		var target_key: String = str(raw_target_key)
		if not _durability.is_target_valid(target_key):
			continue
		var assigned_load: int = int(_reservation_count_by_target.get(target_key, 0))
		var load_penalty: float = float(assigned_load) * TARGET_LOAD_PENALTY_TILES
		var slot_ids: Array = _slot_ids_by_target[target_key] as Array
		for raw_slot_id: Variant in slot_ids:
			var slot_id: String = str(raw_slot_id)
			if rejected_slot_ids.has(slot_id):
				continue
			if _reserved_nav_id_by_slot_id.has(slot_id):
				continue
			var slot: Dictionary = _slots_by_id[slot_id] as Dictionary
			var attack_cell: Vector2i = slot.get("attack_cell", INVALID_CELL) as Vector2i
			if int(_reservation_count_by_cell.get(_cell_key(attack_cell), 0)) >= MAX_RESERVATIONS_PER_ATTACK_CELL:
				continue
			var distance_tiles: float = from_world.distance_to(_manager.cell_center(attack_cell)) / tile_scale
			var score: float = distance_tiles + load_penalty
			# Deterministic tie-break: lower score wins; on a tie, lower slot_id string.
			if best_slot_id == "" or score < best_score or (score == best_score and slot_id < best_slot_id):
				best_score = score
				best_slot_id = slot_id
	if best_slot_id == "":
		return {}
	_reserve(nav_id, best_slot_id)
	return _assignment_from_slot(_slots_by_id[best_slot_id] as Dictionary)


func release(nav_id: int) -> bool:
	return _release_internal(nav_id, true)


# ---------------------------------------------------------------------------
# Slot cache.
# ---------------------------------------------------------------------------
func _ensure_cache() -> void:
	var revision: int = _durability.target_revision()
	if revision == _cache_target_revision:
		return
	_cache_target_revision = revision
	_rebuild_slots()


func _rebuild_slots() -> void:
	var new_slots_by_id: Dictionary = {}
	var new_slot_ids_by_target: Dictionary = {}
	for target_key: String in _durability.target_keys():
		var record: Dictionary = _durability.target_record(target_key)
		var cell: Vector2i = record.get("cell", INVALID_CELL) as Vector2i
		if cell == INVALID_CELL:
			continue
		var instant_destroy: bool = bool(record.get("instant_destroy", false))
		var slot_ids: Array[String] = []
		if instant_destroy:
			# One logical slot on the target cell itself, matching current instant
			# plant pathing: the first client to reach it destroys it.
			var slot_id: String = "%s|instant" % target_key
			new_slots_by_id[slot_id] = _make_slot(target_key, cell, slot_id, true)
			slot_ids.append(slot_id)
		else:
			for offset: Vector2i in NEIGHBOR_OFFSETS:
				var attack_cell: Vector2i = cell + offset
				if not _manager.is_walkable_cell(attack_cell):
					continue
				for local_index: int in range(SLOTS_PER_ATTACK_CELL):
					var sid: String = "%s|%d,%d|%d" % [target_key, attack_cell.x, attack_cell.y, local_index]
					new_slots_by_id[sid] = _make_slot(target_key, attack_cell, sid, false)
					slot_ids.append(sid)
		if not slot_ids.is_empty():
			new_slot_ids_by_target[target_key] = slot_ids
	_slots_by_id = new_slots_by_id
	_slot_ids_by_target = new_slot_ids_by_target
	_reconcile_reservations_after_rebuild()


# Keep reservations whose target and exact slot still exist; drop the rest and
# recompute counts from the survivors. Dropping frees perimeter, so bump availability.
func _reconcile_reservations_after_rebuild() -> void:
	var surviving_by_nav: Dictionary = {}
	var surviving_by_slot: Dictionary = {}
	var count_by_target: Dictionary = {}
	var count_by_cell: Dictionary = {}
	var removed_any: bool = false
	for raw_nav_id: Variant in _reservation_by_nav_id.keys():
		var nav_id: int = int(raw_nav_id)
		var slot_id: String = str(_reservation_by_nav_id[nav_id])
		if not _slots_by_id.has(slot_id):
			removed_any = true
			continue
		var slot: Dictionary = _slots_by_id[slot_id] as Dictionary
		var target_key: String = str(slot.get("target_key", ""))
		if not _durability.is_target_valid(target_key):
			removed_any = true
			continue
		surviving_by_nav[nav_id] = slot_id
		surviving_by_slot[slot_id] = nav_id
		count_by_target[target_key] = int(count_by_target.get(target_key, 0)) + 1
		var cell_key: String = _cell_key(slot.get("attack_cell", INVALID_CELL) as Vector2i)
		count_by_cell[cell_key] = int(count_by_cell.get(cell_key, 0)) + 1
	_reservation_by_nav_id = surviving_by_nav
	_reserved_nav_id_by_slot_id = surviving_by_slot
	_reservation_count_by_target = count_by_target
	_reservation_count_by_cell = count_by_cell
	if removed_any:
		_bump_availability()


# ---------------------------------------------------------------------------
# Internal reservation helpers.
# ---------------------------------------------------------------------------
func _reserve(nav_id: int, slot_id: String) -> void:
	var slot: Dictionary = _slots_by_id[slot_id] as Dictionary
	var target_key: String = str(slot.get("target_key", ""))
	var cell_key: String = _cell_key(slot.get("attack_cell", INVALID_CELL) as Vector2i)
	_reservation_by_nav_id[nav_id] = slot_id
	_reserved_nav_id_by_slot_id[slot_id] = nav_id
	_reservation_count_by_target[target_key] = int(_reservation_count_by_target.get(target_key, 0)) + 1
	_reservation_count_by_cell[cell_key] = int(_reservation_count_by_cell.get(cell_key, 0)) + 1


func _release_internal(nav_id: int, bump: bool) -> bool:
	if not _reservation_by_nav_id.has(nav_id):
		return false
	var slot_id: String = str(_reservation_by_nav_id[nav_id])
	_reservation_by_nav_id.erase(nav_id)
	_reserved_nav_id_by_slot_id.erase(slot_id)
	if _slots_by_id.has(slot_id):
		var slot: Dictionary = _slots_by_id[slot_id] as Dictionary
		_decrement_count(_reservation_count_by_target, str(slot.get("target_key", "")))
		_decrement_count(_reservation_count_by_cell, _cell_key(slot.get("attack_cell", INVALID_CELL) as Vector2i))
	if bump:
		_bump_availability()
	return true


func _decrement_count(counts: Dictionary, key: String) -> void:
	var value: int = int(counts.get(key, 0)) - 1
	if value <= 0:
		counts.erase(key)
	else:
		counts[key] = value


func _make_slot(target_key: String, attack_cell: Vector2i, slot_id: String, instant_destroy: bool) -> Dictionary:
	return {
		"target_key": target_key,
		"attack_cell": attack_cell,
		"slot_id": slot_id,
		"instant_destroy": instant_destroy,
	}


func _assignment_from_slot(slot: Dictionary) -> Dictionary:
	return {
		"target_key": str(slot.get("target_key", "")),
		"attack_cell": slot.get("attack_cell", INVALID_CELL) as Vector2i,
		"slot_id": str(slot.get("slot_id", "")),
		"instant_destroy": bool(slot.get("instant_destroy", false)),
	}


func _bump_availability() -> void:
	_availability_revision += 1


func _cell_key(cell: Vector2i) -> String:
	return "%d,%d" % [cell.x, cell.y]


func _tile_scale() -> float:
	var tile_size: Vector2 = _manager.tile_size()
	return maxf(1.0, maxf(tile_size.x, tile_size.y))
