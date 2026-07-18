extends HouseResidentRole
class_name SheepGardenRole

## The sheep's garden work, and nothing else. All shared house-villager lifecycle (spawn, walk-in,
## night return home, evacuation, repath, removal, identity, interaction hold) lives in the
## HouseResidentController this role is attached to, and every walk goes through its
## send_on_errand(). The sheep's dialog lives in SheepDialogController.
##
## Whenever it is free the sheep takes the nearest of two jobs:
##   * eat a plant debris  -> the debris is cleared and the player is paid a gem;
##   * mend a damaged wet-grass building (rose, imperial plant, ronce, epine turret, kraken)
##     -> its health is healed back, REPAIR_FULL_SECONDS for a full bar and proportionally less
##        for a partial one. Health ownership stays with PlayerPlaceableDurabilityService; this
##        role only asks it to heal.
##
## Routing rule: the sheep never walks over a live plant (it would trample the player's crop), so
## its errands use BuildingManager.find_sheep_path instead of the ordinary villager walkable map.
## That also means it cannot stand on the rose it is mending — see _reach_cell_for.

const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)
const EAT_SECONDS: float = 2.0
## Seconds to heal a building's whole health bar. A partial repair costs proportionally less.
const REPAIR_FULL_SECONDS: float = 2.0
## How often an idle sheep with nothing to do looks for a new job. Scanning for one walks every
## damaged durability target (and every debris cell), so the search is polled at this cadence
## rather than every frame; finishing a job still picks the next one immediately.
const IDLE_TASK_SCAN_SECONDS: float = 0.5
const MAX_PATH_TARGET_ATTEMPTS: int = 8
const DEBRIS_REWARD_GEMS: int = 1
const TASK_DEBRIS: StringName = &"debris"
const TASK_REPAIR: StringName = &"repair"
const NEIGHBOUR_OFFSETS: Array[Vector2i] = [
	Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0),
	Vector2i(1, -1), Vector2i(1, 1), Vector2i(-1, 1), Vector2i(-1, -1),
]

var _manager: BuildingManager = null
var _state: StringName = &"idle"
## The cell being worked on (the debris, or the building being mended) — not necessarily the cell
## the sheep stands on. See _reach_cell_for.
var _work_cell: Vector2i = INVALID_CELL
var _repair_key: String = ""
var _repair_rate: float = 0.0
var _repair_progress: float = 0.0
var _eat_timer: float = 0.0
var _idle_scan_timer: float = 0.0
var _debris_cells: Dictionary = {}
var _unreachable_debris: Dictionary = {}
var _unreachable_repairs: Dictionary = {}


func setup(manager: BuildingManager) -> void:
	_manager = manager
	_connect_plant_manager()


# ---------------------------------------------------------------------------
# HouseResidentRole hooks.
# ---------------------------------------------------------------------------

func on_spawned(_resident: HouseResidentController) -> void:
	_reset_work_state()
	_unreachable_debris.clear()
	_unreachable_repairs.clear()
	_rebuild_debris_index()


## The sheep parked: either it walked in / came back to its idle spot, or it just arrived within
## reach of the job it set out to do.
func on_reached_spot(resident: HouseResidentController) -> void:
	match _state:
		&"moving_to_debris":
			# The debris may have been cleared while the sheep walked to it; then look for another job.
			if not _start_eating(resident):
				_pick_next_task(resident)
		&"moving_to_repair":
			if not _start_repairing(resident):
				_pick_next_task(resident)
		_:
			_state = &"idle"


func on_night_started(resident: HouseResidentController) -> void:
	# The controller is already walking the sheep home; just stop working.
	_cancel_work(resident)


func on_leaving(resident: HouseResidentController) -> void:
	_cancel_work(resident)


func on_cleared() -> void:
	_reset_work_state()


func process(resident: HouseResidentController, delta: float) -> void:
	if _manager == null or not resident.is_active() or resident.is_leaving():
		return
	if GameState.is_night:
		return
	# The sheep only works once it has settled in town, and never while the player is holding it
	# in conversation (the interaction hold pauses its movement, so starting a walk would stall).
	if not resident.has_reached_idle_spot() or resident.is_interaction_held():
		return
	match _state:
		&"eating":
			_process_eating(resident, delta)
		&"repairing":
			_process_repairing(resident, delta)
		&"moving_to_debris":
			# Arrival is reported through on_reached_spot; only abandon a job that went away.
			if not _is_debris_cell(_work_cell):
				_pick_next_task(resident)
		&"moving_to_repair":
			if not _is_repairable_key(_repair_key):
				_pick_next_task(resident)
		&"returning_idle":
			pass
		_:
			_process_idle_task_search(resident, delta)


# ---------------------------------------------------------------------------
# Task selection.
# ---------------------------------------------------------------------------

