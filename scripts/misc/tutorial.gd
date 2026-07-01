extends RichTextLabel
## Day-phase contextual hint.
##
## Each frame it inspects water first, then during the day it inspects the
## rose/seed economy and shows the single most relevant next step, translated
## through the Translations singleton. Empty water stays visible at night; other
## hints are hidden at night. When every planted rose is watered and the player
## has nothing left to plant or buy, it prompts them to pass the night and makes
## the day/night button glow. Until then the day/night button is disabled, so the
## night cannot be triggered while roses are still unplanted or unwatered.
##
## Priority order (most prioritary first):
##   1. empty water reserve ......................... Refill your water
##   2. no roses anywhere + no seeds ................ Game Over
##   3. seeds left, shop tool not equipped .......... Buy roses (equip the tool)
##   4. seeds left, shop tool equipped .............. Plant roses
##   5. planted roses still dry ..................... Water your roses
##   6. all roses watered, nothing left ............. Pass the night (+ glow)

const SEED_KEY: StringName = &"seeds"
const WATER_RESERVE_KEY: StringName = &"water_reserve"

const KEY_GAME_OVER: String = "tutorial.game_over"
const KEY_BUY_ROSES: String = "tutorial.buy_roses"
const KEY_PLANT_ROSES: String = "tutorial.plant_roses"
const KEY_WATER_ROSES: String = "tutorial.water_roses"
const KEY_PASS_NIGHT: String = "tutorial.pass_night"
const KEY_REFILL_WATER: String = "tutorial.refill_water"
const KEY_NEW_DAY: String = "tutorial.new_day"

## When the hint switches messages it first blanks out for this long, so each
## new instruction reads as a distinct prompt rather than a silent swap.
const CHANGE_DELAY: float = 0.5

var _plant_manager: Node
var _progression: Node
var _game_ui: Node
var _day_toggle: Button
var _displayed_key: String = ""  # key currently shown ("" while blank)
var _pending_key: String = ""    # key we are waiting to reveal
var _pending_remaining: float = 0.0
var _glow_tween: Tween
var _glow_active: bool = false
var _waiting_for_seed_harvest: bool = false


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
		_progression = scene.get_node_or_null("progression")
		_game_ui = scene.get_node_or_null("GameUI")
		if not GameState.building_phase_changed.is_connected(_on_building_phase_changed):
			GameState.building_phase_changed.connect(_on_building_phase_changed)
	_day_toggle = get_node_or_null("../dayToggle") as Button


func _process(delta: float) -> void:
	_refresh(delta)


func _on_mode_changed(is_night: bool) -> void:
	_waiting_for_seed_harvest = not is_night
	_refresh()


func _on_building_phase_changed(is_building_phase: bool) -> void:
	_waiting_for_seed_harvest = not is_building_phase
	_refresh()


func _on_locale_changed(_locale: String) -> void:
	# Same message, new language: re-translate in place without re-blanking.
	if _displayed_key != "":
		text = Translations.t(_displayed_key)


func _refresh(delta: float = 0.0) -> void:
	if _plant_manager == null or _progression == null or _game_ui == null or _day_toggle == null:
		_resolve_nodes()
	var key: String = _current_message_key()
	if _waiting_for_seed_harvest and key != KEY_REFILL_WATER:
		key = KEY_NEW_DAY
	if GameState.is_night and key != KEY_REFILL_WATER:
		visible = false
		_set_glow(false)
		_update_day_toggle_interactable()
		return
	visible = true

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
	_set_glow(_displayed_key == KEY_PASS_NIGHT)
	_update_day_toggle_interactable()


## The player can only trigger the night once every rose is planted and watered,
## i.e. exactly when the "pass the night" prompt (and its glow) is on screen. The
## night is left interactable so GameState can still guard the night->day return.
func _update_day_toggle_interactable() -> void:
	if _day_toggle == null:
		return
	_day_toggle.disabled = not (GameState.is_night or _displayed_key == KEY_PASS_NIGHT)


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
	if not GameState.is_building_phase:
		return KEY_NEW_DAY
	# Nothing growing and nothing to build with: the run is lost.
	if planted == 0 and seeds == 0:
		return KEY_GAME_OVER
	# Seeds buy (and directly place) roses; that outranks watering. The player must
	# first equip the shop tool (KEY_BUY_ROSES); once equipped, prompt them to plant.
	if seeds > 0:
		if _shop_tool_equipped():
			return KEY_PLANT_ROSES
		return KEY_BUY_ROSES
	# Some planted roses are still dry.
	if unwatered > 0:
		return KEY_WATER_ROSES
	# Every planted rose is watered and nothing is left to do: end the day.
	return KEY_PASS_NIGHT


## True while the quick-bar shop/build tool is the selected slot (the shop is open).
func _shop_tool_equipped() -> bool:
	return (
		_game_ui != null
		and _game_ui.has_method("is_build_tool_selected")
		and bool(_game_ui.call("is_build_tool_selected"))
	)


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
