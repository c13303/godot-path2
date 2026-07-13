extends Control
class_name PossessedItemsHud

const ITEMS_TEXTURE: Texture2D = preload("res://assets/sprites/legval/items.png")
const SEED_ICON_SCRIPT: Script = preload("res://scripts/ui/seed_icon.gd")
const GEM_ICON_SCRIPT: Script = preload("res://scripts/ui/gem_icon.gd")
const MONEY_ICON_SCRIPT: Script = preload("res://scripts/ui/money_icon.gd")
const GENERIC_CURRENCY_ICON_SCRIPT: Script = preload("res://scripts/ui/generic_currency_icon.gd")
const ITEM_FRAME_SIZE: Vector2 = Vector2(32.0, 32.0)
const ROW_SIZE: Vector2 = Vector2(40.0, 40.0)
const LABEL_SIZE: Vector2 = Vector2(70.0, 34.0)
const BOTTOM_ROW_Y: float = -64.0
const ROW_STEP_Y: float = -50.0
@export var game_ui_path: NodePath = NodePath("..")
@export var progression_path: NodePath = NodePath("../../progression")

var _game_ui: Node
var _progression: Node
var _rows: Dictionary = {}
var _labels: Dictionary = {}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_game_ui = get_node_or_null(game_ui_path)
	_progression = get_node_or_null(progression_path)
	if _progression != null and _progression.has_signal("values_changed"):
		_progression.connect("values_changed", Callable(self, "refresh"))
	if _game_ui != null and _game_ui.has_signal("inventory_changed"):
		_game_ui.connect("inventory_changed", Callable(self, "refresh"))
	refresh()


func refresh() -> void:
	var counts: Dictionary = _collect_possessed_counts()
	var ordered_ids: Array[String] = _ordered_item_ids(counts)
	for currency: StringName in CurrencyCatalog.get_currency_ids():
		_ensure_row(CurrencyCatalog.get_item_id(currency))
	for item_id: String in ordered_ids:
		_ensure_row(item_id)
	for raw_item_id: Variant in _rows.keys():
		var item_id: String = str(raw_item_id)
		var row: Control = _rows[item_id] as Control
		var label: RichTextLabel = _labels[item_id] as RichTextLabel
		var quantity: int = int(counts.get(item_id, 0))
		var visible_now: bool = quantity > 0
		row.visible = visible_now
		if label != null:
			label.text = "x %d" % quantity
	_layout_rows(ordered_ids, counts)


func get_item_flight_target_global_position(item_id: String) -> Vector2:
	if item_id == "":
		return global_position
	if not _rows.has(item_id):
		_ensure_row(item_id)
	var row: Control = _rows.get(item_id, null) as Control
	if row == null:
		return global_position
	var rect: Rect2 = row.get_global_rect()
	if row.visible:
		return rect.get_center()
	return rect.position


func _collect_possessed_counts() -> Dictionary:
	var counts: Dictionary = {}
	if _progression != null and _progression.has_method("get_value"):
		for currency: StringName in CurrencyCatalog.get_currency_ids():
			var key: StringName = CurrencyCatalog.get_progression_key(currency)
			var item_id: String = CurrencyCatalog.get_item_id(currency)
			var quantity: int = int(_progression.call("get_value", key))
			if quantity > 0:
				counts[item_id] = quantity
	if _game_ui != null and _game_ui.has_method("get_possessed_inventory_item_counts"):
		var raw_counts: Variant = _game_ui.call("get_possessed_inventory_item_counts")
		if raw_counts is Dictionary:
			for raw_item_id: Variant in (raw_counts as Dictionary).keys():
				var item_id: String = str(raw_item_id)
				var quantity: int = int((raw_counts as Dictionary)[raw_item_id])
				if item_id != "" and quantity > 0 and not ItemCatalog.is_weapon(item_id):
					counts[item_id] = int(counts.get(item_id, 0)) + quantity
	return counts


