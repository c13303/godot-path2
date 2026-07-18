# Task: Fix and optimize sheep villager debris-eating and repair task performance

Investigate and fix the small frame hitches associated with the sheep villager:

* while eating debris;
* when debris disappears and the sheep chooses its next task;
* while repairing damaged buildings.

Read `AGENTS.md` and `ARCHITECTURE.md` first. Respect the existing module boundaries, strict typing rules, ownership rules, and performance requirements.

The objective is to remove objectively wasteful work without changing sheep gameplay behavior.

## Confirmed suspicious areas

### 1. Periodic full scan of the plant TileMapLayer

In `sheep_garden_role.gd`, the sheep currently refreshes its debris index approximately every 0.5 seconds by iterating over:

```gdscript
plantz.get_used_cells()
```

This continues even while the sheep is walking, eating, repairing, or otherwise busy.

This is not acceptable as the normal runtime synchronization mechanism.

### Required fix

Make the sheep debris index primarily event-driven.

The system should:

1. Perform one initial authoritative debris scan when the sheep role/runtime is initialized.
2. Maintain the debris index incrementally when debris is:

   * created;
   * removed;
   * consumed by the sheep;
   * removed by another system;
   * restored by save/load or level initialization.
3. Ensure all debris-producing paths use the same authoritative notification/API.
4. Remove the recurring full plant-layer scan from normal gameplay.

A rare defensive reconciliation may remain only if genuinely necessary, but it must not run every 0.5 seconds. Prefer fixing missing event paths instead of retaining polling.

Do not let the sheep role become responsible for observing unrelated plant internals. Use the existing plant/debris ownership module, or introduce a small generic debris registry/API in the correct owner if the current APIs are incomplete.

The registry must not retain stale cells after debris is removed.

---

### 2. Sheep pathfinding rebuilds the complete walkability map for every path request

Inspect `building_path_service.gd`, especially `find_sheep_path()`.

The current path request appears to:

* iterate through every used floor cell;
* recompute sheep walkability for every cell;
* allocate a new dictionary and packed array;
* rebuild native pathfinder walkable/blocked sets;
* then run the actual path query.

This may happen again for each candidate target tested by the sheep.

This is likely the main one-frame hitch when the sheep finishes eating or repairing and chooses another task.

### Required fix

Introduce a safely cached sheep pathfinding topology.

The expensive static data must be rebuilt only when relevant topology changes, not once per path query.

Relevant invalidations likely include:

* blocking wall placement/removal;
* blocking building placement/removal;
* plant/debris changes if those cells affect sheep walkability;
* level load/reload;
* save restoration;
* any existing hard navigation/topology invalidation event.

Do not invalidate for cosmetic changes, health changes, animations, rewards, or unrelated agent movement.

Provide a clear API such as the equivalent of:

```gdscript
invalidate_sheep_topology(reason)
ensure_sheep_topology_synced()
find_sheep_path(start_cell, target_cell)
```

Exact naming should follow the existing architecture.

### Candidate path testing

When the sheep evaluates multiple debris or repair candidates:

* synchronize/rebuild the cached topology at most once for the task-selection pass;
* then run multiple path queries against that same cached representation;
* do not rebuild the complete map separately for every candidate;
* preserve the existing bounded candidate attempt limit;
* preserve current target priority and selection semantics unless an existing bug is discovered.

Prefer a dedicated sheep pathfinder instance or another clean ownership mechanism if the currently shared native pathfinder state is overwritten by unrelated callers.

Do not introduce per-frame synchronization or continuous topology comparisons.

---

### 3. Repairing repeatedly refreshes the complete building-health overlay

Inspect:

* `sheep_garden_role.gd`;
* `player_placeable_durability_service.gd`;
* `building_health_overlay.gd`.

The repair loop appears able to call `apply_repair()` many times per second.

Each repair increment refreshes the overlay, and the overlay obtains damaged records by iterating over every registered durability target.

With many walls/buildings, this creates unnecessary repeated global scans while one structure is being repaired.

### Required fix

Make repair and overlay updates incremental or reasonably batched.

Preferred structure:

1. Durability ownership maintains an indexed set/dictionary of currently damaged records.
2. A target enters that index when health changes from full to damaged.
3. A target leaves that index when:

   * fully repaired;
   * destroyed;
   * removed;
   * unloaded.
4. The overlay iterates only the currently damaged records.
5. Repairing one target should update only that target’s visual state whenever practical.

Additionally, avoid applying tiny repair increments every rendered frame if that causes excessive signal/UI churn.

A small fixed repair tick is acceptable, for example 10–15 updates per second, provided:

* total repair duration remains exactly equivalent;
* fractional progress is accumulated correctly;
* repair rates remain frame-rate independent;
* no health is lost because of integer truncation;
* the final repair always reaches full health exactly;
* gameplay timing and balancing remain unchanged.

Do not merely hide the health overlay during sheep repairs. Fix the underlying update cost.

---

### 4. Debris removal TileMap operations

Inspect the debris-consumption sequence, especially calls equivalent to:

```gdscript
plantz.erase_cell(cell)
plantz.update_internals()
plantz.queue_redraw()
```

Determine whether `update_internals()` is actually required immediately after every consumed debris cell.

Do not remove it blindly.

If Godot already batches the TileMapLayer update safely, avoid forcing a synchronous internal update. If another same-frame system requires the updated state, replace the global synchronous flush with the narrowest safe alternative.

Also avoid stacking all of these expensive actions in the same frame:

* TileMap synchronous flush;
* reward creation;
* global debris rescan;
* complete path topology rebuild;
* multiple candidate path queries.

After the topology cache fix, selecting the next task in the same frame should normally be safe. Do not add artificial deferred-frame latency unless profiling still shows a meaningful spike.

---

## Safety and architecture constraints

* Preserve all current sheep behavior and timings.
* Preserve debris rewards.
* Preserve task priority and candidate limits.
* Preserve path correctness and unreachable-target handling.
* Preserve save/load behavior.
* Preserve dynamic building and plant changes.
* Do not introduce stale caches.
* Do not add per-frame polling.
* Do not replace bounded work with a hidden global scan.
* Do not make the C++ extension sheep-specific unless the existing architecture clearly requires a generic native API.
* Generic C++ APIs are acceptable; game-specific sheep rules should remain in GDScript.
* Avoid a new monolithic manager.
* Use existing invalidation/event infrastructure where possible.
* Do not rebuild unrelated global flow fields for sheep A* changes.
* Do not change normal client, monster, villager, or player navigation.
* Do not perform speculative unrelated refactors.

If the existing debris creation APIs are fragmented, consolidate them behind a small authoritative API rather than adding more parallel signals.

If an existing shared cache already solves part of this problem, reuse it rather than introducing another cache.

---

## Diagnostics

Add lightweight development-only telemetry around:

* sheep topology cache rebuild duration;
* number of topology rebuilds;
* number of sheep path queries;
* candidate path attempts per task-selection pass;
* debris registry initial scan duration;
* unexpected debris registry reconciliation;
* durability overlay refresh duration;
* number of damaged targets currently indexed.

Logs must not spam every frame.

Useful warnings include:

* debris registry receives removal for an unknown cell;
* cached sheep topology remains dirty unexpectedly across several requests;
* topology rebuild happens multiple times during one task-selection pass;
* destroyed/unloaded durability target remains in the damaged index.

Remove temporary noisy diagnostics after validation, while retaining useful threshold-based debug telemetry if consistent with the project.

---

## Validation scenarios

Test at minimum:

1. One sheep eating one debris item.
2. Several debris items close together.
3. Debris items spread across the map.
4. Debris created after level start.
5. Debris removed by something other than the sheep.
6. Save and reload with debris present.
7. Sheep completes eating and immediately selects another reachable task.
8. First several candidates are unreachable.
9. Wall placed or removed between sheep errands.
10. Blocking building placed or removed.
11. Multiple damaged buildings.
12. Large number of player-built walls with one building being repaired.
13. Target destroyed or removed while the sheep is walking to it.
14. Target fully repaired by another source before sheep arrival.
15. Sheep interrupted by night transition.
16. Reload during an active or partially completed task.

Check that:

* the sheep never walks toward stale debris;
* the sheep never repairs a deleted target;
* newly created debris becomes discoverable immediately;
* path topology rebuild occurs only after relevant invalidation;
* one task-selection pass performs no more than one topology synchronization;
* repair duration is unchanged;
* no new frame-time spikes are introduced;
* no other navigation groups regress.

---

## Expected report

After implementation, report:

1. Exact root causes confirmed.
2. Files changed.
3. Event/invalidation ownership used.
4. What now causes a sheep topology cache invalidation.
5. What no longer performs full-layer or full-building scans.
6. Before/after telemetry for:

   * debris refresh;
   * path preparation;
   * task selection;
   * repair processing;
   * health overlay refresh.
7. Any remaining unavoidable synchronous TileMap cost.
8. Any non-generic, duplicated, or structurally unsafe code discovered during the task.

Do not claim the hitch is fixed solely because the code looks cleaner. Validate with measurements and describe the measured result.
