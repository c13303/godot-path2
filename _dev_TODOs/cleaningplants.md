# Refactor placeable plants/buildings for healthy future content additions

Read `AGENTS.md` and `ARCHITECTURE.md` first and follow them strictly.

## Context

The project is about to enter a content-production phase with more placeable plants/buildings, including:

* Tall plants using 32×64 or other visual sizes.
* Passive slowdown or future speed-up plants.
* Plants reacting when agents enter their tile.
* Defensive plants with cooldowns or custom effects.
* Additional conventional turrets.
* Potentially more stateful placeables later.

The current architecture already has useful generic foundations:

* `ItemCatalog` describes placement, layer, blocking, speed multipliers, durability, visuals, and turret data.
* `BuildPlacementService` handles normal one-cell placement.
* `BuildingObjectManager` manages runtime building objects.
* `AgentCellTracker` provides optimized cell-transition detection.
* `PlaceableNavImpact` distinguishes topology changes from speed-only changes.
* `TurretSystem` already supports conventional turret definitions reasonably well.

Do **not** rewrite these systems.

The objective is not maximum genericity. The objective is a healthy, explicit architecture where adding normal content does not require accumulating item-ID conditions across central managers.

---

# Main goal

Perform one focused refactor that makes one-cell placeables safe and maintainable for future content.

After this refactor:

1. Logical placeable identity must persist reliably through save/load.
2. Runtime visual scenes must receive enough context to represent their placeable cleanly.
3. Agent-on-tile interactions must use one clear dispatch path based on declared semantics instead of growing item-ID branches.
4. Existing rose, imperial, ronce, pasteque, turret, Kraken, house, savegame, placement, removal, and navigation behavior must remain unchanged.
5. The architecture must remain simple and avoid speculative universal frameworks.

---

# Critical issue 1: persist logical placeable identity

## Current problem

Scene-based placeables can use invisible marker tiles.

Logical item identity is currently reconstructed in several places from approximately:

```text
target layer + source/atlas coordinates
```

This becomes ambiguous when multiple items on the same layer use the same invisible marker tile.

That is unsafe for future traps, plants, turrets, and other scene-based placeables.

## Required change

Make `BuildingObjectManager` own a persistent registry of runtime placeable instances.

Each registered one-cell placeable must retain at least:

```text
cell
item_id
target_layer
direction, when applicable
optional custom state
```

Use an explicit typed representation if appropriate, or a carefully validated serialized dictionary format if that integrates better with the current save architecture.

The logical `item_id` must become the authoritative identity for runtime placeables.

## Save/load requirements

Extend the existing savegame format with a dedicated section for logical placeable instances.

On save, serialize registered placeables using their explicit `item_id`.

On load:

1. Restore normal TileMap data as currently required.
2. Restore/rebuild runtime placeable registrations using saved logical identity.
3. Instantiate their visual/runtime scenes from the corresponding item definition.
4. Restore optional state when supported.
5. Re-register durability and existing runtime systems correctly.

## Backward compatibility

Old saves must continue to load.

For old saves without explicit placeable-instance data:

* Retain the existing tile-based inference only as a legacy migration fallback.
* Reconstruct the logical registry where inference is unambiguous.
* Do not silently guess when several item definitions match the same marker.
* Emit one clear development warning for ambiguous legacy data and use the safest existing fallback behavior.

Tile-based inference must no longer be the normal authoritative path for new saves.

## Catalog validation

Add a development-time validation that detects duplicate marker identities:

```text
target_layer + source_id + atlas_coords + alternative_tile
```

Duplicates are allowed only when explicit logical identity makes them safe, but the validator should report them because they are unsafe for legacy inference and authored TileMap reconstruction.

Keep validation centralized and cheap. It must not run every frame.

---

# Critical issue 2: give runtime scenes a minimal placeable context

## Current problem

A `building_visual_scene` is instantiated and positioned, but custom scenes receive little or no structured information about the logical placeable they represent.

This encourages separate item-specific systems to rediscover:

* The item ID.
* The map cell.
* The item definition.
* The owning runtime registry.
* Saveable local state.

## Required change

Introduce a small runtime context contract for instantiated placeable scenes.

