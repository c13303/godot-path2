extends Node

signal day_started(day_number: int)
signal values_changed

## Manual save slot, written/read by the F5/F9 hotkeys.
const SAVE_PATH: String = "user://progression_save.json"
## Auto-save slot, written on each new day / on quit and restored on launch.
## Kept separate from SAVE_PATH so auto-saving never clobbers a manual F5 save.
const AUTOSAVE_PATH: String = "user://progression_autosave.json"
const SAVE_VERSION: int = 2
const SEED_KEY: StringName = &"seeds"
const GEM_KEY: StringName = &"gems"
const MONEY_KEY: StringName = &"money"
const WATER_RESERVE_KEY: StringName = &"water_reserve"
const PENDING_LOAD_META: StringName = &"pending_progression_load"
const LAYER_NAMES: Array[String] = [
	"floor",
	"plantz",
	"wallz",
	"traversable_buildings",
	"blocking_buildings",
	"fences",
]

## Per-prop starting values, exposed for inspector tuning. These seed the matching
## progression props in _ready() before any save is applied, so a saved game still
## overrides them. Keep one export per ProgressionProp key below.
@export_group("Starting Props")
@export var starting_day: int = 1
@export var starting_monster_per_day: int = 1
@export var starting_monster_per_rose: int = 1
@export var starting_seeds: int = 20
@export var starting_gems: int = 100
@export var starting_money: int = 0
@export var starting_water_reserve: int = 100
@export var starting_water_reserve_max: int = 100
@export_group("")


## A single "progression prop": one tracked global value plus the metadata
## needed to save it (`key`) and to show it in the UI (`display_name`).
class ProgressionProp:
	var key: StringName        # stable id used as the save-file field name
	var display_name: String   # human-readable label shown in the progression label
	var value: int

	func _init(p_key: StringName, p_display_name: String, p_default: int) -> void:
		key = p_key
		display_name = p_display_name
		value = p_default


## Global player progression: the ordered list of progression props.
##
## To add a new tracked value, add ONE ProgressionProp entry to `props` below.
## It is then automatically saved, reloaded, and shown in the progression label
## with no other code changes required.
##
## The values passed here are class-level fallbacks; the node's "Starting Props"
## exports re-seed these in _ready() via _apply_starting_values(), so add a matching
## export there when you want a new prop's starting value to be inspector-tunable.
class Progression:
	var props: Array[ProgressionProp] = [
		ProgressionProp.new(&"nDays", "Day", 1),
		ProgressionProp.new(&"monster_per_day", "Monster per day", 1),
		ProgressionProp.new(&"monster_per_rose", "Monster per rose", 1),
		ProgressionProp.new(&"seeds", "Seeds", 20),
		ProgressionProp.new(&"gems", "Gems", 100),
		ProgressionProp.new(&"money", "Money", 0),
		ProgressionProp.new(&"water_reserve", "Water reserve", 100),
		ProgressionProp.new(&"water_reserve_max", "Water reserve max", 100),
	]

	func get_prop(key: StringName) -> ProgressionProp:
		for prop: ProgressionProp in props:
			if prop.key == key:
				return prop
		return null

	func get_value(key: StringName) -> int:
		var prop: ProgressionProp = get_prop(key)
		return prop.value if prop != null else 0

	func add(key: StringName, amount: int) -> void:
		var prop: ProgressionProp = get_prop(key)
		if prop != null:
			prop.value += amount

	## Serialize every prop to a plain dict (key -> value) for the save file.
	func to_dict() -> Dictionary:
		var data: Dictionary = {}
		for prop: ProgressionProp in props:
			data[String(prop.key)] = prop.value
		return data

	## Restore prop values from a saved dict; missing keys keep their default.
	func from_dict(data: Dictionary) -> void:
		for prop: ProgressionProp in props:
			prop.value = int(data.get(String(prop.key), prop.value))


var progression: Progression = Progression.new()
var _seed_label_tween: Tween
var _gem_label_tween: Tween
var _money_label_tween: Tween
var _water_reserve_tween: Tween
# True once a save has been applied to this scene instance (pending-load during
# _ready or startup auto-load). Prevents the auto-save from being applied twice.
var _save_applied: bool = false


## Public accessor so other systems (e.g. the monster spawner) can read a
## progression prop value by key, e.g. get_value(&"monster_per_day").
func get_value(key: StringName) -> int:
	return progression.get_value(key)


## Spend a positive amount of a progression prop and refresh its UI.
## Returns false without changing the value when there is not enough available.
func spend(key: StringName, amount: int) -> bool:
	if amount <= 0 or progression.get_value(key) < amount:
		return false
	progression.add(key, -amount)
	_update_progression_ui(key == SEED_KEY, key == GEM_KEY, key == MONEY_KEY)
	return true


## Change any progression value through the same save/UI path used by currencies.
## Optional bounds keep runtime resources valid when their progression limits change.
func update_value(key: StringName, delta: int, minimum: int = -2147483648, maximum: int = 2147483647) -> bool:
	var prop: ProgressionProp = progression.get_prop(key)
	if prop == null or delta == 0:
		return false
	var next_value: int = clampi(prop.value + delta, minimum, maximum)
	if next_value == prop.value:
		return false
	prop.value = next_value
	_update_progression_ui(key == SEED_KEY, key == GEM_KEY, key == MONEY_KEY)
	return true


func advance_day(amount: int = 1) -> bool:
	if amount <= 0:
		return false
	progression.add(&"nDays", amount)
	var day_number: int = progression.get_value(&"nDays")
	_update_day_label(day_number)
	day_started.emit(day_number)
	_log("Day advanced: Day %d" % day_number)
	_update_progression_ui()
	return true


## Single entry point for changing the seed count. Pass a positive `delta` to
## grant seeds, a negative `delta` to spend them. Spending more seeds than the
## player owns fails and leaves the count untouched. Refreshes the seed UI on
## any successful change (event-driven; do NOT poll this every frame).
## Use this everywhere seeds are added or removed.
func update_seeds(delta: int) -> bool:
	if delta < 0 and progression.get_value(SEED_KEY) < -delta:
		return false
	if delta != 0:
		progression.add(SEED_KEY, delta)
		_update_progression_ui(true)
	return true


