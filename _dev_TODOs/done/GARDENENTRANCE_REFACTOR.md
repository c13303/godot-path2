You are patching the attached Godot 4 codebase.

Read and follow `AGENTS.md` before editing anything. Its architecture, typing, performance, test/build, and reporting rules are mandatory.

Do not run Godot, tests, compilation, export, SCons, or any build command. The user tests manually.

# Task

Fix inbound garden entrance selection so it follows the **actual navigable route from each spawner**, rather than choosing the entrance with the smallest Manhattan distance from the spawner.

The current behavior is fundamentally wrong when a maze or wall layout exists before a garden:

* an entrance can be geometrically close to the spawner;
* but reaching it may require going around the entire maze;
* another entrance may be farther geometrically but lie directly on the spawner’s natural arrival path;
* the current resolver often chooses almost the opposite entrance from the correct one.

Implement the correct route-aware solution without introducing frame hitches, per-agent path searches, or architectural clutter.

# Confirmed current implementation

The relevant code is already separated into focused services:

* `scripts/map/garden_access_resolver.gd`
* `scripts/map/spawner_garden_selection_service.gd`
* `scripts/map/spawner_route_service.gd`
* `scripts/map/building_preparation_controller.gd`
* `scripts/map/building_invalidation_controller.gd`

`BuildingManager` must remain a façade. Do not move the algorithm back into it.

The current defect is visible in:

## `GardenAccessResolver`

`_score_garden_access_cell()` currently starts enter-mode scoring with:

```gdscript
var score: float = float(_manhattan_cell(access_cell, target_cell))
```

The local continuation and blocked-neighbor penalties cannot understand the maze before the garden.

The real escape flow is consulted only for exit scoring.

## `SpawnerGardenSelectionService`

Spawner-origin garden selection also compares:

```gdscript
entry_cell - spawner_cell
```

using Manhattan distance.

Therefore, even fixing the chosen entrance while leaving garden selection based on geometric distance would still allow the wrong garden to be selected.

# Required design

Create **one reusable spawner-approach cost flow per physical spawner**.

This is not an agent route and not one field per garden.

Conceptually:

```text
walkable spawner approach anchor
        ↓
one reverse flow/cost field
        ↓
all garden entrances query their actual route cost from that spawner
```

A flow targeting the spawner’s walkable anchor gives the reverse route cost from any candidate entrance back to the spawner. Because movement connectivity is symmetric, that cost represents the real route distance from the spawner to the entrance, including the maze.

Expected scaling:

```text
N spawners = N approach fields
```

Not:

```text
N spawners × N gardens
N spawners × N entrances
N agents × N entrances
```

Do not run A* once per entrance.

Do not create a flow field per spawner/garden pair for entrance scoring.

# Ownership

`SpawnerRouteService` already owns:

* per-spawner flow groups;
* flow-group allocation and release;
* fence policy;
* lazy flow request queueing;
* async readiness queries;
* spawner route lifecycle.

Therefore, the spawner approach field belongs to `SpawnerRouteService`.

Do not add approach-flow state to `BuildingManager`.

`SpawnerRouteService` is currently around the AGENTS.md warning-zone size. Keep the implementation compact and cohesive. Do not add unrelated cleanup or a large new state machine.

Do not create a new generic navigation framework.

# 1. Add a per-spawner approach flow

Store approach-flow information as part of the existing spawner route descriptor in `_spawner_routes`.

Use explicit, readable keys equivalent to:

```gdscript
"approach_group"
"approach_target_cell"
"approach_target_world"
"approach_block_fences"
"approach_ready"
"approach_generation"
```

Exact names may differ if a clearer consistent naming scheme already exists.

## Approach target

The flow target must be a real walkable spawner approach anchor.

Prefer the physical `spawner_cell` when it is a valid walkable flow goal.

Otherwise use the existing safe goal-resolution logic, such as:

```gdscript
_resolve_walkable_goal(spawner_cell, "approach@...")
```

Do not blindly target an invalid or blocked tile.

Validate the resulting cell and world position using the existing sane-cell and finite-world guards.

## Fence policy

The approach field must use exactly the same navigation policy as agents originating from that spawner:

* monster spawner: `block_fences == false`;
* client/merchant spawner: `block_fences == true`.

Reuse `_route_blocks_fences(spawner_cell)`.

Do not duplicate phase or spawner-kind policy elsewhere.

## Group allocation and queueing

Allocate the approach group through the existing `agent_manager.create_group()` path.

Submit it through the existing lazy flow request queue:

```gdscript
request_group_flow_rebuild_with_policy(...)
```

Do not bypass the queue with a new independent async mechanism.

Do not modify the C++ extension. The existing APIs are sufficient:

* `request_flow_to_group`
* `is_group_flow_request_ready`
* `group_route_cost_at_world`
* `mark_group_flow_queued`

# 2. Give approach fields priority in preparation

`initialize_spawner_routes_for_kinds()` currently initializes spawner escape routes.

Change its orchestration so all relevant approach fields are requested **before** the less critical escape fields.

Use a clear two-pass sequence:

```text
pass 1: ensure/queue approach field for every relevant spawner
pass 2: initialize/queue the existing escape route for every relevant spawner
```

Keep the existing preparation token checks and per-frame preparation budget.

Do not queue:

```text
approach spawner A
escape spawner A
approach spawner B
escape spawner B
```

when the approach fields are required before garden selection.

Prefer:

```text
approach spawner A
approach spawner B
approach spawner C
then existing escape fields
```

The normal flow request queue must still drain at the current limit of one request per frame.

Do not increase the per-frame request count to hide the new computation.

# 3. Expose explicit approach readiness and cost queries

Add focused public methods on `SpawnerRouteService`, equivalent to:

```gdscript
func spawner_approach_flow_ready(spawner_cell: Vector2i) -> bool
func spawner_approach_cost_at_cell(spawner_cell: Vector2i, cell: Vector2i) -> Dictionary
func rebuild_spawner_approach_flow(spawner_cell: Vector2i) -> void
```

The cost query must distinguish these states explicitly:

```text
READY
PENDING
UNAVAILABLE / UNREACHABLE
```

Do not represent both “field still computing” and “cell unreachable” as the same unqualified `INF` result.

A small typed-status constant scheme is sufficient, for example:

```gdscript
const APPROACH_STATUS_READY: StringName = &"ready"
const APPROACH_STATUS_PENDING: StringName = &"pending"
const APPROACH_STATUS_UNAVAILABLE: StringName = &"unavailable"
```

A returned dictionary may contain:

```gdscript
{
    "status": APPROACH_STATUS_READY,
    "cost": route_cost,
}
```

Use explicit GDScript types and casts according to `AGENTS.md`.

# 4. Resolve inbound entries from real approach cost

Add or adapt a `GardenAccessResolver` API that returns both the selected entry and its real approach cost.

Use an explicit result, equivalent to:

```gdscript
{
    "status": &"ready",
    "entry_cell": selected_entry,
    "approach_cost": selected_cost,
}
```

Also support:

```gdscript
{
    "status": &"pending",
}
```

and a genuine unreachable result.

Keep the existing `nearest_garden_entry()` compatibility wrapper if current callers or dynamic references still require it. Do not casually delete wrappers.

The compatibility wrapper may return `INVALID_CELL` when the structured result is not ready, but all important selection code must use the structured result so pending is not confused with unreachable.

## Candidate cost

For each garden entry cell:

1. Validate the entry.
2. Get its valid outside-garden neighbors through the existing no-corner-cut logic.
3. Query the spawner approach cost at every valid outside neighbor.
4. Keep the minimum finite outside-neighbor cost.
5. Reject that candidate if no outside neighbor has a finite approach cost.

The route cost must be sampled on the **outside neighbor**, not merely on the interior garden entry cell.

The outside neighbor represents the point at which the incoming route actually reaches the garden entrance.

## Scoring order

For inbound entry selection, use lexicographic priorities:

```text
1. actual approach route cost
2. existing local entrance-quality penalty
3. old Manhattan distance only as a deterministic tie-breaker
4. stable coordinate ordering if still tied
```

Do not combine large local penalties with route cost in a way that allows a locally prettier but substantially longer entrance to win.

The actual route cost must remain the primary decision.

The existing enter-mode local checks may remain useful:

* no valid outside step;
* dead continuation;
* narrow continuation;
* blocked cardinal neighbors.

They are secondary quality tie-breakers, not substitutes for navigation cost.

Preserve exit-mode behavior. This task concerns inbound garden entry selection; do not accidentally rewrite or regress the exit scoring that uses escape fields.

# 5. Never cache a temporary Manhattan answer

The current resolver memoizes entry results by spawner/garden.

Update the cache so it stores the structured resolved result, including:

```gdscript
entry_cell
approach_cost
approach generation/revision
```

Mandatory rules:

* never cache a Manhattan fallback while the approach field is pending;
* never cache `PENDING`;
* never reuse an entry resolved from an older approach generation;
* do not silently use Manhattan because the new field has not finished;
* only cache a final result computed from a ready approach field;
* a genuine unreachable result may be cached only for the current completed approach generation.

The cache must still be cleared when garden topology or entry cells change.

Plant layout changes can invalidate the selected entry cache because garden entry geometry may change, but they must not automatically rebuild the spawner approach field because plant placement does not change external walkability.

# 6. Fix garden selection as well as entrance selection

