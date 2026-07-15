# Pass 1 — Complete preparation ownership and shared budgeted-work cancellation

Refactor the current preparation system so that `BuildingPreparationController` becomes the authoritative owner of night/client preparation lifecycle state, while one small focused work gate owns cancellation generations shared by preparation and runtime topology rebuilds.

Read `AGENTS.md` first and follow it strictly.

Do not run:

- Godot;
- tests;
- compilation;
- SCons;
- exports;
- build commands.

The user performs runtime testing manually.

This is a behavior-preserving architectural refactor. Do not change gameplay rules, navigation algorithms, flow-field behavior, spawn timing, client rules, save format, phase order, or runtime rebuild ordering.

---

# Why this pass is justified

The current extraction is incomplete.

`BuildingPreparationController` runs the preparation sequence, but `BuildingManager` still owns:

```gdscript
_night_preparing
_client_preparing
_night_preparation_ready
_night_preparation_token
```

The same token is also advanced or queried by:

- `BuildingInvalidationController`;
- `GardenTopologyService`;
- `SpawnerRouteService`;
- `BuildingRuntimeTickController`.

Other services directly read manager-private preparation state.

This is real split ownership, not merely a line-count problem.

After this pass:

```text
BuildingPreparationController
    owns night/client preparation mode, readiness, active token reference,
    sequencing, completion, failure, and stale-run checks

BuildingPreparationWorkGate
    owns the single generation used to invalidate shared budgeted work

BuildingInvalidationController
    owns runtime rebuild active/progress/dirty state and its own active work-token reference

BuildingManager
    keeps scene lifecycle orchestration, exported configuration,
    completion side effects, compatibility façades, and setup wiring
```

Do not combine a broader run-phase refactor into this pass.

---

# Verified current-codebase names and constraints

Use the actual current names.

The save/load phase restoration entry point is:

```gdscript
restore_gameplay_phase(
    phase: String,
    phase_state: Dictionary,
    has_runtime_agents: bool
)
```

There is no current `restore_day_phase()` method. Do not invent one.

The preparation budget is currently exposed in the scene through:

```gdscript
@export var night_preparation_budget_ms: float
```

Keep that exported property on `BuildingManager` for scene/Inspector compatibility.

It is configuration, not preparation lifecycle state.

There are no current runtime assignments to this property outside scene initialization. Verify this again before editing. If still true, compute the sanitized microsecond value once during setup and pass it explicitly to the consumers that need it.

Do not move the exported property into a `RefCounted`, where it would no longer be scene-configurable.

---

# Scope

Inspect at minimum:

```text
AGENTS.md
scripts/map/building_manager.gd
scripts/map/building_preparation_controller.gd
scripts/map/building_invalidation_controller.gd
scripts/map/building_navigation_sync_service.gd
scripts/map/building_scan_service.gd
scripts/map/garden_topology_service.gd
scripts/map/spawner_route_service.gd
scripts/map/building_runtime_tick_controller.gd
scripts/spawning/spawn_tick_controller.gd
scripts/map/agent_save_service.gd
scripts/map/day_visitor_movement_controller.gd
scripts/map/seed_merchant_controller.gd
scripts/map/client_sale_controller.gd
scripts/map/ARCHITECTURE.md
scripts/gameState/progression.gd
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
_abort_client_preparation
is_night_preparation_ready
night_preparation_budget_ms
restore_gameplay_phase
restore_runtime_agents_from_save
```

Also search dynamic usage:

```text
call(
call_deferred(
Callable
has_method
connect
scene references
string method names
```

Do not delete a compatibility method until direct and dynamic searches prove it is unnecessary.

---

# Part A — Add one small shared work gate

Create:

```text
scripts/map/building_preparation_work_gate.gd
```

Use:

```gdscript
extends RefCounted
class_name BuildingPreparationWorkGate
```

This object owns only:

```text
- one monotonically increasing generation
- one current diagnostic purpose
```

It must not:

```text
- know GameState
- know BuildingManager
- perform rebuilding
- own night readiness
- own preparation mode
- own runtime-rebuild progress
- call gameplay services
```

