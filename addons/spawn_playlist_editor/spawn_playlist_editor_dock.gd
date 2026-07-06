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
const DEFAULT_STARTING_MONEY: int = 0
const DEFAULT_STARTING_WEAPONS: Array[StringName] = [&"spray"]
const DEFAULT_MONSTER_DROP_SEED_CHANCE_PERCENT: int = 0
const TOOL_SHOP_ITEM_IDS: Array[StringName] = [&"rose", &"turret1", &"turret_epine", &"wall", &"ronce", &"fence"]
const MERCHANT_ITEM_IDS: Array[StringName] = [&"seed", &"spray", &"beam", &"sword", &"bomb", &"pasteque"]
const LEGACY_SHOP_ITEM_IDS: Array[StringName] = [&"rose", &"turret1", &"turret_epine", &"wall", &"ronce", &"fence", &"seed", &"spray", &"beam", &"sword", &"bomb"]
const REWARD_CURRENCIES: Array[String] = ["seed", "money", "gem"]
const WAVE_MOVE_WIDTH: float = 94.0
const WAVE_NUMBER_WIDTH: float = 28.0
const WAVE_TYPE_WIDTH: float = 112.0
const WAVE_COUNT_WIDTH: float = 84.0
const WAVE_TIME_WIDTH: float = 96.0
const WAVE_EVENT_WIDTH: float = 124.0
const WAVE_DELETE_WIDTH: float = 74.0
const FLOOR_TILE_CATALOG: Script = preload("res://scripts/map/floor_tile_catalog.gd")
const WATER_POND_ATLAS_ORIGIN: Vector2i = Vector2i(4, 3)
const WATER_OCEAN_HOLE_ATLAS_CENTER: Vector2i = Vector2i(8, 4)
const WATER_DIAGONAL_GROUND_TOP_LEFT_ATLAS: Vector2i = Vector2i(10, 3)
const WATER_DIAGONAL_GROUND_TOP_RIGHT_ATLAS: Vector2i = Vector2i(11, 3)
const WATER_DIAGONAL_GROUND_BOTTOM_LEFT_ATLAS: Vector2i = Vector2i(10, 4)
const WATER_DIAGONAL_GROUND_BOTTOM_RIGHT_ATLAS: Vector2i = Vector2i(11, 4)
const WATER_ISOLATED_ATLAS: Vector2i = Vector2i(10, 6)
const WATER_HORIZONTAL_RIVER_ATLAS: Vector2i = Vector2i(12, 3)
const WATER_HORIZONTAL_RIVER_LEFT_EDGE_ATLAS: Vector2i = Vector2i(12, 4)
const WATER_HORIZONTAL_RIVER_RIGHT_EDGE_ATLAS: Vector2i = Vector2i(12, 5)
const WATER_VERTICAL_RIVER_ATLAS: Vector2i = Vector2i(13, 3)
const WATER_VERTICAL_RIVER_TOP_EDGE_ATLAS: Vector2i = Vector2i(13, 4)
const WATER_VERTICAL_RIVER_BOTTOM_EDGE_ATLAS: Vector2i = Vector2i(13, 5)
const WATER_NEIGHBOR_OFFSETS: Array[Vector2i] = [
	Vector2i(0, -1),
	Vector2i(-1, 0),
	Vector2i(1, 0),
	Vector2i(0, 1),
	Vector2i(-1, -1),
	Vector2i(1, -1),
	Vector2i(-1, 1),
	Vector2i(1, 1),
]

var editor_plugin: EditorPlugin

var _level_paths: Array[String] = []
var _current_level_path: String = ""
var _level_root: Node
var _playlist: LevelSpawnPlaylist
var _spawner_ids: Array[StringName] = []
var _client_spawner_ids: Array[StringName] = []
var _spawner_nodes: Dictionary = {}  # StringName -> NodePath relative to the spawner container
var _duplicate_spawner_ids: Array[StringName] = []
var _selected_night_index: int = 0
var _dirty: bool = false
var _loading_ui: bool = false
var _status_hide_token: int = 0

var _level_option: OptionButton
var _save_button: Button
var _create_button: Button
var _dirty_label: Label
var _playlist_label: Label
var _starting_controls: VBoxContainer
var _monster_drop_controls: VBoxContainer
var _shop_controls: VBoxContainer
var _client_frequency_box: VBoxContainer
var _starting_seeds: SpinBox
var _starting_gems: SpinBox
var _starting_money: SpinBox
var _monster_drop_seed_chance: SpinBox
var _rose_shop_counter_limit: SpinBox
var _weapon_checks_box: HBoxContainer
var _weapon_checkboxes: Dictionary = {}  # StringName -> CheckBox
var _starting_items_box: GridContainer
var _starting_item_spins: Dictionary = {}  # StringName -> SpinBox
var _starting_item_available_checks: Dictionary = {}  # StringName -> CheckBox
var _tool_shop_available_checkboxes: Dictionary = {}  # StringName -> CheckBox
var _tool_shop_price_spins: Dictionary = {}  # StringName -> SpinBox
var _tool_shop_day_spins: Dictionary = {}  # StringName -> SpinBox
var _tool_shop_growth_price_factor_spins: Dictionary = {}  # StringName -> SpinBox
var _merchant_available_checkboxes: Dictionary = {}  # StringName -> CheckBox
var _merchant_price_spins: Dictionary = {}  # StringName -> SpinBox
var _merchant_day_spins: Dictionary = {}  # StringName -> SpinBox
var _night_option: OptionButton
var _night_clients_spin: SpinBox
var _reward_box: VBoxContainer
var _reward_one_time_check: CheckBox
var _reward_amount_spins: Dictionary = {}  # String currency -> SpinBox
var _validation_label: RichTextLabel
var _rename_row: HBoxContainer
var _missing_id_option: OptionButton
var _target_id_option: OptionButton
var _tracks_box: VBoxContainer
var _starting_section: FoldableContainer
var _monster_drop_section: FoldableContainer
var _shop_section: FoldableContainer
var _client_frequency_section: FoldableContainer
var _reward_section: FoldableContainer
var _beautifier_section: FoldableContainer
var _water_edges_button: Button


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
	_refresh_status()
	_refresh_validation()


func move_wave(spawner_id: StringName, from_index: int, to_index: int) -> void:
	var track: SpawnerWaveTrack = _get_track(spawner_id)
	if track == null:
		return
	if from_index < 0 or from_index >= track.waves.size() or to_index < 0 or to_index >= track.waves.size():
		return
	if from_index == to_index:
		return
	var waves: Array[SpawnWave] = _copy_waves(track)
	var wave: SpawnWave = waves[from_index]
	waves.remove_at(from_index)
	waves.insert(to_index, wave)
	track.waves = waves
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
	var tracks: Array[SpawnerWaveTrack] = _copy_spawner_tracks(night)
	var track: SpawnerWaveTrack = tracks[from_index]
	tracks.remove_at(from_index)
	tracks.insert(to_index, track)
	night.spawner_tracks = tracks
	mark_dirty()
	_rebuild_tracks()


func delete_wave(spawner_id: StringName, wave_index: int) -> void:
	var track: SpawnerWaveTrack = _get_track(spawner_id)
	if track == null or wave_index < 0 or wave_index >= track.waves.size():
		return
	var waves: Array[SpawnWave] = _copy_waves(track)
	waves.remove_at(wave_index)
	track.waves = waves
	mark_dirty()
	_rebuild_tracks()


func _build_ui() -> void:
	_loading_ui = true
	size_flags_vertical = SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 6)

	# Persistent header shared by both tabs: pick a level, run level actions and
	# see the save status regardless of which tab is open.
	var level_row: HBoxContainer = HBoxContainer.new()
	level_row.add_theme_constant_override("separation", 6)
	add_child(level_row)

	_level_option = OptionButton.new()
	_level_option.size_flags_horizontal = SIZE_EXPAND_FILL
	_level_option.item_selected.connect(_on_level_selected)
	level_row.add_child(_level_option)

	_save_button = Button.new()
	_save_button.text = "Save"
	_save_button.pressed.connect(_on_save_pressed)
	level_row.add_child(_save_button)

	var refresh_button: Button = Button.new()
	refresh_button.text = "Refresh"
	refresh_button.pressed.connect(_refresh_levels)
	level_row.add_child(refresh_button)

	var action_row: HBoxContainer = HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 6)
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
	_dirty_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_dirty_label.size_flags_horizontal = SIZE_EXPAND_FILL
	action_row.add_child(_dirty_label)

	_playlist_label = Label.new()
	_playlist_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_playlist_label)

	var tabs: TabContainer = TabContainer.new()
	tabs.size_flags_vertical = SIZE_EXPAND_FILL
	tabs.size_flags_horizontal = SIZE_EXPAND_FILL
	add_child(tabs)

	_build_configuration_tab(tabs)
	_build_items_tab(tabs)
	_build_nights_tab(tabs)

	# Validation and the missing-id rename tool sit under the tabs so save errors
	# and warnings stay visible no matter which tab is selected.
	_validation_label = RichTextLabel.new()
	_validation_label.custom_minimum_size = Vector2(0.0, 95.0)
	_validation_label.fit_content = false
	_validation_label.scroll_active = true
	add_child(_validation_label)

	_rename_row = HBoxContainer.new()
	_rename_row.add_theme_constant_override("separation", 6)
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

	_loading_ui = false
	_refresh_status()


