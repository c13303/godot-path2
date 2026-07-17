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
## Root-level container whose direct Node2D children mark one permanent bamboo plant each.
const BAMBOO_CONTAINER_NAME: String = "bamboo"
const SPAWNER_KIND_MONSTER: StringName = &"monster"
const SPAWNER_KIND_CLIENT: StringName = &"client"
const SPAWNER_KIND_MERCHANT: StringName = &"merchant"
const ALLY_MARKER_NAMES: PackedStringArray = ["fundamental_builder_in", "fundamental_builder_spot", "fundamental_builder_out"]
const CLIENT_FREQUENCY_META: StringName = &"frequency_client"
const ENEMY_SPAWNER_TEXTURE_PATH: String = "res://assets/sprites/legval/spawner.png"
const FRIENDLY_SPAWNER_TEXTURE_PATH: String = "res://assets/sprites/legval/clientspawner.png"
const DEFAULT_TOOL_SHOP_AVAILABLE_ITEM_IDS: Array[StringName] = [&"rose", &"imperial_seed", &"turret_epine", &"ronce", &"fence", &"kraken"]
const DEFAULT_MERCHANT_AVAILABLE_ITEM_IDS: Array[StringName] = [&"seed", &"imperial_seed", &"spray", &"beam", &"sword", &"bomb"]
const DEFAULT_LEGACY_SHOP_AVAILABLE_ITEM_IDS: Array[StringName] = [&"rose", &"imperial_seed", &"turret_epine", &"ronce", &"fence", &"kraken", &"seed", &"spray", &"beam", &"sword", &"bomb"]
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
# Floor cells of the level's authored bamboo markers, captured before the shell is freed.
# The markers themselves are editor-only and are never reparented as gameplay visuals;
# BambooHarvestController creates the real plants from these cells.
var _loaded_bamboo_cells: Array[Vector2i] = []
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
	_capture_level_bamboo_cells(level_root)
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


## Floor cells of the level's authored bamboo markers, deduplicated and sorted by Y then X.
## Empty when the level authors no `bamboo` container.
func get_loaded_bamboo_cells() -> Array[Vector2i]:
	return _loaded_bamboo_cells.duplicate()


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
		if child_name.ends_with("_spot") or ALLY_MARKER_NAMES.has(child_name):
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
	return node_name.ends_with("_exit") or node_name.ends_with("_spot") or ALLY_MARKER_NAMES.has(node_name)


func _find_spawner_marker_node(spawner_container: Node, spawner_node: Node2D, spawner_id: StringName, marker_name: String) -> Node2D:
	var sibling_marker_name: String = "%s_%s" % [String(spawner_id), marker_name]
	var sibling_marker: Node2D = spawner_container.get_node_or_null(NodePath(sibling_marker_name)) as Node2D
	if sibling_marker != null:
		return sibling_marker
	return spawner_node.get_node_or_null(NodePath(marker_name)) as Node2D


# Reads the level's root-level `bamboo` container: every direct Node2D child marks one
# permanent bamboo plant. Runs while the level's own floor layer is still present, because
# the shell (markers included) is freed at the end of _load_level. The markers are editor
# aids only — they are never mutated, reparented, or used as gameplay visuals; only their
# derived floor cells survive, and BambooHarvestController builds the real plants from them.
# A level with no container is normal and stays silent.
func _capture_level_bamboo_cells(level_root: Node) -> void:
	_loaded_bamboo_cells.clear()
	var container: Node = level_root.get_node_or_null(NodePath(BAMBOO_CONTAINER_NAME))
	if container == null:
		return
	var floor_layer: TileMapLayer = level_root.get_node_or_null("floor") as TileMapLayer
	if floor_layer == null:
		push_warning("LevelLoader: level '%s' has no floor layer; bamboo marker cells cannot be derived." % _level_path_for_log())
		return
	var marker_name_by_cell: Dictionary = {}  # Vector2i -> String
	for child: Node in container.get_children():
		var marker: Node2D = child as Node2D
		if marker == null:
			push_warning("LevelLoader: bamboo child '%s' in level '%s' is not a Node2D; ignored." % [
				String(child.name), _level_path_for_log()
			])
			continue
		# Same world-to-cell convention as spawner marker capture.
		var local_position: Vector2 = floor_layer.to_local(marker.global_position)
		var cell: Vector2i = floor_layer.local_to_map(local_position)
		if floor_layer.get_cell_source_id(cell) < 0:
			push_warning("LevelLoader: bamboo marker '%s' in level '%s' resolves to cell %s, which has no floor tile; ignored." % [
				String(marker.name), _level_path_for_log(), str(cell)
			])
			continue
		if marker_name_by_cell.has(cell):
			push_warning("LevelLoader: bamboo markers '%s' and '%s' in level '%s' both resolve to cell %s; keeping one bamboo." % [
				str(marker_name_by_cell[cell]), String(marker.name), _level_path_for_log(), str(cell)
			])
			continue
		marker_name_by_cell[cell] = String(marker.name)
		_loaded_bamboo_cells.append(cell)
	_loaded_bamboo_cells.sort_custom(Callable(self, "_sort_cells_by_y_then_x"))


