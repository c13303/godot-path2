Implement complete nighttime placement restrictions for real plants and houses.

Read and follow `AGENTS.md`. Keep the change narrow and production-oriented. Do not run Godot, tests, builds, exports, or compilation.

## Context

Nighttime placement of a rose currently emits `PlantManager.plant_added`, which reaches:

* `BuildingManager._on_plant_added()`
* `GardenTopologyService.add_plant_to_gardens()`
* `rebuild_plant_zone_from_layer()`

This synchronously rebuilds all gardens, route caches, and stale monster assignments. Rectangle rose placement can trigger that complete rebuild once per placed rose.

We are intentionally removing this gameplay possibility instead of optimizing the nighttime garden rebuild.

Important: `imperial_seed` is also a `category == "plant"` placeable and emits the same `plant_added` signal. It must follow the same nighttime restriction, otherwise the lag path remains reachable.

## Required behavior

During night:

* `rose` cannot be selected, previewed, dragged, purchased, or placed.
* `imperial_seed` cannot be selected, previewed, purchased, or placed.
* All actual `category == "plant"` placeables should follow this restriction so future garden plants do not accidentally reintroduce the same problem.
* The gardening quick slot itself must remain available.
* Non-plant gardening items must retain their current behavior:

  * ronce
  * pasteque
  * turrets
  * traps
  * kraken
  * other non-plant gardening placeables
* House construction must be disabled.
* When the house quick slot is normally visible, keep it visible but disabled/greyed at night.
* Do not alter the existing conditions deciding whether the house quick slot is visible.
* Hammer and unbuild nighttime restrictions must remain unchanged.

During day, all current placement behavior must remain unchanged.

## Implementation

### 1. Use one authoritative item-level phase gate

In `scripts/ui/game_ui.gd`, make `is_item_disabled_for_placement(item_id)` the authoritative query for whether a concrete placeable is blocked by the current phase.

At night it must return `true` for:

* hammer buildables;
* house buildables;
* placeables whose catalog category is `"plant"`.

Do not disable the entire gardening tool because it contains valid nighttime combat/build items.

Avoid maintaining separate duplicated lists of blocked items in multiple UI classes.

### 2. Correctly handle the day-to-night transition

Update `GameUI._on_game_mode_changed()` so that when night starts and the currently equipped concrete build item is now phase-disabled:

* close any open quickbar/build selection state as appropriate;
* clear the selected build item immediately;
* remove its preview;
* allow the equipped weapon to become active again;
* ensure no stale rose or house selection survives into night.

This must cover both single-cell placement and an active drag-build operation.

`BuildDragController` already cancels a drag when the selected placeable definition becomes unavailable. Reuse that behavior rather than adding a second drag-state system.

### 3. Make the build picker reflect the restriction

In `scripts/shop/toolbuild.gd`:

* make the item-level nighttime check delegate to `game_ui.is_item_disabled_for_placement(item_id)` instead of maintaining another independent hammer/house list;
* render phase-disabled items greyed/disabled;
* reject mouse activation;
* reject gamepad confirmation;
* prevent scripted/default/resumed selection logic from committing them;
* when the gardening picker opens at night, do not automatically highlight `rose` or another blocked plant as its usable default;
* when the previously remembered gardening item is a blocked plant, select the next usable gardening item when one exists.

The gardening menu may remain open at night because other gardening items remain usable.

Do not hide the rose permanently and do not remove it from the catalog. It should automatically become usable again after night ends.

### 4. Harden scripted selection

Update `GameUI.select_build_item_for_tool()` so it refuses any item for which `is_item_disabled_for_placement(item_id)` is true.

This prevents tutorials, debug helpers, or future scripted callers from equipping a forbidden nighttime placeable.

### 5. Add commit-level defense in depth

In `scripts/map/build_placement_service.gd`, reject phase-disabled items at the beginning of both:

* `try_apply_placeable(...)`
* `commit_drag_build(...)`

Perform this check before:

* placement validation;
* currency or inventory consumption;
* tile mutation;
* `PlantManager.add_plant()`;
* house creation;
* navigation invalidation;
* build FX or sound.

Use the same `game_ui.is_item_disabled_for_placement(item_id)` query. Do not recreate the phase policy inside the placement service.

This guard must protect houses as well as plants, even if a stale definition or direct internal call bypasses normal selection flow.

A rejected placement must:

* place nothing;
* spend nothing;
* emit no plant/building placement signal;
* create no preview residue;
* trigger no navigation or garden rebuild.

### 6. Preserve existing house-slot behavior

The current code already disables `BUILD_HOUSE_ID` at night in `GameUI._is_quickbar_slot_disabled()` and clears structural selections when night starts.

Preserve that behavior and verify the complete path rather than replacing it unnecessarily.

Expected result when the house slot is otherwise available:

* slot remains visible;
* slot is greyed/disabled;
* mouse, keyboard number key, and gamepad navigation cannot open it;
* an already active house preview is cancelled when night begins;
* direct selection or direct commit cannot place a house.

### 7. Do not change unrelated systems

Do not modify:

* garden clustering or garden topology algorithms;
* nighttime monster retargeting;
* flow-field allocation;
* house construction progress;
* builder AI;
* save/load formats;
* tutorial progression;
* item prices or inventory;
* which non-plant gardening constructions are allowed at night.

Tutorial text and arrows are already globally hidden during night. Only touch tutorial code if verification reveals an actual bypass or visible stale arrow.

## Acceptance checks

1. Select a rose during the day, begin dragging, then let night start:

   * drag and preview disappear;
   * releasing the mouse places nothing;
   * no seeds are spent.

2. Open gardening during night:

   * rose is visibly disabled;
   * imperial seed is visibly disabled;
   * neither can be selected with mouse or gamepad;
   * non-plant gardening items retain their previous nighttime availability.

3. Call `select_build_item_for_tool("gardening", "rose")` during night:

   * returns `false`;
   * creates no selection.

4. Attempt a direct single or drag placement using a stale rose definition:

   * placement service rejects it before purchase or mutation;
   * `PlantManager.add_plant()` is not called.

5. When the house quick slot should be visible during night:

   * it remains visible but disabled;
   * it cannot be opened;
   * no house can be selected or placed;
   * no gems are spent.

6. Start night while a house preview is active:

   * preview and selection are cleared immediately.

7. Return to day:

   * rose, imperial seed, and houses regain their normal availability;
   * no permanent selection or UI lock remains.

8. Daytime rose rectangle placement and daytime house placement remain behaviorally unchanged.

Report the exact files changed and briefly describe where the authoritative phase gate now lives. Do not run Godot or tests.
