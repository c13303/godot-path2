extends RefCounted
class_name PlaceableNavImpact

# Single authoritative classification of how a placeable affects agent navigation.
# Every placement, removal, building signal and periodic scan must ask this class
# instead of re-deriving the semantics locally. Classification is driven by item
# semantics (ItemCatalog defs / BuildingObjectManager data), never by the name of the
# TileMap layer a tile happens to live on (several item types can share an atlas tile,
# so atlas coordinates alone do not express navigation behaviour).
#
#   NONE            no movement or speed effect (lamp, furniture, reservoir).
#   SPEED_ONLY      only a per-cell speed_multiplier (turret_epine, ronce,
#                   debris). Requires a live speed update, never a Flow Field rebuild.
#   FENCE_DEPENDENT fence: phase-dependent. A hard navigation blocker for clients /
#                   merchants (day), a speed-only slowdown for monsters (night). See
#                   BuildingManager._fences_block_navigation().
#   HARD_TOPOLOGY   changes which floor cells can be routed through (wall, blocking
#                   building). Only this triggers the full walkability/garden/Flow
#                   Field rebuild and the lazy agent waiting state.

enum Impact {
	NONE,
	SPEED_ONLY,
	FENCE_DEPENDENT,
	HARD_TOPOLOGY,
}

const LAYER_WALLZ: String = "wallz"
const LAYER_FENCES: String = "fences"
const LAYER_BLOCKING: String = "blocking_buildings"
const DEFAULT_TERRAIN_SPEED_MULTIPLIER: float = 1.0

# Speed-only placeables that must never reach the hard-topology invalidation path.
# Used only by the debug assertion in debug_assert_not_hard().
const SPEED_ONLY_GUARD_IDS: Array[String] = ["turret_epine"]


# Classify from item semantics alone, when the caller has an item def but not a layer
# (e.g. a BuildingObjectManager signal that only carries an item id).
static func classify_item(item_def: Dictionary) -> Impact:
	if item_def.is_empty():
		# Unknown item: stay conservative so an unresolved tile is never silently
		# downgraded below hard topology.
		return Impact.HARD_TOPOLOGY
	if _def_is_fence(item_def):
		return Impact.FENCE_DEPENDENT
	if _def_is_hard_blocker(item_def):
		return Impact.HARD_TOPOLOGY
	if _def_has_slowdown(item_def):
		return Impact.SPEED_ONLY
	return Impact.NONE


# Classify a concrete tile mutation on a known layer. wallz is always hard topology and
# fences are always fence-dependent regardless of the (sometimes unresolved) tile def;
# other layers fall back to item semantics.
static func classify_for_layer(layer_name: String, item_def: Dictionary) -> Impact:
	if layer_name == LAYER_WALLZ:
		return Impact.HARD_TOPOLOGY
	if layer_name == LAYER_FENCES:
		return Impact.FENCE_DEPENDENT
	if layer_name == LAYER_BLOCKING:
		return _classify_blocking_item(item_def)
	return Impact.SPEED_ONLY if _def_has_slowdown(item_def) else Impact.NONE


# Does this impact require the full hard-topology rebuild right now? Fences resolve by
# the current phase: they only reshape routing while they block clients / merchants.
static func requires_hard_topology(impact: Impact, fences_block_navigation: bool) -> bool:
	if impact == Impact.HARD_TOPOLOGY:
		return true
	if impact == Impact.FENCE_DEPENDENT:
		return fences_block_navigation
	return false


static func is_speed_only(impact: Impact, fences_block_navigation: bool) -> bool:
	if impact == Impact.SPEED_ONLY:
		return true
	if impact == Impact.FENCE_DEPENDENT:
		return not fences_block_navigation
	return false


static func impact_name(impact: Impact) -> String:
	match impact:
		Impact.NONE:
			return "NONE"
		Impact.SPEED_ONLY:
			return "SPEED_ONLY"
		Impact.FENCE_DEPENDENT:
			return "FENCE_DEPENDENT"
		Impact.HARD_TOPOLOGY:
			return "HARD_TOPOLOGY"
	return "UNKNOWN"


# Debug guard: a speed-only placeable (turret_epine) must never be classified
# as hard topology. Returns true (and errors) when the invariant is violated.
static func debug_assert_not_hard(item_id: String, impact: Impact) -> bool:
	if impact == Impact.HARD_TOPOLOGY and SPEED_ONLY_GUARD_IDS.has(item_id):
		push_error("PlaceableNavImpact: speed-only item '%s' misclassified as HARD_TOPOLOGY" % item_id)
		return true
	return false


static func _classify_blocking_item(item_def: Dictionary) -> Impact:
	if item_def.is_empty():
		return Impact.HARD_TOPOLOGY
	if _def_is_hard_blocker(item_def):
		return Impact.HARD_TOPOLOGY
	if _def_has_slowdown(item_def):
		return Impact.SPEED_ONLY
	return Impact.NONE


static func _def_is_fence(item_def: Dictionary) -> bool:
	return str(item_def.get("target_layer", "")) == LAYER_FENCES or str(item_def.get("category", "")) == "fence"


static func _def_is_hard_blocker(item_def: Dictionary) -> bool:
	return (
		bool(item_def.get("blocks_agents", false))
		or bool(item_def.get("blocks_movement", false))
		or bool(item_def.get("isWall", false))
	)


static func _def_has_slowdown(item_def: Dictionary) -> bool:
	if not item_def.has("speed_multiplier"):
		return false
	return float(item_def.get("speed_multiplier", DEFAULT_TERRAIN_SPEED_MULTIPLIER)) < DEFAULT_TERRAIN_SPEED_MULTIPLIER