func _sort_cells_by_y_then_x(a: Vector2i, b: Vector2i) -> bool:
	if a.y != b.y:
		return a.y < b.y
	return a.x < b.x


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
	var wallz: TileMapLayer = host.get_node_or_null(^"wallz") as TileMapLayer
	var blocking_buildings: TileMapLayer = host.get_node_or_null(^"blocking_buildings") as TileMapLayer
	var building_object_manager: BuildingObjectManager = null
	if host.get_parent() != null:
		building_object_manager = host.get_parent().get_node_or_null("BuildingObjectManager") as BuildingObjectManager
	for reservoir: Node2D in reservoir_nodes:
		var cell: Vector2i = _reservoir_base_cell(reservoir, wallz)
		level_root.remove_child(reservoir)
		_clear_owner_recursive(reservoir)
		reservoir.queue_free()
		_stamp_authored_reservoir_tile(blocking_buildings, cell)
		if building_object_manager == null:
			push_warning("LevelLoader: no BuildingObjectManager; authored reservoir at %s ignored." % str(cell))
			continue
		# The stamped tile alone would already register the reservoir (BuildingObjectManager
		# indexes blocking_buildings on _ready), but registering it explicitly keeps this
		# loader independent of that startup order. add_building replaces any existing entry
		# for the cell, so the two paths cannot double-register it.
		var item_def: Dictionary = ItemCatalog.get_item_def("reservoir").duplicate(true)
		building_object_manager.call_deferred("add_building", cell, item_def)


## Stamps the authored reservoir's blocking tile, mirroring what a player build does. The
## reservoir is a wall, and everything that decides walkability, player collision and
## tantrum targeting reads the blocking_buildings tile — a runtime node alone would leave
## an authored reservoir walk-through.
func _stamp_authored_reservoir_tile(blocking_buildings: TileMapLayer, cell: Vector2i) -> void:
	if blocking_buildings == null:
		push_warning("LevelLoader: no blocking_buildings layer; authored reservoir at %s will not block." % str(cell))
		return
	var source_id: int = _atlas_source_id(blocking_buildings)
	if source_id < 0:
		push_error("LevelLoader: blocking_buildings tile_set has no atlas source; cannot stamp the authored reservoir.")
		return
	var atlas: Vector2i = ItemCatalog.get_item_def("reservoir").get("atlas", Vector2i.ZERO) as Vector2i
	blocking_buildings.set_cell(cell, source_id, atlas)
	blocking_buildings.update_internals()


func _atlas_source_id(layer: TileMapLayer) -> int:
	if layer == null or layer.tile_set == null:
		return -1
	var tile_set: TileSet = layer.tile_set
	for i: int in range(tile_set.get_source_count()):
		var source_id: int = tile_set.get_source_id(i)
		if tile_set.get_source(source_id) is TileSetAtlasSource:
			return source_id
	return -1


## The cell an authored reservoir stands on: the one under the bottom tile-sized square of
## its art. BuildingObjectManager lays the runtime tank out by the same rule (see
## BuildingObjectManager.reservoir_footprint_offset), so the runtime reservoir lands
## exactly where the level author drew it.
func _reservoir_base_cell(reservoir: Node2D, wallz: TileMapLayer) -> Vector2i:
	if wallz == null:
		push_warning("LevelLoader: no wallz layer; cannot anchor the reservoir to a cell.")
		return Vector2i.ZERO
	var sprite: Sprite2D = reservoir as Sprite2D
	if sprite == null or sprite.texture == null:
		push_warning("LevelLoader: reservoir has no sprite texture; cannot compute its base.")
		return Vector2i.ZERO
	var tex_size: Vector2 = sprite.texture.get_size()
	var tile_height: float = tex_size.y if wallz.tile_set == null else float(wallz.tile_set.tile_size.y)
	# Centre of that bottom square, in the sprite's local space (centered sprites put the
	# origin at the middle; otherwise the top-left corner is the origin).
	var base_local: Vector2 = sprite.offset
	if sprite.centered:
		base_local += Vector2(0.0, (tex_size.y - tile_height) * 0.5)
	else:
		base_local += Vector2(tex_size.x * 0.5, tex_size.y - tile_height * 0.5)
	return wallz.local_to_map(wallz.to_local(sprite.to_global(base_local)))

func _find_spawner_container(level_root: Node) -> Node:
	for container_name: String in SPAWNER_CONTAINER_NAMES:
		var container: Node = level_root.get_node_or_null(NodePath(container_name))
		if container != null:
			return container
	return null


func _level_path_for_log() -> String:
	return _loaded_level_scene_path if _loaded_level_scene_path != "" else "<loading>"
