extends RefCounted
class_name ItemCatalog

const ITEM_DEFS: Dictionary = {
	"sword": {
		"id": "sword",
		"name": "Sword",
		"currency": &"gem",
		"type": "weapon",
		"category": "tools",
		"frame": 0,
	},
	"bomb": {
		"id": "bomb",
		"name": "Bomb",
		"type": "weapon",
		"category": "tools",
		"frame": 1,
	},
	"water": {
		"id": "water",
		"name": "Water",
		"type": "gun",
		"category": "tools",
		"frame": 2,
	},
	"spray": {
		"id": "spray",
		"name": "Spray",
		"type": "weapon",
		"category": "tools",
		"frame": 2,
	},
	"beam": {
		"id": "beam",
		"name": "Beam",
		"type": "weapon",
		"category": "tools",
		"frame": 11,
	},
	# Selecting this quick-slot tool opens the shop (build mode). It is not a weapon
	# or a placeable itself; the shop chooses which building to place.
	"build_tool": {
		"id": "build_tool",
		"name": "Build",
		"type": "tool",
		"category": "tools",
		"frame": 9,
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
		"currency": &"gem",
		"type": "placeable",
		"category": "wall",
		"frame": 3,
		"price": 100,
		"target_layer": "wallz",
		"atlas": Vector2i(11, 1),
		"occupies_cell": true,
		"blocks_movement": true,
		"blocks_projectiles": true,
		"runtime_id": "",
		"max_stack": 999,
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
		# A watered rose is still the same inventory item when picked back up.
		"tile_atlases": [Vector2i(0, 0), Vector2i(0, 2)],
		"occupies_cell": true,
		"blocks_movement": false,
		"blocks_projectiles": false,
		"runtime_id": "rose",
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
		"max_stack": 999,
	},
	"turret1": {
		"id": "turret1",
		"name": "Turret",
		"currency": &"gem",
		"type": "placeable",
		"category": "turret",
		"frame": 6,
		"price": 5,
		"target_layer": "blocking_buildings",
		"atlas": Vector2i(2, 0),
		"occupies_cell": true,
		# Walkable breakable object. Monsters can step on it, briefly eat it, and
		# then continue their previous route.
		"isWall": false,
		"blocks_movement": false,
		"blocks_projectiles": false,
		# turret1 may only be built on a free, walkable floor tile (not on walls / void).
		"requires_walkable_floor": true,
		"runtime_id": "turret1",
		"shoot_frequency": 3.0,
		"shoot_duration": 0.2,
		"weapon": "spray",
		# Enemy-detection radius. Kept equal to spray.tres's cone radius so the turret
		# only targets enemies the spray can actually reach.
		"range": 200.0,
		"build_in_range": false,
		"max_stack": 999,
	},
}

static func get_item_def(item_id: String) -> Dictionary:
	if ITEM_DEFS.has(item_id):
		return ITEM_DEFS[item_id]
	return {}

static func item_places_tile(item_id: String) -> bool:
	return is_placeable(item_id)

static func get_place_tile(item_id: String) -> Dictionary:
	return get_placeable_def(item_id)

static func is_placeable(item_id: String) -> bool:
	return str(get_item_def(item_id).get("type", "")) == "placeable"

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