## Single entry point for changing the gem count. Gems are credited when their
## monster-drop animation reaches the HUD icon.
func update_gems(delta: int) -> bool:
	if delta < 0 and progression.get_value(GEM_KEY) < -delta:
		return false
	if delta != 0:
		progression.add(GEM_KEY, delta)
		_update_progression_ui(false, true)
	return true


## Single entry point for changing the money count. Clients pay money when their
## payment animation reaches the HUD icon.
func update_money(delta: int) -> bool:
	if delta < 0 and progression.get_value(MONEY_KEY) < -delta:
		return false
	if delta != 0:
		progression.add(MONEY_KEY, delta)
		_update_progression_ui(false, false, true)
	return true


## Copy the inspector-exposed Starting Props onto their matching progression props.
## One entry per ProgressionProp key; a key with no export keeps its class default.
func _apply_starting_values() -> void:
	_apply_level_starting_values()
	var starting: Dictionary = {
		&"nDays": starting_day,
		&"monster_per_day": starting_monster_per_day,
		&"monster_per_rose": starting_monster_per_rose,
		&"seeds": starting_seeds,
		&"gems": starting_gems,
		&"money": starting_money,
		&"water_reserve": starting_water_reserve,
		&"water_reserve_max": starting_water_reserve_max,
	}
	for raw_key: Variant in starting:
		var key: StringName = raw_key as StringName
		var prop: ProgressionProp = progression.get_prop(key)
		if prop != null:
			prop.value = int(starting[key])


func _apply_level_starting_values() -> void:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return
	var loader: Node = scene.get_node_or_null("LevelLoader")
	if loader == null:
		return
	if loader.has_method("get_loaded_starting_seeds"):
		starting_seeds = int(loader.call("get_loaded_starting_seeds"))
	if loader.has_method("get_loaded_starting_gems"):
		starting_gems = int(loader.call("get_loaded_starting_gems"))
	if loader.has_method("get_loaded_starting_money"):
		starting_money = int(loader.call("get_loaded_starting_money"))


func _ready() -> void:
	# GameState is an autoload, so reconnect every time a fresh scene loads.
	if not GameState.mode_changed.is_connected(_on_game_mode_changed):
		GameState.mode_changed.connect(_on_game_mode_changed)

	# Seed the props from the inspector-exposed Starting Props before any save is
	# applied, so a saved game still overrides these starting values below.
	_apply_starting_values()

	var pending_save_path: String = GameState.consume_startup_save_load_path(SAVE_PATH)
	if GameState.has_meta(PENDING_LOAD_META):
		GameState.remove_meta(PENDING_LOAD_META)
		if pending_save_path == "":
			pending_save_path = SAVE_PATH

	if pending_save_path != "":
		_log("Fresh scene ready; applying pending save before native player setup")
		var data: Dictionary = _read_save_data(pending_save_path)
		if not data.is_empty():
			_apply_save_to_fresh_scene(data)

	_update_progression_ui()
	# BuildingManager loads the level spawn config during its own _ready, which may not
	# have run yet. Refresh the day label once the scene is fully built so day 1 shows
	# the "/total" denominator instead of a bare "day 1".
	call_deferred("_update_day_label", progression.get_value(&"nDays"))


## A night->day transition means a new day has begun.
func _on_game_mode_changed(is_night: bool) -> void:
	if is_night:
		return
	advance_day()


## Show the current day on the dedicated day label. When the level has an authored
## run length this includes the total, e.g. "day 3/10"; otherwise just "day 3".
func _update_day_label(day_number: int) -> void:
	var label: RichTextLabel = _get_day_label()
	if label == null:
		return
	var total_days: int = _get_total_run_days()
	if total_days > 0:
		label.text = "day %d/%d" % [day_number, total_days]
	else:
		label.text = "day %d" % day_number


## Total days in the current run (authored nights + the trailing client day), read
## from BuildingManager. Zero when no run length is defined, which drops the "/total".
func _get_total_run_days() -> int:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return 0
	var building_manager: Node = scene.get_node_or_null("Map/BuildingManager")
	if building_manager != null and building_manager.has_method("total_run_days"):
		return int(building_manager.call("total_run_days"))
	return 0


func _get_day_label() -> RichTextLabel:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return null
	return scene.get_node_or_null("GameUI/top anchor/dayLabel") as RichTextLabel


func _get_progression_ui() -> RichTextLabel:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return null
	return scene.get_node_or_null("GameUI/top left anchor/progressionUI") as RichTextLabel


func _get_seed_label() -> RichTextLabel:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return null
	return scene.get_node_or_null("GameUI/currenciesUI/seedIcon/seedQT") as RichTextLabel


func _get_gem_label() -> RichTextLabel:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return null
	return scene.get_node_or_null("GameUI/currenciesUI/gemIcon/gemQT") as RichTextLabel


func _get_money_label() -> RichTextLabel:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return null
	return scene.get_node_or_null("GameUI/currenciesUI/moneyIcon/moneyQT") as RichTextLabel


func _get_water_reserve_bar() -> ProgressBar:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return null
	return scene.get_node_or_null("GameUI/bottom left anchor/waterReserve") as ProgressBar


