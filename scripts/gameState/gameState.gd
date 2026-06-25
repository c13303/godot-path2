extends Node
## Global game state singleton (autoloaded as "GameState").
## Holds shared game data such as the current day/night mode.

## Emitted whenever the day/night mode changes. `is_night` is the new value.
signal mode_changed(is_night: bool)

## True while night is active. The game starts in day mode.
var is_night: bool = false

const SELECTED_LEVEL_META: StringName = &"selected_level_scene_path"
const STARTUP_SAVE_PATH_META: StringName = &"startup_save_path"
const SKIP_STARTUP_AUTOSAVE_META: StringName = &"skip_startup_autosave"


## Switch to night: monsters are allowed to spawn.
func start_night() -> void:
	set_night(true)


## Switch to day: monster spawning is suppressed.
func start_day() -> void:
	set_night(false)


## Toggle between day and night.
func toggle() -> void:
	# Manual toggles cannot end the night while monsters remain on the map.
	# The building manager calls start_day() separately once the group is empty.
	if is_night and get_tree().get_first_node_in_group(&"monsters") != null:
		return
	set_night(not is_night)


func set_night(value: bool) -> void:
	if is_night == value:
		return
	is_night = value
	mode_changed.emit(is_night)


func set_selected_level_scene_path(scene_path: String) -> void:
	set_meta(SELECTED_LEVEL_META, scene_path)


func clear_selected_level_scene_path() -> void:
	if has_meta(SELECTED_LEVEL_META):
		remove_meta(SELECTED_LEVEL_META)


func get_selected_level_scene_path() -> String:
	return str(get_meta(SELECTED_LEVEL_META, ""))


func request_startup_save_load(save_path: String) -> void:
	set_meta(STARTUP_SAVE_PATH_META, save_path)


func consume_startup_save_load_path(default_save_path: String) -> String:
	if has_meta(STARTUP_SAVE_PATH_META):
		var save_path: String = str(get_meta(STARTUP_SAVE_PATH_META, default_save_path))
		remove_meta(STARTUP_SAVE_PATH_META)
		return save_path
	return ""


func skip_startup_autosave_once() -> void:
	set_meta(SKIP_STARTUP_AUTOSAVE_META, true)


func consume_skip_startup_autosave() -> bool:
	if not has_meta(SKIP_STARTUP_AUTOSAVE_META):
		return false
	remove_meta(SKIP_STARTUP_AUTOSAVE_META)
	return true
