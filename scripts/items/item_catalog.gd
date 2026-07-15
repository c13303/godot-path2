extends RefCounted
class_name ItemCatalog

const TURRET_EPINE_DATA: TurretData = preload("res://scripts/combat/turrets/turret_epine.tres")
const TURRET_EPINE_TEXTURE: Texture2D = preload("res://assets/sprites/legval/turret_epine.png")
const KRAKEN_VISUAL_SCENE: PackedScene = preload("res://scenes/combat/kraken_visual.tscn")
const KRAKEN_DATA: Resource = preload("res://scripts/combat/kraken/kraken.tres")
const FLOOR_TILE_CATALOG: Script = preload("res://scripts/map/floor_tile_catalog.gd")
const HOUSE_TEXTURE: Texture2D = preload("res://assets/sprites/house/house1.png")
const HOUSE_BUILDER_TEXTURE: Texture2D = preload("res://assets/sprites/house/house_builder.png")
const HOUSE_MERCHANT_TEXTURE: Texture2D = preload("res://assets/sprites/house/house_merchant.png")
const HOUSE_WIP_TEXTURE: Texture2D = preload("res://assets/sprites/legval/wiphouse.png")
const INVISIBLE_BUILDING_MARKER_ATLAS: Vector2i = Vector2i(8, 0)

