extends RichTextLabel
## Day-phase contextual hint.
##
## Each frame it inspects water first, then during the day it inspects the
## rose/seed economy and shows the single most relevant next step, translated
## through the Translations singleton. Empty water stays visible at night; other
## hints are hidden at night. When every planted rose is watered and the player
## has nothing left to plant or buy, a hold-to-confirm prompt is shown.
##
## Priority order (most prioritary first):
##   1. empty water reserve ......................... Refill your water
##   2. morning harvest (grown roses) ............... Harvest / add counters / place shop
##   3. client sale phase ........................... nothing (only the tantrum alert)
##   4. seed merchant reward waiting ................ Merchant has a reward
##   5. seeds left, shop tool not equipped .......... Buy roses (equip the tool)
##   6. seeds left, shop tool equipped .............. Plant roses
##   7. planted roses still dry ..................... Water your roses
##   8. all roses watered, clients done ............. Hold to start night

const SEED_KEY: StringName = &"seeds"
const WATER_RESERVE_KEY: StringName = &"water_reserve"

const KEY_BUY_ROSES: String = "tutorial.buy_roses"
const KEY_PLANT_ROSES: String = "tutorial.plant_roses"
const KEY_WATER_ROSES: String = "tutorial.water_roses"
const KEY_PASS_NIGHT: String = "tutorial.pass_night"
const KEY_REFILL_WATER: String = "tutorial.refill_water"
const KEY_SEED_MERCHANT_REWARD: String = "tutorial.seed_merchant_reward"
const KEY_PLACE_SHOP: String = "tutorial.place_shop"
const KEY_ADD_COUNTERS_TO_SELL_ROSES: String = "tutorial.add_counters_to_sell_roses"
const KEY_HARVEST_ROSE: String = "tutorial.harvest_rose"
const KEY_TANTRUM: String = "tutorial.tantrum"
const KEY_NO_ROSES_NO_CLIENTS: String = "tutorial.no_roses_no_clients"
const KEY_START_NIGHT_SPACE: String = "tutorial.hold_start_night_space"
const KEY_START_NIGHT_PAD: String = "tutorial.hold_start_night_pad"
const KEY_START_CLIENTS_SPACE: String = "tutorial.hold_start_clients_space"
const KEY_START_CLIENTS_PAD: String = "tutorial.hold_start_clients_pad"

const HOLD_ACTION_NONE: StringName = &""
const HOLD_ACTION_START_CLIENTS: StringName = &"start_clients"
const HOLD_ACTION_START_NIGHT: StringName = &"start_night"
const INPUT_MODE_PAD: String = "pad"
const HOLD_CONFIRM_SECONDS: float = 1.0

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
var _player_controller: Node
var _hold_progress_circle: Control
var _hold_action: StringName = HOLD_ACTION_NONE
var _hold_elapsed: float = 0.0
var _displayed_key: String = ""  # key currently shown ("" while blank)
var _pending_key: String = ""    # key we are waiting to reveal
var _pending_remaining: float = 0.0
var _glow_tween: Tween
var _glow_active: bool = false
var _alert_key: String = ""
var _alert_count: int = -1
var _alert_remaining: float = 0.0
var _alert_persistent: bool = false
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
		_player_controller = scene.get_node_or_null("Player/PlayerController")
		_progression = scene.get_node_or_null("progression")
		_game_ui = scene.get_node_or_null("GameUI")
		_hold_progress_circle = scene.get_node_or_null("GameUI/holdProgressCircle") as Control
		if not GameState.building_phase_changed.is_connected(_on_building_phase_changed):
			GameState.building_phase_changed.connect(_on_building_phase_changed)
		if not GameState.seed_merchant_phase_changed.is_connected(_on_seed_merchant_phase_changed):
			GameState.seed_merchant_phase_changed.connect(_on_seed_merchant_phase_changed)
	_day_toggle = get_node_or_null("../dayToggle") as Control


func _process(delta: float) -> void:
	_refresh(delta)


func _on_mode_changed(is_night: bool) -> void:
	# Night just ended: we are in the sunrise transition until the new day finishes.
	_sun_rising = not is_night
	_refresh()


