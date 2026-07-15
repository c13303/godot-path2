Implement the following Starpath phase and route update in the attached Godot project.

Read `AGENTS.md` first and follow it. Do not run Godot, tests, builds, exports, or compilation.

## Objective

Correct Starpath behavior by separating monster and client previews by gameplay phase.

Required behavior:

1. **Monster Starpath**

   * Visible during `AFTERNOON`.
   * Must remain visible for the entire `NIGHT`.
   * Continue using only the upcoming/current authored night’s active monster spawners.
   * Monster routes must retain the current shared-edge merging behavior.

2. **Client Starpath**

   * Visible during `DAWN` only.
   * Hidden during `AFTERNOON`, `NIGHT`, and `MORNING`.
   * For every client spawner, display both:

     * its real client **FF IN** route;
     * its real client **FF OUT** route.
   * Client routes must never be merged with one another.
   * This includes:

     * routes from different client spawners;
     * the IN and OUT routes belonging to the same client spawner;
     * identical or partially overlapping edges;
     * edges traversed in opposite directions.

Do not alter the existing footprint visuals, stride, animation cadence, runner behavior, route-center reconstruction, or pooling unless strictly required for this task.

---

# Existing implementation to preserve

Relevant files:

* `scripts/map/path_preview_controller.gd`
* `scripts/map/path_preview_route_planner.gd`
* `scripts/map/path_preview_runner.gd`
* `scripts/map/spawner_route_service.gd`
* `scripts/map/ARCHITECTURE.md`

Current architecture:

* `SpawnerRouteService` owns the real route groups and prepared preview descriptors.
* `PathPreviewController` consumes descriptors and builds tile-center paths.
* `PathPreviewRoutePlanner.build_cell_center_path()` follows the native FF route costs from a start cell to a goal cell.
* `PathPreviewRunner` renders the existing animated footprints.
* `_rebuild_segment_ownership()` currently merges shared edges globally.

Keep those ownership boundaries.

Do not move this logic into `BuildingManager`.

Do not add a new framework or generic event system.

Do not touch the native C++ extension.

---

# 1. Make preview selection phase-specific

In `path_preview_controller.gd`, replace the current `AFTERNOON`-only gate and combined descriptor list with explicit phase behavior.

The descriptor source must be:

```text
AFTERNOON -> prepared monster routes only
NIGHT     -> prepared monster routes only
DAWN      -> prepared client IN + OUT routes only
MORNING   -> no routes
```

Expected transitions:

```text
AFTERNOON -> NIGHT
Keep the same monster preview alive.

NIGHT -> DAWN
Remove monster runners and replace them with client runners.

DAWN -> MORNING
Clear all client runners immediately.

MORNING -> AFTERNOON
Show the next authored night’s monster preview.
```

Do not clear and rebuild the monster preview merely because the phase changes from `AFTERNOON` to `NIGHT` when its route signature is unchanged.

The existing signature comparison and runner reuse should make this possible once both phases consume the same monster descriptors.

The invalidation checks must remain:

* navigation topology dirty;
* plant layout dirty;
* runtime rebuild active.

During invalidation, show no stale route. Rebuild from the prepared real routes once they are valid again.

---

# 2. Generalize preview descriptors to explicit start and goal cells

The current controller assumes every preview path is:

```text
spawner_cell -> entry_cell
```

That is insufficient for client FF OUT.

Prepared descriptors must expose explicit generic route endpoints:

```gdscript
"start_cell": Vector2i
"goal_cell": Vector2i
```

Keep existing semantic fields such as `spawner_cell`, `entry_cell`, `garden_id`, and `route_kind` where useful for debugging and route ownership.

For existing inbound descriptors:

```text
start_cell = spawner_cell
goal_cell = entry_cell
```

`PathPreviewController._plan_route_path()` must call:

```gdscript
PathPreviewRoutePlanner.build_cell_center_path(
    flow,
    manager,
    group_id,
    start_cell,
    goal_cell
)
```

Do not reverse an already generated polyline. Always follow the correct FF group downhill from its real start cell to its real goal.

Update the route signature so that it includes at least:

* route kind;
* source/client spawner identity;
* start cell;
* goal cell;
* garden ID;
* topology revision;
* group ID.

IN and OUT descriptors must never accidentally share the same signature.

Readiness must be checked at the descriptor’s `start_cell`, not always at `spawner_cell`.

---

# 3. Add explicit client outbound descriptors

In `spawner_route_service.gd`, add:

```gdscript
const ROUTE_KIND_CLIENT_OUTBOUND: StringName = &"client_outbound"
```

The existing route kinds remain:

```gdscript
ROUTE_KIND_MONSTER_INBOUND
ROUTE_KIND_CLIENT_INBOUND
```

