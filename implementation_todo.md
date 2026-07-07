We are continuing the BuildingManager cleanup.

Goal:
Batch 12 = production-readiness audit and small stabilization fixes after the previous coupling-cleanup batches.

This is primarily an audit/hardening pass.
Do not perform broad extraction.
Do not change gameplay behavior.
Do not optimize logic unless required to fix an obvious architecture or safety issue.
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
- If unsure, keep the existing code and report it.

Current context:
Many BuildingManager responsibilities have been extracted or cleaned:
- preparation orchestration
- runtime ticking
- agent spawning
- rose counter/shop logic
- debug/query helpers
- some private manager coupling in runtime/retarget/navigation/preparation/spawn/spawner route/garden topology

Now stop automatic extraction and verify the resulting architecture.

Main objective:
Decide whether the current code is production-readable or still at risk of becoming noodle code.

Before editing:
1. Inspect `scripts/map/building_manager.gd`.
2. Inspect all extracted services/controllers under `scripts/map/` that are connected to BuildingManager.
3. Get line counts for the important files.
4. Count `_manager._` private accesses per extracted service.
5. List all services/controllers initialized by `BuildingManager`.
6. Identify which files are close to or above the warning zone.

Warning thresholds:

```txt
0-300 lines: good
300-600 lines: acceptable if cohesive
600-900 lines: warning zone
900+ lines: high warning
1000+ lines: do not grow; split by responsibility

Do not edit before completing this audit.

Audit categories:
For each relevant file, classify it as one of:

A. Clean focused owner
B. Acceptable coordinator/façade
C. Too coupled to BuildingManager
D. Too large but still cohesive
E. Too large and mixed responsibility
F. Wrapper-heavy but acceptable for compatibility
G. Noodle risk / should be next refactor target
H. Unknown / needs human decision

Primary task:
Produce a concise production-readiness report inside the final output.

Secondary task:
Make only small, obvious stabilization edits if they are clearly safe.

Allowed small edits:

add missing boundary comments to coordinator files
rename no methods unless absolutely safe
add a tiny typed getter/wrapper if it removes repeated unsafe private access
replace one or two obviously unsafe direct private service accesses with existing getters
move no large logic blocks
delete no wrappers unless proven dead and unrelated
add no new architecture layer

Do not:

extract another large service
create a generic context/service locator
rewrite ownership
change route/garden/spawn/runtime behavior
change save/load format
delete compatibility wrappers casually
chase zero _manager._ calls
grow any file past 1000 lines

Specific things to check:

BuildingManager role
Verify that BuildingManager is mostly:
Godot lifecycle callbacks
scene wiring
service setup
compatibility wrappers
small orchestration entry points

Flag any remaining large gameplay logic clusters.

Runtime ticking
Verify BuildingRuntimeTickController is only orchestration.
It should preserve update order and delegate domain logic.

Flag any gameplay algorithm inside it.

Garden/navigation cluster
Inspect:
garden_retarget_controller.gd
agent_navigation_phase_controller.gd
garden_topology_service.gd
spawner_route_service.gd
garden_access_resolver.gd
building_path_service.gd

Flag:

unclear state ownership
direct mutable state sharing
excessive manager-private access
circular controller dependencies
route/garden logic duplication
Preparation/spawn cluster
Inspect:
building_preparation_controller.gd
agent_spawn_service.gd
spawn_tick_controller.gd
spawn_playlist_config_service.gd
spawner_garden_selection_service.gd

Flag:

duplicated spawner/route/garden lookup logic
unclear spawn failure handling ownership
direct mutable manager state access
overgrown orchestration
Counter/client/harvest cluster
Inspect:
rose/counter service if present
counter_stock_manager.gd
morning_harvest_controller.gd
client_sale_controller.gd
seed_merchant_controller.gd

Flag:

counter stock state duplication
save/load format risk
animation helpers in wrong owner
client/harvest/merchant coupling
Debug/telemetry
Inspect debug/query/telemetry services.

Flag:

debug logic affecting gameplay
debug code mixed into domain services
obsolete warnings
heavy per-frame debug work
Performance-sensitive loops
Look for per-frame loops over:
all agents
all map cells
all gardens
all spawners
all buildings

Flag any loop that appears newly introduced or suspicious.
Do not optimize it in this pass unless the fix is trivial and behavior-preserving.

AGENTS.md compliance
Verify recent code follows:
no giant files
no new god objects
no over-abstracted generic framework
explicit typing
focused ownership
behavior-preserving refactor style

Expected result:

A clear architecture health report.
At most small stabilization edits.
No broad behavior changes.
No new large files.
A clear recommendation for whether more cleanup is needed.

If the code is good enough:
Say so.
Recommend stopping broad cleanup and switching to feature work.

If the code is not good enough:
Identify the single best next target.
Do not propose five simultaneous refactors.

Output required:

List changed files, if any.
Give line counts for key files.
Give _manager._ private access counts per major extracted service.
Classify major files using the audit categories.
Say whether the architecture is production-readable now.
Say whether noodle risk is low, medium, or high.
List the top 3 remaining risks.
List any small stabilization edits made.
If no edits were made, say that this was intentionally audit-only.
Recommend either:
stop broad cleanup and resume feature work; or
one single next cleanup target.
Mention manual test scenarios if any code changed.

Manual test scenarios if code changed:

Start the game and reach day phase.
Start a normal night.
Spawn monsters from multiple spawners.
Let monsters target plants, eat, and exit.
Place/remove buildings.
Verify navigation invalidation/rebuild still happens.
Run client phase if applicable.
Verify save/load if touched.
Enable debug overlays/telemetry if touched.
Verify no new warnings/errors appear.