func _ordered_item_ids(counts: Dictionary) -> Array[String]:
	var ids: Array[String] = []
	for currency: StringName in CurrencyCatalog.get_currency_ids():
		var item_id: String = CurrencyCatalog.get_item_id(currency)
		if int(counts.get(item_id, 0)) > 0:
			ids.append(item_id)
	for raw_item_id: Variant in counts.keys():
		var item_id: String = str(raw_item_id)
		if item_id != "" and not ids.has(item_id) and int(counts[item_id]) > 0:
			ids.append(item_id)
	ids.sort_custom(Callable(self, "_sort_currency_first"))
	return ids


func _sort_currency_first(a: String, b: String) -> bool:
	var order: Array[String] = []
	for currency: StringName in CurrencyCatalog.get_currency_ids():
		order.append(CurrencyCatalog.get_item_id(currency))
	var ai: int = order.find(a)
	var bi: int = order.find(b)
	if ai >= 0 or bi >= 0:
		if ai < 0:
			return false
		if bi < 0:
			return true
		return ai < bi
	return a < b


func _ensure_row(item_id: String) -> void:
	if _rows.has(item_id):
		return
	var currency: StringName = _currency_for_item_id(item_id)
	var icon: TextureRect = null
	if currency != &"":
		icon = get_node_or_null(CurrencyCatalog.get_icon_node_name(currency)) as TextureRect
	if icon == null:
		icon = TextureRect.new()
		icon.name = item_id + "Icon"
		add_child(icon)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.visible = false
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture = _item_texture(item_id)
	icon.custom_minimum_size = ROW_SIZE
	icon.size = ROW_SIZE
	_apply_currency_animation_script(icon, item_id)

	var label_name: String = CurrencyCatalog.get_label_node_name(currency) if currency != &"" else "quantity"
	var label: RichTextLabel = icon.get_node_or_null(label_name) as RichTextLabel
	if label == null:
		label = RichTextLabel.new()
		label.name = label_name
		icon.add_child(label)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.bbcode_enabled = true
	label.fit_content = true
	label.scroll_active = false
	label.offset_left = 40.0
	label.offset_top = 5.0
	label.offset_right = 110.0
	label.offset_bottom = 39.0
	label.custom_minimum_size = LABEL_SIZE
	_rows[item_id] = icon
	_labels[item_id] = label


func _apply_currency_animation_script(icon: TextureRect, item_id: String) -> void:
	if icon.get_script() != null:
		return
	match item_id:
		"seed":
			icon.set_script(SEED_ICON_SCRIPT)
		"gem":
			icon.set_script(GEM_ICON_SCRIPT)
		"money":
			icon.set_script(MONEY_ICON_SCRIPT)
		_:
			var currency: StringName = _currency_for_item_id(item_id)
			if currency != &"":
				icon.set_script(GENERIC_CURRENCY_ICON_SCRIPT)
				icon.set("currency_id", currency)


func _item_texture(item_id: String) -> AtlasTexture:
	var texture: AtlasTexture = AtlasTexture.new()
	texture.atlas = ITEMS_TEXTURE
	var currency: StringName = _currency_for_item_id(item_id)
	if currency != &"":
		texture.region = CurrencyCatalog.get_icon_region(currency)
		return texture
	var item_def: Dictionary = ItemCatalog.get_item_def(item_id)
	var frame: int = int(item_def.get("frame", -1))
	if frame < 0:
		return null
	texture.region = Rect2(Vector2(float(frame) * ITEM_FRAME_SIZE.x, 0.0), ITEM_FRAME_SIZE)
	return texture


func _currency_for_item_id(item_id: String) -> StringName:
	for currency: StringName in CurrencyCatalog.get_currency_ids():
		if CurrencyCatalog.get_item_id(currency) == item_id:
			return currency
	return &""


func _layout_rows(ordered_ids: Array[String], counts: Dictionary) -> void:
	var y: float = BOTTOM_ROW_Y
	for item_id: String in ordered_ids:
		if int(counts.get(item_id, 0)) <= 0:
			continue
		var row: Control = _rows[item_id] as Control
		row.offset_left = 165.0
		row.offset_top = y
		row.offset_right = 205.0
		row.offset_bottom = y + ROW_SIZE.y
		y += ROW_STEP_Y