const ITEM_DEFS: Dictionary = {
	"sword": {
		"id": "sword",
		"name": "Sword",
		"currency": &"money",
		"type": "weapon",
		"category": "tools",
		"frame": 0,
		"price": 100,
	},
	"bomb": {
		"id": "bomb",
		"name": "Bomb",
		"currency": &"money",
		"type": "weapon",
		"category": "tools",
		"frame": 1,
		"price": 100,
	},
	"water": {
		"id": "water",
		"name": "Water",
		"type": "gun",
		"category": "tools",
		"frame": 2,
	},
	"epine": {
		"id": "epine",
		"name": "Epine",
		"type": "gun",
		"category": "tools",
		"frame": 15,
	},
	"spray": {
		"id": "spray",
		"name": "Spray",
		"currency": &"money",
		"type": "weapon",
		"category": "tools",
		"frame": 2,
		"price": 100,
	},
	"beam": {
		"id": "beam",
		"name": "Beam",
		"currency": &"money",
		"type": "weapon",
		"category": "tools",
		"frame": 11,
		"price": 100,
	},
	"seed": {
		"id": "seed",
		"name": "Seed",
		"currency": &"gem",
		"type": "resource",
		"category": "resources",
		"price": 2,
	},
	"imperial_seed": {
		"id": "imperial_seed",
		"name": "Imperial Seed",
		"currency": &"money",
		"type": "placeable",
		"category": "plant",
		"frame": 20,
		"price": 20,
		"target_layer": "plantz",
		"atlas": Vector2i(0, 3),
		"occupies_cell": true,
		"blocks_movement": false,
		"blocks_projectiles": false,
		"requires_grass_green_floor": true,
		"runtime_id": "imperial_plant",
		"logical_plant": true,
		"plant_kind": "imperial",
		"inventory_backed": true,
		"speed_multiplier": 0.3,
		"max_stack": 999,
	},
	"imperial_rose": {
		"id": "imperial_rose",
		"name": "Imperial Rose",
		"type": "resource",
		"category": "resources",
		"frame": 21,
		"max_stack": 999,
	},
	"bamboo": {
		"id": "bamboo",
		"name": "Bamboo",
		"type": "resource",
		"category": "resources",
		"frame": 23,
		"max_stack": 999,
		"currency_item": true,
	},
	# Selecting this quick-slot tool opens the build picker in gardening mode (rose, ronce,
	# pasteque, turrets). It is not a weapon or a placeable itself; the picker chooses which
	# building to place.
	"gardening": {
		"id": "gardening",
		"name": "Gardening",
		"type": "tool",
		"category": "tools",
		"frame": 9,
	},
	# Selecting this quick-slot tool opens the build picker in hammer mode (shop counter,
	# wall, fence). Like gardening it drives build mode but offers the structural buildables.
	"hammer": {
		"id": "hammer",
		"name": "Hammer",
		"type": "tool",
		"category": "tools",
		"frame": 19,
	},
	# Selecting this quick-slot tool opens the build picker for inventory-owned house
	# placeables. It is a menu tool only; the chosen house item drives placement.
	"buildhouse": {
		"id": "buildhouse",
		"name": "Build House",
		"type": "tool",
		"category": "tools",
		"frame": 27,
	},
	# Holding left-click with this quick-slot tool removes the hovered building.
	"unbuild_tool": {
		"id": "unbuild_tool",
		"name": "Unbuild",
		"type": "tool",
		"category": "tools",
		"frame": 10,
	},
	"wall": {
		"id": "wall",
		"name": "Wall",
		"type": "placeable",
		"category": "wall",
		"frame": 3,
		"target_layer": "wallz",
		"atlas": Vector2i(11, 1),
		"occupies_cell": true,
		"blocks_movement": true,
		"blocks_projectiles": true,
		"runtime_id": "",
		# Owned as a stock count (shows in the currency HUD like the rest of the inventory):
		# placing a wall consumes one from the stock instead of charging currency. Walls are
		# granted as starting stock or rewards, not bought.
		"inventory_backed": true,
		"fixed_stock": true,
		"max_health": 100,
		"max_stack": 999,
	},
	# Legacy saves may still contain item_id "house"; normalize_house_item_id() maps it to
	# house_merchant. Keep this definition out of house build lists by leaving it without
	# special_placement_kind.
	"house": {
		"id": "house",
		"name": "Legacy House",
		"type": "legacy",
		"category": "house",
		"frame": 27,
		"house_texture": HOUSE_MERCHANT_TEXTURE,
		"house_completed_texture": HOUSE_MERCHANT_TEXTURE,
		"house_wip_texture": HOUSE_WIP_TEXTURE,
		"builder_work_seconds": 20.0,
		"max_health": 100,
	},
	# Multi-cell player-built houses. Unlike normal placeables they are NOT routed through
	# the generic one-cell placement path: HouseManager owns the 3x2 blocking footprint,
	# walkable entrance, sprite snapping and durability. Both are direct gem purchases.
	"house_builder": {
		"id": "house_builder",
		"name": "Builder House",
		"type": "placeable",
		"category": "house",
		"frame": 28,
		"target_layer": "wallz",
		"special_placement_kind": &"house",
		"house_resident_type": &"builder",
		"house_texture": HOUSE_BUILDER_TEXTURE,
		"house_completed_texture": HOUSE_BUILDER_TEXTURE,
		"house_wip_texture": HOUSE_WIP_TEXTURE,
		"builder_work_seconds": 20.0,
		"drag_buildable": false,
		"max_health": 100,
		"max_stack": 999,
		"currency": &"gem",
		"price": 20,
	},
	"house_merchant": {
		"id": "house_merchant",
		"name": "Merchant House",
		"type": "placeable",
		"category": "house",
		"frame": 29,
		"target_layer": "wallz",
		"special_placement_kind": &"house",
		"house_resident_type": &"seed_merchant",
		"unique_house_type": true,
		"house_texture": HOUSE_MERCHANT_TEXTURE,
		"house_completed_texture": HOUSE_MERCHANT_TEXTURE,
		"house_wip_texture": HOUSE_WIP_TEXTURE,
		"builder_work_seconds": 20.0,
		"drag_buildable": false,
		"max_health": 100,
		"max_stack": 999,
		"currency": &"gem",
		"price": 20,
	},
	"rose": {
		"id": "rose",
		"name": "Rose",
		"currency": &"seed",
		"type": "placeable",
		"category": "plant",
		"frame": 5,
		"price": 1,
		"target_layer": "plantz",
		"atlas": Vector2i(0, 0),
		# A watered (0,2) or full-bloom (0,1) rose is still the same inventory item when picked back up.
		"tile_atlases": [Vector2i(0, 0), Vector2i(0, 2), Vector2i(0, 1)],
		"occupies_cell": true,
		"blocks_movement": false,
		"blocks_projectiles": false,
		"runtime_id": "rose",
		# Roses slow any agent crossing the cell to 50% speed (player included). Applied
		# via the shared per-cell terrain multiplier, so it reaches every native agent
		# through effective_cell_speed_multiplier. A creature that eats/destroys the rose
		# removes it, which clears the slow.
		"speed_multiplier": 0.5,
		"max_stack": 999,
	},
	"debris": {
		"id": "debris",
		"name": "Debris",
		"type": "world_item",
		"category": "debris",
		"target_layer": "plantz",
		"atlas": Vector2i(1, 1),
		"removable": true,
		"return_to_inventory": false,
		"speed_multiplier": 0.3,
	},
	"lamp": {
		"id": "lamp",
		"name": "Lamp",
		"type": "placeable",
		"category": "furniture",
		"frame": 4,
		"target_layer": "traversable_buildings",
		"atlas": Vector2i(1, 0),
		"occupies_cell": true,
		"blocks_movement": false,
		"blocks_projectiles": false,
		"runtime_id": "lamp",
		"light_source": 3,
		"max_health": 100,
		"max_stack": 999,
	},
	"ronce": {
		"id": "ronce",
		"name": "Ronce",
		"currency": &"gem",
		"type": "placeable",
		"category": "terrain",
		"frame": 14,
		"price": 1,
		"target_layer": "traversable_buildings",
		"atlas": Vector2i(5, 0),
		"occupies_cell": true,
		"blocks_movement": false,
		"blocks_projectiles": false,
		"requires_grass_green_floor": true,
		"runtime_id": "ronce",
		"speed_multiplier": 0.3,
		"max_health": 100,
		"max_stack": 999,
	},
	"fence": {
		"id": "fence",
		"name": "Fence",
		"currency": &"gem",
		"type": "placeable",
		"category": "fence",
		"frame": 18,
		"price": 1,
		"target_layer": "fences",
		"atlas": Vector2i(5, 7),
		"tile_atlases": [
			Vector2i(4, 6),
			Vector2i(5, 6),
			Vector2i(6, 6),
			Vector2i(7, 6),
			Vector2i(8, 6),
			Vector2i(4, 7),
			Vector2i(5, 7),
			Vector2i(6, 7),
			Vector2i(7, 7),
			Vector2i(8, 7),
			Vector2i(4, 8),
			Vector2i(5, 8),
			Vector2i(6, 8),
			Vector2i(7, 8),
			Vector2i(8, 8),
		],
		"occupies_cell": true,
		"blocks_movement": false,
		"blocks_agents": true,
		"blocks_projectiles": false,
		"runtime_id": "fence",
		"speed_multiplier": 0.3,
		"max_health": 100,
		"max_stack": 999,
	},
	"reservoir": {
		"id": "reservoir",
		"name": "Reservoir",
		"currency": &"money",
		"type": "placeable",
		"category": "irrigation",
		"frame": 16,
		"price": 100,
		"target_layer": "traversable_buildings",
		"atlas": Vector2i(6, 0),
		"occupies_cell": true,
		"blocks_movement": false,
		"blocks_projectiles": false,
		"requires_walkable_floor": true,
		"runtime_id": "reservoir",
		"drag_buildable": false,
		"max_health": 100,
		"max_stack": 999,
	},
	# A player-buildable watermelon/pasteque that paints grass around itself when placed. It is
	# bought at the seed merchant into the inventory (inventory_backed) and then placed
	# from the toolbuild picker, which consumes one from the inventory instead of
	# spending currency on placement.
	"pasteque": {
		"id": "pasteque",
		"name": "Watermelon",
		"currency": &"money",
		"type": "placeable",
		"category": "irrigation",
		"frame": 16,
		"price": 20,
		"target_layer": "traversable_buildings",
		"atlas": Vector2i(3, 1),
		"occupies_cell": true,
		"blocks_movement": false,
		"blocks_projectiles": false,
		"requires_walkable_floor": true,
		"runtime_id": "pasteque",
		"drag_buildable": false,
		"irrigation_radius_tiles": 9,
		"destroyed_by_creatures": true,
		"restore_floor_atlas": FLOOR_TILE_CATALOG.DRY_GROUND_FLOOR_ATLAS,
		# Paid for at the seed merchant into the inventory; placing consumes one unit
		# from the inventory rather than charging currency again.
		"inventory_backed": true,
		"max_health": 100,
		"max_stack": 999,
	},
	"turret_epine": {
		"id": "turret_epine",
		"name": "Epine Turret",
		"currency": &"gem",
		"type": "placeable",
		"category": "turret",
		"frame": 6,
		"price": 10,
		"target_layer": "blocking_buildings",
		"atlas": INVISIBLE_BUILDING_MARKER_ATLAS,
		"occupies_cell": true,
		"isWall": false,
		"blocks_movement": false,
		"blocks_player_movement": false,
		"blocks_projectiles": false,
		"speed_multiplier": 0.5,
		"requires_walkable_floor": true,
		"requires_grass_green_floor": true,
		"pad_skip_preview": true,
		"directional": true,
		"runtime_id": "turret_epine",
		# One hit point: destroyed in a single hit by tantrum clients.
		"max_health": 1,
		"turret_data": TURRET_EPINE_DATA,
		"turret_sprite_visual": {
			"texture": TURRET_EPINE_TEXTURE,
			"frame_size": Vector2i(32, 32),
			"frame_padding": Vector2i(2, 2),
			"frame_stride_x": 36,
			"base_frame": 0,
			"head_frame": 1,
			# refractory: shown while turret_epine is cooling down before it can shoot again.
			"refractory_frame": 5,
			"head_offset": Vector2(0.0, -16.0),
			"shot_frames": [
				{"frame": 2, "duration": 0.1},
				{"frame": 3, "duration": 0.1},
				{"frame": 4, "duration": 0.1},
			],
		},
		"max_stack": 999,
	},
	"kraken": {
		"id": "kraken",
		"name": "Kraken Vine",
		"currency": &"gem",
		"type": "placeable",
		"category": "trap",
		"frame": 6,
		"price": 20,
		"target_layer": "traversable_buildings",
		"atlas": INVISIBLE_BUILDING_MARKER_ATLAS,
		"occupies_cell": true,
		"blocks_movement": false,
		"blocks_player_movement": false,
		"blocks_projectiles": false,
		"requires_walkable_floor": true,
		"requires_grass_green_floor": true,
		"speed_multiplier": 0.5,
		"walkover_damage_by_monsters": 30,
		"leaves_debris_on_destroy": true,
		"drag_buildable": false,
		"pad_skip_preview": true,
		"runtime_id": "kraken",
		"building_visual_scene": KRAKEN_VISUAL_SCENE,
		"kraken_data": KRAKEN_DATA,
		"max_health": 100,
		"max_stack": 999,
	},
	"rose_shop_counter": {
		"id": "rose_shop_counter",
		"name": "Rose Shop Counter",
		"currency": &"bamboo",
		"type": "placeable",
		"category": "shop_counter",
		"frame": 12,
		"price": 10,
		# Solid like a wall: placed on the blocking layer so the player's hard
		# collision (driven by _refresh_cell_collision) and the monster steering
		# obstacle both treat the counter cell as impassable. Clients still buy from
		# an adjacent access cell, so the sale flow is unaffected.
		"target_layer": "blocking_buildings",
		"atlas": Vector2i(4, 0),
		"occupies_cell": true,
		"isWall": true,
		"blocks_movement": true,
		"blocks_projectiles": true,
		"requires_grass_green_floor": true,
		"pad_skip_preview": true,
		"runtime_id": "rose_shop_counter",
		# Bought directly from the hammer build picker with its catalog currency, paid
		# on placement. Not inventory-backed and not sold at the seed merchant.
		"max_health": 100,
		"max_stack": 999,
	},
}