## Render every progression prop, one per line: "<display name>: <value>".
## Adding a prop to Progression.props makes it appear here automatically.
func _update_progression_ui(animate_seed_label: bool = false, animate_gem_label: bool = false, animate_money_label: bool = false) -> void:
	values_changed.emit()
	var seed_label: RichTextLabel = _get_seed_label()
	if seed_label != null:
		seed_label.text = "x %d" % progression.get_value(SEED_KEY)
		if animate_seed_label:
			_animate_seed_label(seed_label)
	var gem_label: RichTextLabel = _get_gem_label()
	if gem_label != null:
		gem_label.text = "x %d" % progression.get_value(GEM_KEY)
		if animate_gem_label:
			_animate_gem_label(gem_label)
	var money_label: RichTextLabel = _get_money_label()
	if money_label != null:
		money_label.text = "x %d" % progression.get_value(MONEY_KEY)
		if animate_money_label:
			_animate_money_label(money_label)

	_update_day_label(progression.get_value(&"nDays"))
	var water_reserve_bar: ProgressBar = _get_water_reserve_bar()
	if water_reserve_bar != null:
		var water_maximum: int = maxi(1, progression.get_value(&"water_reserve_max"))
		var water_current: int = clampi(progression.get_value(WATER_RESERVE_KEY), 0, water_maximum)
		water_reserve_bar.max_value = float(water_maximum)
		if _water_reserve_tween != null and _water_reserve_tween.is_valid():
			_water_reserve_tween.kill()
		_water_reserve_tween = create_tween()
		_water_reserve_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_water_reserve_tween.tween_property(water_reserve_bar, "value", float(water_current), 0.2)

	var label: RichTextLabel = _get_progression_ui()
	if label == null:
		return
	var lines: PackedStringArray = PackedStringArray()
	for prop: ProgressionProp in progression.props:
		lines.append("%s: %d" % [prop.display_name, prop.value])
	label.text = "\n".join(lines)


func _animate_seed_label(seed_label: RichTextLabel) -> void:
	if _seed_label_tween != null and _seed_label_tween.is_valid():
		_seed_label_tween.kill()
	seed_label.pivot_offset = seed_label.size * 0.5
	seed_label.scale = Vector2(1.55, 1.55)
	seed_label.modulate = Color(0.35, 1.0, 0.3, 1.0)
	_seed_label_tween = create_tween().set_parallel(true)
	_seed_label_tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_seed_label_tween.tween_property(seed_label, "scale", Vector2.ONE, 0.42)
	_seed_label_tween.tween_property(seed_label, "modulate", Color.WHITE, 0.5)


func _animate_gem_label(gem_label: RichTextLabel) -> void:
	if _gem_label_tween != null and _gem_label_tween.is_valid():
		_gem_label_tween.kill()
	gem_label.pivot_offset = gem_label.size * 0.5
	gem_label.scale = Vector2(1.55, 1.55)
	gem_label.modulate = Color(0.35, 0.75, 1.0, 1.0)
	_gem_label_tween = create_tween().set_parallel(true)
	_gem_label_tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_gem_label_tween.tween_property(gem_label, "scale", Vector2.ONE, 0.42)
	_gem_label_tween.tween_property(gem_label, "modulate", Color.WHITE, 0.5)


func _animate_money_label(money_label: RichTextLabel) -> void:
	if _money_label_tween != null and _money_label_tween.is_valid():
		_money_label_tween.kill()
	money_label.pivot_offset = money_label.size * 0.5
	money_label.scale = Vector2(1.55, 1.55)
	money_label.modulate = Color(1.0, 0.82, 0.22, 1.0)
	_money_label_tween = create_tween().set_parallel(true)
	_money_label_tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_money_label_tween.tween_property(money_label, "scale", Vector2.ONE, 0.42)
	_money_label_tween.tween_property(money_label, "modulate", Color.WHITE, 0.5)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key_event: InputEventKey = event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return

	if key_event.keycode == KEY_F5:
		_log("F5 received (night=%s)" % str(GameState.is_night))
		get_viewport().set_input_as_handled()
		save_progression()
	elif key_event.keycode == KEY_F9:
		_log("F9 received (night=%s)" % str(GameState.is_night))
		get_viewport().set_input_as_handled()
		load_progression()


func save_progression(save_path: String = SAVE_PATH, day_phase_override: String = "") -> bool:
	var scene: Node = get_tree().current_scene
	_log("Save started: %s" % ProjectSettings.globalize_path(save_path))
	var layers: Dictionary = _get_layers(scene)
	var player: Node2D = _get_player()
	var game_ui: Node = scene.get_node_or_null("GameUI") if scene else null
	if layers.size() != LAYER_NAMES.size() or player == null or game_ui == null:
		_fail("Save failed: required game nodes are missing")
		return false

	var inventory: Array[Dictionary] = _get_inventory(game_ui)
	var layer_data: Dictionary = {}
	for layer_name in LAYER_NAMES:
		var layer: TileMapLayer = layers[layer_name] as TileMapLayer
		var serialized_cells: Array[Dictionary] = _serialize_layer(layer)
		layer_data[layer_name] = serialized_cells
		_log("Captured layer %s: %d cells" % [layer_name, serialized_cells.size()])

	var day_phase: String = day_phase_override if day_phase_override != "" else _get_day_phase()
	var plant_states: Array[Dictionary] = _get_plant_states(scene)
	var counter_stock: Array[Dictionary] = _get_counter_stock(scene)
	var ground_collectibles: Array[Dictionary] = _get_ground_collectibles(scene)
	var runtime_agents: Dictionary = _get_runtime_agents(scene)
	var data: Dictionary = {
		"version": SAVE_VERSION,
		"level_scene_path": _get_loaded_level_scene_path(scene),
		"progression": progression.to_dict(),
		"night_rewards": GameState.get_special_reward_claim_save_data(),
		"day_phase": day_phase,
		"layers": layer_data,
		"plant_states": plant_states,
		"counter_stock": counter_stock,
		"ground_collectibles": ground_collectibles,
		"runtime_agents": runtime_agents,
		"player": {
			"position": [player.global_position.x, player.global_position.y],
			"inventory": inventory,
			"equipped_weapon_id": _game_ui_equipped_weapon_id(game_ui),
			"selected_build_item_id": String(game_ui.get("selected_build_item_id")),
		},
	}
	_log("Save summary: %s" % _save_summary(data))
	_log("Save live summary: %s" % _live_scene_summary(scene))
	_warn_if_day_phase_has_monsters("SAVE GAME ERROR")

	var json_text: String = JSON.stringify(data)
	var file: FileAccess = FileAccess.open(save_path, FileAccess.WRITE)
	if file == null:
		_fail("Save failed: cannot open save file")
		return false
	file.store_string(json_text)
	file.close()
	_log("Save complete: player=%s inventory_slots=%d bytes=%d" % [
		str(player.global_position), inventory.size(), json_text.to_utf8_buffer().size()
	])
	_notify("Game saved")
	return true


