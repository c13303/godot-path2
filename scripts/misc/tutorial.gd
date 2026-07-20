extends RichTextLabel
## Day-phase contextual hint.
##
## Each frame it first checks for the temporary unbuild mode, then water, and
## during the day it inspects the rose/seed economy. It shows the single most
## relevant next step, translated through the Translations singleton. Empty water
## stays visible at night; other hints are hidden at night. Once the phase owner says
## the afternoon can end, holding the confirm input ends the day from under any hint —
## build/economy steps and Builder onboarding alike. The only exception is the Builder
## intro prompt, which binds the same input to its own action.
##
## Priority order (most prioritary first):
##   1. fundamental Builder onboarding .............. allow entry / talk / build house
##   2. unbuild tool selected ....................... Select objects to dismantle
##   3. empty water reserve ......................... Refill your water
##   4. day 2, less than 10 bamboo .................. Collect bamboo (world arrow on the grove)
##   5. dawn harvest (grown roses) .................. Harvest / add counters / place shop
##   6. client sale phase ........................... nothing (only the tantrum alert)
##   7. seeds left, day 1 .......................... Buy roses (equip the tool) / Plant roses
##   8. seeds left, day 2+ ......................... Plant roses, once per day
##   9. planted roses still dry ..................... Water your roses
##  10. day 1 build steps (wall/pasteque/turret) .... Block passage / plant pasteque / turret
##  11. day 1 not enough roses for tomorrow ......... Plant more roses
##  12. all roses watered, clients done ............. Hold to start night

const SEED_KEY: StringName = &"seeds"
const WATER_RESERVE_KEY: StringName = &"water_reserve"
const BAMBOO_KEY: StringName = &"bamboo"
## Bamboo the player must own before the "collect bamboo" step considers itself answered.
const REQUIRED_BAMBOO: int = 10
const TutorialArrowScript: Script = preload("res://scripts/misc/tutorial_arrow.gd")
const TutorialWorldArrowScript: Script = preload("res://scripts/misc/tutorial_world_arrow.gd")

const KEY_BUY_ROSES: String = "tutorial.buy_roses"
const KEY_PLANT_ROSES: String = "tutorial.plant_roses"
const KEY_WATER_ROSES: String = "tutorial.water_roses"
const KEY_BLOCK_PASSAGE_WALL: String = "tutorial.block_passage_wall"
const KEY_PLANT_PASTEQUE: String = "tutorial.plant_pasteque"
const KEY_PLANT_TURRET_EPINE: String = "tutorial.plant_turret_epine"
const KEY_PASS_NIGHT: String = "tutorial.pass_night"
const KEY_REFILL_WATER: String = "tutorial.refill_water"
const KEY_COLLECT_BAMBOO: String = "tutorial.collect_bamboo"
const KEY_PLACE_SHOP: String = "tutorial.place_shop"
const KEY_ADD_COUNTERS_TO_SELL_ROSES: String = "tutorial.add_counters_to_sell_roses"
const KEY_HARVEST_ROSE: String = "tutorial.harvest_rose"
const KEY_TANTRUM: String = "tutorial.tantrum"
const KEY_NO_ROSES_NO_CLIENTS: String = "tutorial.no_roses_no_clients"
const KEY_PLANT_MORE_ROSES: String = "tutorial.plant_more_roses"
const KEY_BUILDER_IS_HERE: String = "tutorial.builder_is_here"
const KEY_ALLOW_BUILDER_SPACE: String = "tutorial.allow_builder_space"
const KEY_ALLOW_BUILDER_PAD: String = "tutorial.allow_builder_pad"
const KEY_TALK_BUILDER: String = "tutorial.talk_builder"
const KEY_BUILD_BUILDER_HOUSE: String = "tutorial.build_builder_house"
const KEY_WAIT_BUILDER_BUILD: String = "tutorial.wait_builder_build"
const KEY_BUILD_MERCHANT_HOUSE: String = "tutorial.build_merchant_house"
const KEY_START_NIGHT_SPACE: String = "tutorial.hold_start_night_space"
const KEY_START_NIGHT_PAD: String = "tutorial.hold_start_night_pad"
const KEY_START_CLIENTS_SPACE: String = "tutorial.hold_start_clients_space"
const KEY_START_CLIENTS_PAD: String = "tutorial.hold_start_clients_pad"
const KEY_UNBUILD_SELECTION: String = "tutorial.unbuild_selection"

const HOLD_ACTION_NONE: StringName = &""
const HOLD_ACTION_ALLOW_BUILDER: StringName = &"allow_builder"
const HOLD_ACTION_START_CLIENTS: StringName = &"start_clients"
const HOLD_ACTION_START_NIGHT: StringName = &"start_night"
const INPUT_MODE_PAD: String = "pad"
const HOLD_CONFIRM_SECONDS: float = 1.0
## The hold actions that advance the phase. HOLD_ACTION_ALLOW_BUILDER is deliberately absent:
## it binds the same input, but it requests a cutscene rather than moving the phase on, so the
## phase-toggle button must stay grey and inert while it owns the input.
const PHASE_HOLD_ACTIONS: Array[StringName] = [HOLD_ACTION_START_CLIENTS, HOLD_ACTION_START_NIGHT]
## Last day on which the "hold to start night" hint is shown. It is onboarding: it plays before
## night 1 (day 1) and night 2 (day 2), then stops for the rest of the run. `nDays` increments
## at dawn, so day N is the day preceding night N. Only the hint stops — the hold itself and
## the phase-toggle button keep working every day.
const START_NIGHT_PROMPT_LAST_DAY: int = 2

