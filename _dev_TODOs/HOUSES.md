Implement **House support — pass 1: authored registration, sprite anchoring, wall footprint, and temporary runtime construction test**.

Read and follow `AGENTS.md` before editing.

Do not run Godot, tests, compilation, export, or build commands. The user performs all runtime testing.

## Objective

Prepare a reusable, production-oriented house system.

This pass handles only:

1. Detecting and registering houses already authored in a level.
2. Correctly snapping and Y-sorting their sprites.
3. Registering their five blocking footprint cells as walls.
4. Exposing a generic runtime house creation method.
5. Temporarily testing runtime construction with the `K` key and `test_flyhouse`.

Do not implement the final build-menu integration yet.

---

# Fixed house geometry

The logical anchor of a house is always its **entrance cell**.

A house has a `3 × 2` map presence:

```text
WWW
WEW
```

Relative to the entrance cell `(0, 0)`:

```text
(-1,-1)  (0,-1)  (1,-1)
(-1, 0)  (0, 0)  (1, 0)
```

The five blocking cells are:

```text
(-1,-1)
( 0,-1)
( 1,-1)
(-1, 0)
( 1, 0)
```

The entrance `(0, 0)` must remain completely walkable.

The sprite occupies `3 × 3` visual tiles:

```text
SSS
WWW
WEW
```

The upper `SSS` row is visual only. It must not create walls, collision, placement occupancy, or navigation blockers. Agents can move behind that part, using normal z-index sorting.

## Sprite anchoring

The sprite’s horizontal centre must align with the entrance cell centre.

The **bottom edge of the sprite** must align with the **bottom edge of the entrance cell**.

Do not align the sprite origin or centre directly to the entrance.

Use the actual `Sprite2D` texture, `centered`, `offset`, transform, and TileMap conversion methods. Do not assume a hardcoded 48-pixel sprite or calculate cells through manual division of world coordinates.

The target bottom-centre world position is:

* X: entrance cell centre X.
* Y: entrance cell centre Y plus half the tile height.

For an authored house, derive the initial entrance cell from the currently authored sprite bottom-centre:

1. Determine the sprite bottom-centre in world space.
2. Move the probe upward by half a tile.
3. Convert that point through the floor or wall TileMapLayer to obtain the entrance cell.
4. Snap the sprite exactly using the target alignment above.

## Z-index

Agents use their ground position as z-index.

Set every house sprite to:

```text
z_as_relative = false
z_index = integer world Y of the sprite bottom edge
```

Do not use the sprite centre Y.

Expected result:

* An agent above the house base draws behind it.
* An agent below the house base draws in front.
* The upper visual row behaves as an overhang that agents can walk behind.

---

# Current codebase facts to respect

Relevant existing architecture:

* `LevelLoader` instances the authored level off-tree.
* It captures spawner bindings before moving the level layers and `spawners` container into `Map/MonTilemap`.
* `BuildingManager` is a large façade and must not receive the house implementation itself.
* Startup topology is consumed through `BuildingManager._sync_runtime_state()`.
* Runtime hard-topology changes use `BuildingInvalidationController`.
* Runtime walkability rebuilding is already budgeted.
* Lazy flow-field requests are already tracked by `SpawnerRouteService`.
* `BuildingConstructionOverlay` already represents wall construction progress.
* `BuildingObjectManager` is based around one logical building per cell and is not the correct owner for a multi-cell house.
* The invisible blocking wall atlas currently used under reservoirs is `(15, 0)` on `wallz`.
* `house_seedmerchant`, `seedmerchent_spot`, and `test_flyhouse` already exist as direct children of the level’s `spawners` node.
* `house1.png` is already available at:

```text
res://assets/sprites/house/house1.png
```

Do not rename the existing typoed nodes:

```text
seedmerchent
seedmerchent_exit
seedmerchent_spot
```

Do not move `test_flyhouse` in `level_demo.tscn`. The user has already corrected its position locally.

---

# Required ownership

Create a focused house owner, preferably:

```text
scripts/map/house_manager.gd
```

Use `class_name HouseManager`.

`HouseManager` owns:

* House geometry rules.
* House registry.
* Entrance cells.
* Blocking footprint cells.
* Authored house discovery.
* Sprite snapping.
* Sprite z-index.
* Runtime house creation.
* Batched stamping of house wall cells.
* Starting the runtime house construction visual.
* Duplicate-house and footprint-conflict prevention.

It does not own:

* Flow-field generation.
* Garden rebuilding.
* General building placement.
* Player inventory or currencies.
* Build-menu state.
* Save/load.
* House removal.
* House health.
* Merchant AI.

`BuildingManager` may only contain thin house setup, accessors, and generic navigation wrappers.

Do not put the house algorithms in:

* `BuildingManager`
* `BuildSystem`
* `BuildPlacementService`
* `BuildingObjectManager`
* `LevelLoader`

`LevelLoader` may invoke a focused public/static house preparation entry point because authored houses must be normalized before spawner bindings are captured.

Update `scripts/map/ARCHITECTURE.md` with the new ownership.

---

# House registry

Keep one logical record per house, not one record per blocking cell.

A record should contain at least:

* House name or ID.
* House `Sprite2D`.
* Entrance cell.
* Five blocking cells.
* Whether it was authored or created at runtime.
* Whether it is currently under construction, when relevant.

Provide focused query methods such as:

* Find a house by name.
* Check whether an entrance cell already has a house.
* Get a house entrance.
* Get its blocking cells.

Do not create a speculative base class, resource hierarchy, plugin architecture, or generic building framework.

Different house types will be added later, but this pass only needs a clean method that accepts a house sprite or texture and an entrance cell.

---

# Authored house preparation

Authored houses are detected as:

* Direct children of `spawners`.
* `Sprite2D` nodes.
* Node name begins with `house_`.

The current authored test house is:

```text
house_seedmerchant
```

## Critical LevelLoader ordering

Authored house normalization must occur inside the off-tree level instance **before**:

```text
_capture_level_spawner_bindings(level_root)
```

This is required because `LevelLoader` converts `seedmerchent_spot` into a stored `SpawnerBinding.spot_cell`. Moving the spot after bindings have been captured would leave the merchant target stale.

Adjust `_load_level()` ordering so that it is conceptually:

1. Instantiate the level.
2. Capture general spawn configuration.
3. Prepare authored houses and linked entrance markers.
4. Capture spawner bindings.
5. Continue the existing map-bounds and reparenting process.

Do not duplicate the house geometry inside `LevelLoader`. It should invoke the house owner’s authored preparation API.

## `house_seedmerchant`

For `house_seedmerchant`:

1. Derive its entrance cell from its current sprite bottom edge.
2. Snap its sprite exactly to that entrance.
3. Set its z-index from its final bottom-edge world Y.
4. Register its five wall cells.
5. Leave the entrance empty and walkable.
6. Find the exact sibling node:

```text
seedmerchent_spot
```

7. Snap `seedmerchent_spot.global_position` to the exact centre of the house entrance cell.

The corrected spot must be in place before `_capture_level_spawner_bindings()` runs.

This exact house/spot pairing is test-specific. Keep the underlying “snap a node to a house entrance” method generic rather than embedding merchant logic in the geometry functions.

## Authored wall stamping

Use the transparent `wallz` atlas tile `(15, 0)` for empty footprint cells.

Resolve the actual atlas source ID from the live `wallz.tile_set`. Do not hardcode a source ID.

Stamp the five cells as one batch and call `wallz.update_internals()` once.

Do not put a wall on the entrance.

Do not trigger a runtime rebuild or construction progress display for authored houses. Their blockers must already exist when normal startup topology scanning and precomputation run.

Do not silently overwrite conflicting authored data:

* If the entrance already contains a wall, report a clear error.
* If an intended blocking cell already contains a wall, it may remain because it is already blocking, but report an informative warning if it is not the expected invisible tile.
* Do not erase arbitrary authored tiles to force registration.

Set metadata on prepared authored house sprites if useful, for example their resolved entrance cell, so the runtime registry does not have to infer it differently.

After the level container has been reparented, `HouseManager` must register the prepared live nodes into its authoritative registry without causing another topology rebuild.

---

# BuildingManager integration

Instantiate and set up `HouseManager` from `BuildingManager`.

This must remain thin orchestration only.

House setup must happen after level layers are resolved but before startup flow/topology synchronization is allowed to finish.

Expose a typed getter:

```text
get_house_manager()
```

Add only any generic thin wrapper that is genuinely required, for example a public wrapper for immediately setting one player-navigation cell blocked through the existing `BuildingNavigationSyncService`.

Do not let `HouseManager` call arbitrary private `BuildingManager` fields and methods.

Prefer intention-revealing public APIs.

Do not add house geometry, sprite calculations, footprint loops, or registry state to `BuildingManager`.

---

# Runtime house creation API

Implement a generic runtime method that accepts at least:

* House name or ID.
* Texture or prepared `Sprite2D`.
* Entrance cell.
* Optional runtime parent.

For this pass, runtime houses may be parented under a dedicated `Node2D` container such as:

```text
Map/MonTilemap/Houses
```

Do not unnecessarily reparent authored houses; registering them in their existing `spawners` parent is acceptable.

## Runtime validation

Before changing anything, validate the complete `3 × 2` presence atomically.

The runtime build must be rejected without partial mutation when:

* A house already uses the entrance.
* The entrance is not a valid walkable floor cell.
* Any presence cell is outside the floor.
* Any blocking footprint cell is already occupied by a wall or incompatible building.
* The entrance is occupied by a wall or other blocking placeable.
* The required wall atlas source cannot be resolved.
* The house sprite or texture is invalid.

The visual-only upper row must not be checked as occupied map presence. It is intentionally allowed to overlap space agents can walk through behind the sprite.

The temporary marker is already correctly placed; do not alter its scene position.

## Atomic commit order

After all validation succeeds:

1. Create and parent the house sprite.
2. Snap it to the entrance.
3. Assign its bottom-edge z-index.
4. Stamp all five invisible wall cells.
5. Call `wallz.update_internals()` once.
6. Immediately mark all five cells blocked for player collision using the existing native single-cell collision synchronization path.
7. Register one logical house record.
8. Mark hard navigation topology dirty exactly once.
9. Start one house construction visual.

Do not issue five independent topology invalidations.

Use the existing invalidation controller:

```text
BuildingInvalidationController.after_walkability_changed(...)
```

Use a clear reason such as:

```text
runtime_house_built
```

The existing runtime system must then perform its normal:

* Quiet-window batching.
* Budgeted walkability rebuild.
* Garden/route updates.
* Lazy flow-field recomputation.

Do not manually rebuild flow fields from `HouseManager`.

Do not directly call all the rebuild operations yourself.

Do not modify the C++ extension.

The periodic topology scan must not cause a duplicate rebuild after the authoritative runtime invalidation. Preserve the current signature resynchronization behavior.

---

# Construction visual

A runtime house must behave visually like a wall under construction:

* House sprite at approximately 50% opacity.
* Exactly one progress bar for the entire house.
* Progress remains until:

  * The topology dirty period is consumed.
  * The budgeted runtime rebuild has completed.
  * The lazy flow request queue is empty.
  * The async flow worker is idle.
* The house then returns to its original modulation.
* The progress bar disappears.

Do not show five progress bars for the five wall cells.

Do not track the five cells through the current ordinary tile-cell construction API.

Extend `BuildingConstructionOverlay` cleanly so it can also track an external sprite visual, while preserving all current wall/turret/fence behavior.

Recommended ownership:

* `BuildingConstructionOverlay` continues to own navigation-construction progress and completion.
* Add a small focused visual indicator script if needed, for example:

```text
scripts/map/building_construction_indicator.gd
```

* The indicator can be a child of the house sprite so its z-index stays above that house.
* It should draw one bar centred just above the sprite’s actual local rect.
* Preserve the sprite’s original RGB and alpha, and restore them exactly after construction.
* Clean up safely if the sprite is freed before construction completes.

The existing progress stages should remain unchanged:

* Dirty/quiet window.
* Budgeted runtime rebuild progress.
* Lazy flow queue drain.
* Async worker still active.
* Complete.

When extending `BuildingConstructionOverlay`, ensure processing remains active when it has pending external visuals even if `_pending_cells` is empty.

Do not introduce a second independent copy of the flow-construction state machine unless there is no clean way to reuse the overlay.

---

# Temporary `K` test

Create an isolated temporary controller, preferably:

```text
scripts/debug/house_runtime_test_controller.gd
```

Mark it prominently:

```text
TEMPORARY HOUSE PASS 1 TEST
Remove after runtime house placement is integrated into the real build system.
```

Keep the temporary code isolated and easy to delete.

The controller must:

1. Listen for a non-echo pressed `K` key event.
2. Locate:

```text
Map/MonTilemap/spawners/test_flyhouse
```

3. Interpret the marker’s cell as the house entrance cell.
4. Call the generic runtime house creation method.
5. Use:

```text
res://assets/sprites/house/house1.png
```

6. Create a clearly named runtime test house, for example:

```text
house_runtime_test
```

7. Prevent repeated `K` presses from stacking duplicate houses.
8. On a second press, safely do nothing and optionally print a concise debug warning.