## The player's currently equipped weapon id, resolved through game_ui so an empty stored value
## is saved as the actual first-possessed weapon.
func _game_ui_equipped_weapon_id(game_ui: Node) -> String:
	if game_ui != null and game_ui.has_method("get_equipped_weapon_id"):
		return String(game_ui.call("get_equipped_weapon_id"))
	return ""


func load_progression() -> void:
	# F9 reload is allowed anytime, including during night.
	_log("Load started: %s" % ProjectSettings.globalize_path(SAVE_PATH))
	var data: Dictionary = _read_save_data()
	if data.is_empty():
		return
	_log("Manual load summary: %s" % _save_summary(data))

	_unregister_scene_agents()
	GameState.request_startup_save_load(SAVE_PATH)
	GameState.set_meta(PENDING_LOAD_META, true)
	GameState.reset_transient_run_state()
	_log("Save validated; reloading current scene")
	var reload_error: Error = get_tree().reload_current_scene()
	if reload_error != OK:
		GameState.remove_meta(PENDING_LOAD_META)
		_fail("Load failed: scene reload error %d" % int(reload_error))


## Write the auto-save slot (separate file from the F5/F9 manual slot).
## Skipped entirely while the Enable Auto-Save option is OFF; returns true so callers
## that gate progression on "the save happened" still proceed (no file is written).
func auto_save() -> bool:
	if not CppDebugOptions.auto_save_enabled:
		_log("Auto-save skipped: auto-save disabled")
		return true
	return save_progression(AUTOSAVE_PATH)


func auto_save_after_rose_growth() -> bool:
	# When auto-save is off, don't touch the autosave slot, but still report success:
	# plant_manager only advances the new day when this returns true, so the day must
	# keep progressing even though nothing is written.
	if not CppDebugOptions.auto_save_enabled:
		_log("Rose-growth auto-save skipped: auto-save disabled; day still advances")
		return true
	_log("Rose-growth auto-save requested")
	return save_progression(AUTOSAVE_PATH, "morning")


## Startup auto-load: restore the auto-save slot into the freshly loaded scene.
## No scene reload happens here (the scene is already pristine on launch). Skips
## silently when there is no auto-save, or when a pending-load already applied a
## manual save during _ready (the F9 reload path).
func load_on_start() -> void:
	if _save_applied:
		return
	# Consume the one-shot skip flag regardless so it never leaks into a later launch.
	var skip_requested: bool = GameState.consume_skip_startup_autosave()
	# Auto-save off also means auto-load off: a fresh launch never restores the
	# autosave slot, so a stale snapshot can't resurface (only manual F9 loads a save).
	if not CppDebugOptions.auto_save_enabled:
		_log("Startup auto-load skipped: auto-save disabled")
		return
	if skip_requested:
		_log("Startup auto-load skipped for fresh selected level")
		return
	if not FileAccess.file_exists(AUTOSAVE_PATH):
		_log("No auto-save found on start; beginning a fresh game")
		return
	var data: Dictionary = _read_save_data(AUTOSAVE_PATH)
	if data.is_empty():
		return
	_log("Auto-loading save on start")
	_log("Auto-load summary: %s" % _save_summary(data))
	_apply_save_to_fresh_scene(data)


## Places the player on the level's authored "player" spawn marker. Only applies
## on a fresh start: when a save was restored the player keeps its saved position,
## so this is a no-op. Called during startup _ready (after save-loading is
## resolved and before the first frame is drawn), so the player is never shown at
## its scene-authored placeholder position.
func apply_fresh_start_player_spawn() -> void:
	if _save_applied:
		return
	var player: Node2D = _get_player()
	if player == null:
		return
	var marker: Node2D = _find_player_spawn_marker()
	if marker == null:
		push_warning("progression: level has no 'player' spawn marker; keeping the player's authored position")
		return
	player.global_position = marker.global_position
	player.set("velocity", Vector2.ZERO)
	_log("Fresh start: player placed on 'player' spawn marker at %s" % str(player.global_position))


## Locates the authored "player" marker node inside the loaded level's spawner
## container (reparented under the MonTilemap host by LevelLoader).
func _find_player_spawn_marker() -> Node2D:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return null
	var host: Node = scene.get_node_or_null("Map/MonTilemap")
	if host == null:
		return null
	for container_name in ["spawner", "spawners"]:
		var container: Node = host.get_node_or_null(container_name)
		if container == null:
			continue
		var marker: Node2D = container.get_node_or_null("player") as Node2D
		if marker != null:
			return marker
	return null


## Wipe the auto-save slot and restart a brand-new game (Day 1, defaults). The
## fresh scene reload recreates progression at its defaults; skipping the next
## startup auto-load keeps the post-reload load_on_start from restoring the lost
## run. The manual F5 slot is intentionally left untouched.
func reset_game() -> void:
	GameState.skip_startup_autosave_once()
	if FileAccess.file_exists(AUTOSAVE_PATH):
		var remove_error: Error = DirAccess.remove_absolute(ProjectSettings.globalize_path(AUTOSAVE_PATH))
		if remove_error == OK:
			_log("Auto-save deleted; resetting to a new game")
		else:
			_fail("Reset: could not delete save (error %d)" % int(remove_error))
	# A leftover pending-load flag must never carry into the fresh game.
	if GameState.has_meta(PENDING_LOAD_META):
		GameState.remove_meta(PENDING_LOAD_META)
	GameState.reset_transient_run_state()
	_unregister_scene_agents()
	var reload_error: Error = get_tree().reload_current_scene()
	if reload_error != OK:
		_fail("Reset failed: scene reload error %d" % int(reload_error))


func _unregister_scene_agents() -> void:
	var scene: Node = get_tree().current_scene
	var agent_manager: Node = scene.get_node_or_null("CPP/AgentManagerNative") if scene else null
	if agent_manager == null or not agent_manager.has_method("unregister_agent"):
		_log("No native agent manager found before scene reload")
		return

	var seen_ids: Dictionary = {}
	var group_names: Array[StringName] = [&"player", &"main_chars", &"monsters", &"clients", &"merchants", &"sheep"]
	for group_name: StringName in group_names:
		for node: Node in get_tree().get_nodes_in_group(group_name):
			var nav_id: int = int(node.get("nav_id"))
			if nav_id < 0 or seen_ids.has(nav_id):
				continue
			agent_manager.call("unregister_agent", nav_id)
			seen_ids[nav_id] = true
	_log("Unregistered %d native scene agents before reload" % seen_ids.size())


