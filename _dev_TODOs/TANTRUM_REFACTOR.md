# Task: Make client tantrums look like an RTS army destroying a village

Implement this feature against the provided codebase.

The current tantrum system technically works, but visually and structurally it behaves like many independent clients trying to reach the same point:

* only a small portion of the crowd attacks;
* many clients pile up behind the first attackers;
* clients visibly stand on or beside a valid target without attacking;
* attacks happen in synchronized bursts followed by long inactive gaps;
* retargeting after a building is destroyed is visibly slow.

The intended result is similar to an RTS army destroying a village:

* clients spread across several nearby buildings;
* each building is surrounded by a reasonable number of attackers;
* attackers use the available perimeter instead of stacking on one endpoint;
* attack animations are staggered, so the assault looks continuous;
* clients keep yielding and separating locally while engaged;
* when a target is destroyed, the assault front quickly moves to the remaining buildings.

This is a behavior change, but it must remain simple, deterministic, performant, and easy to maintain.

---

# Verified current causes

Inspect the code before editing, but the following problems are already identified in this codebase.

## `scripts/map/client_tantrum_controller.gd`

The current implementation:

1. Uses `PlayerPlaceableDurabilityService.nearest_target_key()`, so every client independently selects the nearest target without considering how many attackers already selected it.

2. Uses `_best_attack_cell()`, which independently selects the nearest walkable adjacent cell.

   Clients arriving from the same direction therefore tend to choose the same attack cell.

3. Calls:

```gdscript
path_service.path_cells_to_world(path_cells, nav_id, false)
```

Endpoint dispersion is explicitly disabled.

4. Hard-pauses clients while waiting and attacking with:

```gdscript
set_agent_paused(nav_id, true)
```

The native paused branch freezes velocity and skips separation/integration. Attackers therefore become immovable crowd blockers.

5. Uses:

```gdscript
const ATTACK_INTERVAL_SECONDS: float = 3.0
```

The visible lunge lasts only `0.09 + 0.22` seconds. Agents attack for approximately 0.31 seconds and then appear inactive for roughly three seconds.

Because agents enter tantrum and attack at similar times, their attacks become synchronized.

6. Processes exactly one expensive target/path attempt per frame:

```gdscript
return  # one expensive attempt per frame
```

A large crowd can therefore take several seconds to retarget.

## `scripts/map/player_placeable_durability_service.gd`

The single `_revision` is increased for:

* target registration;
* target removal;
* target destruction;
* normal health damage.

Waiting clients use this revision to decide when to retry unreachable targets.

This means every normal hit can wake clients whose navigation situation has not changed.

Health changes and structural target changes must no longer use the same retry revision.

## Native steering

Do not assume a new C++ mode is required.

The existing native steering already lets an unpaused agent with no active path or flow:

* receive agent separation;
* receive static-obstacle repulsion;
* resolve overlap;
* settle when no local force exists.

Therefore, an engaged tantrum client can remain unpaused after its path is detached and still yield to nearby agents.

---

# Required architecture

Create one focused new service:

```txt
scripts/map/client_tantrum_assault_planner.gd
```

Suggested class:

```gdscript
class_name ClientTantrumAssaultPlanner
```

Ownership must be:

## `ClientTantrumAssaultPlanner`

Owns only:

* attack-slot generation;
* per-client slot reservations;
* target load counts;
* global attack-cell occupancy;
* selecting the best available target/slot;
* releasing reservations;
* reservation-availability revision.

It must not own:

* attack timers;
* animation;
* damage;
* client lifecycle;
* pathfinding;
* target health;
* building destruction.

## `ClientTantrumController`

Continues to own:

* hostile client lifecycle;
* waiting/moving/attacking stages;
* target/path requests;
* attack timing;
* attack animation;
* damage calls;
* cleanup.

The controller should instantiate and own the planner directly. Do not add this planner as another major `BuildingManager` responsibility unless genuinely required.

## `PlayerPlaceableDurabilityService`

Continues to own:

* valid destructible targets;
* target records;
* health;
* destruction;
* structural target revision;
* save/load durability.

## `BuildingManager`

Must remain a façade/coordinator.

