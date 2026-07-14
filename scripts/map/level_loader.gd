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
const LEVEL_LAYER_NAMES: PackedStringArray = ["floor", "watersources", "wallz", "fences"]
const SPAWNER_CONTAINER_NAMES: PackedStringArray = ["spawner", "spawners"]
const SPAWNER_KIND_MONSTER: StringName = &"monster"
const SPAWNER_KIND_CLIENT: StringName = &"client"
const SPAWNER_KIND_MERCHANT: StringName = &"merchant"
const CLIENT_FREQUENCY_META: StringName = &"frequency_client"
const ENEMY_SPAWNER_TEXTURE_PATH: String = "res://assets/sprites/legval/spawner.png"
const FRIENDLY_SPAWNER_TEXTURE_PATH: String = "res://assets/sprites/legval/clientspawner.png"
const DEFAULT_TOOL_SHOP_AVAILABLE_ITEM_IDS: Array[StringName] = [&"rose", &"imperial_seed", &"turret_epine", &"ronce", &"fence", &"kraken"]
const DEFAULT_MERCHANT_AVAILABLE_ITEM_IDS: Array[StringName] = [&"seed", &"imperial_seed", &"spray", &"beam", &"sword", &"bomb"]
const DEFAULT_LEGACY_SHOP_AVAILABLE_ITEM_IDS: Array[StringName] = [&"rose", &"imperial_seed", &"turret_epine", &"ronce", &"fence", &"kraken", &"seed", &"spray", &"beam", &"sword", &"bomb"]
const RESERVOIR_CONTAINER_NAME: String = "reservoirs"
const RESERVOIR_Z_INDEX: int = 510
## Wall tile stamped on wallz under the reservoir base so its cell is non-walkable
## and non-buildable. The game only checks that a wallz cell has a source (>= 0), so
## we use a fully transparent atlas tile (15,0 in tileset32x32) that blocks
## nav/building but renders nothing — the reservoir sprite's own z-order is untouched.
## Must not collide with special atlases: exit wall (13,0), spawner (14,0),
## plantsToTarget (13,1).
const RESERVOIR_BASE_WALL_ATLAS: Vector2i = Vector2i(15, 0)
const RESERVOIR_WATER_TEXTURE: Texture2D = preload("res://assets/sprites/legval/reservoir_water.png")
const RESERVOIR_WATER_FILL_SCRIPT: Script = preload("res://scripts/visual_fx/reservoir_water_fill.gd")
const RESERVOIR_RUNTIME_SCRIPT: Script = preload("res://scripts/map/reservoir_runtime.gd")

var _loaded_level_scene_path: String = ""
var _loaded_spawn_playlist: LevelSpawnPlaylist
var _loaded_spawner_bindings: Array[SpawnerBinding] = []
var _loaded_named_spot_cells: Dictionary = {}  # StringName -> Vector2i
# Authored map extent, captured from the level's mapBounds node before the shell is
# freed. Cells drive the native flow field's size/origin; world drives the camera
# scroll limits. Empty (zero size) when the level has no mapBounds node, in which case
# native falls back to the floor used-rect and the camera stays unclamped.
var _loaded_map_bounds_cells: Rect2i = Rect2i()
var _loaded_map_bounds_world: Rect2 = Rect2()
var _loaded_starting_seeds: int = 20
var _loaded_starting_gems: int = 1000
var _loaded_starting_money: int = 0
var _loaded_starting_bamboo: int = 0
var _loaded_starting_currencies: Dictionary = {}
var _loaded_starting_weapons: Array[StringName] = [&"spray"]
var _loaded_starting_items: Dictionary = {}
var _loaded_starting_item_toolbuild_hidden: Array[StringName] = []
var _loaded_monster_drop_seed_chance_percent: int = 0
var _loaded_tool_shop_available_items: Array[StringName] = [&"rose", &"imperial_seed", &"turret_epine", &"ronce", &"fence", &"kraken"]
var _loaded_tool_shop_prices: Dictionary = {
	&"rose": 1,
	&"turret_epine": 10,
	&"ronce": 1,
	&"fence": 1,
	&"kraken": 20,
}
var _loaded_tool_shop_growth_price_factors: Dictionary = {
	&"ronce": 2.0,
}
var _loaded_tool_shop_days: Dictionary = {}
var _loaded_merchant_available_items: Array[StringName] = [&"seed", &"imperial_seed", &"spray", &"beam", &"sword", &"bomb"]
var _loaded_merchant_prices: Dictionary = {
	&"seed": 2,
	&"spray": 100,
	&"beam": 100,
	&"sword": 100,
	&"bomb": 100,
}
var _loaded_merchant_days: Dictionary = {}
var _loaded_merchant_growth_price_factors: Dictionary = {}
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
	# Authored houses must be normalized (sprite snapped, footprint walls stamped, paired spot
	# markers moved to the entrance) BEFORE spawner bindings are captured: a paired spot such as
	# seedmerchent_spot is converted into the merchant's stored spot_cell, so it has to be in its
	# final position first. HouseManager owns the geometry; LevelLoader only invokes it.
	HouseManager.prepare_authored_houses(level_root)
	_capture_level_spawner_bindings(level_root)
	_capture_level_map_bounds(level_root)
	for layer_name in LEVEL_LAYER_NAMES:
		var layer: Node = level_root.get_node_or_null(NodePath(layer_name))
		if layer == null:
			if layer_name == "fences":
				continue
			push_warning("LevelLoader: level '%s' is missing layer '%s'." % [scene_to_load.resource_path, layer_name])
			continue
		if host.has_node(NodePath(layer_name)):
			push_warning("LevelLoader: host already has a '%s' layer; skipping." % layer_name)
			continue
		level_root.remove_child(layer)
		layer.name = layer_name
		_clear_owner_recursive(layer)
		host.add_child(layer)
	_ensure_optional_fences_layer(host)
	_reparent_spawner_container(level_root, host)
	_reparent_reservoir_nodes(level_root, host)

	level_root.free()
	_loaded_level_scene_path = scene_to_load.resource_path


