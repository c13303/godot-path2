@tool
extends VBoxContainer

const LEVELS_DIR: String = "res://scenes/levels"
const PLAYLISTS_DIR: String = "res://scenes/levels/playlists"
const LEVEL_CONFIG_SCRIPT: Script = preload("res://scripts/spawning/level_spawn_config.gd")
const WAVE_ROW_SCRIPT: Script = preload("res://addons/spawn_playlist_editor/wave_row.gd")
const SPAWNER_CONTAINER_NAMES: PackedStringArray = ["spawner", "spawners"]
const CLIENT_FREQUENCY_META: StringName = &"frequency_client"
const DEFAULT_STARTING_SEEDS: int = 20
const DEFAULT_STARTING_GEMS: int = 1000
const DEFAULT_STARTING_WEAPONS: Array[StringName] = [&"spray"]

var editor_plugin: EditorPlugin

var _level_paths: Array[String] = []
var _current_level_path: String = ""
var _level_root: Node
var _playlist: LevelSpawnPlaylist
var _spawner_ids: Array[StringName] = []
var _client_spawner_ids: Array[StringName] = []
var _spawner_nodes: Dictionary = {}  # StringName -> NodePath
var _duplicate_spawner_ids: Array[StringName] = []
var _selected_night_index: int = 0
var _dirty: bool = false
var _loading_ui: bool = false

var _level_option: OptionButton
var _create_button: Button
var _dirty_label: Label
var _playlist_label: Label
var _starting_controls: VBoxContainer
var _client_frequency_box: VBoxContainer
var _starting_seeds: SpinBox
var _starting_gems: SpinBox
var _rose_shop_counter_limit: SpinBox
var _weapon_checks_box: HBoxContainer
var _weapon_checkboxes: Dictionary = {}  # StringName -> CheckBox
var _night_option: OptionButton
var _validation_label: RichTextLabel
var _rename_row: HBoxContainer
var _missing_id_option: OptionButton
var _target_id_option: OptionButton
var _tracks_box: VBoxContainer


func _ready() -> void:
	_build_ui()
	_refresh_levels()


func _exit_tree() -> void:
	if _level_root != null:
		_level_root.free()
		_level_root = null


func mark_dirty() -> void:
	if _loading_ui:
		return
	_dirty = true
	var saved: bool = _save()
	_refresh_status()
	# On a disk write failure _save() leaves an error message in the validation
	# panel; keep it visible by only re-running validation when the save worked.
	if saved:
		_refresh_validation()


func move_wave(spawner_id: StringName, from_index: int, to_index: int) -> void:
	var track: SpawnerWaveTrack = _get_track(spawner_id)
	if track == null:
		return
	if from_index < 0 or from_index >= track.waves.size() or to_index < 0 or to_index >= track.waves.size():
		return
	if from_index == to_index:
		return
	var wave: SpawnWave = track.waves[from_index]
	track.waves.remove_at(from_index)
	track.waves.insert(to_index, wave)
	mark_dirty()
	_rebuild_tracks()


func move_spawner_track(spawner_id: StringName, to_index: int) -> void:
	var night: NightSpawnPlaylist = _get_selected_night()
	if night == null:
		return
	var from_index: int = _get_track_index(spawner_id)
	if from_index < 0 or from_index >= night.spawner_tracks.size() or to_index < 0 or to_index >= night.spawner_tracks.size():
		return
	if from_index == to_index:
		return
	var track: SpawnerWaveTrack = night.spawner_tracks[from_index]
	night.spawner_tracks.remove_at(from_index)
	night.spawner_tracks.insert(to_index, track)
	mark_dirty()
	_rebuild_tracks()


func delete_wave(spawner_id: StringName, wave_index: int) -> void:
	var track: SpawnerWaveTrack = _get_track(spawner_id)
	if track == null or wave_index < 0 or wave_index >= track.waves.size():
		return
	track.waves.remove_at(wave_index)
	mark_dirty()
	_rebuild_tracks()