static func get_item_def(item_id: String) -> Dictionary:
	item_id = normalize_house_item_id(item_id)
	if ITEM_DEFS.has(item_id):
		return ITEM_DEFS[item_id]
	return {}


static func normalize_house_item_id(item_id: String) -> String:
	if item_id == "house":
		return "house_merchant"
	return item_id

static func get_turret_data(item_id: String) -> TurretData:
	var item_def: Dictionary = get_item_def(item_id)
	var raw_data: Variant = item_def.get("turret_data", null)
	return raw_data as TurretData

# Derives turret shot timing from the visual shot_frames so the projectile releases
# when the last (fire) frame begins, keeping firing in sync with the animation instead
# of a hardcoded delay. Returns {} when the item has no shot_frames (caller then falls
# back to the TurretData timing fields).
static func get_turret_shot_animation_timing(item_id: String) -> Dictionary:
	var item_def: Dictionary = get_item_def(item_id)
	var visual_def: Dictionary = item_def.get("turret_sprite_visual", {}) as Dictionary
	var raw_frames: Variant = visual_def.get("shot_frames", [])
	if not (raw_frames is Array) or (raw_frames as Array).is_empty():
		return {}
	var frames: Array = raw_frames as Array
	var release_delay: float = 0.0
	var cycle_duration: float = 0.0
	for i: int in range(frames.size()):
		var frame_data: Dictionary = frames[i] as Dictionary
		var duration: float = maxf(0.0, float(frame_data.get("duration", 0.0)))
		cycle_duration += duration
		if i < frames.size() - 1:
			release_delay += duration
	return {"release_delay": release_delay, "cycle_duration": cycle_duration}