## Clears the owner of a node and all its descendants so it can be re-parented
## under a host in another scene without triggering owner-inconsistency warnings.
func _clear_owner_recursive(node: Node) -> void:
	node.owner = null
	for child in node.get_children():
		_clear_owner_recursive(child)


func _ensure_optional_fences_layer(host: Node) -> void:
	if host == null or host.has_node(^"fences"):
		return
	var wall_layer: TileMapLayer = host.get_node_or_null(^"wallz") as TileMapLayer
	var fence_layer: TileMapLayer = TileMapLayer.new()
	fence_layer.name = "fences"
	fence_layer.z_index = -49
	fence_layer.navigation_enabled = false
	if wall_layer != null:
		fence_layer.tile_set = wall_layer.tile_set
	host.add_child(fence_layer)


func get_loaded_level_scene_path() -> String:
	return _loaded_level_scene_path


func get_loaded_spawn_playlist() -> LevelSpawnPlaylist:
	return _loaded_spawn_playlist


func get_loaded_spawner_bindings() -> Array[SpawnerBinding]:
	var bindings: Array[SpawnerBinding] = []
	for binding: SpawnerBinding in _loaded_spawner_bindings:
		bindings.append(binding)
	return bindings


func get_loaded_named_spot_cells() -> Dictionary:
	return _loaded_named_spot_cells.duplicate()


## Authored map extent in tilemap cells (position = min cell, size = cell count).
## Zero size when the level has no mapBounds node.
func get_loaded_map_bounds_cells() -> Rect2i:
	return _loaded_map_bounds_cells


## Authored map extent in world coordinates. Zero size when the level has no
## mapBounds node.
func get_loaded_map_bounds_world() -> Rect2:
	return _loaded_map_bounds_world


func get_loaded_starting_seeds() -> int:
	return _loaded_starting_seeds


func get_loaded_starting_gems() -> int:
	return _loaded_starting_gems


func get_loaded_starting_money() -> int:
	return _loaded_starting_money


func get_loaded_starting_bamboo() -> int:
	return _loaded_starting_bamboo


func get_loaded_starting_currencies() -> Dictionary:
	return _loaded_starting_currencies.duplicate()


func get_loaded_starting_weapons() -> Array[StringName]:
	var weapons: Array[StringName] = []
	for weapon_id: StringName in _loaded_starting_weapons:
		weapons.append(weapon_id)
	return weapons


func get_loaded_starting_items() -> Dictionary:
	return _loaded_starting_items.duplicate()


