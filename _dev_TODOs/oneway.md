# TASK — Generic one-way flow-field tiles for clients

Read `AGENTS.md` completely before editing.

Do not run Godot, tests, compilation, SCons, export, or builds. The user will test manually.

Implement the feature cleanly and conservatively. Do not introduce unrelated refactors.

## Feature

Levels may contain an authored `TileMapLayer` named:

```text
special_tiles
```

This layer contains invisible navigation-authoring tiles.

The first supported special-tile type is a one-way flow-field constraint used by **clients only**.

Atlas-coordinate mapping:

```text
(12, 8) = UP
(13, 8) = DOWN
(14, 8) = LEFT
(15, 8) = RIGHT
```

Godot cell directions:

```gdscript
UP    = Vector2i(0, -1)
DOWN  = Vector2i(0, 1)
LEFT  = Vector2i(-1, 0)
RIGHT = Vector2i(1, 0)
```

These tiles are authored before the game starts. They cannot be added, removed, or modified during gameplay.

They must remain active whenever affected flow fields are lazily recomputed, without rescanning the TileMapLayer on every rebuild.

---

# Required gameplay semantics

A one-way tile constrains movement **out of its cell**:

> When a client stands on a one-way cell, its next flow-field step must be exactly the direction indicated by that cell.

Examples:

* An `UP` cell may lead only to `cell + Vector2i.UP`.
* It must not produce DOWN, LEFT, RIGHT, or diagonal flow directions.
* An agent may enter the one-way cell from any valid neighboring cell.
* The goal cell may be a one-way cell; arrival at the goal does not require leaving it.

This outgoing-edge interpretation is intentional. It allows turns to be authored by placing successive tiles with different directions.

Do not add steering forces that merely push the agent in the arrow direction.

The flow field itself must understand the directed graph so that:

* route costs are correct;
* unreachable cells remain unreachable;
* garden/target selection receives correct route costs;
* previews use the same route;
* agents never fight between flow direction and steering.

---

# Scope

One-way constraints apply to every flow field used by actual client navigation:

1. Client spawner approach/cost fields used for reachable-distance and garden-entry selection.
2. Client inbound flow fields.
3. Client outbound/escape flow fields.
4. Client route previews, because they read those same real flow groups.
5. Recomputed versions of all those fields after hard topology invalidation.

They must not affect:

* monsters;
* greenmonster;
* bigmonster;
* merchants;
* villagers;
* builders;
* player movement;
* the native default collision/distance field;
* A* paths;
* waterpool steering fields;
* terrain speed multipliers.

Do not treat `block_fences == true` as equivalent to “client.”

Merchants also block fences but must not obey client one-way tiles.

---

# Existing architecture findings

Account for these concrete facts in the current codebase:

## Level loading

`level_demo.tscn` already contains a `special_tiles` layer, but:

```gdscript
LevelLoader.LEVEL_LAYER_NAMES
```

currently transfers only:

```text
floor
watersources
wallz
fences
```

The off-tree level root is then freed, so `special_tiles` is currently discarded.

Fix level loading so the authored layer reaches the runtime `Map/MonTilemap` host.

It must be optional so older levels without this layer continue to work.

## Current native flow policy

`FlowFieldNative` currently has only a per-request `block_fences` distinction.

Do not overload that boolean with one-way behavior.

Add a small generic directional-traversal-field mechanism instead.

## Existing directional cell field

The steering extension already has `DirectionalCellField`.

Do not reuse it for this feature. It modifies runtime velocity and does not modify Dijkstra connectivity or route costs.

---

# Recommended design

Keep the implementation generic in native code but simple on the game side.

## 1. Runtime level layer

Update `LevelLoader` so `special_tiles` is transferred from the authored level into:

```text
Map/MonTilemap/special_tiles
```

Requirements:

* Treat it as optional.
* Set it invisible before or immediately when it is attached:

  ```gdscript
  special_tiles.visible = false
  ```
* Ensure its collision and navigation are disabled.
* It must never be visible for even one gameplay frame.
* Do not synthesize or save an empty layer when a level does not provide one.
* Do not include this static authoring layer in runtime savegame serialization.

Do not hide the whole `MonTilemap` host or alter unrelated layers.

## 2. Scan once during navigation startup

During normal flow-field initialization, after `LevelLoader` has injected the layers:

* Resolve `Map/MonTilemap/special_tiles` with `get_node_or_null()`.
* Read its used cells exactly once.
* Translate recognized atlas coordinates into:

  * absolute map cell;
  * allowed outgoing cardinal direction.
* Push the resulting sparse data into native code.
* Do not retain a second mutable Godot-side gameplay index unless genuinely required.
* Do not rescan this TileMapLayer during wall invalidation or flow-field recomputation.