Use a lightweight typed object/resource/data class, or a clearly typed setup method, such as conceptually:

```gdscript
setup_placeable(context)
```

The context should expose only stable information genuinely useful to placeable runtime scenes:

```text
cell
item_id
item definition or immutable relevant configuration
target layer
direction, when applicable
reference to the appropriate placeable/runtime owner
```

Do not pass the entire `BuildingManager` merely for convenience.

Do not give scenes broad access to unrelated gameplay systems.

## Compatibility

Existing visual scenes that do not implement the setup method must continue working unchanged.

Use optional method detection only during instantiation, not every frame.

The current optional `reset_to_idle()` behavior must remain supported.

## Runtime lookup

`BuildingObjectManager` must provide a clean public query to retrieve:

* The logical placeable registration at a cell.
* Its item ID.
* Its runtime node, if any.

Avoid external systems reading private dictionaries directly.

---

# Critical issue 3: unify agent-on-placeable contact dispatch

## Current problem

The optimized `AgentCellTracker` is reusable, but downstream interaction logic contains explicit item-ID branches for cases such as ronce, pasteque, Kraken, plants, and turrets.

Additional content would cause more IDs to be added across:

* Agent tile interaction handling.
* Placement-time agent rechecks.
* Contact animation routing.
* Possibly dedicated systems and scene wiring.

## Required architecture

Keep `AgentCellTracker` as the only transition/indexing foundation.

Do not create another watcher.

Do not scan all agents against all placeables.

When an agent enters or is rechecked on a cell:

1. Resolve the logical placeable instance at that cell.
2. Resolve its item definition.
3. Determine whether it declares an agent-contact behavior.
4. Dispatch through one focused contact router/controller.
5. Let the appropriate behavior owner handle the actual effect.

## Declarative semantics

Add only the minimum catalog semantics required, for example conceptually:

```gdscript
"agent_contact_enabled": true
"recheck_agents_on_place": true
```

Choose names that fit the existing catalog conventions.

`recheck_agents_on_place` means that when the placeable is constructed underneath agents already indexed in that cell, those agents receive an immediate targeted recheck.

Do not infer this from hardcoded IDs.

## Behavior ownership

Do not create a giant universal effect dictionary or a generic status-effect engine unless the existing code already needs one.

Support two healthy paths:

### Simple existing behavior

Existing centralized systems such as plant trampling, turret consumption, or Kraken may continue owning their gameplay logic.

However, they must be reached through the unified contact router rather than selected through scattered item-ID branches.

### Self-contained custom scene behavior

A runtime placeable scene may optionally implement a narrow contact callback, conceptually:

```gdscript
on_agent_entered_placeable(agent, agent_category)
```

Use a better typed signature if the project already has an appropriate agent abstraction.

The router must check the optional method once per relevant cell transition, not per frame.

## Explicit special cases are acceptable

Do not force fundamentally different mechanics into one generic implementation.

It is acceptable that:

* Kraken keeps a dedicated `KrakenSystem`.
* Conventional turrets keep `TurretSystem`.
* Growable crops remain owned by `PlantManager`.
* A future complex plant receives its own focused controller.

The improvement is that central placeable and agent-tracking code dispatches according to declared capabilities, rather than knowing every concrete item ID.

---

# Contact animation cleanup

Review `PlantContactDanceRouter` and equivalent visual-contact routing.

Replace exact checks such as “this is ronce” where a semantic declaration is sufficient.

Add a minimal item definition field if needed, for example conceptually:

```gdscript
"contact_visual_feedback": "dance"
```

or a simpler boolean if there is only one supported behavior.

Do not introduce an elaborate animation taxonomy prematurely.

Existing contact dance behavior must remain visually unchanged.

---

# Placement-time recheck cleanup

Remove the current item-ID/category-specific logic that decides whether agents already occupying a newly placed cell need rechecking.

Replace it with the declarative item semantic introduced above.

The flow should remain targeted:

```text
place item
→ register logical instance
→ update cell/navigation data
→ ask AgentCellTracker to recheck only agents indexed in that cell
```

No global agent pass.

---

# PlantManager boundary

Do not attempt to turn `PlantManager` into a universal plant framework in this task.

