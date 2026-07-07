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


func has_pending_spawners() -> bool:
	return not _client_sale_pending_spawners.is_empty()


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
	if GameState.is_night or not _client_sale_active:
		return
	var client_tantrum: ClientTantrumController = _manager.get_client_tantrum_controller()
	var client_counter_agents: Dictionary = _manager.client_counter_agents()
	if client_tantrum.is_active():
		if client_count() == 0 and not client_tantrum.has_hostiles():
			# Clear the tantrum flag/group first: can_start_night_after_clients()
			# gates on clients_finished_for_day(), which requires the tantrum to be
			# over. Leaving it active here deadlocks the day — night never starts.
			client_tantrum.end()
			_client_sale_active = false
			GameState.set_client_phase(false)
			_dissolve_counter_piles_after_clients()
			# On the final client day the last client leaving wins the run outright,
			# before the roses-watered night gate below (there is no next night).
			if _manager.try_finish_final_day():
				return
			if _manager.can_start_night_after_clients():
				GameState.start_night()
				return
			if not GameState.is_seed_merchant_phase:
				GameState.set_building_phase(true)
		return
	if not _manager.has_client_targets_remaining():
		_client_sale_pending_spawners.clear()
		if _has_clients_without_rose():
			client_tantrum.begin()
			return
	for raw_cell: Variant in _client_sale_spawn_timers.keys():
		var cell: Vector2i = raw_cell as Vector2i
		var time_left: float = maxf(0.0, float(_client_sale_spawn_timers[cell]) - delta)
		_client_sale_spawn_timers[cell] = time_left
	var spawned_this_frame: bool = false
	var client_frequency_by_cell: Dictionary = _manager.client_frequency_by_cell()
	for index: int in range(_client_sale_pending_spawners.size() - 1, -1, -1):
		var spawner_cell: Vector2i = _client_sale_pending_spawners[index]
		if float(_client_sale_spawn_timers.get(spawner_cell, 0.0)) > 0.0:
			continue
		if _manager.spawn_client_from_spawner(spawner_cell):
			_client_sale_pending_spawners.remove_at(index)
			_client_sale_spawn_timers[spawner_cell] = maxf(0.0, float(client_frequency_by_cell.get(spawner_cell, 1.0)))
			spawned_this_frame = true
			break
		_client_sale_spawn_timers[spawner_cell] = SpawnPlaylistController.RETRY_DELAY_SECONDS
	if spawned_this_frame:
		return
	if _client_sale_pending_spawners.is_empty() and client_count() == 0 and client_counter_agents.is_empty() and not client_tantrum.has_hostiles():
		_client_sale_active = false
		GameState.set_client_phase(false)
		_dissolve_counter_piles_after_clients()
		# On the final client day the last client leaving wins the run outright,
		# before the roses-watered night gate below (there is no next night).
		if _manager.try_finish_final_day():
			return
		if _manager.can_start_night_after_clients():
			GameState.start_night()
			return
		if not GameState.is_seed_merchant_phase:
			GameState.set_building_phase(true)


# Empty every counter the moment the last client of the sale has left the map. Previously
# this waited for nightfall; clearing it here means the roses vanish as soon as the sale is
# over, even if the day lingers (watering still pending, seed merchant on the map). The
# nightfall call in _on_game_mode_changed remains as an idempotent fallback for days that
# never run a client sale at all.
func _dissolve_counter_piles_after_clients() -> void:
	_manager.get_counter_stock_manager().dissolve_all_piles()


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
		return false
	var unwatered: int = int(plant_manager.call("unwatered_rose_count"))
	return unwatered <= 0
