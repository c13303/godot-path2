extends RichTextLabel
## Day-phase contextual hint.
##
## Each frame during the day it inspects the rose/seed economy and shows the
## single most relevant next step, translated through the Translations
## singleton. The hint is hidden at night. When every planted rose is watered
## and the player has nothing left to plant or buy, it prompts them to pass the
## night and makes the day/night button glow.
##
## Priority order (most prioritary first):
##   1. no roses anywhere + no seeds ................. Game Over
##   2. seeds left to spend .......................... Buy roses
##   3. planted roses still dry ...................... Water your roses
##   4. all roses watered, nothing left ............. Pass the night (+ glow)

const SEED_KEY: StringName = &"seeds"

const KEY_GAME_OVER: String = "tutorial.game_over"
const KEY_BUY_ROSES: String = "tutorial.buy_roses"
const KEY_WATER_ROSES: String = "tutorial.water_roses"
const KEY_PASS_NIGHT: String = "tutorial.pass_night"

## When the hint switches messages it first blanks out for this long, so each
## new instruction reads as a distinct prompt rather than a silent swap.
const CHANGE_DELAY: float = 2.0

var _plant_manager: Node
var _game_ui: Node
var _progression: Node
var _shop: CanvasItem
var _day_toggle: Button
var _displayed_key: String = ""  # key currently shown ("" while blank)
var _pending_key: String = ""    # key we are waiting to reveal
var _pending_remaining: float = 0.0
var _glow_tween: Tween
var _glow_active: bool = false


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
		_game_ui = scene.get_node_or_null("GameUI")
		_progression = scene.get_node_or_null("progression")
		_shop = scene.get_node_or_null("GameUI/right anchor/Shop") as CanvasItem
	_day_toggle = get_node_or_null("../dayToggle") as Button


func _process(delta: float) -> void:
	_refresh(delta)


func _on_mode_changed(_is_night: bool) -> void:
	_refresh()


func _on_locale_changed(_locale: String) -> void:
	# Same message, new language: re-translate in place without re-blanking.
	if _displayed_key != "":
		text = Translations.t(_displayed_key)


func _refresh(delta: float = 0.0) -> void:
	if _plant_manager == null or _game_ui == null or _progression == null or _shop == null or _day_toggle == null:
		_resolve_nodes()
	# The hint is only relevant while the shop is open. The shop hides itself at
	# night and stays hidden until the day's seed-harvest animation finishes, so
	# mirroring its visibility also keeps the hint hidden during the harvest.
	if _shop == null or not _shop.visible:
		visible = false
		_set_glow(false)
		return
	visible = true
	var key: String = _current_message_key()

	if key == _displayed_key:
		# Already showing the right message; cancel any stale pending switch.
		_pending_key = key
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


func _current_message_key() -> String:
	var planted: int = 0
	var unwatered: int = 0
	if _plant_manager != null:
		planted = int(_plant_manager.call("rose_count"))
		unwatered = int(_plant_manager.call("unwatered_rose_count"))
	var seeds: int = 0
	if _progression != null:
		seeds = int(_progression.call("get_value", SEED_KEY))

	# Nothing growing and nothing to build with: the run is lost.
	if planted == 0 and seeds == 0:
		return KEY_GAME_OVER
	# Seeds buy (and directly place) roses; that outranks watering.
	if seeds > 0:
		return KEY_BUY_ROSES
	# Some planted roses are still dry.
	if unwatered > 0:
		return KEY_WATER_ROSES
	# Every planted rose is watered and nothing is left to do: end the day.
	return KEY_PASS_NIGHT


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