static func item_places_tile(item_id: String) -> bool:
	return is_placeable(item_id)

static func get_place_tile(item_id: String) -> Dictionary:
	return get_placeable_def(item_id)

static func is_placeable(item_id: String) -> bool:
	return str(get_item_def(item_id).get("type", "")) == "placeable"

## True for placeables that are stocked in the inventory (bought at the merchant) and
## consumed from it when placed, instead of being paid for directly from currency on
## placement. See pasteque.
static func is_inventory_backed(item_id: String) -> bool:
	return bool(get_item_def(item_id).get("inventory_backed", false))

## True for the multi-cell house placeable, which HouseManager places/removes/destroys as one
## logical object instead of through the generic one-cell tile path. Owners branch on this
## single flag rather than matching item_id == "house" in many files.
static func is_house_placeable(item_id: String) -> bool:
	return StringName(get_item_def(item_id).get("special_placement_kind", &"")) == &"house"


## The full house sprite texture (house1.png) used by the preview and the built world object.
## Null for non-house items.
static func get_house_texture(item_id: String) -> Texture2D:
	return get_item_def(item_id).get("house_texture", null) as Texture2D


static func get_house_completed_texture(item_id: String) -> Texture2D:
	var item_def: Dictionary = get_item_def(item_id)
	return item_def.get("house_completed_texture", item_def.get("house_texture", null)) as Texture2D