## Idle with nothing to do: poll for a new job on a timer rather than every frame (see
## IDLE_TASK_SCAN_SECONDS). This is the only path that searches repeatedly without finding work, so
## it is the only one that needs throttling.
func _process_idle_task_search(resident: HouseResidentController, delta: float) -> void:
	if not resident.is_parked():
		return
	_idle_scan_timer -= delta
	if _idle_scan_timer > 0.0:
		return
	_idle_scan_timer = IDLE_TASK_SCAN_SECONDS
	_pick_next_task(resident)


## Sends the sheep to the nearest job it can actually reach, or home to its idle spot when there is
## nothing left to do. A job that cannot be pathed to is remembered so the sheep stops retrying it
## for the rest of the day (on_spawned clears those lists each morning).
func _pick_next_task(resident: HouseResidentController) -> void:
	var from_cell: Vector2i = resident.current_cell()
	if from_cell == INVALID_CELL:
		return
	_manager.ensure_sheep_path_topology_synced()
	for task: Dictionary in _nearest_tasks(from_cell):
		if _start_task(resident, from_cell, task):
			return
		_mark_unreachable(task)
	_return_to_idle_spot(resident, from_cell)


## Every job the sheep could take right now, nearest first — debris and damaged wet-grass buildings
## compete in one list, so "closest wins" holds across both kinds.
func _nearest_tasks(from_cell: Vector2i) -> Array[Dictionary]:
	var tasks: Array[Dictionary] = []
	for raw_cell: Variant in _debris_cells.keys():
		var cell: Vector2i = raw_cell as Vector2i
		if _unreachable_debris.has(cell) or not _is_debris_cell(cell):
			continue
		tasks.append({"kind": TASK_DEBRIS, "cell": cell, "key": ""})
	for raw_record: Variant in _repairable_records():
		var record: Dictionary = raw_record as Dictionary
		var key: String = str(record.get("key", ""))
		if _unreachable_repairs.has(key):
			continue
		tasks.append({"kind": TASK_REPAIR, "cell": record.get("cell", INVALID_CELL) as Vector2i, "key": key})
	tasks.sort_custom(Callable(self, "_sort_tasks_by_distance").bind(from_cell))
	if tasks.size() > MAX_PATH_TARGET_ATTEMPTS:
		tasks.resize(MAX_PATH_TARGET_ATTEMPTS)
	return tasks


## Damaged buildings the sheep may mend: the durability service already tracks every player-built
## target's health, so this only filters its damaged set down to the wet-grass rule.
func _repairable_records() -> Array:
	var out: Array = []
	var durability: PlayerPlaceableDurabilityService = _durability()
	if durability == null:
		return out
	for raw_record: Variant in durability.damaged_records():
		var record: Dictionary = raw_record as Dictionary
		if ItemCatalog.requires_grass_green_floor(str(record.get("item_id", ""))):
			out.append(record)
	return out


func _start_task(resident: HouseResidentController, from_cell: Vector2i, task: Dictionary) -> bool:
	var cell: Vector2i = task.get("cell", INVALID_CELL) as Vector2i
	if cell == INVALID_CELL:
		return false
	var reach_cell: Vector2i = _reach_cell_for(cell, from_cell)
	if reach_cell == INVALID_CELL:
		return false
	_work_cell = cell
	_repair_key = str(task.get("key", ""))
	var is_repair: bool = StringName(task.get("kind", &"")) == TASK_REPAIR
	# Already standing where the work happens (a rose right next to the debris it just ate): start
	# working now rather than pathing to the cell it is on.
	if reach_cell == from_cell:
		var started: bool = _start_repairing(resident) if is_repair else _start_eating(resident)
		if not started:
			_clear_work_target()
		return started
	if not _send_to(resident, from_cell, reach_cell):
		_clear_work_target()
		return false
	_state = &"moving_to_repair" if is_repair else &"moving_to_debris"
	return true


func _clear_work_target() -> void:
	_work_cell = INVALID_CELL
	_repair_key = ""


## Where the sheep must stand to work on `cell`: the cell itself when it may stand there (debris,
## ronce, kraken, epine turret), otherwise the walkable neighbour closest to it. A live rose or
## imperial plant is never standable — that rule is exactly what stops the sheep trampling the
## crop, so it mends those from beside them.
func _reach_cell_for(cell: Vector2i, from_cell: Vector2i) -> Vector2i:
	if _manager.is_sheep_walkable_cell(cell):
		return cell
	var best_cell: Vector2i = INVALID_CELL
	var best_distance: int = 0
	for offset: Vector2i in NEIGHBOUR_OFFSETS:
		var candidate: Vector2i = cell + offset
		if not _manager.is_sheep_walkable_cell(candidate):
			continue
		var distance: int = _cell_distance_sq(candidate, from_cell)
		if best_cell == INVALID_CELL or distance < best_distance:
			best_cell = candidate
			best_distance = distance
	return best_cell


