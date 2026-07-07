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