static func get_house_wip_texture(item_id: String) -> Texture2D:
	return get_item_def(item_id).get("house_wip_texture", null) as Texture2D


static func get_house_builder_work_seconds(item_id: String) -> float:
	return maxf(0.0, float(get_item_def(item_id).get("builder_work_seconds", 20.0)))


static func get_house_resident_type(item_id: String) -> StringName:
	return StringName(get_item_def(item_id).get("house_resident_type", &""))


static func is_unique_house_type(item_id: String) -> bool:
	return bool(get_item_def(item_id).get("unique_house_type", false))


## Fixed-stock items are granted in finite quantities by the level/reward data and
## are never sold by either shop. They can still appear in the build picker so the
## player can place the owned stock.
static func is_fixed_stock(item_id: String) -> bool:
	return bool(get_item_def(item_id).get("fixed_stock", false))

## Data-driven maximum health for a destructible player-built placeable. 0 means the
## item has no repeated-damage health (plants use the instant-destroy path instead).
static func get_max_health(item_id: String) -> int:
	return maxi(0, int(get_item_def(item_id).get("max_health", 0)))

## True for catalog entries the generic durability system tracks as destructible targets
## when player-built. Any normal placeable qualifies automatically, so new building types
## become destructible without editing the tantrum/durability code.
static func is_destructible_placeable(item_id: String) -> bool:
	return is_placeable(item_id)