func _read_save_data(save_path: String = SAVE_PATH) -> Dictionary:
	if not FileAccess.file_exists(save_path):
		_fail("Load failed: no save file")
		return {}

	var file: FileAccess = FileAccess.open(save_path, FileAccess.READ)
	if file == null:
		_fail("Load failed: cannot open save file")
		return {}
	var json: JSON = JSON.new()
	var parse_error: Error = json.parse(file.get_as_text())
	file.close()
	if parse_error != OK or not (json.data is Dictionary):
		_fail("Load failed: save file is invalid")
		return {}

	var data: Dictionary = json.data as Dictionary
	var validation_error: String = _validate_save(data)
	if validation_error != "":
		_fail("Load failed: " + validation_error)
		return {}
	_log("Read save OK: %s summary=%s" % [ProjectSettings.globalize_path(save_path), _save_summary(data)])
	return data


func _apply_save_to_fresh_scene(data: Dictionary) -> void:
	var scene: Node = get_tree().current_scene
	var layers: Dictionary = _get_layers(scene)
	var player: Node2D = _get_player()
	var game_ui: Node = scene.get_node_or_null("GameUI") if scene else null
	if layers.size() != LAYER_NAMES.size() or player == null or game_ui == null:
		_fail("Load failed: required game nodes are missing after scene reload")
		return

	var progression_data: Dictionary = data.get("progression", {}) as Dictionary
	progression.from_dict(progression_data)
	_log("Progression restored: %s" % str(progression.to_dict()))

	var raw_night_rewards: Variant = data.get("night_rewards", {})
	var night_reward_data: Dictionary = {}
	if raw_night_rewards is Dictionary:
		night_reward_data = raw_night_rewards as Dictionary
	GameState.apply_special_reward_claim_save_data(night_reward_data)

	var saved_layers: Dictionary = data["layers"] as Dictionary
	for layer_name in LAYER_NAMES:
		var layer: TileMapLayer = layers[layer_name] as TileMapLayer
		var cells: Array = []
		var raw_cells: Variant = saved_layers.get(layer_name, [])
		if raw_cells is Array:
			cells = raw_cells as Array
		_restore_layer(layer, cells)
		_log("Restored layer %s: %d cells" % [layer_name, cells.size()])

	var player_data: Dictionary = data["player"] as Dictionary
	var saved_position: Array = player_data["position"] as Array
	var target_position: Vector2 = Vector2(float(saved_position[0]), float(saved_position[1]))
	_log("Player restore requested: current=%s saved=%s" % [
		str(player.global_position), str(target_position)
	])
	player.global_position = target_position
	player.set("velocity", Vector2.ZERO)
	_restore_inventory(game_ui, player_data)
	_reindex_loaded_layers(scene)
	_restore_plant_states(scene, data.get("plant_states", []))
	_restore_counter_stock(scene, data.get("counter_stock", []))
	_restore_ground_collectibles(scene, data.get("ground_collectibles", []))
	var raw_runtime_agents: Variant = data.get("runtime_agents", {})
	var has_runtime_agents: bool = raw_runtime_agents is Dictionary and not (raw_runtime_agents as Dictionary).is_empty()
	_restore_day_phase(scene, str(data.get("day_phase", "")), has_runtime_agents)
	call_deferred("_restore_runtime_agents_deferred", raw_runtime_agents)
	_save_applied = true
	_log("Post-load live summary: %s" % _live_scene_summary(scene))
	_log("Load complete: player=%s inventory_slots=%d" % [
		str(player.global_position), (player_data["inventory"] as Array).size()
	])
	_notify("Game loaded")


func _get_layers(scene: Node) -> Dictionary:
	var result: Dictionary = {}
	if scene == null:
		return result
	var tilemap_root: Node = scene.get_node_or_null("Map/MonTilemap")
	if tilemap_root == null:
		return result
	for layer_name in LAYER_NAMES:
		var layer: TileMapLayer = tilemap_root.get_node_or_null(layer_name) as TileMapLayer
		if layer != null:
			result[layer_name] = layer
	return result


func _get_player() -> Node2D:
	return get_tree().get_first_node_in_group("player") as Node2D


func _get_loaded_level_scene_path(scene: Node) -> String:
	if scene == null:
		return ""
	var loader: Node = scene.get_node_or_null("LevelLoader")
	if loader != null and loader.has_method("get_loaded_level_scene_path"):
		return str(loader.call("get_loaded_level_scene_path"))
	return ""


func _get_inventory(game_ui: Node) -> Array[Dictionary]:
	var inventory: Array[Dictionary] = []
	var raw_inventory: Variant = game_ui.get("inventory_slots")
	if raw_inventory is Array:
		for raw_slot: Variant in raw_inventory:
			if raw_slot is Dictionary:
				var slot_data: Dictionary = raw_slot as Dictionary
				inventory.append({
					"item_id": str(slot_data.get("item_id", "")),
					"quantity": int(slot_data.get("quantity", 0)),
				})
	return inventory


func _get_counter_stock(scene: Node) -> Array[Dictionary]:
	var stock: Array[Dictionary] = []
	var building_manager: Node = scene.get_node_or_null("Map/BuildingManager") if scene else null
	if building_manager == null or not building_manager.has_method("serialize_counter_stock"):
		return stock
	var raw_stock: Variant = building_manager.call("serialize_counter_stock")
	if raw_stock is Array:
		var stock_data: Array = raw_stock as Array
		for raw_entry: Variant in stock_data:
			if raw_entry is Dictionary:
				stock.append(raw_entry as Dictionary)
	return stock