Do not put assault algorithms or reservation dictionaries into `building_manager.gd`.

## C++ extension

Do not modify the C++ addon for this task.

The existing unpaused/pathless local-avoidance behavior is sufficient.

Do not add tantrum-specific concepts to the generic steering addon.

---

# Required implementation

## 1. Separate target revision from health refresh

In `player_placeable_durability_service.gd`, replace the current mixed-purpose revision behavior.

Add an explicit structural revision:

```gdscript
var _target_revision: int = 0
```

Expose:

```gdscript
func target_revision() -> int
```

Keep the existing method as a compatibility wrapper unless a complete direct and dynamic usage search proves it can safely be removed:

```gdscript
func revision() -> int:
	return target_revision()
```

The target revision must change when selectable target structure changes:

* a target is registered;
* a target is unregistered;
* a target is destroyed;
* targets are cleared;
* targets are restored;
* live target discovery adds targets;
* stale target records are pruned.

The target revision must **not** change when an existing target only loses health.

Normal non-lethal `apply_damage()` must:

* update health;
* refresh the health overlay;
* not increase the target revision.

Separate overlay refreshing from structural revision changes. Use clear helpers such as:

```gdscript
func _refresh_overlay() -> void
func _bump_target_revision_and_refresh() -> void
```

Avoid double-incrementing the structural revision during one destruction/removal operation.

Add a small explicit query that allows the assault planner to enumerate current targets without reaching into private dictionaries. For example:

```gdscript
func target_keys() -> Array[String]
```

Return a copy. Prefer deterministic ordering.

Do not move health or target ownership into the assault planner.

---

## 2. Add attack-slot reservations

Implement `ClientTantrumAssaultPlanner`.

A practical public API is:

```gdscript
func setup(
	manager: BuildingManager,
	durability: PlayerPlaceableDurabilityService
) -> void

func reserve_best_assignment(
	nav_id: int,
	from_world: Vector2,
	rejected_slot_ids: Dictionary
) -> Dictionary

func release(nav_id: int) -> bool

func reservation(nav_id: int) -> Dictionary

func has_valid_reservation(nav_id: int) -> bool

func availability_revision() -> int

func clear() -> void
```

Equivalent names are acceptable if ownership and intent remain obvious.

A successful assignment should contain explicit fields similar to:

```gdscript
{
	"target_key": target_key,
	"attack_cell": attack_cell,
	"slot_id": slot_id,
	"instant_destroy": instant_destroy,
}
```

Do not return loosely defined positional arrays.

### Regular structure slots

For a normal non-instant target:

* inspect the eight neighboring cells around the target cell;
* keep only currently walkable cells;
* create two logical attack slots per valid attack cell;
* use a deterministic slot ID containing the target, cell, and local slot index.

Use a constant:

```gdscript
const SLOTS_PER_ATTACK_CELL: int = 2
```

Two clients may therefore approach the same tile, but endpoint dispersion and native separation should keep their precise positions distinct.

Also enforce a global occupancy limit per world attack cell:

```gdscript
const MAX_RESERVATIONS_PER_ATTACK_CELL: int = 2
```

This limit applies across different neighboring target buildings as well.

Two adjacent buildings must not each reserve two clients into the same shared walkable cell and create a new jam.

### Instant-destroy targets

Preserve existing instant-destroy semantics.

An instant-destroy target should have one logical reservation slot using its target cell, matching the current pathing behavior.

The first client to reach it destroys it and releases the rest of the assault to retarget.

Do not redesign plant destruction.

### Slot cache

Do not regenerate all target slots every frame.

The planner should cache target slots and rebuild the cache only when:

```gdscript
durability.target_revision()
```

changes.

During a cache rebuild:

* discard removed targets;
* discard attack cells that are no longer valid;
* preserve reservations whose target and slot are still valid;
* release invalid reservations safely;
* keep all ordering deterministic.

### Reservation ownership

Maintain explicit state such as:

```gdscript
var _reservation_by_nav_id: Dictionary = {}
var _reserved_nav_id_by_slot_id: Dictionary = {}
var _reservation_count_by_target: Dictionary = {}
var _reservation_count_by_cell: Dictionary = {}
```

