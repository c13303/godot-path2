Task: reduce `scripts/map/building_manager.gd` by extracting garden access/entry resolution into a dedicated RefCounted controller/service.

Context:
`BuildingManager` is still too large. A good next extraction is the garden access scoring + nearest-entry cache logic currently near the bottom of `building_manager.gd`.

Create a new file:

`scripts/map/garden_access_resolver.gd`

with:

```gdscript
extends RefCounted
class_name GardenAccessResolver
```

Goal:
Move the garden access-cell scoring, garden-entry selection, and entry-resolve cache out of `BuildingManager` while preserving behavior exactly.

Extract these responsibilities from `BuildingManager`:

* `_garden_entry_resolve_cache`
* `_garden_entry_resolve_cache_hit`
* `_garden_entry_resolve_hits`
* `_garden_entry_resolve_misses`
* `_manhattan_cell`
* `_garden_access_outside_neighbors`
* `_valid_walkable_neighbors_no_corner_cut`
* `_group_route_cost_at_cell`
* `_score_garden_access_cell`
* `_blocked_cardinal_count`
* `_select_scored_garden_entry`
* `_nearest_garden_entry_manhattan`
* `_clear_garden_entry_resolve_cache`
* `_garden_entry_resolve_cache_key`
* `_nearest_garden_entry`
* `_nearest_garden_entry_to_exit`

Also move these access-scoring constants out of `BuildingManager` into the new resolver if they are only used by this block:

* `ACCESS_NO_OUTSIDE_PENALTY`
* `ACCESS_EXIT_WORSE_PENALTY`
* `ACCESS_EXIT_FLAT_PENALTY`
* `ACCESS_DEAD_CONTINUATION_PENALTY`
* `ACCESS_NARROW_CONTINUATION_PENALTY`
* `ACCESS_REVERSAL_PENALTY`
* `ACCESS_TURN_PENALTY`
* `ACCESS_BLOCKED_CARDINAL_PENALTY`
* `ACCESS_ENTER_DEAD_CONTINUATION_PENALTY`
* `ACCESS_ENTER_NARROW_CONTINUATION_PENALTY`

Keep shared constants local to the resolver as needed:

```gdscript
const IDLE_GROUP: int = 0
const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)
```

Architecture:
Follow the existing RefCounted controller pattern already used by:

* `GardenTopologyService`
* `GardenRetargetController`
* `SpawnerRouteService`
* `AgentSuspendService`

The new resolver should have:

```gdscript
var _manager: Node

func setup(manager: Node) -> void:
    _manager = manager
```

The resolver may call back into `BuildingManager` for source-of-truth state and low-level queries, same as the other controllers do.

Required public API on `GardenAccessResolver`:

```gdscript
func nearest_garden_entry(garden_id: int, from_cell: Vector2i) -> Vector2i
func nearest_garden_entry_to_exit(garden_id: int, spawner_cell: Vector2i) -> Vector2i
func clear_cache(reason: String = "") -> void

func cache_hit() -> bool
func consume_cache_hit_flag() -> bool # optional if cleaner
func reset_resolve_counters() -> void
func resolve_hits() -> int
func resolve_misses() -> int
```

The exact counter API can be adjusted, but existing profiling/debug behavior in `BuildingManager` and `GardenRetargetController` must remain unchanged.

Important behavior constraints:

1. Do not change gameplay behavior.
2. Do not change garden entry scoring results.
3. Do not change the cache key semantics:

   * key must remain based on source cell + garden id
   * never cache only by `garden_id`
4. Preserve stale-cache validation:

   * cached `INVALID_CELL` is valid and should be reused
   * finite cached cells must still be checked against current garden existence, `entry_cells`, and walkability
5. Preserve the fallback to old Manhattan nearest-entry selection when scoring finds no finite candidate.
6. Preserve debug print behavior gated by:

   * `debug_logs`
   * `CppDebugOptions.logs_enabled`
7. No performance regression.
8. No new topology recomputation.
9. No change to public behavior of `BuildingManager`.

Integration in `BuildingManager`:

Add a member:

```gdscript
var _garden_access_resolver: GardenAccessResolver = GardenAccessResolver.new()
```

In `_ready()`:

```gdscript
_garden_access_resolver.setup(self)
```

Replace the old methods in `BuildingManager` with thin wrappers where external callers or other controllers still expect the old private method names:

```gdscript
func _nearest_garden_entry(garden_id: int, from_cell: Vector2i) -> Vector2i:
    return _garden_access_resolver.nearest_garden_entry(garden_id, from_cell)

func _nearest_garden_entry_to_exit(garden_id: int, spawner_cell: Vector2i) -> Vector2i:
    return _garden_access_resolver.nearest_garden_entry_to_exit(garden_id, spawner_cell)

func _clear_garden_entry_resolve_cache(reason: String = "") -> void:
    _garden_access_resolver.clear_cache(reason)
```

If `_garden_entry_resolve_cache_hit`, `_garden_entry_resolve_hits`, or `_garden_entry_resolve_misses` are read directly inside `BuildingManager`, replace those reads with resolver accessors. Do not keep duplicate state in both classes.

The resolver can access dependencies through `_manager`, for example:

```gdscript
func _gardens() -> Dictionary:
    return _manager.get("_garden_topology").gardens()

func _is_walkable(cell: Vector2i) -> bool:
    return bool(_manager.call("_is_walkable", cell))

func _cell_center(cell: Vector2i) -> Vector2:
    return _manager.call("_cell_center", cell) as Vector2

func _flow() -> Node:
    return _manager.get("flow") as Node

func _spawner_route_service() -> Object:
    return _manager.get("_spawner_route_service") as Object
```

Use the same callback style as the other extracted controllers. Do not invent a new dependency-injection architecture.

Check all references before deleting code from `BuildingManager`:

Search for:

* `_nearest_garden_entry(`
* `_nearest_garden_entry_to_exit(`
* `_clear_garden_entry_resolve_cache(`
* `_garden_entry_resolve_cache`
* `_garden_entry_resolve_cache_hit`
* `_garden_entry_resolve_hits`
* `_garden_entry_resolve_misses`
* `_select_scored_garden_entry(`
* `_score_garden_access_cell(`
* `_garden_access_outside_neighbors(`
* `_valid_walkable_neighbors_no_corner_cut(`
* `_group_route_cost_at_cell(`
* `_blocked_cardinal_count(`

Expected result:

* `building_manager.gd` loses roughly 250–350 lines.
* Garden access scoring lives in `garden_access_resolver.gd`.
* `BuildingManager` keeps only thin compatibility wrappers.
* Existing controllers such as `SpawnerRouteService` and `GardenRetargetController` can continue calling `_manager.call("_nearest_garden_entry", ...)` unchanged.
* No scene/node changes required.
* No `.tscn` changes required.
* No gameplay behavior changes.

Do not do unrelated cleanup in this task.

Do not unify `BuildDirectionRules.direction_from_alternative()` here. That is a separate self-contained follow-up.

Do not rename garden concepts in this task.

Do not compile or run tests; I will do it.
