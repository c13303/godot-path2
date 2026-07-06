Task: reduce scripts/map/building_manager.gd by extracting level spawn playlist setup/validation into a dedicated RefCounted service.

Context:
BuildingManager is still too large. Previous extraction passes have been tested. The next extraction should move level spawn playlist loading and validation out of BuildingManager while preserving behavior exactly.

Create:

scripts/map/spawn_playlist_config_service.gd

with:

extends RefCounted
class_name SpawnPlaylistConfigService

Goal:
Move spawn playlist configuration, spawner-binding validation, playlist enable/invalid state, and valid-monster-type lookup out of BuildingManager.

Extract these responsibilities from BuildingManager:

- loading the level spawn config from the current scene
- storing the loaded playlist
- storing level spawner bindings
- storing loaded level scene path
- storing monster drop seed chance percent
- validating spawner bindings after spawner scan
- configuring SpawnPlaylistController
- maintaining playlist enabled/invalid/validation-attempted flags
- maintaining spawner_bindings_by_id
- valid monster type dictionary construction
- resolving current playlist night index from progression, if it is only used for playlist setup

Likely methods to extract:

- _load_level_spawn_config
- _validate_playlist_after_spawner_scan
- _valid_monster_types
- _get_playlist_night_index_from_progression

Also move these state vars if they are only used by this playlist setup/validation responsibility:

- _level_spawn_playlist
- _level_spawner_bindings
- _loaded_level_scene_path
- _monster_drop_seed_chance_percent
- _spawner_bindings_by_id
- _playlist_spawning_enabled
- _playlist_spawning_invalid
- _playlist_validation_attempted
- _current_playlist_night_index

If some of these vars are still read directly by unrelated code, either:
1. move the state and expose accessors on SpawnPlaylistConfigService, or
2. keep the state in BuildingManager and let the service operate through manager accessors.

Prefer moving the state if it keeps ownership clean without broad call-site churn.

Do not extract SpawnPlaylistController itself.
Do not change LevelSpawnPlaylist.
Do not change LevelSpawnConfigLoader.
Do not change spawn orchestration.
Do not change spawn tick processing.
Do not change spawner scanning.
Do not change monster spawning.
Do not change progression logic beyond delegating the current existing lookup.

Architecture:
Follow the existing RefCounted service/controller pattern.

The new service should keep a manager reference:

var _manager: Node

func setup(manager: Node) -> void:
	_manager = manager

Suggested public API:

func setup(manager: Node) -> void
func load_level_spawn_config() -> void
func validate_after_spawner_scan() -> void
func get_playlist_night_index_from_progression() -> int

func playlist_spawning_enabled() -> bool
func playlist_spawning_invalid() -> bool
func playlist_validation_attempted() -> bool
func current_playlist_night_index() -> int
func set_current_playlist_night_index(value: int) -> void
func monster_drop_seed_chance_percent() -> int
func spawner_bindings_by_id() -> Dictionary
func loaded_level_scene_path() -> String

Adjust names/signatures only if the existing code makes another shape cleaner. Preserve behavior over preferred API shape.

Integration:
Add to BuildingManager:

var _spawn_playlist_config: SpawnPlaylistConfigService = SpawnPlaylistConfigService.new()

In _ready(), before any call that needs loaded playlist config:

_spawn_playlist_config.setup(self)
_spawn_playlist_config.load_level_spawn_config()

Replace the extracted methods in BuildingManager with thin compatibility wrappers:

func _load_level_spawn_config() -> void:
	_spawn_playlist_config.load_level_spawn_config()

func _validate_playlist_after_spawner_scan() -> void:
	_spawn_playlist_config.validate_after_spawner_scan()

func _valid_monster_types() -> Dictionary:
	return _spawn_playlist_config.valid_monster_types()

func _get_playlist_night_index_from_progression() -> int:
	return _spawn_playlist_config.get_playlist_night_index_from_progression()

Keep wrappers because other code may still call these methods.