Use a narrow API equivalent to:

```gdscript
func begin_work(purpose: StringName) -> int
func is_current(token: int) -> bool
func finish_work(token: int) -> bool
func cancel_if_current(token: int) -> bool
func cancel_current_work() -> int

func current_purpose() -> StringName
func current_token() -> int
```

## Required semantics

### `begin_work(purpose)`

- Require a non-empty purpose.
- Increment the generation.
- Store the purpose.
- Return the new token.
- Invalidate every previously running budgeted operation.

### `is_current(token)`

Return true only when:

```text
token > 0
token == current generation
and a work purpose is still active
```

A token whose work has finished must no longer be considered current.

### `finish_work(token)`

- Only succeed when `token` is current.
- Clear the active purpose.
- Make `is_current(token)` return false afterward.
- Do not affect newer work.
- Return whether the finish was accepted.

A simple implementation can use an empty purpose as the “no active work” marker; no second task framework is needed.

### `cancel_if_current(token)`

- Cancel only when the supplied token still owns the current work.
- Advance/invalidate the generation or otherwise make the token stale.
- Clear the purpose.
- Return whether cancellation occurred.

This is the normal API for an owner cancelling its own work.

### `cancel_current_work()`

- Unconditionally invalidate whichever budgeted work is current.
- Clear the purpose.
- Use this only at authoritative global seams that intentionally supersede every shared budgeted operation, such as a real phase reset/dev skip.
- A stale coroutine or stale controller must never call this method.

Do not create:

- a scheduler;
- a task base class;
- a token object hierarchy;
- an event bus;
- a generic cancellation framework.

---

# Part B — Make `BuildingPreparationController` the lifecycle owner

Move these fields out of `BuildingManager`:

```gdscript
_night_preparing
_client_preparing
_night_preparation_ready
_night_preparation_token
```

Use one explicit mode:

```gdscript
enum PreparationMode {
    NONE,
    NIGHT,
    CLIENT,
}
```

`BuildingPreparationController` should own:

```text
- current preparation mode
- active preparation token reference
- night readiness
- sanitized preparation budget in microseconds
- night/client preparation sequences
- stale-run validation
- preparation completion/failure publication
```

Suggested state:

```gdscript
var _mode: PreparationMode = PreparationMode.NONE
var _active_token: int = 0
var _night_ready: bool = false
var _budget_us: int = 500
```

The work gate owns generation creation. The controller only stores the token belonging to its current preparation.

## Required queries

```gdscript
func is_night_preparing() -> bool
func is_client_preparing() -> bool
func is_preparing() -> bool
func is_night_ready() -> bool
func budget_us() -> int
```

Preparing queries must require both:

```text
the matching mode
and _work_gate.is_current(_active_token)
```

A preparation superseded by newer runtime or preparation work must not still appear active.

Do not expose mutable fields.

---

# Part C — Explicit controller dependencies

Replace the preparation controller’s universal manager-private backchannel.

Use an explicit setup equivalent to:

```gdscript
func setup(
    host: Node,
    work_gate: BuildingPreparationWorkGate,
    scan_service: BuildingScanService,
    invalidation_controller: BuildingInvalidationController,
    navigation_sync_service: BuildingNavigationSyncService,
    garden_topology_service: GardenTopologyService,
    spawner_route_service: SpawnerRouteService,
    budget_us: int,
    night_success_callback: Callable,
    client_success_callback: Callable,
    client_abort_callback: Callable
) -> void
```

Exact argument order may differ.

The controller may use the host only for:

```text
- get_tree()
- current_scene lookup for fightSystem
```

It must call public APIs of the focused services directly.

Do not introduce:

- a dependency container;
- a service locator;
- a new manager-private backchannel;
- a signal bus.

A longer explicit setup call is acceptable.

---

# Part D — Beginning, cancelling, restoring, and completing preparation

## Beginning preparation

Expose:

```gdscript
func begin_night_preparation() -> int
func begin_client_preparation() -> int
```