## The new day has finished growing; the morning phase is about to begin, so the
## sunrise transition is over.
func _on_new_day_finished() -> void:
	_sun_rising = false
	_refresh()


func _on_building_phase_changed(_is_building_phase: bool) -> void:
	_refresh()


func _on_seed_merchant_phase_changed(_is_seed_merchant_phase: bool) -> void:
	_refresh()


func _on_locale_changed(_locale: String) -> void:
	# Same message, new language: re-translate in place without re-blanking.
	if _alert_key != "":
		text = _alert_text()
		return
	if _displayed_key != "":
		text = Translations.t(_displayed_key)


func show_alert(key: String, count: int = -1, persistent: bool = false) -> void:
	if key == "":
		return
	_alert_key = key
	_alert_count = count
	_alert_persistent = persistent
	_alert_remaining = ALERT_DURATION if not persistent else 0.0
	visible = true
	text = _alert_text()
	_set_glow(false)


## Dismiss an active alert early. When key is non-empty only the matching alert is
## cleared, so an unrelated alert that happens to be showing is left untouched.
func clear_alert(key: String = "") -> void:
	if _alert_key == "":
		return
	if key != "" and _alert_key != key:
		return
	_alert_key = ""
	_alert_count = -1
	_alert_remaining = 0.0
	_alert_persistent = false
	modulate = Color.WHITE
	_refresh()


func _refresh(delta: float = 0.0) -> void:
	if _plant_manager == null or _progression == null or _game_ui == null or _day_toggle == null:
		_resolve_nodes()
	if _alert_key != "":
		_reset_hold_progress()
		if _alert_persistent:
			visible = true
			text = _alert_text()
			modulate = ALERT_DARK_RED.lerp(ALERT_LIGHT_RED, 0.5)
			_set_glow(false)
			return
		_alert_remaining -= delta
		if _alert_remaining > 0.0:
			visible = true
			text = _alert_text()
			var pulse: float = (sin((ALERT_DURATION - _alert_remaining) * ALERT_FLASH_SPEED) + 1.0) * 0.5
			modulate = ALERT_DARK_RED.lerp(ALERT_LIGHT_RED, pulse)
			_set_glow(false)
			return
		_alert_key = ""
		_alert_count = -1
		_alert_remaining = 0.0
		_alert_persistent = false
		modulate = Color.WHITE
	# While a spawner-reveal cutscene is scrolling the camera the player has no control,
	# so the contextual hint is hidden. The cutscene shows its own focus alert (handled by
	# the alert branch above), which is why this check sits after it.
	if _is_spawner_reveal_cutscene_active():
		_reset_hold_progress()
		_displayed_key = ""
		_pending_key = ""
		text = ""
		visible = false
		modulate = Color.WHITE
		_set_glow(false)
		return
	if _should_request_start_night_prompt():
		_request_start_night_prompt()
	var hold_action: StringName = _current_hold_action()
	if hold_action != HOLD_ACTION_NONE:
		_show_hold_action(hold_action, delta)
		return
	# The morning harvest can be skipped straight to the client sale by holding space once
	# the roses are grown up. The hold runs in the background so the harvest hint stays on
	# screen; the progress circle only appears while the key is actually held.
	if _morning_client_skip_available():
		_advance_hold(HOLD_ACTION_START_CLIENTS, delta)
	else:
		_reset_hold_progress()
	var key: String = _current_message_key()
	if key == KEY_PASS_NIGHT and not GameState.is_night:
		_request_start_night_prompt()
		_show_hold_action(HOLD_ACTION_START_NIGHT, delta)
		return
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
	var unwatered: int = 0
	if _plant_manager != null:
		unwatered = int(_plant_manager.call("unwatered_rose_count"))
	var seeds: int = 0
	var water_reserve: int = 1
	if _progression != null:
		seeds = int(_progression.call("get_value", SEED_KEY))
		water_reserve = int(_progression.call("get_value", WATER_RESERVE_KEY))

	if water_reserve <= 0:
		return KEY_REFILL_WATER
	# Sunrise transition after a night: no day phase has begun yet, so falling through
	# would wrongly show "pass the night". Stay blank until the morning phase starts.
	if _sun_rising and not GameState.is_night:
		return ""
	if GameState.is_morning_phase:
		if _building_manager != null and _building_manager.has_method("has_grownup_roses_to_harvest") and bool(_building_manager.call("has_grownup_roses_to_harvest")):
			if _has_counter_room_for_harvest():
				return KEY_HARVEST_ROSE
			# Counters all full: nudge to add more, but only once at least one counter
			# exists. With no counter built yet the real next step is to place the shop.
			if _rose_shop_counter_count() > 0:
				return KEY_ADD_COUNTERS_TO_SELL_ROSES
			return KEY_PLACE_SHOP
		if _rose_shop_counter_count() <= 0:
			return KEY_PLACE_SHOP
		return ""
	# Client sale in progress: only the water-empty hint (handled above) and the
	# persistent tantrum alert may show, so suppress every economy hint here.
	if GameState.is_client_phase:
		return ""
	if _client_sale_requested_without_roses():
		return KEY_NO_ROSES_NO_CLIENTS
	if GameState.is_seed_merchant_phase and not GameState.is_morning_phase and _has_active_night_reward():
		return KEY_SEED_MERCHANT_REWARD
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