func _build_ui() -> void:
	_loading_ui = true
	size_flags_vertical = SIZE_EXPAND_FILL

	var title: Label = Label.new()
	title.text = "Spawn Playlist"
	title.add_theme_font_size_override("font_size", 18)
	add_child(title)

	var level_row: HBoxContainer = HBoxContainer.new()
	add_child(level_row)

	_level_option = OptionButton.new()
	_level_option.size_flags_horizontal = SIZE_EXPAND_FILL
	_level_option.item_selected.connect(_on_level_selected)
	level_row.add_child(_level_option)

	var refresh_button: Button = Button.new()
	refresh_button.text = "Refresh"
	refresh_button.pressed.connect(_refresh_levels)
	level_row.add_child(refresh_button)

	var action_row: HBoxContainer = HBoxContainer.new()
	add_child(action_row)

	_create_button = Button.new()
	_create_button.text = "Create/Assign Playlist"
	_create_button.pressed.connect(_on_create_playlist_pressed)
	action_row.add_child(_create_button)

	var open_button: Button = Button.new()
	open_button.text = "Open Level"
	open_button.pressed.connect(_on_open_level_pressed)
	action_row.add_child(open_button)

	_dirty_label = Label.new()
	add_child(_dirty_label)

	_playlist_label = Label.new()
	_playlist_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_playlist_label)

	_starting_controls = VBoxContainer.new()
	add_child(_starting_controls)
	_build_starting_controls()

	_client_frequency_box = VBoxContainer.new()
	add_child(_client_frequency_box)

	var night_row: HBoxContainer = HBoxContainer.new()
	add_child(night_row)

	_night_option = OptionButton.new()
	_night_option.size_flags_horizontal = SIZE_EXPAND_FILL
	_night_option.item_selected.connect(_on_night_selected)
	night_row.add_child(_night_option)

	var add_night_button: Button = Button.new()
	add_night_button.text = "Add Night"
	add_night_button.pressed.connect(_on_add_night_pressed)
	night_row.add_child(add_night_button)

	var duplicate_night_button: Button = Button.new()
	duplicate_night_button.text = "Duplicate Night"
	duplicate_night_button.pressed.connect(_on_duplicate_night_pressed)
	night_row.add_child(duplicate_night_button)

	var delete_night_button: Button = Button.new()
	delete_night_button.text = "Delete Night"
	delete_night_button.pressed.connect(_on_delete_night_pressed)
	night_row.add_child(delete_night_button)

	_validation_label = RichTextLabel.new()
	_validation_label.custom_minimum_size = Vector2(0.0, 95.0)
	_validation_label.fit_content = false
	_validation_label.scroll_active = true
	add_child(_validation_label)

	_rename_row = HBoxContainer.new()
	add_child(_rename_row)

	var rename_label: Label = Label.new()
	rename_label.text = "Rename missing ID"
	_rename_row.add_child(rename_label)

	_missing_id_option = OptionButton.new()
	_missing_id_option.custom_minimum_size = Vector2(110.0, 0.0)
	_rename_row.add_child(_missing_id_option)

	var to_label: Label = Label.new()
	to_label.text = "to"
	_rename_row.add_child(to_label)

	_target_id_option = OptionButton.new()
	_target_id_option.custom_minimum_size = Vector2(110.0, 0.0)
	_rename_row.add_child(_target_id_option)

	var rename_button: Button = Button.new()
	rename_button.text = "Apply"
	rename_button.pressed.connect(_on_rename_missing_id_pressed)
	_rename_row.add_child(rename_button)
	_rename_row.visible = false

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = SIZE_EXPAND_FILL
	add_child(scroll)

	_tracks_box = VBoxContainer.new()
	_tracks_box.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.add_child(_tracks_box)

	_loading_ui = false
	_refresh_status()


func _build_starting_controls() -> void:
	var heading: Label = Label.new()
	heading.text = "Starting Level"
	heading.add_theme_font_size_override("font_size", 15)
	_starting_controls.add_child(heading)

	var currency_row: HBoxContainer = HBoxContainer.new()
	_starting_controls.add_child(currency_row)

	var seeds_label: Label = Label.new()
	seeds_label.text = "Seeds"
	currency_row.add_child(seeds_label)

	_starting_seeds = SpinBox.new()
	_starting_seeds.min_value = 0.0
	_starting_seeds.max_value = 1000000.0
	_starting_seeds.step = 1.0
	_starting_seeds.custom_minimum_size = Vector2(86.0, 0.0)
	_starting_seeds.value_changed.connect(_on_starting_seeds_changed)
	currency_row.add_child(_starting_seeds)

	var gems_label: Label = Label.new()
	gems_label.text = "Gems"
	currency_row.add_child(gems_label)

	_starting_gems = SpinBox.new()
	_starting_gems.min_value = 0.0
	_starting_gems.max_value = 1000000.0
	_starting_gems.step = 1.0
	_starting_gems.custom_minimum_size = Vector2(86.0, 0.0)
	_starting_gems.value_changed.connect(_on_starting_gems_changed)
	currency_row.add_child(_starting_gems)

	var counter_limit_row: HBoxContainer = HBoxContainer.new()
	_starting_controls.add_child(counter_limit_row)

	var counter_limit_label: Label = Label.new()
	counter_limit_label.text = "Rose shop counters"
	counter_limit_row.add_child(counter_limit_label)

	_rose_shop_counter_limit = SpinBox.new()
	_rose_shop_counter_limit.min_value = 0.0
	_rose_shop_counter_limit.max_value = 999.0
	_rose_shop_counter_limit.step = 1.0
	_rose_shop_counter_limit.custom_minimum_size = Vector2(86.0, 0.0)
	_rose_shop_counter_limit.value_changed.connect(_on_rose_shop_counter_limit_changed)
	counter_limit_row.add_child(_rose_shop_counter_limit)

	var weapons_label: Label = Label.new()
	weapons_label.text = "Starting weapons"
	_starting_controls.add_child(weapons_label)

	_weapon_checks_box = HBoxContainer.new()
	_starting_controls.add_child(_weapon_checks_box)
	_weapon_checkboxes.clear()
	for weapon_id: StringName in ItemCatalog.get_weapon_ids():
		var checkbox: CheckBox = CheckBox.new()
		checkbox.text = _item_display_name(weapon_id)
		checkbox.tooltip_text = String(weapon_id)
		checkbox.toggled.connect(_on_starting_weapon_toggled.bind(weapon_id))
		_weapon_checks_box.add_child(checkbox)
		_weapon_checkboxes[weapon_id] = checkbox


