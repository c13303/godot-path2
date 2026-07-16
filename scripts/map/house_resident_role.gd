extends RefCounted
class_name HouseResidentRole

## Optional role delegate for an ordinary house villager.
##
## HouseResidentController owns the shared movement/lifecycle (spawn, arrival, night return,
## evacuation, repath, removal). A role layers role-specific side effects on top of those
## lifecycle events — e.g. the seed merchant's shop-phase flag and interaction pause — without
## re-implementing any movement. Ordinary villagers with no special behaviour register no role.
##
## All hooks default to no-ops. The `resident` argument is the owning HouseResidentController,
## so a role can read the live agent node / world position / waiting state through it.


func setup(_manager: BuildingManager) -> void:
	pass


## The resident agent has just been spawned and is walking in.
func on_spawned(_resident: HouseResidentController) -> void:
	pass


## The resident finished walking in and is parked at its idle spot.
func on_reached_spot(_resident: HouseResidentController) -> void:
	pass


## Night started: the resident is heading home / leaving.
func on_night_started(_resident: HouseResidentController) -> void:
	pass


## The resident has begun leaving the map (night departure or evacuation).
func on_leaving(_resident: HouseResidentController) -> void:
	pass


## The resident was cleared/removed: reset any role state and world flags.
func on_cleared() -> void:
	pass


## Per-frame agent-pass hook (interaction proximity / pause).
func process(_resident: HouseResidentController) -> void:
	pass


## Per-frame phase-pass hook (role phase state).
func process_phase(_resident: HouseResidentController) -> void:
	pass