Each method must:

1. call `_work_gate.begin_work()` with a clear purpose;
2. store the returned token;
3. set the matching mode;
4. mark night readiness false;
5. return the token.

Suggested purposes:

```gdscript
&"night_preparation"
&"client_preparation"
```

Beginning new work intentionally supersedes any earlier budgeted preparation/runtime rebuild.

## Authoritative phase reset

Expose one explicit operation for real phase resets, such as:

```gdscript
func reset_for_phase_transition() -> void
```

It must:

- unconditionally cancel shared budgeted work through the gate;
- set mode to `NONE`;
- clear the active token;
- clear night readiness.

Use this for:

- normal transition to day;
- developer night skip;
- save/load reset before beginning the restored preparation;
- other authoritative phase resets currently advancing the manager token.

Do not use unconditional cancellation from stale coroutine completion/failure paths.

## Owner-specific cancellation

When the controller aborts only its own active preparation:

- first verify the mode and token still match;
- use `_work_gate.cancel_if_current(_active_token)`;
- clear controller mode/token only if it still owns that work.

A stale preparation must never cancel newer work claimed by:

- another preparation;
- a runtime rebuild.

## Restoring phase state

Expose explicit state operations instead of writing controller-private fields:

```gdscript
func restore_prepared_night_state() -> void
func restore_unprepared_state() -> void
```

`restore_prepared_night_state()` must:

- cancel any obsolete shared work at this authoritative restore seam;
- set mode to `NONE`;
- clear active token;
- set night readiness true.

`restore_unprepared_state()` must:

- cancel obsolete shared work at this authoritative restore seam;
- set mode to `NONE`;
- clear active token;
- set night readiness false.

Use these from the existing:

```gdscript
restore_gameplay_phase(...)
```

Do not create `restore_day_phase()`.

## Completion

Night success must:

1. verify mode is `NIGHT`;
2. verify the token is the active controller token;
3. verify `_work_gate.is_current(token)`;
4. set mode to `NONE`;
5. clear active token;
6. set night readiness true;
7. call `_work_gate.finish_work(token)`;
8. invoke the narrow manager night-success callback.

Client success must:

1. perform the same current-owner checks;
2. set mode to `NONE`;
3. clear active token;
4. keep night readiness false;
5. finish the gate token;
6. invoke the client-success callback.

Client failure must:

1. invoke no side effect when stale;
2. clear mode/token only if the failed token is still the current client preparation;
3. finish or cancel only that token;
4. invoke the existing client-abort callback;
5. never let an older run abort a newer preparation.

## Night hard failure

Preserve current fail-closed behavior for an actual current night-preparation failure:

- do not publish night readiness;
- do not start spawning;
- do not silently switch phase;
- preserve the existing error reporting.

Do not invent a new fallback policy in this architectural pass.

Document how the current active mode/work token is left after a hard failure. Keep the behavior intentional and consistent rather than accidentally half-clearing it.

---

# Part E — Preparation sequence and async correctness

Use:

```gdscript
func run_night_preparation(token: int) -> bool
func run_client_preparation(token: int) -> bool
```

Return true only when the matching success transition was published.

Return false when:

- the token became stale;
- the phase was cancelled;
- required preparation failed;
- required flow assignment support is unavailable.

Normal mode transitions may still defer execution by one clean frame through thin manager wrappers.

Save/load must await these same methods directly.

## Check after every yield

After every `await`, verify that the controller still owns the expected current token/mode before:

- continuing to another preparation step;
- publishing success;
- publishing client abort;
- mutating preparation state.

This includes:

- the initial clean-frame wait;
- every budgeted topology/route operation;
- the frame before static-collider preparation;
- `prepare_night_static_colliders_budgeted`;
- any future awaited compatibility path.

The current static-collider call can yield without receiving a token. Therefore, an explicit current-token check after it returns is mandatory.

## Shared preparation order

Preserve the exact current sequence:

```text
scan buildings
sync flow extra-blocking cells
rebuild waterpool directional field
clear navigation-topology dirty state
clear plant-layout dirty state
yield one frame
rebuild walkable map cache budgeted
build gardens from plants budgeted
validate gardens budgeted
mark navigation rebuild completed
```

Then preserve the current route/static-collider order for night and client preparation.

Do not alter lazy flow behavior.

## Static collider compatibility

Preserve:

```text
fightSystem.prepare_night_static_colliders_budgeted
fightSystem.prepare_night_static_colliders
```

Preserve the configured millisecond budget passed to the budgeted compatibility method.

Do not redesign `fightSystem`.

---

# Part F — Save/load must respect preparation result

Use the same controller APIs for normal gameplay and save/load.

Current save/load restoration directly awaits preparation before restoring runtime agents. Keep that ordering.

For night restore:

```gdscript
var token: int = _preparation.begin_night_preparation()
var prepared: bool = await _preparation.run_night_preparation(token)
if not prepared:
    return
_agent_save_service.restore_state(data, true)
_notify_restored_phase()
```

Equivalent code is acceptable.

Apply the same rule to client-phase restore.

A stale or failed restore preparation must not continue by claiming:

```gdscript
navigation_prepared == true
```

Do not restore runtime agents against partially rebuilt navigation.

Preserve:

```text
night restore:
    prepare topology
    restore agents with navigation prepared
    notify restored phase

client-phase restore:
    prepare topology
    restore agents with navigation prepared
    purge invalid day monsters
    notify restored phase

normal day restore:
    no night/client preparation
    restore agents without prepared navigation
```

Keep the serialized field:

```text
night_preparation_ready
```

for save-format compatibility even though current restoration primarily derives readiness from the restored phase and freshly runs navigation preparation when runtime agents exist.

Do not change the save schema in this pass.

---

# Part G — Keep exported budget configuration compatible

Keep:

```gdscript
@export_range(...) var night_preparation_budget_ms: float = 3.0
```

on `BuildingManager`.

During setup, sanitize once:

```gdscript
var preparation_budget_us: int = maxi(
    500,
    int(night_preparation_budget_ms * 1000.0)
)
```

Pass the resulting value explicitly to:

```text
BuildingPreparationController
GardenTopologyService
SpawnerRouteService
BuildingRuntimeTickController
```

Only pass it to `BuildingInvalidationController` if its revised implementation directly needs it.

The topology and route services may store the immutable configured integer in focused fields such as:

```gdscript
var _budget_us: int = 500
```

They must not call manager-private preparation budget helpers.

`BuildingRuntimeTickController` must use its configured budget for:

```gdscript
process_queued_flow_requests(...)
```

Do not create a new configuration service for one integer.

Remove:

```gdscript
_manager._night_preparation_budget_us()
```

from new internal code.

If repository search finds a real runtime writer of `night_preparation_budget_ms`, do not cache it silently. Report the mismatch and use a narrow public configuration query instead.

---

# Part H — Give runtime rebuilds safe shared-gate ownership

`BuildingInvalidationController` remains the owner of:

```text
_navigation_topology_dirty
_plant_layout_dirty
_walkability_quiet_seconds_remaining
_runtime_rebuild_active
_runtime_rebuild_is_plant_layout
_runtime_rebuild_id
_runtime_rebuild_wants_gardens
_runtime_rebuild_progress
_navigation_revision
```

Add only the token reference needed to identify its current shared work:

```gdscript
_runtime_work_token: int = 0
```

The work gate generates tokens. The invalidation controller stores only the token for its active runtime rebuild.

## Runtime start

When starting budgeted runtime work:

```gdscript
_runtime_work_token = _work_gate.begin_work(&"runtime_walkability_rebuild")
```

or:

```gdscript
_runtime_work_token = _work_gate.begin_work(&"runtime_plant_layout_rebuild")
```

Pass that token into the existing budgeted topology/route operations.

Preserve `_runtime_rebuild_id`; it protects runtime state from an older coroutine clearing a newer rebuild.

The token and rebuild ID solve different problems:

```text
work token:
    shared budgeted-operation cancellation

runtime rebuild ID:
    ownership of invalidation-controller active/progress fields
```

Do not remove either protection.

## Cancelling runtime-owned work

When a plant edit supersedes an active runtime rebuild:

- preserve current dirty-state behavior;
- call `_work_gate.cancel_if_current(_runtime_work_token)`;
- do not unconditionally cancel newer preparation work;
- keep the existing rebuild-ID/state logic.

When synchronous rebuild supersedes an active runtime rebuild:

- cancel only the runtime token if it still owns the gate;
- invalidate the runtime rebuild ID;
- clear runtime active/type/token state;
- preserve synchronous rebuild behavior.

A stale runtime flag/token must never cancel a newer night/client preparation.

## Finishing runtime work

At the end of each budgeted runtime coroutine:

- call `_work_gate.finish_work(token)`; it is a no-op when superseded;
- clear `_runtime_work_token` only when `rebuild_id` still owns the current runtime state;
- preserve the existing active/type clearing guarded by rebuild ID;
- do not let an older coroutine clear newer runtime state.

Preserve all progress values, logs, quiet-period behavior, and rebuild ordering.

Remove all use of:

```gdscript
_manager.advance_preparation_token()
```

---

# Part I — Remove token/budget backchannels from topology and routes

## `GardenTopologyService`

Update setup so it receives:

```text
BuildingPreparationWorkGate
sanitized budget_us
```

Its budgeted methods must use:

```gdscript
_work_gate.is_current(token)
```

and its own configured budget.

Remove:

```gdscript
_manager._night_preparation_is_current(token)
_manager._night_preparation_budget_us()
```

Preserve:

- every yield location;
- every budget threshold;
- topology algorithms;
- manager coupling unrelated to preparation token/budget.

Do not broaden this pass into a complete `GardenTopologyService` decoupling.

## `SpawnerRouteService`

Apply the same change:

```text
- explicit work gate
- explicit budget_us
- no manager-private token/budget calls
```

Preserve:

- route allocation;
- lazy flow requests;
- async/sync fallback behavior;
- readiness checks;
- route cache behavior;
- cancellation timing;
- queued flow processing.

Do not refactor unrelated manager backchannels in this pass.

---

# Part J — Move waterpool navigation synchronization

Move the implementation of:

```gdscript
_rebuild_waterpool_directional_field()
_clear_waterpool_directional_field()
```

from `BuildingManager` into:

```text
BuildingNavigationSyncService
```

Expose:

```gdscript
func rebuild_waterpool_directional_field() -> void
func clear_waterpool_directional_field() -> void
```

Move the steering-system lookup helper there as well if it becomes unused by `BuildingManager`.

The preparation controller and invalidation controller should call the navigation-sync service directly.

The manager’s day transition should also call the service directly, or retain a thin wrapper only if repository search proves dynamic compatibility requires it.

Preserve water behavior and steering lookup semantics exactly.

---

# Part K — Update all consumers of lifecycle state

Replace direct reads/writes of removed manager fields.

Known consumers include:

```text
BuildingManager mode transitions
BuildingManager client reset/gates
BuildingManager save/load restoration
BuildingManager runtime spawner registration
BuildingManager dev night skip
BuildingRuntimeTickController
SpawnTickController
AgentSaveService
DayVisitorMovementController
SeedMerchantController
ClientSaleController comments
```

Use controller queries:

```gdscript
_preparation.is_night_ready()
_preparation.is_night_preparing()
_preparation.is_client_preparing()
_preparation.is_preparing()
```

The manager may keep public delegates where actual callers already use its façade:

```gdscript
func is_night_preparation_ready() -> bool:
    return _building_preparation_controller.is_night_ready()
```

Keep this public delegate because current callers include save, merchant, and daytime visitor code.

`SpawnTickController` must stop reading:

```gdscript
_manager._night_preparation_ready
```

It may use the public manager delegate unless direct dependency injection is clearly simpler.

Do not create manager mirror booleans.

---