func _refresh_levels() -> void:
	var previous_path: String = _current_level_path
	_level_paths.clear()
	_find_level_scenes(LEVELS_DIR)
	_level_paths.sort()
	_level_option.clear()
	for path: String in _level_paths:
		_level_option.add_item(path.get_file().get_basename())
		_level_option.set_item_metadata(_level_option.get_item_count() - 1, path)
	var selected_index: int = _level_paths.find(previous_path)
	if selected_index < 0 and not _level_paths.is_empty():
		selected_index = 0
	if selected_index >= 0:
		_level_option.select(selected_index)
		_load_level(_level_paths[selected_index])
	else:
		_load_level("")


func _find_level_scenes(dir_path: String) -> void:
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	while true:
		var file_name: String = dir.get_next()
		if file_name == "":
			break
		if file_name.begins_with("."):
			continue
		var path: String = dir_path.path_join(file_name)
		if dir.current_is_dir():
			if file_name != "playlists":
				_find_level_scenes(path)
		elif file_name.begins_with("level_") and file_name.ends_with(".tscn"):
			_level_paths.append(path)
	dir.list_dir_end()


func _load_level(level_path: String) -> void:
	_current_level_path = level_path
	_dirty = false
	_selected_night_index = 0
	_playlist = null
	_spawner_ids.clear()
	_client_spawner_ids.clear()
	_spawner_nodes.clear()
	_duplicate_spawner_ids.clear()
	if _level_root != null:
		_level_root.free()
		_level_root = null
	if level_path == "":
		_refresh_all()
		return
	var packed: PackedScene = load(level_path) as PackedScene
	if packed == null:
		_refresh_all()
		return
	_level_root = packed.instantiate()
	_capture_spawners()
	var config: LevelSpawnConfig = _get_level_config(_level_root)
	if config != null:
		_playlist = config.spawn_playlist
	_refresh_all()


func _capture_spawners() -> void:
	var container: Node = _find_spawner_container(_level_root)
	if container == null:
		return
	var seen: Dictionary = {}
	for child: Node in container.get_children():
		var node_2d: Node2D = child as Node2D
		if node_2d == null:
			continue
		var spawner_id: StringName = StringName(node_2d.name)
		if spawner_id == &"":
			continue
		var spawner_name: String = String(spawner_id)
		if not spawner_name.begins_with("monster") and not spawner_name.begins_with("client"):
			continue
		if seen.has(spawner_id):
			_duplicate_spawner_ids.append(spawner_id)
			continue
		seen[spawner_id] = true
		if spawner_name.begins_with("client"):
			_client_spawner_ids.append(spawner_id)
		else:
			_spawner_ids.append(spawner_id)
		_spawner_nodes[spawner_id] = node_2d.get_path()
	_spawner_ids.sort()
	_client_spawner_ids.sort()


func _refresh_all() -> void:
	_loading_ui = true
	_refresh_starting_controls()
	_refresh_client_frequency_controls()
	_refresh_nights()
	_rebuild_tracks()
	_loading_ui = false
	_refresh_status()
	_refresh_validation()


func _refresh_status() -> void:
	_dirty_label.text = "Unsaved changes" if _dirty else "Saved"
	_dirty_label.modulate = Color(1.0, 0.72, 0.2) if _dirty else Color(0.65, 0.9, 0.65)
	var playlist_path: String = _playlist.resource_path if _playlist != null else "<none>"
	_playlist_label.text = "Level: %s\nPlaylist: %s" % [_current_level_path, playlist_path]
	_create_button.disabled = _current_level_path == ""


func _refresh_starting_controls() -> void:
	var config: LevelSpawnConfig = _get_level_config(_level_root)
	var has_level: bool = _current_level_path != ""
	_starting_controls.visible = has_level
	_starting_seeds.editable = has_level
	_starting_gems.editable = has_level
	_rose_shop_counter_limit.editable = has_level
	var seeds: int = DEFAULT_STARTING_SEEDS
	var gems: int = DEFAULT_STARTING_GEMS
	var counter_limit: int = 2
	var weapons: Array[StringName] = _default_starting_weapons()
	if config != null:
		seeds = config.starting_seeds
		gems = config.starting_gems
		counter_limit = config.rose_shop_counter_limit
		weapons = _valid_weapon_ids(config.starting_weapons)
	_starting_seeds.value = float(seeds)
	_starting_gems.value = float(gems)
	_rose_shop_counter_limit.value = float(counter_limit)
	for raw_weapon_id: Variant in _weapon_checkboxes.keys():
		var weapon_id: StringName = raw_weapon_id as StringName
		var checkbox: CheckBox = _weapon_checkboxes[weapon_id] as CheckBox
		if checkbox != null:
			checkbox.button_pressed = weapons.has(weapon_id)
			checkbox.disabled = not has_level