Exact names may differ.

Every reservation must have exactly one owner.

A reservation must be released when:

* the hostile client dies or becomes invalid;
* the hostile client is cleared;
* tantrum ends;
* its target is destroyed;
* its slot becomes invalid;
* its path to that slot fails and the slot is rejected;
* the client abandons that target.

No stale reservations may remain after cleanup.

---

## 3. Distribute clients across targets

Do not select only the nearest target.

Select the best available target slot using:

* distance from the client to the attack slot;
* the number of clients already assigned to that target;
* slot availability;
* global attack-cell occupancy;
* deterministic tie-breaking.

Use a simple score expressed in tile-scale units. For example:

```text
score =
	distance_to_slot_in_tiles
	+ assigned_clients_on_target * TARGET_LOAD_PENALTY_TILES
```

Start with:

```gdscript
const TARGET_LOAD_PENALTY_TILES: float = 1.5
```

This is intentionally simple.

The effect should be:

* nearby targets are preferred;
* one target does not absorb the entire crowd;
* several neighboring buildings begin receiving attackers;
* a target may still receive several attackers when it is clearly closer.

Do not introduce:

* target-type priorities;
* reservoir priority;
* wall priority;
* damage-based priorities;
* a generic utility-AI framework;
* a behavior tree;
* a new event bus.

All valid destructible targets remain equal except for distance, available perimeter, and current assigned load.

---

## 4. Use reserved cells for pathing

Remove the independent `_best_attack_cell()` decision from the controller.

The planner assignment must provide the attack cell.

Compute the A* path to that reserved attack cell.

Convert the path with endpoint dispersion enabled:

```gdscript
path_service.path_cells_to_world(path_cells, nav_id, true)
```

Do not leave the third argument as `false`.

When a path fails:

1. release that reservation;
2. add that exact `slot_id` to the client’s rejected slots;
3. queue another budgeted assignment attempt;
4. do not reject the entire target when another side may still be reachable.

Use per-client rejected slot IDs rather than only rejected target keys.

Clear rejected slots when the structural target revision changes.

Do not clear them merely because another reservation becomes available.

---

## 5. Do not hard-pause waiting or attacking clients

Tantrum clients must remain natively unpaused during:

* waiting for target assignment;
* moving;
* attacking.

Waiting clients have no active path or flow, so the native addon will only apply local separation and overlap correction.

This is preferable to turning them into immovable statues.

When a moving client enters attack range:

1. detach its completed/current A* path;
2. keep native pause disabled;
3. retain its assault reservation;
4. enter `STAGE_ATTACKING`.

While attacking, the body remains under native local avoidance. The existing sprite-offset tween remains visual-only.

Do not add manual position changes in GDScript.

Do not directly move the client body during the lunge.

Do not change the generic C++ steering implementation.

---

## 6. Recover when separation pushes an attacker away

Because engaged clients are no longer hard-paused, local separation may push one slightly outside attack range.

Handle this explicitly.

After an attack animation has completed:

* if the target is still valid and the client remains in attack range, continue its attack cadence;
* if it is outside attack range but its reservation is still valid, compute a budgeted path back to its reserved attack cell;
* if that path fails, reject and release the slot, then select another assignment.

Do not release a valid reservation merely because the client was briefly pushed.

Do not continuously calculate a path every frame.

A currently playing attack tween must not be interrupted by knockback or separation. Preserve the existing rule that knockback does not interrupt an attack already in progress.

After that attack finishes, normal range/path correction may occur.

---

## 7. Make the assault visually continuous

Replace the synchronized three-second attack cadence.

Preserve approximately the current per-attacker DPS rather than accidentally tripling building destruction speed.

Current approximate cadence:

```text
5 damage / (3.0 cooldown + 0.31 animation)
≈ 1.51 damage per second
```

Use:

```gdscript
const ATTACK_DAMAGE: int = 3
const ATTACK_INTERVAL_MIN_SECONDS: float = 1.45
const ATTACK_INTERVAL_MAX_SECONDS: float = 1.85
```

The animation remains approximately 0.31 seconds, producing roughly comparable average DPS.

