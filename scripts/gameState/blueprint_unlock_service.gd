extends RefCounted
class_name BlueprintUnlockService

## Owns permanent blueprint unlocks. Definitions are intentionally kept as small,
## explicit data: paid blueprints can have prerequisites, while automatic blueprints
## unlock as soon as all of their prerequisites are owned.

const BLUEPRINT_DEFS: Dictionary = {
	&"ronce": {
		"build_item_id": &"ronce",
		"currency": &"money",
		"price": 10,
		"prerequisites": [],
		"automatic": false,
	},
	&"fence": {
		"build_item_id": &"fence",
		"currency": &"money",
		"price": 10,
		"prerequisites": [],
		"automatic": false,
	},
	&"kraken": {
		"build_item_id": &"kraken",
		"currency": &"",
		"price": 0,
		"prerequisites": [&"ronce", &"fence"],
		"automatic": true,
	},
}

const PAID_BLUEPRINT_ORDER: Array[StringName] = [&"ronce", &"fence"]

var _progression: Node
var _unlocked_ids: Dictionary = {}


func setup(progression: Node) -> void:
	_progression = progression


func is_blueprint_buildable(item_id: String) -> bool:
	return _blueprint_id_for_build_item(item_id) != &""


func is_blueprint_unlocked(item_id: String) -> bool:
	var blueprint_id: StringName = _blueprint_id_for_build_item(item_id)
	return blueprint_id == &"" or _unlocked_ids.has(blueprint_id)


func get_purchasable_blueprint_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for blueprint_id: StringName in PAID_BLUEPRINT_ORDER:
		if not _unlocked_ids.has(blueprint_id) and _prerequisites_satisfied(blueprint_id):
			ids.append(blueprint_id)
	return ids


func get_blueprint_price(blueprint_id: StringName) -> int:
	var definition: Dictionary = _definition(blueprint_id)
	return int(definition.get("price", 0))


func get_blueprint_currency(blueprint_id: StringName) -> StringName:
	var definition: Dictionary = _definition(blueprint_id)
	return StringName(definition.get("currency", &""))


func can_purchase_blueprint(blueprint_id: StringName) -> bool:
	var definition: Dictionary = _definition(blueprint_id)
	if definition.is_empty() or bool(definition.get("automatic", false)):
		return false
	if _unlocked_ids.has(blueprint_id) or not _prerequisites_satisfied(blueprint_id):
		return false
	var currency: StringName = get_blueprint_currency(blueprint_id)
	var price: int = get_blueprint_price(blueprint_id)
	if _progression == null or currency == &"" or price <= 0:
		return false
	if not _progression.has_method("get_currency_value"):
		return false
	return int(_progression.call("get_currency_value", currency)) >= price


func try_purchase_blueprint(blueprint_id: StringName) -> bool:
	if not can_purchase_blueprint(blueprint_id):
		return false
	var currency: StringName = get_blueprint_currency(blueprint_id)
	var price: int = get_blueprint_price(blueprint_id)
	if not _progression.has_method("update_currency"):
		return false
	# Currency is changed first through its authoritative API. Unlock state changes only
	# after that succeeds, so every rejected purchase leaves both pieces of state untouched.
	if not bool(_progression.call("update_currency", currency, -price)):
		return false
	_unlocked_ids[blueprint_id] = true
	_resolve_automatic_unlocks()
	return true


func get_save_data() -> Array[String]:
	var data: Array[String] = []
	for raw_id: Variant in BLUEPRINT_DEFS.keys():
		var blueprint_id: StringName = raw_id as StringName
		if _unlocked_ids.has(blueprint_id):
			data.append(String(blueprint_id))
	data.sort()
	return data


func apply_save_data(data: Variant) -> void:
	_unlocked_ids.clear()
	if not (data is Array):
		return
	for raw_id: Variant in (data as Array):
		if not (raw_id is String):
			continue
		var blueprint_id: StringName = StringName(str(raw_id))
		var definition: Dictionary = _definition(blueprint_id)
		if definition.is_empty():
			push_warning("BlueprintUnlockService: ignored unknown saved blueprint '%s'" % String(blueprint_id))
			continue
		# Automatic unlocks are derived state. Recompute them below instead of trusting
		# a malformed save that grants one without its prerequisites.
		if not bool(definition.get("automatic", false)):
			_unlocked_ids[blueprint_id] = true
	_resolve_automatic_unlocks()


func _resolve_automatic_unlocks() -> void:
	var changed: bool = true
	while changed:
		changed = false
		for raw_id: Variant in BLUEPRINT_DEFS.keys():
			var blueprint_id: StringName = raw_id as StringName
			var definition: Dictionary = _definition(blueprint_id)
			if not bool(definition.get("automatic", false)) or _unlocked_ids.has(blueprint_id):
				continue
			if _prerequisites_satisfied(blueprint_id):
				_unlocked_ids[blueprint_id] = true
				changed = true


func _prerequisites_satisfied(blueprint_id: StringName) -> bool:
	var definition: Dictionary = _definition(blueprint_id)
	var raw_prerequisites: Variant = definition.get("prerequisites", [])
	if not (raw_prerequisites is Array):
		return false
	for raw_prerequisite: Variant in (raw_prerequisites as Array):
		var prerequisite_id: StringName = StringName(str(raw_prerequisite))
		if not _unlocked_ids.has(prerequisite_id):
			return false
	return true


func _blueprint_id_for_build_item(item_id: String) -> StringName:
	var blueprint_id: StringName = StringName(item_id)
	return blueprint_id if BLUEPRINT_DEFS.has(blueprint_id) else &""


func _definition(blueprint_id: StringName) -> Dictionary:
	var raw_definition: Variant = BLUEPRINT_DEFS.get(blueprint_id, {})
	return raw_definition as Dictionary if raw_definition is Dictionary else {}