func _refresh_client_frequency_controls() -> void:
	for child: Node in _client_frequency_box.get_children():
		child.queue_free()
	var has_level: bool = _current_level_path != ""
	_client_frequency_box.visible = has_level and not _client_spawner_ids.is_empty()
	if not _client_frequency_box.visible:
		return
	var heading: Label = Label.new()
	heading.text = "Client Spawners"
	heading.add_theme_font_size_override("font_size", 15)
	_client_frequency_box.add_child(heading)
	for spawner_id: StringName in _client_spawner_ids:
		var row: HBoxContainer = HBoxContainer.new()
		_client_frequency_box.add_child(row)
		var label: Label = Label.new()
		label.text = "%s frequency" % String(spawner_id)
		label.custom_minimum_size = Vector2(140.0, 0.0)
		row.add_child(label)
		var spin: SpinBox = SpinBox.new()
		spin.min_value = 0.0
		spin.max_value = 3600.0
		spin.step = 0.1
		spin.suffix = "s"
		spin.custom_minimum_size = Vector2(86.0, 0.0)
		var node: Node = _node_for_spawner_id(spawner_id)
		spin.value = float(node.get_meta(CLIENT_FREQUENCY_META, 1.0)) if node != null else 1.0
		spin.value_changed.connect(_on_client_frequency_changed.bind(spawner_id))
		row.add_child(spin)


func _refresh_nights() -> void:
	_night_option.clear()
	if _playlist == null:
		return
	if _playlist.nights.is_empty():
		_playlist.nights.append(NightSpawnPlaylist.new())
	var night_count: int = _playlist.nights.size()
	_selected_night_index = clampi(_selected_night_index, 0, night_count - 1)
	for night_index: int in range(night_count):
		_night_option.add_item("Night %d" % (night_index + 1))
	_night_option.select(_selected_night_index)


func _rebuild_tracks() -> void:
	for child: Node in _tracks_box.get_children():
		child.queue_free()
	if _playlist == null:
		var empty_label: Label = Label.new()
		empty_label.text = "No playlist assigned. Use Create/Assign Playlist."
		_tracks_box.add_child(empty_label)
		return
	if _spawner_ids.is_empty():
		var no_spawners_label: Label = Label.new()
		no_spawners_label.text = "No spawner nodes found. Add children under a level node named spawner or spawners."
		no_spawners_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_tracks_box.add_child(no_spawners_label)
		return
	var night: NightSpawnPlaylist = _get_selected_night()
	if night == null:
		return
	var event_names: Array[StringName] = _collect_event_names(night)
	var rendered_spawner_ids: Dictionary = {}
	for track: SpawnerWaveTrack in night.spawner_tracks:
		if track == null or track.spawner_id == &"" or not _spawner_ids.has(track.spawner_id) or rendered_spawner_ids.has(track.spawner_id):
			continue
		rendered_spawner_ids[track.spawner_id] = true
		_tracks_box.add_child(_build_spawner_panel(track.spawner_id, event_names))
	for spawner_id: StringName in _spawner_ids:
		if rendered_spawner_ids.has(spawner_id):
			continue
		_tracks_box.add_child(_build_spawner_panel(spawner_id, event_names))


func _build_spawner_panel(spawner_id: StringName, event_names: Array[StringName]) -> Control:
	var panel: PanelContainer = PanelContainer.new()
	panel.size_flags_horizontal = SIZE_EXPAND_FILL
	var outer: VBoxContainer = VBoxContainer.new()
	panel.add_child(outer)

	var header: HBoxContainer = HBoxContainer.new()
	outer.add_child(header)

	var title: Label = Label.new()
	title.text = String(spawner_id)
	title.add_theme_font_size_override("font_size", 15)
	title.size_flags_horizontal = SIZE_EXPAND_FILL
	header.add_child(title)

	var focus_button: Button = Button.new()
	focus_button.text = "Focus"
	focus_button.pressed.connect(_focus_spawner.bind(spawner_id))
	header.add_child(focus_button)

	var track: SpawnerWaveTrack = _get_track(spawner_id)
	if track == null:
		var inactive: Label = Label.new()
		inactive.text = "Inactive this night"
		header.add_child(inactive)
		var enable_button: Button = Button.new()
		enable_button.text = "Enable Track"
		enable_button.pressed.connect(_enable_track.bind(spawner_id))
		header.add_child(enable_button)
		return panel

	var track_index: int = _get_track_index(spawner_id)

	var move_up_button: Button = Button.new()
	move_up_button.text = "Up"
	move_up_button.tooltip_text = "Move this spawner track above its previous neighbor."
	move_up_button.disabled = track_index <= 0
	move_up_button.pressed.connect(move_spawner_track.bind(spawner_id, track_index - 1))
	header.add_child(move_up_button)

	var move_down_button: Button = Button.new()
	move_down_button.text = "Down"
	move_down_button.tooltip_text = "Move this spawner track below its next neighbor."
	move_down_button.disabled = track_index >= _get_active_track_count() - 1
	move_down_button.pressed.connect(move_spawner_track.bind(spawner_id, track_index + 1))
	header.add_child(move_down_button)

	var add_wave_button: Button = Button.new()
	add_wave_button.text = "Add Wave"
	add_wave_button.pressed.connect(_add_wave.bind(spawner_id))
	header.add_child(add_wave_button)

	var disable_button: Button = Button.new()
	disable_button.text = "Disable Track"
	disable_button.pressed.connect(_disable_track.bind(spawner_id))
	header.add_child(disable_button)

	var labels: HBoxContainer = HBoxContainer.new()
	outer.add_child(labels)
	for raw_label_text in ["", "#", "Type", "Count", "Interval", "Wait Event", "Emit Event", ""]:
		var label_text: String = str(raw_label_text)
		var label: Label = Label.new()
		label.text = label_text
		label.custom_minimum_size = _header_width(label_text)
		labels.add_child(label)

	var wave_index: int = 0
	for wave: SpawnWave in track.waves:
		var row: HBoxContainer = WAVE_ROW_SCRIPT.new() as HBoxContainer
		row.call("setup", self, spawner_id, wave_index, track.waves.size(), wave, _monster_types(), event_names)
		outer.add_child(row)
		wave_index += 1
	if track.waves.is_empty():
		var empty: Label = Label.new()
		empty.text = "Track has no waves. It spawns nothing unless you add a wave."
		outer.add_child(empty)
	return panel