func _get_ground_collectibles(scene: Node) -> Array[Dictionary]:
	var collectibles: Array[Dictionary] = []
	var building_manager: Node = scene.get_node_or_null("Map/BuildingManager") if scene else null
	if building_manager == null or not building_manager.has_method("serialize_ground_collectibles_for_save"):
		return collectibles
	var raw_items: Variant = building_manager.call("serialize_ground_collectibles_for_save")
	if raw_items is Array:
		var item_data: Array = raw_items as Array
		for raw_entry: Variant in item_data:
			if raw_entry is Dictionary:
				collectibles.append(raw_entry as Dictionary)
	return collectibles


func _get_day_phase() -> String:
	if GameState.is_night:
		return "night"
	if GameState.is_morning_phase:
		return "morning"
	if GameState.is_client_phase:
		return "client"
	if GameState.is_seed_merchant_phase:
		return "seed_merchant"
	return "building"


func _get_plant_states(scene: Node) -> Array[Dictionary]:
	var states: Array[Dictionary] = []
	var plant_manager: Node = scene.get_node_or_null("Map/PlantManager") if scene else null
	if plant_manager == null or not plant_manager.has_method("serialize_plant_states"):
		return states
	var raw_states: Variant = plant_manager.call("serialize_plant_states")
	if raw_states is Array:
		var state_data: Array = raw_states as Array
		for raw_entry: Variant in state_data:
			if raw_entry is Dictionary:
				states.append(raw_entry as Dictionary)
	return states


func _get_runtime_agents(scene: Node) -> Dictionary:
	var building_manager: Node = scene.get_node_or_null("Map/BuildingManager") if scene else null
	if building_manager == null or not building_manager.has_method("serialize_runtime_agents_for_save"):
		return {}
	var raw_state: Variant = building_manager.call("serialize_runtime_agents_for_save")
	if raw_state is Dictionary:
		return raw_state as Dictionary
	return {}


func _serialize_layer(layer: TileMapLayer) -> Array[Dictionary]:
	var cells: Array[Dictionary] = []
	for raw_cell: Variant in layer.get_used_cells():
		var cell: Vector2i = raw_cell as Vector2i
		var atlas: Vector2i = layer.get_cell_atlas_coords(cell)
		cells.append({
			"x": cell.x,
			"y": cell.y,
			"source": layer.get_cell_source_id(cell),
			"atlas_x": atlas.x,
			"atlas_y": atlas.y,
			"alternative": layer.get_cell_alternative_tile(cell),
		})
	return cells


func _restore_layer(layer: TileMapLayer, cells: Array) -> void:
	layer.clear()
	for raw_cell: Variant in cells:
		var cell_data: Dictionary = raw_cell as Dictionary
		var cell: Vector2i = Vector2i(int(cell_data["x"]), int(cell_data["y"]))
		var atlas: Vector2i = Vector2i(int(cell_data["atlas_x"]), int(cell_data["atlas_y"]))
		layer.set_cell(cell, int(cell_data["source"]), atlas, int(cell_data["alternative"]))
	layer.update_internals()
	layer.queue_redraw()


func _restore_inventory(game_ui: Node, player_data: Dictionary) -> void:
	var saved_inventory: Array = player_data["inventory"] as Array
	var inventory: Array[Dictionary] = []
	for raw_slot: Variant in saved_inventory:
		if raw_slot is Dictionary:
			var saved_slot: Dictionary = raw_slot as Dictionary
			inventory.append({
				"item_id": str(saved_slot.get("item_id", "")),
				"quantity": int(saved_slot.get("quantity", 0)),
			})
		else:
			# Version 1 stored only item-id strings. Preserve those saves by
			# restoring every occupied slot as one item.
			var legacy_item_id: String = str(raw_slot)
			inventory.append({
				"item_id": legacy_item_id,
				"quantity": 1 if legacy_item_id != "" else 0,
			})
	game_ui.set("inventory_slots", inventory)
	# The quickbar is restored to play mode (inactive): the equipped weapon and any equipped
	# build preview are restored, but no menu is reopened.
	game_ui.set("equipped_weapon_id", String(player_data.get("equipped_weapon_id", "")))
	game_ui.set("selected_build_item_id", String(player_data.get("selected_build_item_id", "")))
	game_ui.set("quickbar_active", false)
	game_ui.set("active_slot_index", -1)
	if game_ui.has_method("reset_possessed_weapons_from_inventory"):
		game_ui.call("reset_possessed_weapons_from_inventory")
	if game_ui.has_method("_refresh_all_slots"):
		game_ui.call("_refresh_all_slots")
	_log("Inventory restored: %d slots, weapon=%s" % [
		inventory.size(), String(player_data.get("equipped_weapon_id", ""))
	])


func _restore_counter_stock(scene: Node, raw_stock: Variant) -> void:
	var building_manager: Node = scene.get_node_or_null("Map/BuildingManager") if scene else null
	if building_manager == null or not building_manager.has_method("restore_counter_stock"):
		return
	var stock: Array = []
	if raw_stock is Array:
		stock = raw_stock as Array
	building_manager.call("restore_counter_stock", stock)
	var requested_total: int = 0
	for raw_entry: Variant in stock:
		if raw_entry is Dictionary:
			var entry: Dictionary = raw_entry as Dictionary
			requested_total += int(entry.get("count", 0))
	var restored_total: int = -1
	if building_manager.has_method("total_counter_stock"):
		restored_total = int(building_manager.call("total_counter_stock"))
	var counter_buildings: int = -1
	if building_manager.has_method("rose_shop_counter_count"):
		counter_buildings = int(building_manager.call("rose_shop_counter_count"))
	_log("Counter stock restored: entries=%d requested_roses=%d live_counter_buildings=%d live_counter_roses=%d" % [
		stock.size(),
		requested_total,
		counter_buildings,
		restored_total,
	])


func _restore_ground_collectibles(scene: Node, raw_items: Variant) -> void:
	var building_manager: Node = scene.get_node_or_null("Map/BuildingManager") if scene else null
	if building_manager == null or not building_manager.has_method("restore_ground_collectibles_from_save"):
		return
	var items: Array = []
	if raw_items is Array:
		items = raw_items as Array
	building_manager.call("restore_ground_collectibles_from_save", items)
	_log("Ground collectibles restored: %d" % items.size())