const ALERT_DURATION: float = 3.0
const ALERT_LIGHT_RED: Color = Color(1.0, 0.28, 0.28)
const ALERT_DARK_RED: Color = Color(0.55, 0.0, 0.0)
const ALERT_FLASH_SPEED: float = 8.0
const GARDENING_TOOL_ID: String = "gardening"
const HAMMER_TOOL_ID: String = "hammer"
const BUILD_HOUSE_TOOL_ID: String = "buildhouse"
const ROSE_ITEM_ID: String = "rose"
const PASTEQUE_ITEM_ID: String = "pasteque"
const TURRET_EPINE_ITEM_ID: String = "turret_epine"
const COUNTER_ITEM_ID: String = "rose_shop_counter"
const WALL_ITEM_ID: String = "wall"
const HOUSE_BUILDER_ITEM_ID: String = "house_builder"
const HOUSE_MERCHANT_ITEM_ID: String = "house_merchant"
## Returned by _rose_shop_counter_count when the building manager is not resolved yet. It is
## not zero: zero is the authoritative answer "the player owns no counter", which drives the
## "place the shop" step, whereas unknown must show nothing at all.
const COUNTER_COUNT_UNKNOWN: int = -1

## When the hint switches messages it first blanks out for this long, so each
## new instruction reads as a distinct prompt rather than a silent swap.
const CHANGE_DELAY: float = 0.5

var _plant_manager: Node
var _progression: Node
var _game_ui: Node
var _toolbuild: Control
var _building_manager: Node
var _building_object_manager: Node
var _planificator: Control
var _player_controller: Node
var _hold_progress_circle: Control
var _hold_action: StringName = HOLD_ACTION_NONE
var _hold_elapsed: float = 0.0
var _displayed_key: String = ""  # key currently shown ("" while blank)
var _pending_key: String = ""    # key we are waiting to reveal
var _pending_remaining: float = 0.0
# The phase advance the confirm input is bound to this frame, or HOLD_ACTION_NONE. Recorded by
# _refresh as it walks its branch tree rather than re-derived, so the reading published to the
# phase-toggle button can never drift out of step with what the input actually does. Note this
# is not _hold_action: that one only names the hold being tracked, which for the background
# holds means "available AND currently held".
var _available_phase_action: StringName = HOLD_ACTION_NONE
var _alert_key: String = ""
var _alert_count: int = -1
var _alert_remaining: float = 0.0
var _alert_persistent: bool = false
var _tutorial_arrow: TutorialArrow
var _tutorial_world_arrow: TutorialWorldArrow
var _text_animator: TutorialTextAnimator = TutorialTextAnimator.new()
var _has_planted_turret_epine: bool = false
# Wall stock captured the first time the day-1 wall step is evaluated. The step is skipped
# once the current stock drops below this, i.e. as soon as one starting wall is placed.
var _wall_stock_baseline: int = -1
# True during the first part of dawn: night has ended but plant growth and the
# dawn harvest have not finished starting. Set when night turns off, cleared once
# the new day finishes growing / any real phase starts.
var _sun_rising: bool = false
# Day number whose rose step has already been answered, i.e. the day the player planted
# their first rose. Day 2 onward the rose step latches off for the rest of that day, so it
# plays once instead of nagging while seeds remain. -1 means no rose planted yet this run.
var _rose_step_done_day: int = -1


func _ready() -> void:
	bbcode_enabled = true
	fit_content = true
	scroll_active = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_font_size_override("normal_font_size", 26)
	_text_animator.setup(self)
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
		if _plant_manager != null and _plant_manager.has_signal("plant_added") \
				and not _plant_manager.is_connected("plant_added", Callable(self, "_on_plant_added")):
			_plant_manager.connect("plant_added", Callable(self, "_on_plant_added"))
		_building_manager = scene.get_node_or_null("Map/BuildingManager")
		_building_object_manager = scene.get_node_or_null("Map/BuildingObjectManager")
		if _building_object_manager != null:
			if _building_object_manager.has_method("count_buildings_by_item_id") \
					and int(_building_object_manager.call("count_buildings_by_item_id", TURRET_EPINE_ITEM_ID)) > 0:
				_has_planted_turret_epine = true
			if _building_object_manager.has_signal("building_added") \
					and not _building_object_manager.is_connected("building_added", Callable(self, "_on_building_added")):
				_building_object_manager.connect("building_added", Callable(self, "_on_building_added"))
			if _building_object_manager.has_signal("building_removed") \
					and not _building_object_manager.is_connected("building_removed", Callable(self, "_on_building_removed")):
				_building_object_manager.connect("building_removed", Callable(self, "_on_building_removed"))
		_player_controller = scene.get_node_or_null("Player/PlayerController")
		_progression = scene.get_node_or_null("progression")
		_game_ui = scene.get_node_or_null("GameUI")
		_toolbuild = scene.get_node_or_null("GameUI/Toolbuild") as Control
		_planificator = scene.get_node_or_null("GameUI/planificator") as Control
		_hold_progress_circle = scene.get_node_or_null("GameUI/holdProgressCircle") as Control
		if not GameState.afternoon_phase_changed.is_connected(_on_afternoon_phase_changed):
			GameState.afternoon_phase_changed.connect(_on_afternoon_phase_changed)
		if not GameState.seed_merchant_phase_changed.is_connected(_on_seed_merchant_phase_changed):
			GameState.seed_merchant_phase_changed.connect(_on_seed_merchant_phase_changed)


func _process(delta: float) -> void:
	_refresh(delta)
	_text_animator.update(delta)


## Single entry point for every message the label shows. The animator ignores a request for
## the message already on screen, so the paths below can keep asking for theirs every frame
## without ever restarting the animation. `message_id` is the logical identity of the
## message: two different steps that happen to share text still animate as a change.
func _present_tutorial_message(message_id: String, message_text: String) -> void:
	_text_animator.show_message(message_id, message_text)


## Blanks the label and cancels any running animation, so the message animates again if it
## comes back later.
func _clear_tutorial_message() -> void:
	_text_animator.clear_message()


func _tutorial_message_id(key: String) -> String:
	return "tutorial:%s" % key


func _alert_message_id() -> String:
	return "alert:%s:%d" % [_alert_key, _alert_count]


func _hold_message_id(key: String) -> String:
	return "hold:%s" % key