## True when the level author unchecked this item's "Available" box in the Rose Level
## editor, meaning it must not appear in the toolbuild vertical build menu at all.
func is_starting_item_toolbuild_hidden(item_id: String) -> bool:
	return _loaded_starting_item_toolbuild_hidden.has(StringName(item_id))


func get_loaded_monster_drop_seed_chance_percent() -> int:
	return _loaded_monster_drop_seed_chance_percent


func get_loaded_rose_shop_counter_limit() -> int:
	return _loaded_rose_shop_counter_limit

func get_loaded_tool_shop_available_items() -> Array[StringName]:
	var item_ids: Array[StringName] = []
	for item_id: StringName in _loaded_tool_shop_available_items:
		item_ids.append(item_id)
	return item_ids


func get_loaded_tool_shop_prices() -> Dictionary:
	return _loaded_tool_shop_prices.duplicate()


func get_loaded_tool_shop_growth_price_factors() -> Dictionary:
	return _loaded_tool_shop_growth_price_factors.duplicate()


func get_loaded_tool_shop_days() -> Dictionary:
	return _loaded_tool_shop_days.duplicate()


func get_loaded_merchant_available_items() -> Array[StringName]:
	var item_ids: Array[StringName] = []
	for item_id: StringName in _loaded_merchant_available_items:
		item_ids.append(item_id)
	return item_ids


func get_loaded_merchant_prices() -> Dictionary:
	return _loaded_merchant_prices.duplicate()


func get_loaded_merchant_days() -> Dictionary:
	return _loaded_merchant_days.duplicate()


func get_loaded_merchant_growth_price_factors() -> Dictionary:
	return _loaded_merchant_growth_price_factors.duplicate()


func get_loaded_shop_available_items() -> Array[StringName]:
	var item_ids: Array[StringName] = []
	for item_id: StringName in _loaded_tool_shop_available_items:
		item_ids.append(item_id)
	for item_id: StringName in _loaded_merchant_available_items:
		if not item_ids.has(item_id):
			item_ids.append(item_id)
	return item_ids


func get_loaded_shop_prices() -> Dictionary:
	var prices: Dictionary = _loaded_tool_shop_prices.duplicate()
	for item_id: StringName in _merchant_item_ids():
		prices[item_id] = int(_loaded_merchant_prices.get(item_id, ItemCatalog.get_price(String(item_id))))
	return prices.duplicate()


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
	_loaded_map_bounds_cells = Rect2i()
	_loaded_map_bounds_world = Rect2()
	_loaded_starting_seeds = 20
	_loaded_starting_gems = 1000
	_loaded_starting_money = 0
	_loaded_starting_bamboo = 0
	_loaded_starting_currencies = {}
	_loaded_starting_weapons = [&"spray"]
	_loaded_starting_items = {}
	_loaded_starting_item_toolbuild_hidden = []
	_loaded_monster_drop_seed_chance_percent = 0
	_loaded_tool_shop_available_items = _default_shop_available_items(DEFAULT_TOOL_SHOP_AVAILABLE_ITEM_IDS)
	_loaded_tool_shop_prices = _default_shop_prices(_tool_shop_item_ids())
	_loaded_tool_shop_growth_price_factors = {
		&"ronce": 2.0,
	}
	_loaded_tool_shop_days = {}
	_loaded_merchant_available_items = _default_shop_available_items(DEFAULT_MERCHANT_AVAILABLE_ITEM_IDS)
	_loaded_merchant_prices = _default_shop_prices(_merchant_item_ids())
	_loaded_merchant_days = {}
	_loaded_merchant_growth_price_factors = {}
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
		_loaded_starting_bamboo = config.starting_bamboo
		_loaded_starting_currencies = _valid_starting_currencies(config.starting_currencies)
		_apply_legacy_starting_currencies()
		_loaded_starting_weapons = _valid_starting_weapons(config.starting_weapons)
		_loaded_starting_items = _valid_starting_items(config.starting_items)
		_loaded_starting_item_toolbuild_hidden = _valid_toolbuild_hidden_items(config.starting_item_toolbuild_hidden)
		_loaded_monster_drop_seed_chance_percent = clampi(config.monster_drop_seed_chance_percent, 0, 100)
		_loaded_tool_shop_available_items = _valid_shop_available_items(config.tool_shop_available_items, _tool_shop_item_ids())
		_loaded_tool_shop_prices = _valid_shop_prices(config.tool_shop_prices, _tool_shop_item_ids())
		_loaded_tool_shop_growth_price_factors = _valid_shop_growth_price_factors(config.tool_shop_growth_price_factors, _tool_shop_item_ids())
		_loaded_tool_shop_days = _valid_shop_days(config.tool_shop_days, _tool_shop_item_ids())
		_loaded_merchant_available_items = _valid_shop_available_items(config.merchant_available_items, _merchant_item_ids())
		_loaded_merchant_prices = _valid_shop_prices(config.merchant_prices, _merchant_item_ids())
		_loaded_merchant_days = _valid_shop_days(config.merchant_days, _merchant_item_ids())
		_loaded_merchant_growth_price_factors = _valid_shop_growth_price_factors(config.merchant_growth_price_factors, _merchant_item_ids())
		var legacy_available_items: Array[StringName] = _valid_shop_available_items(config.shop_available_items, _legacy_shop_item_ids())
		var legacy_prices: Dictionary = _valid_shop_prices(config.shop_prices, _legacy_shop_item_ids())
		if not _same_string_name_array(legacy_available_items, _default_shop_available_items(DEFAULT_LEGACY_SHOP_AVAILABLE_ITEM_IDS)):
			if _same_string_name_array(_loaded_tool_shop_available_items, _default_shop_available_items(DEFAULT_TOOL_SHOP_AVAILABLE_ITEM_IDS)):
				_loaded_tool_shop_available_items = _valid_shop_available_items(legacy_available_items, _tool_shop_item_ids())
			if _same_string_name_array(_loaded_merchant_available_items, _default_shop_available_items(DEFAULT_MERCHANT_AVAILABLE_ITEM_IDS)):
				_loaded_merchant_available_items = _valid_shop_available_items(legacy_available_items, _merchant_item_ids())
		if legacy_prices != _default_shop_prices(_legacy_shop_item_ids()):
			if _loaded_tool_shop_prices == _default_shop_prices(_tool_shop_item_ids()):
				_loaded_tool_shop_prices = _valid_shop_prices(legacy_prices, _tool_shop_item_ids())
			if _loaded_merchant_prices == _default_shop_prices(_merchant_item_ids()):
				_loaded_merchant_prices = _valid_shop_prices(legacy_prices, _merchant_item_ids())
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