# Configuration tab: level-wide setup that is not about items — the client spawners and
# the tilemap beautifier tools.
func _build_configuration_tab(tabs: TabContainer) -> void:
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.name = "Configuration"
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = SIZE_EXPAND_FILL
	tabs.add_child(scroll)

	var body: VBoxContainer = VBoxContainer.new()
	body.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.add_child(body)

	_client_frequency_box = VBoxContainer.new()
	_client_frequency_section = _make_section("Client Spawners", _client_frequency_box)
	body.add_child(_client_frequency_section)

	var beautifier_controls: VBoxContainer = VBoxContainer.new()
	_build_beautifier_controls(beautifier_controls)
	_beautifier_section = _make_section("tilemap beautifier", beautifier_controls)
	body.add_child(_beautifier_section)


# Items tab: the starting inventory (currencies, weapons, per-item quantities and
# toolbuild availability), the shop and the monster drop settings.
func _build_items_tab(tabs: TabContainer) -> void:
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.name = "Items"
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = SIZE_EXPAND_FILL
	tabs.add_child(scroll)

	var body: VBoxContainer = VBoxContainer.new()
	body.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.add_child(body)

	_starting_controls = VBoxContainer.new()
	_build_starting_controls()
	_starting_section = _make_section("Starting Level", _starting_controls)
	body.add_child(_starting_section)

	_shop_controls = VBoxContainer.new()
	_build_shop_controls()
	_shop_section = _make_section("Shop", _shop_controls)
	body.add_child(_shop_section)

	_monster_drop_controls = VBoxContainer.new()
	_build_monster_drop_controls()
	_monster_drop_section = _make_section("Monster Drop", _monster_drop_controls)
	body.add_child(_monster_drop_section)


# Nights tab: per-night options, special reward and the wave tracks.
func _build_nights_tab(tabs: TabContainer) -> void:
	var body: VBoxContainer = VBoxContainer.new()
	body.name = "Nights"
	body.size_flags_vertical = SIZE_EXPAND_FILL
	body.size_flags_horizontal = SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 8)
	tabs.add_child(body)

	var night_row: HBoxContainer = HBoxContainer.new()
	night_row.add_theme_constant_override("separation", 6)
	body.add_child(night_row)

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

	var clients_row: HBoxContainer = HBoxContainer.new()
	clients_row.add_theme_constant_override("separation", 6)
	body.add_child(clients_row)

	var clients_label: Label = Label.new()
	clients_label.text = "clients"
	clients_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	clients_row.add_child(clients_label)

	_night_clients_spin = SpinBox.new()
	_night_clients_spin.min_value = 0.0
	_night_clients_spin.max_value = 100000.0
	_night_clients_spin.step = 1.0
	_night_clients_spin.custom_minimum_size = Vector2(130.0, 0.0)
	_night_clients_spin.value_changed.connect(_on_night_clients_changed)
	clients_row.add_child(_night_clients_spin)

	_reward_box = VBoxContainer.new()
	_build_reward_controls()
	_reward_section = _make_section("Special Reward (this night)", _reward_box)
	body.add_child(_reward_section)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = SIZE_EXPAND_FILL
	body.add_child(scroll)

	_tracks_box = VBoxContainer.new()
	_tracks_box.size_flags_horizontal = SIZE_EXPAND_FILL
	_tracks_box.add_theme_constant_override("separation", 8)
	scroll.add_child(_tracks_box)


# Wraps a content control in a collapsible titled section (accordion panel).
func _make_section(title_text: String, content: Control) -> FoldableContainer:
	var section: FoldableContainer = FoldableContainer.new()
	section.title = title_text
	section.size_flags_horizontal = SIZE_EXPAND_FILL
	section.add_child(content)
	return section


func _build_starting_controls() -> void:
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

	var money_label: Label = Label.new()
	money_label.text = "Money"
	currency_row.add_child(money_label)

	_starting_money = SpinBox.new()
	_starting_money.min_value = 0.0
	_starting_money.max_value = 1000000.0
	_starting_money.step = 1.0
	_starting_money.custom_minimum_size = Vector2(86.0, 0.0)
	_starting_money.value_changed.connect(_on_starting_money_changed)
	currency_row.add_child(_starting_money)

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

	var items_label: Label = Label.new()
	items_label.text = "Starting items (any non-weapon item; 0 = none). Uncheck Available to hide a buildable from the toolbuild vertical menu."
	items_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_starting_controls.add_child(items_label)

	# One item per row: Available checkbox | item name | starting quantity.
	_starting_items_box = GridContainer.new()
	_starting_items_box.columns = 3
	_starting_controls.add_child(_starting_items_box)

	var available_header: Label = Label.new()
	available_header.text = "Available"
	available_header.custom_minimum_size = Vector2(80.0, 0.0)
	_starting_items_box.add_child(available_header)
	var item_header: Label = Label.new()
	item_header.text = "Item"
	item_header.custom_minimum_size = Vector2(140.0, 0.0)
	_starting_items_box.add_child(item_header)
	var quantity_header: Label = Label.new()
	quantity_header.text = "Qty"
	quantity_header.custom_minimum_size = Vector2(74.0, 0.0)
	_starting_items_box.add_child(quantity_header)

	_starting_item_spins.clear()
	_starting_item_available_checks.clear()
	for item_id: StringName in _giveable_starting_item_ids():
		var available_check: CheckBox = CheckBox.new()
		available_check.tooltip_text = "Show %s in the toolbuild vertical menu" % String(item_id)
		available_check.custom_minimum_size = Vector2(80.0, 0.0)
		available_check.toggled.connect(_on_starting_item_available_toggled.bind(item_id))
		_starting_items_box.add_child(available_check)
		_starting_item_available_checks[item_id] = available_check

		var item_label: Label = Label.new()
		item_label.text = _item_display_name(item_id)
		item_label.tooltip_text = String(item_id)
		item_label.custom_minimum_size = Vector2(140.0, 0.0)
		_starting_items_box.add_child(item_label)

		var quantity_spin: SpinBox = SpinBox.new()
		quantity_spin.min_value = 0.0
		quantity_spin.max_value = 9999.0
		quantity_spin.step = 1.0
		quantity_spin.custom_minimum_size = Vector2(74.0, 0.0)
		quantity_spin.value_changed.connect(_on_starting_item_changed.bind(item_id))
		_starting_items_box.add_child(quantity_spin)
		_starting_item_spins[item_id] = quantity_spin


func _build_monster_drop_controls() -> void:
	var row: HBoxContainer = HBoxContainer.new()
	_monster_drop_controls.add_child(row)

	var seed_chance_label: Label = Label.new()
	seed_chance_label.text = "Seed chance"
	seed_chance_label.custom_minimum_size = Vector2(128.0, 0.0)
	row.add_child(seed_chance_label)

	_monster_drop_seed_chance = SpinBox.new()
	_monster_drop_seed_chance.min_value = 0.0
	_monster_drop_seed_chance.max_value = 100.0
	_monster_drop_seed_chance.step = 1.0
	_monster_drop_seed_chance.suffix = "%"
	_monster_drop_seed_chance.custom_minimum_size = Vector2(86.0, 0.0)
	_monster_drop_seed_chance.value_changed.connect(_on_monster_drop_seed_chance_changed)
	row.add_child(_monster_drop_seed_chance)


func _build_shop_controls() -> void:
	var heading: Label = Label.new()
	heading.text = "Tool Shop"
	heading.add_theme_font_size_override("font_size", 15)
	_shop_controls.add_child(heading)
	_build_shop_item_controls(TOOL_SHOP_ITEM_IDS, _tool_shop_available_checkboxes, _tool_shop_price_spins, _tool_shop_day_spins, _on_tool_shop_item_available_toggled, _on_tool_shop_price_changed, _on_tool_shop_day_changed, _tool_shop_growth_price_factor_spins, _on_tool_shop_growth_price_factor_changed)

	var counter_limit_row: HBoxContainer = HBoxContainer.new()
	_shop_controls.add_child(counter_limit_row)

	var counter_limit_label: Label = Label.new()
	counter_limit_label.text = "Rose shop counters"
	counter_limit_label.custom_minimum_size = Vector2(128.0, 0.0)
	counter_limit_row.add_child(counter_limit_label)

	_rose_shop_counter_limit = SpinBox.new()
	_rose_shop_counter_limit.min_value = 1.0
	_rose_shop_counter_limit.max_value = 99.0
	_rose_shop_counter_limit.step = 1.0
	_rose_shop_counter_limit.custom_minimum_size = Vector2(86.0, 0.0)
	_rose_shop_counter_limit.value_changed.connect(_on_rose_shop_counter_limit_changed)
	counter_limit_row.add_child(_rose_shop_counter_limit)

	var merchant_heading: Label = Label.new()
	merchant_heading.text = "Merchent"
	merchant_heading.add_theme_font_size_override("font_size", 15)
	_shop_controls.add_child(merchant_heading)
	_build_shop_item_controls(MERCHANT_ITEM_IDS, _merchant_available_checkboxes, _merchant_price_spins, _merchant_day_spins, _on_merchant_item_available_toggled, _on_merchant_price_changed, _on_merchant_day_changed, {}, Callable())


