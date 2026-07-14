Implement the following feature cleanly in the provided Godot 4 codebase.

Read and follow `AGENTS.md` first.

Do not run Godot, compilation, tests, exports, SCons, or any build command. The user tests manually.

# Objective

1. Completely remove the existing `Desire` / footstep texture-stamping mechanic.
2. Replace it with a generic flow-field path-preview system reused for:

   * client routes during dawn;
   * monster routes during afternoon.

This must be production-oriented and must not add gameplay logic to `building_manager.gd`.

---

# Part 1 — Completely remove the old footstep system

The existing mechanic is implemented by:

```txt
scripts/map/desire.gd
scripts/map/desire.gd.uid
assets/sprites/legval/desire.png
Map/MonTilemap/Desire in mainRun.tscn
```

`building_manager.gd` currently resolves the Desire node and combines Desire registration with `AgentCellTracker` registration.

Remove the feature entirely.

## Required cleanup

Delete:

```txt
scripts/map/desire.gd
scripts/map/desire.gd.uid
```

Delete `assets/sprites/legval/desire.png` if it exists in the complete repository and is no longer referenced.

Remove from `mainRun.tscn`:

* the `desire.gd` external resource;
* the `Map/MonTilemap/Desire` node.

Remove from `building_manager.gd`:

* `_desire`;
* `_resolve_desire()`;
* the `_resolve_desire()` call;
* all Desire-specific registration logic;
* stale Desire comments.

The old methods currently also register agents with `AgentCellTracker`. Preserve that important behavior, but rename the API according to its real responsibility.

Use clear names such as:

```gdscript
func _register_runtime_agent(agent: Node2D, category: StringName) -> void
func _unregister_runtime_agent(agent: Node2D) -> void

func register_runtime_agent(agent: Node2D, category: StringName) -> void
```

These methods should only delegate to `AgentCellTracker`.

Update every relevant call site, including at least:

```txt
scripts/map/agent_spawn_service.gd
scripts/map/agent_save_service.gd
scripts/map/monster_death_controller.gd
scripts/map/day_visitor_movement_controller.gd
scripts/map/building_manager.gd
```

In `day_visitor_movement_controller.gd`:

* rename `desire_category` to something accurate such as `tracking_category`;
* remove `_desire_category` if it is not actually needed after spawning;
* update merchant and builder call sites accordingly.

There must be no remaining code reference to:

```txt
Desire
desire.gd
desire.png
register_desire_agent
_unregister_desire_agent
_register_desire_agent
desire_category
```

Do not remove or modify the unrelated player rush smoke trail in:

```txt
scripts/visual_fx/smoke_trail.gd
```

Update `scripts/map/ARCHITECTURE.md` where the old registration boundary or ground-marker behavior is mentioned.

---

# Part 2 — Add a generic native group-flow sampling query

The preview must follow the real native flow-field vectors without spawning fake gameplay agents.

Add a generic, read-only API to `FlowFieldNative`:

```gdscript
compute_group_flow_dir(group_id: int, world_pos: Vector2) -> Vector2
```

Likely files:

```txt
extensions/flowfield/godot/flow_field_native.h
extensions/flowfield/godot/flow_field_native.cpp
```

Implementation requirements:

1. Bind the method through `ClassDB`.
2. Validate the group ID.
3. Retrieve the group flow from the global `AgentManager`.
4. Return `Vector2.ZERO` when:

   * the group is invalid;
   * no group flow exists;
   * the flow is not ready;
   * the position is non-finite;
   * the calculated direction is non-finite.
5. Otherwise call the existing `FlowField::compute_flow_dir()` for that group’s field.
6. Do not add path-preview-specific concepts to the C++ extension.
7. Do not register preview stars as native agents.
8. Do not modify group member counts, steering state, target-radius calculations, or gameplay agent behavior.

The existing method:

```gdscript
group_route_cost_at_world(group_id, world_pos)
```

can continue to be used for readiness, reachability, and arrival checks.

---

# Part 3 — Explicit flow-build policy

A critical constraint exists in the current architecture:

```gdscript
func _fences_block_navigation() -> bool:
    return not GameState.is_night and not _client_tantrum.is_active()
```

That phase-dependent rule cannot be used for preview flow groups.

Monster paths are previewed during afternoon, but they must already use monster navigation semantics:

```txt
monsters ignore fences
```