## Sanitize the authored starting-items map to { StringName item_id -> int quantity>0 },
## dropping unknown item ids and non-positive quantities. Keys may be authored as either
## String or StringName.
func _valid_starting_items(raw_items: Dictionary) -> Dictionary:
	var items: Dictionary = {}
	for raw_key: Variant in raw_items.keys():
		var item_id: StringName = StringName(str(raw_key))
		if item_id == &"" or not ItemCatalog.get_item_def(String(item_id)):
			continue
		var quantity: int = int(raw_items[raw_key])
		if quantity <= 0:
			continue
		items[item_id] = quantity
	return items


func _valid_starting_currencies(raw_currencies: Dictionary) -> Dictionary:
	var currencies: Dictionary = {}
	for raw_key: Variant in raw_currencies.keys():
		var currency: StringName = StringName(str(raw_key))
		if currency == &"" or not CurrencyCatalog.has_currency(currency):
			continue
		var quantity: int = int(raw_currencies[raw_key])
		if quantity < 0:
			continue
		currencies[currency] = quantity
	return currencies


func _apply_legacy_starting_currencies() -> void:
	if _loaded_starting_currencies.has(&"seed"):
		_loaded_starting_seeds = int(_loaded_starting_currencies[&"seed"])
	else:
		_loaded_starting_currencies[&"seed"] = _loaded_starting_seeds
	if _loaded_starting_currencies.has(&"gem"):
		_loaded_starting_gems = int(_loaded_starting_currencies[&"gem"])
	else:
		_loaded_starting_currencies[&"gem"] = _loaded_starting_gems
	if _loaded_starting_currencies.has(&"money"):
		_loaded_starting_money = int(_loaded_starting_currencies[&"money"])
	else:
		_loaded_starting_currencies[&"money"] = _loaded_starting_money
	if _loaded_starting_currencies.has(&"bamboo"):
		_loaded_starting_bamboo = int(_loaded_starting_currencies[&"bamboo"])
	else:
		_loaded_starting_currencies[&"bamboo"] = _loaded_starting_bamboo