Unrecognized occupied atlas coordinates should produce a concise warning containing:

* cell;
* atlas coordinates;
* level context if readily available.

Ignore unrecognized tiles after warning rather than assigning arbitrary behavior.

Validate that recognized cells overlap an existing floor cell. Warn and ignore malformed cells that do not.

Do not log one message per valid tile.

## 3. Generic native directional traversal fields

Add a generic native concept similar to:

```text
directional traversal field ID
```

Suggested API shape; naming may be improved if a clearer equivalent fits the code:

```text
set_directional_traversal_field(field_id, cells, directions)
clear_directional_traversal_field(field_id)
clear_directional_traversal_fields()
```

A field is a sparse mapping:

```text
absolute map cell -> allowed outgoing cardinal direction
```

Native C++ must know nothing about clients, monsters, merchants, atlas coordinates, or level node names.

Use a game-side constant for the client field, for example:

```gdscript
const CLIENT_ONE_WAY_FIELD_ID: int = 1
const NO_TRAVERSAL_FIELD_ID: int = -1
```

Do not add speculative resources, abstract base classes, or a large navigation-policy framework.

## 4. Extend per-flow request policy

Extend group-flow requests with a traversal-field ID, defaulting to none.

Conceptually:

```text
request_flow_to_group(
    group_id,
    goal,
    block_fences = false,
    traversal_field_id = NO_FIELD
)
```

and the equivalent synchronous assignment API.

Preserve compatibility for callers that do not supply the new argument.

The queued request in `SpawnerRouteService` must retain the complete policy:

* `block_fences`;
* `traversal_field_id`.

Do not lose the traversal field between:

* queue creation;
* queue replacement/deduplication;
* submission;
* async snapshot creation;
* worker computation;
* synchronous fallback.

## 5. Explicit route policy by spawner kind

Add a small, readable game-side helper that derives the flow policy from the spawner/agent kind.

Expected behavior:

```text
monster:
    block_fences = false
    traversal_field_id = none

client:
    block_fences = true
    traversal_field_id = client one-way field

merchant:
    block_fences = true
    traversal_field_id = none
```

Do not derive the traversal field from `GameState.is_night`, `block_fences`, or the current phase.

Use the authoritative spawner kind wherever a flow belongs to a specific spawner.

Update all relevant client route creation/rebuild paths, including:

* approach groups;
* garden/counter inbound groups;
* spawner escape/outbound groups;
* rebuilds of existing groups;
* prepared route descriptors where policy metadata is retained;
* route-current/cache validation.

A cached route is current only when both its topology generation and its complete navigation policy match.

Do not accidentally apply the client traversal field to generic monster exit-wall escape groups.

## 6. Directed Dijkstra implementation

The current flow computation runs Dijkstra backward from the goal.

Create one focused native helper equivalent to:

```text
can_traverse(from_cell, to_cell, walkable_set, traversal_constraints)
```

Use the same legality helper in both:

1. cost propagation;
2. final flow-direction selection.

This prevents route costs and emitted directions from disagreeing.

For a constrained source cell:

```text
to_cell - from_cell
```

must exactly equal its allowed direction.

Because Dijkstra expands backward from the goal, when evaluating:

```text
neighbor -> current
```

the constraint must be checked on the predecessor/neighbor cell, not on the current cell.

In the current loop shape, if:

```cpp
nb = cur.cell + d;
```

then the candidate forward movement is:

```cpp
nb -> cur.cell
```

whose movement delta is:

```cpp
-d
```

Check the constraint accordingly.

This detail is critical.

## 7. Diagonal behavior

A constrained one-way cell may not emit a diagonal edge.

Its only legal outgoing edge is the exact cardinal arrow direction.

Keep the existing diagonal corner-cut prevention for ordinary cells.

Do not globally disable diagonal movement.

Do not add entry-direction restrictions: entering an arrow cell remains legal from any otherwise-valid neighbor.

Ensure final direction selection cannot select an illegal diagonal or side exit after Dijkstra has computed correct costs.

Any fallback direction must also have passed the same traversal-legality check.

## 8. Async and synchronous parity

The async snapshot must contain only the selected traversal field’s sparse constraints.

Performance requirements:

* no TileMap calls from the worker;
* no TileMap scan per flow field;
* no full-map directional array copied per request;
* no per-frame work;
* no change to terrain-speed processing;
* no extra global flow recomputation.

A sparse copy proportional to the number of authored one-way cells is acceptable and preferable to complex speculative architecture.

The synchronous fallback must produce the same directed connectivity as the async path.

If the current synchronous implementation bypasses the async-snapshot algorithm for policy-free fields, ensure any request with a traversal field uses the policy-aware computation path.

Do not silently ignore one-way constraints because the async API is unavailable.

## 9. Static lifetime and invalidation

