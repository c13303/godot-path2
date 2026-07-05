extends Control

const LEVELS_DIR: String = "res://scenes/levels"
const MAIN_RUN_SCENE: String = "res://mainRun.tscn"
const AUTOSAVE_PATH: String = "user://progression_autosave.json"
const MANUAL_SAVE_PATH: String = "user://progression_save.json"
const PAD_AXIS_DEADZONE: float = 0.45
const PAD_REPEAT_INITIAL_DELAY: float = 0.28
const PAD_REPEAT_INTERVAL: float = 0.12
const DEBUG_OPTIONS_NODE_NAME: String = "CPP"
const LEVEL_SELECTION_PROPERTY: String = "level_selection"
const LEVEL_SELECTION_UNSET: int = -1
const LEVEL_SELECTION_DISABLED: int = 0
const LEVEL_SELECTION_ENABLED: int = 1

@onready var _choices: VBoxContainer = $Margin/Panel/Content/Scroll/Choices
@onready var _empty_label: Label = $Margin/Panel/Content/EmptyLabel
@onready var _scroll: ScrollContainer = $Margin/Panel/Content/Scroll

var _choice_buttons: Array[Button] = []
var _selected_index: int = -1
var _active_pad_device: int = -1
var _pad_nav_direction: int = 0
var _pad_nav_repeat_time: float = 0.0

func _ready() -> void:
	if not GameState.consume_force_level_selection() and not _is_level_selection_enabled():
		_auto_load_default_level()
		return
	_scroll.follow_focus = true
	_populate_choices()
	set_process(true)


func _process(delta: float) -> void:
	_update_pad_hold_navigation(delta)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventJoypadButton:
		var button_event: InputEventJoypadButton = event as InputEventJoypadButton
		_active_pad_device = button_event.device
		if not button_event.pressed:
			return
		match button_event.button_index:
			JOY_BUTTON_DPAD_UP:
				_step_selection(-1)
				get_viewport().set_input_as_handled()
			JOY_BUTTON_DPAD_DOWN:
				_step_selection(1)
				get_viewport().set_input_as_handled()
			JOY_BUTTON_A:
				_activate_selection()
				get_viewport().set_input_as_handled()
		return

	if event is InputEventJoypadMotion:
		var motion_event: InputEventJoypadMotion = event as InputEventJoypadMotion
		_active_pad_device = motion_event.device


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
		_select_index(0)


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
	_choice_buttons.append(button)


func _select_index(index: int) -> void:
	if _choice_buttons.is_empty():
		_selected_index = -1
		return
	_selected_index = clampi(index, 0, _choice_buttons.size() - 1)
	_choice_buttons[_selected_index].grab_focus()


func _step_selection(direction: int) -> void:
	if direction == 0 or _choice_buttons.is_empty():
		return
	var next_index: int = _selected_index
	if next_index < 0:
		next_index = 0 if direction > 0 else _choice_buttons.size() - 1
	else:
		next_index = (next_index + direction) % _choice_buttons.size()
		if next_index < 0:
			next_index += _choice_buttons.size()
	_select_index(next_index)


func _activate_selection() -> void:
	if _selected_index < 0 or _selected_index >= _choice_buttons.size():
		return
	_choice_buttons[_selected_index].pressed.emit()


func _update_pad_hold_navigation(delta: float) -> void:
	if _active_pad_device < 0:
		_reset_pad_hold_navigation()
		return
	var axis_value: float = Input.get_joy_axis(_active_pad_device, JOY_AXIS_LEFT_Y)
	var direction: int = 0
	if axis_value <= -PAD_AXIS_DEADZONE or Input.is_joy_button_pressed(_active_pad_device, JOY_BUTTON_DPAD_UP):
		direction = -1
	elif axis_value >= PAD_AXIS_DEADZONE or Input.is_joy_button_pressed(_active_pad_device, JOY_BUTTON_DPAD_DOWN):
		direction = 1
	if direction == 0:
		_reset_pad_hold_navigation()
		return
	if direction != _pad_nav_direction:
		_pad_nav_direction = direction
		_pad_nav_repeat_time = PAD_REPEAT_INITIAL_DELAY
		return
	_pad_nav_repeat_time -= delta
	while _pad_nav_repeat_time <= 0.0:
		_step_selection(direction)
		_pad_nav_repeat_time += PAD_REPEAT_INTERVAL


func _reset_pad_hold_navigation() -> void:
	_pad_nav_direction = 0
	_pad_nav_repeat_time = 0.0


func _is_level_selection_enabled() -> bool:
	var override_value: int = _read_level_selection_from_scene(MAIN_RUN_SCENE)
	return override_value == LEVEL_SELECTION_ENABLED


func _read_level_selection_from_scene(scene_path: String) -> int:
	var file: FileAccess = FileAccess.open(scene_path, FileAccess.READ)
	if file == null:
		push_warning("Level menu: cannot inspect debug options in %s" % scene_path)
		return LEVEL_SELECTION_UNSET

	var in_debug_options_node: bool = false
	while not file.eof_reached():
		var line: String = file.get_line().strip_edges()
		if line.begins_with("[node "):
			in_debug_options_node = line.contains("name=\"%s\"" % DEBUG_OPTIONS_NODE_NAME)
			continue
		if in_debug_options_node and line.begins_with("%s = " % LEVEL_SELECTION_PROPERTY):
			var raw_value: String = line.get_slice("=", 1).strip_edges()
			file.close()
			return LEVEL_SELECTION_ENABLED if raw_value == "true" else LEVEL_SELECTION_DISABLED

	file.close()
	return LEVEL_SELECTION_UNSET


func _auto_load_default_level() -> void:
	GameState.clear_selected_level_scene_path()
	GameState.skip_startup_autosave_once()
	GameState.set_night(false)
	_load_main_run()


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
	# Defer so the scene swap doesn't run while the tree is still busy adding
	# this menu's children (e.g. when called from _ready()).
	_change_to_main_run.call_deferred()


func _change_to_main_run() -> void:
	var change_error: Error = get_tree().change_scene_to_file(MAIN_RUN_SCENE)
	if change_error != OK:
		push_error("Level menu: failed to load %s (error %d)" % [MAIN_RUN_SCENE, int(change_error)])