For every prepared client inbound descriptor, also prepare a corresponding outbound descriptor using that client spawner’s real runtime escape FF.

## Client FF IN descriptor

Use the existing client route:

```text
group_id   = spawner-to-garden plant_group
start_cell = client spawner cell
goal_cell  = selected garden entry_cell
route_kind = client_inbound
```

This is the existing client route behavior, generalized with explicit endpoints.

## Client FF OUT descriptor

Use the actual per-spawner runtime escape route stored in `_spawner_routes`.

The outbound descriptor must use:

```text
group_id   = escape_group
start_cell = the same selected garden entry_cell used by FF IN
goal_cell  = escape_wall_target_cell
route_kind = client_outbound
```

Also retain:

```text
spawner_cell
garden_id
entry_cell
topology_revision
```

This represents the real `FlowOut` field associated with that client spawner and its bound exit.

Do not:

* generate a reversed IN route;
* perform A*;
* fabricate a straight line;
* allocate a second preview-only escape FF;
* create a new native group solely for the preview;
* use a monster route as fallback.

The client spawners in the authored levels have bound exits. Still handle missing or unavailable runtime escape data safely:

* invalid `escape_group`: omit the OUT descriptor;
* invalid `escape_wall_target_cell`: omit it;
* uninitialized spawner route: omit it until initialized;
* flow not ready at `entry_cell`: keep the descriptor but mark it unready so the controller retries normally;
* unreachable route: planner returns an empty path and nothing is drawn.

Do not spam warnings every refresh for temporarily unready flows.

A small helper dedicated to building the client outbound descriptor is preferable to duplicating the descriptor assembly logic.

---

# 4. Store both client IN and client OUT descriptors cleanly

The existing `_prepared_upcoming_client_routes` dictionary is keyed once per spawner and therefore cannot directly contain both route legs.

Use a minimal, readable structure. Recommended approach:

```gdscript
var _prepared_upcoming_client_routes: Dictionary = {}
var _prepared_upcoming_client_outbound_routes: Dictionary = {}
```

Both may remain keyed by client spawner cell.

`prepared_upcoming_client_routes()` should return one flat `Array[Dictionary]` containing:

1. all client inbound descriptors;
2. all client outbound descriptors.

Keep deterministic spawner ordering.

Update all cleanup paths accordingly:

* route preparation clear;
* spawner route release;
* garden route release;
* prepared-route invalidation;
* topology rebuild;
* descriptor snapshot refresh.

When a prepared inbound route for a garden is removed, remove its associated outbound descriptor as well.

Do not leave stale outbound descriptors referencing a dissolved garden route or old entry cell.

---

# 5. Keep preview-night selection correct across phase changes

The day number advances on the `NIGHT -> DAWN` transition.

Therefore, blindly using:

```gdscript
current_day_number() - 1
```

for client preview preparation during Dawn can select the next night instead of the night whose clients are about to arrive.

Track or resolve the target authored night explicitly.

Required mapping:

```text
AFTERNOON:
monster target = current day’s upcoming night
client warmup target = current day’s upcoming night

NIGHT:
monster target = the currently active night
client warmup target = that same night

DAWN:
client target = the just-completed night

MORNING:
client target may remain the just-completed night, although previews are hidden

Next AFTERNOON:
monster/client warmup target advances to the next authored night
```

Given that `nDays` increments when night ends, the client target during Dawn/Morning is effectively:

```gdscript
current_day_number() - 2
```

while during Afternoon/Night it is:

```gdscript
current_day_number() - 1
```

Clamp and validate against the authored night count.

Do not rely exclusively on navigation revision changes to refresh prepared descriptors.

Store the prepared target night index for both monster and client descriptor sets, or otherwise ensure that `prepared_upcoming_monster_routes()` and `prepared_upcoming_client_routes()` reprepare when their expected authored night index changes.

This prevents:

* the previous night’s monster paths appearing next afternoon;
* next night’s client count suppressing the current Dawn preview;
* deferred client preparation switching to the wrong authored night after the day increment.

Client descriptors should only be prepared when the relevant authored night has a client count greater than zero.

---

# 6. Disable shared-edge merging for every client route

Current `_rebuild_segment_ownership()` assigns each canonical edge to one route globally.

Preserve that exact behavior for monsters.

Add an explicit route policy, for example:

```gdscript
"merge_shared_segments": true  # monsters
"merge_shared_segments": false # all client IN and OUT routes
```

Equivalent clear naming is acceptable.

Ownership behavior:

## Monster route

For a merge-enabled monster route:

* use the existing canonical undirected edge key;
* first deterministic route owns the shared edge;
* subsequent monster routes do not print on that edge.

