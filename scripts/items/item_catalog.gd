extends RefCounted
class_name ItemCatalog

const ITEM_DEFS: Dictionary = {
	"sword": {
		"id": "sword",
		"name": "Sword",
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
		"max_stack": 99,
	},
	"rose": {
		"id": "rose",
		"name": "Rose",
		"type": "placeable",
		"category": "plant",
		"frame": 5,
		"target_layer": "plantz",
		"atlas": Vector2i(0, 0),
		"occupies_cell": true,
		"blocks_movement": false,
		"blocks_projectiles": false,
		"runtime_id": "rose",
		"max_stack": 99,
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
		"max_stack": 99,
	},
	"turret1": {
		"id": "turret1",
		"name": "Turret",
		"type": "placeable",
		"category": "turret",
		"frame": 6,
		"target_layer": "blocking_buildings",
		"atlas": Vector2i(2, 0),
		"occupies_cell": true,
		# Breakable dynamic obstacle: blocks local agent movement, but is NOT static
		# wall topology — it must never feed wall signatures / flowfield rebuilds.
		"isWall": true,
		"blocks_movement": true,
		"blocks_projectiles": false,
		# turret1 may only be built on a free, walkable floor tile (not on walls / void).
		"requires_walkable_floor": true,
		"runtime_id": "turret1",
		"max_stack": 99,
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

static func get_max_stack(item_id: String) -> int:
	return maxi(1, int(get_item_def(item_id).get("max_stack", 1)))

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