func _build_shop_item_controls(
	item_ids: Array[StringName],
	available_checkboxes: Dictionary,
	price_spins: Dictionary,
	day_spins: Dictionary,
	toggled_handler: Callable,
	price_handler: Callable,
	day_handler: Callable,
	growth_factor_spins: Dictionary,
	growth_factor_handler: Callable
) -> void:
	var header: HBoxContainer = HBoxContainer.new()
	_shop_controls.add_child(header)
	var available_header: Label = Label.new()
	available_header.text = "Available"
	available_header.custom_minimum_size = Vector2(128.0, 0.0)
	header.add_child(available_header)
	var price_header: Label = Label.new()
	price_header.text = "Price"
	price_header.custom_minimum_size = Vector2(86.0, 0.0)
	header.add_child(price_header)
	var day_header: Label = Label.new()
	day_header.text = "Day"
	day_header.custom_minimum_size = Vector2(70.0, 0.0)
	header.add_child(day_header)
	var currency_header: Label = Label.new()
	currency_header.text = "Currency"
	currency_header.custom_minimum_size = Vector2(86.0, 0.0)
	header.add_child(currency_header)
	if growth_factor_handler.is_valid():
		var growth_factor_header: Label = Label.new()
		growth_factor_header.text = "Growth price factor"
		growth_factor_header.custom_minimum_size = Vector2(132.0, 0.0)
		header.add_child(growth_factor_header)

	available_checkboxes.clear()
	price_spins.clear()
	day_spins.clear()
	growth_factor_spins.clear()
	for item_id: StringName in item_ids:
		var row: HBoxContainer = HBoxContainer.new()
		_shop_controls.add_child(row)

		var checkbox: CheckBox = CheckBox.new()
		checkbox.text = _item_display_name(item_id)
		checkbox.tooltip_text = String(item_id)
		checkbox.custom_minimum_size = Vector2(128.0, 0.0)
		checkbox.toggled.connect(toggled_handler.bind(item_id))
		row.add_child(checkbox)
		available_checkboxes[item_id] = checkbox

		var price_spin: SpinBox = SpinBox.new()
		price_spin.min_value = 0.0
		price_spin.max_value = 1000000.0
		price_spin.step = 1.0
		price_spin.custom_minimum_size = Vector2(86.0, 0.0)
		price_spin.value_changed.connect(price_handler.bind(item_id))
		row.add_child(price_spin)
		price_spins[item_id] = price_spin

		var day_spin: SpinBox = SpinBox.new()
		day_spin.min_value = 1.0
		day_spin.max_value = 999.0
		day_spin.step = 1.0
		day_spin.custom_minimum_size = Vector2(70.0, 0.0)
		day_spin.value_changed.connect(day_handler.bind(item_id))
		row.add_child(day_spin)
		day_spins[item_id] = day_spin

		var currency_label: Label = Label.new()
		currency_label.text = String(ItemCatalog.get_currency(String(item_id)))
		currency_label.custom_minimum_size = Vector2(86.0, 0.0)
		row.add_child(currency_label)

		if growth_factor_handler.is_valid():
			var growth_factor_spin: SpinBox = SpinBox.new()
			growth_factor_spin.min_value = 1.0
			growth_factor_spin.max_value = 100.0
			growth_factor_spin.step = 0.1
			growth_factor_spin.custom_minimum_size = Vector2(132.0, 0.0)
			growth_factor_spin.value_changed.connect(growth_factor_handler.bind(item_id))
			row.add_child(growth_factor_spin)
			growth_factor_spins[item_id] = growth_factor_spin


func _build_reward_controls() -> void:
	_reward_box.add_theme_constant_override("separation", 8)
	_reward_one_time_check = CheckBox.new()
	_reward_one_time_check.text = "One-time only (skip when the night loops)"
	_reward_one_time_check.toggled.connect(_on_reward_one_time_toggled)
	_reward_box.add_child(_reward_one_time_check)

	var amount_grid: GridContainer = GridContainer.new()
	amount_grid.columns = REWARD_CURRENCIES.size()
	amount_grid.add_theme_constant_override("h_separation", 12)
	amount_grid.add_theme_constant_override("v_separation", 4)
	_reward_box.add_child(amount_grid)

	# One fixed field per currency. Leave a currency at 0 to grant nothing of it.
	_reward_amount_spins.clear()
	for currency: String in REWARD_CURRENCIES:
		var field: VBoxContainer = VBoxContainer.new()
		field.custom_minimum_size = Vector2(130.0, 0.0)
		amount_grid.add_child(field)

		var label: Label = Label.new()
		label.text = currency.capitalize()
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		field.add_child(label)

		var amount_spin: SpinBox = SpinBox.new()
		amount_spin.min_value = 0.0
		amount_spin.max_value = 1000000.0
		amount_spin.step = 1.0
		amount_spin.custom_minimum_size = Vector2(130.0, 0.0)
		amount_spin.value_changed.connect(_on_reward_amount_changed.bind(currency))
		field.add_child(amount_spin)
		_reward_amount_spins[currency] = amount_spin


func _build_beautifier_controls(parent: VBoxContainer) -> void:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)

	_water_edges_button = Button.new()
	_water_edges_button.text = "water edges"
	_water_edges_button.tooltip_text = "Rewrite watersources tiles using the pond and ocean-hole water edge atlas tiles."
	_water_edges_button.pressed.connect(_on_water_edges_pressed)
	row.add_child(_water_edges_button)


func _rebuild_reward_controls() -> void:
	var night: NightSpawnPlaylist = _get_selected_night()
	var has_night: bool = night != null
	if _night_clients_spin != null:
		_night_clients_spin.visible = has_night
		if has_night:
			_night_clients_spin.set_value_no_signal(float(night.clients))
	_reward_section.visible = has_night
	if not has_night:
		return
	_reward_one_time_check.set_pressed_no_signal(night.special_reward_one_time)
	for raw_currency: Variant in _reward_amount_spins.keys():
		var currency: String = String(raw_currency)
		var amount_spin: SpinBox = _reward_amount_spins[currency] as SpinBox
		if amount_spin != null:
			amount_spin.set_value_no_signal(float(_reward_amount_for_currency(night, currency)))


func _reward_amount_for_currency(night: NightSpawnPlaylist, currency: String) -> int:
	var total: int = 0
	for reward: NightReward in night.special_rewards:
		if reward != null and String(reward.currency) == currency:
			total += reward.amount
	return total


func _on_reward_one_time_toggled(enabled: bool) -> void:
	if _loading_ui:
		return
	var night: NightSpawnPlaylist = _get_selected_night()
	if night == null:
		return
	night.special_reward_one_time = enabled
	mark_dirty()


func _on_reward_amount_changed(value: float, currency: String) -> void:
	if _loading_ui:
		return
	var night: NightSpawnPlaylist = _get_selected_night()
	if night == null:
		return
	_set_reward_amount(night, currency, maxi(0, int(value)))
	mark_dirty()


func _on_night_clients_changed(value: float) -> void:
	if _loading_ui:
		return
	var night: NightSpawnPlaylist = _get_selected_night()
	if night == null:
		return
	night.clients = maxi(0, int(value))
	mark_dirty()


# Stores a single reward entry per currency: updates the existing one, creates it
# when needed, or drops it entirely when the amount is zero. Also collapses any
# legacy duplicate entries for the same currency into that single entry.
func _set_reward_amount(night: NightSpawnPlaylist, currency: String, amount: int) -> void:
	var existing: NightReward = null
	var rewards: Array[NightReward] = _copy_special_rewards(night)
	var index: int = rewards.size() - 1
	while index >= 0:
		var reward: NightReward = rewards[index]
		if reward != null and String(reward.currency) == currency:
			if existing == null:
				existing = reward
			else:
				rewards.remove_at(index)
		index -= 1
	if amount <= 0:
		if existing != null:
			rewards.erase(existing)
			night.special_rewards = rewards
		return
	if existing == null:
		existing = NightReward.new()
		existing.currency = currency
		rewards.append(existing)
	existing.amount = amount
	night.special_rewards = rewards


func _refresh_levels() -> void:
	var previous_path: String = _current_level_path
	_level_paths.clear()
	_find_level_scenes(LEVELS_DIR)
	_level_paths.sort()
	_level_option.clear()
	_level_option.add_item("Select a level...")
	_level_option.set_item_metadata(0, "")
	for path: String in _level_paths:
		_level_option.add_item(path.get_file().get_basename())
		_level_option.set_item_metadata(_level_option.get_item_count() - 1, path)
	var selected_index: int = 0
	if previous_path != "":
		var previous_level_index: int = _level_paths.find(previous_path)
		if previous_level_index >= 0:
			selected_index = previous_level_index + 1
	if selected_index >= 0 and selected_index < _level_option.get_item_count():
		_level_option.select(selected_index)
		_load_level(str(_level_option.get_item_metadata(selected_index)))
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
		_spawner_nodes[spawner_id] = NodePath(String(node_2d.name))
	_spawner_ids.sort()
	_client_spawner_ids.sort()


func _refresh_all() -> void:
	_loading_ui = true
	_refresh_starting_controls()
	_refresh_monster_drop_controls()
	_refresh_shop_controls()
	_refresh_client_frequency_controls()
	_refresh_beautifier_controls()
	_refresh_nights()
	_rebuild_reward_controls()
	_rebuild_tracks()
	_loading_ui = false
	_refresh_status()
	_refresh_validation()


func _refresh_status() -> void:
	_status_hide_token += 1
	_dirty_label.text = "Unsaved changes" if _dirty else "Saved"
	_dirty_label.modulate = Color(1.0, 0.72, 0.2) if _dirty else Color(0.65, 0.9, 0.65)
	_dirty_label.visible = true
	var playlist_path: String = _playlist.resource_path if _playlist != null else "<none>"
	_playlist_label.text = "Level: %s\nPlaylist: %s" % [_current_level_path, playlist_path]
	_save_button.disabled = _current_level_path == ""
	_create_button.disabled = _current_level_path == ""
	if not _dirty:
		_hide_saved_status_after_delay(_status_hide_token)


