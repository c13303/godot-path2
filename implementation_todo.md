Review the current `scripts/map/building_manager.gd`.

Goal: perform the real `SpawnerRouteService` extraction.

The previous pass was only a boundary/stabilization pass and recommended that the real route extraction be done as a separate explicit task. This is that task.

Do not run Godot, tests, compilation, export, or build commands. I will test manually.

## Target

Create a focused route service:

```txt
scripts/map/spawner_route_service.gd
```

Use another clear name only if it better matches the existing project style.

## Responsibility

`SpawnerRouteService` should own route / flow-field route state and behavior.

It may own:

```txt
_spawner_routes
_spawner_garden_routes
_dirty_spawner_escapes
_exit_wall_escapes
_route_cache_hits
_route_cache_misses
flow-field route creation
flow-field route release
route readiness checks
exit-wall escape cache
spawner-to-garden route cache
dirty route draining
```

`BuildingManager` should still own:

```txt
spawner registries
spawner kind lookup
garden dictionaries
garden epoch
walkable map cache
night preparation state
client preparation state
spawn playlist/spawn tick logic
agent state dictionaries
garden retargeting
agent eating/escaping
client systems
save/load facade
```

## Candidate functions to move

Move route-only functions such as:

```gdscript
_release_spawner_route
_drain_dirty_routes
_initialize_spawner_route
_rebuild_spawner_plant_ff
_rebuild_spawner_escape_ff
_rebuild_all_spawner_routes
_rebuild_spawner_garden_route_cache
_release_garden_routes
_release_spawner_garden_route
_garden_route_is_current
_get_or_create_spawner_garden_route
_spawner_garden_route_flow_ready
_request_group_flow_rebuild
_rebuild_exit_wall_escapes_budgeted
_release_exit_wall_escape
_nearest_reachable_exit_escape
_initialize_spawner_routes_for_kinds
_prewarm_spawner_entry_flows_for_kind
_mark_spawner_entry_routes_ready_for_groups
_night_flow_fields_are_ready_for_kinds
_group_flow_id_is_ready
_group_flow_is_ready_at_world
_flow_uses_async_requests
_flow_supports_sync_assign
```

Do not move garden topology, retargeting, spawn tick behavior, or scan logic.

## Desired boundary

`BuildingManager` may keep:

```gdscript
var _spawner_route_service: SpawnerRouteService = SpawnerRouteService.new()
```

Initialize it with:

```gdscript
_spawner_route_service.setup(self)
```

if this matches the current project pattern and keeps the patch smaller.

`BuildingManager` may keep thin private wrappers for compatibility if many existing internal methods call the old names.

Examples:

```gdscript
func _get_or_create_spawner_garden_route(spawner_cell: Vector2i, garden_id: int) -> Dictionary:
    return _spawner_route_service.get_or_create_spawner_garden_route(spawner_cell, garden_id)

func _nearest_reachable_exit_escape(world_pos: Vector2) -> Dictionary:
    return _spawner_route_service.nearest_reachable_exit_escape(world_pos)
```

Thin wrappers are acceptable. Do not rewrite the whole manager call graph just to avoid wrappers.

## Dependency rule

The route service may read required source-of-truth data from `BuildingManager` through narrow methods or through `setup(manager)`.

Acceptable manager dependencies:

```txt
flow
agent_manager
spawner cells
spawner kind lookup
spawner exit/spot lookup
garden lookup
garden epoch
walkability checks
cell/world conversion
night/client preparation token checks
night preparation budget
debug telemetry warnings
```

Avoid copying source-of-truth gameplay registries into the route service unless they are route-owned dictionaries.

Do not make the route service own spawner scanning.

Do not make the route service own garden topology.

Do not make the route service own spawn decisions.

## Important behavior preservation

Preserve exactly:

```txt
same flow-field group allocation
same route release behavior
same dirty route invalidation
same route cache keys
same garden epoch/version checks
same async flow request behavior
same sync fallback behavior
same group readiness checks
same route-cost checks
same exit-wall escape selection
same nearest reachable exit behavior
same route cache hit/miss accounting
same warning/error behavior
same night preparation readiness behavior
same client preparation readiness behavior
```

Do not tune route selection.

Do not change route costs.

Do not change which gardens are targetable.

Do not change monster/client/merchant spawning behavior.

## Do not extract

Do not move or refactor:

```txt
building scan / special tile detection
garden topology creation
garden geometry rebuild
garden retargeting
garden access scoring
spawn tick behavior
spawn playlist behavior
night preparation state machine
client preparation state machine
agent eating
agent escaping
astar-in arrival logic
monster death/drop logic
agent suspend/resume
client systems
save/load behavior
tutorial behavior
debug/telemetry
```

## Stop condition

If the extraction requires deep changes to garden topology, retargeting, scan service, spawn tick logic, or night/client preparation state machines, stop and report the coupling instead of continuing.

Do not “solve” the coupling by expanding the scope.

## GDScript strict typing

Godot/GDScript strict typing is enabled.

Avoid `:=` inference for:

```txt
numeric expressions
Dictionary / Array values
signal or call() returns
mixed int / float math
nullable or dynamic values
```

Prefer explicit local types.

Cast dynamic values before use.

## Patch discipline

Preserve behavior.

Keep the patch small and reviewable.

Do not rename unrelated symbols.

Do not reformat unrelated code.

Do not clean unrelated systems.

Do not create generic utility files.

Do not continue into garden topology or retargeting because the code is nearby.

## Before coding, report

```txt
Owner:
Caller:
State owned:
Public API:
Files changed:
Estimated lines moved:
Route state ownership decision:
Manager state intentionally kept:
Thin wrappers to preserve:
Couplings found:
Risk:
```

Then implement only the route extraction.

## Final report

After implementation, report:

```txt
What moved:
What stayed in BuildingManager:
Route state ownership decision:
Thin wrappers kept:
Files changed:
Remaining risks:
Manual test checklist:
Recommended next step:
```