Each client must receive:

* a deterministic interval between the minimum and maximum;
* a deterministic initial phase delay between zero and its interval.

Base this on `nav_id`.

Do not use the global random-number generator.

Do not give every attacker an initial timer of zero.

The same client/nav ID should produce stable timing during one run.

A simple integer hash is sufficient. Do not create a generic deterministic-random utility framework.

The expected visual result is that, with several attackers, one client is usually lunging while others are returning or preparing their next attack.

Preserve:

* damage application at the lunge contact callback;
* the current visual-only sprite tween;
* damage numbers;
* attacks already in progress not being interrupted by knockback.

Do not add damage-over-time or per-frame damage.

---

## 8. Improve retarget throughput without unbounded work

Replace the exact one-path-attempt-per-frame behavior with a small fixed budget:

```gdscript
const MAX_RETARGET_PATH_ATTEMPTS_PER_FRAME: int = 4
```

Process up to four queued assignment/path attempts per frame.

Skip stale queue entries without consuming unnecessary work where practical.

Do not process the full queue in one frame.

Do not add a generic job scheduler.

Target/slot scoring is cheap and may happen as part of an assignment attempt. A* pathfinding remains bounded by this per-frame limit.

When a building is destroyed, affected clients should begin redistributing over the following few frames rather than taking several seconds.

---

## 9. Distinguish structural and reservation availability changes

Waiting clients need to wake for two different reasons:

1. Target structure changed.
2. A previously occupied attack slot became available.

Store both revisions in waiting state, for example:

```gdscript
"idle_target_revision": -1,
"idle_availability_revision": -1,
```

Use:

```gdscript
durability.target_revision()
planner.availability_revision()
```

The planner availability revision should increase when availability increases, especially when:

* a reservation is released;
* invalid cached reservations are removed;
* planner state is cleared.

It does not need to increase when a new reservation consumes a free slot.

When only reservation availability changes:

* retry assignment;
* preserve rejected slots.

When the structural target revision changes:

* retry assignment;
* clear rejected slots because topology or available targets may have changed.

Normal target health damage must wake neither category.

---

# Required lifecycle cleanup

Audit all tantrum cleanup paths.

Reservations and attack visuals must be cleaned correctly in:

* `clear_hostile(nav_id)`;
* `end()`;
* invalid-hostile pruning;
* target destruction;
* path failure;
* client death;
* controller reset;
* failed assignment;
* any existing hostile-removal callback.

`end()` must:

* kill active tweens;
* restore sprite offsets;
* unpause any native agents defensively;
* clear hostile dictionaries;
* clear retarget queues;
* clear all planner reservations;
* hide the tantrum alert.

Do not leave a reservation owned by a deleted nav ID.

---

# Behavior that must remain unchanged

Do not alter unrelated tantrum rules.

Preserve all of the following:

* tantrum starts only under the existing zero-rose-availability condition;
* all eligible clients become hostile;
* clients with a rose do not join;
* all generic player-built destructible target types remain valid;
* the reservoir remains a generic target with no special priority;
* plants retain instant-destroy behavior;
* building health and destruction remain owned by `PlayerPlaceableDurabilityService`;
* structure destruction still uses the authoritative no-refund removal path;
* plant destruction still uses the authoritative plant-consumption path;
* tantrum does not create debris beyond the behavior already defined by the existing destruction systems;
* damage is applied at the attack contact callback;
* knockback does not interrupt an attack already in progress;
* no hostile attack stage is serialized;
* saving remains blocked during tantrum with the existing `NO SAVE DURING TANTRUM` behavior;
* client damageability and death behavior remain unchanged;
* game-over/reservoir-destruction behavior remains unchanged;
* no new target means the existing level invariant/game-over path still applies;
* normal clients not involved in tantrum continue to use their existing processing.

Do not perform unrelated cleanup.

---

# Expected changed files

Expected:

```txt
scripts/map/client_tantrum_assault_planner.gd
scripts/map/client_tantrum_controller.gd
scripts/map/player_placeable_durability_service.gd
```

`building_manager.gd` should ideally not need gameplay logic changes.

