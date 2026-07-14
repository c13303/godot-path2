# PathPreview final repair — remove duplicate navigation and make it a pure view

Work from the attached updated codebase.

Follow `AGENTS.md`.

Do not run Godot, tests, compilation, export, or build commands. The user performs runtime testing.

This is one focused architectural correction. Do not add another fallback, timer workaround, pixel offset, or parallel scheduler.

---

## Confirm the current defective implementation before editing

The attached code still contains the wrong architecture.

Verify these points in the current files before changing anything:

1. `PathPreviewController` calls or indirectly calls:

```gdscript
ensure_path_preview_topology_ready()
```

2. That call can synchronously execute expensive garden/navigation preparation such as:

```gdscript
_sync_flow_extra_blocking_cells()
_rebuild_walkable_map_cache()
_build_plant_zone()
```

3. `PathPreviewController` independently:

* selects gardens;
* selects entry cells;
* allocates temporary native flow groups;
* requests new flow-field computations;
* tracks their readiness;
* destroys them when the preview changes.

4. The current controller still creates an outbound preview leg:

```text
garden entry -> despawner
```

5. `PathPreviewRunner` still contains an invalid comparison equivalent to:

```gdscript
route_cost <= arrival_radius
```

where route cost is measured in tile traversal cost and arrival radius is measured in pixels.

6. The debug overlay independently recomputes garden entrance/exit cells rather than displaying the endpoint used by the actual prepared route.

If any of these have already been partially changed, adapt the patch to the current code, but preserve the required final architecture below.

---

# Required final architecture

There must be exactly one ownership chain:

```text
GardenTopologyService / invalidation owner
    prepares garden topology lazily

SpawnerRouteService
    prepares and owns real inbound spawner routes

PathPreviewController
    reads those prepared routes and displays them

PathPreviewRunner
    follows an existing ready route group
```

PathPreview must no longer own navigation preparation.

---

# 1. PathPreview must never rebuild garden topology

Remove every call from PathPreview that can prepare, rebuild, validate, or mutate garden topology.

In particular, `PathPreviewController` must not call:

```gdscript
ensure_path_preview_topology_ready()
_build_plant_zone()
_rebuild_walkable_map_cache()
clear_plant_layout_dirty()
mark_navigation_rebuild_completed()
```

directly or through a PathPreview-specific helper.

Delete `ensure_path_preview_topology_ready()` if it exists only for PathPreview.

If other code still uses it, remove only the PathPreview call and report the remaining callers.

## Required behavior after rose placement

Rose placement may only:

```text
mark plant/garden topology dirty
schedule the existing lazy/debounced topology preparation
return immediately
```

It must not synchronously rebuild gardens for the preview.

PathPreview must tolerate topology being temporarily dirty or unavailable:

```text
topology not ready = no preview yet
```

No warning is required. The stars may appear later.

---

# 2. Reuse the existing lazy garden preparation lifecycle

Find the existing quiet-period/budgeted preparation mechanism used for expensive navigation changes such as wall edits.

Reuse or minimally generalize that existing owner.

Do not create:

* a PathPreview timer queue;
* `await process_frame` loops;
* a second scheduler;
* a thread owned by PathPreview;
* repeated polling that starts expensive work;
* immediate rebuilds from rose-placement callbacks.

## Required plant-layout flow

Implement this lifecycle:

```text
rose placed
→ mark plant layout dirty
→ reset existing navigation/garden quiet period
→ after the quiet period, begin the existing budgeted garden rebuild
→ publish/advance the normal garden topology revision
→ request actual spawner-route preparation
```

Drawing several roses quickly must coalesce into one preparation cycle after the player pauses.

Do not rebuild the walkable map cache when only plants changed unless static inspection proves that plant placement actually changes walkability.

Do not clear dirty state from PathPreview.

The topology/invalidation owner clears its own dirty state only after successful preparation.

---

# 3. SpawnerRouteService must own the prepared inbound routes

Use `SpawnerRouteService` as the sole owner of spawner-to-garden route descriptors and flow groups.

The route descriptor for each relevant upcoming monster spawner must expose at least:

```gdscript
spawner_cell
garden_id
entry_cell
entry_world
group_id
ready
topology_revision
```

Use the existing equivalent fields and structures where possible. Do not introduce a second descriptor type if the service already has one.

## Route semantics

Prepare exactly one monster route per active upcoming-night spawner:

```text
spawner -> selected garden entry
```

Do not prepare a visual exit route.

Do not prepare:

```text
garden entry -> despawner
```

for PathPreview.

Actual monsters may continue using their existing runtime escape flow after eating. That behavior is unrelated and must remain untouched.

## Shared computation

