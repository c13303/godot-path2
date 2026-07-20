extends HouseResidentRole
class_name SeedMerchantController

## Seed-merchant-specific concerns only. All shared house-villager lifecycle (spawn, arrival,
## night return, evacuation, repath, removal, identity, interaction hold) lives in the
## HouseResidentController this role is attached to. This role owns:
##   * the seed-merchant shop phase flag (GameState.seed_merchant_phase);
##   * the afternoon "finishing the watering still ends the day" recheck and the
##     purchase-made phase clear.
## Dialog/shop UI + purchases live in MerchantDialogController / game_ui.

const INTERACT_RADIUS_TILES: int = 2

var _manager: BuildingManager = null
var _resident: HouseResidentController = null


func setup(manager: BuildingManager) -> void:
	_manager = manager


## Back-reference to the shared lifecycle controller this role rides on, so the merchant-facing
## facade methods (begin_phase / is_player_near / is_paused_agent) can reach the live agent.
func set_resident(resident: HouseResidentController) -> void:
	_resident = resident


# ---------------------------------------------------------------------------
# HouseResidentRole hooks.
# ---------------------------------------------------------------------------

func on_spawned(_resident_agent: HouseResidentController) -> void:
	GameState.set_seed_merchant_phase(false)


func on_night_started(_resident_agent: HouseResidentController) -> void:
	GameState.set_seed_merchant_phase(false)


func on_leaving(_resident_agent: HouseResidentController) -> void:
	GameState.set_seed_merchant_phase(false)


func on_cleared() -> void:
	GameState.set_seed_merchant_phase(false)


func on_interaction_selected(_resident_agent: HouseResidentController, selected: bool) -> void:
	GameState.set_seed_merchant_phase(selected and not GameState.is_night)


func process_phase(resident: HouseResidentController) -> void:
	if not resident.is_active():
		return
	# The client sale can finish before the player has watered every rose. When that happens the
	# client sale does NOT start the night and the merchant lingers. Re-check here so finishing
	# the watering afterwards still ends the day.
	if GameState.is_afternoon_phase and _manager.can_start_night_after_clients():
		_manager.request_night_after_clients()
		return


# ---------------------------------------------------------------------------
# Merchant-specific facade (called by BuildingManager wrappers).
# ---------------------------------------------------------------------------

## Turns on the shop phase at the start of a day when the merchant is already present.
func begin_phase() -> void:
	GameState.set_seed_merchant_phase(false)


## True whenever the player is within interaction range of the merchant, no matter what the
## merchant is doing (walking in, parked at the spot, or walking back out). Drives the interaction
## prompt, the shop, and the walk-in shop-open path.
func is_player_near() -> bool:
	return _resident != null and _resident.is_interaction_selected()


func is_paused_agent(agent: Node2D) -> bool:
	return _resident != null and _resident.owns_agent(agent) and _resident.is_interaction_held()
