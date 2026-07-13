extends RefCounted
class_name CurrencyCatalog

const ITEM_FRAME_SIZE: Vector2 = Vector2(32.0, 32.0)

const CURRENCY_DEFS: Dictionary = {
	&"money": {
		"id": &"money",
		"display_name": "Money",
		"progression_key": &"money",
		"item_id": "money",
		"icon_node_name": "moneyIcon",
		"label_node_name": "moneyQT",
		"region": Rect2(416.0, 0.0, 32.0, 32.0),
	},
	&"seed": {
		"id": &"seed",
		"display_name": "Seeds",
		"progression_key": &"seeds",
		"item_id": "seed",
		"icon_node_name": "seedIcon",
		"label_node_name": "seedQT",
		"region": Rect2(226.0, 0.0, 32.0, 32.0),
	},
	&"gem": {
		"id": &"gem",
		"display_name": "Gems",
		"progression_key": &"gems",
		"item_id": "gem",
		"icon_node_name": "gemIcon",
		"label_node_name": "gemQT",
		"region": Rect2(256.0, 0.0, 32.0, 32.0),
	},
	&"bamboo": {
		"id": &"bamboo",
		"display_name": "Bamboo",
		"progression_key": &"bamboo",
		"item_id": "bamboo",
		"icon_node_name": "bambooIcon",
		"label_node_name": "bambooQT",
		"region": Rect2(23.0 * ITEM_FRAME_SIZE.x, 0.0, ITEM_FRAME_SIZE.x, ITEM_FRAME_SIZE.y),
	},
}

const CURRENCY_ORDER: Array[StringName] = [&"money", &"seed", &"gem", &"bamboo"]


static func get_currency_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for currency: StringName in CURRENCY_ORDER:
		if CURRENCY_DEFS.has(currency):
			ids.append(currency)
	for raw_currency: Variant in CURRENCY_DEFS.keys():
		var currency: StringName = raw_currency as StringName
		if not ids.has(currency):
			ids.append(currency)
	return ids


static func has_currency(currency: StringName) -> bool:
	return CURRENCY_DEFS.has(currency)


static func get_currency_def(currency: StringName) -> Dictionary:
	if CURRENCY_DEFS.has(currency):
		return CURRENCY_DEFS[currency] as Dictionary
	return {}


static func get_display_name(currency: StringName) -> String:
	return str(get_currency_def(currency).get("display_name", String(currency).capitalize()))


static func get_progression_key(currency: StringName) -> StringName:
	return StringName(get_currency_def(currency).get("progression_key", &""))


static func get_item_id(currency: StringName) -> String:
	return str(get_currency_def(currency).get("item_id", String(currency)))


static func get_icon_node_name(currency: StringName) -> String:
	return str(get_currency_def(currency).get("icon_node_name", "%sIcon" % String(currency)))


static func get_label_node_name(currency: StringName) -> String:
	return str(get_currency_def(currency).get("label_node_name", "%sQT" % String(currency)))


static func get_icon_region(currency: StringName) -> Rect2:
	return get_currency_def(currency).get("region", Rect2()) as Rect2
