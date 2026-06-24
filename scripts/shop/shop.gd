extends Panel

const SEED_KEY: StringName = &"seeds"
const GEM_KEY: StringName = &"gems"
const SEED_CURRENCY: StringName = &"seed"
const GEM_CURRENCY: StringName = &"gem"

## Price for each shop item, keyed by the inventory item id. The item's
## currency is defined in ItemCatalog.
const PRICES: Dictionary = {
	"rose": 1,
	"turret1": 5,
	"wall": 100,
}

@onready var title_label: Label = $MarginContainer/Content/Title
@onready var rose_button: Button = $MarginContainer/Content/Items/RoseItem/Rose
@onready var turret_button: Button = $MarginContainer/Content/Items/TurretItem/Turret
@onready var wall_button: Button = $MarginContainer/Content/Items/WallItem/Wall
@onready var rose_price_label: Label = $MarginContainer/Content/Items/RoseItem/Price/Amount
@onready var turret_price_label: Label = $MarginContainer/Content/Items/TurretItem/Price/Amount
@onready var wall_price_label: Label = $MarginContainer/Content/Items/WallItem/Price/Amount

var progression_node: Node
var game_ui: Node
var _waiting_for_seed_harvest: bool = false


func _ready() -> void:
	var scene: Node = get_tree().current_scene
	progression_node = scene.get_node_or_null("progression") if scene != null else null
	game_ui = scene.get_node_or_null("GameUI") if scene != null else null
	rose_button.pressed.connect(_on_item_pressed.bind("rose", rose_button))
	turret_button.pressed.connect(_on_item_pressed.bind("turret1", turret_button))
	wall_button.pressed.connect(_on_item_pressed.bind("wall", wall_button))

	# Buy buttons are mouse-only. Without this they grab keyboard/gamepad focus
	# on click, after which the Viewport's GUI layer swallows navigation input
	# (arrows, Tab, Enter, Esc, d-pad/stick) before it reaches the game.
	for button: Button in [rose_button, turret_button, wall_button]:
		button.focus_mode = Control.FOCUS_NONE

	rose_price_label.text = str(int(PRICES["rose"]))
	turret_price_label.text = str(int(PRICES["turret1"]))
	wall_price_label.text = str(int(PRICES["wall"]))

	# The shop is open during the day and closed during the night.
	GameState.mode_changed.connect(_on_game_mode_changed)
	var plant_manager: Node = scene.get_node_or_null("Map/PlantManager") if scene != null else null
	if plant_manager != null and plant_manager.has_signal("day_seed_harvest_finished"):
		plant_manager.connect("day_seed_harvest_finished", _on_day_seed_harvest_finished)
	visible = not GameState.is_night


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key_event: InputEventKey = event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return
	if key_event.keycode != KEY_TAB:
		return
	if _waiting_for_seed_harvest:
		return
	visible = not visible
	get_viewport().set_input_as_handled()


## Auto-close the shop at night. On a new day, wait for harvested seeds to land.
func _on_game_mode_changed(is_night: bool) -> void:
	visible = false
	_waiting_for_seed_harvest = not is_night


func _on_day_seed_harvest_finished() -> void:
	_waiting_for_seed_harvest = false
	if not GameState.is_night:
		visible = true


func _on_item_pressed(item_id: String, source_button: Control) -> void:
	if progression_node == null or game_ui == null:
		return
	var price: int = int(PRICES.get(item_id, 0))
	var currency: StringName = ItemCatalog.get_currency(item_id)
	var progression_key: StringName = _progression_key_for_currency(currency)
	if progression_key.is_empty():
		push_error("Shop: item '%s' has no valid currency" % item_id)
		return
	var currency_count: int = int(progression_node.call("get_value", progression_key))
	if currency_count < price:
		_show_insufficient_currency(currency)
		return
	# Validate capacity before spending; the actual add happens when the
	# flight animation lands in the toolbar.
	if not bool(game_ui.call("can_add_inventory", item_id, 1)):
		return
	var spent: bool = bool(progression_node.call("spend", progression_key, price))
	if not spent:
		_show_insufficient_currency(currency)
		return
	var source_position: Vector2 = source_button.get_global_rect().get_center()
	game_ui.call("add_inventory_animated", item_id, 1, source_position)
	Sfx.play_sound(&"buy")
	_reset_title()


func _show_insufficient_currency(currency: StringName) -> void:
	title_label.text = "no %s" % String(currency)
	title_label.add_theme_color_override("font_color", Color.RED)


func _progression_key_for_currency(currency: StringName) -> StringName:
	if currency == SEED_CURRENCY:
		return SEED_KEY
	if currency == GEM_CURRENCY:
		return GEM_KEY
	return &""


func _reset_title() -> void:
	title_label.text = "Shop"
	title_label.remove_theme_color_override("font_color")
