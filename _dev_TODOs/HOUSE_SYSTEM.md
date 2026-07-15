Read `AGENTS.md` first and follow it strictly.

## Task

Fix the Builder performance and idle-home recovery implementation without redesigning unrelated navigation systems.

The current Builder behavior works, but repeatedly uses expensive global operations for tiny local movements.

Do not run Godot, tests, builds, compilation, or export.

## Confirmed problems

### 1. Construction shuffling uses the full global A* pipeline

Current chain:

```text
HouseBuilderWorkController._try_start_local_move()
→ BuilderController.request_builder_local_work_move()
→ DayVisitorMovementController.repath_to_target()
→ BuildingPathService.find_path_on_walkable_map()
→ sync_pathfinder_zone_tiles()
```

`find_path_on_walkable_map()` resends the entire walkable map and scans blockers.

This currently happens every `0.8–1.4` seconds while a Builder moves between nearby cells around the same house.

That is unacceptable for a tiny visual work movement.

### 2. Idle-home correction runs every frame

`BuilderController.process_active_visitors()` currently calls:

```gdscript
_process_idle_home_correction()
_process_builder_motion_watchdog(delta)
```

An idle house Builder displaced from its claimed cell can immediately request another full A* path. Under continuous pushing, this can repeatedly repath.

The requirement is only:

> A house Builder who is idling near its house and gets meaningfully pushed away must eventually return.

This must be implemented lazily, not checked/repathed every frame.

### 3. Candidate checks repeatedly scan every agent

`BuilderController._is_candidate_available()` calls:

```gdscript
_manager.occupied_cells_for_spawning()
```

That recreates an array by scanning all nodes in:

```text
main_chars
monsters
clients
merchants
builders
player
```

This can happen once per candidate cell and repeatedly during construction shuffling.

### 4. Debug watchers

* `BuilderController._process_builder_motion_watchdog()` runs every frame even when debug logging is disabled.
* `agent_registration_consistency_watcher.gd` does not include the `builders` group, causing Builders to appear as false native-registration leaks.

---

# Required implementation

## A. Use a bounded local path for construction shuffling

Modify the local construction movement only:

```gdscript
BuilderController.request_builder_local_work_move()
```

It must no longer call:

```gdscript
DayVisitorMovementController.repath_to_target()
_manager.find_path_on_walkable_map()
BuildingPathService.sync_pathfinder_zone_tiles()
```

Implement a small bounded local path search:

* four-directional tile movement;
* only inspect a small area around the current and destination cells;
* use `BuildingManager.is_walkable_cell()` as the walkability source of truth;
* never rebuild or synchronize the global PathfinderNative walkable map;
* never scan all map walls/buildings;
* return a short `PackedVector2Array` cell path.

The local search must have a hard bounded scope. A maximum local search distance around `8–12` tiles is sufficient because work cells are generated within `HOUSE_WORK_CELL_SEARCH_RADIUS = 3`.

Add one small explicit-path API to `DayVisitorMovementController`, for example:

```gdscript
func assign_cell_path(destination_cell: Vector2i, path_cells: PackedVector2Array) -> bool
```

It must:

* convert the provided cells with the existing `path_cells_to_world()` behavior;
* call native `assign_agent_path`;
* update `_target_cell`;
* update `_waiting`;
* call `start_astar_in()` consistently with normal paths.

Do not duplicate the native path-assignment code in `BuilderController`.

If the bounded local path fails:

* do not fall back to global A* for a construction shuffle;
* leave the Builder at its current work position;
* return it to the pause phase so it can try another candidate later.

Full A* remains correct and allowed for:

* initial travel from home to a WIP house;
* returning to the home area;
* entering/leaving the level;
* night departure;
* explicit topology-change repathing.

Do not change those long-distance paths.

## B. Cache house work-cell candidates

`HouseBuilderWorkController._work_cell_candidates()` currently rebuilds the same ring candidates repeatedly.

Cache the static candidate list by `house_id`.

Invalidate that cache when:

* the WIP house is removed;
* navigation topology changes;
* controller state is cleared/restored;
* the house no longer exists.

Dynamic occupancy must still be checked when selecting a candidate. Do not cache whether a cell is occupied.

## C. Use `AgentCellTracker` for occupancy queries

Do not call `occupied_cells_for_spawning()` from normal Builder candidate checks.

Add a focused read-only query to `AgentCellTracker`, such as:

```gdscript
func is_cell_occupied(cell: Vector2i, excluded_agent: Node2D = null) -> bool
```

It must use the existing `_cell_to_agents` index.

Requirements:

* exclude the requesting Builder itself;
* ignore invalid or queued-for-deletion nodes;
* return immediately when a valid occupant is found;
* do not allocate a complete occupied-cell array.

Use this query from:

```gdscript
BuilderController._is_candidate_available()
```

Keep `occupied_cells_for_spawning()` for rare spawn-time operations; this task does not require refactoring all existing spawning systems.

## D. Make idle-home correction lazy

Replace the per-frame idle correction with a low-frequency check.

Use approximately:

```text
check interval: 0.5 seconds
displacement grace: 1.0 second
failed repath retry cooldown: 1.0 second
```

Only inspect Builders that are:

* house-bound;
* active;
* daytime;
* not working;
* not leaving;
* in `STATE_IDLE`;
* currently waiting.

Track the exact assigned target world position in `DayVisitorMovementController` so displacement is measured against the actual dispersed path endpoint, not merely the tile center.

Add a read-only getter such as:

```gdscript
func target_world_position() -> Vector2
```

Update this position whenever a path or parked target is assigned.

A Builder should be considered displaced only when its distance from that target exceeds a meaningful threshold, approximately `0.4–0.5` tile.

It must remain displaced for the grace duration before requesting a return path.

After requesting a return:

* clear the displacement timer;
* do not retry before the cooldown expires;
* sustained pushing must not cause repeated path requests every frame.

### Failed return handling

`return_builder_to_idle_area()` currently calls `_park_builder_at_current_cell()` when no return target/path is available. This permanently turns the remote current cell into the Builder’s idle target.

Fix this.

A failed return may temporarily park the Builder, but it must preserve a pending “return to home area” intent and retry lazily after the cooldown.

Do not permanently redefine the Builder’s home/idle area because one path attempt failed.

Keep this retry state inside `BuilderController`; do not add it to `BuildingManager`.

## E. Debug watchers

### Builder motion watchdog

Only execute `_process_builder_motion_watchdog(delta)` when:

```gdscript
CppDebugOptions.logs_enabled
```

When debug logging is disabled:

* do not create `active_ids`;
* do not iterate Builders for stall diagnostics;
* clear stale watchdog dictionaries once when needed.

Do not remove the warnings; just make the watcher genuinely debug-only.

### Registration watcher

In:

```text
scripts/debug/agent_registration_consistency_watcher.gd
```

add:

```gdscript
&"builders"
```

to `TRACKED_GROUPS`.

Do not change the watcher’s diagnostic-only behavior.

---

# Behavior that must remain unchanged

Preserve:

* multiple Builders;
* one Builder per completed Builder house;
* the fundamental Builder fallback;
* WIP house build order;
* 20-second construction progress;
* hammer animation cadence;
* Builder movement around a WIP house;
* night interruption and departure;
* construction resuming on the next day;
* house save/load behavior;
* Builders being respawned from house state rather than saved individually.

Do not modify:

* the C++ extension;
* general monster/client pathfinding;
* flow fields;
* general `BuildingPathService` behavior;
* savegame format;
* unrelated building systems.

Do not move this logic into `BuildingManager`.

## Expected files

Primary files:

```text
scripts/map/builder_controller.gd
scripts/map/house_builder_work_controller.gd
scripts/map/day_visitor_movement_controller.gd
scripts/map/agent_cell_tracker.gd
scripts/debug/agent_registration_consistency_watcher.gd
```

Only modify additional files when strictly required.

## Acceptance criteria

1. During ordinary construction, repeated local Builder shuffles never call `find_path_on_walkable_map()` or `sync_pathfinder_zone_tiles()`.
2. Initial travel to a house still uses normal full A*.
3. Builder work-cell candidates are not regenerated every pause cycle.
4. `_is_candidate_available()` no longer creates a complete occupied-agent array.
5. An idle house Builder pushed away returns after a short grace period.
6. Continuous pushing does not generate per-frame path requests.
7. A failed home return is retried later and does not permanently redefine the current remote cell as home.
8. With debug disabled, the Builder stall watchdog performs no per-frame Builder scan.
9. The registration consistency watcher recognizes Builders.
10. Multiple Builders cannot claim the same work or idle cell.
11. Wall/topology changes invalidate local candidate caches and preserve correct long-range repathing.
12. No Builder, house, construction, dawn/night, or save/load regression.

At the end, report:

* changed files;
* the bounded-local-path algorithm and its hard limit;
* every remaining situation where Builders use full global A*;
* how idle return retry/debounce works;
* cache invalidation points;
* manual test scenarios.

Do not perform broad cleanup outside this task.
