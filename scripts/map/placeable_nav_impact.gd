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
const MIN_TERRAIN_SPEED_MULTIPLIER: float = 0.05
const MAX_TERRAIN_SPEED_MULTIPLIER: float = 4.0


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
	if _def_has_speed_modifier(item_def):
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
	return Impact.SPEED_ONLY if _def_has_speed_modifier(item_def) else Impact.NONE


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


# Speed multiplier this def imposes on a regular agent (monster / client / merchant /
# sheep). 1.0 when the def carries no terrain-speed modifier.
static func def_speed_multiplier(item_def: Dictionary) -> float:
	if item_def.is_empty() or not item_def.has("speed_multiplier"):
		return DEFAULT_TERRAIN_SPEED_MULTIPLIER
	var multiplier: float = float(item_def.get("speed_multiplier", DEFAULT_TERRAIN_SPEED_MULTIPLIER))
	if is_nan(multiplier) or is_inf(multiplier) or multiplier <= 0.0:
		return DEFAULT_TERRAIN_SPEED_MULTIPLIER
	return clampf(multiplier, MIN_TERRAIN_SPEED_MULTIPLIER, MAX_TERRAIN_SPEED_MULTIPLIER)


# Speed multiplier this def imposes on the PLAYER. Defs opting out with
# "slows_player": false (roses: the player is never slowed by their own crop) impose
# nothing on the player while still slowing every other agent. A definition may instead
# provide an explicit player_speed_multiplier (ronce). Single authority for the rule:
# both terrain-speed call sites ask this.
static func def_player_speed_multiplier(item_def: Dictionary) -> float:
	if not bool(item_def.get("slows_player", true)):
		return DEFAULT_TERRAIN_SPEED_MULTIPLIER
	if item_def.has("player_speed_multiplier"):
		return _validated_speed_multiplier(item_def.get("player_speed_multiplier", DEFAULT_TERRAIN_SPEED_MULTIPLIER))
	return def_speed_multiplier(item_def)


## Speed multiplier for bigmonster's dedicated terrain channel. Most placeables
## inherit the ordinary-agent value; only definitions with an explicit override differ.
static func def_big_monster_speed_multiplier(item_def: Dictionary) -> float:
	if item_def.has("big_monster_speed_multiplier"):
		return _validated_speed_multiplier(item_def.get("big_monster_speed_multiplier", DEFAULT_TERRAIN_SPEED_MULTIPLIER))
	return def_speed_multiplier(item_def)


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


# Debug guard: any semantically speed-only placeable must never be classified as
# hard topology. Returns true (and errors) when the invariant is violated.
static func debug_assert_not_hard(item_id: String, impact: Impact) -> bool:
	var item_def: Dictionary = ItemCatalog.get_item_def(item_id)
	if impact == Impact.HARD_TOPOLOGY and _def_has_speed_modifier(item_def) and not _def_is_hard_blocker(item_def):
		push_error("PlaceableNavImpact: speed-only item '%s' misclassified as HARD_TOPOLOGY" % item_id)
		return true
	return false


static func _classify_blocking_item(item_def: Dictionary) -> Impact:
	if item_def.is_empty():
		return Impact.HARD_TOPOLOGY
	if _def_is_hard_blocker(item_def):
		return Impact.HARD_TOPOLOGY
	if _def_has_speed_modifier(item_def):
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


static func _def_has_speed_modifier(item_def: Dictionary) -> bool:
	if not item_def.has("speed_multiplier"):
		return false
	var multiplier: float = def_speed_multiplier(item_def)
	return not is_equal_approx(multiplier, DEFAULT_TERRAIN_SPEED_MULTIPLIER)


static func _validated_speed_multiplier(raw_multiplier: Variant) -> float:
	var multiplier: float = float(raw_multiplier)
	if is_nan(multiplier) or is_inf(multiplier) or multiplier <= 0.0:
		return DEFAULT_TERRAIN_SPEED_MULTIPLIER
	return clampf(multiplier, MIN_TERRAIN_SPEED_MULTIPLIER, MAX_TERRAIN_SPEED_MULTIPLIER)