func _alert_text() -> String:
	var translated: String = Translations.t(_alert_key)
	if _alert_count >= 0:
		return "%s (%d)" % [translated, _alert_count]
	return translated


func _should_request_start_night_prompt() -> bool:
	if GameState.is_night or GameState.is_morning_phase or GameState.is_client_phase or GameState.is_seed_merchant_phase:
		return false
	# During the sunrise transition the new day has not begun yet: no phase flag is set
	# and the roses are still wet from overnight (they only dry when the build phase
	# starts). Without this guard the just-ended night would immediately request the
	# start-night prompt. That request may only happen once the real day is under way.
	if _sun_rising:
		return false
	return _can_start_night_after_clients()


## True while the night or client spawner-reveal cutscene is playing (camera scrolling
## around the spawners with player input locked).
func _is_spawner_reveal_cutscene_active() -> bool:
	if _building_manager == null:
		return false
	if _building_manager.has_method("is_night_start_cutscene_active") and bool(_building_manager.call("is_night_start_cutscene_active")):
		return true
	if _building_manager.has_method("is_client_reveal_cutscene_active") and bool(_building_manager.call("is_client_reveal_cutscene_active")):
		return true
	return false


func _can_start_night_after_clients() -> bool:
	if not _has_planted_roses_on_floor():
		return false
	if _building_manager == null or not _building_manager.has_method("can_start_night_after_clients"):
		return false
	return bool(_building_manager.call("can_start_night_after_clients"))


func _has_planted_roses_on_floor() -> bool:
	if _plant_manager == null or not _plant_manager.has_method("rose_count"):
		return false
	return int(_plant_manager.call("rose_count")) > 0


func _request_start_night_prompt() -> void:
	_displayed_key = ""
	_pending_key = ""
	text = ""
	visible = false
	_set_glow(false)
	if _building_manager != null and _building_manager.has_method("request_night_after_clients"):
		_building_manager.call("request_night_after_clients")


func _current_hold_action() -> StringName:
	if _building_manager == null:
		return HOLD_ACTION_NONE
	if _building_manager.has_method("is_client_sale_start_requested") and bool(_building_manager.call("is_client_sale_start_requested")):
		if not _has_roses_to_sell_today():
			return HOLD_ACTION_NONE
		return HOLD_ACTION_START_CLIENTS
	if _building_manager.has_method("is_night_start_requested") and bool(_building_manager.call("is_night_start_requested")):
		if not _can_start_night_after_clients():
			if _building_manager.has_method("clear_night_start_request"):
				_building_manager.call("clear_night_start_request")
			return HOLD_ACTION_NONE
		return HOLD_ACTION_START_NIGHT
	return HOLD_ACTION_NONE


## Shows the hold prompt as the on-screen hint and advances its progress. Used when the
## phase change is the natural next step, so the label itself is the "hold to..." prompt.
func _show_hold_action(action: StringName, delta: float) -> void:
	_displayed_key = ""
	_pending_key = ""
	_pending_remaining = 0.0
	visible = true
	modulate = Color.WHITE
	text = Translations.t(_hold_translation_key(action))
	_set_glow(false)
	_advance_hold(action, delta)


