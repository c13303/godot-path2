# Map / Building Architecture

## BuildingManager
Owns:
- Scene-facing exported references, setup, lifecycle, day/night orchestration.
- Service/controller wiring and compatibility wrappers used by scenes, signals, saves, and older callers.
- High-level dispatch for spawning, garden rebuilds, client/merchant phases, save/progression integration.

Does not own:
- Detailed garden topology data structures.
- Build placement/removal/input behavior.
- Spawner route caches and garden-access scoring internals.

Notes:
- Still large by design as the coordinator/facade. Keep wrappers when external Godot calls may depend on them.

## GardenTopologyService
Owns:
- Garden dictionaries, plant-zone caches, walkable-map cache, dirty/empty garden state.

Does not own:
- Agent retargeting, route scoring, spawning, or scene lifecycle.

Notes:
- This is the source of truth for garden topology state.

## GardenAccessResolver
Owns:
- Garden entry/exit access scoring and memoized entry resolution.

Does not own:
- Garden topology storage or route cache ownership.

Notes:
- Reads manager-owned low-level queries through explicit accessors.

## SpawnerRouteService
Owns:
- Spawner escape routes, spawner-to-garden route groups, exit-wall escape groups, route cache stats.

Does not own:
- Spawner source-of-truth dictionaries or spawn timing.

Notes:
- Uses agent/flow dynamic calls where external native or scene APIs are optional.

## AgentNavigationPhaseController
Owns:
- Runtime agent phase dictionaries for entry flow, A* in, eating/counter work, and escape.

Does not own:
- Garden topology or route cache state.

Notes:
- BuildingManager exposes compatibility wrappers for older phase-related call sites.

## GardenRetargetController
Owns:
- Retarget queue, plant-target reverse index, stale-target checks, retarget profiling.

Does not own:
- Garden topology source data or route groups.

Notes:
- Some manager interaction remains direct because retargeting coordinates several manager-owned subsystems.

## BuildSystem Controllers / Services
Owns:
- Build input, preview, drag, placement, removal, and build-mode direction state.

Does not own:
- Night/day map preparation or agent navigation behavior.

Notes:
- BuildModeStateController is wired to BuildSystem, not BuildingManager.

## HouseManager
Owns:
- Fixed house geometry rules (3x2 blocking footprint on the entrance cell; 3x3 visual sprite with a purely-visual overhang row).
- The authoritative house registry (one logical HouseRecord per house: id, sprite, entrance, five blocking cells, authored/runtime, under-construction).
- Authored-house discovery (`house_`-prefixed Sprite2D under the spawner container) and normalization: sprite bottom-edge snapping, entrance-top-edge z-index (so an agent in the walkable doorway draws in front), batched footprint-wall stamping, paired spot-marker snapping.
- Generic runtime house creation: atomic 3x2 validation, sprite snap/z-index, one batched five-cell wall stamp, immediate player collision, one registry record, one hard-topology invalidation, one construction visual.

Does not own:
- Flow-field generation, garden rebuilding, general building placement, inventory/currencies, build-menu state, save/load, house removal, house health, or merchant AI.

Notes:
- Authored preparation is a static entry point (`prepare_authored_houses`) invoked by LevelLoader on the off-tree level instance BEFORE spawner bindings are captured, because a paired spot (seedmerchent_spot) becomes the merchant's stored spot_cell.
- Reaches BuildingManager only through public wrappers: `get_construction_overlay`, `set_player_navigation_cell_blocked`, `is_walkable_cell`, `has_floor_cell`, `has_wall_cell`, and `get_building_invalidation_controller().after_walkability_changed(...)`.
- Footprint blockers use the transparent wallz tile (15,0) — the same invisible blocker as the reservoir base — resolved from the live tile_set, never hardcoded source ids.

## BuildingConstructionOverlay / BuildingConstructionIndicator
Owns:
- The single flow-construction progress state machine (dirty/quiet window -> budgeted walkability rebuild -> lazy flow queue drain -> async worker idle -> complete).

Notes:
- The overlay ghosts per-cell wall/turret/fence tiles AND drives external sprite visuals (houses) that share the same progress. A house uses one BuildingConstructionIndicator child (one bar, 50% ghost) instead of five per-cell bars. Processing stays active while either pending cells or house indicators remain.

## HouseRuntimeTestController (TEMPORARY)
- Isolated `K`-key debug controller (`scripts/debug/house_runtime_test_controller.gd`) wired from a clearly marked temporary block in BuildingManager. Builds one runtime house at the `test_flyhouse` marker. Delete together with its wiring once houses are integrated into the real build system.
