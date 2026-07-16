You are working on the provided Godot 4 codebase.

Read `AGENTS.md` completely before editing and follow it strictly.

Do not run Godot, tests, builds, compilation, or exports. The user will test manually.

# Task: inventor blueprints and persistent buildable unlocks

Some buildables must now be permanently unlocked through blueprints purchased from the Inventor.

Implement a small, data-driven blueprint system with prerequisite support. Keep it generic enough for more blueprints later, but do not build a complex skill-tree framework or over-engineer the feature.

## Required gameplay

On a fresh game, these buildables are locked:

* `ronce`
* `fence`
* `kraken`

Locked buildables must:

* not appear in their build picker;
* not be selectable through keyboard, mouse, gamepad, tutorials, or scripted selection;
* not produce a placement preview;
* not be placeable through a stale selection or direct placement call.

Existing authored or previously placed instances must continue to function normally. The lock only controls the player’s ability to place new instances.

## Inventor blueprints

The Inventor dialog currently contains only its greeting and an `OK` choice.

Add blueprint choices to this dialog.

### Paid blueprints

1. `ronce`

   * Blueprint price: `10 money`
   * No prerequisite.

2. `fence`

   * Blueprint price: `10 money`
   * No prerequisite.

These are one-time blueprint prices. Do not change the normal construction prices of the buildables:

* `ronce` must keep its existing build cost and growth-price behavior;
* `fence` must keep its existing build cost;
* blueprint money is paid only once to unlock the buildable.

### Kraken dependency

`kraken` requires both of these blueprints:

* `ronce`
* `fence`

Interpretation for this implementation:

* Kraken has no separate purchase price.
* As soon as both `ronce` and `fence` are unlocked, `kraken` becomes unlocked automatically.
* Do not display a purchasable Kraken row.
* Model this through the generic prerequisite/automatic-unlock data rather than hardcoding `if ronce and fence then kraken` inside the Inventor controller.

A future blueprint must be able to declare zero or more prerequisite blueprint IDs.

## Inventor dialog behavior

Reuse the existing generic `DialogUI` and follow the existing merchant-dialog pattern where appropriate.

The dialog choices should be ordered:

1. Available blueprint rows.
2. Existing `OK` choice at the bottom.

For each paid blueprint row:

* use the buildable’s existing item icon from `items.png` / `ItemCatalog`;
* use the existing localized item display name;
* display price `10`;
* display the money icon;
* enable the row only when the player owns at least 10 money;
* keep the dialog open after purchase.

On successful purchase:

1. Deduct exactly 10 money through the authoritative progression currency API.
2. Permanently unlock the blueprint.
3. Play the existing purchase sound.
4. Refresh the dialog choices immediately.
5. Remove the purchased row.
6. Make the corresponding buildable immediately available in its normal build picker.
7. Re-evaluate automatic prerequisite unlocks, causing Kraken to unlock after the second required blueprint is bought.

Do not:

* grant an inventory item;
* animate an item toward an inventory slot;
* charge the construction cost;
* close the dialog after a blueprint purchase;
* create a separate Blueprint dialog scene;
* put persistent/economy logic directly in `inventor_dialog_controller.gd`.

Keep the current Inventor greeting and interaction/lifecycle behavior.

When every paid blueprint is already unlocked, the dialog should simply show its greeting and the `OK` choice.

## Architecture

The current relevant architecture is:

* `scripts/ui/inventor_dialog_controller.gd`

  * currently a thin dialog adapter;
  * should remain an adapter, not become the owner of progression state.

* `scripts/ui/dialog.gd`

  * already supports icons, price text, currency icons, enabled rows, non-closing choices, and `refresh_choices()`.

* `scripts/ui/merchant_dialog_controller.gd`

  * provides a useful example for creating and refreshing shop rows.

* `scripts/ui/game_ui.gd`

  * currently owns build availability/economy façade methods;
  * already has `is_build_item_available()`, affordability queries, currency spending paths, and toolbuild refresh helpers;
  * it is already very large, so add only narrow wrappers or gates here, not the blueprint implementation itself.

* `scripts/shop/toolbuild.gd`

  * already hides rows by calling `game_ui.is_build_item_available()`;
  * it should not gain blueprint-specific rules.

* `scripts/gameState/progression.gd`

  * owns saved progression and currencies;
  * it is also already very large, so keep its additions to service setup, narrow public wrappers, and save/load integration.

* `scripts/map/build_mode_state_controller.gd`

  * resolves the selected buildable definition.

* `scripts/map/build_placement_service.gd`

  * owns commit-level placement validation.

## Preferred ownership

Create one focused blueprint progression owner, for example:

```text
scripts/gameState/blueprint_unlock_service.gd
```

A different name is acceptable if it is clearer, but keep one obvious owner.

This service should own:

* blueprint definitions;
* the set of unlocked blueprint IDs;
* prerequisite evaluation;
* automatic unlock resolution;
* purchase eligibility;
* serialization and restoration of unlock state.

A simple dictionary definition is sufficient. For example, conceptually:

```gdscript
ronce:
    build_item_id = "ronce"
    currency = &"money"
    price = 10
    prerequisites = []
    automatic = false

fence:
    build_item_id = "fence"
    currency = &"money"
    price = 10
    prerequisites = []
    automatic = false

kraken:
    build_item_id = "kraken"
    price = 0
    prerequisites = [&"ronce", &"fence"]
    automatic = true
```

The exact representation may differ.

Do not create:

* a generic graph framework;
* resources/scenes for three tiny definitions;
* an event bus;
* abstract base classes;
* a full visual tree UI;
* separate manager/controller/catalog files unless there is a concrete responsibility that justifies each file.

A single focused service with straightforward data is preferred.

## Required public behavior

Expose narrow intention-revealing APIs from the owner, directly or through the `progression` façade, such as:

```gdscript
is_blueprint_buildable(item_id: String) -> bool
is_blueprint_unlocked(item_id: String) -> bool
get_purchasable_blueprint_ids() -> Array[StringName]
get_blueprint_price(item_id: String) -> int
get_blueprint_currency(item_id: String) -> StringName
can_purchase_blueprint(item_id: String) -> bool
try_purchase_blueprint(item_id: String) -> bool
get_blueprint_save_data() -> Array
apply_blueprint_save_data(data: Variant) -> void
```

These names are illustrative. Use the smallest coherent API.

Requirements for `try_purchase_blueprint()`:

* reject unknown IDs;
* reject automatic-only blueprints;
* reject already unlocked blueprints;
* reject blueprints whose prerequisites are not satisfied;
* reject insufficient currency without changing any state;
* perform currency deduction and unlock atomically;
* resolve newly satisfied automatic unlocks after success;
* return `true` only on a successful new purchase.

Automatic prerequisite resolution should also run after loading saved state.

Do not poll blueprint state every frame in the progression service.

## Build availability integration

Blueprint state must be an additional gate, not a replacement for existing level configuration.

Effective availability should be conceptually:

```text
existing level / house / item availability
AND
blueprint unlocked, when the item has a blueprint requirement
```

Items without blueprint definitions must preserve their current behavior exactly.

Do not remove `ronce`, `fence`, or `kraken` from:

* `ItemCatalog`;
* level tool-shop configuration;
* their normal tool categories;
* existing build-price configuration.

Their normal availability path should remain intact after the blueprint gate passes.

Integrate the gate centrally through `game_ui.is_build_item_available()` or an equally authoritative existing availability path so `toolbuild.gd` continues to work without blueprint-specific knowledge.

Also add defense in depth:

1. `BuildModeStateController.selected_placeable_def()` must return an empty definition when the selected item is no longer available.
2. `BuildPlacementService` commit paths must reject unavailable items before validation, spending, tile mutation, object creation, FX, navigation invalidation, or signals.
3. Both single placement and drag placement must be protected.
4. `try_purchase_build()` must continue rejecting unavailable buildables.
5. A selected locked item restored from an old or malformed save must be cleared rather than remaining as a hidden stale selection.

Do not merge blueprint locking into `is_item_disabled_for_placement()`. That method currently represents phase restrictions such as night. Keep permanent progression availability and temporary phase disabling conceptually separate.

## Save/load

Blueprint unlocks are permanent player progression and must be saved.

The current save version is `9`.

1. Increment the save version.
2. Add a dedicated save section, for example:

```json
"unlocked_blueprints": [
  "ronce",
  "fence",
  "kraken"
]
```

3. Validate the section:

   * it must be an array;
   * entries must be strings;
   * unknown blueprint IDs should not corrupt the load. Either ignore them with a warning or reject them consistently, choosing the safer current save-policy convention.

4. Restore blueprint state before restoring or validating the active selected build item.

5. On a genuinely fresh game:

   * no blueprint starts unlocked;
   * therefore `ronce`, `fence`, and `kraken` are locked.

6. Migration for saves created before this blueprint feature:

   * previous versions allowed all three buildables;
   * migrate versions `1–9` with `ronce`, `fence`, and `kraken` already unlocked;
   * this preserves existing players’ capabilities and avoids silently removing builds from an ongoing save.

7. A normal save created by the new version must restore exactly the unlocked state it saved.

8. Fresh-game reset must naturally return to an empty unlock set. Do not store this state in an autoload that survives scene reloads unintentionally.

Update save diagnostics/summary only if useful and compact, for example adding the unlocked blueprint count. Do not broadly refactor the save system during this task.

## Localization

Use existing localized item-name keys wherever possible:

```text
item.ronce
item.fence
item.kraken
```

Do not hardcode French-only names in the controller.

Add only the translation keys genuinely required for blueprint-specific UI, in both English and French translation JSON files.

