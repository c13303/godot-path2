Fix nighttime rose/plant construction correctly: disable it at every entry point and remove the obsolete unoptimized nighttime plant-processing branch.

Read and follow `AGENTS.md` and `ARCHITECTURE.md`.

Do not run Godot, tests, builds, exports, or compilation. The user will test.

## Problem

Placing roses during night causes a massive frame freeze.

The current plant-added flow behaves differently depending on the phase:

* During day, plant-layout changes use the deferred/coalesced/budgeted invalidation pipeline.
* During night, `BuildingManager._on_plant_added()` directly calls garden rebuild and monster retarget logic synchronously.

The problematic branch is approximately:

```gdscript
if not GameState.is_night:
    _building_invalidation_controller.after_plant_layout_changed(...)
    return

_add_plant_to_gardens(cell)
_retarget_agents_for_garden_topology_change(cell)
```

This nighttime branch can cause:

* complete garden topology rebuilding;
* garden ID/cache invalidation;
* flow-field and route invalidation;
* scanning and retargeting active monsters;
* one full rebuild per individual rose during rectangle placement.

`imperial_seed` is also a real plant placeable and reaches the same `plant_added` path.

The gameplay decision is now:

* real plants cannot be built during night;
* houses cannot be built during night;
* the obsolete synchronous nighttime plant-addition implementation must also be removed so future scripts or mechanics cannot reintroduce the freeze.

## Required result

During night:

* `rose` cannot be selected, previewed, dragged, purchased, or placed.
* `imperial_seed` cannot be selected, previewed, purchased, or placed.
* Any current or future placeable whose catalog category is `"plant"` must follow the same restriction.
* Houses cannot be selected, previewed, purchased, or placed.
* The house quick slot remains visible whenever its existing visibility conditions say it should be visible, but it is greyed and disabled.
* The gardening quick slot remains usable because it contains non-plant items that may still be valid at night.
* Existing valid nighttime gardening/build items retain their current behavior.

When night starts while a forbidden preview or drag is active:

* cancel the drag;
* clear the preview;
* clear the concrete selected build item;
* do not spend resources;
* do not place anything;
* restore normal weapon/tool control cleanly.

When day returns:

* plants and houses regain their normal availability automatically.

## Part 1 — Remove the obsolete nighttime plant-addition path

Inspect `BuildingManager._on_plant_added()` and the related garden topology / invalidation services.

Remove the phase-specific direct calls that synchronously rebuild garden topology and retarget agents during night.

Plant additions must have one consistent architecture regardless of phase:

```text
plant mutation
    → mark plant layout/topology dirty
    → coalesce repeated changes
    → process through the existing budgeted invalidation pipeline
```

Do not keep an unreachable legacy branch “just in case.”

The result must ensure that any legitimate non-player plant addition at night, such as:

* scripted events;
* debug tools;
* future mechanics;
* restoration code;
* internal calls to `PlantManager.add_plant()`;

does not trigger the old immediate full garden rebuild.

Reuse the existing daytime plant-layout invalidation path. Do not create a second asynchronous system.

### Preserve semantic correctness

If a plant is added internally at night despite player placement being disabled:

* topology must eventually update;
* garden routes must eventually become correct;
* affected agents must be retargeted through the normal queued/budgeted mechanism;
* no synchronous global rebuild may occur inside the `plant_added` signal callback.

If the current invalidation controller assumes daytime-only processing, fix that assumption narrowly so queued plant topology work can safely progress during night.

Do not simply ignore internal nighttime plant additions.

## Part 2 — Add one authoritative phase-availability rule

Create or consolidate one authoritative query for concrete placeable availability, preferably in the existing `GameUI` placement-selection ownership.

For example:

```gdscript
is_item_disabled_for_placement(item_id: StringName) -> bool
```

At night it must disable:

* all catalog items with `category == "plant"`;
* all house buildables;
* any other already-established nighttime-disabled categories such as hammer buildables, without changing their current behavior.

Do not hardcode separate `rose` and `imperial_seed` checks when the catalog category already expresses the rule.

Do not duplicate the phase policy across several UI and placement files.

Lower layers may call the authoritative query, but they must not independently recreate the rule.

## Part 3 — Build-picker and quick-slot behavior

Update the relevant picker/quickbar code, including `scripts/ui/game_ui.gd` and `scripts/shop/toolbuild.gd` where applicable.

### Gardening

During night:

* keep the gardening tool/quick slot available;
* show plant entries as disabled/greyed;
* prevent mouse activation;
* prevent keyboard confirmation;
* prevent gamepad confirmation;
* prevent remembered/default selection from choosing a disabled plant;
* if the previously remembered gardening item is a plant, select the next valid non-plant gardening item when opening the picker;
* if no valid item exists, leave no concrete build item selected.

Do not hide plants permanently from the catalog.

### Houses

During night:

* preserve all current house-slot visibility rules;
* when visible, render the house quick slot disabled/greyed;
* prevent opening it by mouse, keyboard shortcut, or gamepad;
* prevent house item selection from scripts or resumed UI state.

Do not alter builder-house uniqueness rules, prices, inventory, tutorials, or house availability during day.

## Part 4 — Cancel stale state on phase transition

