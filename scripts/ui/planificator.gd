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
# Fallback icon for a monster type with no catalog texture; clients use their own sheet.
const FALLBACK_MONSTER_TEXTURE: Texture2D = preload("res://assets/sprites/legval/monster.png")
const CLIENT_TEXTURE: Texture2D = preload("res://assets/sprites/legval/cat.png")
const CLIENT_ICON_HFRAMES: int = 7
const FALLBACK_MONSTER_HFRAMES: int = 4

const KEY_NOW: String = "planificator.now"
const KEY_NIGHT: String = "planificator.tonight"
const KEY_DAY: String = "planificator.tomorrow"
const KEY_VICTORY: String = "planificator.victory"

var _slot_labels: Array[Label] = []
var _slot_rows: Array[VBoxContainer] = []
var _resolver: PlanificatorTimelineResolver = PlanificatorTimelineResolver.new()
var _icon_cache: Dictionary = {}
var _live_refresh_elapsed: float = 0.0
# Coalesces the several game-state signals emitted during one day/night transition into a
# single deferred refresh, so the visual model is only resolved once the transition stack
# has fully settled (see _queue_refresh).
var _refresh_queued: bool = false
# True once a complete, valid playlist-backed model has been published. Guards against
# blanking that model with a transient empty result while a dependency is briefly missing.
var _has_published_valid: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_ui()
	_connect_refresh_signals()
	_queue_refresh()


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
	if not GameState.gameplay_phase_changed.is_connected(_on_gameplay_phase_changed):
		GameState.gameplay_phase_changed.connect(_on_gameplay_phase_changed)
	if not Translations.locale_changed.is_connected(_on_locale_changed):
		Translations.locale_changed.connect(_on_locale_changed)
	var progression: Node = _get_progression()
	if progression != null and progression.has_signal(&"day_started"):
		var callback: Callable = Callable(self, "_on_day_started")
		if not progression.is_connected(&"day_started", callback):
			progression.connect(&"day_started", callback)


func _on_gameplay_phase_changed(_phase: int) -> void:
	_queue_refresh()


func _on_day_started(_day_number: int) -> void:
	_queue_refresh()


func _on_locale_changed(_locale: String) -> void:
	_queue_refresh()


# Signal-driven refreshes are coalesced: a day/night transition emits several phase
# signals in one synchronous stack (mode_changed, day_started, building/morning/client
# phase changes). Refreshing on each would resolve the timeline against half-applied
# state. Deferring collapses them into one refresh that runs after the stack unwinds, when
# progression, phase flags and the client-step latch are all settled.
func _queue_refresh() -> void:
	if _refresh_queued:
		return
	_refresh_queued = true
	call_deferred("_run_queued_refresh")


func _run_queued_refresh() -> void:
	_refresh_queued = false
	_refresh()


func _refresh() -> void:
	if _slot_rows.size() < SLOT_COUNT or _slot_labels.size() < SLOT_COUNT:
		return
	# Resolve and validate the complete model BEFORE touching the visible sections, so the
	# UI is never progressively cleared and repopulated while the timeline is being decided.
	var playlist: LevelSpawnPlaylist = _get_playlist()
	var slots: Array = _resolve_slots()
	if not _is_publishable(playlist, slots):
		# Dependency temporarily missing or an invalid partial model: keep the previous
		# valid display and retry on the next deferred/polled refresh.
		return
	visible = true
	for rows: VBoxContainer in _slot_rows:
		_clear_rows(rows)
	for slot_index: int in range(SLOT_COUNT):
		if slot_index < slots.size():
			_render_slot(slot_index, slots[slot_index] as PlanificatorTimelineResolver.TimelineSlot, slot_index == 0)
		else:
			_hide_slot(slot_index)
	_set_mouse_filter_recursive(self)
	if playlist != null:
		_has_published_valid = true