## While the message is fresh the rainbow owns the colour: modulating the label red would
## tint every glyph the same. The alert colour resumes once the fresh window ends.
func _apply_alert_modulate() -> void:
	modulate = Color.WHITE if _text_animator.is_fresh() else _current_alert_color()


func _on_mode_changed(is_night: bool) -> void:
	if GameState.is_emitting_restored_phase_signals():
		return
	# Night just ended: we are in the sunrise transition until the new day finishes.
	_sun_rising = not is_night
	_refresh()


## The new day has finished growing; the dawn harvest is about to begin, so the
## sunrise transition is over.
func _on_new_day_finished() -> void:
	_sun_rising = false
	_refresh()


func _on_afternoon_phase_changed(_is_afternoon_phase: bool) -> void:
	_refresh()


func _on_seed_merchant_phase_changed(_is_seed_merchant_phase: bool) -> void:
	_refresh()


## The player planted a plant. A rose answers the day's rose step, which from day 2 on
## latches it off until tomorrow. Save restore rebuilds the plant layer through its own
## path and never emits this, so loading a garden does not answer the step.
func _on_plant_added(cell: Vector2i) -> void:
	if _plant_manager == null or not _plant_manager.has_method("is_rose_cell"):
		return
	if not bool(_plant_manager.call("is_rose_cell", cell)):
		return
	_rose_step_done_day = _current_day_number()
	_refresh()


func _on_building_added(_cell: Vector2i, item_id: String) -> void:
	if item_id == TURRET_EPINE_ITEM_ID:
		_has_planted_turret_epine = true
		_refresh()
	elif item_id == COUNTER_ITEM_ID:
		_refresh()


## Counters are counted live off the building system, so removal keeps no state here: the
## signal only invalidates the hint, which then re-reads the current count.
func _on_building_removed(_cell: Vector2i, item_id: String) -> void:
	if item_id == COUNTER_ITEM_ID:
		_refresh()


func _on_locale_changed(_locale: String) -> void:
	# Same message, new language: re-translate in place without re-blanking.
	if _unbuild_tool_selected():
		_show_key_immediately(KEY_UNBUILD_SELECTION)
		return
	if _alert_key != "":
		_present_tutorial_message(_alert_message_id(), _alert_text())
		return
	if _displayed_key != "":
		_present_tutorial_message(_tutorial_message_id(_displayed_key), Translations.t(_displayed_key))


## Transient alert for a repeating event: ignored while any alert is already showing.
## The event therefore pops the message once, lets it live out its full duration, and can
## pop it again afterwards. It also never steals the label from a more urgent alert, in
## particular the persistent tantrum one that runs during the same client sale phase.
func show_alert_once(key: String) -> void:
	if _alert_key != "":
		return
	show_alert(key)


func show_alert(key: String, count: int = -1, persistent: bool = false) -> void:
	if key == "":
		return
	_alert_key = key
	_alert_count = count
	_alert_persistent = persistent
	_alert_remaining = ALERT_DURATION if not persistent else 0.0
	if _unbuild_tool_selected():
		_show_key_immediately(KEY_UNBUILD_SELECTION)
		return
	visible = true
	_present_tutorial_message(_alert_message_id(), _alert_text())
	if not persistent:
		# A transient alert must outlive its own reveal: it stays up for at least as long as
		# typing plus the fresh window, so it is never cut off mid-animation.
		_alert_remaining = maxf(ALERT_DURATION, _text_animator.get_minimum_visible_duration())
	_apply_alert_modulate()
	_update_tutorial_arrow("")


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


func _update_alert_timer(delta: float) -> void:
	if _alert_key == "" or _alert_persistent:
		return
	if delta <= 0.0:
		return
	_alert_remaining -= delta
	if _alert_remaining <= 0.0:
		_clear_elapsed_alert()


func _clear_elapsed_alert() -> void:
	_alert_key = ""
	_alert_count = -1
	_alert_remaining = 0.0
	_alert_persistent = false
	modulate = Color.WHITE


func _current_alert_color() -> Color:
	if _alert_key == KEY_BUILDER_IS_HERE:
		return Color.WHITE
	if _alert_persistent:
		return ALERT_DARK_RED.lerp(ALERT_LIGHT_RED, 0.5)
	var elapsed: float = ALERT_DURATION - _alert_remaining
	var pulse: float = (sin(elapsed * ALERT_FLASH_SPEED) + 1.0) * 0.5
	return ALERT_DARK_RED.lerp(ALERT_LIGHT_RED, pulse)


