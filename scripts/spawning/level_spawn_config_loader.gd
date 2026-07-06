extends RefCounted
class_name LevelSpawnConfigLoader

# Loads a level's runtime spawn configuration (playlist, spawner bindings, scene
# path and monster seed-drop chance) from the current scene's LevelLoader node.
# Pure loader: it holds no manager state and never reaches back into the manager.
# Call load_from_scene() and copy the typed fields onto the owning manager.
# (Distinct from the authored LevelSpawnConfig resource node.)

const DEFAULT_PLAYLIST_PATH_TEMPLATE: String = "res://scenes/levels/playlists/%s_spawn_playlist.tres"

var playlist: LevelSpawnPlaylist = null
var spawner_bindings: Array[SpawnerBinding] = []
var level_scene_path: String = ""
var monster_drop_seed_chance_percent: int = 0

static func load_from_scene(scene: Node) -> LevelSpawnConfigLoader:
	var result: LevelSpawnConfigLoader = LevelSpawnConfigLoader.new()
	if scene == null:
		return result
	var loader: Node = scene.get_node_or_null("LevelLoader")
	if loader == null:
		return result
	if loader.has_method("get_loaded_level_scene_path"):
		result.level_scene_path = str(loader.call("get_loaded_level_scene_path"))
	if loader.has_method("get_loaded_spawn_playlist"):
		result.playlist = loader.call("get_loaded_spawn_playlist") as LevelSpawnPlaylist
	if loader.has_method("get_loaded_monster_drop_seed_chance_percent"):
		result.monster_drop_seed_chance_percent = clampi(int(loader.call("get_loaded_monster_drop_seed_chance_percent")), 0, 100)
	if result.playlist == null:
		result.playlist = _load_default_playlist(result.level_scene_path)
	if loader.has_method("get_loaded_spawner_bindings"):
		var raw_bindings: Array = loader.call("get_loaded_spawner_bindings") as Array
		for raw_binding: Variant in raw_bindings:
			var binding: SpawnerBinding = raw_binding as SpawnerBinding
			if binding != null:
				result.spawner_bindings.append(binding)
	return result

static func _load_default_playlist(level_scene_path: String) -> LevelSpawnPlaylist:
	if level_scene_path == "":
		return null
	var playlist_path: String = DEFAULT_PLAYLIST_PATH_TEMPLATE % level_scene_path.get_file().get_basename()
	if not ResourceLoader.exists(playlist_path):
		return null
	var resource: Resource = load(playlist_path)
	return resource as LevelSpawnPlaylist