The flow group displayed by PathPreview must be the same prepared inbound route group owned by `SpawnerRouteService`.

PathPreview must not allocate a duplicate group.

PathPreview must not call:

```gdscript
request_group_flow_rebuild_with_policy()
assign_flow_to_group()
request_flow_to_group()
```

for its own cosmetic group.

If the service currently destroys these routes before the night begins, adjust their lifecycle so the prepared routes remain valid through the preview and can be reused by runtime navigation where compatible.

Do not maintain two groups representing the same:

```text
spawner + garden + entry + navigation policy
```

## Navigation policy

The prepared monster route must use the real monster policy.

For example, if monsters can cross fences:

```text
monster preview/runtime route: fences do not block
```

Do not derive navigation policy from the fact that the current phase is afternoon.

The route descriptor must explicitly represent the route kind or policy.

---

# 4. PathPreviewController becomes a pure consumer

After this patch, `PathPreviewController` may only:

* determine whether preview should currently be visible;
* obtain active upcoming-night spawner IDs/cells;
* query `SpawnerRouteService` for prepared route descriptors;
* wait until a descriptor is `ready`;
* create/reuse a visual runner for the descriptor’s `group_id`;
* recycle visuals when routes disappear or the phase changes.

It must not:

* rebuild topology;
* select a garden independently;
* select an entry independently;
* resolve a despawner;
* allocate flow groups;
* request flow computation;
* mutate navigation revisions;
* clear dirty flags.

## No-garden and not-ready states

When there is no garden:

```text
no route descriptor
no stars
no warnings
```

When topology exists but route preparation is not finished:

```text
descriptor absent or not ready
no star yet
no synchronous work
```

When the route becomes ready:

```text
spawn the runner using the existing group_id
```

The preview may appear several frames after planting. Smooth planting is more important than immediate visualization.

## Route identity

Use the service-owned route identity or a stable key such as:

```text
spawner cell
garden ID
entry cell
topology revision
group ID
```

When that identity changes:

* recycle the old runner;
* create a runner for the new ready route;
* do not dissolve the group from PathPreview.

`SpawnerRouteService`, not PathPreview, owns group destruction.

---

# 5. Remove all outbound preview code

Delete from the preview feature:

* outbound leg construction;
* escape-cell lookup used by preview;
* outbound route signatures;
* outbound runner creation;
* outbound counters;
* outbound debug output;
* preview-owned outbound groups.

For two active monster spawners, the final preview must contain:

```text
2 inbound routes
2 runners maximum
0 outbound routes
```

Do not simply hide outbound stars while still computing their fields.

---

# 6. Repair PathPreviewRunner completion logic

The runner must follow the shared route group to the exact selected entry tile.

## Delete the invalid unit comparison

Remove any condition equivalent to:

```gdscript
if route_cost <= arrival_radius:
    finish()
```

Do not convert pixels to tiles to preserve this logic.

Route cost is not world-space distance.

## Authoritative normal arrival

Use:

```gdscript
_world_position.distance_to(_goal_world) <= _arrival_radius
```

for visible arrival.

Both values are world-space coordinates.

## Handle the native goal cell correctly

The native flow direction may be `Vector2.ZERO` inside the goal cell because its route cost is `0.0`.

When:

```gdscript
flow_direction == Vector2.ZERO
```

query route cost.

If route cost is finite and approximately zero:

```gdscript
route_cost <= 0.001
```

move directly toward `_goal_world`.

Clamp the final movement step so it cannot overshoot:

```gdscript
var remaining: float = _world_position.distance_to(_goal_world)
var movement: float = minf(speed * delta, remaining)
_world_position += direction_to_goal * movement
```

Do not directly steer toward the goal when route cost is nonzero. That could cross walls.

## Remove the fixed normal lifetime failure

A fixed lifetime such as:

```gdscript
max_runner_lifetime = 8.0
```

cannot be used as a normal completion rule because valid routes may be longer than:

```text
speed × 8 seconds
```

Replace it with a stalled-progress safety watchdog.

Track meaningful progress, for example:

```text
distance to goal decreases
or route cost decreases
or world position changes sufficiently
```

Only recycle as stalled after no meaningful progress for a generous duration.

A long but progressing valid route must be allowed to continue.

Retain protection against genuinely unreachable or frozen routes.

---

# 7. Debug overlay must show the shared route endpoint

Stop independently deriving “entrance” and “exit” markers from garden boundary cells.

The overlay must read the same prepared route descriptors from `SpawnerRouteService`.

For each active prepared route, draw exactly:

```gdscript
descriptor.entry_cell
```

Use one clearly documented color for:

```text
selected monster garden entry
```

