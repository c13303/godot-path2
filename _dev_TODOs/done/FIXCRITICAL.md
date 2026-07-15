Fix the critical native flow-field pool exhaustion and route-group lifecycle issues in this codebase.

Read `AGENTS.md` and `ARCHITECTURE.md` first. Respect the existing ownership boundaries and navigation architecture.

Do not run Godot, tests, compilation, export, or build commands. The user will test manually.

## Problem

Runtime errors occur after several route rebuilds:

```text
ERROR: FlowFieldNative.apply_async_result: flowfield pool exhausted for group 31
ERROR: FlowFieldNative.apply_async_result: flowfield pool exhausted for group 32
```

This can leave client route groups permanently unready, preventing clients from entering.

The fix must address lifecycle correctness, asynchronous replacement behavior, failure recovery, and unnecessary retained route groups. Do not merely increase `MAX_FLOWFIELDS`.

## Confirmed issues to fix

### 1. Expose native group dissolution to GDScript

`SpawnerRouteService` conditionally calls:

```gdscript
agent_manager.has_method("dissolve_group")
```

but `AgentManagerNative::_bind_methods()` does not expose `dissolve_group()`.

Consequently, route cleanup silently skips native group dissolution and, in some paths, queued-request cancellation.

Bind a proper native method that allows GDScript to release a group explicitly.

Requirements:

* Bind `dissolve_group(group_id)` in `AgentManagerNative`.
* Reuse the existing native `AgentManager::dissolve_group()` lifecycle logic.
* Do not duplicate cleanup logic in the Godot wrapper.
* Invalid or already-released group IDs must be handled safely.
* Do not leave GDScript cleanup dependent on `has_method()` once the method is guaranteed by the native API.

### 2. Make route release atomic and unconditional

Inspect all release paths in `scripts/map/spawner_route_service.gd`, especially cleanup of:

* approach groups
* escape groups
* spawner-to-garden groups
* exit-wall groups
* removed spawners or gardens
* invalidated route descriptors

For every route-group release:

1. Cancel or invalidate queued async work for that group.
2. Prevent already-computing stale results from being installed later.
3. Dissolve the native group.
4. Remove the GDScript descriptor/cache entry.

Centralize this sequence in one small private helper owned by `SpawnerRouteService`; do not repeat slightly different cleanup blocks.

The helper must be safe to call more than once.

### 3. Reject stale async results after group release or reuse

A queued or already-running flow-field computation may finish after its route group was removed or its group ID reused.

Use the existing request serial/generation mechanism if one exists. Extend it rather than creating a parallel system.

When applying an async result, verify that:

* the group still exists
* the result belongs to the group’s current request generation/serial
* the group has not been dissolved and recreated since the request started

A stale result must be discarded without:

* allocating a flow-field slot
* changing group wait state
* replacing a newer field
* producing repeated error spam

Group dissolution or reuse must invalidate all previous outstanding results for that group ID.

### 4. Replace an existing group field in place

The current async apply path appears to:

1. allocate/register a new pool field
2. assign it to the group
3. release the old field afterward

At full occupancy, rebuilding an existing group therefore requires a temporary extra pool slot and fails even though the operation is only a replacement.

Change the replacement path so that:

* if the group already owns a valid flow field, copy the newly computed field data into that existing pooled field
* preserve the existing field ID, pointer identity and reference count
* allocate a new pool slot only when the group currently owns no field
* never mutate an old field that is still shared by an unrelated group, if sharing is supported

`FlowField::copy_from()` appears intended to copy field data without replacing `id` or `refcount`; reuse it if appropriate.

Keep synchronous and asynchronous installation semantics consistent.

### 5. Recover correctly from async installation failure

Currently, when async installation fails because no field slot is available, the group can remain in `GROUP_FLOW_WAIT_COMPUTING`.

Fix every async failure exit so a group cannot remain permanently stuck.

On a genuine current-request failure:

* clear the computing state
* record a retryable failure or return to the appropriate non-computing state
* allow the existing lazy route request system to retry
* do not report the request as successfully applied
* do not clear or modify a newer request’s state

