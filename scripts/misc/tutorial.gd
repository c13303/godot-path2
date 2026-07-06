extends RichTextLabel
## Day-phase contextual hint.
##
## Each frame it inspects water first, then during the day it inspects the
## rose/seed economy and shows the single most relevant next step, translated
## through the Translations singleton. Empty water stays visible at night; other
## hints are hidden at night. When every planted rose is watered and the player
## has nothing left to plant or buy, night starts automatically.
##
## Priority order (most prioritary first):
##   1. empty water reserve ......................... Refill your water
##   2. no roses anywhere + no seeds ................ Game Over
##   3. seeds left, shop tool not equipped .......... Buy roses (equip the tool)
##   4. seeds left, shop tool equipped .............. Plant roses
##   5. planted roses still dry ..................... Water your roses
##   6. all roses watered, nothing left ............. Start night automatically

const SEED_KEY: StringName = &"seeds"
const WATER_RESERVE_KEY: StringName = &"water_reserve"

const KEY_GAME_OVER: String = "tutorial.game_over"
const KEY_BUY_ROSES: String = "tutorial.buy_roses"
const KEY_PLANT_ROSES: String = "tutorial.plant_roses"
const KEY_WATER_ROSES: String = "tutorial.water_roses"
const KEY_PASS_NIGHT: String = "tutorial.pass_night"
const KEY_SUN_RISING: String = "tutorial.sun_rising"
const KEY_REFILL_WATER: String = "tutorial.refill_water"
const KEY_CLIENT_TIME: String = "tutorial.client_time"
const KEY_SEED_MERCHANT_REWARD: String = "tutorial.seed_merchant_reward"
const KEY_PLACE_SHOP: String = "tutorial.place_shop"
const KEY_ADD_COUNTERS_TO_SELL_ROSES: String = "tutorial.add_counters_to_sell_roses"
const KEY_HARVEST_ROSE: String = "tutorial.harvest_rose"
const KEY_TANTRUM: String = "tutorial.tantrum"

const ALERT_DURATION: float = 3.0
const ALERT_LIGHT_RED: Color = Color(1.0, 0.28, 0.28)
const ALERT_DARK_RED: Color = Color(0.55, 0.0, 0.0)
const ALERT_FLASH_SPEED: float = 8.0

## When the hint switches messages it first blanks out for this long, so each
## new instruction reads as a distinct prompt rather than a silent swap.
const CHANGE_DELAY: float = 0.5

var _plant_manager: Node
var _progression: Node
var _game_ui: Node
var _building_manager: Node
var _building_object_manager: Node
var _day_toggle: Control
var _displayed_key: String = ""  # key currently shown ("" while blank)
var _pending_key: String = ""    # key we are waiting to reveal
var _pending_remaining: float = 0.0
var _glow_tween: Tween
var _glow_active: bool = false
var _waiting_for_seed_harvest: bool = false
var _alert_key: String = ""
var _alert_remaining: float = 0.0
# True during the sunrise transition: night has just ended but the first day phase
# (the morning harvest) has not begun yet. Set when night turns off, cleared once
# the new day finishes growing / any real phase starts.
var _sun_rising: bool = false


func _ready() -> void:
	bbcode_enabled = true
	fit_content = true
	scroll_active = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_font_size_override("normal_font_size", 26)
	_resolve_nodes()
	if not GameState.mode_changed.is_connected(_on_mode_changed):
		GameState.mode_changed.connect(_on_mode_changed)
	if not Translations.locale_changed.is_connected(_on_locale_changed):
		Translations.locale_changed.connect(_on_locale_changed)
	_refresh()


func _resolve_nodes() -> void:
	var scene: Node = get_tree().current_scene
	if scene != null:
		_plant_manager = scene.get_node_or_null("Map/PlantManager")
		if _plant_manager != null and _plant_manager.has_signal("new_day_finished") \
				and not _plant_manager.is_connected("new_day_finished", Callable(self, "_on_new_day_finished")):
			_plant_manager.connect("new_day_finished", Callable(self, "_on_new_day_finished"))
		_building_manager = scene.get_node_or_null("Map/BuildingManager")
		_building_object_manager = scene.get_node_or_null("Map/BuildingObjectManager")
		_progression = scene.get_node_or_null("progression")
		_game_ui = scene.get_node_or_null("GameUI")
		if not GameState.building_phase_changed.is_connected(_on_building_phase_changed):
			GameState.building_phase_changed.connect(_on_building_phase_changed)
		if not GameState.seed_merchant_phase_changed.is_connected(_on_seed_merchant_phase_changed):
			GameState.seed_merchant_phase_changed.connect(_on_seed_merchant_phase_changed)
	_day_toggle = get_node_or_null("../dayToggle") as Control


