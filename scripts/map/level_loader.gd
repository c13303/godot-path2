class_name LevelLoader
extends Node

## Loads the authored map for a run before the game starts. A "level" is the three
## authored TileMapLayers (floor / watersources / wallz); every level_*.tscn is a
## self-contained, human-designed map that can be swapped here without touching
## mainRun.
##
## This node is placed as the FIRST child of the root game node. During scene
## instantiation _enter_tree runs top-down, so when this fires the MonTilemap host
## has not entered the tree yet — it is neither "inside tree" nor busy setting up
## children, so add_child() on it is allowed (adding to a node that is mid-init,
## e.g. our own parent, is what Godot forbids). The injected layers then enter and
## become ready in normal propagation order, so by the time any gameplay system
## resolves Map/MonTilemap/floor (etc.) in _ready, the layers already exist —
## loading a level never changes how the rest of the game runs.

## Host that receives the level's layers, relative to this node (root's child).
@export var montilemap_path: NodePath = ^"../Map/MonTilemap"
## The level to load before the game starts. Assigned in mainRun.tscn.
@export var level_scene: PackedScene

## The authored layers a level provides, in the order they should be hosted.
const LEVEL_LAYER_NAMES: PackedStringArray = ["floor", "watersources", "wallz"]
const SPAWNER_CONTAINER_NAMES: PackedStringArray = ["spawner", "spawners"]
const SPAWNER_KIND_MONSTER: StringName = &"monster"
const SPAWNER_KIND_CLIENT: StringName = &"client"
const CLIENT_FREQUENCY_META: StringName = &"frequency_client"

var _loaded_level_scene_path: String = ""
var _loaded_spawn_playlist: LevelSpawnPlaylist
var _loaded_spawner_bindings: Array[SpawnerBinding] = []
var _loaded_starting_seeds: int = 20
var _loaded_starting_gems: int = 1000
var _loaded_starting_money: int = 0
var _loaded_starting_weapons: Array[StringName] = [&"spray"]
var _loaded_shop_available_items: Array[StringName] = [&"rose", &"turret1", &"wall", &"seed", &"spray", &"beam", &"sword", &"bomb"]
var _loaded_shop_prices: Dictionary = {
	&"rose": 1,
	&"turret1": 5,
	&"wall": 100,
	&"seed": 2,
	&"spray": 100,
	&"beam": 100,
	&"sword": 100,
	&"bomb": 100,
}
var _loaded_rose_shop_counter_limit: int = 2

func _enter_tree() -> void:
	_load_level()

func _load_level() -> void:
	var scene_to_load: PackedScene = _resolve_level_scene()
	if scene_to_load == null:
		push_error("LevelLoader: no level_scene assigned; map layers will be missing.")
		return

	var host: Node = get_node_or_null(montilemap_path)
	if host == null:
		push_error("LevelLoader: MonTilemap host not found at '%s'." % montilemap_path)
		return

	# Instanced off-tree; we only keep its authored layers and discard the shell.
	var level_root: Node = scene_to_load.instantiate()
	_capture_level_spawn_config(level_root, scene_to_load.resource_path)
	_capture_level_spawner_bindings(level_root)
	for layer_name in LEVEL_LAYER_NAMES:
		var layer: Node = level_root.get_node_or_null(NodePath(layer_name))
		if layer == null:
			push_warning("LevelLoader: level '%s' is missing layer '%s'." % [scene_to_load.resource_path, layer_name])
			continue
		if host.has_node(NodePath(layer_name)):
			push_warning("LevelLoader: host already has a '%s' layer; skipping." % layer_name)
			continue
		level_root.remove_child(layer)
		layer.name = layer_name
		_clear_owner_recursive(layer)
		host.add_child(layer)
	_reparent_spawner_container(level_root, host)

	level_root.free()
	_loaded_level_scene_path = scene_to_load.resource_path


## Clears the owner of a node and all its descendants so it can be re-parented
## under a host in another scene without triggering owner-inconsistency warnings.
func _clear_owner_recursive(node: Node) -> void:
	node.owner = null
	for child in node.get_children():
		_clear_owner_recursive(child)


func get_loaded_level_scene_path() -> String:
	return _loaded_level_scene_path


