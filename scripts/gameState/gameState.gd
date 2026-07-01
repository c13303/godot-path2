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
## True once the player has bought at least one item during the current seed-merchant
## visit. Reset each time a new merchant phase begins; drives the "close the transaction"
## tutorial prompt once the player walks away from the (now hidden) merchant shop.
var seed_merchant_purchase_made: bool = false

## Night special-reward claim tracking. Keyed by playlist night index.
## `_claimed_one_time_night_rewards` holds indices whose one-time-only reward has
## been permanently collected (never offered again this run). `_special_reward_claim_day`
## is the nDays value the current reward was collected on, so a repeatable reward stays
## hidden for the rest of that day but returns after the playlist loops. Both persist in
## the save file (see progression.gd) and reset on any fresh start.
var _claimed_one_time_night_rewards: Dictionary = {}
var _special_reward_claim_day: int = -1

const SELECTED_LEVEL_META: StringName = &"selected_level_scene_path"
const STARTUP_SAVE_PATH_META: StringName = &"startup_save_path"
const SKIP_STARTUP_AUTOSAVE_META: StringName = &"skip_startup_autosave"


## Switch to night: monsters are allowed to spawn.
func start_night() -> void:
	set_morning_phase(false)
	set_client_phase(false)
	set_seed_merchant_phase(false)
	set_night(true)


## Switch to day: monster spawning is suppressed.
func start_day() -> void:
	set_night(false)


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


## True when the current night's special reward can still be collected: a one-time
## reward not yet claimed this run, and not already collected earlier today.
func is_special_reward_available(night_index: int, day_number: int, one_time: bool) -> bool:
	if one_time and _claimed_one_time_night_rewards.has(night_index):
		return false
	if _special_reward_claim_day == day_number:
		return false
	return true


## Record that the current night's special reward was collected on `day_number`.
func record_special_reward_claim(night_index: int, day_number: int, one_time: bool) -> void:
	_special_reward_claim_day = day_number
	if one_time:
		_claimed_one_time_night_rewards[night_index] = true


func reset_special_reward_claims() -> void:
	_claimed_one_time_night_rewards.clear()
	_special_reward_claim_day = -1


## Serialize claim state for the save file.
func get_special_reward_claim_save_data() -> Dictionary:
	var claimed: Array[int] = []
	for raw_index: Variant in _claimed_one_time_night_rewards.keys():
		claimed.append(int(raw_index))
	return {"claimed_one_time": claimed, "claim_day": _special_reward_claim_day}


## Restore claim state from a save file (missing/invalid data resets to empty).
func apply_special_reward_claim_save_data(data: Dictionary) -> void:
	reset_special_reward_claims()
	var raw_claimed: Variant = data.get("claimed_one_time", [])
	if raw_claimed is Array:
		for raw_index: Variant in raw_claimed as Array:
			_claimed_one_time_night_rewards[int(raw_index)] = true
	_special_reward_claim_day = int(data.get("claim_day", -1))


func consume_skip_startup_autosave() -> bool:
	if not has_meta(SKIP_STARTUP_AUTOSAVE_META):
		return false
	remove_meta(SKIP_STARTUP_AUTOSAVE_META)
	return true