func _process(delta: float) -> void:
	_refresh(delta)


func _on_mode_changed(is_night: bool) -> void:
	_waiting_for_seed_harvest = not is_night
	# Night just ended: we are in the sunrise transition until the new day finishes.
	_sun_rising = not is_night
	_refresh()


## The new day has finished growing; the morning phase is about to begin, so the
## sunrise transition is over.
func _on_new_day_finished() -> void:
	_sun_rising = false
	_refresh()


func _on_building_phase_changed(is_building_phase: bool) -> void:
	_waiting_for_seed_harvest = not is_building_phase
	_refresh()


func _on_seed_merchant_phase_changed(is_seed_merchant_phase: bool) -> void:
	_waiting_for_seed_harvest = is_seed_merchant_phase
	_refresh()


func _on_locale_changed(_locale: String) -> void:
	# Same message, new language: re-translate in place without re-blanking.
	if _alert_key != "":
		text = Translations.t(_alert_key)
		return
	if _displayed_key != "":
		text = Translations.t(_displayed_key)


func show_alert(key: String) -> void:
	if key == "":
		return
	_alert_key = key
	_alert_remaining = ALERT_DURATION
	visible = true
	text = Translations.t(_alert_key)
	_set_glow(false)


func _refresh(delta: float = 0.0) -> void:
	if _plant_manager == null or _progression == null or _game_ui == null or _day_toggle == null:
		_resolve_nodes()
	if _alert_key != "":
		_alert_remaining -= delta
		if _alert_remaining > 0.0:
			visible = true
			text = Translations.t(_alert_key)
			var pulse: float = (sin((ALERT_DURATION - _alert_remaining) * ALERT_FLASH_SPEED) + 1.0) * 0.5
			modulate = ALERT_DARK_RED.lerp(ALERT_LIGHT_RED, pulse)
			_set_glow(false)
			return
		_alert_key = ""
		_alert_remaining = 0.0
		modulate = Color.WHITE
	if _should_start_night_automatically():
		_start_night_automatically()
		return
	var key: String = _current_message_key()
	if key == KEY_PASS_NIGHT and not GameState.is_night:
		_start_night_automatically()
		return
	if _waiting_for_seed_harvest and GameState.is_client_phase and key != KEY_REFILL_WATER:
		key = KEY_CLIENT_TIME
	if GameState.is_seed_merchant_phase and not GameState.is_morning_phase and key != KEY_REFILL_WATER and _has_active_night_reward():
		key = KEY_SEED_MERCHANT_REWARD
	if key == "":
		_displayed_key = ""
		text = ""
		visible = false
		modulate = Color.WHITE
		_set_glow(false)
		return
	if GameState.is_night and key != KEY_REFILL_WATER:
		visible = false
		modulate = Color.WHITE
		_set_glow(false)
		return
	visible = true
	modulate = Color.WHITE

	if key == _displayed_key:
		# Already showing the right message; cancel any stale pending switch.
		_pending_key = key
	elif key == KEY_REFILL_WATER:
		_pending_key = key
		_pending_remaining = 0.0
		_displayed_key = key
		text = Translations.t(key)
	else:
		# A change is needed: blank the label and (re)start the delay toward the
		# newest target. The message only appears once it has held for CHANGE_DELAY.
		if key != _pending_key:
			_pending_key = key
			_pending_remaining = CHANGE_DELAY
			_displayed_key = ""
			text = ""
		else:
			_pending_remaining -= delta
			if _pending_remaining <= 0.0:
				_displayed_key = key
				text = Translations.t(key)

	# Glow tracks the message actually on screen, so it stays in step with the text.
	_set_glow(false)