func _refresh(delta: float = 0.0) -> void:
	if _plant_manager == null or _progression == null or _game_ui == null:
		_resolve_nodes()
	_update_alert_timer(delta)
	# Cleared before the walk; every branch that offers a phase advance marks it again below.
	# A branch that returns without marking is one where the confirm input does nothing (or is
	# bound to something that is not a phase), which is exactly what NONE means.
	_available_phase_action = HOLD_ACTION_NONE
	# The intro prompt binds the hold input to letting the Builder in, so it is the one
	# onboarding step that owns the input. Every other onboarding step below is a hint only:
	# the afternoon-end hold keeps running under it.
	if _fundamental_builder_intro_prompt_active():
		_show_hold_action(HOLD_ACTION_ALLOW_BUILDER, delta)
		return
	if not _is_spawner_reveal_cutscene_active() and not _is_dialog_open() and _fundamental_builder_dialog_pending():
		_update_background_night_hold(delta)
		_show_key_immediately(KEY_TALK_BUILDER)
		return
	# At night the onboarding build steps are not the player's current step, so they must not
	# take the hint over. This matters now that the hold can end the day mid-onboarding.
	var forced_builder_key: String = "" if GameState.is_night else _forced_builder_onboarding_key()
	if forced_builder_key != "":
		_update_background_night_hold(delta)
		_show_key_immediately(forced_builder_key)
		return
	if _normal_tutorials_suppressed_by_builder_onboarding():
		_update_background_night_hold(delta)
		_clear_hint()
		return
	if _alert_key != "":
		_update_background_night_hold(delta)
		if _alert_persistent:
			visible = true
			_present_tutorial_message(_alert_message_id(), _alert_text())
			_apply_alert_modulate()
			_update_tutorial_arrow("")
			return
		if _alert_remaining > 0.0:
			visible = true
			_present_tutorial_message(_alert_message_id(), _alert_text())
			_apply_alert_modulate()
			_update_tutorial_arrow("")
			return
		_clear_elapsed_alert()
	# While a spawner-reveal cutscene is scrolling the camera the player has no control,
	# so the contextual hint is hidden. The cutscene shows its own focus alert (handled by
	# the alert branch above), which is why this check sits after it.
	if _is_spawner_reveal_cutscene_active():
		_reset_hold_progress()
		_clear_hint()
		return
	if _is_dialog_open():
		_reset_hold_progress()
		_clear_hint()
		return
	var hold_action: StringName = _current_hold_action()
	if hold_action != HOLD_ACTION_NONE:
		_show_hold_action(hold_action, delta)
		return
	if _unbuild_tool_selected():
		_update_background_night_hold(delta)
		_show_key_immediately(KEY_UNBUILD_SELECTION)
		return
	if _water_refill_needed():
		_update_background_night_hold(delta)
		_show_key_immediately(KEY_REFILL_WATER)
		return
	var start_night_skip_hold_active: bool = _start_night_pre_prompt_hold_active()
	# The dawn harvest can be skipped straight to the client sale by holding space once
	# the roses are grown up. The hold runs in the background so the harvest hint stays on
	# screen; the progress circle only appears while the key is actually held.
	if _dawn_client_skip_available():
		_available_phase_action = HOLD_ACTION_START_CLIENTS
		_advance_hold(HOLD_ACTION_START_CLIENTS, delta)
	elif not start_night_skip_hold_active:
		_reset_hold_progress()
	var key: String = _current_message_key()
	if key == KEY_PASS_NIGHT and not GameState.is_night:
		_request_start_night_prompt()
		if _start_night_prompt_suppressed():
			# Past the onboarding nights only the message stops. This is _show_hold_action minus
			# the label, deliberately: routing through the weaker background hold instead would
			# also drop the hold's own conditions, and space must keep ending the day on exactly
			# the days it does today.
			_available_phase_action = HOLD_ACTION_START_NIGHT
			_advance_hold(HOLD_ACTION_START_NIGHT, delta)
			_clear_hint()
			return
		_show_hold_action(HOLD_ACTION_START_NIGHT, delta)
		return
	# Reached when a contextual hint owns the label while the night is already available; mark
	# it whether or not the key is down, then let the background hold track the press.
	if _should_request_start_night_prompt():
		_available_phase_action = HOLD_ACTION_START_NIGHT
	if start_night_skip_hold_active:
		_advance_hold(HOLD_ACTION_START_NIGHT, delta)
	if key == "":
		_displayed_key = ""
		_clear_tutorial_message()
		visible = false
		modulate = Color.WHITE
		_update_tutorial_arrow("")
		return
	if GameState.is_night and key != KEY_REFILL_WATER:
		visible = false
		modulate = Color.WHITE
		_update_tutorial_arrow("")
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
		_present_tutorial_message(_tutorial_message_id(key), Translations.t(key))
	else:
		# A change is needed: blank the label and (re)start the delay toward the
		# newest target. The message only appears once it has held for CHANGE_DELAY.
		if key != _pending_key:
			_pending_key = key
			_pending_remaining = CHANGE_DELAY
			_displayed_key = ""
			_clear_tutorial_message()
		else:
			_pending_remaining -= delta
			if _pending_remaining <= 0.0:
				_displayed_key = key
				_present_tutorial_message(_tutorial_message_id(key), Translations.t(key))

	_update_tutorial_arrow(_displayed_key)


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
	if _fundamental_builder_dialog_pending():
		return KEY_TALK_BUILDER
	if _builder_house_tutorial_active():
		return KEY_BUILD_BUILDER_HOUSE
	if _waiting_for_onboarding_house_completion():
		return KEY_WAIT_BUILDER_BUILD
	if _merchant_house_tutorial_active():
		return KEY_BUILD_MERCHANT_HOUSE
	# Sunrise transition after a night: dawn growth has not finished, so falling through
	# would wrongly show "pass the night". Stay blank until the dawn harvest starts.
	if _sun_rising and not GameState.is_night:
		return ""
	# Stock step: bamboo is gathered in the field, so it precedes every step that spends it.
	if _should_prompt_collect_bamboo():
		return KEY_COLLECT_BAMBOO
	if GameState.is_dawn_phase:
		if _building_manager != null and _building_manager.has_method("has_grownup_roses_to_harvest") and bool(_building_manager.call("has_grownup_roses_to_harvest")):
			if _has_counter_room_for_harvest():
				return KEY_HARVEST_ROSE
			# No room to harvest into. Which step that means depends on how many counters
			# exist right now, never on whether one existed earlier in the run.
			var counter_count: int = _rose_shop_counter_count()
			if counter_count == 0:
				return KEY_PLACE_SHOP
			if counter_count > 0:
				return KEY_ADD_COUNTERS_TO_SELL_ROSES
			return ""
		if _client_sale_requested_without_roses():
			return KEY_NO_ROSES_NO_CLIENTS
		if not _client_sale_start_requested() and _should_prompt_place_shop():
			return KEY_PLACE_SHOP
		return ""
	# Client sale in progress: only the water-empty hint (handled above) and the
	# persistent tantrum alert may show, so suppress every economy hint here.
	if GameState.is_client_phase:
		return ""
	if not GameState.is_afternoon_phase:
		return ""
	if _client_sale_requested_without_roses():
		return KEY_NO_ROSES_NO_CLIENTS
	# Seeds buy (and directly place) roses; that outranks watering.
	if seeds > 0:
		var rose_key: String = _rose_step_key()
		if rose_key != "":
			return rose_key
	# Some planted roses are still dry.
	if unwatered > 0:
		return KEY_WATER_ROSES
	# Day-1 build steps: once the day is ready to end, walk the player through blocking the
	# passage, planting a watermelon for irrigation, then a spitter for defence.
	if _can_start_night_after_clients() and _has_day_one_build_prompt_remaining():
		if _should_prompt_build_wall():
			return KEY_BLOCK_PASSAGE_WALL
		if _build_affordable_quantity(PASTEQUE_ITEM_ID) > 0:
			return KEY_PLANT_PASTEQUE
		if _should_prompt_plant_turret_epine():
			return KEY_PLANT_TURRET_EPINE
	# Day-1 guard: don't offer to end the day until enough roses are planted to satisfy the
	# clients the planificator previews for tomorrow.
	if _should_warn_plant_more_roses():
		return KEY_PLANT_MORE_ROSES
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