A small setup/getter change is acceptable only if clearly necessary, but the planner should preferably be owned directly by `ClientTantrumController`.

Do not modify:

```txt
extensions/flowfield/**
```

for this task.

If more files become necessary, report why before expanding scope.

---

# Acceptance criteria

The implementation is complete only when all of these are structurally true:

1. No two clients own the same logical attack slot.

2. No attack cell exceeds its global reservation capacity.

3. Clients distribute across several nearby targets once one target’s useful perimeter becomes loaded.

4. Clients approach different attack cells around a structure.

5. Path endpoint dispersion is enabled.

6. Waiting and attacking clients are not hard-paused.

7. Engaged clients continue receiving native separation.

8. Clients pushed out of range return to their reserved attack position or safely select another slot.

9. Attack animation phases are deterministic and staggered.

10. Approximate per-client DPS remains close to the old implementation.

11. Retarget pathfinding remains bounded per frame.

12. Normal health damage does not wake unreachable clients.

13. Structural target changes do wake waiting clients.

14. Released slots wake clients waiting because all useful positions were occupied.

15. Destroying one target releases all reservations connected to it.

16. Ending tantrum leaves no attack tween, paused hostile, queue entry, or reservation behind.

17. The implementation does not introduce tantrum-specific C++ logic.

18. The implementation does not add a generic combat/AI framework.

---

# Manual test scenarios to include in the final report

Do not run these tests. The user runs them manually.

Provide at least these scenarios:

## Distribution

* Build several walls, counters, lamps, turrets, and a reservoir near one another.
* Trigger tantrum with 50–100 clients.
* Verify clients distribute across multiple targets.
* Verify they occupy several sides of structures.
* Verify one endpoint does not receive the entire crowd.

## Continuous attack appearance

* Watch at least eight clients attacking.
* Verify lunges are staggered.
* Verify there is no repeated army-wide three-second inactive gap.

## Local crowd behavior

* Observe clients at a crowded building.
* Verify engaged attackers can yield or shuffle.
* Verify they are not immovable blockers.
* Verify clients pushed outside range return to their reserved position.

## Target destruction

* Let a low-health building be destroyed.
* Verify its attackers redistribute within a small number of frames.
* Verify no long queue-induced freeze.
* Verify no stale attackers continue damaging the deleted target.

## Narrow access

* Place a target with only one accessible side.
* Verify only the available slots are used.
* Verify surplus clients select other targets or wait without stacking into one exact position.

## Shared perimeter cells

* Place structures directly beside one another.
* Verify their reservations do not overload the same shared attack cell.

## Instant targets

* Include destructible plants.
* Verify one client reaches and instantly destroys each plant using existing plant destruction semantics.
* Verify other clients retarget correctly.

## Knockback

* Knock an attacking hostile during its lunge.
* Verify the current attack completes.
* Verify the client returns to range afterward if displaced.

## Cleanup

* Kill hostile clients while moving, waiting, and attacking.
* End the tantrum.
* Verify no paused clients, stuck tweens, stale reservations, or warnings remain.

## Performance

* Trigger tantrum with hundreds of clients.
* Watch existing frame and lag telemetry.
* Verify pathfinding is still bounded and no full-agent/full-target work is added every frame.

## Regression

* Start a normal day.
* Start a normal night.
* Verify normal monster navigation remains unchanged.
* Verify building placement/removal still works.
* Verify target health overlay still updates after every hit.
* Verify saving is still rejected during tantrum.
* Verify save/load outside tantrum remains unchanged.

---

# Mandatory implementation report

At the end, report:

1. Changed files.
2. The exact responsibility of the new assault planner.
3. How attack slots and global cell capacity work.
4. How target load affects assignment.
5. How reservations are released.
6. How clients remain locally mobile while attacking.
7. Old versus new approximate per-client DPS.
8. The retarget budget used.
9. How target revision was separated from health refresh.
10. Compatibility wrappers retained.
11. Any private coupling retained.
12. Any production-quality concern found.
13. Manual test scenarios.
14. Explicit confirmation that Godot, compilation, tests, and builds were not run.

Do not claim that runtime behavior was verified because the user performs manual testing.

