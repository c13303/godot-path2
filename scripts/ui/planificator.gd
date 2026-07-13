extends Control

const ICON_SIZE: Vector2 = Vector2(32.0, 32.0)
const FOCUS_ICON_SIZE: Vector2 = Vector2(72.0, 72.0)
const PANEL_WIDTH: float = 210.0
const NORMAL_FONT_SIZE: int = 11
const FOCUS_FONT_SIZE: int = 24
const LIVE_REFRESH_SECONDS: float = 0.15
const MONSTER_TEXTURE: Texture2D = preload("res://assets/sprites/legval/monster.png")
const BIG_MONSTER_TEXTURE: Texture2D = preload("res://assets/sprites/legval/bigmonster.png")
const CLIENT_TEXTURE: Texture2D = preload("res://assets/sprites/legval/cat.png")
const KEY_TODAY: String = "planificator.today"
const KEY_NIGHT: String = "planificator.tonight"
const KEY_DAY: String = "planificator.tomorrow"
const KEY_VICTORY: String = "planificator.victory"

var _today_label: Label
var _night_label: Label
var _day_label: Label
var _victory_label: Label
var _today_rows: VBoxContainer
var _night_rows: VBoxContainer
var _day_rows: VBoxContainer
var _icon_cache: Dictionary = {}
var _live_refresh_elapsed: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_ui()
	_connect_refresh_signals()
	_apply_translations()
	call_deferred("_refresh")
	call_deferred("_refresh")


func _process(delta: float) -> void:
	_live_refresh_elapsed += delta
	if _live_refresh_elapsed < LIVE_REFRESH_SECONDS:
		return
	_live_refresh_elapsed = 0.0
	_refresh()


func _build_ui() -> void:
	for child: Node in get_children():
		child.queue_free()

	var panel: PanelContainer = PanelContainer.new()
	panel.name = "Panel"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.custom_minimum_size = Vector2(PANEL_WIDTH, 0.0)
	panel.anchor_left = 0.0
	panel.anchor_top = 0.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = 0.0
	panel.offset_top = 0.0
	panel.offset_right = 0.0
	panel.offset_bottom = 0.0
	add_child(panel)

	var margin: MarginContainer = MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	panel.add_child(margin)

	var content: VBoxContainer = VBoxContainer.new()
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_theme_constant_override("separation", 8)
	margin.add_child(content)

	_today_label = _make_section_label(NORMAL_FONT_SIZE)
	content.add_child(_today_label)
	_today_rows = VBoxContainer.new()
	_today_rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_today_rows.add_theme_constant_override("separation", 3)
	content.add_child(_today_rows)

	_night_label = _make_section_label(NORMAL_FONT_SIZE)
	content.add_child(_night_label)
	_night_rows = VBoxContainer.new()
	_night_rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_night_rows.add_theme_constant_override("separation", 3)
	content.add_child(_night_rows)

	_day_label = _make_section_label(NORMAL_FONT_SIZE)
	content.add_child(_day_label)
	_day_rows = VBoxContainer.new()
	_day_rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_day_rows.add_theme_constant_override("separation", 3)
	content.add_child(_day_rows)

	_victory_label = _make_section_label(NORMAL_FONT_SIZE)
	_victory_label.visible = false
	content.add_child(_victory_label)

	_set_mouse_filter_recursive(self)


func _make_section_label(font_size: int) -> Label:
	var label: Label = Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", font_size)
	return label


func _connect_refresh_signals() -> void:
	if not GameState.mode_changed.is_connected(_on_refresh_signal):
		GameState.mode_changed.connect(_on_refresh_signal)
	if not GameState.building_phase_changed.is_connected(_on_refresh_signal):
		GameState.building_phase_changed.connect(_on_refresh_signal)
	if not GameState.client_phase_changed.is_connected(_on_refresh_signal):
		GameState.client_phase_changed.connect(_on_refresh_signal)
	if not GameState.morning_phase_changed.is_connected(_on_refresh_signal):
		GameState.morning_phase_changed.connect(_on_refresh_signal)
	if not Translations.locale_changed.is_connected(_on_locale_changed):
		Translations.locale_changed.connect(_on_locale_changed)
	var progression: Node = _get_progression()
	if progression != null and progression.has_signal(&"day_started"):
		var callback: Callable = Callable(self, "_on_day_started")
		if not progression.is_connected(&"day_started", callback):
			progression.connect(&"day_started", callback)


func _on_refresh_signal(_value: bool) -> void:
	_refresh()


func _on_day_started(_day_number: int) -> void:
	_refresh()


func _on_locale_changed(_locale: String) -> void:
	_apply_translations()


func _apply_translations() -> void:
	if _today_label != null:
		_today_label.text = Translations.t(KEY_TODAY)
	if _night_label != null:
		_night_label.text = Translations.t(KEY_NIGHT)
	if _day_label != null:
		_day_label.text = Translations.t(KEY_DAY)
	if _victory_label != null:
		_victory_label.text = Translations.t(KEY_VICTORY)