Possible generic wording, only if needed:

```text
EN: Blueprint
FR: Plan
```

The existing Inventor greeting should remain unchanged unless a missing translation must be restored.

## Scene wiring

Update `mainRun.tscn` only as needed for explicit dependencies.

For example, the Inventor controller may receive a progression reference, or it may use narrow `game_ui` façade methods. Choose the cleanest path with the least coupling.

Do not make the Inventor controller search arbitrary scene nodes every purchase when a stable exported reference or existing façade is available.

Preserve:

* interaction target group registration;
* Inventor proximity checks;
* day/night availability;
* shared resident lifecycle;
* dialog input locking;
* closing through `OK`, Escape, controller cancel, and close button.

## Performance

This system must be event-driven.

Acceptable work:

* evaluate a few blueprint definitions when the dialog opens;
* evaluate them after a purchase;
* evaluate them during save restoration;
* query one dictionary during build availability checks.

Do not add:

* map scans;
* agent scans;
* per-frame prerequisite traversal in gameplay systems;
* repeated save-data reconstruction;
* unnecessary signals across unrelated managers.

The existing `toolbuild.gd` per-frame refresh may query the resulting boolean, but the query itself must be constant-time and side-effect free.

## Edge cases

Handle these cases:

* Player has 0–9 money: Ronce and Fence rows are visible but disabled.
* Player has exactly 10 money: one blueprint can be purchased.
* Purchasing Ronce first unlocks only Ronce.
* Purchasing Fence first unlocks only Fence.
* Purchasing the second prerequisite automatically unlocks Kraken.
* Repeated activation cannot charge twice.
* A failed purchase changes neither money nor unlock state.
* Closing and reopening the dialog preserves purchased state.
* Save after one purchase restores only that purchase; Kraken remains locked.
* Save after both purchases restores all three unlocked.
* An old version-9 save migrates with all three unlocked.
* Locked rows do not appear in the build picker.
* Other buildables remain unaffected.
* Existing Ronce/Fence/Kraken world objects remain functional even when the corresponding blueprint is locked in a fresh test setup.
* Direct or stale placement attempts cannot bypass the lock.
* Buying a blueprint while a different build menu was previously open does not leave stale quickbar UI under the dialog.

## Scope restrictions

Do not:

* refactor the full shop system;
* refactor the full save system;
* move general build availability out of `game_ui.gd`;
* redesign `DialogUI`;
* change construction prices;
* change buildable behavior;
* change Inventor spawning or housing;
* add a visible technology-tree screen;
* add more blueprints than the three specified;
* add speculative categories, tiers, research points, or blueprint inventory items.

## Expected implementation shape

A clean solution should approximately involve:

* one new focused blueprint unlock/progression service;
* small save/load integration in `progression.gd`;
* small build-availability façade integration in `game_ui.gd`;
* Inventor dialog rows and purchase handling in `inventor_dialog_controller.gd`;
* small defense-in-depth availability checks in the existing selection/placement owners;
* required scene wiring;
* translation additions.

Do not add the whole implementation to `progression.gd`, `game_ui.gd`, or `inventor_dialog_controller.gd`.

## Manual test checklist

Do not run these tests yourself. Report them for the user.

1. Start a genuinely fresh game.
2. Open Gardening:

   * Ronce absent.
   * Kraken absent.
3. Open Hammer:

   * Fence absent.
4. Open Inventor with less than 10 money:

   * Ronce and Fence blueprint rows visible but disabled.
   * OK closes normally.
5. Give the player 10 money and purchase Ronce:

   * money becomes 0;
   * Ronce row disappears;
   * Ronce appears in Gardening;
   * Fence remains locked;
   * Kraken remains locked.
6. Repeat from a fresh game by purchasing Fence first.
7. Purchase both:

   * total blueprint cost is 20 money;
   * Kraken unlocks automatically;
   * Kraken appears in Gardening;
   * no Kraken purchase row is shown.
8. Verify normal construction still charges existing gem prices.
9. Save after only one blueprint, reload, and verify state.
10. Save after both blueprints, reload, and verify all three.
11. Load a version-9 save and verify all three are migrated as unlocked.
12. Attempt scripted/direct/stale placement of a locked item and verify:

    * no currency spent;
    * no tile/object created;
    * no FX or navigation invalidation.
13. Verify existing placed objects continue operating.
14. Verify mouse, keyboard, and gamepad dialog navigation.
15. Verify no new warnings or errors during normal day/night transitions.

## Final report

At completion, report:

1. Changed files.
2. The owner of blueprint definitions and unlock state.
3. The exact save key and migration behavior.
4. How build availability is gated.
5. How stale/direct placement bypasses are prevented.
6. Any compatibility wrappers retained.
7. Any pre-existing messy coupling intentionally left untouched.
8. Manual tests for the user.
9. Confirm that Godot/tests/builds were not run.
