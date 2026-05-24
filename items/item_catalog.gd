extends RefCounted
class_name ItemCatalog

const ITEM_DEFS: Dictionary = {
	"sword": {
		"id": "sword",
		"name": "Sword",
		"category": "tools",
		"frame": 0,
	},
	"bomb": {
		"id": "bomb",
		"name": "Bomb",
		"category": "tools",
		"frame": 1,
	},
	"water": {
		"id": "water",
		"name": "Water",
		"category": "tools",
		"frame": 2,
	},
	"wall": {
		"id": "wall",
		"name": "Wall",
		"category": "blocks",
		"frame": 3,
		"place_tile": {
			"layer": "wallz",
			"atlas": Vector2i(11, 1),
		},
	},
}

static func get_item_def(item_id: String) -> Dictionary:
	if ITEM_DEFS.has(item_id):
		return ITEM_DEFS[item_id]
	return {}

static func item_places_tile(item_id: String) -> bool:
	return get_item_def(item_id).has("place_tile")

static func get_place_tile(item_id: String) -> Dictionary:
	var item_def := get_item_def(item_id)
	var raw: Variant = item_def.get("place_tile", {})
	if raw is Dictionary:
		return raw
	return {}
