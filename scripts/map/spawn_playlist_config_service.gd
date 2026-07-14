extends RefCounted
class_name SpawnPlaylistConfigService

# Owns level spawn-playlist configuration and spawner-binding validation:
# loading the level spawn config, storing the playlist / bindings / scene path /
# seed-drop chance, validating spawner bindings after the spawner scan, configuring
# SpawnPlaylistController, and maintaining the playlist enabled/invalid/validated
# flags plus the current playlist night index. Extracted from BuildingManager so
# the manager keeps only high-level night/client orchestration.
#
# Does NOT own SpawnPlaylistController, LevelSpawnPlaylist, LevelSpawnConfigLoader,
# spawn orchestration, spawn ticking, spawner scanning, or monster spawning.

const SPAWNER_KIND_MONSTER: StringName = &"monster"

var _manager: BuildingManager

var _level_spawn_playlist: LevelSpawnPlaylist
var _level_spawner_bindings: Array[SpawnerBinding] = []
var _level_spawner_bindings_by_id: Dictionary = {}  # StringName -> SpawnerBinding
var _named_spot_cells: Dictionary = {}  # StringName -> Vector2i
var _loaded_level_scene_path: String = ""
var _monster_drop_seed_chance_percent: int = 0
var _spawner_bindings_by_id: Dictionary = {}  # StringName -> Vector2i
var _playlist_spawning_enabled: bool = false
var _playlist_spawning_invalid: bool = false
var _playlist_validation_attempted: bool = false
var _current_playlist_night_index: int = -1


func setup(manager: BuildingManager) -> void:
	_manager = manager


func load_level_spawn_config() -> void:
	var config: LevelSpawnConfigLoader = LevelSpawnConfigLoader.load_from_scene(_manager.get_tree().current_scene)
	_level_spawn_playlist = config.playlist
	_level_spawner_bindings = config.spawner_bindings
	_named_spot_cells = config.named_spot_cells.duplicate()
	_loaded_level_scene_path = config.level_scene_path
	_monster_drop_seed_chance_percent = config.monster_drop_seed_chance_percent
	_level_spawner_bindings_by_id.clear()
	for binding: SpawnerBinding in _level_spawner_bindings:
		if binding != null and binding.spawner_id != &"":
			_level_spawner_bindings_by_id[binding.spawner_id] = binding


func validate_after_spawner_scan() -> void:
	if _playlist_validation_attempted:
		return
	_playlist_validation_attempted = true
	_playlist_spawning_enabled = false
	_playlist_spawning_invalid = false
	_spawner_bindings_by_id.clear()
	if _level_spawn_playlist == null:
		_playlist_spawning_invalid = true
		push_error("BuildingManager: no spawn playlist found for '%s'; spawning disabled." % _loaded_level_scene_path)
		return
	if _level_spawner_bindings.is_empty():
		_playlist_spawning_invalid = true
		push_error("BuildingManager: spawn playlist exists for '%s' but the level has no spawner node bindings; spawning disabled." % _loaded_level_scene_path)
		return
	var binding_cells: Dictionary = {}
	var bindings_valid: bool = true
	for binding: SpawnerBinding in _level_spawner_bindings:
		if binding == null:
			push_error("BuildingManager: null spawner binding in level spawn config.")
			bindings_valid = false
			continue
		if binding.kind != SPAWNER_KIND_MONSTER:
			continue
		if binding.spawner_id == &"":
			push_error("BuildingManager: spawner binding has empty spawner_id for cell %s." % str(binding.cell))
			bindings_valid = false
			continue
		if _spawner_bindings_by_id.has(binding.spawner_id):
			push_error("BuildingManager: duplicate spawner binding ID '%s'." % String(binding.spawner_id))
			bindings_valid = false
			continue
		if binding_cells.has(binding.cell):
			push_error("BuildingManager: duplicate spawner binding cell %s." % str(binding.cell))
			bindings_valid = false
			continue
		_spawner_bindings_by_id[binding.spawner_id] = binding.cell
		binding_cells[binding.cell] = true
	if not bindings_valid:
		_playlist_spawning_invalid = true
		push_error("BuildingManager: invalid spawner bindings; playlist spawning disabled for safety.")
		return
	var valid_monster_types_dict: Dictionary = valid_monster_types()
	var controller: SpawnPlaylistController = _spawn_playlist_controller()
	var valid: bool = controller.configure(
		_level_spawn_playlist,
		_spawner_bindings_by_id,
		_spawners(),
		valid_monster_types_dict
	)
	if not valid:
		for raw_error: Variant in controller.get_last_errors():
			push_error("BuildingManager: " + str(raw_error))
		_playlist_spawning_invalid = true
		push_error("BuildingManager: invalid level spawn playlist; playlist spawning disabled for safety.")
		return
	_playlist_spawning_enabled = true
	CppDebugOptions.dlog("BuildingManager: spawn playlist enabled for '%s' with %d night(s) and %d spawner binding(s)." % [
		_loaded_level_scene_path,
		controller.get_total_night_count(),
		_spawner_bindings_by_id.size(),
	])
	if _manager.debug_logs:
		_debug_telemetry().log("Configured spawn playlist nights=%d bindings=%d" % [
			controller.get_total_night_count(),
			_spawner_bindings_by_id.size(),
		])


