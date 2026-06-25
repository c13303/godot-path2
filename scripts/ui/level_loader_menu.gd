extends Control

const LEVELS_DIR: String = "res://scenes/levels"
const MAIN_RUN_SCENE: String = "res://mainRun.tscn"
const AUTOSAVE_PATH: String = "user://progression_autosave.json"
const MANUAL_SAVE_PATH: String = "user://progression_save.json"

@onready var _choices: VBoxContainer = $Margin/Panel/Content/Scroll/Choices
@onready var _empty_label: Label = $Margin/Panel/Content/EmptyLabel


func _ready() -> void:
	_populate_choices()


func _populate_choices() -> void:
	var added_count: int = 0

	if FileAccess.file_exists(AUTOSAVE_PATH):
		_add_choice("Reload autosave", Callable(self, "_on_save_pressed").bind(AUTOSAVE_PATH))
		added_count += 1
	if FileAccess.file_exists(MANUAL_SAVE_PATH):
		_add_choice("Reload F9", Callable(self, "_on_save_pressed").bind(MANUAL_SAVE_PATH))
		added_count += 1

	var level_paths: Array[String] = _get_level_paths()
	for level_path: String in level_paths:
		var level_name: String = _display_name_from_path(level_path)
		_add_choice(level_name, Callable(self, "_on_level_pressed").bind(level_path))
		added_count += 1

	_empty_label.visible = added_count == 0
	if added_count > 0:
		var first_choice: Control = _choices.get_child(0) as Control
		if first_choice != null:
			first_choice.grab_focus()


func _get_level_paths() -> Array[String]:
	var result: Array[String] = []
	var dir: DirAccess = DirAccess.open(LEVELS_DIR)
	if dir == null:
		push_warning("Level menu: cannot open %s" % LEVELS_DIR)
		return result

	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".tscn"):
			result.append(LEVELS_DIR + "/" + file_name)
		file_name = dir.get_next()
	dir.list_dir_end()
	result.sort()
	return result


func _display_name_from_path(level_path: String) -> String:
	var file_name: String = level_path.get_file().get_basename()
	return file_name.replace("_", " ").capitalize()


func _add_choice(label_text: String, action: Callable) -> void:
	var button: Button = Button.new()
	button.text = label_text
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.custom_minimum_size = Vector2(0.0, 56.0)
	button.focus_mode = Control.FOCUS_ALL
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.add_theme_font_size_override("font_size", 24)
	button.pressed.connect(action)
	_choices.add_child(button)


func _on_level_pressed(level_path: String) -> void:
	GameState.set_selected_level_scene_path(level_path)
	GameState.skip_startup_autosave_once()
	GameState.set_night(false)
	_load_main_run()


func _on_save_pressed(save_path: String) -> void:
	_apply_saved_level_path(save_path)
	GameState.request_startup_save_load(save_path)
	GameState.set_night(false)
	_load_main_run()


func _apply_saved_level_path(save_path: String) -> void:
	var file: FileAccess = FileAccess.open(save_path, FileAccess.READ)
	if file == null:
		return

	var json: JSON = JSON.new()
	var parse_error: Error = json.parse(file.get_as_text())
	file.close()
	if parse_error != OK or not (json.data is Dictionary):
		GameState.clear_selected_level_scene_path()
		return

	var data: Dictionary = json.data as Dictionary
	var raw_level_path: Variant = data.get("level_scene_path", "")
	var level_path: String = str(raw_level_path)
	if level_path != "" and ResourceLoader.exists(level_path):
		GameState.set_selected_level_scene_path(level_path)
	else:
		GameState.clear_selected_level_scene_path()


func _load_main_run() -> void:
	var change_error: Error = get_tree().change_scene_to_file(MAIN_RUN_SCENE)
	if change_error != OK:
		push_error("Level menu: failed to load %s (error %d)" % [MAIN_RUN_SCENE, int(change_error)])