func get_loaded_spawn_playlist() -> LevelSpawnPlaylist:
	return _loaded_spawn_playlist


func get_loaded_spawner_bindings() -> Array[SpawnerBinding]:
	var bindings: Array[SpawnerBinding] = []
	for binding: SpawnerBinding in _loaded_spawner_bindings:
		bindings.append(binding)
	return bindings


func get_loaded_starting_seeds() -> int:
	return _loaded_starting_seeds


func get_loaded_starting_gems() -> int:
	return _loaded_starting_gems


func get_loaded_starting_money() -> int:
	return _loaded_starting_money


func get_loaded_starting_weapons() -> Array[StringName]:
	var weapons: Array[StringName] = []
	for weapon_id: StringName in _loaded_starting_weapons:
		weapons.append(weapon_id)
	return weapons


func get_loaded_rose_shop_counter_limit() -> int:
	return _loaded_rose_shop_counter_limit

func get_loaded_shop_available_items() -> Array[StringName]:
	var item_ids: Array[StringName] = []
	for item_id: StringName in _loaded_shop_available_items:
		item_ids.append(item_id)
	return item_ids


func get_loaded_shop_prices() -> Dictionary:
	return _loaded_shop_prices.duplicate()


func _resolve_level_scene() -> PackedScene:
	var selected_path: String = GameState.get_selected_level_scene_path()
	if selected_path != "":
		var selected_resource: Resource = load(selected_path)
		var selected_scene: PackedScene = selected_resource as PackedScene
		if selected_scene != null:
			return selected_scene
		push_warning("LevelLoader: selected level '%s' could not be loaded; using exported level." % selected_path)
	return level_scene


func _capture_level_spawn_config(level_root: Node, level_scene_path: String) -> void:
	_loaded_spawn_playlist = null
	_loaded_spawner_bindings.clear()
	_loaded_starting_seeds = 20
	_loaded_starting_gems = 1000
	_loaded_starting_money = 0
	_loaded_starting_weapons = [&"spray"]
	_loaded_shop_available_items = [&"rose", &"turret1", &"wall", &"seed", &"spray", &"beam", &"sword", &"bomb"]
	_loaded_shop_prices = {
		&"rose": 1,
		&"turret1": 5,
		&"wall": 100,
		&"seed": 2,
		&"spray": 100,
		&"beam": 100,
		&"sword": 100,
		&"bomb": 100,
	}
	_loaded_rose_shop_counter_limit = 2
	if level_root == null:
		return
	var config: LevelSpawnConfig = level_root as LevelSpawnConfig
	if config == null:
		config = level_root.get_node_or_null("LevelSpawnConfig") as LevelSpawnConfig
	if config != null:
		_loaded_spawn_playlist = config.spawn_playlist
		_loaded_starting_seeds = config.starting_seeds
		_loaded_starting_gems = config.starting_gems
		_loaded_starting_money = config.starting_money
		_loaded_starting_weapons = _valid_starting_weapons(config.starting_weapons)
		_loaded_shop_available_items = _valid_shop_available_items(config.shop_available_items)
		_loaded_shop_prices = _valid_shop_prices(config.shop_prices)
		_loaded_rose_shop_counter_limit = clampi(config.rose_shop_counter_limit, 1, 99)
	if _loaded_spawn_playlist != null:
		return
	var fallback_playlist: LevelSpawnPlaylist = _load_default_spawn_playlist(level_scene_path)
	if fallback_playlist != null:
		_loaded_spawn_playlist = fallback_playlist


func _load_default_spawn_playlist(level_scene_path: String) -> LevelSpawnPlaylist:
	if level_scene_path == "":
		return null
	var playlist_path: String = "res://scenes/levels/playlists/%s_spawn_playlist.tres" % level_scene_path.get_file().get_basename()
	if not ResourceLoader.exists(playlist_path):
		return null
	var resource: Resource = load(playlist_path)
	return resource as LevelSpawnPlaylist


