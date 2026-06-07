extends RefCounted
class_name ItemCatalog

const ITEM_DEFS: Dictionary = {
	"sword": {
		"id": "sword",
		"name": "Sword",
		"item_type": "weapon",
		"category": "tools",
		"frame": 0,
	},
	"bomb": {
		"id": "bomb",
		"name": "Bomb",
		"item_type": "weapon",
		"category": "tools",
		"frame": 1,
	},
	"water": {
		"id": "water",
		"name": "Water",
		"item_type": "gun",
		"category": "tools",
		"frame": 2,
	},
	"wall": {
		"id": "wall",
		"name": "Wall",
		"item_type": "placeable",
		"category": "blocks",
		"frame": 3,
		"placeable_kind": "wall",
		"target_layer": "wallz",
		"atlas": Vector2i(11, 1),
		"occupies_cell": true,
		"blocks_movement": true,
		"blocks_projectiles": true,
		"runtime_id": "",
	},
	"rose": {
		"id": "rose",
		"name": "Rose",
		"item_type": "placeable",
		"category": "buildings",
		"frame": 5,
		"placeable_kind": "building",
		"building_subtype": "edible_plant",
		"target_layer": "plantz",
		"atlas": Vector2i(0, 0),
		"occupies_cell": true,
		"blocks_movement": false,
		"blocks_projectiles": false,
		"runtime_id": "rose",
	},
	"lamp": {
		"id": "lamp",
		"name": "Lamp",
		"item_type": "placeable",
		"category": "buildings",
		"frame": 4,
		"placeable_kind": "building",
		"building_subtype": "lamp",
		"target_layer": "buildings",
		"atlas": Vector2i(1, 0),
		"occupies_cell": true,
		"blocks_movement": false,
		"blocks_projectiles": false,
		"runtime_id": "lamp",
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
	return str(get_item_def(item_id).get("item_type", "")) == "placeable"

static func get_placeable_def(item_id: String) -> Dictionary:
	var item_def: Dictionary = get_item_def(item_id)
	if is_placeable(item_id):
		return item_def
	var raw: Variant = item_def.get("place_tile", {})
	if raw is Dictionary:
		return raw
	return {}