func _water_refill_needed() -> bool:
	if _progression == null or not _progression.has_method("get_value"):
		return false
	return int(_progression.call("get_value", WATER_RESERVE_KEY)) <= 0


func _unbuild_tool_selected() -> bool:
	return (
		_game_ui != null
		and _game_ui.has_method("is_unbuild_tool_selected")
		and bool(_game_ui.call("is_unbuild_tool_selected"))
	)


func _show_key_immediately(key: String) -> void:
	_displayed_key = key
	_pending_key = key
	_pending_remaining = 0.0
	_present_tutorial_message(_tutorial_message_id(key), Translations.t(key))
	visible = true
	modulate = Color.WHITE
	_update_tutorial_arrow(key)


func _should_request_start_night_prompt() -> bool:
	if not GameState.is_afternoon_phase or GameState.is_seed_merchant_phase:
		return false
	# During the sunrise transition the new day has not begun yet: no phase flag is set
	# and the roses are still wet from overnight (they only dry when the build phase
	# starts). Without this guard the just-ended night would immediately request the
	# start-night prompt. That request may only happen once the real day is under way.
	if _sun_rising:
		return false
	# Player input is locked while a reveal cutscene plays, so a key held under it must not
	# end the day. This one matters in the afternoon: that is when the fundamental Builder's
	# arrival cutscene runs, and it is the phase the start-night hold belongs to.
	if _is_spawner_reveal_cutscene_active():
		return false
	return _can_start_night_after_clients()


## True while any reveal cutscene is playing (camera scrolling around the map with player
## input locked): the night monsters, the clients, or the fundamental Builder's arrival.
func _is_spawner_reveal_cutscene_active() -> bool:
	return (
		_building_manager != null
		and _building_manager.has_method("is_any_reveal_cutscene_active")
		and bool(_building_manager.call("is_any_reveal_cutscene_active"))
	)


func _is_dialog_open() -> bool:
	for node: Node in get_tree().get_nodes_in_group(&"dialog_ui"):
		if node != null and node.has_method("is_open") and bool(node.call("is_open")):
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


## Asks the phase owner to open the night-after-clients window. Called every frame while the
## start-night prompt is the current step, so it must not touch the label: the caller shows the
## hold prompt right after, and blanking the message here would restart its reveal each frame.
func _request_start_night_prompt() -> void:
	if _building_manager != null and _building_manager.has_method("request_night_after_clients"):
		_building_manager.call("request_night_after_clients")


func _current_hold_action() -> StringName:
	if _building_manager == null:
		return HOLD_ACTION_NONE
	if _building_manager.has_method("is_client_sale_start_requested") and bool(_building_manager.call("is_client_sale_start_requested")):
		return HOLD_ACTION_START_CLIENTS
	return HOLD_ACTION_NONE


func _start_night_pre_prompt_hold_active() -> bool:
	return _should_request_start_night_prompt() and _hold_input_pressed()


## Runs the afternoon-end hold underneath a hint that owns the label. Every contextual hint
## is advisory: once the phase owner says night may start, holding the input must end the day
## even though the "hold to start night" prompt is not the current message. Clears the hold
## when night is not available, so a key held for something else never accumulates progress.
func _update_background_night_hold(delta: float) -> void:
	# Availability is about what the input is bound to, not whether it is down: mark it from the
	# prompt condition alone, so the phase-toggle button turns green before the player holds.
	if _should_request_start_night_prompt():
		_available_phase_action = HOLD_ACTION_START_NIGHT
	if _start_night_pre_prompt_hold_active():
		_advance_hold(HOLD_ACTION_START_NIGHT, delta)
	else:
		_reset_hold_progress()


## Shows the hold prompt as the on-screen hint and advances its progress. Used when the
## phase change is the natural next step, so the label itself is the "hold to..." prompt.
func _show_hold_action(action: StringName, delta: float) -> void:
	if PHASE_HOLD_ACTIONS.has(action):
		_available_phase_action = action
	_displayed_key = ""
	_pending_key = ""
	_pending_remaining = 0.0
	visible = true
	modulate = Color.WHITE
	var hold_key: String = _hold_translation_key(action)
	_present_tutorial_message(_hold_message_id(hold_key), Translations.t(hold_key))
	_update_tutorial_arrow("")
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


## True while the dawn harvest is running and at least one rose has
## grown up: the player may start the client sale early, before harvesting.
func _dawn_client_skip_available() -> bool:
	if not GameState.is_dawn_phase:
		return false
	if _building_manager == null or not _building_manager.has_method("grownup_rose_count"):
		return false
	return int(_building_manager.call("grownup_rose_count")) > 0


func _client_sale_start_requested() -> bool:
	return (
		_building_manager != null
		and _building_manager.has_method("is_client_sale_start_requested")
		and bool(_building_manager.call("is_client_sale_start_requested"))
	)


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