It currently owns crop-style lifecycle behavior such as rose and imperial growth/watering.

Keep that responsibility intact.

Static defensive plants, traps, turrets, and passive navigation plants should remain ordinary placeables unless they genuinely need crop growth behavior.

Only clean direct dependencies needed for the new contact dispatch.

Do not pre-build support for hypothetical growth models.

---

# Visual size and footprint rules

This task concerns one-cell logical placeables.

A runtime scene may visually be:

* 32×64.
* 64×64.
* Taller or wider than one tile.
* Animated.
* Composed of multiple sprites.

Its scene origin/base must correspond to the logical occupied cell.

Do not implement general multi-cell footprints in this task.

Do not reinterpret a tall 32×64 sprite as occupying two gameplay cells.

Document this rule close to the runtime placeable scene contract.

---

# Navigation requirements

Preserve the current distinction between:

* Hard topology changes requiring lazy Flow Field invalidation/rebuild.
* Speed multiplier changes that can update affected cells without global Flow Field rebuilding.
* Player-only collision.
* Agent-only blocking.
* Projectile blocking.

Do not merge these concepts.

New contact-dispatch code must not trigger navigation rebuilds.

Ensure future speed-up values greater than `1.0` remain supported anywhere speed multipliers are validated, stored, passed to C++, or reapplied after load.

Do not clamp all multipliers to a maximum of `1.0`.

Reasonable positive validation is acceptable.

---

# Removal requirements

All removal paths must unregister the same logical instance exactly once:

* Player demolition.
* Damage/destruction.
* Plant trampling.
* Turret consumption.
* Scripted removal.
* Save reload/map reset.
* Scene teardown.

Unregistration must clean:

* Runtime visual node.
* Logical registry.
* Durability registration.
* Contact behavior/system registration.
* Relevant cell indexes.
* Navigation/speed state through the existing invalidation path.

Avoid duplicated cleanup logic. Establish one authoritative removal/unregister flow where feasible.

Do not rewrite all removal code if a smaller shared cleanup entry point is sufficient.

---

# Existing behavior that must not regress

Verify the code paths for:

* Rose placement, watering, growth, harvesting, trampling, stacking, and save/load.
* Imperial plant lifecycle.
* Pasteque behavior.
* Ronce slowdown and contact animation.
* Conventional turret placement, targeting, durability, consumption, refund/removal, and save/load.
* Kraken placement on water, custom runtime scene, damage/contact handling, destruction, and save/load.
* Houses and WIP houses.
* Passive terrain-speed changes.
* Slowdown application to agents.
* Player collision.
* Agent blocking.
* Projectile blocking.
* Placement previews for scene-based placeables.
* Directional placeables.
* Legacy authored map buildings.
* Old savegames.

Do not change gameplay values or visual timing.

---

# Architecture constraints

Follow these strictly:

* No new giant manager.
* No universal “effect engine” created for hypothetical content.
* No per-frame placeable polling.
* No duplicate agent spatial index.
* No direct item-ID switches in core placement/tracking code when item semantics are sufficient.
* No broad public exposure of internal dictionaries.
* No unrelated cleanup.
* No major rewrite of the catalog format.
* No forced inheritance hierarchy for every placeable scene.
* Optional capabilities are preferable to empty mandatory methods.
* Keep C++ generic; this task should primarily remain on the GDScript/content architecture side unless an actual C++ correctness issue is found.
* Preserve strict GDScript typing.
* Avoid unsafe `:=` inference for dynamic, numeric, nullable, signal, `Dictionary`, or `Array` results.
* If any single existing file would gain more than roughly 150 lines, create a focused owner file rather than expanding the manager.
* Each new file must have one clear gameplay responsibility.

---

# Suggested ownership

Verify actual names and architecture before editing, but the likely responsibilities are:

### `BuildingObjectManager`

Owns:

* Logical runtime placeable registry.
* Runtime scene instantiation.
* Runtime scene setup context.
* Save serialization/restoration of logical placeables.
* Public lookup by cell.
* Unified unregistering of runtime placeable instances.

It must not own concrete combat effects.

### New focused placeable contact router/controller