Update these spawner-origin decisions in `SpawnerGardenSelectionService`:

```gdscript
select_garden_for_spawner()
select_garden_for_client_spawner()
select_garden_entry_for_route()
```

They must compare the resolver’s `approach_cost`, not Manhattan distance from `spawner_cell`.

Do not blindly replace every Manhattan calculation in the file.

These methods have different semantics:

* spawner-origin garden selection must use spawner approach cost;
* methods choosing a route for an already-active agent from `from_cell` may still legitimately use the agent’s current position as their immediate proximity metric;
* `nearest_spawner_cell()` is unrelated and should not be changed for this task.

Inspect each call semantically rather than performing a text replacement.

# 7. Do not allocate one garden flow per candidate during scoring

The selection service currently calls:

```gdscript
get_or_create_spawner_garden_route(...)
```

inside candidate loops.

That can allocate and queue a plant flow group for every candidate garden merely to decide which garden wins.

Do not make the new approach system more expensive by preserving that pattern unnecessarily.

Required behavior:

1. Score eligible garden candidates using the one ready spawner approach field.
2. Order candidates by real approach cost and deterministic tie-breakers.
3. Attempt to create/validate the actual inbound garden route only for the winning candidate.
4. If route creation genuinely fails, try the next scored candidate.
5. Stop after the first usable route.

Do not prewarm every garden route.

The selection service should perform selection first and produce side effects only for the final selected route.

Preserve lazy creation of the actual spawner-to-selected-garden plant flow.

# 8. Pending approach fields must cause retry, not a wrong selection

A spawner approach field may still be queued or computing when spawning tries to select a garden.

When this happens:

* do not choose a Manhattan fallback;
* do not choose among an incomplete subset;
* do not report the garden as permanently unreachable;
* do not consume or lose the spawn;
* return an explicit transient “approach field pending” result.

Both existing spawn systems already retry failed spawn attempts:

* monster playlist retry;
* client sale retry.

Use that existing behavior.

Update `AgentSpawnService` only as much as needed to distinguish:

```text
transient approach field pending
```

from:

```text
no reachable garden
```

The transient pending case should:

* return `false`;
* provide a clear non-misleading failure/debug reason;
* allow the existing retry timer to retry;
* avoid warning spam.

Do not add another spawn queue.

Do not instantiate an agent and park it before its garden has been selected. The existing `ff wait` behavior remains for the selected garden route’s plant flow, not for an unresolved garden choice.

# 9. Hard-topology invalidation

A wall or genuine hard blocker can change which entrance is best even when the garden’s own entry-cell list has not changed.

Therefore, garden route validity cannot depend only on:

```text
garden epoch
garden version
fence policy
```

The approach generation or navigation revision must also participate.

On a hard walkability/topology rebuild:

1. Invalidate the old approach result immediately.
2. Increment or replace its approach generation.
3. Queue a rebuild of one approach field per affected spawner.
4. Invalidate cached inbound entry resolutions using the old generation.
5. Ensure existing spawner/garden inbound routes cannot remain “current” solely because the garden version is unchanged.
6. Re-resolve the entry only after the new approach field is ready.
7. Rebuild or recreate the actual selected garden route using the newly selected entry.

Do not continue rebuilding existing plant flows toward an old entry while the new approach field is pending.

Integrate this into the existing budgeted topology rebuild pipeline. Do not create a parallel invalidation system.

The live runtime path must remain sliced across frames and use the existing preparation token cancellation behavior.

# 10. Plant-only changes must not rebuild approach fields

Planting or removing a rose changes garden layout, but it does not change the external maze or walkable topology.

The existing plant-layout-only rebuild path must:

* rebuild/revalidate gardens as it already does;
* clear final garden-entry selection caches if entry cells changed;
* recreate a selected inbound garden route if its garden entry changed;
* not queue new spawner approach fields;
* not add visible rose-placement lag.

This is a strict acceptance requirement.

The debug flow batch count must not increase merely because a rose was planted, unless that operation genuinely altered hard walkability through some separate existing rule.

# 11. Spawner removal and lifecycle cleanup

When a spawner route is released:

* cancel any queued approach request for its group;
* dissolve the approach group;
* clear the descriptor;
* clear cached garden-entry results for that spawner;
* preserve the existing cleanup of escape and plant groups.

Do not leak native flow groups.

Do not leave stale approach descriptors in `_spawner_routes`.

# 12. Path preview compatibility

The path-preview system consumes prepared real inbound monster routes.

After this patch:

* prepared monster routes must use the route-aware selected garden and entry;
* PathPreview must not create its own approach field;
* PathPreview must not perform its own entrance scoring;
* PathPreview must continue reading the same real runtime plant group;
* if the approach field is pending, preparation should defer/skip until the route can be correctly selected rather than previewing a Manhattan fallback.

