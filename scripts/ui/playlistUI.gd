extends Control

const ICON_SIZE: Vector2 = Vector2(32.0, 32.0)
const PANEL_WIDTH: float = 190.0
const MONSTER_TEXTURE: Texture2D = preload("res://assets/sprites/legval/monster.png")
const BIG_MONSTER_TEXTURE: Texture2D = preload("res://assets/sprites/legval/bigmonster.png")
const CLIENT_TEXTURE: Texture2D = preload("res://assets/sprites/legval/client.png")
const MERCHANT_TEXTURE: Texture2D = preload("res://assets/sprites/legval/merchent.png")
const KEY_TITLE: String = "playlist.next_day"
const KEY_NIGHT: String = "playlist.night"
const KEY_DAY: String = "playlist.day"

var _title_label: Label
var _night_label: Label
var _day_label: Label
var _night_rows: VBoxContainer
var _day_rows: VBoxContainer
var _icon_cache: Dictionary = {}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_ui()
	_connect_refresh_signals()
	_apply_translations()
	call_deferred("_refresh")
	call_deferred("_refresh")


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
	content.add_theme_constant_override("separation", 6)
	margin.add_child(content)

	_title_label = Label.new()
	_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_title_label.add_theme_font_size_override("font_size", 13)
	content.add_child(_title_label)

	_night_label = _make_section_label()
	content.add_child(_night_label)
	_night_rows = VBoxContainer.new()
	_night_rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_night_rows.add_theme_constant_override("separation", 3)
	content.add_child(_night_rows)

	_day_label = _make_section_label()
	content.add_child(_day_label)
	_day_rows = VBoxContainer.new()
	_day_rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_day_rows.add_theme_constant_override("separation", 3)
	content.add_child(_day_rows)

	_set_mouse_filter_recursive(self)


func _make_section_label() -> Label:
	var label: Label = Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", 11)
	return label


func _connect_refresh_signals() -> void:
	if not GameState.mode_changed.is_connected(_on_refresh_signal):
		GameState.mode_changed.connect(_on_refresh_signal)
	if not GameState.building_phase_changed.is_connected(_on_refresh_signal):
		GameState.building_phase_changed.connect(_on_refresh_signal)
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
	if _title_label != null:
		_title_label.text = Translations.t(KEY_TITLE)
	if _night_label != null:
		_night_label.text = Translations.t(KEY_NIGHT)
	if _day_label != null:
		_day_label.text = Translations.t(KEY_DAY)


func _refresh() -> void:
	if _night_rows == null or _day_rows == null:
		return
	_clear_rows(_night_rows)
	_clear_rows(_day_rows)

	if GameState.is_night:
		visible = false
		return

	var playlist: LevelSpawnPlaylist = _get_playlist()
	if playlist == null or playlist.nights.is_empty():
		visible = false
		return
	visible = true

	var night_index: int = _get_preview_night_index(playlist)
	var night: NightSpawnPlaylist = playlist.nights[night_index]
	if night == null:
		return

	var monster_counts: Dictionary = _get_monster_counts(night)
	_add_monster_rows(monster_counts)
	_add_row(_day_rows, &"client", maxi(0, night.clients))
	_add_row(_day_rows, &"merchant", 1)
	_set_mouse_filter_recursive(self)


func _clear_rows(container: VBoxContainer) -> void:
	for child: Node in container.get_children():
		child.queue_free()


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


func _add_monster_rows(monster_counts: Dictionary) -> void:
	var ordered_types: Array[StringName] = [&"basic", &"bigmonster"]
	for monster_type: StringName in ordered_types:
		var count: int = int(monster_counts.get(monster_type, 0))
		if count > 0:
			_add_row(_night_rows, monster_type, count)
	for raw_type: Variant in monster_counts.keys():
		var monster_type: StringName = StringName(str(raw_type))
		if ordered_types.has(monster_type):
			continue
		var count: int = int(monster_counts.get(monster_type, 0))
		if count > 0:
			_add_row(_night_rows, monster_type, count)


func _add_row(container: VBoxContainer, agent_type: StringName, count: int) -> void:
	var row: HBoxContainer = HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.custom_minimum_size = Vector2(0.0, ICON_SIZE.y)
	row.add_theme_constant_override("separation", 6)
	container.add_child(row)

	var icon: TextureRect = TextureRect.new()
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.custom_minimum_size = ICON_SIZE
	icon.texture = _get_icon(agent_type)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	row.add_child(icon)

	var count_label: Label = Label.new()
	count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	count_label.text = "X %d" % count
	count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(count_label)


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
		&"merchant":
			texture = MERCHANT_TEXTURE
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