## The phase advance the confirm input (space / pad X) would perform right now, or
## HOLD_ACTION_NONE. Read by the phase-toggle button, which mirrors it as a green/gray frame
## rather than deciding availability for itself.
func available_phase_action() -> StringName:
	return _available_phase_action


## Perform the phase advance the confirm input is currently bound to; no-op when there is none.
## This is the phase-toggle button's click path: it takes the same route as a completed hold,
## so the button can never do something the spacebar would not.
func trigger_phase_action() -> void:
	if _available_phase_action == HOLD_ACTION_NONE:
		return
	_trigger_hold_action(_available_phase_action)
	_reset_hold_progress()
	_available_phase_action = HOLD_ACTION_NONE


func _trigger_hold_action(action: StringName) -> void:
	if _building_manager == null:
		return
	if action == HOLD_ACTION_START_CLIENTS and _building_manager.has_method("begin_client_sale_phase"):
		_building_manager.call("begin_client_sale_phase")
	elif action == HOLD_ACTION_START_NIGHT and _building_manager.has_method("try_start_night_after_clients"):
		_building_manager.call("try_start_night_after_clients")
	elif action == HOLD_ACTION_ALLOW_BUILDER and _building_manager.has_method("request_fundamental_builder_intro_cutscene"):
		_building_manager.call("request_fundamental_builder_intro_cutscene")


func _hold_translation_key(action: StringName) -> String:
	var pad_mode: bool = _is_pad_mode()
	if action == HOLD_ACTION_ALLOW_BUILDER:
		return KEY_ALLOW_BUILDER_PAD if pad_mode else KEY_ALLOW_BUILDER_SPACE
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


func _has_counter_room_for_harvest() -> bool:
	if _building_manager != null and _building_manager.has_method("has_counter_room_for_harvest"):
		return bool(_building_manager.call("has_counter_room_for_harvest"))
	return false


func _current_day_number() -> int:
	if _progression == null or not _progression.has_method("get_value"):
		return -1
	return int(_progression.call("get_value", &"nDays"))


func _is_day_one() -> bool:
	return _current_day_number() == 1


func _is_day_two() -> bool:
	return _current_day_number() == 2


## The afternoon rose step, or "" when it has nothing left to say.
##
## Day 1 walks the player through the two substeps and keeps nagging while seeds remain:
## equip the gardening tool, then plant. From day 2 on they know the tool, so both collapse
## into a single "plant roses" hint shown whatever is equipped, and it plays only once:
## planting the first rose of the day latches it off, letting the next step through even
## though seeds are left.
func _rose_step_key() -> String:
	if _is_day_one():
		return KEY_PLANT_ROSES if _gardening_equipped() else KEY_BUY_ROSES
	if _rose_step_done_day >= 0 and _rose_step_done_day == _current_day_number():
		return ""
	return KEY_PLANT_ROSES


func _build_affordable_quantity(item_id: String) -> int:
	if _game_ui == null or not _game_ui.has_method("get_build_affordable_quantity"):
		return 0
	return int(_game_ui.call("get_build_affordable_quantity", item_id))


## Rose shop counters that exist in the world right now, or COUNTER_COUNT_UNKNOWN while the
## building manager is not resolved yet. Counters are never tracked here: the building system
## owns that state, and a counter the player removes must lower this count again.
func _rose_shop_counter_count() -> int:
	if _building_manager == null or not _building_manager.has_method("rose_shop_counter_count"):
		return COUNTER_COUNT_UNKNOWN
	return int(_building_manager.call("rose_shop_counter_count"))


## Day-2 only: the player owns less than REQUIRED_BAMBOO. Bamboo is harvested from the field,
## so the step points the world arrow at the authored bamboo grove. Within day 2 it is not a
## one-time step: spending back below the threshold asks for more bamboo again.
func _should_prompt_collect_bamboo() -> bool:
	if not _is_day_two():
		return false
	if _progression == null or not _progression.has_method("get_value"):
		return false
	return int(_progression.call("get_value", BAMBOO_KEY)) < REQUIRED_BAMBOO


## Dawn step: the player has no counter at all, so building the first one is the current
## requirement. Not a one-time step — removing the last counter brings it back. It belongs to
## dawn only, before the client sale: the afternoon build phase must not raise it. An unknown
## count suppresses the step rather than guessing either way.
func _should_prompt_place_shop() -> bool:
	return _rose_shop_counter_count() == 0


## Day-1 only: any of the guided build steps (wall / watermelon / spitter) is still pending.
func _has_day_one_build_prompt_remaining() -> bool:
	return (
		_is_day_one()
		and (
			_should_prompt_build_wall()
			or _build_affordable_quantity(PASTEQUE_ITEM_ID) > 0
			or _should_prompt_plant_turret_epine()
		)
	)


func _should_prompt_plant_turret_epine() -> bool:
	return not _has_planted_turret_epine and _build_affordable_quantity(TURRET_EPINE_ITEM_ID) > 0


## Day-1 wall step: prompt until the player places their first wall. Walls are tilemap
## tiles (not building-object nodes), so we track placement through the inventory stock
## instead: the step shows while the wall stock is still at its starting baseline and
## is skipped the moment one wall has been spent. Precedes the watermelon/spitter prompts.
func _should_prompt_build_wall() -> bool:
	var stock: int = _wall_stock()
	# Capture the baseline only once real stock exists, so a premature 0 (inventory not yet
	# granted / game_ui not resolved) never latches the step off before the player can build.
	if _wall_stock_baseline < 0 and stock > 0:
		_wall_stock_baseline = stock
	return _wall_stock_baseline > 0 and stock >= _wall_stock_baseline


func _wall_stock() -> int:
	if _game_ui != null and _game_ui.has_method("get_inventory_item_quantity"):
		return int(_game_ui.call("get_inventory_item_quantity", WALL_ITEM_ID))
	return 0


