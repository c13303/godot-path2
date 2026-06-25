extends Node

signal day_started(day_number: int)

## Manual save slot, written/read by the F5/F9 hotkeys.
const SAVE_PATH: String = "user://progression_save.json"
## Auto-save slot, written on each new day / on quit and restored on launch.
## Kept separate from SAVE_PATH so auto-saving never clobbers a manual F5 save.
const AUTOSAVE_PATH: String = "user://progression_autosave.json"
const SAVE_VERSION: int = 2
const SEED_KEY: StringName = &"seeds"
const GEM_KEY: StringName = &"gems"
const WATER_RESERVE_KEY: StringName = &"water_reserve"
const PENDING_LOAD_META: StringName = &"pending_progression_load"
const LAYER_NAMES: Array[String] = [
	"floor",
	"plantz",
	"wallz",
	"traversable_buildings",
	"blocking_buildings",
]


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
class Progression:
	var props: Array[ProgressionProp] = [
		ProgressionProp.new(&"nDays", "Day", 1),
		ProgressionProp.new(&"monster_per_day", "Monster per day", 1),
		ProgressionProp.new(&"monster_per_rose", "Monster per rose", 1),
		ProgressionProp.new(&"seeds", "Seeds", 5),
		ProgressionProp.new(&"gems", "Gems", 0),
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
	_update_progression_ui(key == SEED_KEY, key == GEM_KEY)
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
	_update_progression_ui(key == SEED_KEY, key == GEM_KEY)
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


func _ready() -> void:
	# GameState is an autoload, so reconnect every time a fresh scene loads.
	if not GameState.mode_changed.is_connected(_on_game_mode_changed):
		GameState.mode_changed.connect(_on_game_mode_changed)

	if GameState.has_meta(PENDING_LOAD_META):
		GameState.remove_meta(PENDING_LOAD_META)
		_log("Fresh scene ready; applying pending save before native player setup")
		var data: Dictionary = _read_save_data()
		if not data.is_empty():
			_apply_save_to_fresh_scene(data)

	_update_progression_ui()


## A night->day transition means a new day has begun.
func _on_game_mode_changed(is_night: bool) -> void:
	if is_night:
		return
	progression.add(&"nDays", 1)
	var day_number: int = progression.get_value(&"nDays")
	_update_day_label(day_number)
	day_started.emit(day_number)
	_log("New day started: Day %d" % day_number)
	_update_progression_ui()


## Show the current day on the dedicated day label, e.g. "day 3".
func _update_day_label(day_number: int) -> void:
	var label: RichTextLabel = _get_day_label()
	if label != null:
		label.text = "day %d" % day_number


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
	return scene.get_node_or_null("GameUI/top right/seedIcon/seedQT") as RichTextLabel


func _get_gem_label() -> RichTextLabel:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return null
	return scene.get_node_or_null("GameUI/top right/gemIcon/gemQT") as RichTextLabel


func _get_water_reserve_bar() -> ProgressBar:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return null
	return scene.get_node_or_null("GameUI/bottom left anchor/waterReserve") as ProgressBar


## Render every progression prop, one per line: "<display name>: <value>".
## Adding a prop to Progression.props makes it appear here automatically.
func _update_progression_ui(animate_seed_label: bool = false, animate_gem_label: bool = false) -> void:
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

	_update_day_label(progression.get_value(&"nDays"))
	var water_reserve_bar: ProgressBar = _get_water_reserve_bar()
	if water_reserve_bar != null:
		var water_maximum: int = maxi(1, progression.get_value(&"water_reserve_max"))
		var water_current: int = clampi(progression.get_value(WATER_RESERVE_KEY), 0, water_maximum)
		water_reserve_bar.max_value = float(water_maximum)
		water_reserve_bar.value = float(water_current)

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


func save_progression(save_path: String = SAVE_PATH) -> void:
	if _reject_during_night():
		return
	_log("Save started: %s" % ProjectSettings.globalize_path(save_path))
	var scene: Node = get_tree().current_scene
	var layers: Dictionary = _get_layers(scene)
	var player: Node2D = _get_player()
	var game_ui: Node = scene.get_node_or_null("GameUI") if scene else null
	if layers.size() != LAYER_NAMES.size() or player == null or game_ui == null:
		_fail("Save failed: required game nodes are missing")
		return

	var inventory: Array[Dictionary] = _get_inventory(game_ui)
	var layer_data: Dictionary = {}
	for layer_name in LAYER_NAMES:
		var layer: TileMapLayer = layers[layer_name] as TileMapLayer
		var serialized_cells: Array[Dictionary] = _serialize_layer(layer)
		layer_data[layer_name] = serialized_cells
		_log("Captured layer %s: %d cells" % [layer_name, serialized_cells.size()])

	var data: Dictionary = {
		"version": SAVE_VERSION,
		"progression": progression.to_dict(),
		"layers": layer_data,
		"player": {
			"position": [player.global_position.x, player.global_position.y],
			"inventory": inventory,
			"selected_quick_index": int(game_ui.get("selected_quick_index")),
		},
	}

	var json_text: String = JSON.stringify(data)
	var file: FileAccess = FileAccess.open(save_path, FileAccess.WRITE)
	if file == null:
		_fail("Save failed: cannot open save file")
		return
	file.store_string(json_text)
	file.close()
	_log("Save complete: player=%s inventory_slots=%d bytes=%d" % [
		str(player.global_position), inventory.size(), json_text.to_utf8_buffer().size()
	])
	_notify("Game saved")


func load_progression() -> void:
	if _reject_during_night():
		return
	_log("Load started: %s" % ProjectSettings.globalize_path(SAVE_PATH))
	var data: Dictionary = _read_save_data()
	if data.is_empty():
		return

	_unregister_scene_agents()
	GameState.set_meta(PENDING_LOAD_META, true)
	_log("Save validated; reloading current scene")
	var reload_error: Error = get_tree().reload_current_scene()
	if reload_error != OK:
		GameState.remove_meta(PENDING_LOAD_META)
		_fail("Load failed: scene reload error %d" % int(reload_error))


## Write the auto-save slot (separate file from the F5/F9 manual slot).
func auto_save() -> void:
	save_progression(AUTOSAVE_PATH)


## Startup auto-load: restore the auto-save slot into the freshly loaded scene.
## No scene reload happens here (the scene is already pristine on launch). Skips
## silently when there is no auto-save, or when a pending-load already applied a
## manual save during _ready (the F9 reload path).
func load_on_start() -> void:
	if _save_applied:
		return
	if not FileAccess.file_exists(AUTOSAVE_PATH):
		_log("No auto-save found on start; beginning a fresh game")
		return
	var data: Dictionary = _read_save_data(AUTOSAVE_PATH)
	if data.is_empty():
		return
	_log("Auto-loading save on start")
	_apply_save_to_fresh_scene(data)


## Wipe the auto-save slot and restart a brand-new game (Day 1, defaults). The
## fresh scene reload recreates progression at its defaults; deleting the
## auto-save first stops the next launch (and the post-reload load_on_start)
## from restoring it. The manual F5 slot is intentionally left untouched.
func reset_game() -> void:
	if FileAccess.file_exists(AUTOSAVE_PATH):
		var remove_error: Error = DirAccess.remove_absolute(ProjectSettings.globalize_path(AUTOSAVE_PATH))
		if remove_error == OK:
			_log("Auto-save deleted; resetting to a new game")
		else:
			_fail("Reset: could not delete save (error %d)" % int(remove_error))
	# A leftover pending-load flag must never carry into the fresh game.
	if GameState.has_meta(PENDING_LOAD_META):
		GameState.remove_meta(PENDING_LOAD_META)
	GameState.set_night(false)
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
	var group_names: Array[StringName] = [&"player", &"main_chars", &"monsters"]
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

	var saved_layers: Dictionary = data["layers"] as Dictionary
	for layer_name in LAYER_NAMES:
		var layer: TileMapLayer = layers[layer_name] as TileMapLayer
		var cells: Array = saved_layers[layer_name] as Array
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
	_save_applied = true
	_log("Load complete: player=%s inventory_slots=%d" % [
		str(player.global_position), (player_data["inventory"] as Array).size()
	])
	_notify("Game loaded")


func _reject_during_night() -> bool:
	if not GameState.is_night:
		return false
	_log("Operation rejected because night is active")
	_notify("Save/load unavailable during night")
	return true


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
	game_ui.set("selected_quick_index", int(player_data.get("selected_quick_index", 0)))
	if game_ui.has_method("_refresh_all_slots"):
		game_ui.call("_refresh_all_slots")
	_log("Inventory restored: %d slots, selected=%d" % [
		inventory.size(), int(player_data.get("selected_quick_index", 0))
	])


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
	return ""


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
	pass
