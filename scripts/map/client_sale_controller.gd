extends RefCounted
class_name ClientSaleController

# Owns the daytime client-sale phase: spawning the night's clients from client
# spawners under per-cell frequency timers, running the per-frame sale loop, and
# deciding when the sale is finished (so the day can advance to night). Mirrors the
# other manager-owned controllers (SeedMerchantController, etc.): it holds a typed
# back-reference to BuildingManager and delegates the spawn primitive, spawner
# registry, counter stock and cross-controller checks through narrow manager APIs.
# It owns only the sale-local state; preparation lifecycle stays in
# BuildingPreparationController and phase gates stay in the manager.

const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)
# Client demand used only for legacy levels that ship no authored spawn playlist.
const LEGACY_FALLBACK_CLIENT_COUNT: int = 20

var _manager: BuildingManager

var _client_sale_active: bool = false
var _client_sale_pending_spawners: Array[Vector2i] = []
var _client_sale_spawn_timers: Dictionary = {}  # Vector2i -> float

# Authoritative day client-step lifecycle. True from the instant a night ends (a new day
# begins) until that day's client step is explicitly completed or skipped. Distinct from
# _client_sale_active, which only covers the active spawning/selling window: this stays
# true through the pre-sale morning/preparation gap so the planificator can keep showing
# the "NOW clients" slot across the whole night->day transition. Owned here (the day
# client-sale owner), never derived from GameState phase booleans by the UI.
var _client_step_pending: bool = false


func setup(manager: BuildingManager) -> void:
	_manager = manager


func reset() -> void:
	_client_sale_active = false
	_client_sale_pending_spawners.clear()
	_client_sale_spawn_timers.clear()


func clear_spawns() -> void:
	_client_sale_pending_spawners.clear()
	_client_sale_spawn_timers.clear()


func is_active() -> bool:
	return _client_sale_active


# --- Day client-step lifecycle (see _client_step_pending) ---

# Open the day's client step. Called by BuildingManager the instant a night ends and the
# new day begins, and on a save loaded straight into a daytime pre/active client phase.
func begin_client_step() -> void:
	_client_step_pending = true


# Close the day's client step: the sale finished, or the day ran no client sale at all
# (skipped), or a fresh night began. After this the planificator previews the next night.
func mark_client_step_finished() -> void:
	_client_step_pending = false


func current_day_client_step_pending_or_active() -> bool:
	return _client_step_pending


func restore_client_step_pending(value: bool) -> void:
	_client_step_pending = value


func serialize_state() -> Dictionary:
	return _serialize_state_with_pending(_client_sale_pending_spawners)


func capture_checkpoint() -> Dictionary:
	var resumed_live_spawners: Array[Vector2i] = []
	var seen_live_agents: Dictionary = {}
	var client_tantrum: ClientTantrumController = _manager.get_client_tantrum_controller()
	if client_tantrum.is_active() or client_tantrum.has_hostiles():
		return _capture_failure("client tantrum is active; hostile clients are not serializable")
	for raw_node: Node in _manager.get_tree().get_nodes_in_group(&"clients"):
		var agent: Node2D = raw_node as Node2D
		if agent == null or not is_instance_valid(agent):
			continue
		if bool(agent.get_meta("client_has_rose", false)):
			continue
		var spawner_cell: Vector2i = agent.get_meta("spawner_cell") as Vector2i if agent.has_meta("spawner_cell") else INVALID_CELL
		if spawner_cell == INVALID_CELL or not _manager.client_spawners().has(spawner_cell):
			var nav_id: int = int(agent.get("nav_id"))
			return _capture_failure("unserved client missing valid source spawner: nav_id=%d spawner=%s" % [nav_id, str(spawner_cell)])
		if seen_live_agents.has(agent):
			continue
		seen_live_agents[agent] = true
		resumed_live_spawners.append(spawner_cell)
	var combined_pending: Array[Vector2i] = []
	for spawner_cell: Vector2i in resumed_live_spawners:
		combined_pending.append(spawner_cell)
	for spawner_cell: Vector2i in _client_sale_pending_spawners:
		combined_pending.append(spawner_cell)
	var state: Dictionary = _serialize_state_with_pending(combined_pending)
	state["resumed_live_client_count"] = resumed_live_spawners.size()
	return {"ok": true, "error": "", "state": state}