Owns:

* Receiving agent/cell transition notifications.
* Resolving the logical placeable at the cell.
* Checking declared contact capability.
* Dispatching to the existing specialized owner or optional runtime scene callback.

It must not own agent tracking or all concrete gameplay effects.

### `AgentCellTracker`

Continues owning:

* Agent-to-cell indexing.
* Cell transition detection.
* Targeted cell rechecks.

It must not learn concrete placeable IDs.

### `ItemCatalog`

Owns:

* Minimal declarative capability flags.
* Existing placeable configuration.

Do not put runtime mutable state in catalog definitions.

### Specialized systems

Continue owning their actual mechanics:

* `PlantManager`
* `TurretSystem`
* `KrakenSystem`
* Other focused systems

---

# Migration strategy

Implement incrementally inside the same task:

1. Add logical runtime identity and lookup without removing legacy inference.
2. Add save serialization/restoration for explicit identity.
3. Add the runtime context setup contract.
4. Add the unified contact router.
5. Migrate existing ronce, pasteque, turret, plant, and Kraken contact cases.
6. Replace placement-time recheck hardcoding.
7. Replace avoidable contact-animation item-ID branches.
8. Keep legacy inference only for old saves/authored tiles.
9. Add validation and development diagnostics.
10. Remove obsolete duplicated paths only after all existing callers use the new route.

At no intermediate stage should existing content become unloadable.

---

# Diagnostics

Add concise development-only diagnostics for:

* Duplicate marker identities.
* Save records referencing unknown item IDs.
* A registered placeable whose runtime node is unexpectedly missing when one is required.
* Ambiguous legacy marker inference.
* Double registration or double removal of the same cell.

Avoid normal gameplay log spam.

Do not keep temporary tracing logs after the refactor.

---

# Validation

Do not launch Godot, run the game, export, or execute tests unless explicitly authorized by the user.

Perform static validation only:

* Search for remaining concrete placeable IDs in core placement/contact/recheck code.
* Check all save/load call sites.
* Check all removal paths.
* Check strict typing.
* Check signal connection/disconnection symmetry.
* Check initialization order during load.
* Check that runtime scenes are not instantiated twice.
* Check that old tile-only saves retain a migration path.
* Check that speed multipliers above `1.0` are not rejected.
* Check that no new `_process()` or global agent scan was introduced.

---

# Acceptance criteria

The refactor is complete only when all of the following are true:

1. New saves explicitly preserve logical `item_id` for runtime placeables.
2. Two different scene-based placeables may safely share the same invisible marker tile on the same layer in new saves.
3. Old saves still load through a controlled legacy fallback.
4. Core agent tracking contains no ronce, Kraken, pasteque, turret, or concrete plant item-ID knowledge.
5. Placing a contact-enabled object beneath an existing agent triggers only a targeted cell recheck.
6. A new passive slowdown or speed-up plant requires catalog/content configuration, not central manager branches.
7. A new simple contact plant can be added with:

   * An item definition.
   * A runtime scene or focused behavior owner.
   * Declared contact semantics.
   * No new branch in `BuildingManager` or `AgentCellTracker`.
8. Conventional turrets continue using the current turret architecture.
9. Crop lifecycle behavior remains in `PlantManager`.
10. Scene dimensions remain independent of the one-cell logical footprint.
11. Removal unregisters runtime placeable identity exactly once.
12. No per-frame global scans or new navigation rebuild triggers were introduced.
13. Existing gameplay behavior is preserved.
14. Temporary debug logs and obsolete branches are removed.

---

# Final report

At completion, provide:

1. A concise description of the final architecture.
2. The exact files created and modified.
3. The authoritative owner of:

   * Logical placeable identity.
   * Runtime scene lifecycle.
   * Contact dispatch.
   * Concrete effects.
   * Save/load migration.
4. How old saves are handled.
5. Which former item-ID branches were removed.
6. How to add:

   * A passive 32×64 slowdown plant.
   * A passive speed-up plant.
   * A simple contact-damage plant.
   * A conventional turret.
7. Any remaining intentional special cases and why they remain specialized.
8. Static validation performed.
9. Anything that still requires manual in-game testing by the user.
