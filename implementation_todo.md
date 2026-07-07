We are continuing the BuildingManager cleanup.

Goal:
Batch 3 = reduce unsafe `_manager._private_method()` / `_manager._private_state` coupling in extracted services, without changing gameplay behavior.

This is a refactor-only pass.
Do not change gameplay behavior.
Do not optimize logic unless required to preserve behavior after the boundary cleanup.
Do not run Godot, tests, export, build, or compilation commands.

Project rules:
- Godot/GDScript strict typing is enabled.
- Avoid `:=` inference for numeric expressions, Dictionary/Array values, signal/call returns, mixed int/float math, nullable values, and dynamic values.
- Prefer explicit local types.
- Keep files readable.
- Do not create or grow 1000+ line files.
- Do not create generic abstractions without immediate use.
- Do not perform a broad rewrite.
- Do not rename public/wrapper methods unless direct search proves it is safe.
- Preserve behavior exactly.
- If unsure, keep the existing call and report it.

Context:
`BuildingManager` has been progressively reduced by extracting focused RefCounted services/controllers.
Some extracted services still call `BuildingManager` private methods or private variables directly.
This was acceptable during extraction, but now we want to clean the most dangerous coupling.

Main objective:
Replace high-risk direct private manager access with explicit, stable access points.

Do not try to eliminate every `_manager._xxx` call in one pass.
Focus on the worst coupling first.

Before editing:
1. Search extracted services for direct manager-private access:

```txt
_manager._
Count occurrences per file.
Identify the highest-risk / highest-frequency services.
Inspect call purpose before changing anything.
Prefer small explicit wrappers or query APIs over large abstractions.

Likely files to inspect:

scripts/map/garden_retarget_controller.gd
scripts/map/agent_navigation_phase_controller.gd
scripts/map/spawner_route_service.gd
scripts/map/garden_topology_service.gd
scripts/map/agent_suspend_service.gd
scripts/map/turret_eating_controller.gd
scripts/map/building_invalidation_controller.gd
scripts/map/building_path_service.gd
scripts/map/building_preparation_controller.gd
scripts/map/agent_spawn_service.gd
scripts/map/rose_counter_service.gd or counter_stock_manager.gd
scripts/map/building_manager.gd

Refactor strategy:
Use one of these approaches, in this order.

Approach A — expose narrow public wrappers on BuildingManager
Use this when the data/function still genuinely belongs to BuildingManager, but services should not call private methods.

Example:

Before:

_manager._is_walkable(cell)

After:

_manager.is_map_cell_walkable_for_navigation(cell)

with a public-ish wrapper in BuildingManager:

func is_map_cell_walkable_for_navigation(cell: Vector2i) -> bool:
	return _is_walkable(cell)

Use clear names that describe why the service needs the data.

Approach B — use an existing service directly
Use this when the called method already belongs to a service.

Example:

Before:

_manager._rebuild_spawner_garden_route_cache()

After:

_manager.spawner_route_service().rebuild_spawner_garden_route_cache()

or a thin manager accessor if needed:

func get_spawner_route_service() -> SpawnerRouteService:
	return _spawner_route_service

Only do this if the service type and ownership are clear.

Approach C — create a small query/access service
Use this only if many services repeatedly need the same kind of read-only map/building queries.

Possible file:

scripts/map/building_query_service.gd

Possible responsibility:

read-only map/building queries
cell walkability checks
plant/building lookup helpers
room/cell conversion helpers if currently scattered

Do not put orchestration, spawning, phase logic, or mutation in this query service.

Avoid creating this if 2-3 simple wrappers are enough.

Strongly avoid:

giant “context” objects
generic service locators
moving random methods just to reduce _manager._
changing state ownership during this pass
changing routing, garden, spawn, client, harvest, or day/night behavior
deleting wrappers unless obviously safe
making files larger and less readable

Priority targets:
Focus on direct private access patterns like:

_manager._some_private_method()
_manager._some_private_dictionary
_manager._some_private_array
_manager._some_private_node
_manager._some_private_flag

Highest priority:

Direct access to mutable dictionaries/arrays.
Direct access to dirty flags/state flags.
Direct calls that cross domain boundaries.
Repeated private calls used by several services.
Private calls from recently extracted services.

Lower priority:

One-off private calls that would need awkward abstraction.
Compatibility wrappers.
Debug-only calls.
Calls that are clearly safe and local.

State ownership rule:
Do not move ownership of major state in this pass unless it is tiny and obvious.

For example:

Do not move all garden state again.
Do not move all spawner state again.
Do not move all agent phase state again.
Do not rewrite preparation/spawn/counter flows.

This batch is about safer boundaries, not new extractions.

Naming rule:
Public wrappers should be intention-revealing.

Avoid vague names:

get_data()
do_rebuild()
manager_call()

Prefer explicit names:

is_cell_walkable_for_agent_navigation(cell)
get_registered_spawner_cells()
request_exit_wall_escape_rebuild()
mark_navigation_topology_dirty()

Compatibility:
Keep existing private methods unless you are certain they are unused internally.
The goal is not to delete all private methods.
The goal is to stop extracted services from depending on private manager internals.

Expected result:

Fewer _manager._xxx calls in extracted services.
The most dangerous private mutable state access is replaced by explicit methods.
BuildingManager may gain a small number of clear public wrappers/accessors.
No broad behavior changes.
No new god-object service.
No new file over 1000 lines.
Existing manually tested behavior remains intact.

Suggested concrete workflow:

Generate a list of _manager._ calls by file.
Pick 2-4 high-value files only.
For each private access, classify it:
read-only query
mutation request
service delegation
state ownership leak
debug-only
Replace only the safe/high-value ones.
Keep unclear cases unchanged.
Report what remains and why.

Do not attempt to reach zero _manager._ calls.

Safety checks by reading/searching only:

Search all renamed or newly wrapped methods.
Verify method signatures are unchanged where wrappers remain.
Verify no call sites now bypass required side effects.
Verify save/load structure is untouched.
Verify no scene/signal/Callable/call references were broken.
Verify no preload/load path typo if a new query service is created.
Verify setup order in _ready() if a new service is added.
Verify strict typing on all new locals and returns.

Output required:

List changed files.
Show before/after count of _manager._ occurrences per modified service.
Explain which private accesses were replaced and why.
Explain which private accesses were intentionally retained and why.
Confirm no behavior changes were intended.
Mention manual test scenarios.

Manual test scenarios to suggest:

Start a normal night.
Spawn monsters from multiple spawners.
Let monsters target/eat plants and exit.
Remove/place buildings that affect navigation invalidation.
Run client phase if applicable.
Verify garden targeting/retargeting still works.
Verify day/night transition still proceeds.
Verify no new warnings/errors appear.