---

# Mandatory quality rules

Follow these rules for the entire task.

# AGENTS.md

For every task: do not guess. Ask if unsure. Dedicated ownership for files.

Prefer simple, readable, production-oriented code.

The goal is not maximum abstraction. The goal is code that is easy to understand, easy to modify, hard to break, and not likely to grow into huge tangled files.

## Test / build policy

Do not run Godot, tests, compilation, export, or build commands.

The user runs tests manually.

Only run Godot if the user explicitly authorizes it in the current conversation.

Godot executable, only if authorized:

```txt
C:\GAMETOOLS\godot
```

## GDScript typing

Godot/GDScript strict typing is enabled.

When editing GDScript, avoid `:=` inference for:

* numeric expressions;
* Dictionary / Array values;
* signal or `call()` returns;
* mixed `int` / `float` math;
* nullable or dynamic values.

Prefer explicit local types:

```gdscript
var count: int = 0
var pos: Vector2i = Vector2i.ZERO
var speed: float = 0.0
var data: Dictionary = {}
```

Cast deliberately when needed.

Do not rely on implicit Variant behavior when the value type matters.

## Production-quality objective

Every change should move the code toward production quality.

Production quality means:

* clear ownership of state;
* small focused files;
* explicit responsibilities;
* predictable control flow;
* limited coupling;
* readable names;
* no hidden side effects;
* no dead compatibility layers unless needed;
* no speculative architecture;
* no giant files;
* no god objects;
* no “temporary” hacks without warning.

If a requested feature or refactor starts making the code messy, stop and report it before continuing.

Report clearly when:

* a file is becoming too large;
* a method is doing too many things;
* a manager/controller is becoming a god object;
* logic is being duplicated;
* state ownership is unclear;
* services are calling too deeply into each other;
* the clean solution would require a larger refactor.

## Simplicity rule

Do the simplest thing that keeps the code maintainable.

Do not over-engineer.

Avoid:

* generic frameworks;
* speculative interfaces;
* abstract base classes without immediate need;
* service locators;
* unnecessary event buses;
* premature plugin-style architecture;
* splitting tiny logic into many tiny files;
* moving code just to move code.

Prefer:

* one focused service/controller per real responsibility;
* clear method names;
* direct readable code;
* small helper methods when they reduce repetition;
* explicit data flow;
* local refactors that make the current task safer.

If there are two options, prefer the one a future coding agent can understand quickly.

## File size and responsibility limits

Avoid creating or growing huge files.

Guidelines:

```txt
0-300 lines: good
300-600 lines: acceptable if cohesive
600-900 lines: warning zone
900+ lines: justify before adding more
1000+ lines: do not grow; split by responsibility
```

If a file is already large, do not add new responsibility to it unless there is no safer option.

If a method grows beyond roughly 80–120 lines, check whether it should be split.

If a manager is mostly coordinating many unrelated systems, move new behavior into a focused controller/service instead of adding more logic to the manager.

## Anti-noodle architecture rules

Do not create code where everything knows about everything.

Avoid these patterns:

```gdscript
_manager._some_private_method()
_manager._some_private_dictionary
_manager._some_private_flag
```

from extracted services unless there is no safe alternative.

Prefer:

* explicit public wrappers with intention-revealing names;
* direct calls to the owning service;
* small query methods for read-only access;
* keeping state mutations inside the owner of that state.

Bad:

```gdscript
_manager._gardens[garden_id]
_manager._rebuild_everything()
_manager._some_random_private_flag = true
```

Better:

```gdscript
_manager.get_garden_cells(garden_id)
_manager.request_navigation_rebuild()
_manager.mark_navigation_topology_dirty()
```

If private coupling is kept, mention it in the final report.

## State ownership

Every important piece of state should have one clear owner.

Before adding or moving state, identify the owner.

Examples:

* navigation invalidation state should live in an invalidation controller;
* garden topology state should live in a garden topology service;
* spawning orchestration should live in a spawn service;
* runtime frame orchestration should live in a runtime tick controller;
* UI selection state should stay with UI/state controllers;
* save/load compatibility can stay as façade wrappers if needed.