Client paths are previewed during dawn and must use client navigation semantics:

```txt
clients treat fences as navigation blockers
```

Do not temporarily change `GameState`, and do not build monster preview fields using daytime fence rules.

Extend `SpawnerRouteService` with a generic explicit-policy request method, for example:

```gdscript
func request_group_flow_rebuild_with_policy(
        group_id: int,
        goal_world: Vector2,
        block_fences: bool,
        label: String = ""
) -> void
```

It should reuse the existing queued/budgeted flow-build mechanism.

Keep the existing gameplay wrapper if necessary:

```gdscript
request_group_flow_rebuild(...)
```

Existing gameplay behavior must remain unchanged. The new preview system calls the explicit-policy method with:

```txt
clients:  block_fences = true
monsters: block_fences = false
```

Do not bypass the existing one-flow-request-per-frame queue.

---

# Part 4 — Path-preview architecture

Create a focused path-preview owner instead of expanding `building_manager.gd`.

Recommended files:

```txt
scripts/map/path_preview_controller.gd
scripts/map/path_preview_runner.gd
```

Add a world-space `Node2D` using `path_preview_controller.gd` under:

```txt
Map/MonTilemap
```

in `mainRun.tscn`.

`building_manager.gd` may receive only small public getters or thin façade methods needed by the preview controller. Do not place runner scheduling, route discovery, drawing, or flow sampling algorithms in `building_manager.gd`.

## Ownership

### `PathPreviewController`

Owns:

* current preview mode;
* active spawner set;
* preview-only flow-group allocation;
* preview route descriptors;
* route refresh/invalidation;
* runner pooling and scheduling;
* phase signal connections;
* cleanup when the phase changes.

### `PathPreviewRunner`

Owns one moving visual:

* procedural star rendering;
* its short fading trail;
* movement along one flow group;
* arrival/stuck/unreachable detection;
* reset/reuse lifecycle.

Do not use a permanent image canvas, TileMap stamps, decals, or accumulating textures.

---

# Part 5 — Preview route definition

For every relevant spawner, preview two separate FF-only legs.

## Inbound leg

```txt
start: spawner world position
flow goal: currently selected reachable garden entry
flow policy: based on preview kind
```

## Outbound leg

```txt
start: the same selected garden entry
flow goal: that spawner’s authored exit / resolved escape target
flow policy: based on preview kind
```

This deliberately omits all A* movement inside the garden.

The moving stars show route direction, so inbound and outbound paths remain understandable even when they overlap.

Do not:

* run `BuildingPathService`;
* call A*;
* assign native agent paths;
* instantiate character agents;
* use steering avoidance;
* simulate plant/counter movement inside a garden.

## Route selection

Reuse the same garden eligibility and nearest-entry scoring rules as real agents.

However, do not create or mutate normal gameplay spawner/garden route groups merely to discover a preview target.

Refactor `SpawnerGardenSelectionService` as needed so the common target-selection calculation can be called in a pure mode:

```txt
spawner + agent kind
    -> selected garden id
    -> selected entry cell
```

The pure selection path must not allocate a gameplay group.

Avoid duplicating the full garden-selection algorithm between gameplay and preview code. Extract a shared internal scoring helper if necessary.

Add a narrow, read-only method to `SpawnerRouteService` for resolving the authored spawner escape target without allocating the normal gameplay escape group.

For example:

```gdscript
func resolve_spawner_escape_target_cell(spawner_cell: Vector2i) -> Vector2i
```

Reuse the same resolution rules currently used by `initialize_spawner_route()`.

---

# Part 6 — Preview-only group lifecycle

The preview controller must allocate its own temporary native groups.

For every valid route:

* one group for inbound movement;
* one group for outbound movement.

Build those groups through the existing `SpawnerRouteService` flow request queue.

Do not attach agents to them.

Store enough information per leg:

```gdscript
{
    "group_id": int,
    "start_world": Vector2,
    "goal_world": Vector2,
    "spawner_cell": Vector2i,
    "direction": StringName
}
```

When a preview route is removed or replaced:

* stop and recycle its runners;
* dissolve its preview-only groups through `AgentManager.dissolve_group()`;
* erase the route state.

When leaving dawn or afternoon:

* clear all runners;
* dissolve all preview groups immediately;
* leave no native groups behind.

Also clear safely during `_exit_tree()`.

Do not save any preview state. It is reconstructed from the current phase after loading.