func _valid_starting_weapons(raw_weapons: Array[StringName]) -> Array[StringName]:
	var weapons: Array[StringName] = []
	var seen: Dictionary = {}
	for weapon_id: StringName in raw_weapons:
		var item_id: String = String(weapon_id)
		if item_id == "" or seen.has(weapon_id) or not ItemCatalog.is_weapon(item_id):
			continue
		seen[weapon_id] = true
		weapons.append(weapon_id)
	return weapons


func _valid_shop_available_items(raw_item_ids: Array[StringName]) -> Array[StringName]:
	var item_ids: Array[StringName] = []
	var seen: Dictionary = {}
	for item_id: StringName in raw_item_ids:
		var item_id_string: String = String(item_id)
		if item_id_string == "" or seen.has(item_id) or not _is_configurable_shop_item(item_id):
			continue
		seen[item_id] = true
		item_ids.append(item_id)
	return item_ids


func _valid_shop_prices(raw_prices: Dictionary) -> Dictionary:
	var prices: Dictionary = {}
	for item_id: StringName in _configurable_shop_item_ids():
		var raw_price: Variant = raw_prices.get(item_id, raw_prices.get(String(item_id), ItemCatalog.get_price(String(item_id))))
		prices[item_id] = maxi(0, int(raw_price))
	return prices


func _is_configurable_shop_item(item_id: StringName) -> bool:
	return _configurable_shop_item_ids().has(item_id)


func _configurable_shop_item_ids() -> Array[StringName]:
	return [&"rose", &"turret1", &"wall", &"seed", &"spray", &"beam", &"sword", &"bomb"]


func _capture_level_spawner_bindings(level_root: Node) -> void:
	var floor_layer: TileMapLayer = level_root.get_node_or_null("floor") as TileMapLayer
	if floor_layer == null:
		push_warning("LevelLoader: level '%s' has no floor layer; spawner node cells cannot be derived." % _level_path_for_log())
		return
	var spawner_container: Node = _find_spawner_container(level_root)
	if spawner_container == null:
		return
	for child: Node in spawner_container.get_children():
		var spawner_node: Node2D = child as Node2D
		if spawner_node == null:
			continue
		var spawner_id: StringName = StringName(spawner_node.name)
		if spawner_id == &"":
			continue
		var kind: StringName = _spawner_kind_from_name(String(spawner_id))
		if kind == &"":
			continue
		var local_pos: Vector2 = floor_layer.to_local(spawner_node.global_position)
		var cell: Vector2i = floor_layer.local_to_map(local_pos)
		var exit_cell: Vector2i = cell
		var exit_node: Node2D = spawner_node.get_node_or_null("exit") as Node2D
		if exit_node != null:
			var exit_local_pos: Vector2 = floor_layer.to_local(exit_node.global_position)
			exit_cell = floor_layer.local_to_map(exit_local_pos)
		var binding: SpawnerBinding = SpawnerBinding.new()
		binding.spawner_id = spawner_id
		binding.kind = kind
		binding.cell = cell
		binding.exit_cell = exit_cell
		if kind == SPAWNER_KIND_CLIENT:
			binding.frequency_client = maxf(0.0, float(spawner_node.get_meta(CLIENT_FREQUENCY_META, 1.0)))
		_loaded_spawner_bindings.append(binding)


func _spawner_kind_from_name(spawner_name: String) -> StringName:
	if spawner_name.begins_with("monster"):
		return SPAWNER_KIND_MONSTER
	if spawner_name.begins_with("client"):
		return SPAWNER_KIND_CLIENT
	return &""


func _reparent_spawner_container(level_root: Node, host: Node) -> void:
	var spawner_container: Node = _find_spawner_container(level_root)
	if spawner_container == null:
		return
	if host.has_node(NodePath(spawner_container.name)):
		push_warning("LevelLoader: host already has a '%s' node; skipping level spawner visuals." % spawner_container.name)
		return
	level_root.remove_child(spawner_container)
	_clear_owner_recursive(spawner_container)
	host.add_child(spawner_container)


func _find_spawner_container(level_root: Node) -> Node:
	for container_name: String in SPAWNER_CONTAINER_NAMES:
		var container: Node = level_root.get_node_or_null(NodePath(container_name))
		if container != null:
			return container
	return null


func _level_path_for_log() -> String:
	return _loaded_level_scene_path if _loaded_level_scene_path != "" else "<loading>"