When the game transitions into night, inspect the currently selected concrete placeable.

If it is now forbidden:

* cancel active drag placement;
* clear the build preview;
* clear selected item state;
* close or refresh the picker as appropriate;
* prevent the release event from committing the stale placement;
* ensure input returns to the expected weapon/tool state.

Use the existing drag/build cancellation APIs.

Do not add a parallel drag-state implementation.

This must work for:

* single-cell rose preview;
* rose rectangle drag;
* imperial-seed preview;
* house preview;
* house drag, if the architecture supports one;
* mouse and gamepad selection.

## Part 5 — Harden scripted selection

Any public method such as:

```gdscript
select_build_item_for_tool(tool_id, item_id)
```

must reject a phase-disabled concrete item.

Expected behavior:

* return failure cleanly;
* do not create a preview;
* do not change current build definition;
* do not consume currency or inventory;
* do not leave half-selected UI state.

This protects tutorials, debug helpers, restored selection state, and future callers.

## Part 6 — Add final placement-service guards

In the authoritative placement commit layer, such as `scripts/map/build_placement_service.gd`, reject forbidden items before any gameplay mutation.

Guard both single and batch/drag paths, including functions equivalent to:

* `try_apply_placeable(...)`
* `commit_drag_build(...)`

The check must happen before:

* placement validation that scans agents;
* price/inventory consumption;
* tile mutation;
* `PlantManager.add_plant()`;
* house creation;
* navigation invalidation;
* garden invalidation;
* sounds;
* particles;
* construction FX;
* placement signals.

A rejected placement must:

* place nothing;
* spend nothing;
* emit no placement-related mutation signal;
* trigger no garden or navigation work;
* leave no preview residue.

This is defense in depth against stale definitions, same-frame transitions, scripted calls, and future UI regressions.

Use the authoritative phase-availability query. Do not duplicate the plant/house policy inside the placement service.

## Part 7 — Avoid unnecessary nighttime occupancy work

Because plants can no longer be player-placed at night, ensure the placement preview/validation flow does not continue performing expensive plant placement checks while a disabled plant is selected.

In particular, avoid entering candidate-cell × active-agent occupancy scans for a phase-disabled item.

The availability check should short-circuit before preview validation and drag-cell validation.

Do not alter occupancy rules for valid daytime plant placement.

## Do not modify

Do not redesign or change:

* garden clustering rules;
* garden entrance scoring;
* flow-field algorithms;
* monster navigation semantics;
* builder AI;
* house construction progress;
* savegame formats;
* plant prices;
* house prices;
* inventory quantities;
* tutorial consumption state;
* valid nighttime non-plant placeables;
* unrelated quickbar behavior.

Do not reset gardens or route caches merely because night starts.

## Acceptance checks

### Plant restrictions

1. During day, rose and imperial-seed placement work exactly as before.

2. During night:

   * rose is visible in its picker but disabled;
   * imperial seed is visible but disabled;
   * neither can be selected by mouse, keyboard, or gamepad;
   * other valid gardening items remain selectable.

3. Open the gardening picker at night after previously using rose:

   * rose is not restored as the active item;
   * the next valid non-plant item is selected, or no item is selected if none is available.

4. Select rose during day, begin rectangle dragging, then transition to night:

   * drag is cancelled immediately;
   * preview disappears;
   * releasing input places nothing;
   * no seed or currency is spent;
   * no plant-added signal is emitted.

5. Call scripted item selection for rose or imperial seed during night:

   * selection is rejected;
   * no preview is created.

6. Pass a stale plant definition directly to single-placement and drag-commit functions during night:

   * both paths reject it before validation, spending, mutation, or signals.

### House restrictions

7. When the house quick slot is normally visible at night:

   * it remains visible;
   * it is disabled/greyed;
   * it cannot be opened by mouse, shortcut, or gamepad.

8. Start night with a house preview active:

   * preview and selection are cancelled;
   * placement cannot complete afterward;
   * no gems are spent.

9. Direct or scripted house selection/commit during night is rejected.

10. Returning to day restores normal house availability.

### Architecture and performance

11. Inspect `BuildingManager._on_plant_added()`:

* no synchronous night-only garden rebuild branch remains;
* plant changes use the same deferred/coalesced/budgeted invalidation entry point in every phase.

12. Trigger an internal `PlantManager.add_plant()` during night:

* the signal callback does not synchronously rebuild all gardens;
* topology work is queued/coalesced;
* topology eventually becomes correct;
* affected agents are retargeted through the existing queued pipeline.

13. Rectangle planting during day:

* repeated plant additions are coalesced;
* the system does not perform one complete synchronous garden rebuild per cell.

14. A disabled plant selected at night does not run expensive occupancy checks against all active monsters.

## Deliverable

After implementation, report:

* exact files changed;
* the authoritative function that owns phase-based placeable availability;
* the obsolete nighttime plant branch that was removed;
* how internal nighttime plant additions now reach the deferred/budgeted invalidation pipeline;
* how stale previews and drags are cancelled;
* where the final commit-level guards were added;
* any pre-existing behavior discovered that already satisfied part of the request.

Do not report tests as passed because no Godot execution is authorized.