func _restore_plant_states(scene: Node, raw_states: Variant) -> void:
	var plant_manager: Node = scene.get_node_or_null("Map/PlantManager") if scene else null
	if plant_manager == null or not plant_manager.has_method("restore_plant_states"):
		return
	var states: Array = []
	if raw_states is Array:
		states = raw_states as Array
	plant_manager.call("restore_plant_states", states)
	_log("Plant states restored: %d entries" % states.size())


func _restore_day_phase(scene: Node, phase: String, has_runtime_agents: bool = false) -> void:
	if phase == "":
		return
	if phase == "building":
		var plant_manager: Node = scene.get_node_or_null("Map/PlantManager") if scene else null
		if plant_manager != null and plant_manager.has_method("mark_build_phase_rose_dry_handled_for_current_day"):
			plant_manager.call("mark_build_phase_rose_dry_handled_for_current_day")
	GameState.restore_day_phase_flags(phase)
	var building_manager: Node = scene.get_node_or_null("Map/BuildingManager") if scene else null
	if has_runtime_agents and (phase == "night" or phase == "client"):
		_log("Day phase restored from runtime snapshot: %s" % phase)
		return
	if building_manager != null and building_manager.has_method("restore_day_phase"):
		building_manager.call("restore_day_phase", phase)
		_log("Day phase restored: %s" % phase)


func _restore_runtime_agents(scene: Node, raw_state: Variant) -> void:
	if not (raw_state is Dictionary):
		return
	var building_manager: Node = scene.get_node_or_null("Map/BuildingManager") if scene else null
	if building_manager == null or not building_manager.has_method("restore_runtime_agents_from_save"):
		return
	building_manager.call("restore_runtime_agents_from_save", raw_state as Dictionary)
	var agents: Array = []
	var runtime_state: Dictionary = raw_state as Dictionary
	var raw_agents: Variant = runtime_state.get("agents", [])
	if raw_agents is Array:
		agents = raw_agents as Array
	_log("Runtime agents restored from save: %d" % agents.size())


func _restore_runtime_agents_deferred(raw_state: Variant) -> void:
	await get_tree().process_frame
	var scene: Node = get_tree().current_scene
	if scene == null:
		return
	_restore_runtime_agents(scene, raw_state)


func _reindex_loaded_layers(scene: Node) -> void:
	var plant_manager: Node = scene.get_node_or_null("Map/PlantManager")
	if plant_manager and plant_manager.has_method("initialize_from_layer"):
		plant_manager.call("initialize_from_layer")
		_log("Plant manager re-indexed")

	var building_object_manager: Node = scene.get_node_or_null("Map/BuildingObjectManager")
	if building_object_manager and building_object_manager.has_method("initialize_from_layer"):
		building_object_manager.call("initialize_from_layer")
		_log("Building object manager re-indexed")

	var fight_system: Node = scene.get_node_or_null("fightSystem")
	if fight_system and fight_system.has_method("refresh_projectile_walls"):
		fight_system.call("refresh_projectile_walls")
		_log("Projectile static colliders refreshed")


func _validate_save(data: Dictionary) -> String:
	var save_version: int = int(data.get("version", -1))
	if save_version != 1 and save_version != SAVE_VERSION:
		return "unsupported save version"
	if not (data.get("layers") is Dictionary) or not (data.get("player") is Dictionary):
		return "missing save sections"

	var layers: Dictionary = data["layers"] as Dictionary
	for layer_name in LAYER_NAMES:
		if layer_name == "fences" and not layers.has(layer_name):
			continue
		if not (layers.get(layer_name) is Array):
			return "invalid layer " + layer_name
		var cells: Array = layers[layer_name] as Array
		for raw_cell: Variant in cells:
			if not (raw_cell is Dictionary):
				return "invalid cell in " + layer_name
			var cell: Dictionary = raw_cell as Dictionary
			for field: String in ["x", "y", "source", "atlas_x", "atlas_y", "alternative"]:
				if not cell.has(field):
					return "invalid cell in " + layer_name

	var player_data: Dictionary = data["player"] as Dictionary
	var position: Variant = player_data.get("position")
	var inventory: Variant = player_data.get("inventory")
	if not (position is Array) or (position as Array).size() != 2:
		return "invalid player position"
	if not (inventory is Array):
		return "invalid player inventory"
	var inventory_data: Array = inventory as Array
	for raw_slot: Variant in inventory_data:
		if save_version == 1:
			if not (raw_slot is String):
				return "invalid player inventory slot"
			continue
		if not (raw_slot is Dictionary):
			return "invalid player inventory slot"
		var slot_data: Dictionary = raw_slot as Dictionary
		if not slot_data.has("item_id") or not slot_data.has("quantity"):
			return "invalid player inventory slot"
		var item_id: String = str(slot_data["item_id"])
		var quantity: int = int(slot_data["quantity"])
		var max_stack: int = ItemCatalog.get_max_stack(item_id)
		if quantity < 0 or quantity > max_stack:
			return "invalid player inventory quantity"
		if (item_id == "") != (quantity == 0):
			return "invalid player inventory slot"
	if data.has("counter_stock"):
		if not (data["counter_stock"] is Array):
			return "invalid counter stock"
		var counter_stock: Array = data["counter_stock"] as Array
		for raw_entry: Variant in counter_stock:
			if not (raw_entry is Dictionary):
				return "invalid counter stock entry"
			var entry: Dictionary = raw_entry as Dictionary
			for field: String in ["x", "y", "count"]:
				if not entry.has(field):
					return "invalid counter stock entry"
			if int(entry["count"]) < 0:
				return "invalid counter stock count"
	if data.has("plant_states"):
		if not (data["plant_states"] is Array):
			return "invalid plant states"
		var plant_states: Array = data["plant_states"] as Array
		for raw_entry: Variant in plant_states:
			if not (raw_entry is Dictionary):
				return "invalid plant state entry"
			var entry: Dictionary = raw_entry as Dictionary
			for field: String in ["x", "y", "watered_once", "grownup"]:
				if not entry.has(field):
					return "invalid plant state entry"
			if not (entry["watered_once"] is bool) or not (entry["grownup"] is bool):
				return "invalid plant state value"
			if entry.has("plant_kind") and not (entry["plant_kind"] is String):
				return "invalid plant state kind"
			if entry.has("stage") and int(entry["stage"]) < 0:
				return "invalid plant state stage"
	if data.has("ground_collectibles"):
		if not (data["ground_collectibles"] is Array):
			return "invalid ground collectibles"
		var ground_collectibles: Array = data["ground_collectibles"] as Array
		for raw_entry: Variant in ground_collectibles:
			if not (raw_entry is Dictionary):
				return "invalid ground collectible entry"
			var item: Dictionary = raw_entry as Dictionary
			for field: String in ["currency", "state", "x", "y"]:
				if not item.has(field):
					return "invalid ground collectible entry"
			var currency: String = str(item["currency"])
			if not ["seed", "gem", "money"].has(currency):
				return "invalid ground collectible currency"
			var state: String = str(item["state"])
			if not ["falling", "ready"].has(state):
				return "invalid ground collectible state"
	if data.has("day_phase"):
		var phase: String = str(data["day_phase"])
		if not ["building", "morning", "client", "seed_merchant", "night"].has(phase):
			return "invalid day phase"
	if data.has("runtime_agents") and not (data["runtime_agents"] is Dictionary):
		return "invalid runtime agents"
	return ""


