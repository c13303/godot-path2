extends Node

const SAVE_PATH: String = "user://progression_save.json"
const SAVE_VERSION: int = 1
const PENDING_LOAD_META: StringName = &"pending_progression_load"
const LAYER_NAMES: Array[String] = [
	"floor",
	"plantz",
	"wallz",
	"traversable_buildings",
	"blocking_buildings",
]


func _ready() -> void:
	if not GameState.has_meta(PENDING_LOAD_META):
		return
	GameState.remove_meta(PENDING_LOAD_META)
	_log("Fresh scene ready; applying pending save before native player setup")
	var data: Dictionary = _read_save_data()
	if data.is_empty():
		return
	_apply_save_to_fresh_scene(data)


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


func save_progression() -> void:
	if _reject_during_night():
		return
	_log("Save started: %s" % ProjectSettings.globalize_path(SAVE_PATH))
	var scene: Node = get_tree().current_scene
	var layers: Dictionary = _get_layers(scene)
	var player: Node2D = _get_player()
	var game_ui: Node = scene.get_node_or_null("GameUI") if scene else null
	if layers.size() != LAYER_NAMES.size() or player == null or game_ui == null:
		_fail("Save failed: required game nodes are missing")
		return

	var inventory: Array[String] = _get_inventory(game_ui)
	var layer_data: Dictionary = {}
	for layer_name in LAYER_NAMES:
		var layer: TileMapLayer = layers[layer_name] as TileMapLayer
		var serialized_cells: Array[Dictionary] = _serialize_layer(layer)
		layer_data[layer_name] = serialized_cells
		_log("Captured layer %s: %d cells" % [layer_name, serialized_cells.size()])

	var data: Dictionary = {
		"version": SAVE_VERSION,
		"layers": layer_data,
		"player": {
			"position": [player.global_position.x, player.global_position.y],
			"inventory": inventory,
			"selected_quick_index": int(game_ui.get("selected_quick_index")),
		},
	}

	var json_text: String = JSON.stringify(data)
	var file: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.WRITE)
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


func _read_save_data() -> Dictionary:
	if not FileAccess.file_exists(SAVE_PATH):
		_fail("Load failed: no save file")
		return {}

	var file: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.READ)
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


func _get_inventory(game_ui: Node) -> Array[String]:
	var inventory: Array[String] = []
	var raw_inventory: Variant = game_ui.get("inventory_slots")
	if raw_inventory is Array:
		for raw_item: Variant in raw_inventory:
			inventory.append(str(raw_item))
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
	var inventory: Array[String] = []
	for raw_item: Variant in saved_inventory:
		inventory.append(str(raw_item))
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


func _validate_save(data: Dictionary) -> String:
	if int(data.get("version", -1)) != SAVE_VERSION:
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
	print("[Progression] " + message)