Then update BuildingManager call sites to use either the wrappers or the service accessors consistently.

Important:
If _playlist_spawning_enabled, _playlist_spawning_invalid, _playlist_validation_attempted, or _current_playlist_night_index are moved into the service, update all BuildingManager reads/writes to use service accessors.

For example:

if _spawn_playlist_config.playlist_spawning_enabled():
	...

_spawn_playlist_config.set_current_playlist_night_index(
	_spawn_playlist_config.get_playlist_night_index_from_progression()
)

Do not keep duplicate playlist state in both BuildingManager and SpawnPlaylistConfigService.

Dependencies:
The service may access manager-owned dependencies through _manager.

Likely dependencies:

var spawn_playlist_controller: SpawnPlaylistController = _manager.get("_spawn_playlist_controller") as SpawnPlaylistController
var spawners: Dictionary = _manager.get("_spawners") as Dictionary

For progression lookup, keep the same behavior as the existing code:

- use manager._get_progression(), or
- move only the playlist-night-index method and call _manager.call("_get_progression")

Do not change the day-number modulo behavior.

Constants:
Use the existing spawner kind constants exactly.

If needed, define local copies only if they are exclusively playlist-config-related:

const SPAWNER_KIND_MONSTER: StringName = &"monster"

Do not move unrelated spawner constants unless they are part of this service’s ownership.

Behavior preservation requirements:
- Do not change when playlist validation is attempted.
- Do not change validation failure behavior.
- Do not change validation error messages.
- Do not change duplicate binding detection.
- Do not change empty binding detection.
- Do not change null binding detection.
- Do not change empty spawner_id detection.
- Do not change duplicate spawner_id behavior.
- Do not change duplicate cell behavior.
- Do not change filtering to monster bindings only.
- Do not change valid monster type detection.
- Do not change calls to SpawnPlaylistController.configure.
- Do not change playlist enabled/invalid flags.
- Do not change fallback spawning behavior.
- Do not change debug log text.
- Do not change current night index calculation.
- Do not change monster_drop_seed_chance_percent behavior.

Search all references before editing:

- _load_level_spawn_config(
- _validate_playlist_after_spawner_scan(
- _valid_monster_types(
- _get_playlist_night_index_from_progression(
- _level_spawn_playlist
- _level_spawner_bindings
- _loaded_level_scene_path
- _monster_drop_seed_chance_percent
- _spawner_bindings_by_id
- _playlist_spawning_enabled
- _playlist_spawning_invalid
- _playlist_validation_attempted
- _current_playlist_night_index

Expected result:
- building_manager.gd loses the spawn playlist loading/validation block.
- SpawnPlaylistConfigService owns playlist config state and validation.
- BuildingManager keeps only wrappers and high-level night/client orchestration.
- SpawnPlaylistController remains unchanged.
- SpawnTickController remains unchanged.
- Existing spawning behavior remains unchanged.
- No .tscn changes required.
- No gameplay behavior changes.

Regression risks to avoid:
1. Do not accidentally validate before _scan_buildings has populated _spawners.
2. Do not accidentally reset validation-attempted every scan.
3. Do not accidentally enable playlist spawning after validation errors.
4. Do not accidentally include client or merchant bindings in monster playlist validation.
5. Do not change current night modulo behavior.
6. Do not duplicate _spawner_bindings_by_id state.
7. Do not silently swallow validation errors.
8. Do not change debug/error strings unless absolutely necessary.
9. Do not modify agent spawning.
10. Do not modify spawner scan service.
11. Do not modify spawn tick processing.
12. Do not compile or run tests; I will do it.

Non-goals:
Do not refactor LevelSpawnPlaylist.
Do not refactor LevelSpawnConfigLoader.
Do not refactor SpawnPlaylistController.
Do not refactor SpawnTickController.
Do not refactor spawner scanning.
Do not refactor night preparation.
Do not refactor spawn route creation.
Do not optimize behavior.
Do not perform unrelated cleanup.