The authored directional field is immutable for the entire loaded level.

Register it once.

When walls or other hard topology changes trigger the existing lazy flow rebuild:

* do not mark the special layer dirty;
* do not rescan it;
* do not rebuild a separate directional cache;
* simply include the already-registered traversal field in affected client flow requests.

The constraints must survive ordinary flow-field clearing/replacement and savegame restoration.

Only clear or replace them when the loaded level/navigation instance itself is being replaced or destroyed.

## 10. Unreachable routes

If one-way authoring makes a route unreachable:

* preserve the existing unreachable/+INF behavior;
* do not fall back to an unconstrained client field;
* do not make the tile walkable in both directions;
* do not force agents through it with steering.

Route selection and existing fail-closed handling must receive the truthful result.

A bad authored arrow may therefore make a client entrance or outbound route unavailable. This is expected and should be visible during manual testing.

---

# Performance acceptance criteria

The implementation is acceptable only if:

* `special_tiles` is scanned once per level load/navigation initialization;
* directional constraints are stored sparsely;
* ordinary frames perform zero work for this feature;
* wall placement/removal does not rescan the layer;
* each affected client flow rebuild adds only O(number of relevant one-way cells) snapshot/setup work plus an O(1) edge check during the already-existing Dijkstra traversal;
* unaffected monster and default fields do not carry or process client constraints;
* no new full-map rebuild is triggered solely because one-way data exists.

Avoid premature micro-optimization, but do not query dictionaries through Godot or call into a TileMap from inside the inner Dijkstra loop.

Use native C++ containers in the worker.

---

# Regression requirements

Preserve all current behavior except the new directional restriction.

Specifically verify statically that:

* levels without `special_tiles` still load;
* the layer is invisible;
* floor, water, walls, fences, spawners, houses, and bamboo loading are unchanged;
* monsters continue to ignore fences as before;
* clients continue to block fences;
* merchants continue to block fences but ignore client arrows;
* default player wall collision is unchanged;
* terrain slow/fast tiles are unchanged;
* waterpool directional steering is unchanged;
* flow request queue deduplication still works;
* flow group cache/currentness checks include the new policy;
* async cancellation/generation checks remain intact;
* debug flow rendering naturally displays the resulting directed client flow.

Do not broadly refactor `FlowFieldNative`, `SpawnerRouteService`, `BuildingManager`, or `LevelLoader`.

---

# Manual test plan to include in the report

Provide a precise manual test checklist for the user:

1. Start `level_demo` and confirm `special_tiles` is invisible.
2. Place an arrow in a narrow client corridor and confirm clients traverse it only in its direction.
3. Confirm a reverse client route reroutes through another available path.
4. Confirm a reverse route becomes unreachable when no alternate directed path exists.
5. Confirm clients can enter an arrow cell from another valid cardinal side and then leave only in the arrow direction.
6. Confirm client inbound navigation obeys arrows.
7. Confirm client outbound navigation obeys arrows.
8. Confirm client path previews match actual movement.
9. Confirm monsters cross the same cells without one-way restrictions.
10. Confirm merchants do not inherit the client restriction.
11. Build/remove a wall, allow the lazy flow rebuild to complete, and confirm arrows still work without rescanning/re-registering them.
12. Load a level without `special_tiles` and confirm no error or behavior change.
13. Save/reload and confirm the authored constraints remain active.

Mention that inbound and outbound client routes may require separate directed lanes in level authoring.

---

# Code-quality constraints

Follow `AGENTS.md`:

* strict GDScript typing;
* avoid unsafe `:=` inference;
* explicit ownership;
* no private cross-service noodle coupling beyond existing unavoidable patterns;
* no large unrelated cleanup;
* no speculative architecture;
* no species-specific logic in native C++;
* no per-frame polling;
* no hidden fallback that changes semantics.

If implementing this cleanly exposes an existing policy bug—especially a client flow group whose spawner kind is unavailable or whose policy currently depends only on the global day/night phase—fix only the smallest necessary policy propagation and report it.

Do not guess silently. If a specific existing route cannot be reliably classified as client, monster, or merchant, stop that portion and report the exact call path and ambiguity rather than applying client arrows broadly.

---

# Final report

Report:

1. Exact files changed.
2. Owner of the authored special-layer scan.
3. Native API added.
4. Exact outgoing-edge semantics implemented.
5. How reverse Dijkstra checks the predecessor cell.
6. How client, merchant, and monster policies differ.
7. Every client flow-group category updated.
8. How route caches include the new policy.
9. Why no per-frame or per-rebuild TileMap scan exists.
10. Handling of missing/unknown/malformed special tiles.
11. Any existing architectural problem discovered.
12. Manual test checklist.
13. Confirmation that no Godot/build/test command was run.