Do not use the build menu.

Do not consume currency.

Do not add an item to `ItemCatalog`.

Do not create a preview.

Do not add refund or removal support.

Do not place five ordinary wall constructions independently.

The test controller may be wired from `BuildingManager` through a clearly marked temporary setup block or as an isolated temporary scene node. Do not put the raw `K` input handling into the main house implementation.

---

# Explicitly out of scope

Do not implement any of the following in this pass:

* Build-menu house item.
* Placement preview.
* Mouse placement.
* Cost or currencies.
* Refund.
* House removal.
* Save/load.
* Health or tantrum targeting.
* Build FX.
* House interiors.
* Entering the house.
* Door animation.
* Multiple orientations.
* Rotated footprints.
* Different footprint sizes.
* House-specific gameplay.
* Merchant behavior changes beyond snapping its existing target spot.
* Changes to the C++ extension.
* Broad BuildingManager cleanup.
* Broad LevelLoader refactoring.
* Changes to `test_flyhouse` authored position.

Do not register the five house blockers as five player-built durability targets.

Do not represent a house as five or six `BuildingObjectManager` buildings.

---

# Expected files

The clean implementation will likely involve:

New:

```text
scripts/map/house_manager.gd
scripts/debug/house_runtime_test_controller.gd
```

Possibly new, if useful for a clean single progress bar:

```text
scripts/map/building_construction_indicator.gd
```

Modified:

```text
scripts/map/level_loader.gd
scripts/map/building_manager.gd
scripts/map/building_construction_overlay.gd
scripts/map/ARCHITECTURE.md
```

Potentially `mainRun.tscn` only if the isolated temporary test controller is scene-wired there.

Do not modify `level_demo.tscn` merely to reposition `test_flyhouse`.

If the current local code differs slightly, adapt to the existing architecture while preserving the ownership and behavior specified here.

---

# Acceptance criteria

## Authored house

At level startup:

* `house_seedmerchant` is detected automatically from its `house_` prefix.
* Its sprite snaps to the tile grid.
* Its bottom edge exactly matches the bottom edge of its entrance cell.
* Its z-index is based on its bottom edge.
* Exactly five cells block navigation.
* The entrance remains walkable.
* The top sprite-only row has no map blocker.
* `seedmerchent_spot` is exactly at the entrance cell centre.
* The stored merchant `spot_cell` therefore resolves to the house entrance.
* The merchant can still path to the spot.
* The house blockers are included in startup topology precomputation.
* No runtime construction bar appears for the authored house.
* No extra post-startup topology rebuild is triggered specifically for the authored house.

## Z-index

Verify manually:

* An agent walking above the house base is drawn behind the house.
* An agent walking below the house base is drawn in front.
* An agent can travel through valid space behind the visual-only upper row.
* Sorting does not use the sprite centre.

## Runtime test

When `K` is pressed:

* One house using `house1.png` is created.
* Its entrance is exactly the `test_flyhouse` marker cell.
* Its sprite is snapped using the same rules as the authored house.
* Exactly five invisible wall cells are stamped.
* The entrance remains walkable.
* Player collision changes immediately for all five wall cells.
* One hard-topology invalidation is issued.
* One budgeted runtime rebuild begins through the existing system.
* The house is translucent during construction.
* Exactly one progress bar is shown.
* The bar remains until lazy flow work is genuinely finished.
* The sprite returns to normal afterward.
* Agents subsequently route around the five blockers and can use the entrance.
* Pressing `K` again does not duplicate or overwrite the house.
* No five-cell rebuild storm occurs.
* No five progress bars appear.

## Regression safety

Existing behavior must remain intact for:

* Ordinary wall placement and removal.
* Existing wall construction progress.
* Turrets and fences.
* Reservoir anchoring.
* Startup spawner binding capture.
* Monster/client/merchant route preparation.
* Seed merchant spawning and departure.
* Runtime topology signature resynchronization.

---

# Final report

Do not run the game.

At completion, report:

1. Every changed and created file.
2. The final ownership split.
3. How authored houses are prepared before spawner binding capture.
4. How the entrance cell is derived.
5. How sprite bottom alignment and z-index are calculated.
6. How the five wall cells are committed as one batch.
7. How runtime invalidation is issued only once.
8. How the single house progress bar reuses existing navigation construction state.
9. The exact temporary test code that should later be deleted.
10. Any compatibility wrapper retained.
11. Any remaining private coupling.
12. Production-quality concerns noticed.
13. Manual test steps, without claiming they were run.
