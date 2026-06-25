extends Panel

## The shop is the entry point to build mode. Clicking an item selects it (a green
## frame appears) and the cursor enters build mode for that item, provided the
## player can afford one. Buildings are paid for directly from currency as they are
## placed and never enter the inventory. Hiding the shop (Tab / Esc / right-click /
## the close button) clears the selection and returns to the weapon toolbar.

const SEED_KEY: StringName = &"seeds"
const GEM_KEY: StringName = &"gems"
const SEED_CURRENCY: StringName = &"seed"
const GEM_CURRENCY: StringName = &"gem"

@onready var title_label: Label = $MarginContainer/Content/Title
@onready var rose_button: Button = $MarginContainer/Content/Items/RoseItem/Rose
@onready var turret_button: Button = $MarginContainer/Content/Items/TurretItem/Turret
@onready var wall_button: Button = $MarginContainer/Content/Items/WallItem/Wall
@onready var rose_price_label: Label = $MarginContainer/Content/Items/RoseItem/Price/Amount
@onready var turret_price_label: Label = $MarginContainer/Content/Items/TurretItem/Price/Amount
@onready var wall_price_label: Label = $MarginContainer/Content/Items/WallItem/Price/Amount
@onready var close_button: Button = $CloseButton

var progression_node: Node
var game_ui: Node
var _waiting_for_seed_harvest: bool = false
var _selected_item_id: String = ""
var _selection_frame: Panel
# Shop item id -> its button, used to drive selection and position the green frame.
var _item_buttons: Dictionary = {}


func _ready() -> void:
	var scene: Node = get_tree().current_scene
	progression_node = scene.get_node_or_null("progression") if scene != null else null
	game_ui = scene.get_node_or_null("GameUI") if scene != null else null

	_item_buttons = {
		"rose": rose_button,
		"turret1": turret_button,
		"wall": wall_button,
	}
	for raw_item_id: Variant in _item_buttons:
		var item_id: String = String(raw_item_id)
		var button: Button = _item_buttons[item_id]
		button.pressed.connect(_on_item_pressed.bind(item_id))
		# Mouse-only buttons. Without this they grab keyboard/gamepad focus on click,
		# after which the Viewport's GUI layer swallows navigation input before it
		# reaches the game.
		button.focus_mode = Control.FOCUS_NONE

	if close_button != null:
		close_button.pressed.connect(_close_shop)
		close_button.focus_mode = Control.FOCUS_NONE

	rose_price_label.text = str(ItemCatalog.get_price("rose"))
	turret_price_label.text = str(ItemCatalog.get_price("turret1"))
	wall_price_label.text = str(ItemCatalog.get_price("wall"))

	# The shop is open during the day and closed during the night.
	GameState.mode_changed.connect(_on_game_mode_changed)
	var plant_manager: Node = scene.get_node_or_null("Map/PlantManager") if scene != null else null
	if plant_manager != null and plant_manager.has_signal("day_seed_harvest_finished"):
		plant_manager.connect("day_seed_harvest_finished", _on_day_seed_harvest_finished)
	visible = not GameState.is_night


func _input(event: InputEvent) -> void:
	# Right-click anywhere hides the shop (and exits build mode).
	if event is InputEventMouseButton:
		var mouse_event: InputEventMouseButton = event as InputEventMouseButton
		if mouse_event.button_index == MOUSE_BUTTON_RIGHT and mouse_event.pressed and visible:
			_close_shop()
			get_viewport().set_input_as_handled()
		return

	if not (event is InputEventKey):
		return
	var key_event: InputEventKey = event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return

	if key_event.keycode == KEY_TAB:
		if _waiting_for_seed_harvest:
			return
		_set_shop_visible(not visible)
		get_viewport().set_input_as_handled()
	elif key_event.keycode == KEY_ESCAPE and visible:
		_close_shop()
		get_viewport().set_input_as_handled()


## Auto-close the shop at night. On a new day, wait for harvested seeds to land.
func _on_game_mode_changed(is_night: bool) -> void:
	_set_shop_visible(false)
	_waiting_for_seed_harvest = not is_night


func _on_day_seed_harvest_finished() -> void:
	_waiting_for_seed_harvest = false
	if not GameState.is_night:
		visible = true


func _on_item_pressed(item_id: String) -> void:
	if not visible or GameState.is_night:
		return
	# Clicking the already-selected item toggles it back off.
	if _selected_item_id == item_id:
		_clear_selection()
		_reset_title()
		return
	# Build mode is only entered when the player can afford at least one.
	if not _can_afford(item_id):
		_show_insufficient_currency(ItemCatalog.get_currency(item_id))
		return
	_select_item(item_id)
	_reset_title()


func _select_item(item_id: String) -> void:
	_selected_item_id = item_id
	if game_ui != null and game_ui.has_method("set_selected_build_item"):
		game_ui.call("set_selected_build_item", item_id)
	_show_selection_frame_over(_item_buttons[item_id])
	Sfx.play_sound(&"buy")


func _clear_selection() -> void:
	_selected_item_id = ""
	if game_ui != null and game_ui.has_method("clear_build_selection"):
		game_ui.call("clear_build_selection")
	if _selection_frame != null:
		_selection_frame.visible = false


func _close_shop() -> void:
	_set_shop_visible(false)


func _set_shop_visible(value: bool) -> void:
	visible = value
	if not value:
		_clear_selection()
		_reset_title()


func _can_afford(item_id: String) -> bool:
	return game_ui != null and game_ui.has_method("can_afford_build") and bool(game_ui.call("can_afford_build", item_id, 1))


func _ensure_selection_frame() -> void:
	if _selection_frame != null:
		return
	_selection_frame = Panel.new()
	_selection_frame.name = "BuildSelectionFrame"
	_selection_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_selection_frame.z_index = 50
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(0.20, 1.0, 0.35, 0.12)
	style.set_border_width_all(3)
	style.border_color = Color(0.30, 1.0, 0.45)
	style.set_corner_radius_all(6)
	_selection_frame.add_theme_stylebox_override("panel", style)
	add_child(_selection_frame)


func _show_selection_frame_over(button: Control) -> void:
	_ensure_selection_frame()
	var rect: Rect2 = button.get_global_rect()
	var pad: float = 3.0
	_selection_frame.global_position = rect.position - Vector2(pad, pad)
	_selection_frame.size = rect.size + Vector2(pad * 2.0, pad * 2.0)
	_selection_frame.visible = true


func _show_insufficient_currency(currency: StringName) -> void:
	title_label.text = "no %s" % String(currency)
	title_label.add_theme_color_override("font_color", Color.RED)


func _reset_title() -> void:
	title_label.text = "Shop"
	title_label.remove_theme_color_override("font_color")
