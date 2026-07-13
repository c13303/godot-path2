extends Control

# Renderer for the planificator timeline. It owns no schedule semantics: it collects its
# authoritative dependencies (the playlist owned by BuildingManager, the progression day,
# and the live now-counts), asks PlanificatorTimelineResolver for the ordered slots, and
# draws at most two generic slot sections. The first resolved slot is always the focused
# (large) slot; the second is normal-sized.

const ICON_SIZE: Vector2 = Vector2(32.0, 32.0)
const FOCUS_ICON_SIZE: Vector2 = Vector2(72.0, 72.0)
const PANEL_WIDTH: float = 210.0
const NORMAL_FONT_SIZE: int = 11
const FOCUS_FONT_SIZE: int = 24
const LIVE_REFRESH_SECONDS: float = 0.15
const SLOT_COUNT: int = 2
const MONSTER_TEXTURE: Texture2D = preload("res://assets/sprites/legval/monster.png")
const BIG_MONSTER_TEXTURE: Texture2D = preload("res://assets/sprites/legval/bigmonster.png")
const CLIENT_TEXTURE: Texture2D = preload("res://assets/sprites/legval/cat.png")

const KEY_NOW: String = "planificator.now"
const KEY_NIGHT: String = "planificator.tonight"
const KEY_DAY: String = "planificator.tomorrow"
const KEY_VICTORY: String = "planificator.victory"

var _slot_labels: Array[Label] = []
var _slot_rows: Array[VBoxContainer] = []
var _resolver: PlanificatorTimelineResolver = PlanificatorTimelineResolver.new()
var _icon_cache: Dictionary = {}
var _live_refresh_elapsed: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_ui()
	_connect_refresh_signals()
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
	_slot_labels.clear()
	_slot_rows.clear()

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

	for _index: int in range(SLOT_COUNT):
		var label: Label = _make_section_label(NORMAL_FONT_SIZE)
		content.add_child(label)
		_slot_labels.append(label)
		var rows: VBoxContainer = VBoxContainer.new()
		rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rows.add_theme_constant_override("separation", 3)
		content.add_child(rows)
		_slot_rows.append(rows)

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
	_refresh()


func _refresh() -> void:
	if _slot_rows.size() < SLOT_COUNT or _slot_labels.size() < SLOT_COUNT:
		return
	visible = true
	for rows: VBoxContainer in _slot_rows:
		_clear_rows(rows)

	var slots: Array = _resolve_slots()
	for slot_index: int in range(SLOT_COUNT):
		if slot_index < slots.size():
			var slot: PlanificatorTimelineResolver.TimelineSlot = slots[slot_index]
			_render_slot(slot_index, slot, slot_index == 0)
		else:
			_hide_slot(slot_index)
	_set_mouse_filter_recursive(self)


## Number of clients previewed for the coming day (the TOMORROW slot). Used by the
## day-1 tutorial to check whether the player has planted enough roses to satisfy them.
## Reads the same resolved timeline used for rendering; returns 0 when there is no
## TOMORROW client slot.
func previewed_client_count() -> int:
	var slots: Array = _resolve_slots()
	for slot: PlanificatorTimelineResolver.TimelineSlot in slots:
		if slot.kind != PlanificatorTimelineResolver.SLOT_TOMORROW:
			continue
		var total: int = 0
		for row: PlanificatorTimelineResolver.TimelineRow in slot.rows:
			if row.agent_type == PlanificatorTimelineResolver.CLIENT_AGENT:
				total += row.count
		return total
	return 0


func _resolve_slots() -> Array:
	var playlist: LevelSpawnPlaylist = _get_playlist()
	var day_number: int = _get_day_number()
	var live_monster_count: int = _remaining_enemy_count()
	var live_client_count: int = _remaining_client_count()
	return _resolver.resolve(playlist, day_number, live_monster_count, live_client_count)


func _render_slot(slot_index: int, slot: PlanificatorTimelineResolver.TimelineSlot, focused: bool) -> void:
	var label: Label = _slot_labels[slot_index]
	var rows: VBoxContainer = _slot_rows[slot_index]
	var font_size: int = FOCUS_FONT_SIZE if focused else NORMAL_FONT_SIZE
	label.text = _slot_label_text(slot.kind)
	label.add_theme_font_size_override("font_size", font_size)

	if slot.is_victory:
		# Victory carries a label but no rows.
		label.visible = true
		rows.visible = false
		return

	rows.add_theme_constant_override("separation", 8 if focused else 3)
	for row: PlanificatorTimelineResolver.TimelineRow in slot.rows:
		_add_row(rows, row.agent_type, row.count, focused)
	var has_rows: bool = rows.get_child_count() > 0
	label.visible = has_rows
	rows.visible = has_rows


func _hide_slot(slot_index: int) -> void:
	_slot_labels[slot_index].visible = false
	_slot_rows[slot_index].visible = false


func _slot_label_text(kind: StringName) -> String:
	match kind:
		PlanificatorTimelineResolver.SLOT_NOW:
			return Translations.t(KEY_NOW)
		PlanificatorTimelineResolver.SLOT_TONIGHT:
			return Translations.t(KEY_NIGHT)
		PlanificatorTimelineResolver.SLOT_TOMORROW:
			return Translations.t(KEY_DAY)
		PlanificatorTimelineResolver.SLOT_VICTORY:
			return Translations.t(KEY_VICTORY)
	return ""


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


# Authoritative playlist source: the one owned by BuildingManager's spawn-playlist
# config, the same resource runtime spawning uses. May be briefly unavailable during
# scene startup; the live poll refreshes again once it exists.
func _get_playlist() -> LevelSpawnPlaylist:
	var building_manager: Node = _get_building_manager()
	if building_manager == null or not building_manager.has_method("get_spawn_playlist_config"):
		return null
	var config: SpawnPlaylistConfigService = building_manager.call("get_spawn_playlist_config") as SpawnPlaylistConfigService
	if config == null:
		return null
	return config.level_spawn_playlist()


func _get_day_number() -> int:
	var progression: Node = _get_progression()
	if progression == null or not progression.has_method("get_value"):
		return 1
	return int(progression.call("get_value", &"nDays"))


func _get_progression() -> Node:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return null
	return scene.get_node_or_null("progression")


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
