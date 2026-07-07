We are continuing the BuildingManager cleanup.

Goal:
Batch 5 = audit the remaining `scripts/map/building_manager.gd` responsibilities, remove only clearly dead façade/wrapper clutter, and extract one small remaining coherent cluster if it is obvious.

This is a refactor-only pass.
Do not change gameplay behavior.
Do not optimize logic unless required by the refactor.
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
- If unsure, keep the method and report it.

Current context:
Previous batches likely extracted:
- shared preparation orchestration
- agent spawning
- rose counter/shop logic
- some unsafe `_manager._private` coupling
- debug/query/helper logic

Now avoid random “cleaning”.
The priority is to understand what remains and prevent `BuildingManager` from becoming messy again.

Main goal:
Turn `BuildingManager` into a readable façade/coordinator by classifying the remaining methods and pruning only safe clutter.

Before editing:
1. Get current line count of `scripts/map/building_manager.gd`.
2. List all remaining methods in `BuildingManager`.
3. Categorize every method into one of these groups:

```txt
A. Required lifecycle / Godot callbacks
B. External/public compatibility API
C. Thin service wrapper
D. Phase orchestration still genuinely owned by BuildingManager
E. Save/load compatibility
F. Signal/editor/Callable/call entry point
G. Debug/query wrapper
H. Local helper still containing real logic
I. Suspected dead code
J. Unclear / keep
Do not edit until this categorization is done.

Primary task:
Remove or simplify only methods in category I. Suspected dead code, and only when direct search proves they are safe.

Deletion rule:
A method can be deleted only if all are true:

- no direct references in `.gd`
- no method-name string references in `.gd`
- no references in `.tscn` / `.tres` text resources
- not a Godot callback
- not connected to a signal
- not used by Callable
- not likely called through `call()`
- not a save/load method
- not external/public-ish API
- not useful as a compatibility wrapper

If any doubt exists, keep it.

Secondary task:
If, after categorization, there is one obvious small remaining cluster in category H. Local helper still containing real logic, extract it.

Only extract a cluster if:

it has a clear owner;
it is not phase-critical;
it does not touch many unrelated domains;
it can be moved into an existing service or one small new service;
the new file will stay comfortably under 1000 lines;
the diff stays easy to review.

Good extraction candidates:

- purely local coordinate/cell conversion helpers
- small building lookup helper group
- small visual/debug helper group not already moved
- small save helper group, only if save format remains untouched
- small node lookup/cache helper group

Bad extraction candidates:

- day/night flow
- spawn flow
- preparation flow
- garden topology mutation
- retargeting mutation
- client sale flow
- harvest flow
- merchant flow
- save/load format changes
- large mixed helper clusters

If there is no obvious safe cluster, do not extract anything.
In that case, only perform the audit and safe dead-code pruning.

Compatibility wrappers:
Do not delete wrappers just because they are thin.
Thin wrappers are acceptable when they protect scenes, signals, dynamic calls, or external code from refactor churn.

Good wrapper:

func _spawn_agent_from(...) -> Node:
	return _agent_spawn_service.spawn_agent_from(...)

Bad wrapper only if proven unused:

func _old_unused_internal_method(...) -> void:
	return _some_service.old_unused_internal_method(...)

But even then, delete only if search proves safety.

Manager-private coupling:
Do not make private-coupling cleanup the main goal of this pass.
If a tiny safe replacement is obvious, it is allowed.
Otherwise leave it and report it.

Expected result:

BuildingManager has an explicit responsibility map.
Some clearly dead code may be removed.
At most one small coherent helper cluster is extracted.
No risky architecture rewrite.
No gameplay behavior changes.
No new large files.
A future agent can read the report and know what remains.

Suggested workflow:

Count lines in building_manager.gd.
List all method names.
Categorize all methods.
Search references for suspected dead methods.
Delete only proven-safe dead methods.
Optionally extract one small obvious cluster.
Re-search moved/deleted names.
Report remaining categories.

Safety checks by reading/searching only:

Search deleted method names in .gd, .tscn, .tres.
Search moved method names before and after.
Search for string-based calls.
Verify no Godot lifecycle callback was removed.
Verify no signal target was removed.
Verify no save/load method was removed.
Verify no public-ish compatibility API was removed.
Verify strict typing in any new or changed code.
Verify preload/load paths if a new service is created.
Verify setup order if a new service is added.

Output required:

Current building_manager.gd line count before and after.
Method categorization summary.
List changed files.
List deleted methods, with proof/reason.
List moved methods, if any.
Confirm preserved wrappers.
Confirm no behavior changes were intended.
List remaining responsibility clusters in BuildingManager.
Mention manual test scenarios.

Manual test scenarios to suggest:

Start the game and reach day phase.
Start a normal night.
Spawn monsters from multiple spawners.
Let monsters target/eat plants and exit.
Place/remove buildings that affect navigation.
Run client phase.
Save and reload if save state is involved.
Enable debug overlays if available.
Verify no new warnings/errors appear.