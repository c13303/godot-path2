extends Node
## Global game state singleton (autoloaded as "GameState").
## Holds shared game data such as the current day/night mode.

## Emitted whenever the day/night mode changes. `is_night` is the new value.
signal mode_changed(is_night: bool)
signal building_phase_changed(is_building_phase: bool)
signal morning_phase_changed(is_morning_phase: bool)
signal client_phase_changed(is_client_phase: bool)
signal seed_merchant_phase_changed(is_seed_merchant_phase: bool)

## True while night is active. The game starts in day mode.
var is_night: bool = false
var is_building_phase: bool = true
var is_morning_phase: bool = false
var is_client_phase: bool = false
var is_seed_merchant_phase: bool = false
var is_reservoir_destroyed: bool = false
## True once the player has bought at least one item during the current seed-merchant
## visit. Reset each time a new merchant phase begins; drives the "close the transaction"
## tutorial prompt once the player walks away from the (now hidden) merchant shop.
var seed_merchant_purchase_made: bool = false

## Night special-reward claim tracking. Per-reward keys are "night_index:reward_key".
## `_claimed_one_time_night_rewards` also accepts legacy integer night indices from older
## saves, which still hide the whole old reward bundle for that night.
var _claimed_one_time_night_rewards: Dictionary = {}
var _special_reward_claim_days: Dictionary = {}
var _special_reward_legacy_claim_day: int = -1

const SELECTED_LEVEL_META: StringName = &"selected_level_scene_path"
const STARTUP_SAVE_PATH_META: StringName = &"startup_save_path"
const SKIP_STARTUP_AUTOSAVE_META: StringName = &"skip_startup_autosave"
const FORCE_LEVEL_SELECTION_META: StringName = &"force_level_selection"


## Reset autoload-only gameplay flags before a fresh main scene is loaded.
## This is intentionally silent: callers use it while replacing/reloading scenes, so
## emitting mode_changed would let the outgoing scene advance a day or start phases.
func reset_transient_run_state() -> void:
	is_night = false
	is_building_phase = true
	is_morning_phase = false
	is_client_phase = false
	is_seed_merchant_phase = false
	is_reservoir_destroyed = false
	seed_merchant_purchase_made = false


## Restore phase flags for an already loaded day scene without emitting mode_changed.
## Save files only persist daytime phases; nights are reconstructed by normal play.
func restore_day_phase_flags(phase: String) -> void:
	is_night = false
	is_building_phase = false
	is_morning_phase = false
	is_client_phase = false
	is_seed_merchant_phase = false
	seed_merchant_purchase_made = false
	match phase:
		"morning":
			is_morning_phase = true
		"client":
			is_client_phase = true
		"seed_merchant":
			is_seed_merchant_phase = true
		_:
			is_building_phase = true
	building_phase_changed.emit(is_building_phase)
	morning_phase_changed.emit(is_morning_phase)
	client_phase_changed.emit(is_client_phase)
	seed_merchant_phase_changed.emit(is_seed_merchant_phase)


## Switch to night: monsters are allowed to spawn.
func start_night() -> void:
	set_morning_phase(false)
	set_client_phase(false)
	set_seed_merchant_phase(false)
	set_night(true)


## Switch to day: monster spawning is suppressed.
func start_day() -> void:
	set_night(false)


func set_reservoir_destroyed(value: bool) -> void:
	is_reservoir_destroyed = value


func set_building_phase(value: bool) -> void:
	if is_building_phase == value:
		return
	is_building_phase = value
	if value:
		set_morning_phase(false)
		set_client_phase(false)
		set_seed_merchant_phase(false)
	building_phase_changed.emit(is_building_phase)


func set_morning_phase(value: bool) -> void:
	if is_morning_phase == value:
		return
	is_morning_phase = value
	if value:
		set_client_phase(false)
		set_seed_merchant_phase(false)
		is_building_phase = false
		building_phase_changed.emit(is_building_phase)
	morning_phase_changed.emit(is_morning_phase)


func set_client_phase(value: bool) -> void:
	if is_client_phase == value:
		return
	is_client_phase = value
	if value:
		set_morning_phase(false)
		is_building_phase = false
		building_phase_changed.emit(is_building_phase)
	client_phase_changed.emit(is_client_phase)


func set_seed_merchant_phase(value: bool) -> void:
	if is_seed_merchant_phase == value:
		return
	is_seed_merchant_phase = value
	if value:
		seed_merchant_purchase_made = false
		set_morning_phase(false)
		is_building_phase = false
		building_phase_changed.emit(is_building_phase)
	seed_merchant_phase_changed.emit(is_seed_merchant_phase)