func _header_width(label_text: String) -> Vector2:
	match label_text:
		"#":
			return Vector2(24.0, 0.0)
		"Type":
			return Vector2(90.0, 0.0)
		"Count":
			return Vector2(74.0, 0.0)
		"Interval":
			return Vector2(86.0, 0.0)
		"Wait Event", "Emit Event":
			return Vector2(110.0, 0.0)
		_:
			return Vector2(76.0, 0.0)


func _refresh_validation() -> void:
	var errors: PackedStringArray = PackedStringArray()
	var warnings: PackedStringArray = PackedStringArray()
	_validate(errors, warnings)
	_refresh_rename_row()
	var text: String = ""
	if errors.is_empty() and warnings.is_empty():
		text = "[color=light_green]No validation issues.[/color]"
	else:
		for error: String in errors:
			text += "[color=salmon]Error: %s[/color]\n" % error
		for warning: String in warnings:
			text += "[color=khaki]Warning: %s[/color]\n" % warning
	_validation_label.clear()
	_validation_label.append_text(text)


func _validate(errors: PackedStringArray, warnings: PackedStringArray) -> void:
	if _current_level_path == "":
		errors.append("No level selected.")
		return
	if _level_root == null:
		errors.append("Selected level could not be loaded.")
		return
	if _find_spawner_container(_level_root) == null:
		errors.append("Level has no node named spawner or spawners.")
	if _spawner_ids.is_empty():
		errors.append("Level has no child Node2D spawners.")
	if _playlist == null:
		errors.append("Level has no spawn playlist assigned.")
		return
	if _playlist.nights.is_empty():
		errors.append("Playlist has no nights.")
	var spawner_id_set: Dictionary = {}
	for spawner_id: StringName in _spawner_ids:
		if spawner_id_set.has(spawner_id):
			errors.append("Duplicate spawner ID: %s." % String(spawner_id))
		spawner_id_set[spawner_id] = true
	for duplicate_id: StringName in _duplicate_spawner_ids:
		errors.append("Duplicate spawner ID: %s." % String(duplicate_id))
	var night_index: int = 0
	for night: NightSpawnPlaylist in _playlist.nights:
		if night == null:
			errors.append("Night %d is null." % (night_index + 1))
			night_index += 1
			continue
		_validate_night(night, night_index, spawner_id_set, errors, warnings)
		night_index += 1


func _validate_night(night: NightSpawnPlaylist, night_index: int, spawner_id_set: Dictionary, errors: PackedStringArray, _warnings: PackedStringArray) -> void:
	var track_ids: Dictionary = {}
	var emitted_events: Dictionary = {}
	for track: SpawnerWaveTrack in night.spawner_tracks:
		if track == null:
			continue
		for wave: SpawnWave in track.waves:
			if wave != null and wave.emit_event != &"":
				emitted_events[wave.emit_event] = true
	var track_index: int = 0
	for track: SpawnerWaveTrack in night.spawner_tracks:
		if track == null:
			errors.append("Night %d has a null track." % (night_index + 1))
			track_index += 1
			continue
		if track.spawner_id == &"":
			errors.append("Night %d track %d has an empty spawner ID." % [night_index + 1, track_index + 1])
		elif track_ids.has(track.spawner_id):
			errors.append("Night %d has duplicate track for %s." % [night_index + 1, String(track.spawner_id)])
		elif not spawner_id_set.has(track.spawner_id):
			errors.append("Night %d references missing spawner %s." % [night_index + 1, String(track.spawner_id)])
		track_ids[track.spawner_id] = true
		var wave_index: int = 0
		for wave: SpawnWave in track.waves:
			if wave == null:
				errors.append("Night %d %s wave %d is null." % [night_index + 1, String(track.spawner_id), wave_index + 1])
				wave_index += 1
				continue
			if not _monster_types().has(wave.monster_type):
				errors.append("Night %d %s wave %d has invalid monster type %s." % [night_index + 1, String(track.spawner_id), wave_index + 1, String(wave.monster_type)])
			if wave.monster_count < 0:
				errors.append("Night %d %s wave %d has negative monster count." % [night_index + 1, String(track.spawner_id), wave_index + 1])
			if wave.spawn_interval_seconds < 0.0:
				errors.append("Night %d %s wave %d has negative interval." % [night_index + 1, String(track.spawner_id), wave_index + 1])
			if wave.wait_for_event != &"" and not emitted_events.has(wave.wait_for_event):
				errors.append("Night %d %s wave %d waits for event never emitted this night: %s." % [night_index + 1, String(track.spawner_id), wave_index + 1, String(wave.wait_for_event)])
			if wave.wait_for_event != &"" and wave.wait_for_event == wave.emit_event:
				errors.append("Night %d %s wave %d waits for the same event it emits." % [night_index + 1, String(track.spawner_id), wave_index + 1])
			wave_index += 1
		track_index += 1