## Day-1 only: the player is ready to end the day but has not planted enough roses to
## satisfy the clients the planificator previews for tomorrow. When true the start-night
## prompt is withheld in favour of the "plant more roses" nudge.
func _should_warn_plant_more_roses() -> bool:
	if not _is_day_one():
		return false
	if not _should_request_start_night_prompt():
		return false
	return _planted_rose_count() < _next_day_client_demand()


func _builder_house_tutorial_active() -> bool:
	return _building_manager != null \
		and _building_manager.has_method("is_builder_house_tutorial_active") \
		and bool(_building_manager.call("is_builder_house_tutorial_active"))


func _fundamental_builder_intro_prompt_active() -> bool:
	return _building_manager != null \
		and _building_manager.has_method("is_fundamental_builder_intro_prompt_active") \
		and bool(_building_manager.call("is_fundamental_builder_intro_prompt_active"))


func _fundamental_builder_dialog_pending() -> bool:
	if GameState.is_night:
		return false
	if _building_manager == null:
		return false
	if _building_manager.has_method("is_any_reveal_cutscene_active") and bool(_building_manager.call("is_any_reveal_cutscene_active")):
		return false
	if not _building_manager.has_method("is_fundamental_builder_dialog_pending") \
			or not bool(_building_manager.call("is_fundamental_builder_dialog_pending")):
		return false
	if _building_manager.has_method("is_fundamental_builder_active") \
			and not bool(_building_manager.call("is_fundamental_builder_active")):
		return false
	return true


func _normal_tutorials_suppressed_by_builder_onboarding() -> bool:
	return _building_manager != null \
		and _building_manager.has_method("should_suppress_normal_tutorials_for_builder_onboarding") \
		and bool(_building_manager.call("should_suppress_normal_tutorials_for_builder_onboarding"))


func _forced_builder_onboarding_key() -> String:
	if _builder_house_tutorial_active():
		return KEY_BUILD_BUILDER_HOUSE
	if _waiting_for_onboarding_house_completion():
		return KEY_WAIT_BUILDER_BUILD
	if _merchant_house_tutorial_active():
		return KEY_BUILD_MERCHANT_HOUSE
	return ""


func _waiting_for_onboarding_house_completion() -> bool:
	return _building_manager != null \
		and _building_manager.has_method("is_waiting_for_onboarding_house_completion") \
		and bool(_building_manager.call("is_waiting_for_onboarding_house_completion"))


func _merchant_house_tutorial_active() -> bool:
	return _building_manager != null \
		and _building_manager.has_method("is_merchant_house_tutorial_active") \
		and bool(_building_manager.call("is_merchant_house_tutorial_active"))


func _planted_rose_count() -> int:
	if _plant_manager == null or not _plant_manager.has_method("rose_count"):
		return 0
	return int(_plant_manager.call("rose_count"))


func _next_day_client_demand() -> int:
	if _planificator == null or not _planificator.has_method("previewed_client_count"):
		return 0
	return int(_planificator.call("previewed_client_count"))


func _tutorial_item_for_key(key: String) -> String:
	match key:
		KEY_BUY_ROSES, KEY_PLANT_ROSES:
			return ROSE_ITEM_ID
		KEY_PLANT_PASTEQUE:
			return PASTEQUE_ITEM_ID
		KEY_PLANT_TURRET_EPINE:
			return TURRET_EPINE_ITEM_ID
	return ""


func _update_tutorial_arrow(key: String) -> void:
	# The HUD arrow (below) and the world arrow are driven together: whichever contextual
	# message is showing decides both. Most steps have no world target, so this clears.
	_update_tutorial_world_arrow(key)
	_ensure_tutorial_arrow()
	if _tutorial_arrow == null:
		return
	if key == KEY_PLANT_MORE_ROSES:
		var planner_rect: Rect2 = _planificator_rect()
		if planner_rect.size != Vector2.ZERO:
			_tutorial_arrow.point_right_at(planner_rect, get_process_delta_time())
			return
		_hide_tutorial_arrow()
		return
	if key == KEY_WATER_ROSES:
		# "Arrosez vos roses" shows no arrow: the water tool is the only equipped
		# option at that point, so the hint text alone is enough.
		_hide_tutorial_arrow()
		return
	if key == KEY_BLOCK_PASSAGE_WALL:
		_point_to_hammer_build_item(WALL_ITEM_ID)
		return
	if key == KEY_PLACE_SHOP and _is_day_two():
		_point_to_hammer_build_item(COUNTER_ITEM_ID)
		return
	if key == KEY_BUILD_BUILDER_HOUSE:
		_point_to_house_build_item(HOUSE_BUILDER_ITEM_ID)
		return
	if key == KEY_BUILD_MERCHANT_HOUSE:
		_point_to_house_build_item(HOUSE_MERCHANT_ITEM_ID)
		return
	var item_id: String = _tutorial_item_for_key(key)
	if item_id == "":
		_hide_tutorial_arrow()
		return
	if _is_gardening_menu_open():
		var item_rect: Rect2 = _visible_build_item_rect(item_id)
		if item_rect.size != Vector2.ZERO:
			_tutorial_arrow.point_right_at(item_rect, get_process_delta_time())
			return
	elif not _gardening_equipped():
		var tool_rect: Rect2 = _gardening_tool_rect()
		if tool_rect.size != Vector2.ZERO:
			_tutorial_arrow.point_down_at(tool_rect, get_process_delta_time())
			return
	_hide_tutorial_arrow()


## Points at a buildable reached through the hammer: the item inside the open hammer menu, or
## the hammer quick slot to open it. Shows nothing once the item is armed for placement — the
## player is already holding it, and pointing back at the hammer slot would send them backwards.
func _point_to_hammer_build_item(item_id: String) -> void:
	if _tutorial_arrow == null:
		return
	if _is_hammer_menu_open():
		var item_rect: Rect2 = _visible_build_item_rect(item_id)
		if item_rect.size != Vector2.ZERO:
			_tutorial_arrow.point_right_at(item_rect, get_process_delta_time())
			return
	elif not _is_build_item_equipped(item_id):
		var hammer_rect: Rect2 = _quick_slot_rect(HAMMER_TOOL_ID)
		if hammer_rect.size != Vector2.ZERO:
			_tutorial_arrow.point_down_at(hammer_rect, get_process_delta_time())
			return
	_hide_tutorial_arrow()


