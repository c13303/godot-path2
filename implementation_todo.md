Task: batched runtime-agent cleanup pass to make the map/building codebase easier for coding agents and humans to maintain.

Targets:

* `scripts/map/agent_navigation_phase_controller.gd`
* `scripts/map/garden_retarget_controller.gd`
* `scripts/map/agent_suspend_service.gd`
* `scripts/map/monster_death_controller.gd`
* `scripts/map/drowning_controller.gd`
* `scripts/map/turret_eating_controller.gd`
* minimal related changes in `scripts/map/building_manager.gd`

Goal:
Reduce hidden runtime-agent coupling with `BuildingManager`, without changing gameplay behavior.

This is a cleanup pass, not a feature pass.

Do not optimize.
Do not move broad behavior.
Do not run Godot, tests, builds, compilation, or exports.

Problem:
Runtime agent behavior is spread across extracted services, but `AgentNavigationPhaseController` still calls many `BuildingManager` private methods through `_manager.call(...)`.

This makes future agent edits risky because the real dependencies are hidden.

Main objective:
Make runtime agent dependencies clearer by replacing safe `_manager.call(...)`, `_manager.get(...)`, and `_manager.has_method(...)` usages with explicit direct calls, cached dependencies, or small typed accessors.

Focus especially on `agent_navigation_phase_controller.gd`, because it currently has the most hidden coupling.

Before editing, search inside the target files for:

* `_manager.call(`
* `_manager.get(`
* `_manager.has_method(`
* `_manager.set(`

Classify each usage as:

* manager wrapper around an existing service
* manager state access
* manager method call
* dependency lookup
* compatibility/safety check
* unclear / risky

Clean the safest groups first.

Preferred cleanup order:

1. Replace calls to `BuildingManager` wrappers that simply forward to already-existing services.

For example, if `BuildingManager._find_path_in_zone(...)` only forwards to `BuildingPathService`, prefer making the dependency explicit and calling the service directly.

2. Cache stable service dependencies during `setup(...)` when safe.

Likely useful dependencies for `AgentNavigationPhaseController`:

* `GardenTopologyService`
* `SpawnerRouteService`
* `GardenRetargetController`
* `BuildingPathService`
* `BuildingDebugTelemetry`
* `CounterStockManager`
* `AgentDefinitionService`
* `plant_manager`
* `agent_manager`
* `floorz`
* `plantz`

Only add dependencies that are actually needed by the existing code.

3. Replace known manager method calls with direct typed manager calls only when the method clearly exists and keeping it on `BuildingManager` is intentional.

4. Add small typed accessors on `BuildingManager` only when this avoids broad churn and makes ownership clearer.

5. Keep `_manager.call(...)` only when there is a real dynamic-call reason or replacing it would be risky.

Do not try to remove every manager reference.
The goal is a meaningful reduction of hidden coupling, not a perfect rewrite.

Ownership rules:

`AgentNavigationPhaseController` should own:

* runtime agent navigation phases
* entry flow handling
* A*-in arrival handling
* eating phase handling
* escape phase handling
* client counter phase handling
* phase dictionaries such as eating / escaping / entry-path / astar-in agents

It should not own:

* garden topology computation
* spawner route creation internals
* plant manager internals
* counter stock storage
* actual monster death cleanup
* drowning/turret suspension internals
* spawn playlist logic
* spawn tick logic
* build placement/removal

`GardenRetargetController` should own:

* retarget queues
* stale target detection
* plant-target reverse index
* waiting-for-retarget state
* retarget processing

`AgentSuspendService` should own:

* temporary suspension/resume records for agents

`MonsterDeathController` should own:

* monster death cleanup/drop behavior already assigned to it

`DrowningController` should own:

* drowning-specific suspension/kill behavior

`TurretEatingController` should own:

* turret-eating-specific suspension/damage behavior

`BuildingManager` should only:

* wire runtime-agent services
* coordinate lifecycle
* keep compatibility wrappers when external callers may still need them
* expose small accessors when needed

Do not change:

* monster movement behavior
* entry flow behavior
* A*-in behavior
* eating behavior
* escape behavior
* retarget behavior
* waiting-for-retarget behavior
* client counter behavior
* seed merchant escape behavior
* drowning behavior
* turret eating behavior
* monster death behavior
* agent spawn/despawn behavior
* garden targeting behavior
* route selection behavior
* bottleneck behavior
* debug log text
* public method names used by other files
* `.tscn` files

Important regression risks:

* do not change when agents enter eating state
* do not change when agents switch to escape flow
* do not change direct eat-exit flow-field behavior
* do not change garden retarget timing
* do not change agent unregister timing
* do not change plant consumption timing
* do not change client payment/counter behavior
* do not change seed merchant pause/escape handling
* do not add broad per-agent scans
* do not add extra hot-path work

Keep compatibility wrappers in `BuildingManager` if external callers may still need them.

If a hidden manager access cannot be safely replaced, leave it unchanged and explain why in the final report.

Expected result:

* `agent_navigation_phase_controller.gd` has significantly fewer `_manager.call(...)` usages
* runtime-agent dependencies are easier to see from `setup(...)`
* behavior is unchanged
* `BuildingManager` may gain small typed accessors if needed
* no scene files are changed

Final report:

* files changed
* `_manager.call/get/has_method/set` usages removed per file
* dependencies cached or added per file
* usages intentionally left unchanged and why
* any new accessors/wrappers added to `BuildingManager`
* behavior intentionally preserved
* manual test risks