---

# Part 7 — Phase behavior

Connect to the authoritative `GameState.gameplay_phase_changed` signal.

Also evaluate the current phase once during startup so restored saves display the correct preview.

## Dawn: client preview

While:

```gdscript
GameState.gameplay_phase == GameState.GameplayPhase.DAWN
```

show blue client-route stars.

Stop them immediately when morning/client phase begins.

Preview only when the upcoming client phase has at least one planned client.

Use the existing completed-night client-count logic. Do not invent a second interpretation of which night owns the clients.

Preview all registered client spawners that can participate in that client phase.

Use:

```txt
agent kind: client
block_fences: true
color: blue
```

If no valid client target currently exists, skip that spawner without producing repeated warnings.

## Afternoon: monster preview

While:

```gdscript
GameState.gameplay_phase == GameState.GameplayPhase.AFTERNOON
```

show red monster-route stars for the upcoming authored night.

Stop them immediately when night begins.

Only include monster spawners that have actual monster activity in the upcoming playlist night.

There is already similar logic in:

```gdscript
BuildingManager.night_active_spawner_world_positions()
```

Refactor it so the authoritative query can return cells first, for example:

```gdscript
func night_active_spawner_cells(night_index: int) -> Array[Vector2i]
```

Then let the existing world-position query map those cells to positions.

Do not duplicate playlist-track filtering.

Use the upcoming playlist night index from progression/configuration, not the planificator UI.

Use:

```txt
agent kind: monster
block_fences: false
color: red
```

On the trailing client-only final day, there is no upcoming night, so no red preview should appear.

## Other phases

Show no path preview during:

```txt
MORNING
NIGHT
```

---

# Part 8 — Route refresh after map changes

The preview must react to walls, fences, plants, counters, and garden topology changes without rebuilding every frame.

Use a lightweight refresh strategy.

Add a monotonically increasing navigation/topology revision to the existing owner:

```txt
BuildingInvalidationController
```

Expose it through a read-only getter.

Increment it only after a complete successful navigation/topology rebuild, including:

* completed runtime budgeted walkability rebuild;
* synchronous walkability rebuild;
* plant-layout rebuild where navigation data is refreshed;
* shared client/night preparation after its topology passes finish successfully.

Do not increment it while a multi-frame rebuild is only partially complete.

The path-preview controller may poll at a low frequency, approximately 0.25–0.75 seconds.

Build a route signature containing at least:

* current preview kind;
* relevant sorted spawner cells;
* navigation revision;
* selected garden ID and entry cell for every spawner;
* resolved escape target cell.

Only dissolve/rebuild preview groups when this signature changes.

While `BuildingInvalidationController.runtime_rebuild_active()` is true:

* do not create routes against partial topology;
* hide or pause preview runners;
* refresh after the rebuild completes.

This prevents repeated FF computation while still updating the preview shortly after a placement/removal.

---

# Part 9 — Star visual

The visual must be generated procedurally. Do not require a new texture asset.

Each `PathPreviewRunner` should draw:

* a small five-point star;
* a short fading trail behind it.

Use the configured route color for both.

Default colors:

```txt
clients: blue
monsters: red
```

Keep colors exported or centralized in the controller so they are easy to tune.

The appearance should be subtle:

* partially transparent;
* small;
* no huge bloom;
* no permanent marks;
* no opaque continuous line covering the map.

Place the preview above the floor/plant ground visuals but below gameplay agents and major foreground objects. Use an explicit configurable `z_index`.

## Trail

Maintain a small bounded history of recent world positions.

Draw several short segments with progressively lower alpha toward the oldest point.

Clear the history when a runner is recycled or teleported to its start.

Do not use `Line2D` nodes created and destroyed continuously. Either reuse them or draw the bounded trail directly in the runner.

---

# Part 10 — Runner movement

A runner follows exactly one native group flow.

Every process tick:

1. Query `compute_group_flow_dir(group_id, global_position)`.
2. Query `group_route_cost_at_world(group_id, global_position)` when needed.
3. Stop/recycle if the field is unavailable or unreachable.
4. Move in the returned direction at the configured preview speed.
5. Recycle when sufficiently close to the route goal or when route cost indicates arrival.

The stars should move quickly enough to make route direction obvious.

To avoid cutting across corners at high speed:

* substep movement;
* resample the flow direction after each small movement step;
* keep each substep no larger than roughly one quarter of a tile.