Do not broaden this task into a visual PathPreview rewrite.

# 13. Performance constraints

The implementation must have:

```text
O(spawners) approach flow computations per hard topology generation
```

and cheap cached cost lookups for gardens and entries.

Forbidden:

* A* per entrance;
* A* per garden;
* a flow field per entrance;
* an approach flow per garden;
* per-agent approach fields;
* full-map GDScript flood fills;
* per-frame scanning of all gardens or entrances;
* synchronous flow computation during rose placement;
* increasing the existing flow request drain rate;
* C++ extension changes;
* duplicating flow request queues;
* Manhattan fallback cached during async computation.

The existing lazy flow queue and async C++ computation must absorb the work.

The expected runtime symptom during a hard wall change is, at worst, a short existing navigation wait—not a frame hitch.

# 14. Architecture constraints

Follow `AGENTS.md`.

In particular:

* `BuildingManager` remains façade/orchestration only.
* Do not add the scoring algorithm to `BuildingManager`.
* Keep approach state in its clear owner.
* Use public intention-revealing service methods.
* Do not have services reach further into random private manager dictionaries when an owner query can be added.
* Preserve compatibility wrappers if their usage is uncertain.
* Do not perform unrelated refactors.
* Do not create a generic path-cost framework.
* Do not grow a method beyond roughly 80–120 lines.
* Do not use `:=` for risky or dynamic values.
* Explicitly type local variables, arrays, dictionaries, and casts.
* Do not rely on implicit Variant conversions.

Likely modified files:

```text
scripts/map/spawner_route_service.gd
scripts/map/garden_access_resolver.gd
scripts/map/spawner_garden_selection_service.gd
scripts/map/building_preparation_controller.gd
scripts/map/building_invalidation_controller.gd
scripts/map/agent_spawn_service.gd
```

`building_manager.gd` should receive only thin compatibility wrappers if genuinely required.

Touch `garden_retarget_controller.gd` only if its current behavior incorrectly treats approach-pending as permanent failure. Do not refactor the controller otherwise.

Do not modify the C++ extension.

# Acceptance scenarios

The user will test manually.

## A. Maze before one garden

Create a garden with two entrances:

* entrance A is geometrically closest to the spawner;
* the maze makes A require a long detour;
* entrance B is farther in Manhattan distance but is reached naturally by the corridor.

Expected:

* agents select entrance B;
* the selected entry matches actual route arrival;
* no agent first travels past the garden and doubles back toward A.

## B. Multiple gardens

Create:

* one geometrically close garden behind a long maze detour;
* one geometrically farther garden on the direct route.

Expected:

* the direct-route garden wins when its actual approach cost is lower;
* garden selection and entry selection agree.

## C. Multiple spawners

Place spawners on opposite sides of the same garden.

Expected:

* each spawner may choose a different entrance;
* cached results are never shared incorrectly between spawners.

## D. Wall add/remove

Add or remove a wall that changes the best route.

Expected:

* no visible main-thread hitch;
* one approach rebuild is queued per relevant spawner, not per garden;
* old cached entries are not reused;
* after the new field is ready, agents use the newly correct entrance;
* no flow remains targeted toward the old entry merely because garden version stayed unchanged.

## E. Rose placement

Plant a rose.

Expected:

* no approach flow is queued solely because of the plant;
* no new rose-placement lag;
* garden entry cache may refresh if garden geometry changed;
* the existing plant-layout-only budgeted path remains intact.

## F. Fence policy

For the same map:

* monster approach costs ignore fences as blockers;
* client/merchant approach costs treat fences as blockers;
* the policy comes from `_route_blocks_fences()` rather than duplicated conditionals.

## G. Pending computation

Force or observe approach fields still computing when a spawn is requested.

Expected:

* the spawn retries;
* no Manhattan fallback is selected;
* no monster/client is lost;
* no false permanent “no reachable garden” state is cached;
* no warning spam.

## H. Path preview

Expected:

* the preview follows the same corrected inbound route and entry as actual monsters;
* no duplicate preview-only navigation field is created.

# Final report

After editing, report:

1. Every changed file.
2. The exact owner of the approach-flow state.
3. How approach fields are allocated, queued, rebuilt, and released.
4. How pending versus unreachable is represented.
5. How entry and garden selection now use real route cost.
6. How the cache is protected against pending/stale generations.
7. How hard-topology changes invalidate routes.
8. Why plant-only changes do not rebuild approach fields.
9. Any compatibility wrappers retained.
10. Any private coupling intentionally retained.
11. Any production-quality concern found.
12. The manual test scenarios to run.

Do not claim tests passed because you must not run Godot or builds.