func _refresh_beautifier_controls() -> void:
	var has_level: bool = _current_level_path != "" and _level_root != null
	_beautifier_section.visible = has_level
	_water_edges_button.disabled = not has_level


func _hide_saved_status_after_delay(token: int) -> void:
	await get_tree().create_timer(2.0).timeout
	if token == _status_hide_token and not _dirty:
		_dirty_label.visible = false


func _refresh_starting_controls() -> void:
	var config: LevelSpawnConfig = _get_level_config(_level_root)
	var has_level: bool = _current_level_path != ""
	_starting_section.visible = has_level
	_starting_seeds.editable = has_level
	_starting_gems.editable = has_level
	_starting_money.editable = has_level
	var seeds: int = DEFAULT_STARTING_SEEDS
	var gems: int = DEFAULT_STARTING_GEMS
	var money: int = DEFAULT_STARTING_MONEY
	var weapons: Array[StringName] = _default_starting_weapons()
	if config != null:
		seeds = config.starting_seeds
		gems = config.starting_gems
		money = config.starting_money
		weapons = _valid_weapon_ids(config.starting_weapons)
	_starting_seeds.value = float(seeds)
	_starting_gems.value = float(gems)
	_starting_money.value = float(money)
	for raw_weapon_id: Variant in _weapon_checkboxes.keys():
		var weapon_id: StringName = raw_weapon_id as StringName
		var checkbox: CheckBox = _weapon_checkboxes[weapon_id] as CheckBox
		if checkbox != null:
			checkbox.button_pressed = weapons.has(weapon_id)
			checkbox.disabled = not has_level
	var starting_items: Dictionary = config.starting_items if config != null else {}
	for raw_item_id: Variant in _starting_item_spins.keys():
		var item_id: StringName = raw_item_id as StringName
		var quantity_spin: SpinBox = _starting_item_spins[item_id] as SpinBox
		if quantity_spin != null:
			quantity_spin.value = float(_starting_item_quantity(starting_items, item_id))
			quantity_spin.editable = has_level
	var hidden_items: Array = config.starting_item_toolbuild_hidden if config != null else []
	for raw_item_id: Variant in _starting_item_available_checks.keys():
		var item_id: StringName = raw_item_id as StringName
		var available_check: CheckBox = _starting_item_available_checks[item_id] as CheckBox
		if available_check != null:
			available_check.button_pressed = not _toolbuild_hidden_has(hidden_items, item_id)
			available_check.disabled = not has_level


func _refresh_monster_drop_controls() -> void:
	var config: LevelSpawnConfig = _get_level_config(_level_root)
	var has_level: bool = _current_level_path != ""
	_monster_drop_section.visible = has_level
	_monster_drop_seed_chance.editable = has_level
	var seed_chance_percent: int = DEFAULT_MONSTER_DROP_SEED_CHANCE_PERCENT
	if config != null:
		seed_chance_percent = clampi(config.monster_drop_seed_chance_percent, 0, 100)
	_monster_drop_seed_chance.value = float(seed_chance_percent)


func _refresh_shop_controls() -> void:
	var config: LevelSpawnConfig = _get_level_config(_level_root)
	var has_level: bool = _current_level_path != ""
	_shop_section.visible = has_level
	_rose_shop_counter_limit.editable = has_level
	var tool_available_items: Array[StringName] = _default_tool_shop_available_items()
	var tool_prices: Dictionary = _default_tool_shop_prices()
	var tool_days: Dictionary = {}
	var tool_growth_price_factors: Dictionary = _default_tool_shop_growth_price_factors()
	var merchant_available_items: Array[StringName] = _default_merchant_available_items()
	var merchant_prices: Dictionary = _default_merchant_prices()
	var merchant_days: Dictionary = {}
	var counter_limit: int = 2
	if config != null:
		tool_available_items = _valid_tool_shop_available_items(config.tool_shop_available_items)
		tool_prices = _valid_tool_shop_prices(config.tool_shop_prices)
		tool_days = _valid_tool_shop_days(config.tool_shop_days)
		tool_growth_price_factors = _valid_tool_shop_growth_price_factors(config.tool_shop_growth_price_factors)
		merchant_available_items = _valid_merchant_available_items(config.merchant_available_items)
		merchant_prices = _valid_merchant_prices(config.merchant_prices)
		merchant_days = _valid_merchant_days(config.merchant_days)
		var legacy_available_items: Array[StringName] = _valid_legacy_shop_available_items(config.shop_available_items)
		var legacy_prices: Dictionary = _valid_legacy_shop_prices(config.shop_prices)
		if not _same_string_name_array(legacy_available_items, _default_legacy_shop_available_items()):
			if _same_string_name_array(tool_available_items, _default_tool_shop_available_items()):
				tool_available_items = _valid_tool_shop_available_items(legacy_available_items)
			if _same_string_name_array(merchant_available_items, _default_merchant_available_items()):
				merchant_available_items = _valid_merchant_available_items(legacy_available_items)
		if legacy_prices != _default_legacy_shop_prices():
			if tool_prices == _default_tool_shop_prices():
				tool_prices = _valid_tool_shop_prices(legacy_prices)
			if merchant_prices == _default_merchant_prices():
				merchant_prices = _valid_merchant_prices(legacy_prices)
		counter_limit = clampi(config.rose_shop_counter_limit, 1, 99)
	_refresh_shop_item_controls(_tool_shop_available_checkboxes, _tool_shop_price_spins, _tool_shop_day_spins, tool_available_items, tool_prices, tool_days, has_level, _tool_shop_growth_price_factor_spins, tool_growth_price_factors)
	_refresh_shop_item_controls(_merchant_available_checkboxes, _merchant_price_spins, _merchant_day_spins, merchant_available_items, merchant_prices, merchant_days, has_level, {}, {})
	_rose_shop_counter_limit.value = float(counter_limit)


func _refresh_shop_item_controls(
	available_checkboxes: Dictionary,
	price_spins: Dictionary,
	day_spins: Dictionary,
	available_items: Array[StringName],
	prices: Dictionary,
	days: Dictionary,
	has_level: bool,
	growth_factor_spins: Dictionary,
	growth_price_factors: Dictionary
) -> void:
	for raw_item_id: Variant in available_checkboxes.keys():
		var item_id: StringName = raw_item_id as StringName
		var checkbox: CheckBox = available_checkboxes[item_id] as CheckBox
		if checkbox != null:
			checkbox.button_pressed = available_items.has(item_id)
			checkbox.disabled = not has_level
	for raw_item_id: Variant in price_spins.keys():
		var item_id: StringName = raw_item_id as StringName
		var price_spin: SpinBox = price_spins[item_id] as SpinBox
		if price_spin != null:
			price_spin.value = float(int(prices.get(item_id, ItemCatalog.get_price(String(item_id)))))
			price_spin.editable = has_level
	for raw_item_id: Variant in day_spins.keys():
		var item_id: StringName = raw_item_id as StringName
		var day_spin: SpinBox = day_spins[item_id] as SpinBox
		if day_spin != null:
			day_spin.value = float(int(days.get(item_id, 1)))
			day_spin.editable = has_level
	for raw_item_id: Variant in growth_factor_spins.keys():
		var item_id: StringName = raw_item_id as StringName
		var growth_factor_spin: SpinBox = growth_factor_spins[item_id] as SpinBox
		if growth_factor_spin != null:
			growth_factor_spin.value = float(growth_price_factors.get(item_id, 1.0))
			growth_factor_spin.editable = has_level


func _refresh_client_frequency_controls() -> void:
	for child: Node in _client_frequency_box.get_children():
		child.queue_free()
	var has_level: bool = _current_level_path != ""
	_client_frequency_section.visible = has_level and not _client_spawner_ids.is_empty()
	if not _client_frequency_section.visible:
		return
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
		var nights: Array[NightSpawnPlaylist] = [NightSpawnPlaylist.new()]
		_playlist.nights = nights
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
	var margin: MarginContainer = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	panel.add_child(margin)

	var outer: VBoxContainer = VBoxContainer.new()
	outer.size_flags_horizontal = SIZE_EXPAND_FILL
	outer.add_theme_constant_override("separation", 6)
	margin.add_child(outer)

	var header: HBoxContainer = HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	outer.add_child(header)

	var title: Label = Label.new()
	title.text = String(spawner_id)
	title.add_theme_font_size_override("font_size", 15)
	title.size_flags_horizontal = SIZE_EXPAND_FILL
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(title)

	var focus_button: Button = Button.new()
	focus_button.text = "Focus"
	focus_button.pressed.connect(_focus_spawner.bind(spawner_id))
	header.add_child(focus_button)

	var track: SpawnerWaveTrack = _get_track(spawner_id)
	if track == null:
		var inactive: Label = Label.new()
		inactive.text = "Inactive this night"
		inactive.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
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
	labels.add_theme_constant_override("separation", 6)
	outer.add_child(labels)
	_add_wave_header_label(labels, "", WAVE_MOVE_WIDTH, false)
	_add_wave_header_label(labels, "#", WAVE_NUMBER_WIDTH, false)
	_add_wave_header_label(labels, "Type", WAVE_TYPE_WIDTH, false)
	_add_wave_header_label(labels, "Count", WAVE_COUNT_WIDTH, false)
	_add_wave_header_label(labels, "Interval", WAVE_TIME_WIDTH, false)
	_add_wave_header_label(labels, "Wait Event", WAVE_EVENT_WIDTH, true)
	_add_wave_header_label(labels, "Emit Event", WAVE_EVENT_WIDTH, true)
	_add_wave_header_label(labels, "Emit Delay", WAVE_TIME_WIDTH, false)
	_add_wave_header_label(labels, "", WAVE_DELETE_WIDTH, false)

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


