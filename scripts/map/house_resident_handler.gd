extends RefCounted
class_name HouseResidentHandler

## Narrow lifecycle contract that AllyHousingController orchestrates for one resident role.
##
## Ordinary one-house/one-resident villagers (the seed merchant, the future Inventor, ...)
## use the shared HouseResidentController, which implements this contract directly. Builders
## keep a specialized adapter (BuilderResidentHandler) because they construct houses, own
## work queues, and carry the fundamental-Builder onboarding.
##
## Every method has a no-op / false default so an adapter overrides only what its role needs,
## and AllyHousingController can call the whole contract on every handler without type checks.
## Reconciliation and house events are driven at controlled lifecycle points (day begin,
## house completed/removed, after load) — never per frame.


## Spawn missing residents and retire stale ones from the completed-house records.
func reconcile_houses() -> void:
	pass


## Per-frame agent-pass update (arrival + interaction proximity). Keep it cheap.
func process(_delta: float) -> void:
	pass


## Per-frame phase-pass update (role phase state). No-op for roles without a phase.
func process_phase(_delta: float) -> void:
	pass


func on_night_started() -> void:
	pass


func start_pending_departures() -> void:
	pass


## Repath active residents after a walkability change (never a synchronous nav rebuild).
func repath_for_walkability_change() -> void:
	pass


## A house finished construction: the handler owning that house type spawns its resident.
func on_house_completed(_snapshot: HouseManager.HouseSnapshot) -> void:
	pass


## A house is being torn down: the handler owning its resident evacuates/releases it.
func on_house_removing(_snapshot: HouseManager.HouseSnapshot) -> void:
	pass


## A tracked resident agent was removed from the world: drop its state and mappings.
func on_agent_removed(_agent: Node2D) -> void:
	pass


## True when this handler owns the given agent (routes removal/queries to it).
func owns_agent(_agent: Node2D) -> bool:
	return false
