# Pass 1 — Complete preparation ownership and asynchronous rebuild cancellation

Refactor the current preparation system so that `BuildingPreparationController` becomes the authoritative owner of night/client preparation state, while a small focused work gate owns cancellation of shared budgeted topology work.

Read `AGENTS.md` first and follow it strictly.

Do not run Godot, tests, compilation, export, or build commands. The user performs runtime testing manually.

This is a behavior-preserving architectural refactor. Do not change gameplay rules, navigation algorithms, flow-field behaviour, spawn timing, client rules, save format, or phase order.

## Main objective

The current extraction is incomplete.

`building_preparation_controller.gd` says:

```gdscript
# This is an orchestration-only extraction: domain state and underlying rebuild
# operations still live on BuildingManager and its existing services.
```

That split is no longer acceptable.

Currently, `BuildingManager` still owns:

```gdscript
_night_preparing
_client_preparing
_night_preparation_ready
_night_preparation_token
```

Meanwhile:

* `BuildingPreparationController` runs the preparation sequence;
* `BuildingInvalidationController` advances the same token;
* `GardenTopologyService` checks the token through private manager calls;
* `SpawnerRouteService` checks the token through private manager calls;
* `SpawnTickController` directly reads `_night_preparation_ready`;
* `BuildingRuntimeTickController` reads the private budget helper;
* save/load and dev-skip manipulate the same state directly.

This creates split ownership and makes asynchronous cancellation difficult to reason about.

After this pass:

```text
BuildingPreparationController
    owns night/client preparation lifecycle state

BuildingPreparationWorkGate
    owns the generation token shared by all budgeted topology work

BuildingInvalidationController
    owns runtime rebuild active/progress state

BuildingManager
    only starts/cancels preparation, reacts to completion,
    and exposes compatibility wrappers
```

## Scope

Inspect at minimum:

```text
scripts/map/building_manager.gd
scripts/map/building_preparation_controller.gd
scripts/map/building_invalidation_controller.gd
scripts/map/building_navigation_sync_service.gd
scripts/map/garden_topology_service.gd
scripts/map/spawner_route_service.gd
scripts/map/building_runtime_tick_controller.gd
scripts/spawning/spawn_tick_controller.gd
scripts/map/agent_save_service.gd
scripts/map/seed_merchant_controller.gd
scripts/map/client_sale_controller.gd
scripts/map/ARCHITECTURE.md
```

Search the complete repository for:

```text
_night_preparing
_client_preparing
_night_preparation_ready
_night_preparation_token
_night_preparation_is_current
_night_preparation_budget_us
advance_preparation_token
run_night_preparation
run_client_preparation
finish_night_preparation_success
finish_client_preparation_success
abort_client_preparation
is_night_preparation_ready
night_preparation_budget_ms
```

Also search dynamic usage:

```text
call(
Callable
has_method
connect
scene references
string method names
```

Do not delete compatibility methods until direct and dynamic searches prove they are unnecessary.

# Part A — Add one shared budgeted-work gate

Create:

```text
scripts/map/building_preparation_work_gate.gd
```

Use a similarly precise name only if there is a clearly better existing naming convention.

Suggested class:

```gdscript
extends RefCounted
class_name BuildingPreparationWorkGate
```

It owns only:

```text
- one monotonically increasing generation/token
- an optional current work-purpose name for diagnostics
```

It must not:

```text
- know GameState
- know BuildingManager
- perform rebuilding
- own readiness
- own runtime-rebuild progress
- call gameplay services
```

Required API semantics:

```gdscript
func begin_work(purpose: StringName) -> int
```

Claims a fresh token and invalidates every previously running budgeted operation.

```gdscript
func cancel_current_work() -> int
```

Advances the token and clears the diagnostic purpose.

```gdscript
func is_current(token: int) -> bool
```

Returns true only when the token is the latest claimed generation.

```gdscript
func finish_work(token: int) -> void
```

Clears the current diagnostic purpose only when `token` is still current.

Optional read-only diagnostic queries are acceptable:

```gdscript
func current_purpose() -> StringName
func current_token() -> int
```

Do not create an abstract task framework, generic scheduler, cancellation-token inheritance hierarchy, or signal bus.

This is a small, direct generation guard for existing budgeted coroutines.

# Part B — Make `BuildingPreparationController` the state owner

Move these states out of `BuildingManager`:

```gdscript
_night_preparing
_client_preparing
_night_preparation_ready
```

`BuildingPreparationController` must own them.

Prefer one explicit preparation mode instead of two unrelated booleans:

```gdscript
enum PreparationMode {
    NONE,
    NIGHT,
    CLIENT,
}
```

Equivalent strongly typed state is acceptable.

The controller should own:

```text
- current preparation mode
- active preparation token
- night preparation readiness
- preparation budget configuration
- night/client preparation sequence
- cancellation and stale-run handling
```

Required read-only queries:

```gdscript
func is_night_preparing() -> bool
func is_client_preparing() -> bool
func is_preparing() -> bool
func is_night_ready() -> bool
func budget_us() -> int
```

The queries must not report a stale preparation as active after its work token has been superseded.

For example, `is_night_preparing()` should require both:

```text
mode == NIGHT
and active token is still current
```

## Beginning preparation

Expose explicit operations equivalent to:

```gdscript
func begin_night_preparation() -> int
func begin_client_preparation() -> int
```

Each operation must:

1. claim a new work token with a clear purpose;
2. set the appropriate preparation mode;
3. store the active token;
4. mark night readiness false;
5. return the token.

The actual asynchronous sequence may remain a separate method:

```gdscript
func run_night_preparation(token: int) -> bool
func run_client_preparation(token: int) -> bool
```

Normal mode transitions may still defer the call by one frame through a thin manager wrapper.

Save/load restoration must be able to begin preparation and `await` the same authoritative sequence directly.

Do not maintain separate normal-play and save/load implementations.

## Cancellation

Expose one explicit cancellation/reset path.

It must:

* invalidate the current work token;
* clear the active preparation mode;
* clear readiness unless restoring an already prepared night;
* prevent stale coroutines from publishing success later.

Do not manually increment a token in several manager methods.

## Completion

On successful night preparation:

1. verify the work token is still current;
2. clear the active preparation mode;
3. mark night readiness true;
4. finish the work-gate entry;
5. invoke the existing night-preparation-success follow-up.

On successful client preparation:

1. verify the token is current;
2. clear the active preparation mode;
3. keep night readiness false;
4. finish the work-gate entry;
5. invoke the existing client activation/reveal follow-up.

On client preparation failure:

1. clear the mode only if the failed token still belongs to the current preparation;
2. finish or cancel the work token safely;
3. execute the existing client-abort behaviour;
4. do not let an older coroutine cancel a newer preparation.

Use explicit callbacks or narrow manager methods for the follow-up phase effects.

The manager may retain methods equivalent to:

```gdscript
_on_night_preparation_succeeded()
_on_client_preparation_succeeded()
_on_client_preparation_aborted()
```

Those callbacks must not own or duplicate preparation state.

They may continue to coordinate:

```text
- tutorial alert
- night reveal
- seed merchant departure
- client-sale activation
- client reveal
- fallback building phase after abort
```

This pass does not yet extract the full run-phase state machine.

# Part C — Give the preparation controller explicit dependencies

The current controller receives the complete manager and calls many private methods.

Replace that universal private backchannel where practical.

The preparation controller should receive explicit references to the focused owners it uses:

```text
BuildingPreparationWorkGate
BuildingScanService
BuildingInvalidationController
BuildingNavigationSyncService
GardenTopologyService
SpawnerRouteService
```

It may also receive:

```text
- a Node host used only for `get_tree()` / current-scene access
- narrow completion Callables
- the configured preparation budget
```

Do not introduce a dependency-container object or service locator.

A longer explicit setup signature is preferable to hidden access through `_manager._private_member`.

The controller should directly call the public APIs of these services.

## Static collider preparation

Preserve the existing lookup and compatibility behaviour for:

```text
fightSystem.prepare_night_static_colliders_budgeted
fightSystem.prepare_night_static_colliders
```

Preserve the configured preparation budget.

Do not redesign `fightSystem`.

# Part D — Move waterpool navigation synchronization to its correct owner

These methods currently remain in `BuildingManager`:

```gdscript
_rebuild_waterpool_directional_field()
_clear_waterpool_directional_field()
```

They are navigation synchronization operations.

Move their implementation into:

```text
BuildingNavigationSyncService
```

Expose public methods such as:

```gdscript
func rebuild_waterpool_directional_field() -> void
func clear_waterpool_directional_field() -> void
```

The manager may keep thin compatibility wrappers if dynamic usage requires them.

`BuildingPreparationController` should call the navigation-sync service directly.

Do not change water behaviour or steering lookup semantics.

# Part E — Remove shared-token access through `BuildingManager`

`BuildingInvalidationController`, `GardenTopologyService`, and `SpawnerRouteService` currently use manager-private preparation-token methods.

Replace that coupling with the shared `BuildingPreparationWorkGate`.

## `BuildingInvalidationController`

It must continue to own:

```text
_runtime_rebuild_active
_runtime_rebuild_id
_runtime_rebuild_wants_gardens
_runtime_rebuild_progress
dirty flags
quiet-period state
```

Do not move those into the preparation controller.

When starting a budgeted runtime walkability rebuild:

```text
- claim a new work token with purpose `runtime_walkability_rebuild`
- pass that token into the existing budgeted topology operations
```

When a synchronous rebuild must supersede an active budgeted rebuild:

```text
- invalidate the shared work token
- invalidate the existing runtime rebuild ID
- preserve the current synchronous-rebuild behaviour
```

Do not call:

```gdscript
_manager.advance_preparation_token()
```

The invalidation controller should receive the work gate directly.

A superseded runtime coroutine must not clear the active state of a newer rebuild. Preserve the existing rebuild-ID protection.

## `GardenTopologyService`

Its budgeted methods must check:

```gdscript
_work_gate.is_current(token)
```

instead of:

```gdscript
_manager._night_preparation_is_current(token)
```

Do not retain a second token algorithm.

Use the preparation budget supplied through explicit setup/configuration rather than manager-private access.

Preserve all existing yield points and budget thresholds.

## `SpawnerRouteService`

Apply the same rule:

```text
- work-gate token validity
- explicit preparation budget
- no manager-private token queries
```

Preserve route allocation, lazy flow requests, readiness checks, and cancellation timing exactly.

# Part F — Update all readiness and preparing consumers

Replace direct access to the removed manager state.

Known consumers include:

```text
SpawnTickController
BuildingRuntimeTickController
AgentSaveService
SeedMerchantController
BuildingManager phase gates
BuildingManager save/load restoration
BuildingManager dev night skip
runtime spawner registration
```

Use one authoritative controller query.

Examples:

```gdscript
_preparation.is_night_ready()
_preparation.is_client_preparing()
_preparation.is_preparing()
```

No service should read:

```gdscript
_manager._night_preparation_ready
_manager._client_preparing
```

The manager may expose compatibility delegates:

```gdscript
func is_night_preparation_ready() -> bool:
    return _building_preparation_controller.is_night_ready()
```

Add other public delegates only where an actual caller needs them.

Do not create duplicate cached booleans in the manager.

# Part G — Rewrite manager call sites as thin orchestration

Update these areas carefully:

```text
_on_game_mode_changed()
_begin_client_sale_phase()
restore_day_phase()
restore_runtime_agents_from_save()
skip_current_night_for_dev()
can_start_night_after_clients()
has_clients_for_save_load()
save_load_client_block_reason()
should_skip_building_runtime_tick()
runtime spawner registration
```

## Night start

The manager should:

1. preserve playlist setup and validation;
2. preserve reveal abort/reset logic;
3. call `begin_night_preparation()`;
4. defer/await the controller’s night preparation sequence.

It must not mutate preparation fields itself.