func _on_level_selected(index: int) -> void:
	if index < 0 or index >= _level_option.get_item_count():
		return
	var path: String = str(_level_option.get_item_metadata(index))
	_load_level(path)


func _on_night_selected(index: int) -> void:
	_selected_night_index = index
	_rebuild_tracks()


func _on_create_playlist_pressed() -> void:
	if _current_level_path == "":
		return
	if _playlist == null:
		_playlist = LevelSpawnPlaylist.new()
		_playlist.nights.append(NightSpawnPlaylist.new())
		var playlist_path: String = _default_playlist_path_for_level(_current_level_path)
		var dir_error: Error = DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(PLAYLISTS_DIR))
		if dir_error != OK:
			_show_save_error("Could not create playlists directory", dir_error)
			return
		var save_error: Error = ResourceSaver.save(_playlist, playlist_path)
		if save_error != OK:
			_show_save_error("Could not create playlist resource", save_error)
			return
	if not _assign_playlist_to_level_scene():
		return
	_dirty = false
	_refresh_all()


# Autosaves the current playlist and level scene. Saves even when validation
# reports errors so no edit is silently lost; the validation panel still
# surfaces any issues. Returns false if a disk write failed.
func _save() -> bool:
	if _current_level_path == "":
		return false
	if _playlist != null:
		var save_path: String = _playlist.resource_path
		if save_path == "":
			save_path = _default_playlist_path_for_level(_current_level_path)
			_playlist.take_over_path(save_path)
		var save_error: Error = ResourceSaver.save(_playlist, save_path)
		if save_error != OK:
			_show_save_error("Could not save playlist", save_error)
			return false
	if not _assign_playlist_to_level_scene():
		return false
	_dirty = false
	return true


func _on_open_level_pressed() -> void:
	if _current_level_path == "" or editor_plugin == null:
		return
	editor_plugin.get_editor_interface().open_scene_from_path(_current_level_path)


func _on_rename_missing_id_pressed() -> void:
	if _playlist == null or _missing_id_option.get_item_count() == 0 or _target_id_option.get_item_count() == 0:
		return
	var missing_id: StringName = StringName(str(_missing_id_option.get_item_metadata(_missing_id_option.selected)))
	var target_id: StringName = StringName(str(_target_id_option.get_item_metadata(_target_id_option.selected)))
	if missing_id == &"" or target_id == &"" or missing_id == target_id:
		return
	for night: NightSpawnPlaylist in _playlist.nights:
		if night == null:
			continue
		for track: SpawnerWaveTrack in night.spawner_tracks:
			if track != null and track.spawner_id == missing_id:
				track.spawner_id = target_id
	mark_dirty()
	_refresh_all()


func _on_starting_seeds_changed(value: float) -> void:
	if _loading_ui:
		return
	var config: LevelSpawnConfig = _get_or_create_loaded_level_config()
	if config == null:
		return
	config.starting_seeds = int(value)
	mark_dirty()


func _on_starting_gems_changed(value: float) -> void:
	if _loading_ui:
		return
	var config: LevelSpawnConfig = _get_or_create_loaded_level_config()
	if config == null:
		return
	config.starting_gems = int(value)
	mark_dirty()


func _on_rose_shop_counter_limit_changed(value: float) -> void:
	if _loading_ui:
		return
	var config: LevelSpawnConfig = _get_or_create_loaded_level_config()
	if config == null:
		return
	config.rose_shop_counter_limit = int(value)
	mark_dirty()


func _on_starting_weapon_toggled(enabled: bool, weapon_id: StringName) -> void:
	if _loading_ui:
		return
	var config: LevelSpawnConfig = _get_or_create_loaded_level_config()
	if config == null:
		return
	var weapons: Array[StringName] = _valid_weapon_ids(config.starting_weapons)
	if enabled:
		if not weapons.has(weapon_id):
			weapons.append(weapon_id)
	else:
		var index: int = weapons.find(weapon_id)
		if index >= 0:
			weapons.remove_at(index)
	config.starting_weapons = weapons
	mark_dirty()


func _on_client_frequency_changed(value: float, spawner_id: StringName) -> void:
	if _loading_ui:
		return
	var node: Node = _node_for_spawner_id(spawner_id)
	if node == null:
		return
	node.set_meta(CLIENT_FREQUENCY_META, maxf(0.0, value))
	mark_dirty()


func _on_add_night_pressed() -> void:
	if _playlist == null:
		return
	_playlist.nights.append(NightSpawnPlaylist.new())
	_selected_night_index = _playlist.nights.size() - 1
	mark_dirty()
	_refresh_all()


func _on_duplicate_night_pressed() -> void:
	var night: NightSpawnPlaylist = _get_selected_night()
	if _playlist == null or night == null:
		return
	var duplicate: NightSpawnPlaylist = night.duplicate(true) as NightSpawnPlaylist
	_playlist.nights.insert(_selected_night_index + 1, duplicate)
	_selected_night_index += 1
	mark_dirty()
	_refresh_all()