func _refresh() -> void:
	if _today_rows == null or _night_rows == null or _day_rows == null:
		return
	_clear_rows(_today_rows)
	_clear_rows(_night_rows)
	_clear_rows(_day_rows)
	visible = true
	if _victory_label != null:
		_victory_label.visible = false

	var today_agent_type: StringName = &"monster" if GameState.is_night else &"client"
	var today_count: int = _remaining_enemy_count() if GameState.is_night else _remaining_client_count()
	if GameState.is_morning_phase:
		var morning_focus: String = "today" if today_count > 0 else ""
		_apply_focus_section(morning_focus)
		_add_row(_today_rows, today_agent_type, today_count, morning_focus == "today")
		_update_section_visibility()
		return

	var playlist: LevelSpawnPlaylist = _get_playlist()
	if playlist == null or playlist.nights.is_empty():
		var fallback_focus: String = "today" if today_count > 0 else ""
		_apply_focus_section(fallback_focus)
		_add_row(_today_rows, today_agent_type, today_count, fallback_focus == "today")
		_update_section_visibility()
		return

	var night_index: int = _get_preview_night_index(playlist)
	var night: NightSpawnPlaylist = playlist.nights[night_index]
	if night == null:
		var empty_night_focus: String = "today" if today_count > 0 else ""
		_apply_focus_section(empty_night_focus)
		_add_row(_today_rows, today_agent_type, today_count, empty_night_focus == "today")
		_update_section_visibility()
		return

	var monster_counts: Dictionary = _get_monster_counts(night)
	var night_count: int = _total_monster_count(monster_counts)
	var day_count: int = maxi(0, night.clients)
	var focus_section: String = _first_nonempty_section(today_count, night_count, day_count)
	_apply_focus_section(focus_section)
	_add_row(_today_rows, today_agent_type, today_count, focus_section == "today")
	_add_monster_rows(monster_counts, focus_section == "night")
	_add_row(_day_rows, &"client", day_count, focus_section == "day")
	if _victory_label != null:
		_victory_label.visible = _tomorrow_is_victory_day()
	_update_section_visibility()
	_set_mouse_filter_recursive(self)


## Number of clients previewed for the coming day (the "tomorrow" section). Used by the
## day-1 tutorial to check whether the player has planted enough roses to satisfy them.
func previewed_client_count() -> int:
	var playlist: LevelSpawnPlaylist = _get_playlist()
	if playlist == null or playlist.nights.is_empty():
		return 0
	var night_index: int = _get_preview_night_index(playlist)
	if night_index < 0 or night_index >= playlist.nights.size():
		return 0
	var night: NightSpawnPlaylist = playlist.nights[night_index]
	if night == null:
		return 0
	return maxi(0, night.clients)


func _clear_rows(container: VBoxContainer) -> void:
	for child: Node in container.get_children():
		child.queue_free()


func _remaining_client_count() -> int:
	var building_manager: Node = _get_building_manager()
	if building_manager != null and building_manager.has_method("remaining_planificator_client_count"):
		return int(building_manager.call("remaining_planificator_client_count"))
	return 0


func _remaining_enemy_count() -> int:
	var building_manager: Node = _get_building_manager()
	if building_manager != null and building_manager.has_method("remaining_planificator_enemy_count"):
		return int(building_manager.call("remaining_planificator_enemy_count"))
	return get_tree().get_nodes_in_group("monsters").size()


func _get_building_manager() -> Node:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return null
	return scene.get_node_or_null("Map/BuildingManager")


func _get_playlist() -> LevelSpawnPlaylist:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return null
	var loader: Node = scene.get_node_or_null("LevelLoader")
	if loader == null or not loader.has_method("get_loaded_spawn_playlist"):
		return null
	return loader.call("get_loaded_spawn_playlist") as LevelSpawnPlaylist


func _get_preview_night_index(playlist: LevelSpawnPlaylist) -> int:
	var total_nights: int = playlist.get_night_count()
	if total_nights <= 0:
		return 0
	var progression: Node = _get_progression()
	if progression == null or not progression.has_method("get_value"):
		return 0
	var day_number: int = int(progression.call("get_value", &"nDays"))
	var day_index: int = maxi(0, day_number - 1)
	# Nights no longer loop; clamp so the trailing client day previews the final night.
	return mini(day_index, total_nights - 1)


## True when surviving tonight's fight leads straight into the run's trailing client-only
## day (the victory day). Runs are finite: N authored nights fought on days 1..N, then the
## win is claimed on day N+1. So the day *after* tonight is that victory day exactly when
## the current day equals the authored night count.
func _tomorrow_is_victory_day() -> bool:
	var playlist: LevelSpawnPlaylist = _get_playlist()
	if playlist == null:
		return false
	var total_nights: int = playlist.get_night_count()
	if total_nights <= 0:
		return false
	var progression: Node = _get_progression()
	if progression == null or not progression.has_method("get_value"):
		return false
	var day_number: int = int(progression.call("get_value", &"nDays"))
	return day_number == total_nights