# Part L — Rewrite manager call sites as thin orchestration

Update these current areas carefully:

```text
_on_game_mode_changed()
_begin_client_sale_phase()
_reset_client_sale_state()
restore_gameplay_phase()
restore_runtime_agents_from_save()
skip_current_night_for_dev()
can_start_night_after_clients()
has_clients_for_save_load()
save_load_client_block_reason()
day_clients_gone()
should_skip_building_runtime_tick()
runtime spawner registration
```

## Night start

Preserve playlist setup, validation, reveal abort/reset, and spawn queue cleanup.

Then:

1. begin night preparation through the controller;
2. defer the thin run wrapper by one clean frame as currently intended.

Do not mutate preparation fields in the manager.

## Day start

Use the authoritative phase-reset method to cancel shared work and clear readiness.

Preserve:

- waterpool directional-field clearing;
- playlist fallback clearing;
- day-start pending state;
- sheep/client/merchant behavior.

## Client preparation

Preserve client-total/spawner/target checks.

Then:

1. begin client preparation through the controller;
2. defer the controller run through the existing clean seam.

Do not keep `_client_preparing` in the manager.

## Client-sale reset

`_reset_client_sale_state()` should reset client-sale/reveal/tantrum/counter state only.

Preparation cancellation belongs to explicit preparation/phase-reset calls made by its caller.

Remove comments claiming the manager owns `_client_preparing`.

## Runtime spawner registration

Replace the direct readiness field check with the authoritative readiness query.

Preserve all other conditions and route initialization timing.

## Runtime tick gate

Use:

```gdscript
_building_preparation_controller.is_preparing()
```

alongside the existing runtime-rebuild active query.

## Developer night skip

Cancel shared preparation/runtime budgeted work through the authoritative phase-reset path before clearing spawn state and starting day.

No stale preparation may publish success afterward.

---

# Part M — Completion callbacks remain manager-owned side effects

The manager may retain narrow callbacks equivalent to:

```gdscript
func _on_night_preparation_succeeded() -> void
func _on_client_preparation_succeeded() -> void
func _on_client_preparation_aborted() -> void
```

These callbacks may coordinate existing phase effects:

```text
night:
    no-rose tutorial
    night reveal
    reveal completion
    ally departure start

client success:
    client-sale activation
    client reveal

client abort:
    client-sale reset
    dawn fallback/request state
```

They must not own, write, or duplicate:

```text
preparation mode
preparation readiness
preparation token
```

Pass them into the preparation controller as `Callable`s.

---

# Part N — Compatibility decisions expected for the current repository

After direct and dynamic search, the current repository is expected to justify these decisions:

## Keep

```gdscript
is_night_preparation_ready()
```

Keep as a public manager façade delegating to the controller.

Keep thin deferred wrappers equivalent to:

```gdscript
_run_night_preparation(token)
_run_client_preparation(token)
```

if continuing to use `call_deferred()` by method name. They must only forward to the controller.

## Remove or replace

After migrating current callers, remove:

```gdscript
_night_preparation_is_current()
_night_preparation_budget_us()
advance_preparation_token()
finish_night_preparation_success()
finish_client_preparation_success()
_abort_client_preparation()
```

The success/abort methods should become narrow callbacks with names reflecting side effects, not preparation-state ownership.

Do not keep dead delegates merely because they existed before.

If dynamic search finds an external caller that contradicts this expected decision, retain a thin compatibility delegate and report the evidence.

New internal code must not route through obsolete wrappers.

---

# Part O — Setup order

Wire dependencies in an explicit, readable order.

At minimum:

1. instantiate the shared work gate as a manager-owned service reference;
2. compute sanitized `preparation_budget_us`;
3. set up `GardenTopologyService` with manager, gate, and budget;
4. set up `SpawnerRouteService` with manager, gate, and budget;
5. set up `BuildingNavigationSyncService`;
6. set up `BuildingInvalidationController` with manager, gate, and focused services it needs;
7. set up `BuildingPreparationController` with explicit dependencies and callbacks;
8. set up `BuildingRuntimeTickController` with manager and budget.