## Client route

For a non-merged client route:

* mark every valid segment in its polyline as owned;
* do not consult or modify the shared `edge_owner` map;
* do not remove segments shared with another client route;
* do not remove segments shared between its own IN and OUT paths.

Every client descriptor must independently start its normal set of route runners.

Do not solve this by adding positional offsets or changing footprint appearance. The requirement is independent route rendering, not visual lane separation.

Since monster and client previews are phase-separated, no special monster-versus-client collision rule is needed.

---

# 7. Route classification in the controller

Both client route kinds must use the client footprint frame:

```text
client_inbound  -> FOOTPRINT_FRAME_CLIENT
client_outbound -> FOOTPRINT_FRAME_CLIENT
monster_inbound -> FOOTPRINT_FRAME_MONSTER
```

Do not classify a route as client only by testing equality with `ROUTE_KIND_CLIENT_INBOUND`, because that would incorrectly render `client_outbound` as a monster route.

Use an explicit helper such as:

```gdscript
func _route_is_client(route_kind: StringName) -> bool:
```

or an explicit `match`.

Keep route classification local and obvious.

---

# 8. Preserve current performance characteristics

The preview must remain read-only with respect to pathfinding.

Required:

* no route-cost walk per frame;
* no FF recomputation initiated by a runner;
* no A* for Starpath;
* no native agent assignment;
* no per-footprint path query;
* path polyline built once per route identity when its flow becomes ready;
* low-frequency descriptor refresh retained;
* runner pool retained;
* invalid routes remain silent.

Adding client OUT should add one route descriptor and one cached polyline per valid client spawner, not continuous computation.

Do not change the one-flow-request-per-frame lazy queue.

---

# 9. Update comments and architecture documentation

Update outdated comments in:

* `path_preview_controller.gd`;
* `spawner_route_service.gd`;
* `scripts/map/ARCHITECTURE.md`.

Documentation must state:

* monster preview is shown during Afternoon and Night;
* client preview is shown during Dawn only;
* clients display both inbound and outbound FF routes;
* monster shared edges are merged;
* client routes have full independent segment ownership and are never merged;
* preview consumes real runtime flow groups and does not alter gameplay navigation.

Do not perform unrelated documentation cleanup.

---

# Files expected to change

Primary:

```text
scripts/map/path_preview_controller.gd
scripts/map/spawner_route_service.gd
scripts/map/ARCHITECTURE.md
```

Only change this if the generic endpoint support genuinely requires it:

```text
scripts/map/path_preview_route_planner.gd
```

`path_preview_runner.gd` should not require behavioral changes.

Avoid modifying:

```text
scripts/map/building_manager.gd
scripts/map/agent_navigation_phase_controller.gd
scripts/map/building_preparation_controller.gd
native extension files
```

A tiny public façade/helper in `BuildingManager` is acceptable only if there is no clean existing public query, but do not place preview logic there.

---

# Manual acceptance checklist

The user will test manually.

## Phase behavior

1. During Afternoon:

   * red monster footprints are visible;
   * no client footprints are visible.

2. Transition Afternoon → Night:

   * the red Monster Starpath remains visible;
   * it continues animating during the full night;
   * it does not disappear simply because Night began.

3. Transition Night → Dawn:

   * monster footprints disappear;
   * client footprints appear;
   * no next-night monster preview is shown during Dawn.

4. During Morning/client sale:

   * all Starpath previews are hidden.

5. During the following Afternoon:

   * monster paths correspond to the next authored night, not the previous one.

## Client route behavior

For every client spawner during Dawn:

1. A client-colored FF IN route travels:

   * from that client spawner;
   * to its selected garden entry.

2. A client-colored FF OUT route travels:

   * from that selected garden entry;
   * toward that same client spawner’s configured escape target.

3. Two client spawners sharing part of a path both retain their complete animated paths.

4. A client IN route and client OUT route sharing or reversing an edge both retain that edge.

5. No client route disappears merely because another client descriptor was processed first.

## Existing behavior

* Monster overlapping routes still merge exactly as before.
* Footprint spacing, fading, speed, scale, direction, and density remain unchanged.
* Building a wall still invalidates and refreshes Starpath through the existing lazy system.
* No synchronous lag is introduced when placing plants or walls.
* Unready/blocked routes show nothing rather than a fake route.
* Restoring a save shows only the preview valid for the restored gameplay phase.

---

# Final report

Report:

1. files changed;
2. exact phase visibility rules implemented;
3. how client FF OUT descriptors are derived;
4. how monster merging was preserved;
5. how client merging was disabled;
6. how authored-night index changes across Dawn were handled;
7. confirmation that Godot/tests/builds were not run.