func _save_summary(data: Dictionary) -> String:
	var progression_data: Dictionary = data.get("progression", {}) as Dictionary
	var layers: Dictionary = data.get("layers", {}) as Dictionary
	var plant_layer_count: int = 0
	var raw_plant_layer: Variant = layers.get("plantz", [])
	if raw_plant_layer is Array:
		var plant_layer_cells: Array = raw_plant_layer as Array
		plant_layer_count = plant_layer_cells.size()
	var plant_states: Array = []
	var raw_plant_states: Variant = data.get("plant_states", [])
	if raw_plant_states is Array:
		plant_states = raw_plant_states as Array
	var grown_count: int = 0
	var watered_count: int = 0
	for raw_entry: Variant in plant_states:
		if not (raw_entry is Dictionary):
			continue
		var entry: Dictionary = raw_entry as Dictionary
		if bool(entry.get("grownup", false)):
			grown_count += 1
		if bool(entry.get("watered_once", false)):
			watered_count += 1
	var counter_stock: Array = []
	var raw_counter_stock: Variant = data.get("counter_stock", [])
	if raw_counter_stock is Array:
		counter_stock = raw_counter_stock as Array
	var counter_total: int = 0
	for raw_counter: Variant in counter_stock:
		if raw_counter is Dictionary:
			var counter_entry: Dictionary = raw_counter as Dictionary
			counter_total += int(counter_entry.get("count", 0))
	var player_data: Dictionary = data.get("player", {}) as Dictionary
	var inventory_count: int = 0
	var raw_inventory: Variant = player_data.get("inventory", [])
	if raw_inventory is Array:
		var inventory: Array = raw_inventory as Array
		inventory_count = inventory.size()
	return "phase=%s day=%d seeds=%d gems=%d money=%d plant_layer=%d plant_states=%d watered=%d grown=%d counter_entries=%d counter_total=%d inventory_slots=%d" % [
		str(data.get("day_phase", "<missing>")),
		int(progression_data.get("nDays", 0)),
		int(progression_data.get("seeds", 0)),
		int(progression_data.get("gems", 0)),
		int(progression_data.get("money", 0)),
		plant_layer_count,
		plant_states.size(),
		watered_count,
		grown_count,
		counter_stock.size(),
		counter_total,
		inventory_count,
	]


func _live_scene_summary(scene: Node) -> String:
	var plant_manager: Node = scene.get_node_or_null("Map/PlantManager") if scene else null
	var rose_count_value: int = -1
	var grown_count_value: int = -1
	var unwatered_count_value: int = -1
	if plant_manager != null:
		if plant_manager.has_method("rose_count"):
			rose_count_value = int(plant_manager.call("rose_count"))
		if plant_manager.has_method("grownup_rose_count"):
			grown_count_value = int(plant_manager.call("grownup_rose_count"))
		if plant_manager.has_method("unwatered_rose_count"):
			unwatered_count_value = int(plant_manager.call("unwatered_rose_count"))
	var building_manager: Node = scene.get_node_or_null("Map/BuildingManager") if scene else null
	var counter_total: int = -1
	var counter_buildings: int = -1
	if building_manager != null and building_manager.has_method("total_counter_stock"):
		counter_total = int(building_manager.call("total_counter_stock"))
	if building_manager != null and building_manager.has_method("rose_shop_counter_count"):
		counter_buildings = int(building_manager.call("rose_shop_counter_count"))
	return "phase=%s day=%d seeds=%d gems=%d money=%d roses=%d grown=%d unwatered=%d counter_buildings=%d counter_total=%d" % [
		_get_day_phase(),
		progression.get_value(&"nDays"),
		progression.get_value(SEED_KEY),
		progression.get_value(GEM_KEY),
		progression.get_value(MONEY_KEY),
		rose_count_value,
		grown_count_value,
		unwatered_count_value,
		counter_buildings,
		counter_total,
	]


## Save/load correctness guard: monsters only exist at night. Finding one while any
## day phase is active means the run reached an illegal state, so log it loudly. This
## is detection only (the load path in BuildingManager also despawns the monster).
func _warn_if_day_phase_has_monsters(context: String) -> void:
	if GameState.is_night:
		return
	if get_tree().get_first_node_in_group(&"monsters") != null:
		push_error("[%s] Monster when its day." % context)
		_log("%s: monster present during a day phase" % context)


func _notify(message: String) -> void:
	var scene: Node = get_tree().current_scene
	var notif: Node = scene.get_node_or_null("GameUI/notif") if scene else null
	if notif and notif.has_method("show_notif"):
		notif.call("show_notif", message)
	else:
		print(message)


func _fail(message: String) -> void:
	_log(message)
	push_warning(message)
	_notify(message)


func _log(message: String) -> void:
	CppDebugOptions.save_log("[SAVE] Progression: " + message)