func _mark_unreachable(task: Dictionary) -> void:
	if StringName(task.get("kind", &"")) == TASK_REPAIR:
		_unreachable_repairs[str(task.get("key", ""))] = true
	else:
		_unreachable_debris[task.get("cell", INVALID_CELL) as Vector2i] = true


func _return_to_idle_spot(resident: HouseResidentController, from_cell: Vector2i) -> void:
	_reset_work_state()
	var idle_cell: Vector2i = resident.idle_cell()
	if idle_cell == INVALID_CELL or from_cell == idle_cell:
		return
	if _send_to(resident, from_cell, idle_cell):
		_state = &"returning_idle"


func _send_to(resident: HouseResidentController, from_cell: Vector2i, to_cell: Vector2i) -> bool:
	var path_cells: PackedVector2Array = _manager.find_sheep_path(from_cell, to_cell)
	if path_cells.is_empty():
		return false
	return resident.send_on_errand(to_cell, path_cells)


# ---------------------------------------------------------------------------
# Eating debris.
# ---------------------------------------------------------------------------

func _start_eating(resident: HouseResidentController) -> bool:
	if not _is_debris_cell(_work_cell):
		return false
	_state = &"eating"
	_eat_timer = EAT_SECONDS
	_start_work_animation(resident, EAT_SECONDS)
	return true


func _process_eating(resident: HouseResidentController, delta: float) -> void:
	_eat_timer -= delta
	if _eat_timer > 0.0:
		return
	var eaten_cell: Vector2i = _work_cell
	_stop_work_animation(resident)
	_reset_work_state()
	if _is_debris_cell(eaten_cell):
		_consume_debris(eaten_cell)
	_pick_next_task(resident)


func _consume_debris(cell: Vector2i) -> void:
	var reward_position: Vector2 = _manager.cell_center(cell)
	var plant_manager: Node = _manager.get_plant_manager()
	if plant_manager != null and plant_manager.has_method("remove_debris"):
		plant_manager.call("remove_debris", cell)
	_manager.refresh_runtime_cell_speed(cell)
	_debris_cells.erase(cell)
	_unreachable_debris.erase(cell)
	Sfx.play_sound(&"crunsh")
	_spawn_debris_reward_gems(reward_position)


# ---------------------------------------------------------------------------
# Repairing wet-grass buildings.
# ---------------------------------------------------------------------------

func _start_repairing(resident: HouseResidentController) -> bool:
	# Guarantees a live, damaged target, so max_health is necessarily above 0 below.
	if not _is_repairable_key(_repair_key):
		return false
	var record: Dictionary = _repair_record(_repair_key)
	_state = &"repairing"
	_repair_progress = 0.0
	# Constant health-per-second for this building: a full bar costs REPAIR_FULL_SECONDS, so a
	# half-empty one costs half that. Rate is per-building, since max_health differs per item.
	_repair_rate = float(int(record.get("max_health", 0))) / REPAIR_FULL_SECONDS
	_start_work_animation(resident, _repair_seconds_remaining(record))
	return true


## Heals the target as the sheep works, so the bar visibly fills and an interrupted repair still
## leaves the building better off. Health is an int, so fractional progress is accumulated here and
## handed over a point at a time.
func _process_repairing(resident: HouseResidentController, delta: float) -> void:
	if not _is_repairable_key(_repair_key):
		_finish_repairing(resident)
		return
	_repair_progress += delta * _repair_rate
	var health_points: int = int(floor(_repair_progress))
	if health_points <= 0:
		return
	_repair_progress -= float(health_points)
	var durability: PlayerPlaceableDurabilityService = _durability()
	if durability == null or durability.apply_repair(_repair_key, health_points) <= 0:
		_finish_repairing(resident)
		return
	if not _is_repairable_key(_repair_key):
		_finish_repairing(resident)


func _finish_repairing(resident: HouseResidentController) -> void:
	_stop_work_animation(resident)
	_reset_work_state()
	_pick_next_task(resident)


func _repair_record(key: String) -> Dictionary:
	var durability: PlayerPlaceableDurabilityService = _durability()
	if durability == null or key == "" or not durability.is_target_valid(key):
		return {}
	return durability.target_record(key)


## True while `key` names a live, damaged wet-grass building. A destroyed target (health 0) is gone
## for good, so the sheep never nurses it back.
func _is_repairable_key(key: String) -> bool:
	var record: Dictionary = _repair_record(key)
	if record.is_empty():
		return false
	var health: int = int(record.get("health", 0))
	var max_health: int = int(record.get("max_health", 0))
	if health <= 0 or health >= max_health:
		return false
	return ItemCatalog.requires_grass_green_floor(str(record.get("item_id", "")))