## Sanitize the authored hidden-item list to known item ids, dropping empties, unknown ids
## and duplicates. Keys may be authored as either String or StringName.
func _valid_toolbuild_hidden_items(raw_item_ids: Array) -> Array[StringName]:
	var item_ids: Array[StringName] = []
	var seen: Dictionary = {}
	for raw_item_id: Variant in raw_item_ids:
		var item_id: StringName = StringName(str(raw_item_id))
		if item_id == &"" or seen.has(item_id) or ItemCatalog.get_item_def(String(item_id)).is_empty():
			continue
		seen[item_id] = true
		item_ids.append(item_id)
	return item_ids


func _tool_shop_item_ids() -> Array[StringName]:
	var item_ids: Array[StringName] = []
	for item_id: StringName in ItemCatalog.get_tool_shop_item_ids():
		if not ItemCatalog.is_fixed_stock(String(item_id)):
			item_ids.append(item_id)
	return item_ids


func _merchant_item_ids() -> Array[StringName]:
	var item_ids: Array[StringName] = []
	for item_id: StringName in ItemCatalog.get_merchant_shop_item_ids():
		if not ItemCatalog.is_fixed_stock(String(item_id)):
			item_ids.append(item_id)
	return item_ids


func _legacy_shop_item_ids() -> Array[StringName]:
	var item_ids: Array[StringName] = _tool_shop_item_ids()
	for item_id: StringName in _merchant_item_ids():
		if not item_ids.has(item_id):
			item_ids.append(item_id)
	return item_ids


func _valid_shop_available_items(raw_item_ids: Array[StringName], valid_item_ids: Array[StringName]) -> Array[StringName]:
	var item_ids: Array[StringName] = []
	var seen: Dictionary = {}
	for item_id: StringName in raw_item_ids:
		var item_id_string: String = String(item_id)
		if item_id_string == "" or seen.has(item_id) or not valid_item_ids.has(item_id):
			continue
		seen[item_id] = true
		item_ids.append(item_id)
	return item_ids


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


func _default_shop_available_items(item_ids_source: Array[StringName]) -> Array[StringName]:
	var item_ids: Array[StringName] = []
	for item_id: StringName in item_ids_source:
		item_ids.append(item_id)
	return item_ids


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


func _capture_level_spawner_bindings(level_root: Node) -> void:
	_loaded_spawner_bindings.clear()
	_loaded_named_spot_cells.clear()
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
		var child_name: String = String(spawner_node.name)
		if child_name.ends_with("_spot"):
			var spot_local_pos: Vector2 = floor_layer.to_local(spawner_node.global_position)
			_loaded_named_spot_cells[StringName(child_name)] = floor_layer.local_to_map(spot_local_pos)
		if _is_spawner_marker_node(spawner_node):
			continue
		var spawner_id: StringName = StringName(spawner_node.name)
		if spawner_id == &"":
			continue
		var kind: StringName = _spawner_kind_from_node(spawner_node)
		if kind == &"":
			continue
		var local_pos: Vector2 = floor_layer.to_local(spawner_node.global_position)
		var cell: Vector2i = floor_layer.local_to_map(local_pos)
		var exit_cell: Vector2i = cell
		var exit_node: Node2D = _find_spawner_marker_node(spawner_container, spawner_node, spawner_id, "exit")
		if exit_node != null:
			var exit_local_pos: Vector2 = floor_layer.to_local(exit_node.global_position)
			exit_cell = floor_layer.local_to_map(exit_local_pos)
		var spot_cell: Vector2i = Vector2i(2147483647, 2147483647)
		var spot_node: Node2D = _find_spawner_marker_node(spawner_container, spawner_node, spawner_id, "spot")
		if spot_node != null:
			var spot_local_pos: Vector2 = floor_layer.to_local(spot_node.global_position)
			spot_cell = floor_layer.local_to_map(spot_local_pos)
		var binding: SpawnerBinding = SpawnerBinding.new()
		binding.spawner_id = spawner_id
		binding.kind = kind
		binding.cell = cell
		binding.exit_cell = exit_cell
		binding.spot_cell = spot_cell
		if kind == SPAWNER_KIND_CLIENT:
			binding.frequency_client = maxf(0.0, float(spawner_node.get_meta(CLIENT_FREQUENCY_META, 1.0)))
		_loaded_spawner_bindings.append(binding)


