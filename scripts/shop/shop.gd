extends Panel

## The shop is the building picker for build mode. It is open exactly while the
## quick-bar Build tool is selected (see game_ui.is_build_tool_selected) and during
## the day; selecting any other quick slot closes it. Clicking an affordable item
## selects it (a green frame appears) so the build system places it; buildings are
## paid for directly from currency and never enter the inventory.

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

var progression_node: Node
var game_ui: Node
var _waiting_for_seed_harvest: bool = false
# The building currently picked for placement (drives the green frame + build mode).
var _selected_item_id: String = ""
# The last building the player picked; restored when the shop reopens (if affordable).
var _last_picked_item_id: String = ""
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

	rose_price_label.text = str(ItemCatalog.get_price("rose"))
	turret_price_label.text = str(ItemCatalog.get_price("turret1"))
	wall_price_label.text = str(ItemCatalog.get_price("wall"))

# The shop is closed during the night and during the morning sale phase.
	GameState.mode_changed.connect(_on_game_mode_changed)
	_waiting_for_seed_harvest = false
	if not GameState.building_phase_changed.is_connected(_on_building_phase_changed):
		GameState.building_phase_changed.connect(_on_building_phase_changed)
	_set_shop_open(false)
	set_process(true)


## Shop visibility is derived from the quick-bar selection: open only while the
## Build tool is the selected quick slot (and it is daytime, past the harvest).
func _process(_delta: float) -> void:
	var should_show: bool = (
		game_ui != null
		and game_ui.has_method("is_build_tool_selected")
		and bool(game_ui.call("is_build_tool_selected"))
		and not GameState.is_night
		and GameState.is_building_phase
		and not _waiting_for_seed_harvest
	)
	if should_show and not visible:
		_open_shop()
	elif not should_show and visible:
		_close_shop()


func _open_shop() -> void:
	_set_shop_open(true)
	# Resume placing the building we were last on, if we can still afford it.
	if _last_picked_item_id != "" and _can_afford(_last_picked_item_id):
		_select_item(_last_picked_item_id)


func _close_shop() -> void:
	_set_shop_open(false)
	_deselect_active()
	_reset_title()


func _set_shop_open(is_open: bool) -> void:
	visible = is_open
	mouse_filter = Control.MOUSE_FILTER_STOP if is_open else Control.MOUSE_FILTER_IGNORE


## At night and during morning sale the shop is closed. Once building phase starts,
## the build tool is auto-selected to reopen it.
func _on_game_mode_changed(is_night: bool) -> void:
	_waiting_for_seed_harvest = not is_night


func _on_building_phase_changed(is_building_phase: bool) -> void:
	_waiting_for_seed_harvest = not is_building_phase
	if is_building_phase and not GameState.is_night and game_ui != null and game_ui.has_method("select_build_tool"):
		game_ui.call("select_build_tool")


func _on_item_pressed(item_id: String) -> void:
	if not visible or GameState.is_night:
		return
	# Clicking the already-selected item toggles it back off and forgets it.
	if _selected_item_id == item_id:
		_deselect_active()
		_last_picked_item_id = ""
		_reset_title()
		return
	# Build placement is only armed when the player can afford at least one.
	if not _can_afford(item_id):
		_show_insufficient_currency(ItemCatalog.get_currency(item_id))
		return
	_select_item(item_id)
	_reset_title()


func _select_item(item_id: String) -> void:
	_selected_item_id = item_id
	_last_picked_item_id = item_id
	if game_ui != null and game_ui.has_method("set_selected_build_item"):
		game_ui.call("set_selected_build_item", item_id)
	_show_selection_frame_over(_item_buttons[item_id])
	Sfx.play_sound(&"buy")


## Clears the active build pick (green frame + build mode) but remembers it for the
## next time the shop opens.
func _deselect_active() -> void:
	_selected_item_id = ""
	if game_ui != null and game_ui.has_method("clear_build_selection"):
		game_ui.call("clear_build_selection")
	if _selection_frame != null:
		_selection_frame.visible = false


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
