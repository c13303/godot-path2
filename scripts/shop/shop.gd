extends Panel

const SEED_KEY: StringName = &"seeds"

@onready var title_label: Label = $MarginContainer/Content/Title
@onready var rose_button: Button = $MarginContainer/Content/Items/Rose
@onready var turret_button: Button = $MarginContainer/Content/Items/Turret
@onready var wall_button: Button = $MarginContainer/Content/Items/Wall

var progression_node: Node
var game_ui: Node


func _ready() -> void:
	visible = false
	var scene: Node = get_tree().current_scene
	progression_node = scene.get_node_or_null("progression") if scene != null else null
	game_ui = scene.get_node_or_null("GameUI") if scene != null else null
	rose_button.pressed.connect(_on_item_pressed.bind("rose"))
	turret_button.pressed.connect(_on_item_pressed.bind("turret1"))
	wall_button.pressed.connect(_on_item_pressed.bind("wall"))


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


func _on_item_pressed(item_id: String) -> void:
	if progression_node == null or game_ui == null:
		return
	var seed_count: int = int(progression_node.call("get_value", SEED_KEY))
	if seed_count <= 0:
		_show_no_seed()
		return
	var added: bool = bool(game_ui.call("add_inventory", item_id, 1))
	if not added:
		return
	var spent: bool = bool(progression_node.call("update_seeds", -1))
	if not spent:
		_show_no_seed()
		return
	_reset_title()


func _show_no_seed() -> void:
	title_label.text = "no seed"
	title_label.add_theme_color_override("font_color", Color.RED)


func _reset_title() -> void:
	title_label.text = "Shop"
	title_label.remove_theme_color_override("font_color")
