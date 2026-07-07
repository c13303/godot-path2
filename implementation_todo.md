We are continuing the BuildingManager cleanup.

Goal:
Batch 4 = reduce `scripts/map/building_manager.gd` façade/wrapper bloat and move remaining debug/query/helper responsibilities into focused owners, while preserving behavior exactly.

This is a refactor-only pass.
Do not change gameplay behavior.
Do not optimize logic unless required by the extraction.
Do not run Godot, tests, export, build, or compilation commands.

Project rules:
- Godot/GDScript strict typing is enabled.
- Avoid `:=` inference for numeric expressions, Dictionary/Array values, signal/call returns, mixed int/float math, nullable values, and dynamic values.
- Prefer explicit local types.
- Keep files readable.
- Do not create or grow 1000+ line files.
- Do not create generic abstractions without immediate use.
- Do not perform a broad rewrite.
- Preserve public/wrapper methods unless direct search proves removal is safe.
- If unsure, keep the wrapper and report it.

Current context:
Earlier cleanup batches likely extracted:
- shared night/client preparation into `BuildingPreparationController`
- agent spawning into `AgentSpawnService`
- rose counter/shop logic into `RoseCounterService` or `CounterStockManager`
- some unsafe `_manager._private` coupling was reduced

Now `BuildingManager` should be treated as a façade/coordinator only.
This pass should remove remaining low-risk implementation pockets that do not belong in the façade.

Before editing:
1. Inspect `scripts/map/building_manager.gd`.
2. Get the current line count.
3. Identify remaining method clusters by responsibility.
4. Do not touch core gameplay flows already extracted unless needed for wiring.
5. Do not move state ownership unless small and obvious.
6. Prefer moving coherent clusters, not individual random methods.

Primary target:
Move remaining debug/query/helper responsibilities out of `BuildingManager`.

Likely clusters to inspect:

```txt
debug
telemetry
path debug
garden debug
flow debug
agent debug
overlay
route debug
navigation query
path query
cell query
building query
helper

Likely existing destination:
If BuildingDebugTelemetry or similar already exists, extend it carefully.

Possible new focused files, only if needed:

scripts/map/building_debug_query_service.gd
scripts/map/building_navigation_query_service.gd

Do not create both unless both are clearly needed.

Preferred responsibility split:

BuildingDebugQueryService
Owns debug-only helper methods, especially methods used by overlays, labels, telemetry, debug prints, or editor/debug visualization.

Possible responsibilities:

expose garden/route/debug label data
debug path queries
debug flow-field query wrappers
debug cell summaries
debug-only route inspection
debug-only telemetry helpers

It must not own gameplay state.

BuildingNavigationQueryService
Owns read-only navigation/map/path query helpers if they are used by gameplay code and are not merely debug.

Possible responsibilities:

read-only walkability queries
read-only route lookup helpers
read-only cell-to-room/cell-to-garden helpers
read-only target/path inspection helpers

It must not own rebuild orchestration.
It must not own invalidation.
It must not own spawning.
It must not own phase transitions.

If a method mutates state, do not put it in a query service unless the mutation is purely debug-cache maintenance and clearly documented.

Compatibility rule:
Keep thin wrappers in BuildingManager for any method that may be used by:

other scripts
scenes
signals
Callable
call()
editor wiring
debug UI
saved references

Wrapper style:

func debug_some_existing_method(...) -> SomeType:
	return _building_debug_query_service.debug_some_existing_method(...)

or:

func get_some_navigation_query(...) -> SomeType:
	return _building_navigation_query_service.get_some_navigation_query(...)

Only delete wrappers if direct search proves:

no references exist;
the method name is not used dynamically;
it is not public-ish API;
it is not likely referenced by scenes/editor/debug overlay.

When in doubt, keep the wrapper.

Important:
Do not make this a “delete wrappers” pass.
This is a responsibility extraction pass.
Wrapper deletion is allowed only when obviously safe.

Extraction guidance:
Good candidates to move:

methods that only format/debug/report current state
methods that only read data and return a value
methods that are only used by debug overlays/telemetry
repeated query helpers that make BuildingManager hard to scan
helper methods whose domain owner already exists

Bad candidates to move in this pass:

day/night transition flow
spawning flow
preparation flow
counter/shop flow
garden topology mutation
retarget mutation
invalidation mutation
save/load compatibility
signal entry points
exported/editor-facing methods
methods with unclear dynamic call usage

Manager-private coupling:
It is acceptable for the new query/debug service to call some manager wrappers or manager-private methods if eliminating that coupling would require a risky rewrite.

However:

Prefer existing public wrappers created in Batch 3.
Do not introduce new direct mutable state access if avoidable.
Do not worsen coupling.
Report any retained direct private coupling.

Expected result:

BuildingManager loses another coherent block of implementation code.
Debug/query/helper code has a clearer owner.
BuildingManager remains a compatibility façade for methods likely called externally.
No new file over 1000 lines.
No gameplay behavior changes.
No broad architecture rewrite.

Suggested workflow:

Categorize remaining BuildingManager methods into groups:
façade/wrapper
phase orchestration
debug/query/helper
state ownership
save/load
unknown/dynamic risk
Pick one or two clear debug/query/helper clusters.
Move those clusters into a focused service.
Add setup in _ready() if a new service is created.
Replace internal calls with service calls.
Keep compatibility wrappers where needed.
Search references before deleting anything.
Report what remains in BuildingManager.

Safety checks by reading/searching only:

Search all moved method names before and after moving.
Search for method-name strings in .gd, .tscn, .tres, .res text resources where possible.
Verify no signal/Callable/call/editor references were broken.
Verify all new files have correct preload/load paths.
Verify _ready() setup order is correct.
Verify strict typing on all new locals and returns.
Verify no debug overlay/debug UI method disappeared.
Verify save/load structure is untouched.
Verify no gameplay method signature changed.

Output required:

List changed files.
Current line count of building_manager.gd before and after.
Explain which debug/query/helper logic moved.
Confirm which wrappers were preserved.
Confirm whether any wrappers were removed, with reason.
Mention any intentionally retained manager-private coupling.
Mention what responsibility clusters still remain in BuildingManager.
Mention manual test scenarios.

Manual test scenarios to suggest:

Start a normal night.
Spawn monsters from multiple spawners.
Let monsters target/eat plants and exit.
Place/remove buildings that trigger navigation invalidation.
Open/enable any debug overlays used for gardens/routes/flow/pathing.
Verify debug labels/telemetry still display correctly.
Run client phase if applicable.
Verify no new warnings/errors appear.