func _on_delete_night_pressed() -> void:
	if _playlist == null or _playlist.nights.is_empty():
		return
	_playlist.nights.remove_at(_selected_night_index)
	if _playlist.nights.is_empty():
		_playlist.nights.append(NightSpawnPlaylist.new())
	_selected_night_index = clampi(_selected_night_index, 0, _playlist.nights.size() - 1)
	mark_dirty()
	_refresh_all()


func _enable_track(spawner_id: StringName) -> void:
	var night: NightSpawnPlaylist = _get_selected_night()
	if night == null or _get_track(spawner_id) != null:
		return
	var track: SpawnerWaveTrack = SpawnerWaveTrack.new()
	track.spawner_id = spawner_id
	night.spawner_tracks.append(track)
	mark_dirty()
	_rebuild_tracks()


func _disable_track(spawner_id: StringName) -> void:
	var night: NightSpawnPlaylist = _get_selected_night()
	if night == null:
		return
	var index: int = _get_track_index(spawner_id)
	if index < 0:
		return
	night.spawner_tracks.remove_at(index)
	mark_dirty()
	_rebuild_tracks()


func _add_wave(spawner_id: StringName) -> void:
	var track: SpawnerWaveTrack = _get_track(spawner_id)
	if track == null:
		_enable_track(spawner_id)
		track = _get_track(spawner_id)
	if track == null:
		return
	var wave: SpawnWave = SpawnWave.new()
	wave.monster_type = _monster_types()[0]
	track.waves.append(wave)
	mark_dirty()
	_rebuild_tracks()


func _focus_spawner(spawner_id: StringName) -> void:
	if _current_level_path == "" or editor_plugin == null:
		return
	editor_plugin.get_editor_interface().open_scene_from_path(_current_level_path)
	var root: Node = editor_plugin.get_editor_interface().get_edited_scene_root()
	if root == null:
		return
	var container: Node = _find_spawner_container(root)
	if container == null:
		return
	var node: Node = container.get_node_or_null(NodePath(String(spawner_id)))
	if node == null:
		return
	var selection: Object = editor_plugin.get_editor_interface().get_selection()
	selection.clear()
	selection.add_node(node)


func _node_for_spawner_id(spawner_id: StringName) -> Node:
	if _level_root == null or not _spawner_nodes.has(spawner_id):
		return null
	var node_path: NodePath = _spawner_nodes[spawner_id] as NodePath
	return _level_root.get_node_or_null(node_path)


func _assign_playlist_to_level_scene() -> bool:
	if _current_level_path == "":
		return false
	var packed: PackedScene = load(_current_level_path) as PackedScene
	if packed == null:
		return false
	var root: Node = packed.instantiate()
	var config: LevelSpawnConfig = _get_level_config(root)
	if config != null:
		config.spawn_playlist = _playlist
		_apply_starting_values_to_config(config)
	elif root.get_script() != null:
		root.free()
		_show_save_error("Level root already has a different script; assign LevelSpawnConfig manually or use a child LevelSpawnConfig node", ERR_ALREADY_EXISTS)
		return false
	else:
		root.set_script(LEVEL_CONFIG_SCRIPT)
		root.set("spawn_playlist", _playlist)
		root.set("starting_seeds", int(_starting_seeds.value))
		root.set("starting_gems", int(_starting_gems.value))
		root.set("starting_weapons", _selected_starting_weapons())
		root.set("rose_shop_counter_limit", int(_rose_shop_counter_limit.value))
	_apply_client_frequency_to_scene(root)
	var new_scene: PackedScene = PackedScene.new()
	var pack_error: Error = new_scene.pack(root)
	root.free()
	if pack_error != OK:
		_show_save_error("Could not pack level scene", pack_error)
		return false
	var save_error: Error = ResourceSaver.save(new_scene, _current_level_path)
	if save_error != OK:
		_show_save_error("Could not save level scene", save_error)
		return false
	return true


func _apply_starting_values_to_config(config: LevelSpawnConfig) -> void:
	config.starting_seeds = int(_starting_seeds.value)
	config.starting_gems = int(_starting_gems.value)
	config.starting_weapons = _selected_starting_weapons()
	config.rose_shop_counter_limit = int(_rose_shop_counter_limit.value)


func _apply_client_frequency_to_scene(root: Node) -> void:
	var container: Node = _find_spawner_container(root)
	if container == null:
		return
	for spawner_id: StringName in _client_spawner_ids:
		var source_node: Node = _node_for_spawner_id(spawner_id)
		var target_node: Node = container.get_node_or_null(NodePath(String(spawner_id)))
		if source_node == null or target_node == null:
			continue
		target_node.set_meta(CLIENT_FREQUENCY_META, float(source_node.get_meta(CLIENT_FREQUENCY_META, 1.0)))


func _show_save_error(message: String, error: Error) -> void:
	_validation_label.clear()
	_validation_label.append_text("[color=salmon]%s: %s[/color]" % [message, error_string(error)])


func _refresh_rename_row() -> void:
	_missing_id_option.clear()
	_target_id_option.clear()
	var missing_ids: Array[StringName] = _collect_missing_track_ids()
	for missing_id: StringName in missing_ids:
		_missing_id_option.add_item(String(missing_id))
		_missing_id_option.set_item_metadata(_missing_id_option.get_item_count() - 1, String(missing_id))
	for spawner_id: StringName in _spawner_ids:
		_target_id_option.add_item(String(spawner_id))
		_target_id_option.set_item_metadata(_target_id_option.get_item_count() - 1, String(spawner_id))
	_rename_row.visible = not missing_ids.is_empty() and not _spawner_ids.is_empty()