## Toggle between day and night.
func toggle() -> void:
	# Manual toggles cannot end the night while monsters remain on the map.
	# The building manager calls start_day() separately once the group is empty.
	if is_night and get_tree().get_first_node_in_group(&"monsters") != null:
		return
	set_night(not is_night)


func set_night(value: bool) -> void:
	if is_night == value:
		return
	is_night = value
	if is_night:
		set_building_phase(false)
		set_morning_phase(false)
		set_client_phase(false)
		set_seed_merchant_phase(false)
	mode_changed.emit(is_night)


func set_selected_level_scene_path(scene_path: String) -> void:
	set_meta(SELECTED_LEVEL_META, scene_path)


func clear_selected_level_scene_path() -> void:
	if has_meta(SELECTED_LEVEL_META):
		remove_meta(SELECTED_LEVEL_META)


func get_selected_level_scene_path() -> String:
	return str(get_meta(SELECTED_LEVEL_META, ""))


func request_startup_save_load(save_path: String) -> void:
	set_meta(STARTUP_SAVE_PATH_META, save_path)


func consume_startup_save_load_path(default_save_path: String) -> String:
	if has_meta(STARTUP_SAVE_PATH_META):
		var save_path: String = str(get_meta(STARTUP_SAVE_PATH_META, default_save_path))
		remove_meta(STARTUP_SAVE_PATH_META)
		return save_path
	return ""


func skip_startup_autosave_once() -> void:
	set_meta(SKIP_STARTUP_AUTOSAVE_META, true)
	# Every fresh start (reset, level select, game-over restart) routes through here,
	# so this is the single place that clears carried-over night-reward claims.
	reset_special_reward_claims()
	reset_transient_run_state()


func force_level_selection_once() -> void:
	set_meta(FORCE_LEVEL_SELECTION_META, true)


func consume_force_level_selection() -> bool:
	if not has_meta(FORCE_LEVEL_SELECTION_META):
		return false
	remove_meta(FORCE_LEVEL_SELECTION_META)
	return true


## True when the current night's special reward can still be collected: a one-time
## reward not yet claimed this run, and not already collected earlier today.
func is_special_reward_available(night_index: int, day_number: int, one_time: bool, reward_key: String = "") -> bool:
	if one_time and _claimed_one_time_night_rewards.has(night_index):
		return false
	if _special_reward_legacy_claim_day == day_number:
		return false
	if reward_key == "":
		return true
	var claim_key: String = _special_reward_claim_key(night_index, reward_key)
	if one_time and _claimed_one_time_night_rewards.has(claim_key):
		return false
	if int(_special_reward_claim_days.get(claim_key, -1)) == day_number:
		return false
	return true


## Record that the current night's special reward was collected on `day_number`.
func record_special_reward_claim(night_index: int, day_number: int, one_time: bool, reward_key: String = "") -> void:
	if reward_key == "":
		_special_reward_legacy_claim_day = day_number
		return
	var claim_key: String = _special_reward_claim_key(night_index, reward_key)
	_special_reward_claim_days[claim_key] = day_number
	if one_time:
		_claimed_one_time_night_rewards[claim_key] = true


func reset_special_reward_claims() -> void:
	_claimed_one_time_night_rewards.clear()
	_special_reward_claim_days.clear()
	_special_reward_legacy_claim_day = -1


## Serialize claim state for the save file.
func get_special_reward_claim_save_data() -> Dictionary:
	var claimed: Array = []
	for raw_index: Variant in _claimed_one_time_night_rewards.keys():
		claimed.append(raw_index)
	return {
		"claimed_one_time": claimed,
		"claim_day": _special_reward_legacy_claim_day,
		"claim_days": _special_reward_claim_days.duplicate(),
	}


## Restore claim state from a save file (missing/invalid data resets to empty).
func apply_special_reward_claim_save_data(data: Dictionary) -> void:
	reset_special_reward_claims()
	var raw_claimed: Variant = data.get("claimed_one_time", [])
	if raw_claimed is Array:
		for raw_index: Variant in raw_claimed as Array:
			_claimed_one_time_night_rewards[raw_index] = true
	var raw_claim_days: Variant = data.get("claim_days", {})
	if raw_claim_days is Dictionary:
		for raw_key: Variant in (raw_claim_days as Dictionary).keys():
			_special_reward_claim_days[str(raw_key)] = int((raw_claim_days as Dictionary)[raw_key])
	_special_reward_legacy_claim_day = int(data.get("claim_day", -1))


func _special_reward_claim_key(night_index: int, reward_key: String) -> String:
	return "%d:%s" % [night_index, reward_key]


func consume_skip_startup_autosave() -> bool:
	if not has_meta(SKIP_STARTUP_AUTOSAVE_META):
		return false
	remove_meta(SKIP_STARTUP_AUTOSAVE_META)
	return true