func _get_progression() -> Node:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return null
	return scene.get_node_or_null("progression")


func _get_monster_counts(night: NightSpawnPlaylist) -> Dictionary:
	var counts: Dictionary = {}
	for track: SpawnerWaveTrack in night.spawner_tracks:
		if track == null:
			continue
		for wave: SpawnWave in track.waves:
			if wave == null:
				continue
			var monster_type: StringName = wave.monster_type
			var count: int = maxi(0, wave.monster_count)
			counts[monster_type] = int(counts.get(monster_type, 0)) + count
	return counts


func _total_monster_count(monster_counts: Dictionary) -> int:
	var total: int = 0
	for raw_count: Variant in monster_counts.values():
		total += int(raw_count)
	return total


func _first_nonempty_section(today_count: int, night_count: int, day_count: int) -> String:
	if today_count > 0:
		return "today"
	if night_count > 0:
		return "night"
	if day_count > 0:
		return "day"
	return ""


func _add_monster_rows(monster_counts: Dictionary, large: bool = false) -> void:
	var ordered_types: Array[StringName] = [&"basic", &"bigmonster"]
	for monster_type: StringName in ordered_types:
		var count: int = int(monster_counts.get(monster_type, 0))
		if count > 0:
			_add_row(_night_rows, monster_type, count, large)
	for raw_type: Variant in monster_counts.keys():
		var monster_type: StringName = StringName(str(raw_type))
		if ordered_types.has(monster_type):
			continue
		var count: int = int(monster_counts.get(monster_type, 0))
		if count > 0:
			_add_row(_night_rows, monster_type, count, large)


func _add_row(container: VBoxContainer, agent_type: StringName, count: int, large: bool = false) -> void:
	if count <= 0:
		return
	var icon_size: Vector2 = FOCUS_ICON_SIZE if large else ICON_SIZE
	var font_size: int = FOCUS_FONT_SIZE if large else NORMAL_FONT_SIZE
	var row: HBoxContainer = HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.custom_minimum_size = Vector2(0.0, icon_size.y)
	row.add_theme_constant_override("separation", 9 if large else 6)
	container.add_child(row)

	var icon: TextureRect = TextureRect.new()
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.custom_minimum_size = icon_size
	icon.texture = _get_icon(agent_type)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	row.add_child(icon)

	var count_label: Label = Label.new()
	count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	count_label.text = "X %d" % count
	count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	count_label.add_theme_font_size_override("font_size", font_size)
	row.add_child(count_label)


func _apply_focus_section(section: String) -> void:
	_apply_label_focus(_today_label, section == "today")
	_apply_label_focus(_night_label, section == "night")
	_apply_label_focus(_day_label, section == "day")
	if _today_rows != null:
		_today_rows.add_theme_constant_override("separation", 8 if section == "today" else 3)
	if _night_rows != null:
		_night_rows.add_theme_constant_override("separation", 8 if section == "night" else 3)
	if _day_rows != null:
		_day_rows.add_theme_constant_override("separation", 8 if section == "day" else 3)


func _apply_label_focus(label: Label, focused: bool) -> void:
	if label == null:
		return
	label.add_theme_font_size_override("font_size", FOCUS_FONT_SIZE if focused else NORMAL_FONT_SIZE)


func _update_section_visibility() -> void:
	if _today_label != null:
		_today_label.visible = _today_rows != null and _today_rows.get_child_count() > 0
	if _today_rows != null:
		_today_rows.visible = _today_rows.get_child_count() > 0
	if _night_label != null:
		_night_label.visible = _night_rows != null and _night_rows.get_child_count() > 0
	if _night_rows != null:
		_night_rows.visible = _night_rows.get_child_count() > 0
	if _day_label != null:
		_day_label.visible = _day_rows != null and _day_rows.get_child_count() > 0
	if _day_rows != null:
		_day_rows.visible = _day_rows.get_child_count() > 0


func _get_icon(agent_type: StringName) -> Texture2D:
	if _icon_cache.has(agent_type):
		return _icon_cache[agent_type] as Texture2D
	var texture: Texture2D = MONSTER_TEXTURE
	var frame_size: Vector2i = Vector2i(64, 64)
	match agent_type:
		&"bigmonster":
			texture = BIG_MONSTER_TEXTURE
			frame_size = Vector2i(96, 96)
		&"client":
			texture = CLIENT_TEXTURE
			frame_size = Vector2i(64, 64)
		_:
			texture = MONSTER_TEXTURE
			frame_size = Vector2i(64, 64)
	var atlas: AtlasTexture = AtlasTexture.new()
	atlas.atlas = texture
	atlas.region = Rect2(Vector2.ZERO, Vector2(frame_size))
	_icon_cache[agent_type] = atlas
	return atlas


func _set_mouse_filter_recursive(node: Node) -> void:
	if node is Control:
		var control: Control = node as Control
		control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child: Node in node.get_children():
		_set_mouse_filter_recursive(child)