Add bounded guards:

* maximum runner lifetime;
* maximum time with zero flow direction;
* non-finite position/direction checks;
* maximum substeps per frame.

A broken or temporarily unavailable field must recycle the runner rather than leaving it frozen forever.

---

# Part 11 — Density and pooling

The path should remain subtly visible most of the time because several stars are staggered along it.

Do not create a permanent static path line.

Use a pool of reusable runners.

Suggested behavior:

* each route leg emits a runner at a configurable interval;
* inbound and outbound legs have independent staggered emission;
* enough concurrent runners exist that a normal route usually has one or more stars visible;
* enforce a global maximum runner count.

Reasonable configurable values may include:

```txt
runner speed
emission interval
star size
trail duration or point count
arrival radius
maximum runner lifetime
maximum runner count
```

Do not expose dozens of unnecessary tuning properties.

No node should be instantiated or freed every emission cycle after the pool has been initialized.

---

# Part 12 — Performance and behavioral constraints

The system must:

* perform no scene-tree scan every frame;
* perform no CPU image upload;
* perform no texture stamping;
* perform no A* query;
* perform no actual agent spawn;
* perform no steering registration;
* perform no collision query;
* leave gameplay group membership unchanged;
* leave existing monster/client spawning behavior unchanged;
* preserve lazy gameplay flow-field behavior;
* use the existing budgeted flow request queue;
* release every temporary group;
* remain safe when a route is temporarily missing or unreachable.

The C++ API must remain generic and useful outside this feature.

---

# Likely files to modify

Expected files include, but are not necessarily limited to:

```txt
AGENTS.md                                      read only
mainRun.tscn
scripts/map/desire.gd                         delete
scripts/map/desire.gd.uid                     delete
scripts/map/path_preview_controller.gd        new
scripts/map/path_preview_runner.gd            new
scripts/map/building_manager.gd
scripts/map/building_invalidation_controller.gd
scripts/map/building_preparation_controller.gd
scripts/map/spawner_route_service.gd
scripts/map/spawner_garden_selection_service.gd
scripts/map/agent_spawn_service.gd
scripts/map/agent_save_service.gd
scripts/map/monster_death_controller.gd
scripts/map/day_visitor_movement_controller.gd
scripts/map/seed_merchant_controller.gd
scripts/map/builder_controller.gd
scripts/map/ARCHITECTURE.md
extensions/flowfield/godot/flow_field_native.h
extensions/flowfield/godot/flow_field_native.cpp
```

Keep `building_manager.gd` changes limited to:

* renamed agent-tracking wrappers;
* small getters;
* thin route/spawner query façades;
* no preview algorithms.

---

# Acceptance criteria

## Old mechanic removal

* No `Desire` node exists.
* No `desire.gd` or `desire.png` reference remains.
* No agent registration method contains “desire” in its name.
* Monsters, clients, merchants, and builders remain registered with `AgentCellTracker`.
* Player rush smoke behavior remains untouched.

## Dawn

* Blue stars appear during dawn when clients are planned.
* Every participating client spawner has an inbound and outbound FF preview when valid.
* Fences block client preview routes.
* Preview disappears immediately when morning/client phase starts.
* No internal garden A* route is drawn.

## Afternoon

* Red stars appear during afternoon.
* Only spawners active in the upcoming authored night are previewed.
* Monster preview routes ignore fences even though the current phase is afternoon.
* Preview disappears immediately when night starts.
* No red preview appears when no authored night remains.

## Visual

* Stars visibly move in the route direction.
* Several staggered stars make routes subtly readable most of the time.
* Trails fade and disappear.
* Nothing is permanently painted onto the map.

## Lifecycle

* Wall/fence/topology changes refresh the preview after the navigation rebuild.
* Preview groups are dissolved when routes change, phases change, or the scene exits.
* No fake agents or native group members are introduced.
* Save/load reconstructs the preview from the restored phase without saved preview data.

---

# Final report

Report:

1. files added, modified, and deleted;
2. how the old footstep registration coupling was cleaned;
3. the final ownership split between controller and runner;
4. how preview-only flow groups are allocated and released;
5. how client and monster fence policies are kept independent of the current phase;
6. how route invalidation avoids rebuilding every frame;
7. confirmation that no Godot/build/test command was run;
8. any remaining uncertainty that requires manual testing.