## True for placeables the catalog files under the "plant" category (rose, imperial_seed, and
## any plant added later). The nighttime placement ban keys off this category so a new plant
## is covered by the rule the moment it is added to the catalog.
static func is_plant_placeable(item_id: String) -> bool:
	return is_placeable(item_id) and str(get_item_def(item_id).get("category", "")) == "plant"

## True for placeables that live on the plant layer and are destroyed instantly on contact
## (roses, imperial plants, future plant-layer placeables) rather than taking repeated hits.
static func is_instant_destroy_placeable(item_id: String) -> bool:
	var item_def: Dictionary = get_item_def(item_id)
	if not is_placeable(item_id):
		return false
	if bool(item_def.get("logical_plant", false)):
		return true
	if str(item_def.get("category", "")) == "plant":
		return true
	return str(item_def.get("target_layer", "")) == "plantz"

## Catalog types that count as combat weapons (fired by the fight system) rather
## than tools/placeables. Quick-bar disabling and night auto-arming key off this.
const WEAPON_TYPES: Array[String] = ["weapon", "gun"]

static func is_weapon(item_id: String) -> bool:
	return str(get_item_def(item_id).get("type", "")) in WEAPON_TYPES

static func get_weapon_ids() -> Array[StringName]:
	var weapon_ids: Array[StringName] = []
	for raw_item_id: Variant in ITEM_DEFS.keys():
		var item_id: String = str(raw_item_id)
		if is_weapon(item_id):
			weapon_ids.append(StringName(item_id))
	weapon_ids.sort()
	return weapon_ids

static func get_giveable_starting_item_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for raw_item_id: Variant in ITEM_DEFS.keys():
		var item_id: String = str(raw_item_id)
		if bool(get_item_def(item_id).get("currency_item", false)):
			continue
		var item_type: String = str(get_item_def(item_id).get("type", ""))
		if item_type == "placeable" or item_type == "resource":
			ids.append(StringName(item_id))
	ids.sort()
	return ids

static func get_gardening_shop_item_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for raw_item_id: Variant in ITEM_DEFS.keys():
		var item_id: String = str(raw_item_id)
		var item_def: Dictionary = get_item_def(item_id)
		if str(item_def.get("type", "")) != "placeable":
			continue
		var category: String = str(item_def.get("category", ""))
		if category == "plant" or category == "terrain" or category == "turret" or category == "irrigation" or category == "trap":
			ids.append(StringName(item_id))
	return _ordered_known_first(ids, [&"rose", &"imperial_seed", &"ronce", &"pasteque", &"turret_epine", &"kraken"])

static func get_hammer_shop_item_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for raw_item_id: Variant in ITEM_DEFS.keys():
		var item_id: String = str(raw_item_id)
		var item_def: Dictionary = get_item_def(item_id)
		if str(item_def.get("type", "")) != "placeable":
			continue
		var category: String = str(item_def.get("category", ""))
		if category == "shop_counter" or category == "wall" or category == "fence" or category == "furniture":
			ids.append(StringName(item_id))
	return _ordered_known_first(ids, [&"rose_shop_counter", &"wall", &"fence"])

static func get_house_build_item_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for raw_item_id: Variant in ITEM_DEFS.keys():
		var item_id: String = str(raw_item_id)
		if item_id == "house":
			continue
		var item_def: Dictionary = get_item_def(item_id)
		if str(item_def.get("type", "")) != "placeable":
			continue
		if StringName(item_def.get("special_placement_kind", &"")) == &"house":
			ids.append(StringName(item_id))
	return _ordered_known_first(ids, [&"house_builder", &"house_merchant"])

