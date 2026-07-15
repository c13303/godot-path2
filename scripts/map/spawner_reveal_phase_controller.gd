extends RefCounted
class_name SpawnerRevealPhaseController

const REVEAL_CONTEXT_NIGHT: StringName = &"night"
const REVEAL_CONTEXT_CLIENTS: StringName = &"clients"
const TUTORIAL_KEY_DEVILS_HUNGRY: String = "tutorial.devils_hungry"
const TUTORIAL_KEY_CLIENTS_COMING: String = "tutorial.clients_coming"
const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)

var _manager: BuildingManager
var _cutscene: SpawnerRevealCutsceneController
var _night_reveal_active: bool = false
var _client_reveal_active: bool = false
var _released_keys_by_context: Dictionary = {}
# One-shot reveals. Each cutscene plays once per run: on the first night for the monsters
# and on the first client sale for the clients. The latch is consumed as soon as the reveal
# is requested, even on a night that reveals nothing (no roses, playlist spawning off), and
# is saved with the run so loading a mid-run save never replays it.
var _night_reveal_consumed: bool = false
var _client_reveal_consumed: bool = false


func setup(manager: BuildingManager, cutscene: SpawnerRevealCutsceneController) -> void:
	_manager = manager
	_cutscene = cutscene
	if not _cutscene.reveal_item.is_connected(_on_cutscene_reveal_item):
		_cutscene.reveal_item.connect(_on_cutscene_reveal_item)
	if not _cutscene.completed.is_connected(_on_cutscene_completed):
		_cutscene.completed.connect(_on_cutscene_completed)


func begin_night_reveal() -> bool:
	if _night_reveal_consumed:
		return false
	_night_reveal_consumed = true
	_clear_released_keys(REVEAL_CONTEXT_NIGHT)
	var playlist: SpawnPlaylistController = _manager.get_spawn_playlist_controller()
	var reveal_items: Array[Dictionary] = _night_reveal_items(playlist.get_initial_ready_spawn_requests())
	_night_reveal_active = not reveal_items.is_empty()
	if _cutscene.begin(REVEAL_CONTEXT_NIGHT, reveal_items, TUTORIAL_KEY_DEVILS_HUNGRY):
		return true
	_night_reveal_active = false
	return false


func begin_client_reveal() -> bool:
	if _client_reveal_consumed:
		return false
	_client_reveal_consumed = true
	_clear_released_keys(REVEAL_CONTEXT_CLIENTS)
	var client_sale: ClientSaleController = _manager.get_client_sale_controller()
	var reveal_items: Array[Dictionary] = _client_reveal_items(client_sale.get_initial_reveal_spawner_cells())
	_client_reveal_active = not reveal_items.is_empty()
	if _cutscene.begin(REVEAL_CONTEXT_CLIENTS, reveal_items, TUTORIAL_KEY_CLIENTS_COMING):
		return true
	_client_reveal_active = false
	return false


## Burns the one-shot night reveal without playing it. Called for nights that start but
## never request a reveal (no roses left, playlist spawning disabled): the first night of
## the run is still the reveal night, so a calm one spends it. Idempotent.
func consume_night_reveal() -> void:
	_night_reveal_consumed = true


func abort_night_reveal() -> void:
	if _cutscene.is_active_context(REVEAL_CONTEXT_NIGHT):
		_cutscene.abort()
	_night_reveal_active = false
	_clear_released_keys(REVEAL_CONTEXT_NIGHT)


func abort_client_reveal() -> void:
	if _cutscene.is_active_context(REVEAL_CONTEXT_CLIENTS):
		_cutscene.abort()
	_client_reveal_active = false
	_clear_released_keys(REVEAL_CONTEXT_CLIENTS)


func night_reveal_active() -> bool:
	return _night_reveal_active


func client_reveal_active() -> bool:
	return _client_reveal_active


func released_night_track_indices() -> Dictionary:
	return _released_keys(REVEAL_CONTEXT_NIGHT)


func released_client_spawner_cells() -> Dictionary:
	return _released_keys(REVEAL_CONTEXT_CLIENTS)


