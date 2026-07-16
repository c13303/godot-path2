extends RefCounted
class_name HouseResidentConfig

## Immutable description of one ordinary house-villager type, consumed by HouseResidentController.
##
## Adding a future ordinary villager (e.g. the Inventor) fills one of these in and registers a
## HouseResidentController with it in AllyHousingController — no new lifecycle branches anywhere.
##
##   resident_type      canonical role id, must match ItemCatalog house_resident_type + the meta
##                      stamped on the agent (agent.get_meta("resident_type"))
##   house_item_id      catalog house that owns this resident (e.g. &"house_merchant")
##   agent_kind         agent-kind meta / spawner kind stamped on the agent
##   scene_group        scene group the agent joins (role identity for save/removal/contact)
##   tracking_category  AgentCellTracker category for tile-contact evaluation
##   visual_setup       Callable(agent) that applies the role's sprite/visuals
##   role               optional HouseResidentRole for role-specific side effects (null = none)
##   interaction_hold_radius_tiles
##                      0 disables automatic native movement hold; positive values pause
##                      autonomous movement while the player remains within that tile radius

var resident_type: StringName = &""
var house_item_id: StringName = &""
var agent_kind: StringName = &""
var scene_group: StringName = &""
var tracking_category: StringName = &""
var visual_setup: Callable = Callable()
var role: HouseResidentRole = null
var interaction_hold_radius_tiles: int = 0


func is_valid() -> bool:
	return resident_type != &"" \
		and house_item_id != &"" \
		and agent_kind != &"" \
		and scene_group != &"" \
		and tracking_category != &"" \
		and visual_setup.is_valid()