The user expects this marker to indicate the endpoint reached by the star.

Remove the green fictional exit marker completely.

There is no need to display a selected garden exit because runtime monsters no longer navigate through such a waypoint after eating.

Do not remove generic garden boundary data from `GardenTopologyService`; it may still be required for entry selection.

Only remove the misleading overlay calculation and display.

## Expected overlay relationship

For every visible preview runner:

```text
runner goal cell == displayed entry marker cell
```

No separate resolver call is permitted in the overlay.

---

# 8. Remove polling that performs work

A lightweight poll that only checks revisions/readiness is acceptable if the current architecture has no signal.

A poll must never:

* rebuild gardens;
* request new groups;
* take full-map snapshots;
* mutate dirty state.

Prefer existing signals/revision notifications where already available.

Do not create a large new event framework solely for this patch.

---

# 9. Remove obsolete PathPreview code

After converting PathPreview to a pure consumer, delete obsolete code rather than leaving it dormant.

Expected removals include, where present:

```text
preview leg plan structures
preview group allocation helpers
preview group dissolution helpers
preview flow request callbacks
preview-specific topology preparation
escape target resolution
outbound direction values
temporary route statistics
test diagnostics
per-group wait logs
direct-no-garden fallback
```

Keep runner pooling and visual animation code.

Keep strict GDScript typing.

Do not perform unrelated cleanup.

---

# Mandatory code searches before finalizing

Search the repository for all callers/references to:

```text
ensure_path_preview_topology_ready
request_group_flow_rebuild_with_policy
direct_no_garden
outbound
arrival_cost
max_runner_lifetime
get_garden_exit_tiles
get_garden_enter_tiles
EXIT_COLOR
```

Confirm that no obsolete PathPreview-owned route computation remains.

Also search for every construction of `PathPreviewRunner` and verify that each runner receives a service-owned ready `group_id`.

---

# Manual acceptance criteria

The user will test these cases.

## A. Draw the first roses

Expected:

* rose placement remains responsive;
* no immediate full garden rebuild from PathPreview;
* no preview-native group allocation occurs in the rose-placement call stack;
* stars may appear after the existing quiet/budgeted preparation completes.

## B. Draw several roses continuously

Expected:

* repeated placements coalesce;
* no rebuild per rose;
* no repeated destruction/recreation of preview-owned groups;
* one route refresh occurs after the quiet period.

## C. No garden

Expected:

* no preview;
* no group request from PathPreview;
* no warnings;
* no direct spawner-to-despawner fallback.

## D. Route reaches the garden

Expected:

* star follows the full inbound route;
* star does not stop approximately 12 tiles early;
* star is not killed after an arbitrary eight seconds while progressing;
* star enters the selected entry tile;
* star moves toward the exact entry-cell center after reaching native route cost zero.

## E. Debug marker

Expected:

* one selected-entry marker per prepared route;
* marker is on the same cell used as runner goal;
* no fictional exit marker;
* no independently recomputed entrance.

## F. Two active spawners

Expected:

```text
2 shared inbound route groups
2 preview runners maximum
0 outbound preview groups
0 PathPreview-owned groups
```

## G. Phase transition

Expected:

* PathPreview recycles its visual runners;
* it does not destroy service-owned route groups merely because the visual phase ended;
* route ownership remains with `SpawnerRouteService`.

## H. Runtime monsters

Expected:

* monsters use the prepared inbound route correctly;
* monsters still transition to garden targeting;
* monsters still escape after eating through the existing runtime escape system;
* no runtime exit behavior was removed.

## I. Wall modification

Expected:

* normal wall invalidation still rebuilds routes through the existing lazy system;
* prepared route descriptors update;
* PathPreview follows the replacement groups without creating duplicates.

---

# Required final report

Provide a concrete report containing:

1. Exact files changed.
2. The old synchronous rose-placement-to-preview call chain that was removed.
3. The existing lazy/debounced owner now responsible for plant topology preparation.
4. The `SpawnerRouteService` structure/API used by PathPreview.
5. Proof that PathPreview no longer allocates or requests any flow group.
6. Proof that only one inbound route exists per active spawner.
7. Proof that the outbound preview was deleted rather than hidden.
8. The exact invalid runner completion conditions removed.
9. The new goal-cell and stalled-progress behavior.
10. The exact debug overlay source for `entry_cell`.
11. Repository-search results for the obsolete symbols listed above.
12. Confirmation that actual monster escape navigation was untouched.
13. Confirmation that Godot/tests/builds were not run.

Do not claim runtime validation.

Do not return a partial cosmetic fix. If the current code structure prevents one part of this ownership model, explain the concrete blocker in the final report, but complete every other required deletion and correction.