Exact order can vary if dependencies require it, but do not create cyclic initialization or retrieve half-configured services.

Use concrete typed fields where the script class is available. Do not leave new services typed as `Variant` without a real compatibility reason.

---

# Behavior that must remain unchanged

Preserve all of the following:

- preparation begins on a clean frame;
- no spawning before night preparation succeeds;
- flow-field groups remain lazily computed;
- preparation does not wait for every flow field;
- missing async support still falls back to synchronous assignment when supported;
- missing both async and synchronous support still reports the existing error and never marks readiness true;
- no-rose night tutorial behavior;
- night reveal order;
- client reveal order;
- seed merchant night departure;
- client preparation abort fallback;
- runtime wall rebuild quiet period;
- runtime plant-layout rebuild behavior;
- runtime rebuild progress;
- runtime rebuild cancellation;
- synchronous rebuild superseding an asynchronous runtime rebuild;
- save/load restoration order;
- developer night skip;
- configured preparation budget;
- debug/telemetry messages unless ownership terminology is now materially wrong.

Do not change:

- garden-building algorithms;
- spawner-route algorithms;
- flow-field algorithms;
- wall invalidation rules;
- client counts;
- night completion;
- playlist indexing;
- planificator logic;
- victory logic;
- agent movement;
- spawn frequency.

---

# Architecture documentation

Update:

```text
scripts/map/ARCHITECTURE.md
```

Document:

## `BuildingPreparationController`

Owns:

```text
- night/client preparation mode
- night readiness
- active preparation token reference
- preparation sequencing
- completion/failure lifecycle
```

Does not own:

```text
- runtime rebuild active/progress state
- work-token generation
- garden topology data
- route caches
- run-phase progression
- exported scene configuration
```

## `BuildingPreparationWorkGate`

Owns:

```text
- the generation shared by budgeted topology/route work
- active diagnostic purpose
- stale-token detection
```

Does not own:

```text
- preparation mode
- readiness
- dirty flags
- rebuild algorithms
- phase transitions
```

## `BuildingInvalidationController`

Owns:

```text
- runtime rebuild and dirty state
- runtime rebuild ID
- active runtime work-token reference
```

Uses the shared work gate without owning preparation state.

## `BuildingManager`

State that it no longer owns preparation lifecycle fields.

It still owns:

```text
- exported `night_preparation_budget_ms`
- scene lifecycle orchestration
- setup/wiring
- phase side-effect callbacks
- public compatibility façades
```

Remove comments that still claim preparation state is manager-owned.

---

# Quality constraints

- Strict GDScript typing.
- Avoid unsafe `:=` usage prohibited by `AGENTS.md`.
- No loosely typed dictionary for preparation state.
- No duplicate lifecycle truth in manager and controller.
- No new manager-private preparation backchannel.
- No exposed controller fields.
- No scheduler or event bus.
- No broader run-phase refactor.
- No unrelated cleanup.
- No gameplay optimization hidden inside this architecture pass.
- Do not run the project.

The success criterion is not line-count reduction.

Success means preparation lifecycle and shared cancellation can be understood by reading:

```text
building_preparation_controller.gd
building_preparation_work_gate.gd
building_invalidation_controller.gd
```

without tracing manager-owned flags or a manager-owned token.

---

# Expected files to change

New:

```text
scripts/map/building_preparation_work_gate.gd
```