func _serialize_state_with_pending(pending_cells: Array[Vector2i]) -> Dictionary:
	var pending_spawners: Array[Dictionary] = []
	for spawner_cell: Vector2i in pending_cells:
		pending_spawners.append({"x": spawner_cell.x, "y": spawner_cell.y})
	var spawn_timers: Array[Dictionary] = []
	for raw_cell: Variant in _client_sale_spawn_timers.keys():
		var cell: Vector2i = raw_cell as Vector2i
		spawn_timers.append({
			"x": cell.x,
			"y": cell.y,
			"time_left": float(_client_sale_spawn_timers[cell]),
		})
	return {
		"active": _client_sale_active,
		"pending_spawners": pending_spawners,
		"spawn_timers": spawn_timers,
	}


func _capture_failure(error: String) -> Dictionary:
	CppDebugOptions.save_log("[SAVE] ClientSaleController: " + error)
	return {"ok": false, "error": error, "state": {}}


func restore_state(data: Dictionary) -> void:
	reset()
	_client_sale_active = bool(data.get("active", false))
	var raw_pending: Variant = data.get("pending_spawners", [])
	if raw_pending is Array:
		for raw_cell: Variant in raw_pending as Array:
			var cell: Vector2i = _cell_from_dict(raw_cell)
			if cell != INVALID_CELL:
				_client_sale_pending_spawners.append(cell)
	var raw_timers: Variant = data.get("spawn_timers", [])
	if raw_timers is Array:
		for raw_entry: Variant in raw_timers as Array:
			if not (raw_entry is Dictionary):
				continue
			var entry: Dictionary = raw_entry as Dictionary
			var cell: Vector2i = _cell_from_dict(entry)
			if cell != INVALID_CELL:
				_client_sale_spawn_timers[cell] = maxf(0.0, float(entry.get("time_left", 0.0)))
	if _client_sale_active:
		GameState.set_client_phase(true)


func _cell_from_dict(raw_value: Variant) -> Vector2i:
	if raw_value is Dictionary:
		var data: Dictionary = raw_value as Dictionary
		return Vector2i(int(data.get("x", INVALID_CELL.x)), int(data.get("y", INVALID_CELL.y)))
	return INVALID_CELL


func has_pending_spawners() -> bool:
	return not _client_sale_pending_spawners.is_empty()


func get_initial_reveal_spawner_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var seen: Dictionary = {}
	for spawner_cell: Vector2i in _client_sale_pending_spawners:
		if seen.has(spawner_cell):
			continue
		if float(_client_sale_spawn_timers.get(spawner_cell, 0.0)) > 0.0:
			continue
		seen[spawner_cell] = true
		cells.append(spawner_cell)
	return cells


func spawn_revealed_client_from_spawner(spawner_cell: Vector2i) -> bool:
	if not _client_sale_active:
		return false
	for index: int in range(_client_sale_pending_spawners.size() - 1, -1, -1):
		if _client_sale_pending_spawners[index] != spawner_cell:
			continue
		if not _manager.spawn_client_from_spawner(spawner_cell):
			_client_sale_spawn_timers[spawner_cell] = SpawnPlaylistController.RETRY_DELAY_SECONDS
			return false
		_client_sale_pending_spawners.remove_at(index)
		var client_frequency_by_cell: Dictionary = _manager.client_frequency_by_cell()
		_client_sale_spawn_timers[spawner_cell] = maxf(0.0, float(client_frequency_by_cell.get(spawner_cell, 1.0)))
		return true
	return false


