extends HouseResidentRole
class_name SeedMerchantController

## Seed-merchant-specific concerns only. All shared house-villager lifecycle (spawn, arrival,
## night return, evacuation, repath, removal, identity) lives in the HouseResidentController
## this role is attached to. This role owns:
##   * the seed-merchant shop phase flag (GameState.seed_merchant_phase);
##   * freezing/unfreezing the merchant while the player is within interaction range;
##   * the afternoon "finishing the watering still ends the day" recheck and the
##     purchase-made phase clear.
## Dialog/shop UI + purchases live in MerchantDialogController / game_ui.

const INTERACT_RADIUS_TILES: int = 2

var _manager: BuildingManager = null
var _resident: HouseResidentController = null
# True while the merchant is frozen because the player is within interaction range. Mirrors the
# native per-agent pause; cleared when the player walks away or the merchant starts leaving.
var _paused: bool = false


func setup(manager: BuildingManager) -> void:
	_manager = manager


## Back-reference to the shared lifecycle controller this role rides on, so the merchant-facing
## facade methods (begin_phase / is_player_near / is_paused_agent) can reach the live agent.
func set_resident(resident: HouseResidentController) -> void:
	_resident = resident


# ---------------------------------------------------------------------------
# HouseResidentRole hooks.
# ---------------------------------------------------------------------------

func on_spawned(_resident: HouseResidentController) -> void:
	_paused = false
	GameState.set_seed_merchant_phase(true)


func on_night_started(resident: HouseResidentController) -> void:
	_unpause(resident)
	GameState.set_seed_merchant_phase(false)


func on_leaving(resident: HouseResidentController) -> void:
	_unpause(resident)
	GameState.set_seed_merchant_phase(false)


func on_cleared() -> void:
	_paused = false
	GameState.set_seed_merchant_phase(false)


func process(resident: HouseResidentController) -> void:
	# Once the merchant is leaving it must never re-pause: night has already started, and walking
	# back into the departing merchant should not freeze it.
	if not resident.is_active() or resident.is_leaving():
		return
	var near: bool = resident.is_player_near(INTERACT_RADIUS_TILES)
	if near and not GameState.is_night and not GameState.is_seed_merchant_phase:
		GameState.set_seed_merchant_phase(true)
	# Keep walking to the spot even when the player is close; the merchant only freezes for the
	# player once it has parked. The player can still open the shop with interact during the walk-in.
	if not resident.has_reached_idle_spot():
		return
	if near == _paused:
		return
	_set_paused(resident, near)


func process_phase(resident: HouseResidentController) -> void:
	if not resident.is_active():
		return
	# The client sale can finish before the player has watered every rose. When that happens the
	# client sale does NOT start the night and the merchant lingers. Re-check here so finishing
	# the watering afterwards still ends the day.
	if GameState.is_afternoon_phase and _manager.can_start_night_after_clients():
		_manager.request_night_after_clients()
		return
	if GameState.is_seed_merchant_phase and GameState.seed_merchant_purchase_made and not resident.is_player_near(INTERACT_RADIUS_TILES):
		GameState.set_seed_merchant_phase(false)


# ---------------------------------------------------------------------------
# Merchant-specific facade (called by BuildingManager wrappers).
# ---------------------------------------------------------------------------

## Turns on the shop phase at the start of a day when the merchant is already present.
func begin_phase() -> void:
	if _resident != null and _resident.is_active() and not GameState.is_night:
		GameState.set_seed_merchant_phase(true)


## True whenever the player is within interaction range of the merchant, no matter what the
## merchant is doing (walking in, parked at the spot, or walking back out). Drives the interaction
## prompt, the shop, and the walk-in shop-open path.
func is_player_near() -> bool:
	return _resident != null and _resident.is_player_near(INTERACT_RADIUS_TILES)


func is_paused_agent(agent: Node2D) -> bool:
	return _resident != null and _resident.owns_agent(agent) and _paused


# ---------------------------------------------------------------------------
# Internals.
# ---------------------------------------------------------------------------

func _unpause(resident: HouseResidentController) -> void:
	if _paused:
		_set_paused(resident, false)


func _set_paused(resident: HouseResidentController, value: bool) -> void:
	_paused = value
	var agent: Node2D = resident.agent_node()
	var nav_id: int = int(agent.get("nav_id")) if agent != null else -1
	var agent_manager: Node = _manager.get_agent_manager() if _manager != null else null
	if nav_id >= 0 and agent_manager != null and agent_manager.has_method("set_agent_paused"):
		agent_manager.call("set_agent_paused", nav_id, value)