Expected existing files:

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
scripts/map/client_sale_controller.gd
scripts/map/ARCHITECTURE.md
```

Potentially comment/query-only changes where current usage requires them:

```text
scripts/map/day_visitor_movement_controller.gd
scripts/map/seed_merchant_controller.gd
```

Do not modify `progression.gd` unless repository inspection proves its existing dynamic façade calls require an actual compatibility adjustment.

Do not modify unrelated files without a narrow reason stated in the final report.

---

# Manual tests to report

Do not run these tests. Include them in the final report.

1. **Fresh startup**
   - flow becomes ready;
   - startup topology synchronization completes;
   - no stuck loading state.

2. **Normal night**
   - preparation starts exactly once;
   - spawning remains gated;
   - reveal starts after preparation;
   - monsters spawn normally.

3. **Night with no roses**
   - existing tutorial alert appears;
   - reveal/continuation order remains correct.

4. **Night ends during preparation**
   - shared work becomes stale;
   - stale coroutine cannot publish readiness during day;
   - waterpool field clears as before.

5. **Client phase**
   - preparation starts once;
   - clients activate only after preparation;
   - reveal remains correct.

6. **Client skip conditions**
   - zero clients, missing client spawner, or no valid targets preserve existing skip/abort behavior;
   - no preparation remains falsely active.

7. **Runtime wall rebuild**
   - quiet period remains;
   - runtime tick pauses;
   - progress reaches completion;
   - runtime tick resumes.

8. **Runtime plant-layout rebuild**
   - planting remains budgeted;
   - no approach-flow invalidation is added;
   - progress and retarget behavior remain correct.

9. **Second change during active runtime rebuild**
   - first token becomes stale;
   - newer dirty state remains authoritative;
   - old coroutine does not clear newer state.

10. **Preparation supersedes runtime rebuild**
    - runtime coroutine becomes stale;
    - stale runtime cleanup does not cancel or clear the preparation;
    - preparation completes normally.

11. **Stale runtime event cannot cancel newer preparation**
    - an old runtime token fails `cancel_if_current`;
    - current night/client work remains current.

12. **Synchronous rebuild supersedes budgeted runtime rebuild**
    - only runtime-owned work is cancelled;
    - synchronous topology is complete;
    - no half-built garden state remains.

13. **Save/load at night**
    - preparation completes before agent restoration;
    - failed/stale preparation does not restore with `navigation_prepared=true`;
    - readiness and spawning continue correctly.

14. **Save/load during client phase**
    - client preparation completes;
    - clients restore correctly;
    - stale monsters are purged as before.

15. **Normal daytime load**
    - no unnecessary night/client preparation;
    - readiness remains false.

16. **Restore saved night phase**
    - `restore_gameplay_phase("night", ...)` uses the controller’s explicit prepared-state API;
    - deferred runtime-agent preparation still rebuilds navigation before restoring agents.

17. **Developer night skip during preparation**
    - shared work is cancelled;
    - monsters/spawn state clear;
    - day starts;
    - stale preparation cannot complete afterward.

18. **Runtime spawner registration during prepared night**
    - route initialization uses authoritative readiness exactly as before.

19. **Seed merchant/day visitor**
    - night departure remains gated by the public readiness façade.

20. **Async flow implementation**
    - lazy async behavior remains unchanged.

21. **Synchronous-only flow implementation**
    - fallback continues to work.

22. **Flow implementation supporting neither**
    - existing error appears;
    - readiness never becomes true;
    - fail-closed behavior is documented.

23. **Static-collider preparation cancelled while awaiting**
    - stale run cannot publish success after the collider await returns.

24. **Debugger**
    - no invalid access to removed manager fields;
    - no stale owner cancels newer work;
    - no cyclic setup errors;
    - no new console spam.

---

# Final report

Report:

1. every changed/new file;
2. lifecycle fields removed from `BuildingManager`;
3. exact state now owned by `BuildingPreparationController`;
4. the work-gate fields and API;
5. how finished tokens become non-current;
6. where unconditional cancellation is allowed;
7. how owner-specific cancellation prevents stale work cancelling newer work;
8. runtime work-token and rebuild-ID responsibilities;
9. manager-private preparation token/budget accesses removed;
10. exported budget compatibility and how `budget_us` is distributed;
11. waterpool methods moved;
12. manager compatibility façades retained and why;
13. obsolete wrappers removed and search evidence;
14. save/load handling when preparation returns false;
15. behavior intentionally preserved;
16. remaining private coupling intentionally left for later;
17. production-quality concerns discovered;
18. the complete manual-test list.

Do not claim runtime success because Godot and tests were not run.