# Validate the resolved model before it replaces the current display. A playlist-driven
# run must show exactly two ordered slots, or a single VICTORY slot. A level with no
# authored playlist uses the legacy single-count fallback, but only until a real model has
# been shown (so a brief null-playlist dropout never blanks a valid timeline).
func _is_publishable(playlist: LevelSpawnPlaylist, slots: Array) -> bool:
	if playlist == null:
		return not _has_published_valid
	if slots.size() == 1 and (slots[0] as PlanificatorTimelineResolver.TimelineSlot).is_victory:
		return true
	if slots.size() == 2:
		return true
	push_warning("planificator: resolver produced an invalid %d-slot model for an active run; keeping previous display." % slots.size())
	return false


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
	var anchor_index: int = _get_anchor_night_index()
	var client_step_pending: bool = _get_client_step_pending()
	var monster_counts: Dictionary = _remaining_monster_counts_by_type()
	var live_client_count: int = _remaining_client_count()
	return _resolver.resolve(
		playlist,
		day_number,
		anchor_index,
		client_step_pending,
		monster_counts,
		live_client_count
	)


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


# Current-night monster counts grouped by canonical monster_type (living + pending),
# owned by BuildingManager. Falls back to grouping the live scene group by its stamped
# metadata if the manager query is unavailable (scene startup); never flattens to a single
# aggregate type.
func _remaining_monster_counts_by_type() -> Dictionary:
	var building_manager: Node = _get_building_manager()
	if building_manager != null and building_manager.has_method("remaining_planificator_monster_counts_by_type"):
		var raw_counts: Variant = building_manager.call("remaining_planificator_monster_counts_by_type")
		if raw_counts is Dictionary:
			return raw_counts as Dictionary
	return _live_monster_counts_from_group()


func _live_monster_counts_from_group() -> Dictionary:
	var counts: Dictionary = {}
	for node: Node in get_tree().get_nodes_in_group("monsters"):
		if not is_instance_valid(node):
			continue
		var monster_type: StringName = MonsterCatalog.BASIC_ID
		if node.has_meta("monster_type"):
			monster_type = StringName(str(node.get_meta("monster_type")))
		counts[monster_type] = int(counts.get(monster_type, 0)) + 1
	return counts


func _get_anchor_night_index() -> int:
	var building_manager: Node = _get_building_manager()
	if building_manager != null and building_manager.has_method("planificator_anchor_night_index"):
		return int(building_manager.call("planificator_anchor_night_index"))
	return -1


func _get_client_step_pending() -> bool:
	var building_manager: Node = _get_building_manager()
	if building_manager != null and building_manager.has_method("current_day_client_step_pending_or_active"):
		return bool(building_manager.call("current_day_client_step_pending_or_active"))
	return false


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


# Resolve a row icon generically. Clients use their own sheet; every other agent_type is a
# monster type looked up in MonsterCatalog, so a newly catalogued monster renders with no
# change here. An unknown type keeps its own row and shows a safe fallback icon plus a
# warning; it is never merged into another type.
func _get_icon(agent_type: StringName) -> Texture2D:
	if _icon_cache.has(agent_type):
		return _icon_cache[agent_type] as Texture2D
	var atlas: AtlasTexture = AtlasTexture.new()
	if agent_type == PlanificatorTimelineResolver.CLIENT_AGENT:
		atlas.atlas = CLIENT_TEXTURE
		atlas.region = _first_frame_region(CLIENT_TEXTURE, CLIENT_ICON_HFRAMES)
	else:
		var data: MonsterData = MonsterCatalog.get_monster(agent_type)
		if data != null and data.texture != null:
			atlas.atlas = data.texture
			atlas.region = _first_frame_region(data.texture, maxi(1, data.sprite_hframes))
		else:
			push_warning("planificator: no catalog icon for monster type '%s'; using fallback icon." % String(agent_type))
			atlas.atlas = FALLBACK_MONSTER_TEXTURE
			atlas.region = _first_frame_region(FALLBACK_MONSTER_TEXTURE, FALLBACK_MONSTER_HFRAMES)
	_icon_cache[agent_type] = atlas
	return atlas


# First directional frame of a horizontal sprite sheet: full height, one hframe wide.
func _first_frame_region(texture: Texture2D, hframes: int) -> Rect2:
	var frame_width: float = float(texture.get_width()) / float(maxi(1, hframes))
	return Rect2(0.0, 0.0, frame_width, float(texture.get_height()))


func _set_mouse_filter_recursive(node: Node) -> void:
	if node is Control:
		var control: Control = node as Control
		control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child: Node in node.get_children():
		_set_mouse_filter_recursive(child)
