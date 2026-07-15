## Task: Fix Starpath invalidation on rose harvest and keep Starpaths visible during active phases

Read `AGENTS.md` first and preserve the existing architecture. Do not solve this by adding another broad watcher, polling loop, or manager-level special case.

Do not run Godot, tests, compilation, export, or build commands. The user will test manually.

### Current problem

During Dawn, harvesting a rose triggers the plant-layout invalidation pipeline.

The current sequence appears to be:

* rose removal marks the plant layout dirty;
* `path_preview_controller` sees `plant_layout_dirty()` and clears all routes immediately;
* after the debounced garden rebuild, the global navigation/topology revision changes;
* that revision is part of each preview-route signature;
* all Starpaths are therefore destroyed and rebuilt, even when their actual path is unchanged.

The visible result is that client Starpaths blink, disappear, restart, and are unnecessarily recomputed after ordinary rose harvesting.

This is too coarse.

A rose edit can change garden membership or a destination in exceptional cases, but it does not change the external walkable maze in the same way that walls or blocking structures do.

---

## Required behavior

### 1. Do not blank Starpaths during plant-only rebuilds

When the plant layout becomes dirty:

* keep the currently displayed Starpaths alive;
* do not call a blanket `_clear_routes()`;
* do not stop or restart unchanged runners;
* let the debounced garden-layout rebuild complete in the background of the existing preview.

A plant-only edit must not create a visible blank interval.

### 2. Selectively update routes after the garden rebuild

Once the garden topology/descriptors have been rebuilt:

* prepare the new route descriptors;
* compare each new descriptor with the currently active route;
* only replan or replace routes whose meaningful routing identity changed;
* preserve unchanged route instances and their current animation progress.

Meaningful descriptor changes include at least:

* route start cell changed;
* destination garden changed;
* destination entry cell changed;
* route became available or unavailable;
* route type changed;
* relevant flow-field/group identity changed.

Do not restart every Starpath because an unrelated global revision counter changed.

### 3. Separate walkability invalidation from plant-layout invalidation

The preview system must distinguish:

#### External walkability changes

Examples:

* wall added or removed;
* blocking building added or removed;
* door or equivalent navigation obstacle changed;
* any edit that changes the actual cost field or traversable external maze.

These changes must force route replanning, even when the route keeps the same:

* start cell;
* destination cell;
* garden ID;
* group ID.

Use the existing appropriate navigation/walkability revision if one already exists, or introduce a narrowly owned revision representing external route-field contents.

#### Plant or garden-layout changes

Examples:

* rose harvested;
* rose added or removed;
* plant cluster metadata rebuilt;
* garden destination metadata changed without changing the external maze.

These must only cause descriptor refresh and selective replacement.

Do not use one coarse global revision as the identity of every preview route.

### 4. Do not blindly remove revision protection

Do not merely delete `topology_revision` from the route signature unless it is replaced with a revision that correctly represents external walkability changes.

Otherwise this bug would be introduced:

* a wall changes the route field;
* start and destination remain the same;
* group ID remains the same;
* the preview incorrectly reuses the obsolete polyline.

The final solution must retain correctness for wall/building topology changes.

### 5. Replace changed routes atomically

When a route genuinely requires replanning:

* keep the old route visible while the replacement is prepared where practical;
* switch to the replacement only when it is ready;
* avoid globally clearing all routes before rebuilding them;
* do not restart unrelated runners.

The preview should remain visually continuous.

---

## Starpath visibility lifecycle

Starpaths must not disappear merely because agents have started moving.

### Monster Starpaths

Monster Starpaths must:

* be visible during their preview period;
* remain visible throughout the Night while monsters are actively moving;
* disappear only when the monster phase is actually over or the routes are otherwise no longer relevant.

If they already remain visible at Night, preserve that behavior and verify that this fix does not regress it.

### Client Starpaths

Client Starpaths must:

* be visible at Dawn when client routes are previewed;
* remain visible while clients are actively walking during the client-sale phase;
* disappear only once the client movement/sale phase is actually over or the routes are no longer relevant.

Do not tie visibility only to the passive preview phase if that causes them to disappear as soon as clients spawn.

Preserve the existing distinction between client routes and monster routes. Do not merge unrelated client Starpaths together as part of this task.

---

## Expected implementation approach

Inspect the ownership and existing APIs around at least:

* `path_preview_controller.gd`;
* `building_invalidation_controller.gd`;
* `spawner_route_service.gd`;
* `garden_topology_service.gd`;
* the phase/state owner controlling Dawn, client sale, and Night visibility;
* plant removal and plant-layout rebuild completion callbacks.

Before editing, identify:

* which component owns preview-route identity;
* which component owns external navigation revisions;
* which component emits completion of plant-layout rebuilds;
* which component decides whether client and monster Starpaths should currently be visible.

Keep these responsibilities separated.

Prefer a model similar to:

* `walkability_revision` invalidates actual planned geometry;
* descriptor equality detects destination changes;
* plant-layout dirty state does not clear existing previews;
* phase visibility determines whether each route family remains displayed.

Do not add route-specific logic to `building_manager.gd` if the existing preview/invalidation services can own it cleanly.

---

## Important edge cases

Handle these explicitly:

1. Harvesting one ordinary rose:

   * existing client Starpaths remain visible;
   * no runner restarts if route identity and geometry are unchanged.

2. Harvesting several roses rapidly:

   * existing debounce remains effective;
   * no repeated clear/restart flicker;
   * ideally one descriptor refresh after the quiet period.

3. Removing the last relevant rose from a garden:

   * routes whose destination becomes invalid are removed or redirected correctly;
   * unrelated routes remain untouched.

4. A plant edit changes garden grouping or selected entry:

   * only affected routes are rebuilt.

5. Adding or removing a wall:

   * affected route geometry is definitely replanned;
   * an old route is not retained solely because start and destination IDs match.

6. During Night:

   * monster Starpaths remain visible while monsters move.

7. During the client-sale phase:

   * client Starpaths remain visible while clients walk.

8. End of the relevant phase:

   * obsolete route family is cleaned up normally;
   * no permanent stale preview remains.

9. Save/load or level reset:

   * no stale route instances or revision state survive incorrectly.

---

## Performance constraints

* No per-frame descriptor rebuilding.
* No per-frame full-route comparison using large arrays if avoidable.
* No polling watcher.
* Reuse the existing debounced/budgeted plant-layout rebuild.
* Preserve current route runners when unchanged.
* Do not recompute every route after every rose harvest.
* Do not add expensive byte-for-byte polyline comparison if stable semantic identity plus a correct walkability revision is sufficient.

The goal is less work than the current implementation, not a more complex invalidation layer that costs more every frame.

---

## Deliverable

Implement the fix and then report:

1. root cause confirmed in the actual code;
2. files changed;
3. how plant-layout invalidation is now distinguished from external walkability invalidation;
4. how unchanged runners are preserved;
5. how Night monster-Starpath visibility is maintained;
6. how client Starpaths remain visible while clients are walking;
7. any unavoidable edge case or architectural caveat.

Do not report success based only on code inspection. Clearly state what the user must manually verify in Godot.