func activate() -> void:
	if GameState.is_night:
		return
	_client_sale_active = false
	_client_sale_pending_spawners.clear()
	_client_sale_spawn_timers.clear()
	var client_total: int = completed_night_client_count_for_day()
	var client_spawners: Dictionary = _manager.client_spawners()
	if client_total <= 0 or client_spawners.is_empty():
		_manager.on_client_sale_skipped()
		return
	var client_cells: Array[Vector2i] = []
	for raw_cell: Variant in client_spawners.keys():
		client_cells.append(raw_cell as Vector2i)
	if client_cells.is_empty():
		_manager.on_client_sale_skipped()
		return
	for index: int in range(client_total):
		var random_index: int = randi_range(0, client_cells.size() - 1)
		_client_sale_pending_spawners.append(client_cells[random_index])
	for cell: Vector2i in client_cells:
		_client_sale_spawn_timers[cell] = 0.0
	_client_sale_active = true
	GameState.set_client_phase(true)


func process(delta: float) -> void:
	if GameState.is_night:
		return
	if not _client_sale_active:
		_finish_client_phase_if_empty()
		return
	if _manager.is_client_reveal_cutscene_active():
		_process_client_spawns(delta, _manager.released_client_reveal_spawner_cells(), true)
		return
	var client_tantrum: ClientTantrumController = _manager.get_client_tantrum_controller()
	var client_counter_agents: Dictionary = _manager.client_counter_agents()
	# No roses remain: current rose-less clients turn hostile, while every scheduled
	# client still gets to spawn and join the tantrum instead of silently disappearing.
	if not _roses_available():
		client_tantrum.start_all_clients_without_rose()
	var spawned_this_frame: bool = _process_client_spawns(delta)
	if spawned_this_frame:
		return
	# Sale completion still requires no pending spawns, no normal clients, no
	# counter-bound clients, and no hostile clients (hostiles remain in the "clients"
	# group, so client_count() also covers them; has_hostiles() is the explicit gate).
	if (
		_client_sale_pending_spawners.is_empty()
		and client_count() == 0
		and client_counter_agents.is_empty()
		and not client_tantrum.has_hostiles()
	):
		_complete_client_sale()


# Empty every counter the moment the last client of the sale has left the map. Previously
# this waited for nightfall; clearing it here means the roses vanish as soon as the sale is
# over, even if the day lingers (watering still pending, seed merchant on the map). The
# nightfall call in _on_game_mode_changed remains as an idempotent fallback for days that
# never run a client sale at all.
func _dissolve_counter_piles_after_clients() -> void:
	_manager.get_counter_stock_manager().dissolve_all_piles()


func _process_client_spawns(delta: float, allowed_spawners: Dictionary = {}, restrict_to_allowed: bool = false) -> bool:
	for raw_cell: Variant in _client_sale_spawn_timers.keys():
		var cell: Vector2i = raw_cell as Vector2i
		if restrict_to_allowed and not allowed_spawners.has(cell):
			continue
		var time_left: float = maxf(0.0, float(_client_sale_spawn_timers[cell]) - delta)
		_client_sale_spawn_timers[cell] = time_left
	var client_frequency_by_cell: Dictionary = _manager.client_frequency_by_cell()
	for index: int in range(_client_sale_pending_spawners.size() - 1, -1, -1):
		var spawner_cell: Vector2i = _client_sale_pending_spawners[index]
		if restrict_to_allowed and not allowed_spawners.has(spawner_cell):
			continue
		if float(_client_sale_spawn_timers.get(spawner_cell, 0.0)) > 0.0:
			continue
		if _manager.spawn_client_from_spawner(spawner_cell):
			_client_sale_pending_spawners.remove_at(index)
			_client_sale_spawn_timers[spawner_cell] = maxf(0.0, float(client_frequency_by_cell.get(spawner_cell, 1.0)))
			return true
		_client_sale_spawn_timers[spawner_cell] = SpawnPlaylistController.RETRY_DELAY_SECONDS
	return false