func _repair_seconds_remaining(record: Dictionary) -> float:
	if _repair_rate <= 0.0:
		return 0.0
	var missing_health: int = maxi(0, int(record.get("max_health", 0)) - int(record.get("health", 0)))
	return float(missing_health) / _repair_rate


# ---------------------------------------------------------------------------
# Work state / animation.
# ---------------------------------------------------------------------------

## Both jobs reuse the agent's eating animation and native eating phase: it is the villager rig's
## only "busy in place" state, and it reads as the sheep nuzzling whatever it is working on.
func _start_work_animation(resident: HouseResidentController, seconds: float) -> void:
	var agent: Node2D = resident.agent_node()
	if agent != null and agent.has_method("start_eating"):
		agent.call("start_eating", seconds)


func _stop_work_animation(resident: HouseResidentController) -> void:
	var agent: Node2D = resident.agent_node()
	if agent != null and agent.has_method("stop_eating"):
		agent.call("stop_eating")


func _cancel_work(resident: HouseResidentController) -> void:
	if _state == &"eating" or _state == &"repairing":
		_stop_work_animation(resident)
	_reset_work_state()


func _reset_work_state() -> void:
	_state = &"idle"
	_work_cell = INVALID_CELL
	_repair_key = ""
	_repair_rate = 0.0
	_repair_progress = 0.0
	_eat_timer = 0.0


func _durability() -> PlayerPlaceableDurabilityService:
	return _manager.get_player_placeable_durability_service() if _manager != null else null


# ---------------------------------------------------------------------------
# Rewards.
# ---------------------------------------------------------------------------

func _spawn_debris_reward_gems(world_position: Vector2) -> void:
	var scene: Node = _manager.get_tree().current_scene
	var gem_icon: Node = scene.get_node_or_null("GameUI/currenciesUI/gemIcon") if scene != null else null
	if gem_icon != null and gem_icon.has_method("animate_gem_harvest"):
		for i: int in range(DEBRIS_REWARD_GEMS):
			var started: bool = bool(gem_icon.call("animate_gem_harvest", world_position, i))
			if not started:
				_credit_debris_reward_gem()
		return
	for i: int in range(DEBRIS_REWARD_GEMS):
		_credit_debris_reward_gem()


func _credit_debris_reward_gem() -> void:
	var scene: Node = _manager.get_tree().current_scene
	var progression_node: Node = scene.get_node_or_null("progression") if scene != null else null
	if progression_node != null and progression_node.has_method("update_gems"):
		progression_node.call("update_gems", 1)


# ---------------------------------------------------------------------------
# Debris index.
# ---------------------------------------------------------------------------

func _rebuild_debris_index() -> void:
	_debris_cells.clear()
	var plant_manager: Node = _manager.get_plant_manager() if _manager != null else null
	if plant_manager == null or not plant_manager.has_method("debris_cells"):
		return
	var registry: Dictionary = plant_manager.call("debris_cells") as Dictionary
	for raw_cell: Variant in registry.keys():
		var cell: Vector2i = raw_cell as Vector2i
		_debris_cells[cell] = true


func _is_debris_cell(cell: Vector2i) -> bool:
	if cell == INVALID_CELL:
		return false
	var plant_manager: Node = _manager.get_plant_manager() if _manager != null else null
	return plant_manager != null and plant_manager.has_method("has_debris") and bool(plant_manager.call("has_debris", cell))


func _connect_plant_manager() -> void:
	var plant_manager: Node = _manager.get_plant_manager() if _manager != null else null
	if plant_manager == null:
		return
	for signal_name: StringName in [&"debris_added", &"debris_removed"]:
		if not plant_manager.has_signal(signal_name):
			continue
		var callback: Callable = Callable(self, "_on_debris_registry_changed")
		if not plant_manager.is_connected(signal_name, callback):
			plant_manager.connect(signal_name, callback)


func _on_debris_registry_changed(cell: Vector2i) -> void:
	if _is_debris_cell(cell):
		_debris_cells[cell] = true
	else:
		_debris_cells.erase(cell)
		_unreachable_debris.erase(cell)


# ---------------------------------------------------------------------------
# Sorting helpers.
# ---------------------------------------------------------------------------

func _sort_tasks_by_distance(a: Dictionary, b: Dictionary, from_cell: Vector2i) -> bool:
	var a_distance: int = _cell_distance_sq(a.get("cell", INVALID_CELL) as Vector2i, from_cell)
	var b_distance: int = _cell_distance_sq(b.get("cell", INVALID_CELL) as Vector2i, from_cell)
	return a_distance < b_distance


func _cell_distance_sq(a: Vector2i, b: Vector2i) -> int:
	var delta: Vector2i = a - b
	return delta.x * delta.x + delta.y * delta.y