## Only the one-shot latches are saved; the active-reveal flags and released keys are
## deliberately left out. A cutscene is not resumable across a save, so a save taken while
## one plays reloads with the reveal already spent and the night/sale running normally.
func serialize_state() -> Dictionary:
	return {
		"night_reveal_consumed": _night_reveal_consumed,
		"client_reveal_consumed": _client_reveal_consumed,
	}


func restore_state(data: Dictionary) -> void:
	_night_reveal_consumed = bool(data.get("night_reveal_consumed", false))
	_client_reveal_consumed = bool(data.get("client_reveal_consumed", false))


func _on_cutscene_reveal_item(context: StringName, _item_index: int, item: Dictionary) -> void:
	match context:
		REVEAL_CONTEXT_NIGHT:
			if _spawn_night_reveal_item(item):
				_mark_released_key(context, int(item.get("track_index", -1)))
		REVEAL_CONTEXT_CLIENTS:
			if _spawn_client_reveal_item(item):
				_mark_released_key(context, item.get("spawner_cell", INVALID_CELL))


func _on_cutscene_completed(context: StringName, release_spawning: bool) -> void:
	if not release_spawning:
		return
	match context:
		REVEAL_CONTEXT_NIGHT:
			_night_reveal_active = false
			_clear_released_keys(REVEAL_CONTEXT_NIGHT)
			_manager.on_night_reveal_finished()
		REVEAL_CONTEXT_CLIENTS:
			_client_reveal_active = false
			_clear_released_keys(REVEAL_CONTEXT_CLIENTS)


func _night_reveal_items(requests: Array[Dictionary]) -> Array[Dictionary]:
	var items: Array[Dictionary] = []
	for request: Dictionary in requests:
		var cell: Vector2i = request.get("spawner_cell", INVALID_CELL) as Vector2i
		if cell == INVALID_CELL:
			continue
		var item: Dictionary = request.duplicate()
		item["world_position"] = _manager.cell_center(cell)
		items.append(item)
	return items


func _client_reveal_items(spawner_cells: Array[Vector2i]) -> Array[Dictionary]:
	var items: Array[Dictionary] = []
	for cell: Vector2i in spawner_cells:
		if cell == INVALID_CELL:
			continue
		items.append({
			"spawner_cell": cell,
			"world_position": _manager.cell_center(cell),
		})
	return items


func _spawn_night_reveal_item(item: Dictionary) -> bool:
	if not GameState.is_night:
		return false
	var cell: Vector2i = item.get("spawner_cell", INVALID_CELL) as Vector2i
	if cell == INVALID_CELL or not _manager.get_spawners().has(cell):
		_manager.report_playlist_spawn_result(item, false, "physical spawner cell is missing")
		return false
	var monster_type: StringName = StringName(str(item.get("monster_type", "basic")))
	var spawned: bool = _manager.spawn_monster_from_spawner(cell, monster_type)
	if spawned:
		_manager.report_playlist_spawn_result(item, true)
	else:
		_manager.report_playlist_spawn_result(item, false, _manager.last_spawn_failure())
	return spawned


func _spawn_client_reveal_item(item: Dictionary) -> bool:
	if GameState.is_night:
		return false
	var cell: Vector2i = item.get("spawner_cell", INVALID_CELL) as Vector2i
	if cell == INVALID_CELL:
		return false
	return _manager.get_client_sale_controller().spawn_revealed_client_from_spawner(cell)


func _mark_released_key(context: StringName, key: Variant) -> void:
	if key == null:
		return
	if key is int and int(key) < 0:
		return
	if key is Vector2i and (key as Vector2i) == INVALID_CELL:
		return
	var released_keys: Dictionary = _released_keys_by_context.get(context, {}) as Dictionary
	released_keys[key] = true
	_released_keys_by_context[context] = released_keys


func _released_keys(context: StringName) -> Dictionary:
	var released_keys: Dictionary = _released_keys_by_context.get(context, {}) as Dictionary
	return released_keys.duplicate()


func _clear_released_keys(context: StringName) -> void:
	_released_keys_by_context.erase(context)
