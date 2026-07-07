We are continuing the BuildingManager cleanup.

Goal:
Batch 10 = reduce unsafe manager-private coupling in the preparation and spawn orchestration services, without changing gameplay behavior.

This is a refactor-only pass.
Do not change gameplay behavior.
Do not optimize logic unless required by the boundary cleanup.
Do not run Godot, tests, export, build, or compilation commands.

Project rules:
- Godot/GDScript strict typing is enabled.
- Avoid `:=` inference for numeric expressions, Dictionary/Array values, signal/call returns, mixed int/float math, nullable values, and dynamic values.
- Prefer explicit local types.
- Keep files readable.
- Do not create or grow 1000+ line files.
- Do not create generic abstractions without immediate use.
- Do not perform a broad rewrite.
- Preserve behavior exactly.
- If unsure, keep the existing private access and report it.

Current context:
Previous batches reduced `BuildingManager` bloat, extracted runtime ticking, and started cleaning domain boundaries.

The next coupling hotspots are likely:

```txt
scripts/map/building_preparation_controller.gd
scripts/map/agent_spawn_service.gd
scripts/map/building_manager.gd

These services coordinate important gameplay setup:

night/client preparation
scan/sync/rebuild sequence
spawner route initialization
async flow-field readiness
agent scene instantiation
spawn cell selection
route/garden assignment
agent registration

This pass must stay conservative.

Main objective:
Reduce the most dangerous direct _manager._xxx access in BuildingPreparationController and AgentSpawnService, especially raw mutable state access and service-through-manager-private access.

Do not rewrite preparation.
Do not rewrite spawning.
Do not change spawn fallback behavior.
Do not change preparation order.
Do not change async/await behavior.
Do not change route assignment.
Do not change garden selection.
Do not change agent registration.

Before editing:

Inspect building_preparation_controller.gd.
Inspect agent_spawn_service.gd.
Inspect related wrappers/accessors in building_manager.gd.
Count _manager._ references in both target services.
Categorize each private access as:
- preparation guard/state flag
- scan/sync/rebuild orchestration
- service/controller access
- spawner registry/query
- route/garden selection
- spawn scene lookup
- spawn placement query
- agent registration
- debug/telemetry only
- unclear / keep

Do not edit before this classification.

Priority 1 — service/controller access:
If a target service accesses another manager-owned service through private fields, prefer typed getters on BuildingManager.

Examples:

func get_building_scan_service() -> BuildingScanService:
	return _building_scan

func get_building_navigation_sync_service() -> BuildingNavigationSyncService:
	return _building_navigation_sync

func get_building_invalidation_controller() -> BuildingInvalidationController:
	return _building_invalidation_controller

func get_spawner_route_service() -> SpawnerRouteService:
	return _spawner_route_service

func get_spawner_garden_selection_service() -> SpawnerGardenSelectionService:
	return _spawner_garden_selection_service

func get_agent_definition_service() -> AgentDefinitionService:
	return _agent_definition_service

func get_debug_telemetry() -> BuildingDebugTelemetry:
	return _debug_telemetry

Only add getters that are actually used.
Use the real class names from the current codebase.

Priority 2 — preparation state flags:
If BuildingPreparationController directly mutates preparation state flags on the manager, replace with narrow manager methods if safe.

Bad:

_manager._night_preparing = false
_manager._night_preparation_ready = true
_manager._client_preparing = false

Better:

_manager.finish_night_preparation_success()
_manager.finish_night_preparation_abort()
_manager.finish_client_preparation_success()
_manager.finish_client_preparation_abort()

Only create methods that exactly preserve current behavior.
Do not move ownership of preparation state in this pass unless it is already clearly isolated.

The manager may still own the flags; the controller should request transitions through explicit methods.

Priority 3 — readiness/guard queries:
Replace raw reads with intention-revealing methods where simple.

Examples:

func is_flow_ready() -> bool:
	return _flow_ready

func is_startup_ready() -> bool:
	return _startup_ready

func has_active_spawners() -> bool:
	return _spawners.size() > 0

Do not expose raw arrays/dictionaries unless necessary.

Priority 4 — spawner and route access:
Avoid exposing mutable spawner dictionaries directly if a narrow query is enough.

Prefer methods like:

func get_registered_spawner_cells() -> Array[Vector2i]:
	...

func get_spawner_data(spawner_cell: Vector2i) -> Dictionary:
	...

func has_spawner_route(spawner_cell: Vector2i) -> bool:
	...

But only add what is needed for the current services.

Priority 5 — spawn setup / agent registration:
If AgentSpawnService directly performs manager-private calls for registration or route assignment, prefer explicit manager methods with names that describe the operation.

Examples:

func register_spawned_agent(agent: Node, spawner_cell: Vector2i, agent_kind: StringName) -> void:
	...

func assign_spawned_agent_route(agent: Node, route: PackedVector2Array, garden_id: int) -> void:
	...

Only do this if it reduces private coupling without hiding too much logic.
Do not invent new behavior.

Priority 6 — unclear or high-risk access:
Keep it unchanged and report it.

Do not chase zero _manager._xxx calls.

A successful pass reduces the worst private accesses, not all of them.

Expected target:
Reduce _manager._ references in each target file by roughly 25-50% if safe.

If safe replacements are not obvious, reduce less and report why.

Strict behavior preservation:
Preserve exactly:

- preparation sequence order
- async wait behavior
- dirty/invalidation semantics
- scan/rebuild order
- route cache rebuild behavior
- spawner route initialization
- spawn timing
- spawn scene lookup
- spawn cell fallback
- spawn failure cleanup
- agent registration
- garden route assignment
- debug/telemetry output semantics

Compatibility:
Do not remove existing private methods.
Do not remove wrappers.
Do not rename public-ish methods.
Do not change scene/signal/callable APIs.
Do not delete dead code in this pass.

This is not a pruning pass.

Suggested workflow:

Count _manager._ references in both target files.
Classify each access.
Pick the highest-value unsafe accesses.
Add narrow typed getters/wrappers where useful.
Replace only safe call sites.
Keep unclear/private/debug-only access unchanged.
Re-count _manager._ references.
Report what remains.

Safety checks by reading/searching only:

Verify preparation order is unchanged.
Verify async/await points are unchanged.
Verify no agent status string changed.
Verify spawn fallback and failure paths are unchanged.
Verify route/garden assignment is unchanged.
Verify no queue order changed.
Verify no save/load structure changed.
Verify no signal/Callable/call method was removed.
Verify no scene/editor reference was broken.
Verify strict typing in all changed code.

Output required:

List changed files.
Give before/after _manager._ count for:
building_preparation_controller.gd
agent_spawn_service.gd
List new getters/wrappers added to BuildingManager.
List any new public methods added to services/controllers.
Explain which private accesses were replaced and why.
Explain which private accesses were intentionally retained and why.
Confirm preparation order was preserved.
Confirm spawn behavior was preserved.
Confirm no behavior changes were intended.
Mention remaining production-quality concerns.
Mention manual test scenarios.

Manual test scenarios to suggest:

Start the game and reach day phase.
Start a normal night.
Verify night preparation completes.
Spawn monsters from multiple spawners.
Verify failed/blocked spawn cases do not crash.
Let monsters target plants, eat, and exit.
Run client phase if applicable.
Verify client preparation completes.
Place/remove buildings before night.
Verify navigation invalidation/rebuild still happens.
Verify no new warnings/errors appear