func _finish_client_phase_if_empty() -> void:
	if not GameState.is_client_phase:
		return
	var client_tantrum: ClientTantrumController = _manager.get_client_tantrum_controller()
	var client_counter_agents: Dictionary = _manager.client_counter_agents()
	if (
		_client_sale_pending_spawners.is_empty()
		and client_count() == 0
		and client_counter_agents.is_empty()
		and not client_tantrum.is_active()
		and not client_tantrum.has_hostiles()
	):
		_complete_client_sale()


func _complete_client_sale() -> void:
	_client_sale_active = false
	mark_client_step_finished()
	GameState.set_client_phase(false)
	_dissolve_counter_piles_after_clients()
	# On the final client day the last client leaving wins the run outright,
	# before the roses-watered night gate below (there is no next night).
	if _manager.try_finish_final_day():
		return
	_rot_unsold_roses_after_clients()
	GameState.start_afternoon()
	if _manager.can_start_night_after_clients():
		_manager.request_night_after_clients()
		return


func client_count() -> int:
	return _manager.get_tree().get_nodes_in_group("clients").size()


func remaining_client_count_for_today() -> int:
	if clients_finished_for_day():
		return 0
	var remaining_count: int = _client_sale_pending_spawners.size() + client_count()
	if remaining_count > 0:
		return remaining_count
	return completed_night_client_count_for_day()


func planned_client_count_for_current_step() -> int:
	var anchored_night_index: int = _manager.planificator_anchor_night_index()
	if anchored_night_index >= 0:
		return _client_count_for_completed_night_index(anchored_night_index)
	return completed_night_client_count_for_day()


func _roses_available() -> bool:
	return _manager.total_counter_stock() > 0 or _manager.grownup_rose_count() > 0


func has_roses_available() -> bool:
	return _roses_available()


func _rot_unsold_roses_after_clients() -> void:
	var plant_manager: Node = _manager.get_plant_manager()
	if plant_manager != null and plant_manager.has_method("rot_unsold_roses_once_after_clients_finished"):
		plant_manager.call("rot_unsold_roses_once_after_clients_finished")


# Clients shown and spawned during day D belong to the night completed immediately
# before that day: completed_night_index = day_number - 2. Days with no completed night
# (day 1, and any day past the final authored night) have no authored clients. The index
# is never clamped to the final night, so the trailing client day cannot reuse it.
func completed_night_client_count_for_day() -> int:
	return _client_count_for_completed_night_index(_manager.current_day_number() - 2)


func _client_count_for_completed_night_index(completed_night_index: int) -> int:
	var playlist_config: SpawnPlaylistConfigService = _manager.get_spawn_playlist_config()
	var playlist: LevelSpawnPlaylist = playlist_config.level_spawn_playlist()
	if playlist == null or playlist.nights.is_empty():
		return LEGACY_FALLBACK_CLIENT_COUNT
	if completed_night_index < 0 or completed_night_index >= playlist.nights.size():
		return 0
	var night: NightSpawnPlaylist = playlist.nights[completed_night_index]
	if night == null:
		return 0
	return maxi(0, night.clients)


func clients_finished_for_day() -> bool:
	var client_tantrum: ClientTantrumController = _manager.get_client_tantrum_controller()
	var client_counter_agents: Dictionary = _manager.client_counter_agents()
	return (
		not _client_sale_active
		and not client_tantrum.is_active()
		and not GameState.is_client_phase
		and _client_sale_pending_spawners.is_empty()
		and client_count() == 0
		and client_counter_agents.is_empty()
		and not client_tantrum.has_hostiles()
	)


func all_planted_roses_are_wet() -> bool:
	var plant_manager: Node = _manager.get_plant_manager()
	if plant_manager == null or not plant_manager.has_method("rose_count") or not plant_manager.has_method("unwatered_rose_count"):
		return false
	var planted: int = int(plant_manager.call("rose_count"))
	if planted <= 0:
		# Nothing planted (all harvested/sold, or lost to a tantrum): the watering gate is
		# vacuously satisfied, so the night can still be started once the clients are done.
		return true
	var unwatered: int = int(plant_manager.call("unwatered_rose_count"))
	return unwatered <= 0