func _is_spawner_marker_node(node: Node) -> bool:
	var node_name: String = String(node.name)
	return node_name.ends_with("_exit") or node_name.ends_with("_spot")


func _find_spawner_marker_node(spawner_container: Node, spawner_node: Node2D, spawner_id: StringName, marker_name: String) -> Node2D:
	var sibling_marker_name: String = "%s_%s" % [String(spawner_id), marker_name]
	var sibling_marker: Node2D = spawner_container.get_node_or_null(NodePath(sibling_marker_name)) as Node2D
	if sibling_marker != null:
		return sibling_marker
	return spawner_node.get_node_or_null(NodePath(marker_name)) as Node2D


# Reads the level's mapBounds rectangle (a CollisionShape2D + RectangleShape2D used
# purely as an editor-draggable region) into world + cell extents, then the shell node
# itself is discarded with the rest of level_root. Runs before the layers are reparented
# so the level's own floor layer resolves the cell coordinates the native field uses.
func _capture_level_map_bounds(level_root: Node) -> void:
	var bounds_node: Node = level_root.get_node_or_null("mapBounds")
	if bounds_node == null:
		return
	var shape_node: CollisionShape2D = bounds_node.get_node_or_null("CollisionShape2D") as CollisionShape2D
	if shape_node == null:
		push_warning("LevelLoader: level '%s' mapBounds has no CollisionShape2D; map extent not captured." % _level_path_for_log())
		return
	var rect_shape: RectangleShape2D = shape_node.shape as RectangleShape2D
	if rect_shape == null:
		push_warning("LevelLoader: level '%s' mapBounds shape is not a RectangleShape2D; map extent not captured." % _level_path_for_log())
		return

	var center: Vector2 = shape_node.global_position
	var half: Vector2 = rect_shape.size * 0.5
	var top_left: Vector2 = center - half
	var bottom_right: Vector2 = center + half
	_loaded_map_bounds_world = Rect2(top_left, rect_shape.size)

	var floor_layer: TileMapLayer = level_root.get_node_or_null("floor") as TileMapLayer
	if floor_layer == null:
		push_warning("LevelLoader: level '%s' has no floor layer; map extent cells not derived." % _level_path_for_log())
		return

	var min_cell: Vector2i = floor_layer.local_to_map(floor_layer.to_local(top_left))
	# Nudge the far corner inward by a pixel so an edge sitting exactly on a cell seam
	# does not pull in an extra row/column the rectangle only touches at its boundary.
	var max_cell: Vector2i = floor_layer.local_to_map(floor_layer.to_local(bottom_right - Vector2(1.0, 1.0)))
	var size_cells: Vector2i = (max_cell - min_cell) + Vector2i.ONE
	if size_cells.x <= 0 or size_cells.y <= 0:
		push_warning("LevelLoader: level '%s' mapBounds produced a non-positive cell extent." % _level_path_for_log())
		return
	_loaded_map_bounds_cells = Rect2i(min_cell, size_cells)


func _spawner_kind_from_node(spawner_node: Node2D) -> StringName:
	var spawner_name: String = String(spawner_node.name)
	if spawner_name.begins_with("seedmerchant") or spawner_name.begins_with("seedmerchent"):
		return SPAWNER_KIND_MERCHANT
	var sprite: Sprite2D = spawner_node as Sprite2D
	if sprite != null and sprite.texture != null:
		var texture_path: String = sprite.texture.resource_path
		if texture_path == ENEMY_SPAWNER_TEXTURE_PATH:
			return SPAWNER_KIND_MONSTER
		if texture_path == FRIENDLY_SPAWNER_TEXTURE_PATH:
			return SPAWNER_KIND_CLIENT
	return _spawner_kind_from_name(spawner_name)


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