func _current_message_key() -> String:
	var planted: int = 0
	var unwatered: int = 0
	if _plant_manager != null:
		planted = int(_plant_manager.call("rose_count"))
		unwatered = int(_plant_manager.call("unwatered_rose_count"))
	var seeds: int = 0
	var water_reserve: int = 1
	if _progression != null:
		seeds = int(_progression.call("get_value", SEED_KEY))
		water_reserve = int(_progression.call("get_value", WATER_RESERVE_KEY))

	if water_reserve <= 0:
		return KEY_REFILL_WATER
	# Sunrise transition after a night: no day phase has begun yet, so fall through
	# would wrongly show "pass the night". Announce the rising sun instead.
	if _sun_rising and not GameState.is_night:
		return KEY_SUN_RISING
	if GameState.is_morning_phase:
		if _building_manager != null and _building_manager.has_method("has_grownup_roses_to_harvest") and bool(_building_manager.call("has_grownup_roses_to_harvest")):
			if not _has_counter_room_for_harvest():
				return KEY_ADD_COUNTERS_TO_SELL_ROSES
			return KEY_HARVEST_ROSE
		if _rose_shop_counter_count() <= 0:
			return KEY_PLACE_SHOP
		return ""
	if GameState.is_client_phase:
		return KEY_CLIENT_TIME
	if GameState.is_seed_merchant_phase and not GameState.is_morning_phase and _has_active_night_reward():
		return KEY_SEED_MERCHANT_REWARD
	# Nothing growing, no seeds, and no roses left on the counters: the run is lost.
	if planted == 0 and seeds == 0 and _counter_stock() <= 0:
		return KEY_GAME_OVER
	# Seeds buy (and directly place) roses; that outranks watering. The player must
	# first equip the shop tool (KEY_BUY_ROSES); once equipped, prompt them to plant.
	if seeds > 0:
		if _gardening_equipped():
			return KEY_PLANT_ROSES
		return KEY_BUY_ROSES
	# Some planted roses are still dry.
	if unwatered > 0:
		return KEY_WATER_ROSES
	# Every planted rose is watered, and the client sale has actually completed:
	# end the day.
	if _can_start_night_after_clients():
		return KEY_PASS_NIGHT
	return ""


func _should_start_night_automatically() -> bool:
	if GameState.is_night or GameState.is_morning_phase or GameState.is_client_phase or GameState.is_seed_merchant_phase:
		return false
	# During the sunrise transition the new day has not begun yet: no phase flag is set
	# and the roses are still wet from overnight (they only dry when the build phase
	# starts). Without this guard the just-ended night would immediately restart, looping
	# the night forever. Auto-night may only begin once the real day is under way.
	if _sun_rising:
		return false
	return _can_start_night_after_clients()


func _can_start_night_after_clients() -> bool:
	if _building_manager == null or not _building_manager.has_method("can_start_night_after_clients"):
		return false
	return bool(_building_manager.call("can_start_night_after_clients"))


func _start_night_automatically() -> void:
	_displayed_key = ""
	_pending_key = ""
	text = ""
	visible = false
	_set_glow(false)
	GameState.start_night()


## True while the player stands next to the seed merchant, i.e. while its merchant bar is
## shown. When false during the merchant phase the bar is hidden (see toolbuild.gd).
func _player_near_seed_merchant() -> bool:
	return (
		_building_manager != null
		and _building_manager.has_method("is_player_near_seed_merchant")
		and bool(_building_manager.call("is_player_near_seed_merchant"))
	)


## True while the gardening tool is the selected slot. The "plant roses" prompt is gated on
## gardening specifically (not the hammer), since roses are placed from the gardening picker.
func _gardening_equipped() -> bool:
	return (
		_game_ui != null
		and _game_ui.has_method("is_gardening_selected")
		and bool(_game_ui.call("is_gardening_selected"))
	)


func _rose_shop_counter_count() -> int:
	if _building_object_manager != null and _building_object_manager.has_method("count_buildings_by_item_id"):
		return int(_building_object_manager.call("count_buildings_by_item_id", "rose_shop_counter"))
	return 0


func _counter_stock() -> int:
	if _building_manager != null and _building_manager.has_method("total_counter_stock"):
		return int(_building_manager.call("total_counter_stock"))
	return 0


func _has_counter_room_for_harvest() -> bool:
	if _building_manager != null and _building_manager.has_method("has_counter_room_for_harvest"):
		return bool(_building_manager.call("has_counter_room_for_harvest"))
	return false


func _has_active_night_reward() -> bool:
	if _game_ui == null or not _game_ui.has_method("get_active_night_reward"):
		return false
	var reward_info: Dictionary = _game_ui.call("get_active_night_reward") as Dictionary
	return not reward_info.is_empty()


## Pulses the day/night button so the player notices they can end the day.
func _set_glow(active: bool) -> void:
	if active == _glow_active:
		return
	_glow_active = active
	if _glow_tween != null and _glow_tween.is_valid():
		_glow_tween.kill()
		_glow_tween = null
	if _day_toggle == null:
		return
	if active:
		_day_toggle.pivot_offset = _day_toggle.size * 0.5
		_glow_tween = create_tween().set_loops()
		_glow_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		_glow_tween.tween_property(_day_toggle, "modulate", Color(1.0, 0.82, 0.25), 0.55)
		_glow_tween.parallel().tween_property(_day_toggle, "scale", Vector2(1.12, 1.12), 0.55)
		_glow_tween.tween_property(_day_toggle, "modulate", Color.WHITE, 0.55)
		_glow_tween.parallel().tween_property(_day_toggle, "scale", Vector2.ONE, 0.55)
	else:
		_day_toggle.modulate = Color.WHITE
		_day_toggle.scale = Vector2.ONE