## Day start

The manager should cancel current preparation through the controller.

Preserve:

```text
- waterpool directional-field clearing
- playlist fallback clearing
- day-start pending state
- sheep/client/merchant behaviour
```

## Client preparation

The manager should:

1. preserve existing client-total, spawner, and target checks;
2. call `begin_client_preparation()`;
3. defer/await the controller’s client preparation sequence.

It must not own `_client_preparing`.

## Save/load

Use the same controller APIs as normal gameplay.

Do not manually reconstruct preparation flags.

Preserve these cases:

```text
night restore:
    prepare topology
    restore agents with navigation ready
    notify restored phase

client-phase restore:
    prepare topology
    restore agents with navigation ready
    purge invalid day monsters
    notify restored phase

normal day restore:
    no night/client preparation
    restore agents without prepared navigation
```

The save format and serialized `night_preparation_ready` value must remain compatible.

## Restoring an already prepared night phase

`restore_day_phase("night")` currently marks preparation ready.

Provide an explicit controller method for this compatibility case, such as:

```gdscript
func restore_prepared_night_state() -> void
```

Do not write controller-private state from the manager.

## Dev skip

`skip_current_night_for_dev()` must cancel preparation through the controller before clearing spawn state and starting the day.

# Compatibility policy

Preserve wrappers when they may be used through:

```text
signals
call()
Callable
scenes
save/load
debug tools
tutorial code
```

Potential wrappers include:

```gdscript
_run_night_preparation(token)
_run_client_preparation(token)
_night_preparation_is_current(token)
_night_preparation_budget_us()
advance_preparation_token()
is_night_preparation_ready()
finish_night_preparation_success()
finish_client_preparation_success()
```

Do not blindly retain all of them.

For each wrapper:

* search direct usage;
* search dynamic usage;
* delete it if proven internal and obsolete;
* otherwise convert it to a thin delegate;
* mention retained compatibility wrappers in the final report.

New internal code must not use obsolete compatibility wrappers merely because they remain available.

# Behaviour that must remain unchanged

Preserve all of the following:

* preparation begins on a clean frame;
* no spawning before night preparation succeeds;
* flow-field groups remain lazily computed;
* preparation does not wait for every flow field;
* missing async flow support still falls back to synchronous assignment when supported;
* missing both async and synchronous support still produces the existing error;
* no-rose night tutorial behaviour;
* night reveal order;
* client reveal order;
* seed merchant night departure;
* client preparation abort fallback;
* runtime wall rebuild quiet period;
* runtime rebuild progress;
* runtime rebuild cancellation;
* synchronous rebuild superseding an asynchronous rebuild;
* save/load restoration order;
* dev night skip;
* preparation performance budget;
* all debug/telemetry messages unless a name is now materially misleading.

Do not change:

* garden-building algorithms;
* spawner-route algorithms;
* flow-field algorithms;
* wall invalidation rules;
* client counts;
* night completion;
* playlist indexing;
* planificator logic;
* victory logic;
* agent movement;
* spawn frequency.

# Architecture documentation

Update:

```text
scripts/map/ARCHITECTURE.md
```

Document:

## BuildingPreparationController

Owns:

```text
- night/client preparation mode
- preparation readiness
- sequencing of preparation work
- lifecycle of active preparation
```

Does not own:

```text
- runtime walkability rebuild state
- garden topology data
- route caches
- run-phase progression
```

## BuildingPreparationWorkGate

Owns:

```text
- generation token shared by budgeted topology work
- stale coroutine detection
```

Does not own:

```text
- preparation state
- dirty flags
- rebuild algorithms
- phase transitions
```

Update `BuildingManager` documentation to state that it no longer owns preparation state.

Remove comments that still describe preparation state as manager-owned.

# Quality constraints

* Strict GDScript typing.
* Avoid `:=` in the cases prohibited by `AGENTS.md`.
* Do not use loosely typed dictionaries for preparation state.
* Do not create duplicate truth between manager and controller.
* Do not add a new manager-private backchannel.
* Do not expose controller fields directly.
* Do not create a general task scheduler.
* Do not add an event bus.
* Do not mix the later run-phase refactor into this pass.
* Do not refactor unrelated systems.
* Do not optimize by changing behaviour.
* Do not run the project.