Stale-result rejection is not a current-request failure and must not disturb the active request.

### 6. Release unnecessary cached spawner-to-garden route groups

Inspect how `_spawner_garden_routes` or equivalent route descriptors are retained.

The route count can grow approximately with:

```text
spawners × gardens
```

Do not retain every historically valid spawner/garden route forever.

Implement conservative cleanup using existing lifecycle knowledge:

Keep a route group only while it is needed by at least one of these conditions:

* currently selected route
* queued or computing route request
* referenced by active agents
* explicitly required for an imminent client phase according to the existing route-preparation system

Release obsolete, unused route groups at existing invalidation/removal/selection transition points.

Do not add a timer, per-frame scan, broad watcher, or arbitrary LRU system unless the existing architecture truly requires it.

Do not dissolve a route still used by active agents.

### 7. Add focused debug diagnostics

Add debug-only diagnostics that make future pool problems actionable.

Provide one native diagnostic method or existing debug output capable of reporting:

* used flow-field slots / capacity
* active native groups / capacity
* each active group’s group ID
* owned flow-field ID
* request/wait state
* field refcount
* zero-refcount fields still occupying pool slots
* groups without a field while marked ready or computing

Diagnostics must not print every frame. Emit only:

* when pool allocation fails
* when explicitly requested through the existing debug system
* or when a clear invariant is violated

Include enough information in the pool-exhaustion error to identify whether the pressure comes from legitimate active groups or leaked/unowned fields.

## Capacity policy

Do not solve this by changing `MAX_FLOWFIELDS` from 64 to a very large value.

After fixing lifecycle and replacement semantics:

* keep the capacity centralized in `nav_config.h`
* it is acceptable to add a small explicit safety headroom only if technically justified
* document why `MAX_GROUPS` and `MAX_FLOWFIELDS` may differ
* avoid a memory-heavy increase because each full-size field is large

If one field per group is the intended invariant, enforce and document that invariant rather than hiding leaks with excess capacity.

## Architecture constraints

* Native flow-field ownership and pool mechanics remain in the C++ extension.
* Route-domain decisions remain in `SpawnerRouteService`.
* Do not move game-specific spawner/garden semantics into generic native code.
* Do not redesign the overall flow-field system.
* Do not add polling or per-frame cleanup.
* Prefer deterministic cleanup at ownership transitions.
* Keep strict GDScript typing.
* Do not use broad fallback behavior that silently conceals invalid state.

## Expected files

Inspect and modify only the files actually required, likely including:

* `extensions/flowfield/godot/agent_manager_native.cpp`
* its corresponding header
* `extensions/flowfield/agent_manager/agent_manager.cpp`
* `extensions/flowfield/godot/flow_field_native.cpp`
* flow-field manager/config files if required
* `scripts/map/spawner_route_service.gd`

Do not expand unrelated managers.

## Acceptance criteria

After the patch:

1. GDScript can always explicitly dissolve native route groups.
2. Releasing a route cancels/invalidate its outstanding async requests.
3. A result from a dissolved or reused group cannot be applied.
4. Rebuilding a group that already owns a field does not require a free temporary pool slot.
5. No failure path leaves a group permanently in `GROUP_FLOW_WAIT_COMPUTING`.
6. Obsolete unused spawner/garden route groups are released deterministically.
7. Active agents never lose a route group that they still reference.
8. Repeated day/night cycles and route invalidations do not monotonically increase occupied field slots.
9. Pool diagnostics clearly distinguish legitimate capacity pressure from leaked fields/groups.
10. Existing client and monster route behavior remains unchanged apart from fixing missing/stuck routes.

## Final response

Provide:

* the exact root causes confirmed in the code
* the files changed
* the ownership/lifecycle sequence after the fix
* how stale async results are rejected
* how in-place replacement avoids temporary pool exhaustion
* the route-cache cleanup rule
* any remaining legitimate maximum-route limitation

Do not claim runtime validation because Godot/build/tests must not be run.