func _collect_missing_track_ids() -> Array[StringName]:
	var missing_ids: Array[StringName] = []
	if _playlist == null:
		return missing_ids
	var spawner_id_set: Dictionary = {}
	for spawner_id: StringName in _spawner_ids:
		spawner_id_set[spawner_id] = true
	var seen_missing: Dictionary = {}
	for night: NightSpawnPlaylist in _playlist.nights:
		if night == null:
			continue
		for track: SpawnerWaveTrack in night.spawner_tracks:
			if track == null or track.spawner_id == &"" or spawner_id_set.has(track.spawner_id) or seen_missing.has(track.spawner_id):
				continue
			seen_missing[track.spawner_id] = true
			missing_ids.append(track.spawner_id)
	missing_ids.sort()
	return missing_ids


func _get_selected_night() -> NightSpawnPlaylist:
	if _playlist == null or _selected_night_index < 0 or _selected_night_index >= _playlist.nights.size():
		return null
	return _playlist.nights[_selected_night_index]


func _get_track(spawner_id: StringName) -> SpawnerWaveTrack:
	var night: NightSpawnPlaylist = _get_selected_night()
	if night == null:
		return null
	for track: SpawnerWaveTrack in night.spawner_tracks:
		if track != null and track.spawner_id == spawner_id:
			return track
	return null


func _get_track_index(spawner_id: StringName) -> int:
	var night: NightSpawnPlaylist = _get_selected_night()
	if night == null:
		return -1
	var index: int = 0
	for track: SpawnerWaveTrack in night.spawner_tracks:
		if track != null and track.spawner_id == spawner_id:
			return index
		index += 1
	return -1


func _get_active_track_count() -> int:
	var night: NightSpawnPlaylist = _get_selected_night()
	if night == null:
		return 0
	return night.spawner_tracks.size()


func _collect_event_names(night: NightSpawnPlaylist) -> Array[StringName]:
	var events: Array[StringName] = []
	var seen: Dictionary = {}
	for track: SpawnerWaveTrack in night.spawner_tracks:
		if track == null:
			continue
		for wave: SpawnWave in track.waves:
			if wave == null or wave.emit_event == &"" or seen.has(wave.emit_event):
				continue
			seen[wave.emit_event] = true
			events.append(wave.emit_event)
	events.sort()
	return events


func _find_spawner_container(root: Node) -> Node:
	if root == null:
		return null
	for container_name: String in SPAWNER_CONTAINER_NAMES:
		var container: Node = root.get_node_or_null(NodePath(container_name))
		if container != null:
			return container
	return null


func _get_level_config(root: Node) -> LevelSpawnConfig:
	if root == null:
		return null
	var config: LevelSpawnConfig = root as LevelSpawnConfig
	if config != null:
		return config
	return root.get_node_or_null("LevelSpawnConfig") as LevelSpawnConfig


func _get_or_create_loaded_level_config() -> LevelSpawnConfig:
	if _level_root == null:
		return null
	var config: LevelSpawnConfig = _get_level_config(_level_root)
	if config != null:
		return config
	if _level_root.get_script() != null:
		return null
	_level_root.set_script(LEVEL_CONFIG_SCRIPT)
	config = _level_root as LevelSpawnConfig
	if config != null:
		config.spawn_playlist = _playlist
		config.starting_seeds = DEFAULT_STARTING_SEEDS
		config.starting_gems = DEFAULT_STARTING_GEMS
		config.starting_weapons = _default_starting_weapons()
	return config


func _selected_starting_weapons() -> Array[StringName]:
	var weapons: Array[StringName] = []
	for raw_weapon_id: Variant in _weapon_checkboxes.keys():
		var weapon_id: StringName = raw_weapon_id as StringName
		var checkbox: CheckBox = _weapon_checkboxes[weapon_id] as CheckBox
		if checkbox != null and checkbox.button_pressed:
			weapons.append(weapon_id)
	return weapons


func _valid_weapon_ids(raw_weapons: Array[StringName]) -> Array[StringName]:
	var weapons: Array[StringName] = []
	var seen: Dictionary = {}
	for weapon_id: StringName in raw_weapons:
		if weapon_id == &"" or seen.has(weapon_id) or not ItemCatalog.is_weapon(String(weapon_id)):
			continue
		seen[weapon_id] = true
		weapons.append(weapon_id)
	return weapons


func _default_starting_weapons() -> Array[StringName]:
	var weapons: Array[StringName] = []
	for weapon_id: StringName in DEFAULT_STARTING_WEAPONS:
		weapons.append(weapon_id)
	return weapons


func _item_display_name(item_id: StringName) -> String:
	var item_def: Dictionary = ItemCatalog.get_item_def(String(item_id))
	return str(item_def.get("name", String(item_id)))


func _default_playlist_path_for_level(level_path: String) -> String:
	return PLAYLISTS_DIR.path_join("%s_spawn_playlist.tres" % level_path.get_file().get_basename())


func _monster_types() -> Array[StringName]:
	return [&"basic"]