## Advances a hold without touching the hint label, so it can run in the background while a
## different contextual message stays on screen (e.g. skipping the harvest to start clients).
## The progress circle owns its own visibility and only appears once the key is held.
func _advance_hold(action: StringName, delta: float) -> void:
	if action != _hold_action:
		_hold_action = action
		_hold_elapsed = 0.0
	if _hold_input_pressed():
		_hold_elapsed = minf(HOLD_CONFIRM_SECONDS, _hold_elapsed + delta)
	else:
		_hold_elapsed = 0.0
	_set_hold_progress(_hold_elapsed / HOLD_CONFIRM_SECONDS)
	if _hold_elapsed < HOLD_CONFIRM_SECONDS:
		return
	_trigger_hold_action(action)
	_reset_hold_progress()


## True while the day is awake, the morning harvest is running and at least one rose has
## grown up: the player may start the client sale early, before harvesting.
func _morning_client_skip_available() -> bool:
	if not GameState.is_morning_phase:
		return false
	if _building_manager == null or not _building_manager.has_method("grownup_rose_count"):
		return false
	return int(_building_manager.call("grownup_rose_count")) > 0


func _client_sale_requested_without_roses() -> bool:
	return (
		_building_manager != null
		and _building_manager.has_method("is_client_sale_start_requested")
		and bool(_building_manager.call("is_client_sale_start_requested"))
		and not _has_roses_to_sell_today()
	)


func _has_roses_to_sell_today() -> bool:
	if _building_manager != null and _building_manager.has_method("has_roses_to_sell_today"):
		return bool(_building_manager.call("has_roses_to_sell_today"))
	return false


func _trigger_hold_action(action: StringName) -> void:
	if _building_manager == null:
		return
	if action == HOLD_ACTION_START_CLIENTS and _building_manager.has_method("begin_client_sale_phase"):
		_building_manager.call("begin_client_sale_phase")
	elif action == HOLD_ACTION_START_NIGHT and _building_manager.has_method("try_start_night_after_clients"):
		_building_manager.call("try_start_night_after_clients")


func _hold_translation_key(action: StringName) -> String:
	var pad_mode: bool = _is_pad_mode()
	if action == HOLD_ACTION_START_CLIENTS:
		return KEY_START_CLIENTS_PAD if pad_mode else KEY_START_CLIENTS_SPACE
	if action == HOLD_ACTION_START_NIGHT:
		return KEY_START_NIGHT_PAD if pad_mode else KEY_START_NIGHT_SPACE
	return ""


func _hold_input_pressed() -> bool:
	if _is_pad_mode():
		for device: int in Input.get_connected_joypads():
			if Input.is_joy_button_pressed(device, JOY_BUTTON_X):
				return true
		return false
	return Input.is_physical_key_pressed(KEY_SPACE)


func _is_pad_mode() -> bool:
	return (
		_player_controller != null
		and _player_controller.has_method("get_control_mode")
		and str(_player_controller.call("get_control_mode")) == INPUT_MODE_PAD
	)


func _set_hold_progress(value: float) -> void:
	if _hold_progress_circle == null:
		return
	_hold_progress_circle.set("progress", value)


func _reset_hold_progress() -> void:
	_hold_action = HOLD_ACTION_NONE
	_hold_elapsed = 0.0
	# Setting progress to 0 hides the circle: it owns its own "never show while empty" rule.
	_set_hold_progress(0.0)


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


func _has_counter_room_for_harvest() -> bool:
	if _building_manager != null and _building_manager.has_method("has_counter_room_for_harvest"):
		return bool(_building_manager.call("has_counter_room_for_harvest"))
	return false


func _has_active_night_reward() -> bool:
	if _game_ui == null or not _game_ui.has_method("get_active_night_reward"):
		return false
	var reward_info: Dictionary = _game_ui.call("get_active_night_reward") as Dictionary
	return not reward_info.is_empty()


## Pulses the day/night icon so the player notices they can end the day.
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
