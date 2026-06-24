extends Panel

const SEED_KEY: StringName = &"seeds"

## Price (in seeds) for each shop item, keyed by the inventory item id.
const PRICES: Dictionary = {
	"rose": 1,
	"turret1": 10,
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


func _ready() -> void:
	var scene: Node = get_tree().current_scene
	progression_node = scene.get_node_or_null("progression") if scene != null else null
	game_ui = scene.get_node_or_null("GameUI") if scene != null else null
	rose_button.pressed.connect(_on_item_pressed.bind("rose", rose_button))
	turret_button.pressed.connect(_on_item_pressed.bind("turret1", turret_button))
	wall_button.pressed.connect(_on_item_pressed.bind("wall", wall_button))

	rose_price_label.text = str(int(PRICES["rose"]))
	turret_price_label.text = str(int(PRICES["turret1"]))
	wall_price_label.text = str(int(PRICES["wall"]))

	# The shop is open during the day and closed during the night.
	GameState.mode_changed.connect(_on_game_mode_changed)
	visible = not GameState.is_night


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key_event: InputEventKey = event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return
	if key_event.keycode != KEY_TAB:
		return
	visible = not visible
	get_viewport().set_input_as_handled()


## Auto-close the shop when night starts, auto-open it when day starts.
func _on_game_mode_changed(is_night: bool) -> void:
	visible = not is_night


func _on_item_pressed(item_id: String, source_button: Control) -> void:
	if progression_node == null or game_ui == null:
		return
	var price: int = int(PRICES.get(item_id, 0))
	var seed_count: int = int(progression_node.call("get_value", SEED_KEY))
	if seed_count < price:
		_show_no_seed()
		return
	# Validate capacity before spending; the actual add happens when the
	# flight animation lands in the toolbar.
	if not bool(game_ui.call("can_add_inventory", item_id, 1)):
		return
	var spent: bool = bool(progression_node.call("update_seeds", -price))
	if not spent:
		_show_no_seed()
		return
	var source_position: Vector2 = source_button.get_global_rect().get_center()
	game_ui.call("add_inventory_animated", item_id, 1, source_position)
	_reset_title()


func _show_no_seed() -> void:
	title_label.text = "no seed"
	title_label.add_theme_color_override("font_color", Color.RED)


func _reset_title() -> void:
	title_label.text = "Shop"
	title_label.remove_theme_color_override("font_color")
