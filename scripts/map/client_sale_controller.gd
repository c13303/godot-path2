extends RefCounted
class_name ClientSaleController

# Owns the daytime client-sale phase: spawning the night's clients from client
# spawners under per-cell frequency timers, running the per-frame sale loop, and
# deciding when the sale is finished (so the day can advance to night). Mirrors the
# other manager-owned controllers (SeedMerchantController, etc.): it holds a typed
# back-reference to BuildingManager and delegates the spawn primitive, spawner
# registry, counter stock and cross-controller checks through narrow manager APIs.
# It owns only the sale-local state; the night-preparation coupling
# (_client_preparing and the phase gates) stays in the manager.

const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)

var _manager: BuildingManager

var _client_sale_active: bool = false
var _client_sale_pending_spawners: Array[Vector2i] = []
var _client_sale_spawn_timers: Dictionary = {}  # Vector2i -> float


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


func serialize_state() -> Dictionary:
	var pending_spawners: Array[Dictionary] = []
	for spawner_cell: Vector2i in _client_sale_pending_spawners:
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
	var client_total: int = current_night_client_count()
	var client_spawners: Dictionary = _manager.client_spawners()
	if client_total <= 0 or client_spawners.is_empty() or not _manager.has_client_targets_remaining():
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
	# No rose targets remain: cancel any pending future client spawns. Existing clients
	# are NOT globally converted — rose-holders keep escaping, rose-less clients keep
	# their current navigation, and only an individual empty-counter arrival can trigger
	# its own tantrum. Do not return early merely because a hostile exists.
	if not _manager.has_client_targets_remaining():
		_client_sale_pending_spawners.clear()
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
	GameState.set_client_phase(false)
	_dissolve_counter_piles_after_clients()
	# On the final client day the last client leaving wins the run outright,
	# before the roses-watered night gate below (there is no next night).
	if _manager.try_finish_final_day():
		return
	if _manager.can_start_night_after_clients():
		_manager.request_night_after_clients()
		return
	if not GameState.is_seed_merchant_phase:
		GameState.set_building_phase(true)


func client_count() -> int:
	return _manager.get_tree().get_nodes_in_group("clients").size()


func current_night_client_count() -> int:
	var playlist_config: SpawnPlaylistConfigService = _manager.get_spawn_playlist_config()
	var playlist: LevelSpawnPlaylist = playlist_config.level_spawn_playlist()
	if playlist == null or playlist.nights.is_empty():
		return 20
	var night_index: int = playlist_config.current_playlist_night_index()
	if night_index < 0 or night_index >= playlist.nights.size():
		night_index = _manager.get_playlist_night_index_from_progression()
	night_index = clampi(night_index, 0, playlist.nights.size() - 1)
	var night: NightSpawnPlaylist = playlist.nights[night_index]
	if night == null:
		return 20
	return maxi(0, night.clients)


func _has_clients_without_rose() -> bool:
	for raw_node: Node in _manager.get_tree().get_nodes_in_group("clients"):
		var client: Node2D = raw_node as Node2D
		if client != null and is_instance_valid(client) and not bool(client.get_meta("client_has_rose", false)):
			return true
	return false


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