func _reparent_reservoir_nodes(level_root: Node, host: Node) -> void:
	var reservoir_nodes: Array[Node2D] = []
	for child: Node in level_root.get_children():
		var reservoir: Node2D = child as Node2D
		if reservoir == null or String(child.name).to_lower() != "reservoir":
			continue
		reservoir_nodes.append(reservoir)
	if reservoir_nodes.is_empty():
		return
	var container: Node2D = host.get_node_or_null(NodePath(RESERVOIR_CONTAINER_NAME)) as Node2D
	if container == null:
		container = Node2D.new()
		container.name = RESERVOIR_CONTAINER_NAME
		host.add_child(container)
	var wallz: TileMapLayer = host.get_node_or_null(^"wallz") as TileMapLayer
	for reservoir: Node2D in reservoir_nodes:
		var global_pos: Vector2 = reservoir.global_position
		level_root.remove_child(reservoir)
		_clear_owner_recursive(reservoir)
		container.add_child(reservoir)
		reservoir.global_position = global_pos
		reservoir.z_as_relative = false
		reservoir.z_index = RESERVOIR_Z_INDEX
		reservoir.script = RESERVOIR_RUNTIME_SCRIPT
		_snap_reservoir_base_to_wall_tile(reservoir, wallz)
		_add_reservoir_water_fill(reservoir)
		reservoir.add_to_group("reservoirs")

## Snaps the reservoir so the middle of its sprite's bottom edge sits on the center
## of the nearest wallz cell, marks that cell as a wall (non-walkable /
## non-buildable, invisible tile), and Y-sorts the sprite against the agents: its
## z_index is set to the base Y, so an agent above the base (smaller Y) draws behind
## it and an agent below (larger Y) draws in front — agents use z_index = int(Y).
## Called once at level load per authored reservoir.
func _snap_reservoir_base_to_wall_tile(reservoir: Node2D, wallz: TileMapLayer) -> void:
	if wallz == null:
		push_warning("LevelLoader: no wallz layer; cannot anchor reservoir base to a wall tile.")
		return
	var sprite: Sprite2D = reservoir as Sprite2D
	if sprite == null or sprite.texture == null:
		push_warning("LevelLoader: reservoir has no sprite texture; cannot compute its base.")
		return
	# Middle of the bottom edge in the sprite's local space (centered sprites put the
	# origin at the middle; otherwise the top-left corner is the origin).
	var tex_size: Vector2 = sprite.texture.get_size()
	var base_local: Vector2 = sprite.offset
	if sprite.centered:
		base_local += Vector2(0.0, tex_size.y * 0.5)
	else:
		base_local += Vector2(tex_size.x * 0.5, tex_size.y)
	var base_world: Vector2 = sprite.to_global(base_local)
	# For a square grid the cell containing the point is the one whose center is
	# nearest, so local_to_map already gives the nearest tile.
	var cell: Vector2i = wallz.local_to_map(wallz.to_local(base_world))
	var cell_center_world: Vector2 = wallz.to_global(wallz.map_to_local(cell))
	# Shift the whole sprite (translation only) so the base lands on the cell center.
	reservoir.global_position += cell_center_world - base_world
	# Y-sort against agents: z = base Y (the cell center the base now sits on). The
	# reservoir is static, so this one-shot value stays correct. Overrides the fixed
	# RESERVOIR_Z_INDEX set by the caller.
	reservoir.z_as_relative = false
	reservoir.z_index = int(cell_center_world.y)
	var source_id: int = _wallz_atlas_source_id(wallz)
	if source_id < 0:
		push_warning("LevelLoader: wallz tile_set has no atlas source; cannot stamp reservoir wall tile.")
		return
	wallz.set_cell(cell, source_id, RESERVOIR_BASE_WALL_ATLAS)
	wallz.update_internals()

func _wallz_atlas_source_id(wallz: TileMapLayer) -> int:
	if wallz == null or wallz.tile_set == null:
		return -1
	var ts: TileSet = wallz.tile_set
	for i in range(ts.get_source_count()):
		var sid: int = ts.get_source_id(i)
		if ts.get_source(sid) is TileSetAtlasSource:
			return sid
	return -1

func _add_reservoir_water_fill(reservoir: Node2D) -> void:
	if reservoir.has_node(NodePath("WaterFill")):
		return
	var water: Sprite2D = Sprite2D.new()
	water.name = "WaterFill"
	water.texture = RESERVOIR_WATER_TEXTURE
	water.z_as_relative = true
	water.z_index = -1
	water.script = RESERVOIR_WATER_FILL_SCRIPT
	reservoir.add_child(water)


func _find_spawner_container(level_root: Node) -> Node:
	for container_name: String in SPAWNER_CONTAINER_NAMES:
		var container: Node = level_root.get_node_or_null(NodePath(container_name))
		if container != null:
			return container
	return null


func _level_path_for_log() -> String:
	return _loaded_level_scene_path if _loaded_level_scene_path != "" else "<loading>"