Do not duplicate state across manager and service unless required for compatibility.

Do not move ownership of major state during a feature task unless the task is specifically a refactor.

## Manager / façade rule

Large manager files should be treated as façades/coordinators, not dumping grounds.

A manager may contain:

* Godot lifecycle callbacks;
* scene wiring;
* exported node references;
* setup of services/controllers;
* compatibility wrappers;
* small orchestration entry points.

A manager should not contain:

* large gameplay algorithms;
* long frame loops;
* spawning internals;
* pathfinding internals;
* save format transformations mixed with gameplay;
* debug systems mixed with gameplay;
* unrelated helper clusters;
* new feature logic that belongs to a domain service.

When adding a feature, first look for the correct existing service/controller.

If no owner exists, create a focused one.

Do not create a new service if the logic clearly belongs to an existing cohesive owner.

## Refactor policy

Refactors must be behavior-preserving unless the user explicitly asks for behavior changes.

Before refactoring:

1. Identify the current owner of the logic.
2. Identify who calls it.
3. Search for dynamic usage: `call()`, `Callable`, signals, scene references, string method names.
4. Preserve wrappers when unsure.
5. Move one coherent responsibility at a time.

Do not combine risky refactors with feature work unless necessary.

Do not perform broad cleanup while implementing a feature.

If cleanup is needed first, report the reason and propose a small focused cleanup.

## Feature implementation policy

When asked to add a feature:

1. Find the smallest correct owner for the feature.
2. Reuse existing systems where they fit.
3. Avoid adding logic to large managers.
4. Keep behavior localized.
5. Keep data flow explicit.
6. Add configuration only if the feature needs it now.
7. Avoid speculative extension points.
8. Warn if the feature requires touching too many systems.

A good feature change should usually have:

* one main owner;
* a small number of call sites;
* clear state ownership;
* no hidden cross-service mutation;
* no large unrelated rewrites.

## Compatibility wrappers

Do not delete wrappers casually.

Keep wrappers when they may be used by:

* Godot signals;
* scenes;
* editor wiring;
* `Callable`;
* `call()`;
* saved resources;
* external nodes;
* debug tools;
* existing public-ish APIs.

Delete a wrapper only if direct search proves it is unused and not dynamically referenced.

When unsure, keep it and report it.

## Debug and telemetry

Debug logic should not be mixed into core gameplay when avoidable.

Prefer focused debug/query/telemetry services for:

* debug overlays;
* route inspection;
* garden visualization;
* flow-field labels;
* lag reporting;
* diagnostic summaries.

Debug code must not change gameplay behavior.

Do not remove debug warnings unless they are obsolete or misleading.

## Performance policy

Performance matters.

The game may have hundreds of agents active.

Avoid per-frame work that scales badly with:

* all agents;
* all map cells;
* all buildings;
* all gardens;
* all spawners.

Before adding per-frame loops, check whether the work can be:

* event-driven;
* queued;
* cached;
* limited per frame;
* scoped to dirty/affected objects only.

Do not optimize by making the code unreadable.

If a clean implementation may be expensive, warn the user and explain the tradeoff.

## Reporting requirements

At the end of every coding task, report:

1. Changed files.
2. What moved or changed.
3. What behavior was intentionally preserved.
4. Any compatibility wrappers kept.
5. Any private coupling or messy area intentionally retained.
6. Any production-quality concern noticed.
7. Suggested manual test scenarios.

If the task risks creating noodles, explicitly say so and explain the safer alternative.

## Manual testing

The user runs tests manually.

Suggest relevant manual tests, but do not run them.

For gameplay/navigation changes, suggest tests such as:

* start a normal day;
* start a normal night;
* spawn monsters from multiple spawners;
* let monsters target, eat, and exit;
* place/remove buildings;
* verify pathing/navigation invalidation;
* verify client phase if affected;
* verify save/load if affected;
* verify debug overlays if affected;
* check for new warnings/errors.

## Final rule

Prefer code that is boring, explicit, and easy to follow.

Do not chase perfect architecture.

Do not create noodles.

If the clean solution is bigger than the task, warn the user before making the code worse.