func _add_wave_header_label(labels: HBoxContainer, text: String, width: float, expand: bool) -> void:
	var label: Label = Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(width, 0.0)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if text == "#":
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	if expand:
		label.size_flags_horizontal = SIZE_EXPAND_FILL
	labels.add_child(label)


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
	_rebuild_reward_controls()
	_rebuild_tracks()


func _on_create_playlist_pressed() -> void:
	if _current_level_path == "":
		return
	if _playlist == null:
		_playlist = LevelSpawnPlaylist.new()
		var nights: Array[NightSpawnPlaylist] = [NightSpawnPlaylist.new()]
		_playlist.nights = nights
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


# Saves the current playlist and level scene. Saves even when validation reports
# errors so explicit Save never silently drops an edit; the validation panel still
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


func _on_save_pressed() -> void:
	var saved: bool = _save()
	_refresh_status()
	if saved:
		_refresh_validation()


func _on_open_level_pressed() -> void:
	if _current_level_path == "" or editor_plugin == null:
		return
	editor_plugin.get_editor_interface().open_scene_from_path(_current_level_path)


func _on_water_edges_pressed() -> void:
	if _current_level_path == "" or _level_root == null:
		return
	var level_root: Node = _current_editable_level_root()
	var watersources: TileMapLayer = level_root.get_node_or_null("watersources") as TileMapLayer
	if watersources == null:
		_show_save_error("Level has no watersources TileMapLayer", ERR_DOES_NOT_EXIST)
		return
	var changed_count: int = _beautify_water_edges(watersources)
	var floor_layer: TileMapLayer = level_root.get_node_or_null("floor") as TileMapLayer
	var floor_result: Dictionary = _reconcile_floor_with_water(floor_layer, watersources) if floor_layer != null else {}
	if not _save_level_scene(level_root):
		return
	if level_root != _level_root:
		_reload_cached_level_root()
	_validation_label.clear()
	_validation_label.append_text("[color=light_green]Water edges updated: %d tile%s.[/color]" % [changed_count, "" if changed_count == 1 else "s"])
	if floor_layer == null:
		_validation_label.append_text("\n[color=yellow]No floor TileMapLayer found; skipped floor cleanup.[/color]")
	else:
		var cleared_count: int = int(floor_result.get("cleared", 0))
		var filled_count: int = int(floor_result.get("filled", 0))
		_validation_label.append_text("\n[color=light_green]Floor tiles removed under water: %d tile%s.[/color]" % [cleared_count, "" if cleared_count == 1 else "s"])
		_validation_label.append_text("\n[color=light_green]Floor tiles restored off water: %d tile%s.[/color]" % [filled_count, "" if filled_count == 1 else "s"])


func _current_editable_level_root() -> Node:
	if editor_plugin != null:
		var edited_root: Node = editor_plugin.get_editor_interface().get_edited_scene_root()
		if edited_root != null and edited_root.scene_file_path == _current_level_path:
			return edited_root
	return _level_root


func _reload_cached_level_root() -> void:
	if _level_root != null:
		_level_root.free()
		_level_root = null
	var packed: PackedScene = load(_current_level_path) as PackedScene
	if packed == null:
		return
	_spawner_ids.clear()
	_client_spawner_ids.clear()
	_spawner_nodes.clear()
	_duplicate_spawner_ids.clear()
	_level_root = packed.instantiate()
	_capture_spawners()


func _beautify_water_edges(watersources: TileMapLayer) -> int:
	var water_cells: Dictionary = {}
	var used_cells: Array[Vector2i] = []
	for cell: Vector2i in watersources.get_used_cells():
		if watersources.get_cell_source_id(cell) < 0:
			continue
		used_cells.append(cell)
		water_cells[cell] = true

	var replacement_atlas_coords: Dictionary = {}
	for cell: Vector2i in used_cells:
		var atlas_coords: Vector2i = _water_edge_atlas_for_cell(cell, water_cells)
		if watersources.get_cell_atlas_coords(cell) != atlas_coords:
			replacement_atlas_coords[cell] = atlas_coords

	for raw_cell: Variant in replacement_atlas_coords.keys():
		var cell: Vector2i = Vector2i(raw_cell)
		var atlas_coords: Vector2i = Vector2i(replacement_atlas_coords[cell])
		var source_id: int = watersources.get_cell_source_id(cell)
		var alternative_tile: int = watersources.get_cell_alternative_tile(cell)
		watersources.set_cell(cell, source_id, atlas_coords, alternative_tile)
	return replacement_atlas_coords.size()


# Enforces the floor/water invariant across the combined floor+water region: every
# cell with a watersources tile has its floor cleared (water is never layered on top
# of ground), and every cell without water gets a dry-ground floor tile if it has
# none (restoring floor where water was deleted). Returns {"cleared": int, "filled": int}.
func _reconcile_floor_with_water(floor_layer: TileMapLayer, watersources: TileMapLayer) -> Dictionary:
	var water_cells: Dictionary = {}
	for cell: Vector2i in watersources.get_used_cells():
		if watersources.get_cell_source_id(cell) < 0:
			continue
		water_cells[cell] = true

	# Region to reconcile = bounding rect of every floor and water tile. Cells where
	# water was deleted are now empty on both layers, so they only fall inside this
	# rect (not in either used-cell list); walking the rect is what recovers them.
	var region: Rect2i = _combined_used_rect(floor_layer, watersources)
	if region.size == Vector2i.ZERO:
		return {"cleared": 0, "filled": 0}

	# Floor source/alternative to paint with: sampled from an existing floor tile so we
	# match whatever tileset the level uses. Without one we cannot author floor tiles.
	var floor_source_id: int = -1
	var floor_alternative_tile: int = 0
	var floor_used: Array[Vector2i] = floor_layer.get_used_cells()
	if not floor_used.is_empty():
		var sample_cell: Vector2i = floor_used[0]
		floor_source_id = floor_layer.get_cell_source_id(sample_cell)
		floor_alternative_tile = floor_layer.get_cell_alternative_tile(sample_cell)

	var dry_ground_atlas: Vector2i = FLOOR_TILE_CATALOG.DRY_GROUND_FLOOR_ATLAS
	var cleared_count: int = 0
	var filled_count: int = 0
	for y: int in range(region.position.y, region.position.y + region.size.y):
		for x: int in range(region.position.x, region.position.x + region.size.x):
			var cell: Vector2i = Vector2i(x, y)
			if water_cells.has(cell):
				if floor_layer.get_cell_source_id(cell) >= 0:
					floor_layer.erase_cell(cell)
					cleared_count += 1
				continue
			if floor_layer.get_cell_source_id(cell) >= 0:
				continue
			if floor_source_id < 0:
				continue
			floor_layer.set_cell(cell, floor_source_id, dry_ground_atlas, floor_alternative_tile)
			filled_count += 1
	return {"cleared": cleared_count, "filled": filled_count}


# Bounding rectangle (inclusive of the far edge) enclosing every used cell across the
# floor and watersources layers. Zero-size when both layers are empty.
func _combined_used_rect(floor_layer: TileMapLayer, watersources: TileMapLayer) -> Rect2i:
	var has_any: bool = false
	var min_cell: Vector2i = Vector2i.ZERO
	var max_cell: Vector2i = Vector2i.ZERO
	for layer: TileMapLayer in [floor_layer, watersources]:
		for cell: Vector2i in layer.get_used_cells():
			if layer.get_cell_source_id(cell) < 0:
				continue
			if not has_any:
				min_cell = cell
				max_cell = cell
				has_any = true
				continue
			min_cell.x = mini(min_cell.x, cell.x)
			min_cell.y = mini(min_cell.y, cell.y)
			max_cell.x = maxi(max_cell.x, cell.x)
			max_cell.y = maxi(max_cell.y, cell.y)
	if not has_any:
		return Rect2i()
	return Rect2i(min_cell, max_cell - min_cell + Vector2i.ONE)


func _water_edge_atlas_for_cell(cell: Vector2i, water_cells: Dictionary) -> Vector2i:
	if _is_water_surrounded_by_ground(cell, water_cells):
		return WATER_ISOLATED_ATLAS
	var river_atlas_coords: Vector2i = _river_atlas_for_cell(cell, water_cells)
	if river_atlas_coords != Vector2i(-1, -1):
		return river_atlas_coords
	var ocean_hole_atlas_coords: Vector2i = _ocean_hole_atlas_for_cell(cell, water_cells)
	if ocean_hole_atlas_coords != Vector2i(-1, -1):
		return ocean_hole_atlas_coords
	var pond_atlas_coords: Vector2i = _pond_atlas_for_cell(cell, water_cells)
	if pond_atlas_coords != WATER_POND_ATLAS_ORIGIN + Vector2i(1, 1):
		return pond_atlas_coords
	var diagonal_ground_atlas_coords: Vector2i = _diagonal_ground_atlas_for_cell(cell, water_cells)
	if diagonal_ground_atlas_coords != Vector2i(-1, -1):
		return diagonal_ground_atlas_coords
	return pond_atlas_coords


