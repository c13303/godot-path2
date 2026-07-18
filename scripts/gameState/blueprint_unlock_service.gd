extends RefCounted
class_name BlueprintUnlockService

## Owns permanent blueprint unlocks. Definitions are intentionally kept as small,
## explicit data: paid blueprints can have prerequisites, while automatic blueprints
## can unlock as soon as all of their prerequisites are owned.

const BLUEPRINT_DEFS: Dictionary = {
	&"ronce": {
		"build_item_id": &"ronce",
		"currency": &"money",
		"price": 10,
		"prerequisites": [],
		"automatic": false,
		"initially_published": true,
	},
	&"fence": {
		"build_item_id": &"fence",
		"currency": &"money",
		"price": 10,
		"prerequisites": [],
		"automatic": false,
		"initially_published": false,
		"initially_unlocked": true,
	},
	&"kraken": {
		"build_item_id": &"kraken",
		"currency": &"money",
		"price": 10,
		"prerequisites": [&"ronce", &"fence"],
		"automatic": false,
		"initially_published": false,
	},
	&"turret_helice": {
		"build_item_id": &"turret_helice",
		"currency": &"money",
		"price": 10,
		"prerequisites": [],
		"automatic": false,
		"initially_published": false,
	},
}

const PAID_BLUEPRINT_ORDER: Array[StringName] = [&"ronce", &"fence", &"kraken", &"turret_helice"]

var _progression: Node
var _unlocked_ids: Dictionary = {}
var _published_ids: Dictionary = {}
var _unseen_published_ids: Dictionary = {}


func setup(progression: Node) -> void:
	_progression = progression
	_initialize_initial_unlocks()
	_initialize_initial_publications()


func is_blueprint_buildable(item_id: String) -> bool:
	return _blueprint_id_for_build_item(item_id) != &""


func is_blueprint_unlocked(item_id: String) -> bool:
	var blueprint_id: StringName = _blueprint_id_for_build_item(item_id)
	return blueprint_id == &"" or _unlocked_ids.has(blueprint_id)


func get_purchasable_blueprint_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for blueprint_id: StringName in PAID_BLUEPRINT_ORDER:
		if _published_ids.has(blueprint_id) and not _unlocked_ids.has(blueprint_id):
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
	if _unlocked_ids.has(blueprint_id) or not _published_ids.has(blueprint_id):
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


func publish_newly_eligible_blueprints_for_dawn() -> bool:
	var changed: bool = false
	for blueprint_id: StringName in PAID_BLUEPRINT_ORDER:
		if _unlocked_ids.has(blueprint_id) or _published_ids.has(blueprint_id):
			continue
		if _prerequisites_satisfied(blueprint_id):
			_published_ids[blueprint_id] = true
			_unseen_published_ids[blueprint_id] = true
			changed = true
	return changed


func has_unseen_published_blueprints() -> bool:
	return not _unseen_published_ids.is_empty()


func mark_published_blueprints_seen() -> bool:
	if _unseen_published_ids.is_empty():
		return false
	_unseen_published_ids.clear()
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
	_published_ids.clear()
	_unseen_published_ids.clear()
	# Baseline unlocks (e.g. Fence) are permanent and never depend on the save, so seed them
	# before restoring so even a pre-baseline save still starts with them unlocked.
	_initialize_initial_unlocks()
	if not (data is Array):
		_initialize_initial_publications()
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
	_initialize_initial_publications()


func get_publication_save_data() -> Dictionary:
	var published: Array[String] = _string_ids(_published_ids)
	var unseen: Array[String] = _string_ids(_unseen_published_ids)
	return {"published": published, "unseen": unseen}


func apply_publication_save_data(data: Variant) -> void:
	# Old saves did not persist publication state. They retain the authored initial
	# offers and do not gain a simulated dawn during load.
	if not (data is Dictionary):
		return
	var saved: Dictionary = data as Dictionary
	if not saved.has("published") and not saved.has("unseen"):
		return
	_published_ids.clear()
	_unseen_published_ids.clear()
	_apply_saved_id_list(saved.get("published", []), _published_ids)
	_apply_saved_id_list(saved.get("unseen", []), _unseen_published_ids)
	for raw_id: Variant in _unseen_published_ids.keys():
		if not _published_ids.has(raw_id):
			_unseen_published_ids.erase(raw_id)


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


func _initialize_initial_unlocks() -> void:
	for raw_id: Variant in BLUEPRINT_DEFS.keys():
		var blueprint_id: StringName = raw_id as StringName
		var definition: Dictionary = _definition(blueprint_id)
		if bool(definition.get("initially_unlocked", false)):
			_unlocked_ids[blueprint_id] = true


func _initialize_initial_publications() -> void:
	for blueprint_id: StringName in PAID_BLUEPRINT_ORDER:
		var definition: Dictionary = _definition(blueprint_id)
		if bool(definition.get("initially_published", false)):
			_published_ids[blueprint_id] = true
			_unseen_published_ids[blueprint_id] = true


func _apply_saved_id_list(data: Variant, target: Dictionary) -> void:
	if not (data is Array):
		return
	for raw_id: Variant in (data as Array):
		var blueprint_id: StringName = StringName(str(raw_id))
		if BLUEPRINT_DEFS.has(blueprint_id):
			target[blueprint_id] = true


func _string_ids(ids: Dictionary) -> Array[String]:
	var result: Array[String] = []
	for raw_id: Variant in ids.keys():
		result.append(String(raw_id))
	result.sort()
	return result


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