func valid_monster_types() -> Dictionary:
	var types: Dictionary = {}
	for monster_id: StringName in MonsterCatalog.get_ids():
		types[monster_id] = true
	return types


func get_playlist_night_index_from_progression() -> int:
	var total_nights: int = _spawn_playlist_controller().get_total_night_count()
	if total_nights <= 0:
		return 0
	var prog: Node = _manager._get_progression()
	if prog == null:
		return 0
	var day_number: int = int(prog.call("get_value", &"nDays"))
	var day_index: int = maxi(0, day_number - 1)
	# Nights no longer loop: each day maps to its own night, and any day past the last
	# authored night (the trailing client-only victory day) clamps to the final night.
	return mini(day_index, total_nights - 1)


## Authored night count from the loaded level playlist resource. Available from
## startup (unlike SpawnPlaylistController.get_total_night_count(), which is only
## populated once the playlist is configured on the first night).
func total_night_count() -> int:
	return _level_spawn_playlist.get_night_count() if _level_spawn_playlist != null else 0


func playlist_spawning_enabled() -> bool:
	return _playlist_spawning_enabled


func set_playlist_spawning_enabled(value: bool) -> void:
	_playlist_spawning_enabled = value


func playlist_spawning_invalid() -> bool:
	return _playlist_spawning_invalid


func set_playlist_spawning_invalid(value: bool) -> void:
	_playlist_spawning_invalid = value


func playlist_validation_attempted() -> bool:
	return _playlist_validation_attempted


func current_playlist_night_index() -> int:
	return _current_playlist_night_index


func set_current_playlist_night_index(value: int) -> void:
	_current_playlist_night_index = value


func monster_drop_seed_chance_percent() -> int:
	return _monster_drop_seed_chance_percent


func spawner_bindings_by_id() -> Dictionary:
	return _spawner_bindings_by_id


func loaded_level_scene_path() -> String:
	return _loaded_level_scene_path


func level_spawn_playlist() -> LevelSpawnPlaylist:
	return _level_spawn_playlist


func level_spawner_bindings() -> Array[SpawnerBinding]:
	return _level_spawner_bindings


func level_spawner_binding(spawner_id: StringName) -> SpawnerBinding:
	return _level_spawner_bindings_by_id.get(spawner_id, null) as SpawnerBinding


func named_spot_cell(spot_id: StringName) -> Vector2i:
	return _named_spot_cells.get(spot_id, Vector2i(2147483647, 2147483647)) as Vector2i


func _spawn_playlist_controller() -> SpawnPlaylistController:
	return _manager._spawn_playlist_controller


func _spawners() -> Dictionary:
	return _manager._spawners


func _debug_telemetry() -> BuildingDebugTelemetry:
	return _manager._debug_telemetry