func _is_water_surrounded_by_ground(cell: Vector2i, water_cells: Dictionary) -> bool:
	for offset: Vector2i in WATER_NEIGHBOR_OFFSETS:
		if water_cells.has(cell + offset):
			return false
	return true


func _river_atlas_for_cell(cell: Vector2i, water_cells: Dictionary) -> Vector2i:
	var has_north: bool = water_cells.has(cell + Vector2i(0, -1))
	var has_west: bool = water_cells.has(cell + Vector2i(-1, 0))
	var has_east: bool = water_cells.has(cell + Vector2i(1, 0))
	var has_south: bool = water_cells.has(cell + Vector2i(0, 1))
	if has_north or has_south:
		if not has_west and not has_east:
			if not has_north and has_south:
				return WATER_VERTICAL_RIVER_TOP_EDGE_ATLAS
			if has_north and not has_south:
				return WATER_VERTICAL_RIVER_BOTTOM_EDGE_ATLAS
			if has_north and has_south:
				return WATER_VERTICAL_RIVER_ATLAS
	else:
		if not has_west and has_east:
			return WATER_HORIZONTAL_RIVER_LEFT_EDGE_ATLAS
		if has_west and not has_east:
			return WATER_HORIZONTAL_RIVER_RIGHT_EDGE_ATLAS
		if has_west and has_east:
			return WATER_HORIZONTAL_RIVER_ATLAS
	return Vector2i(-1, -1)


func _ocean_hole_atlas_for_cell(cell: Vector2i, water_cells: Dictionary) -> Vector2i:
	for offset: Vector2i in WATER_NEIGHBOR_OFFSETS:
		var ground_cell: Vector2i = cell - offset
		if _is_single_tile_ground_hole(ground_cell, water_cells):
			return WATER_OCEAN_HOLE_ATLAS_CENTER + offset
	return Vector2i(-1, -1)


func _is_single_tile_ground_hole(ground_cell: Vector2i, water_cells: Dictionary) -> bool:
	if water_cells.has(ground_cell):
		return false
	for offset: Vector2i in WATER_NEIGHBOR_OFFSETS:
		if not water_cells.has(ground_cell + offset):
			return false
	return true


func _diagonal_ground_atlas_for_cell(cell: Vector2i, water_cells: Dictionary) -> Vector2i:
	if not water_cells.has(cell + Vector2i(0, -1)):
		return Vector2i(-1, -1)
	if not water_cells.has(cell + Vector2i(-1, 0)):
		return Vector2i(-1, -1)
	if not water_cells.has(cell + Vector2i(1, 0)):
		return Vector2i(-1, -1)
	if not water_cells.has(cell + Vector2i(0, 1)):
		return Vector2i(-1, -1)
	if not water_cells.has(cell + Vector2i(-1, -1)):
		return WATER_DIAGONAL_GROUND_TOP_LEFT_ATLAS
	if not water_cells.has(cell + Vector2i(1, -1)):
		return WATER_DIAGONAL_GROUND_TOP_RIGHT_ATLAS
	if not water_cells.has(cell + Vector2i(-1, 1)):
		return WATER_DIAGONAL_GROUND_BOTTOM_LEFT_ATLAS
	if not water_cells.has(cell + Vector2i(1, 1)):
		return WATER_DIAGONAL_GROUND_BOTTOM_RIGHT_ATLAS
	return Vector2i(-1, -1)


func _pond_atlas_for_cell(cell: Vector2i, water_cells: Dictionary) -> Vector2i:
	var has_north: bool = water_cells.has(cell + Vector2i(0, -1))
	var has_west: bool = water_cells.has(cell + Vector2i(-1, 0))
	var has_east: bool = water_cells.has(cell + Vector2i(1, 0))
	var has_south: bool = water_cells.has(cell + Vector2i(0, 1))
	var atlas_column: int = 1
	var atlas_row: int = 1
	if not has_west:
		atlas_column = 0
	elif not has_east:
		atlas_column = 2
	if not has_north:
		atlas_row = 0
	elif not has_south:
		atlas_row = 2
	return WATER_POND_ATLAS_ORIGIN + Vector2i(atlas_column, atlas_row)


func _save_level_scene(level_root: Node) -> bool:
	var new_scene: PackedScene = PackedScene.new()
	var pack_error: Error = new_scene.pack(level_root)
	if pack_error != OK:
		_show_save_error("Could not pack level scene", pack_error)
		return false
	var save_error: Error = ResourceSaver.save(new_scene, _current_level_path)
	if save_error != OK:
		_show_save_error("Could not save level scene", save_error)
		return false
	return true


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


func _on_starting_money_changed(value: float) -> void:
	if _loading_ui:
		return
	var config: LevelSpawnConfig = _get_or_create_loaded_level_config()
	if config == null:
		return
	config.starting_money = int(value)
	mark_dirty()


func _on_monster_drop_seed_chance_changed(value: float) -> void:
	if _loading_ui:
		return
	var config: LevelSpawnConfig = _get_or_create_loaded_level_config()
	if config == null:
		return
	config.monster_drop_seed_chance_percent = clampi(int(value), 0, 100)
	mark_dirty()


func _on_rose_shop_counter_limit_changed(value: float) -> void:
	if _loading_ui:
		return
	var config: LevelSpawnConfig = _get_or_create_loaded_level_config()
	if config == null:
		return
	config.rose_shop_counter_limit = clampi(int(value), 1, 99)
	mark_dirty()


func _on_tool_shop_item_available_toggled(enabled: bool, item_id: StringName) -> void:
	if _loading_ui:
		return
	var config: LevelSpawnConfig = _get_or_create_loaded_level_config()
	if config == null:
		return
	var available_items: Array[StringName] = _valid_tool_shop_available_items(config.tool_shop_available_items)
	if enabled:
		if not available_items.has(item_id):
			available_items.append(item_id)
	else:
		var index: int = available_items.find(item_id)
		if index >= 0:
			available_items.remove_at(index)
	config.tool_shop_available_items = available_items
	config.shop_available_items = _selected_legacy_shop_available_items()
	mark_dirty()


func _on_tool_shop_price_changed(value: float, item_id: StringName) -> void:
	if _loading_ui:
		return
	var config: LevelSpawnConfig = _get_or_create_loaded_level_config()
	if config == null:
		return
	var prices: Dictionary = _valid_tool_shop_prices(config.tool_shop_prices)
	prices[item_id] = maxi(0, int(value))
	config.tool_shop_prices = prices
	config.shop_prices = _selected_legacy_shop_prices()
	mark_dirty()


func _on_tool_shop_day_changed(value: float, item_id: StringName) -> void:
	if _loading_ui:
		return
	var config: LevelSpawnConfig = _get_or_create_loaded_level_config()
	if config == null:
		return
	var days: Dictionary = _valid_tool_shop_days(config.tool_shop_days)
	var day: int = maxi(1, int(value))
	if day > 1:
		days[item_id] = day
	else:
		days.erase(item_id)
	config.tool_shop_days = days
	mark_dirty()


func _on_tool_shop_growth_price_factor_changed(value: float, item_id: StringName) -> void:
	if _loading_ui:
		return
	var config: LevelSpawnConfig = _get_or_create_loaded_level_config()
	if config == null:
		return
	var growth_price_factors: Dictionary = _valid_tool_shop_growth_price_factors(config.tool_shop_growth_price_factors)
	var factor: float = maxf(1.0, value)
	if factor > 1.0:
		growth_price_factors[item_id] = factor
	else:
		growth_price_factors.erase(item_id)
	config.tool_shop_growth_price_factors = growth_price_factors
	mark_dirty()


func _on_merchant_item_available_toggled(enabled: bool, item_id: StringName) -> void:
	if _loading_ui:
		return
	var config: LevelSpawnConfig = _get_or_create_loaded_level_config()
	if config == null:
		return
	var available_items: Array[StringName] = _valid_merchant_available_items(config.merchant_available_items)
	if enabled:
		if not available_items.has(item_id):
			available_items.append(item_id)
	else:
		var index: int = available_items.find(item_id)
		if index >= 0:
			available_items.remove_at(index)
	config.merchant_available_items = available_items
	config.shop_available_items = _selected_legacy_shop_available_items()
	mark_dirty()


func _on_merchant_price_changed(value: float, item_id: StringName) -> void:
	if _loading_ui:
		return
	var config: LevelSpawnConfig = _get_or_create_loaded_level_config()
	if config == null:
		return
	var prices: Dictionary = _valid_merchant_prices(config.merchant_prices)
	prices[item_id] = maxi(0, int(value))
	config.merchant_prices = prices
	config.shop_prices = _selected_legacy_shop_prices()
	mark_dirty()


func _on_merchant_day_changed(value: float, item_id: StringName) -> void:
	if _loading_ui:
		return
	var config: LevelSpawnConfig = _get_or_create_loaded_level_config()
	if config == null:
		return
	var days: Dictionary = _valid_merchant_days(config.merchant_days)
	var day: int = maxi(1, int(value))
	if day > 1:
		days[item_id] = day
	else:
		days.erase(item_id)
	config.merchant_days = days
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


func _on_starting_item_changed(value: float, item_id: StringName) -> void:
	if _loading_ui:
		return
	var config: LevelSpawnConfig = _get_or_create_loaded_level_config()
	if config == null:
		return
	var items: Dictionary = config.starting_items.duplicate()
	# Drop any legacy String-keyed duplicate so the StringName key is authoritative.
	items.erase(String(item_id))
	var quantity: int = maxi(0, int(value))
	if quantity > 0:
		items[item_id] = quantity
	else:
		items.erase(item_id)
	config.starting_items = items
	mark_dirty()