func _point_to_house_build_item(item_id: String) -> void:
	if _tutorial_arrow == null:
		return
	if _is_build_house_menu_open():
		var house_rect: Rect2 = _visible_build_item_rect(item_id)
		if house_rect.size != Vector2.ZERO:
			_tutorial_arrow.point_right_at(house_rect, get_process_delta_time())
			return
	elif not _is_build_item_equipped(item_id):
		var buildhouse_rect: Rect2 = _quick_slot_rect(BUILD_HOUSE_TOOL_ID)
		if buildhouse_rect.size != Vector2.ZERO:
			_tutorial_arrow.point_down_at(buildhouse_rect, get_process_delta_time())
			return
	_hide_tutorial_arrow()


func _ensure_tutorial_arrow() -> void:
	if _tutorial_arrow != null and is_instance_valid(_tutorial_arrow):
		return
	if _game_ui == null:
		return
	_tutorial_arrow = TutorialArrowScript.new() as TutorialArrow
	_tutorial_arrow.name = "TutorialArrow"
	_game_ui.call_deferred("add_child", _tutorial_arrow)


## Points the world arrow at the tile a step designates (e.g. build the watermelon on tuto1),
## or clears it when the current step has no world target. Complements the HUD arrow, which
## points at the tool/build item to select.
func _update_tutorial_world_arrow(key: String) -> void:
	_ensure_tutorial_world_arrow()
	if _tutorial_world_arrow == null:
		return
	var target_name: String = _world_arrow_target_for_key(key)
	if target_name == "":
		_tutorial_world_arrow.clear()
		return
	var marker: Node2D = _tuto_marker_node(target_name)
	if marker == null:
		_tutorial_world_arrow.clear()
		return
	_tutorial_world_arrow.point_at_node(marker)


## Maps a contextual message key to the name of the world marker node it should point at.
## Empty string means the step has no world target.
func _world_arrow_target_for_key(key: String) -> String:
	if key == KEY_BLOCK_PASSAGE_WALL:
		return "tuto2"
	if key == KEY_PLANT_PASTEQUE:
		return "tuto1"
	if key == KEY_PLANT_TURRET_EPINE:
		return "tuto3"
	if key == KEY_COLLECT_BAMBOO:
		return "tuto4_bamboo"
	return ""


func _tuto_marker_node(node_name: String) -> Node2D:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return null
	return scene.get_node_or_null("Map/MonTilemap/spawners/%s" % node_name) as Node2D


func _ensure_tutorial_world_arrow() -> void:
	if _tutorial_world_arrow != null and is_instance_valid(_tutorial_world_arrow):
		return
	var scene: Node = get_tree().current_scene
	if scene == null:
		return
	_tutorial_world_arrow = TutorialWorldArrowScript.new() as TutorialWorldArrow
	_tutorial_world_arrow.name = "TutorialWorldArrow"
	scene.call_deferred("add_child", _tutorial_world_arrow)


func _is_gardening_menu_open() -> bool:
	return (
		_game_ui != null
		and _game_ui.has_method("get_selected_build_tool_id")
		and str(_game_ui.call("get_selected_build_tool_id")) == GARDENING_TOOL_ID
	)


func _is_hammer_menu_open() -> bool:
	return (
		_game_ui != null
		and _game_ui.has_method("get_selected_build_tool_id")
		and str(_game_ui.call("get_selected_build_tool_id")) == HAMMER_TOOL_ID
	)


## True while this exact buildable is armed for placement (build preview in hand). The steps that
## point at a quick slot use it to stand down once the player has the item out.
func _is_build_item_equipped(item_id: String) -> bool:
	return (
		_game_ui != null
		and _game_ui.has_method("get_selected_build_item_id")
		and str(_game_ui.call("get_selected_build_item_id")) == item_id
	)


func _is_build_house_menu_open() -> bool:
	return _game_ui != null \
		and _game_ui.has_method("get_selected_build_tool_id") \
		and str(_game_ui.call("get_selected_build_tool_id")) == BUILD_HOUSE_TOOL_ID


func _visible_build_item_rect(item_id: String) -> Rect2:
	if _toolbuild == null or not _toolbuild.has_method("get_visible_build_item_global_rect"):
		return Rect2()
	return _toolbuild.call("get_visible_build_item_global_rect", item_id) as Rect2


func _planificator_rect() -> Rect2:
	if _planificator == null or not _planificator.visible:
		return Rect2()
	return _planificator.get_global_rect()


func _gardening_tool_rect() -> Rect2:
	return _quick_slot_rect(GARDENING_TOOL_ID)


func _quick_slot_rect(slot_kind: String) -> Rect2:
	if _game_ui == null or not _game_ui.has_method("get_quick_slot_global_rect_for_kind"):
		return Rect2()
	return _game_ui.call("get_quick_slot_global_rect_for_kind", slot_kind) as Rect2


func _hide_tutorial_arrow() -> void:
	if _tutorial_arrow != null:
		_tutorial_arrow.hide_arrow()


## Blanks the hint entirely: no message, no arrow, label hidden. Does not touch the hold, so a
## caller that wants the background hold to keep running just calls it after that hold.
func _clear_hint() -> void:
	_displayed_key = ""
	_pending_key = ""
	_clear_tutorial_message()
	visible = false
	modulate = Color.WHITE
	_update_tutorial_arrow("")


## True once the "hold to start night" hint has served its onboarding purpose. Suppresses only
## the message; see START_NIGHT_PROMPT_LAST_DAY. An unknown day reads as -1 and so keeps the
## hint showing, which is the safe way round.
func _start_night_prompt_suppressed() -> bool:
	return _current_day_number() > START_NIGHT_PROMPT_LAST_DAY
