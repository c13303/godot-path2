extends RefCounted
class_name RunCompletionController

# Owns run-length and victory decisioning, kept out of BuildingManager so the manager
# does not accumulate win-condition gameplay logic. Mirrors the other manager-owned
# controllers (ClientSaleController, SeedMerchantController, ...): holds a back-reference
# to BuildingManager and reads the spawn-playlist config + progression through it.
#
# Runs are finite: a level playlist has N authored nights, fought on days 1..N, then a
# trailing client-only day N+1 on which the run is won once the last client leaves with
# the reservoir still alive. Victory is latched on GameState.is_run_won, polled by the
# victory modal.

var _manager: BuildingManager


func setup(manager: BuildingManager) -> void:
	_manager = manager


# Total days in a full run: one day per authored night plus the trailing client-only
# day on which the run is won. Zero when the level has no authored playlist, which
# leaves the day label without a denominator and the run endless (legacy behaviour).
func total_run_days() -> int:
	var nights: int = _total_night_count()
	return nights + 1 if nights > 0 else 0


# True on the trailing client day, once every authored night has been survived
# (the day counter has advanced one past the authored night count).
func is_final_client_day() -> bool:
	var nights: int = _total_night_count()
	if nights <= 0:
		return false
	var prog: Node = _manager.get_progression()
	if prog == null:
		return false
	return int(prog.call("get_value", &"nDays")) > nights


# Called the instant a day's client sale finishes (last client left). On the final
# client day the run is won here — regardless of whether fresh roses were planted or
# watered, since there is no following night to prepare for. Returns true once it has
# taken over the end-of-day flow so the caller skips its night/build transition.
func try_finish_final_day() -> bool:
	if not is_final_client_day():
		return false
	declare_victory()
	return true


# Replaces the direct start_night() taken once the day's clients are done: on the
# final client day the run is won instead of rolling into another (non-existent) night.
func start_night_after_clients() -> void:
	if is_final_client_day():
		declare_victory()
		return
	GameState.start_night()


# Replaces set_building_phase(true) on days that run no client sale at all: the final
# client day has nothing left to do, so it wins; earlier days fall back to building.
func on_client_sale_skipped() -> void:
	if is_final_client_day():
		declare_victory()
		return
	GameState.set_building_phase(true)


func declare_victory() -> void:
	# A destroyed reservoir is a loss even on the last day, so it always wins the race.
	if GameState.is_reservoir_destroyed or GameState.is_run_won:
		return
	GameState.set_building_phase(true)
	GameState.set_run_won(true)


func _total_night_count() -> int:
	var config: SpawnPlaylistConfigService = _manager.get_spawn_playlist_config()
	if config == null:
		return 0
	return config.total_night_count()