func _on_starting_item_available_toggled(_enabled: bool, _item_id: StringName) -> void:
	if _loading_ui:
		return
	var config: LevelSpawnConfig = _get_or_create_loaded_level_config()
	if config == null:
		return
	config.starting_item_toolbuild_hidden = _selected_starting_item_hidden()
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
	var nights: Array[NightSpawnPlaylist] = _copy_nights(_playlist)
	nights.append(NightSpawnPlaylist.new())
	_playlist.nights = nights
	_selected_night_index = nights.size() - 1
	mark_dirty()
	_refresh_all()


func _on_duplicate_night_pressed() -> void:
	var night: NightSpawnPlaylist = _get_selected_night()
	if _playlist == null or night == null:
		return
	var duplicate: NightSpawnPlaylist = night.duplicate(true) as NightSpawnPlaylist
	var nights: Array[NightSpawnPlaylist] = _copy_nights(_playlist)
	nights.insert(_selected_night_index + 1, duplicate)
	_playlist.nights = nights
	_selected_night_index += 1
	mark_dirty()
	_refresh_all()


func _on_delete_night_pressed() -> void:
	if _playlist == null or _playlist.nights.is_empty():
		return
	var nights: Array[NightSpawnPlaylist] = _copy_nights(_playlist)
	nights.remove_at(_selected_night_index)
	if nights.is_empty():
		nights.append(NightSpawnPlaylist.new())
	_playlist.nights = nights
	_selected_night_index = clampi(_selected_night_index, 0, nights.size() - 1)
	mark_dirty()
	_refresh_all()


func _enable_track(spawner_id: StringName) -> void:
	var night: NightSpawnPlaylist = _get_selected_night()
	if night == null or _get_track(spawner_id) != null:
		return
	var track: SpawnerWaveTrack = SpawnerWaveTrack.new()
	track.spawner_id = spawner_id
	var tracks: Array[SpawnerWaveTrack] = _copy_spawner_tracks(night)
	tracks.append(track)
	night.spawner_tracks = tracks
	mark_dirty()
	_rebuild_tracks()


func _disable_track(spawner_id: StringName) -> void:
	var night: NightSpawnPlaylist = _get_selected_night()
	if night == null:
		return
	var index: int = _get_track_index(spawner_id)
	if index < 0:
		return
	var tracks: Array[SpawnerWaveTrack] = _copy_spawner_tracks(night)
	tracks.remove_at(index)
	night.spawner_tracks = tracks
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
	var waves: Array[SpawnWave] = _copy_waves(track)
	waves.append(wave)
	track.waves = waves
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
	var container: Node = _find_spawner_container(_level_root)
	if container == null:
		return null
	var node_path: NodePath = _spawner_nodes[spawner_id] as NodePath
	return container.get_node_or_null(node_path)


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
		root.set("starting_money", int(_starting_money.value))
		root.set("starting_weapons", _selected_starting_weapons())
		root.set("starting_items", _selected_starting_items())
		root.set("starting_item_toolbuild_hidden", _selected_starting_item_hidden())
		root.set("monster_drop_seed_chance_percent", clampi(int(_monster_drop_seed_chance.value), 0, 100))
		root.set("tool_shop_available_items", _selected_tool_shop_available_items())
		root.set("tool_shop_prices", _selected_tool_shop_prices())
		root.set("tool_shop_growth_price_factors", _selected_tool_shop_growth_price_factors())
		root.set("tool_shop_days", _selected_tool_shop_days())
		root.set("merchant_available_items", _selected_merchant_available_items())
		root.set("merchant_prices", _selected_merchant_prices())
		root.set("merchant_days", _selected_merchant_days())
		root.set("shop_available_items", _selected_legacy_shop_available_items())
		root.set("shop_prices", _selected_legacy_shop_prices())
		root.set("rose_shop_counter_limit", clampi(int(_rose_shop_counter_limit.value), 1, 99))
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
	config.starting_money = int(_starting_money.value)
	config.starting_weapons = _selected_starting_weapons()
	config.starting_items = _selected_starting_items()
	config.starting_item_toolbuild_hidden = _selected_starting_item_hidden()
	config.monster_drop_seed_chance_percent = clampi(int(_monster_drop_seed_chance.value), 0, 100)
	config.tool_shop_available_items = _selected_tool_shop_available_items()
	config.tool_shop_prices = _selected_tool_shop_prices()
	config.tool_shop_growth_price_factors = _selected_tool_shop_growth_price_factors()
	config.tool_shop_days = _selected_tool_shop_days()
	config.merchant_available_items = _selected_merchant_available_items()
	config.merchant_prices = _selected_merchant_prices()
	config.merchant_days = _selected_merchant_days()
	config.shop_available_items = _selected_legacy_shop_available_items()
	config.shop_prices = _selected_legacy_shop_prices()
	config.rose_shop_counter_limit = clampi(int(_rose_shop_counter_limit.value), 1, 99)


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
		config.starting_money = DEFAULT_STARTING_MONEY
		config.starting_weapons = _default_starting_weapons()
		config.starting_items = {}
		config.starting_item_toolbuild_hidden = []
		config.monster_drop_seed_chance_percent = DEFAULT_MONSTER_DROP_SEED_CHANCE_PERCENT
		config.tool_shop_available_items = _default_tool_shop_available_items()
		config.tool_shop_prices = _default_tool_shop_prices()
		config.tool_shop_growth_price_factors = _default_tool_shop_growth_price_factors()
		config.tool_shop_days = {}
		config.merchant_available_items = _default_merchant_available_items()
		config.merchant_prices = _default_merchant_prices()
		config.merchant_days = {}
		config.shop_available_items = _default_legacy_shop_available_items()
		config.shop_prices = _default_legacy_shop_prices()
		config.rose_shop_counter_limit = 2
	return config


func _copy_nights(playlist: LevelSpawnPlaylist) -> Array[NightSpawnPlaylist]:
	var nights: Array[NightSpawnPlaylist] = []
	if playlist == null:
		return nights
	for night: NightSpawnPlaylist in playlist.nights:
		nights.append(night)
	return nights


func _copy_spawner_tracks(night: NightSpawnPlaylist) -> Array[SpawnerWaveTrack]:
	var tracks: Array[SpawnerWaveTrack] = []
	if night == null:
		return tracks
	for track: SpawnerWaveTrack in night.spawner_tracks:
		tracks.append(track)
	return tracks


func _copy_waves(track: SpawnerWaveTrack) -> Array[SpawnWave]:
	var waves: Array[SpawnWave] = []
	if track == null:
		return waves
	for wave: SpawnWave in track.waves:
		waves.append(wave)
	return waves


func _copy_special_rewards(night: NightSpawnPlaylist) -> Array[NightReward]:
	var rewards: Array[NightReward] = []
	if night == null:
		return rewards
	for reward: NightReward in night.special_rewards:
		rewards.append(reward)
	return rewards


func _selected_starting_weapons() -> Array[StringName]:
	var weapons: Array[StringName] = []
	for raw_weapon_id: Variant in _weapon_checkboxes.keys():
		var weapon_id: StringName = raw_weapon_id as StringName
		var checkbox: CheckBox = _weapon_checkboxes[weapon_id] as CheckBox
		if checkbox != null and checkbox.button_pressed:
			weapons.append(weapon_id)
	return weapons


func _selected_starting_items() -> Dictionary:
	var items: Dictionary = {}
	for raw_item_id: Variant in _starting_item_spins.keys():
		var item_id: StringName = raw_item_id as StringName
		var quantity_spin: SpinBox = _starting_item_spins[item_id] as SpinBox
		if quantity_spin == null:
			continue
		var quantity: int = maxi(0, int(quantity_spin.value))
		if quantity > 0:
			items[item_id] = quantity
	return items


## Item ids whose "Available" box is unchecked: they are hidden from the toolbuild vertical
## menu. Empty means every buildable stays available.
func _selected_starting_item_hidden() -> Array[StringName]:
	var hidden: Array[StringName] = []
	for raw_item_id: Variant in _starting_item_available_checks.keys():
		var item_id: StringName = raw_item_id as StringName
		var available_check: CheckBox = _starting_item_available_checks[item_id] as CheckBox
		if available_check != null and not available_check.button_pressed:
			hidden.append(item_id)
	return hidden


## Membership test for an authored hidden-items list, tolerating either a StringName or a
## String entry (as tscn / hand edits may produce).
func _toolbuild_hidden_has(hidden_items: Array, item_id: StringName) -> bool:
	return hidden_items.has(item_id) or hidden_items.has(String(item_id))


## Every non-weapon item that can be granted at start: placeables and resources
## (weapons have their own checkbox row; pure tools like the build tool are excluded).
func _giveable_starting_item_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for raw_id: Variant in ItemCatalog.ITEM_DEFS.keys():
		var item_def: Dictionary = ItemCatalog.get_item_def(str(raw_id))
		var item_type: String = str(item_def.get("type", ""))
		if item_type == "placeable" or item_type == "resource":
			ids.append(StringName(str(raw_id)))
	return ids


## Reads the quantity for an item from an authored starting-items dict, tolerating either
## a StringName or a String key (as tscn / hand edits may produce).
func _starting_item_quantity(items: Dictionary, item_id: StringName) -> int:
	if items.has(item_id):
		return maxi(0, int(items[item_id]))
	if items.has(String(item_id)):
		return maxi(0, int(items[String(item_id)]))
	return 0


