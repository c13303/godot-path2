extends Panel

const SEED_KEY: StringName = &"seeds"
const GEM_KEY: StringName = &"gems"
const SEED_CURRENCY: StringName = &"seed"
const GEM_CURRENCY: StringName = &"gem"
const BULK_BUY_HOLD_SECONDS: float = 0.5

## Price for each shop item, keyed by the inventory item id. The item's
## currency is defined in ItemCatalog.
const PRICES: Dictionary = {
	"rose": 1,
	"turret1": 5,
	"wall": 100,
}

class HoldProgressDisc:
	extends Control

	var _progress: float = 0.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_progress(value: float) -> void:
		_progress = clampf(value, 0.0, 1.0)
		queue_redraw()

	func _draw() -> void:
		var center: Vector2 = size * 0.5
		var radius: float = minf(size.x, size.y) * 0.42
		if radius <= 0.0:
			return
		draw_circle(center, radius, Color(0.0, 0.0, 0.0, 0.45))
		draw_arc(center, radius, 0.0, TAU, 48, Color(1.0, 1.0, 1.0, 0.25), 3.0, true)
		if _progress <= 0.0:
			return
		var start_angle: float = -PI * 0.5
		var end_angle: float = start_angle + TAU * _progress
		var segments: int = maxi(3, int(ceilf(48.0 * _progress)))
		var points: PackedVector2Array = PackedVector2Array()
		points.append(center)
		for i: int in range(segments + 1):
			var step_progress: float = float(i) / float(segments)
			var angle: float = lerpf(start_angle, end_angle, step_progress)
			points.append(center + Vector2(cos(angle), sin(angle)) * radius)
		draw_colored_polygon(points, Color(0.55, 1.0, 0.65, 0.75))
		draw_arc(center, radius, start_angle, end_angle, segments, Color(0.85, 1.0, 0.9, 0.95), 3.0, true)

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
var _held_item_id: String = ""
var _held_button: Button
var _hold_elapsed: float = 0.0
var _hold_progress_disc: HoldProgressDisc


func _ready() -> void:
	var scene: Node = get_tree().current_scene
	progression_node = scene.get_node_or_null("progression") if scene != null else null
	game_ui = scene.get_node_or_null("GameUI") if scene != null else null
	rose_button.button_down.connect(_start_bulk_buy_hold.bind("rose", rose_button))
	turret_button.button_down.connect(_start_bulk_buy_hold.bind("turret1", turret_button))
	wall_button.button_down.connect(_start_bulk_buy_hold.bind("wall", wall_button))
	rose_button.button_up.connect(_cancel_bulk_buy_hold)
	turret_button.button_up.connect(_cancel_bulk_buy_hold)
	wall_button.button_up.connect(_cancel_bulk_buy_hold)

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
	set_process(false)


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
	if not visible:
		_cancel_bulk_buy_hold()
	get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if (
		_held_item_id == ""
		or _held_button == null
		or not visible
		or GameState.is_night
		or not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	):
		_cancel_bulk_buy_hold()
		return
	_hold_elapsed = minf(_hold_elapsed + delta, BULK_BUY_HOLD_SECONDS)
	if _hold_progress_disc != null:
		_position_hold_progress_disc()
		_hold_progress_disc.set_progress(_hold_elapsed / BULK_BUY_HOLD_SECONDS)
	if _hold_elapsed >= BULK_BUY_HOLD_SECONDS:
		var item_id: String = _held_item_id
		var source_button: Button = _held_button
		_cancel_bulk_buy_hold()
		_buy_maximum(item_id, source_button)


## Auto-close the shop at night. On a new day, wait for harvested seeds to land.
func _on_game_mode_changed(is_night: bool) -> void:
	_cancel_bulk_buy_hold()
	visible = false
	_waiting_for_seed_harvest = not is_night


func _on_day_seed_harvest_finished() -> void:
	_waiting_for_seed_harvest = false
	if not GameState.is_night:
		visible = true


func _start_bulk_buy_hold(item_id: String, source_button: Button) -> void:
	if not visible or GameState.is_night:
		return
	_cancel_bulk_buy_hold()
	_held_item_id = item_id
	_held_button = source_button
	_hold_elapsed = 0.0
	_hold_progress_disc = HoldProgressDisc.new()
	_hold_progress_disc.name = "BulkBuyProgressDisc"
	add_child(_hold_progress_disc)
	_hold_progress_disc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hold_progress_disc.z_index = 100
	_position_hold_progress_disc()
	_hold_progress_disc.set_progress(0.0)
	set_process(true)


func _position_hold_progress_disc() -> void:
	if _hold_progress_disc == null or _held_button == null:
		return
	var button_rect: Rect2 = _held_button.get_global_rect()
	_hold_progress_disc.global_position = button_rect.position
	_hold_progress_disc.size = button_rect.size


func _cancel_bulk_buy_hold() -> void:
	_held_item_id = ""
	_held_button = null
	_hold_elapsed = 0.0
	if _hold_progress_disc != null:
		_hold_progress_disc.queue_free()
		_hold_progress_disc = null
	set_process(false)


func _buy_maximum(item_id: String, source_button: Control) -> void:
	if progression_node == null or game_ui == null:
		return
	var price: int = int(PRICES.get(item_id, 0))
	if price <= 0:
		return
	var currency: StringName = ItemCatalog.get_currency(item_id)
	var progression_key: StringName = _progression_key_for_currency(currency)
	if progression_key.is_empty():
		push_error("Shop: item '%s' has no valid currency" % item_id)
		return
	var currency_count: int = int(progression_node.call("get_value", progression_key))
	if currency_count < price:
		_show_insufficient_currency(currency)
		return
	var quantity: int = _maximum_purchasable_quantity(item_id, price, currency_count)
	if quantity <= 0:
		return
	# Validate capacity before spending; the actual add happens when the
	# flight animation lands in the toolbar.
	if not bool(game_ui.call("can_add_inventory", item_id, quantity)):
		return
	var total_price: int = price * quantity
	var spent: bool = bool(progression_node.call("spend", progression_key, total_price))
	if not spent:
		_show_insufficient_currency(currency)
		return
	var source_position: Vector2 = source_button.get_global_rect().get_center()
	game_ui.call("add_inventory_animated", item_id, quantity, source_position)
	Sfx.play_sound(&"buy")
	_reset_title()


func _maximum_purchasable_quantity(item_id: String, price: int, currency_count: int) -> int:
	var affordable_quantity: int = floori(float(currency_count) / float(price))
	var low: int = 0
	var high: int = affordable_quantity
	while low < high:
		var midpoint: int = floori(float(low + high + 1) * 0.5)
		if bool(game_ui.call("can_add_inventory", item_id, midpoint)):
			low = midpoint
		else:
			high = midpoint - 1
	return low


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