static func get_tool_shop_item_ids() -> Array[StringName]:
	var ids: Array[StringName] = get_gardening_shop_item_ids()
	for item_id: StringName in get_hammer_shop_item_ids():
		if not ids.has(item_id):
			ids.append(item_id)
	for item_id: StringName in get_house_build_item_ids():
		if not ids.has(item_id):
			ids.append(item_id)
	return ids

static func get_merchant_shop_item_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	if ITEM_DEFS.has("seed"):
		ids.append(&"seed")
	for weapon_id: StringName in get_weapon_ids():
		var weapon_def: Dictionary = get_item_def(String(weapon_id))
		if weapon_def.has("currency") and not ids.has(weapon_id):
			ids.append(weapon_id)
	for raw_item_id: Variant in ITEM_DEFS.keys():
		var item_id: String = str(raw_item_id)
		if is_inventory_backed(item_id) and not is_fixed_stock(item_id):
			var id_name: StringName = StringName(item_id)
			if not ids.has(id_name):
				ids.append(id_name)
	return _ordered_known_first(ids, [&"seed", &"imperial_seed", &"sword", &"bomb", &"spray", &"beam", &"pasteque", &"rose_shop_counter"])

static func get_max_stack(item_id: String) -> int:
	return maxi(1, int(get_item_def(item_id).get("max_stack", 999)))

static func get_currency(item_id: String) -> StringName:
	return StringName(get_item_def(item_id).get("currency", &""))

## Build price in the item's currency (see get_currency). 0 means "not for sale".
static func get_price(item_id: String) -> int:
	return int(get_item_def(item_id).get("price", 0))

static func is_stackable(item_id: String) -> bool:
	return get_max_stack(item_id) > 1

static func get_placeable_def(item_id: String) -> Dictionary:
	var item_def: Dictionary = get_item_def(item_id)
	if is_placeable(item_id):
		return item_def
	var raw: Variant = item_def.get("place_tile", {})
	if raw is Dictionary:
		return raw
	return {}

static func get_placeable_id_for_tile(target_layer: String, atlas_coords: Vector2i) -> String:
	var normalized_layer: String = "traversable_buildings" if target_layer == "buildings" else target_layer
	for raw_item_def: Variant in ITEM_DEFS.values():
		if not (raw_item_def is Dictionary):
			continue
		var item_def: Dictionary = raw_item_def as Dictionary
		if str(item_def.get("type", "")) != "placeable" and not bool(item_def.get("removable", false)):
			continue
		var item_layer: String = str(item_def.get("target_layer", "wallz"))
		if item_layer == "buildings":
			item_layer = "traversable_buildings"
		if item_layer != normalized_layer:
			continue
		var raw_atlases: Variant = item_def.get("tile_atlases", [])
		if raw_atlases is Array:
			for raw_atlas: Variant in raw_atlases:
				if _atlas_coords_from_variant(raw_atlas) == atlas_coords:
					return str(item_def.get("id", ""))
		if _atlas_coords_from_variant(item_def.get("atlas", Vector2i(-1, -1))) == atlas_coords:
			return str(item_def.get("id", ""))
	return ""

static func removed_item_returns_to_inventory(item_id: String) -> bool:
	return bool(get_item_def(item_id).get("return_to_inventory", true))

static func _atlas_coords_from_variant(raw_atlas: Variant) -> Vector2i:
	if raw_atlas is Vector2i:
		return raw_atlas as Vector2i
	if raw_atlas is Vector2:
		var vector_atlas: Vector2 = raw_atlas as Vector2
		return Vector2i(int(vector_atlas.x), int(vector_atlas.y))
	if raw_atlas is Array and raw_atlas.size() == 2:
		return Vector2i(int(raw_atlas[0]), int(raw_atlas[1]))
	return Vector2i(-1, -1)

static func _ordered_known_first(ids: Array[StringName], preferred_order: Array[StringName]) -> Array[StringName]:
	var ordered: Array[StringName] = []
	for item_id: StringName in preferred_order:
		if ids.has(item_id):
			ordered.append(item_id)
	for item_id: StringName in ids:
		if not ordered.has(item_id):
			ordered.append(item_id)
	return ordered