func _selected_tool_shop_available_items() -> Array[StringName]:
	return _selected_shop_available_items_from(_tool_shop_available_checkboxes, TOOL_SHOP_ITEM_IDS)


func _selected_merchant_available_items() -> Array[StringName]:
	return _selected_shop_available_items_from(_merchant_available_checkboxes, MERCHANT_ITEM_IDS)


func _selected_legacy_shop_available_items() -> Array[StringName]:
	var item_ids: Array[StringName] = _selected_tool_shop_available_items()
	for item_id: StringName in _selected_merchant_available_items():
		if not item_ids.has(item_id):
			item_ids.append(item_id)
	return item_ids


func _selected_shop_available_items_from(available_checkboxes: Dictionary, valid_item_ids: Array[StringName]) -> Array[StringName]:
	var item_ids: Array[StringName] = []
	for raw_item_id: Variant in available_checkboxes.keys():
		var item_id: StringName = raw_item_id as StringName
		var checkbox: CheckBox = available_checkboxes[item_id] as CheckBox
		if checkbox != null and checkbox.button_pressed and valid_item_ids.has(item_id):
			item_ids.append(item_id)
	return item_ids


func _selected_tool_shop_prices() -> Dictionary:
	return _selected_shop_prices_from(_tool_shop_price_spins, TOOL_SHOP_ITEM_IDS)


func _selected_merchant_prices() -> Dictionary:
	return _selected_shop_prices_from(_merchant_price_spins, MERCHANT_ITEM_IDS)


func _selected_tool_shop_days() -> Dictionary:
	return _selected_shop_days_from(_tool_shop_day_spins, TOOL_SHOP_ITEM_IDS)


func _selected_tool_shop_growth_price_factors() -> Dictionary:
	return _selected_shop_growth_price_factors_from(_tool_shop_growth_price_factor_spins, TOOL_SHOP_ITEM_IDS)


func _selected_merchant_days() -> Dictionary:
	return _selected_shop_days_from(_merchant_day_spins, MERCHANT_ITEM_IDS)


func _selected_legacy_shop_prices() -> Dictionary:
	var prices: Dictionary = _selected_tool_shop_prices()
	var merchant_prices: Dictionary = _selected_merchant_prices()
	for item_id: StringName in MERCHANT_ITEM_IDS:
		prices[item_id] = int(merchant_prices.get(item_id, ItemCatalog.get_price(String(item_id))))
	return prices


func _selected_shop_prices_from(price_spins: Dictionary, item_ids: Array[StringName]) -> Dictionary:
	var prices: Dictionary = {}
	for item_id: StringName in item_ids:
		var price_spin: SpinBox = price_spins.get(item_id) as SpinBox
		var price: int = ItemCatalog.get_price(String(item_id))
		if price_spin != null:
			price = maxi(0, int(price_spin.value))
		prices[item_id] = price
	return prices


func _selected_shop_days_from(day_spins: Dictionary, item_ids: Array[StringName]) -> Dictionary:
	var days: Dictionary = {}
	for item_id: StringName in item_ids:
		var day_spin: SpinBox = day_spins.get(item_id) as SpinBox
		if day_spin == null:
			continue
		var day: int = maxi(1, int(day_spin.value))
		if day > 1:
			days[item_id] = day
	return days


func _selected_shop_growth_price_factors_from(growth_factor_spins: Dictionary, item_ids: Array[StringName]) -> Dictionary:
	var growth_price_factors: Dictionary = {}
	for item_id: StringName in item_ids:
		var growth_factor_spin: SpinBox = growth_factor_spins.get(item_id) as SpinBox
		if growth_factor_spin == null:
			continue
		var factor: float = maxf(1.0, float(growth_factor_spin.value))
		if factor > 1.0:
			growth_price_factors[item_id] = factor
	return growth_price_factors


func _valid_weapon_ids(raw_weapons: Array[StringName]) -> Array[StringName]:
	var weapons: Array[StringName] = []
	var seen: Dictionary = {}
	for weapon_id: StringName in raw_weapons:
		if weapon_id == &"" or seen.has(weapon_id) or not ItemCatalog.is_weapon(String(weapon_id)):
			continue
		seen[weapon_id] = true
		weapons.append(weapon_id)
	return weapons


func _valid_tool_shop_available_items(raw_item_ids: Array[StringName]) -> Array[StringName]:
	return _valid_shop_available_items(raw_item_ids, TOOL_SHOP_ITEM_IDS)


func _valid_merchant_available_items(raw_item_ids: Array[StringName]) -> Array[StringName]:
	return _valid_shop_available_items(raw_item_ids, MERCHANT_ITEM_IDS)


func _valid_legacy_shop_available_items(raw_item_ids: Array[StringName]) -> Array[StringName]:
	return _valid_shop_available_items(raw_item_ids, LEGACY_SHOP_ITEM_IDS)


func _valid_shop_available_items(raw_item_ids: Array[StringName], valid_item_ids: Array[StringName]) -> Array[StringName]:
	var item_ids: Array[StringName] = []
	var seen: Dictionary = {}
	for item_id: StringName in raw_item_ids:
		if item_id == &"" or seen.has(item_id) or not valid_item_ids.has(item_id):
			continue
		seen[item_id] = true
		item_ids.append(item_id)
	return item_ids


func _valid_tool_shop_prices(raw_prices: Dictionary) -> Dictionary:
	return _valid_shop_prices(raw_prices, TOOL_SHOP_ITEM_IDS)


func _valid_merchant_prices(raw_prices: Dictionary) -> Dictionary:
	return _valid_shop_prices(raw_prices, MERCHANT_ITEM_IDS)


func _valid_legacy_shop_prices(raw_prices: Dictionary) -> Dictionary:
	return _valid_shop_prices(raw_prices, LEGACY_SHOP_ITEM_IDS)


func _valid_tool_shop_days(raw_days: Dictionary) -> Dictionary:
	return _valid_shop_days(raw_days, TOOL_SHOP_ITEM_IDS)


func _valid_tool_shop_growth_price_factors(raw_factors: Dictionary) -> Dictionary:
	return _valid_shop_growth_price_factors(raw_factors, TOOL_SHOP_ITEM_IDS)


func _valid_merchant_days(raw_days: Dictionary) -> Dictionary:
	return _valid_shop_days(raw_days, MERCHANT_ITEM_IDS)


func _valid_shop_prices(raw_prices: Dictionary, item_ids: Array[StringName]) -> Dictionary:
	var prices: Dictionary = {}
	for item_id: StringName in item_ids:
		var raw_price: Variant = raw_prices.get(item_id, raw_prices.get(String(item_id), ItemCatalog.get_price(String(item_id))))
		prices[item_id] = maxi(0, int(raw_price))
	return prices


func _valid_shop_days(raw_days: Dictionary, item_ids: Array[StringName]) -> Dictionary:
	var days: Dictionary = {}
	for item_id: StringName in item_ids:
		var raw_day: Variant = raw_days.get(item_id, raw_days.get(String(item_id), 1))
		var day: int = maxi(1, int(raw_day))
		if day > 1:
			days[item_id] = day
	return days


func _valid_shop_growth_price_factors(raw_factors: Dictionary, item_ids: Array[StringName]) -> Dictionary:
	var growth_price_factors: Dictionary = {}
	for item_id: StringName in item_ids:
		var raw_factor: Variant = raw_factors.get(item_id, raw_factors.get(String(item_id), 1.0))
		var factor: float = maxf(1.0, float(raw_factor))
		if factor > 1.0:
			growth_price_factors[item_id] = factor
	return growth_price_factors


func _default_tool_shop_available_items() -> Array[StringName]:
	return _default_shop_available_items(TOOL_SHOP_ITEM_IDS)


func _default_merchant_available_items() -> Array[StringName]:
	return _default_shop_available_items(MERCHANT_ITEM_IDS)


func _default_legacy_shop_available_items() -> Array[StringName]:
	return _default_shop_available_items(LEGACY_SHOP_ITEM_IDS)


func _default_shop_available_items(item_ids_source: Array[StringName]) -> Array[StringName]:
	var item_ids: Array[StringName] = []
	for item_id: StringName in item_ids_source:
		item_ids.append(item_id)
	return item_ids


func _default_tool_shop_prices() -> Dictionary:
	return _default_shop_prices(TOOL_SHOP_ITEM_IDS)


func _default_tool_shop_growth_price_factors() -> Dictionary:
	return {}


func _default_merchant_prices() -> Dictionary:
	return _default_shop_prices(MERCHANT_ITEM_IDS)


func _default_legacy_shop_prices() -> Dictionary:
	return _default_shop_prices(LEGACY_SHOP_ITEM_IDS)


func _default_shop_prices(item_ids_source: Array[StringName]) -> Dictionary:
	var prices: Dictionary = {}
	for item_id: StringName in item_ids_source:
		prices[item_id] = ItemCatalog.get_price(String(item_id))
	return prices


func _same_string_name_array(left: Array[StringName], right: Array[StringName]) -> bool:
	if left.size() != right.size():
		return false
	for item_id: StringName in left:
		if not right.has(item_id):
			return false
	return true


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
	# Enumerated from the monster bible so new .tres definitions appear in the wave
	# dropdown automatically.
	var ids: Array[StringName] = MonsterCatalog.get_ids()
	if ids.is_empty():
		return [&"basic"]
	return ids