# Expected result

After this pass:

```text
BuildingManager
    contains no preparation state variables

BuildingPreparationController
    is the single owner of preparation lifecycle/readiness

BuildingPreparationWorkGate
    is the single owner of cancellation generations

BuildingInvalidationController
    owns only runtime rebuild state and uses the shared work gate

GardenTopologyService and SpawnerRouteService
    no longer call manager-private preparation token/budget methods

SpawnTickController
    no longer reads manager-private readiness state
```

The line-count reduction is not the success criterion.

Success means preparation and cancellation behaviour can be understood by reading:

```text
building_preparation_controller.gd
building_preparation_work_gate.gd
```

without tracing several manager-owned flags.

# Manual tests to report

Do not run these tests. Include them in the final report.

1. Fresh startup:

   * flow becomes ready;
   * startup preparation completes;
   * no stuck loading state.

2. Start a normal night:

   * preparation starts once;
   * spawning remains gated;
   * reveal begins after preparation;
   * monsters spawn normally.

3. Night with no remaining roses:

   * existing tutorial alert appears;
   * night reveal/continuation remains correct.

4. End the night while work exists:

   * previous preparation token becomes stale;
   * no stale completion publishes night-ready state during the day.

5. Start client phase:

   * client preparation starts once;
   * clients activate only after preparation;
   * client reveal remains correct.

6. Client phase with zero clients, no client spawner, or no valid targets:

   * existing skip behaviour remains unchanged;
   * no preparation remains stuck active.

7. Add/remove a wall during active gameplay:

   * runtime rebuild begins after the quiet period;
   * runtime tick pauses as before;
   * progress reaches completion;
   * runtime tick resumes.

8. Make a second topology change during an active runtime rebuild:

   * first coroutine becomes stale;
   * newer rebuild remains authoritative;
   * old coroutine does not clear the newer active flag.

9. Force a synchronous rebuild while a budgeted rebuild is active:

   * budgeted work is cancelled;
   * synchronous result is complete;
   * no half-built garden state remains.

10. Save/load during a night:

    * topology prepares before agents restore;
    * night-ready state is correct;
    * spawning and navigation continue.

11. Save/load during client phase:

    * client preparation completes;
    * clients restore correctly;
    * stale monsters are purged as before.

12. Save/load during a normal daytime building phase:

    * no unnecessary night/client preparation;
    * readiness remains false.

13. Restore a saved prepared-night phase:

    * compatibility readiness state is restored correctly.

14. Use developer night skip during preparation:

    * preparation is cancelled;
    * monsters are removed;
    * day starts;
    * no stale preparation completes afterward.

15. Register a new spawner during a prepared active night:

    * its route is initialized under the same readiness conditions as before.

16. Seed merchant:

    * departure remains gated by night preparation readiness.

17. Flow implementation with async request support:

    * existing lazy async behaviour remains.

18. Flow implementation with synchronous assignment only:

    * fallback continues to work.

19. Flow implementation supporting neither:

    * existing error is reported;
    * preparation does not falsely succeed.

20. Check the debugger:

    * no invalid access to removed manager fields;
    * no stale coroutine warnings;
    * no new cyclic setup errors.

# Final report

Report:

1. changed files;
2. preparation state moved from `BuildingManager`;
3. exact state now owned by `BuildingPreparationController`;
4. work-gate API and ownership;
5. how stale night/client preparation is cancelled;
6. how runtime rebuilds use the same token without owning preparation state;
7. direct manager-private preparation accesses removed;
8. waterpool navigation methods moved;
9. compatibility wrappers kept and why;
10. compatibility wrappers removed and search evidence;
11. behaviour intentionally preserved;
12. remaining private coupling;
13. production-quality concerns discovered;
14. complete manual-test list.

Do not claim runtime success because Godot and tests must not be run.
