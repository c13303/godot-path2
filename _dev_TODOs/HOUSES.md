Implement **House support — pass 2: real inventory-backed buildable, editor acquisition paths, complete preview, unbuild, durability, and save/load**.

Read and follow `AGENTS.md` before editing.

Do not run Godot, tests, compilation, export, or build commands. The user performs runtime testing.

# Objective

Convert the house system created in pass 1 into a complete player buildable.

The house must:

* Be an owned-stock item, consumed on placement exactly like wall stock.
* Appear in the hammer build menu.
* Be grantable as level-start inventory.
* Be grantable as a survived-night reward.
* Be optionally purchasable from the seed merchant.
* Be configurable through the Rose Level Editor for all three acquisition paths.
* Show a six-cell placement preview.
* Show the complete house sprite in the correct position during preview.
* Build through the existing runtime house and navigation-construction pipeline.
* Be unbuilt as one complete logical object.
* Return one house item to inventory when normally unbuilt.
* Be one destructible player-built structure with one health pool.
* Be destroyed as a whole without refund when destroyed by enemies.
* Save and reload correctly.

Remove the temporary `K` runtime-house test from pass 1 after the real buildable path is operational.

Do not implement additional house variants yet.

---

# Existing pass-1 system

Inspect the actual current code before editing.

Pass 1 should already provide a focused house owner, expected to be something similar to:

```text
scripts/map/house_manager.gd
```

It should already own:

* House geometry.
* House registry.
* Authored-house discovery.
* Entrance cells.
* Five navigation-blocking cells.
* Sprite snapping.
* Bottom-edge z-index.
* Runtime house creation.
* Batched wall stamping.
* Runtime construction progress.
* Authored `house_seedmerchant` registration.
* `seedmerchent_spot` snapping.
* A temporary `K` test using `test_flyhouse`.

Reuse and extend that owner.

Do not create a second house registry, duplicate geometry methods, or bypass the pass-1 runtime construction method.

If pass 1 used slightly different filenames or public method names, adapt to the actual implementation while preserving its ownership.

Before changing anything, identify:

1. The actual `HouseManager` API.
2. How authored and runtime house records differ.
3. How the six-cell presence is currently indexed.
4. How the five blocking wall cells are stamped and removed.
5. How the construction overlay tracks a runtime house.
6. How the temporary `K` controller is wired.
7. Which calls are public and which still rely on private manager access.

Do not perform broad cleanup unrelated to this feature.

---

# Fixed house geometry

The entrance cell remains the logical anchor.

Map presence:

```text
WWW
WEW
```

Relative to entrance `(0, 0)`:

```text
(-1,-1)  (0,-1)  (1,-1)
(-1, 0)  (0, 0)  (1, 0)
```

The complete six-cell presence is:

```text
(-1,-1)
( 0,-1)
( 1,-1)
(-1, 0)
( 0, 0)  entrance
( 1, 0)
```

The five navigation blockers are:

```text
(-1,-1)
( 0,-1)
( 1,-1)
(-1, 0)
( 1, 0)
```

The entrance `(0, 0)` is:

* Part of the house’s reserved placement presence.
* Included in preview coverage.
* Not a wall.
* Not a player collision blocker.
* Not a navigation blocker.
* Not available for another placeable while the house exists.

Sprite footprint:

```text
SSS
WWW
WEW
```

The top visual row remains visual only. It is not included in placement occupancy.

All geometry must remain centralized in `HouseManager`.

Do not reproduce these offsets separately in preview, placement, removal, durability, and save code.

Expose focused methods such as:

```text
get_presence_cells(entrance_cell)
get_blocking_cells(entrance_cell)
get_house_at_presence_cell(cell)
get_house_entrance(house_id)
get_house_sprite(house_id)
```

Use the existing equivalent methods when already present.

---

# Catalog item

Add one item with the stable ID:

```text
house
```

Display name:

```text
House
```

Visual asset:

```text
res://assets/sprites/house/house1.png
```

Use the wall icon for menus for now:

```text
frame = 3
```

The preview and world object must use the actual house sprite, not the wall icon.

The item should conceptually contain:

```text
"id": "house"
"name": "House"
"type": "placeable"
"category": "house"
"frame": 3
"inventory_backed": true
"fixed_stock": false
"drag_buildable": false
"max_health": 100
"max_stack": 999
"currency": &"money"
"price": 0
```

Add whatever focused house visual/catalog field is appropriate, for example:

```text
"house_texture": HOUSE_TEXTURE
```

or:

```text
"special_placement_kind": &"house"
```

Do not identify house behavior solely from `item_id == "house"` in many unrelated files.

A small catalog query such as this is appropriate:

```text
ItemCatalog.is_house_placeable(item_id)
```

or a placeable-definition field queried by the relevant owners.

## Inventory semantics

The house uses wall-like owned-stock semantics:

* The player owns a quantity.
* Placing consumes one.
* Normal unbuild returns one.
* Enemy destruction returns nothing.
* No currency is charged during placement.

However, do **not** set `fixed_stock = true`.

The current wall is fixed stock because it is never sold by the merchant. The house must be optionally purchasable, so it must remain:

```text
inventory_backed = true
fixed_stock = false
```

This gives it wall-like placement semantics while preserving merchant compatibility.

## Merchant balance

Do not invent a default price.

Use:

```text
currency = &"money"
price = 0
```

Do not include the house in default level merchant stock.

A level author who enables it as a merchant item must author a positive merchant price in the Rose Level Editor.

A missing or zero merchant price must not grant a free house. Preserve the existing merchant purchase rejection for non-positive prices.

---

# Hammer build menu

Add the house to the hammer category.

Update the authoritative catalog query, expected to be:

```text
ItemCatalog.get_hammer_shop_item_ids()
```

Place it after wall unless the current menu ordering has a clearer established convention.

Expected approximate ordering:

```text
rose_shop_counter
wall
house
fence
```

The house must:

* Use the wall icon in the menu.
* Show its owned quantity through the existing inventory-backed quantity display.
* Be selectable only when allowed by the level’s toolbuild availability configuration.
* Be unaffordable/unplaceable when owned quantity is zero.
* Consume exactly one item per house.
* Never support drag or bulk placement.

Do not implement a special house inventory counter outside the normal inventory system.

Do not add another HUD currency.

---

# Rose Level Editor integration

Find the actual Rose Level Editor implementation in the repository.

Do not guess its file locations. Search for:

* `starting_items`
* `starting_item_toolbuild_hidden`
* `merchant_available_items`
* `merchant_prices`
* `merchant_days`
* `NightReward`
* `special_rewards`
* `get_giveable_starting_item_ids`
* `get_merchant_shop_item_ids`
* Item dropdown or item picker population
* The Items tab and Merchant tab

The house must be available in all relevant editor surfaces.

## 1. Starting inventory

The editor must allow the level author to grant:

```text
house -> quantity
```

through `LevelSpawnConfig.starting_items`.

The generated level data must use the existing generic format:

```text
starting_items = {
    &"house": quantity
}
```

Do not create a house-specific starting field.

Because `house` is a normal non-weapon placeable, it should be included through the existing catalog source such as:

```text
ItemCatalog.get_giveable_starting_item_ids()
```

If the editor has a separate hardcoded list, replace or update the smallest authoritative list rather than adding scattered special cases.

## 2. Night reward

The editor must allow `house` as a `NightReward.item_id`.

The existing reward system already supports inventory items:

```text
item_id = "house"
amount = quantity
```

Claiming the reward must:

* Add the quantity to the normal inventory.
* Use the wall icon for the reward/menu animation.
* Respect inventory capacity.
* Leave an unclaimable reward available when inventory capacity is insufficient.
* Use the existing generic reward path.

Do not create a house-specific reward type.

## 3. Seed merchant

The editor must allow `house` in:

```text
merchant_available_items
merchant_prices
merchant_days
merchant_growth_price_factors
```

where those controls already exist.

When enabled for a level:

* The seed merchant displays the house.
* It uses the wall icon.
* Purchasing spends money.
* Purchasing adds one house to inventory.
* Placement later consumes the stocked item.
* The player does not pay again on placement.

The house must use the existing inventory-backed placeable purchase path:

```text
try_purchase_placeable_merchant_item(...)
```

Do not create a house-specific purchase method.

The editor should reject, visibly warn about, or clearly flag an enabled merchant house with a price of zero, following whatever validation pattern the editor currently uses. Do not invent a price.

## Editor source of truth

Prefer catalog-driven editor population.

The intended result is that future house item definitions using the same immediate house-placeable contract can appear without editing three separate hardcoded editor lists.

Do not create a speculative generic editor framework. Use the current catalog/query conventions.

If the Rose Level Editor is genuinely outside the supplied repository, do not fake integration. Report the missing editor location precisely in the final report. Continue implementing all runtime catalog/config support that the editor will consume.

---

# House placement routing

`BuildPlacementService` currently assumes most placeables are one tile.

Do not force the house through that one-cell commit path.

Add a focused branch for house placeables before generic tile placement.

The routing should conceptually be:

1. Determine hovered entrance cell.
2. Ask `HouseManager` for complete placement validation.
3. If invalid, show invalid preview/notification.
4. Verify the player owns one house.
5. Consume exactly one inventory item.
6. Ask `HouseManager` to commit one runtime player-built house.
7. If an unexpected commit failure occurs after inventory consumption, restore the consumed item immediately.
8. Clear selection when the player has no remaining stock.

`BuildPlacementService` remains the owner of:

* Generic placement request coordination.
* Inventory/payment coordination.
* Notifications.
* Build FX call.

`HouseManager` remains the owner of:

* House-specific validation.
* Six-cell occupancy.
* Sprite creation.
* Wall stamping.
* Registry mutation.
* Construction state.
* Batched navigation invalidation.

Do not place the five blocking cells through five calls to the ordinary wall placement method.

Do not call `try_purchase_build("wall", 5)`.

Do not consume six house items.

---

# Placement validation

The hovered build cell is the entrance cell.

Validate the complete six-cell presence before consuming inventory or changing the scene.

All six cells must be evaluated atomically.

A house is invalid when any presence cell:

* Is outside the valid floor map.
* Does not satisfy the same basic buildable-floor requirements as a wall.
* Already belongs to another house.
* Contains an existing wall.
* Contains a plant.
* Contains a fence.
* Contains a traversable building.
* Contains a blocking building.
* Contains a reservoir or other registered runtime building.
* Contains an incompatible placeable.
* Is occupied by a blocking entity according to the existing placement occupancy checks.

The entrance must also be empty during placement even though it remains walkable after construction.

Do not clear or overwrite an existing tile to make the house fit.

Unlike the generic one-cell placement path, house placement must not call `clear_other_build_layer()` over the footprint.

Any conflict rejects the complete placement with no partial mutation.

The top visual-only row is not validated as occupied map presence.

## Existing authored houses

Authored houses must also reserve their complete six-cell presence in `HouseManager`.

This prevents the player from placing another object:

* On an authored house wall cell.
* In the authored house entrance.
* Inside its logical presence.

Authored houses remain non-player-built and must not become refundable or destructible merely because they exist in the registry.

---

# Placement preview

The preview must represent the actual house, not one wall tile.

Extend the existing preview owner, expected to be:

```text
BuildPreviewController
```

Do not move general preview ownership into `HouseManager`.

`BuildPreviewController` should ask `HouseManager` for geometry and sprite positioning.

## Required preview contents

For the hovered entrance cell, show:

1. Coverage over all six occupied presence cells.
2. The complete `house1.png` sprite.
3. The sprite bottom-aligned exactly as it will be after placement.
4. The entrance included in the six-cell coverage.
5. No coverage over the sprite-only top row.

The six-cell coverage can reuse the current preview tile/selection visual system. It must clearly cover:

```text
WWW
WEW
```

including `E`.

The house sprite must:

* Be horizontally centred on the entrance.
* Have its bottom edge aligned with the entrance cell’s bottom edge.
* Use the same shared positioning method as the final house.
* Be semi-transparent as appropriate for a preview.
* Be cleaned up whenever the preview is cleared or the selected item changes.

Do not independently recalculate sprite alignment in `BuildPreviewController`.

## Valid/invalid state

Validation applies to the complete footprint.

When all six cells are valid:

* Show the normal valid preview color.
* Show the full sprite using the normal preview modulation.

When any presence cell is invalid:

* Tint the complete six-cell footprint invalid.
* Tint the complete house sprite invalid.
* Do not show a mixture of five green cells and one red cell.

The player must understand that the house placement is one atomic object.

## Mouse and gamepad

The same preview must work for:

* Mouse hover placement.
* Gamepad build cursor placement.

The gamepad anchor cell is also the entrance.

Do not set `pad_skip_preview = true`.

Do not enable drag placement.

Rotation is out of scope.

---

# Placement commit

After successful validation and inventory consumption, call the authoritative runtime-house creation method from pass 1.

The resulting player-built house must:

* Create one logical house registry record.
* Reserve all six presence cells.
* Stamp exactly five invisible wall cells.
* Leave the entrance TileMap cell empty.
* Create one visible house sprite.
* Apply bottom-edge z-index.
* Immediately synchronize player collision for all five blocking cells.
* Trigger exactly one hard-topology invalidation.
* Use exactly one construction-progress visual.
* Become one player-built durability target.
* Play at most one build FX, centred on the entrance or logical house centre.
* Consume exactly one `house` inventory item.

Do not trigger five flow-field invalidations.

Do not create five construction bars.

Do not register five independent wall buildings.

Use the existing pass-1 construction behavior:

* House sprite is translucent while navigation work is pending.
* One progress bar represents the whole house.
* It completes only after the existing topology and flow work is complete.

---

# House registry requirements

Each runtime house record must contain enough authoritative state for this pass.

At minimum:

* Stable runtime house ID.
* Catalog item ID.
* Entrance cell.
* Six presence cells, or the information required to derive them.
* Five blocking cells, or the information required to derive them.
* Sprite node.
* Authored/runtime origin.
* Player-built flag.
* Removable flag.
* Destructible flag.
* Construction state when currently relevant.

Do not store duplicate geometry arrays when they can be derived safely from the entrance through one centralized method.

Maintain a lookup from every one of the six presence cells to the owning house.

This lookup is required for:

* Placement conflict detection.
* Hover/unbuild detection.
* Rectangle unbuild deduplication.
* Entrance removal.
* Durability validity.
* Save validation.

One house must always be one logical object.

---

# Unbuild support

The complete player-built house can be unbuilt.

The unbuild tool must recognize the house when hovering any of its six presence cells:

```text
WWW
WEW
```

This includes the entrance, even though the entrance has no wall tile.

Consult `HouseManager` before or alongside ordinary TileMap removal lookup.

Do not rely on the invisible wall atlas to identify a house.

## Authored houses

Authored houses such as:

```text
house_seedmerchant
```

must not be removable through the player unbuild tool.

Only player-built runtime houses are removable and refundable.

## Removal selection

When the cursor touches any house presence cell:

* Resolve the complete logical house.
* Normalize the removal record to its house ID and entrance.
* Show one unbuild operation, not one operation per wall cell.

For rectangle removal:

* If several selected cells belong to the same house, include that house only once.
* Do not queue five removals for its five walls.
* Do not refund multiple houses because multiple footprint cells were selected.

Use a stable logical removal key such as:

```text
house:<runtime_house_id>
```

or the established equivalent.

## Removal progress

Reuse the normal unbuild hold/progress interaction.

A single progress indicator is sufficient.

Anchor it consistently to:

* The entrance cell, or
* The house sprite.

Do not show six independent removal bars.

## Atomic teardown

The authoritative normal-unbuild method must remove the complete house atomically:

1. Validate that it is a live, player-built, removable house.
2. Cancel any active house construction visual safely.
3. Remove its single durability record.
4. Clear all six presence-cell ownership entries.
5. Erase its five owned invisible wall cells.
6. Call `wallz.update_internals()` once.
7. Refresh player collision for all five blocking cells.
8. Remove/free the visible sprite.
9. Remove the logical registry record.
10. Trigger one hard-topology invalidation.
11. Return exactly one `house` item through the existing refund system.
12. Play at most one unbuild/refund animation.

Because the house is inventory-backed, normal unbuild must use the existing inventory refund semantics:

```text
refund_build("house", world_position, 1)
```

This should return one house to inventory rather than returning money.

Do not refund five wall items.

Do not return money.

## Ownership safety

Only erase a blocker cell when it is still owned by that house.

If a blocker cell unexpectedly contains foreign authored data or no longer matches the house-owned invisible blocker, do not erase arbitrary foreign content. Report a concise warning and continue the safest possible cleanup.

---

# Destructible integration

A player-built house is a destructible building like the other player-built structures.

Use:

```text
max_health = 100
```

A house must be:

* One target.
* One health pool.
* One health bar.
* One destruction event.

Do not register its five wall cells as five durability targets.

Do not register the entrance as a separate target.

Authored houses remain outside player-built durability unless explicitly marked player-built in the future.

## Durability identity

Use the entrance as the stable logical cell for durability serialization and target identity.

Use a logical durability layer/name such as:

```text
houses
```

Do not pretend the house is a normal `wallz` item. The invisible wall cells are implementation details and their atlas does not identify the logical house.

Extend `PlayerPlaceableDurabilityService` cleanly so it can validate and destroy this logical multi-cell placeable.

The service should be able to:

* Register a player-built house.
* Validate that the house still exists through `HouseManager`.
* Resolve its item ID.
* Resolve its attack target position.
* Resolve its health-bar position.
* Destroy it through a no-refund `HouseManager` method.
* Serialize and restore its current health.

Avoid putting house geometry into the durability service.

## Attack target position

Tantrum clients need a reachable target.

For the house:

* Use the entrance cell centre as the attack/navigation target position.
* The entrance remains walkable, so agents can approach it.
* Destruction still affects the entire house.

Do not target the centre of a blocking wall cell if that makes the target unreachable.

The existing assault planner should continue consuming the generic durability target API. Do not add house-specific behavior to the planner.

## Health-bar position

The health bar must appear above the visible house sprite, not over the entrance ground cell.

Add or extend a generic durability query such as:

```text
health_bar_world_position(target_key)
```

For normal tile buildings, preserve the current cell-centre behavior.

For a house, ask `HouseManager` or the house sprite for a suitable point above the sprite bounds.

Update `BuildingHealthOverlay` to consume this query rather than assuming every bar belongs at:

```text
building_manager.cell_center(cell)
```

The health bar remains hidden at full health and appears after the first hit.

## Hostile destruction

When health reaches zero:

* Remove the one durability record.
* Call the authoritative complete-house teardown without refund.
* Remove the sprite.
* Clear six-cell occupancy.
* Remove the five blockers.
* Update collision.
* Trigger one topology invalidation.
* Do not grant inventory.
* Do not grant money.
* Do not leave five wall durability records.
* Do not leave invisible blockers behind.

Preserve the current no-refund destruction path for all existing placeables.

Do not add debris unless the catalog explicitly requests it. The house should not leave debris in this pass.

---

# Save/load

A player-built house must survive normal save/load.

The five invisible wall cells are already serialized through `wallz`, but that is not enough because the sprite and logical house registry are not TileMap cells.

Add explicit runtime-house serialization.

## House save records

Save only player-built runtime houses.

Do not serialize authored houses; they are recreated by normal level loading.

A saved house record should contain at least:

```text
item_id
entrance_x
entrance_y
```

Include a stable house-kind or visual identifier only when it is needed to reconstruct the catalog-defined visual.

Do not save raw node paths, instance IDs, textures as strings duplicated from the catalog, or all six derived cells unnecessarily.

Do not serialize temporary construction progress. A loaded house may be treated as fully constructed because startup navigation is reconstructed from the restored map.

## Progression save integration

Add a save section such as:

```text
runtime_houses
```

or:

```text
player_built_houses
```

Use thin façade methods through `BuildingManager`, for example:

```text
serialize_player_built_houses()
restore_player_built_houses(records)
```

The real logic stays in `HouseManager`.

Bump the save version if required by the project’s current compatibility convention.

If bumping from version 4 to version 5:

* Accept versions 1–5.
* Treat missing house data in versions 1–4 as an empty list.
* Validate house entries in version 5.
* Preserve all existing save compatibility behavior.
* Do not invalidate old saves merely because they have no house section.

## Required load order

On load:

1. The level and authored houses are created normally.
2. Saved TileMap layers are restored, including the five house blocker cells.
3. Player-built house records are restored into `HouseManager`.
4. Their visible sprites and six-cell registry ownership are recreated.
5. The restored blocker cells are validated.
6. Building/runtime layer indexes are restored as currently required.
7. House durability records are restored only after the house registry exists.
8. Navigation startup/rebuild sees the restored wall footprint.
9. No construction progress bar appears for loaded houses.

Do not recreate the five blocker cells through five runtime placement operations during load.

Do not trigger one runtime topology rebuild per restored house.

The load path should either:

* Reuse the wall cells already restored from the save, or
* Repair a missing expected blocker in one controlled batch when safe.

If the save contains an impossible conflict, report a warning and skip or repair it safely. Do not erase arbitrary scene content.

## Durability save/load

The generic durability section must preserve:

* House target identity.
* Current health.
* Maximum health.

When durability restoration validates a record with logical layer `houses`, it must ask `HouseManager`, not a TileMap layer.

Loaded damaged houses must show the health bar correctly after restoration.

## Inventory

No house-specific inventory save work should be needed.

The existing inventory save/load must preserve unplaced owned houses automatically through the catalog item ID.

Verify this path rather than duplicating it.

---

# Temporary pass-1 test removal

After the real buildable placement works, remove all temporary `K` test code introduced in pass 1.

Expected candidates include:

```text
scripts/debug/house_runtime_test_controller.gd
```

and any temporary setup or scene wiring associated with it.

Remove:

* `K` input handling.
* `test_flyhouse` runtime placement calls.
* Temporary comments and constants.
* Temporary controller instantiation.
* Temporary scene node wiring.

Do not remove or reposition the authored `test_flyhouse` marker unless the user explicitly requests scene cleanup later. It may remain unused in the level scene.

Do not remove reusable runtime-house APIs merely because the temporary caller is removed.

---

# BuildingManager and BuildSystem constraints

`BuildingManager` remains a façade/coordinator.

It may expose thin methods such as:

```text
get_house_manager()
serialize_player_built_houses()
restore_player_built_houses(records)
register_player_built_house_durability(...)
remove_player_built_house_no_refund(...)
```

Use the smallest necessary API.

Do not add:

* House geometry.
* Footprint loops.
* Sprite positioning.
* Save record transformation.
* Placement validation algorithms.
* Unbuild algorithms.

to `BuildingManager`.

`BuildSystem` may route placement/removal calls but must not become the house owner.

Avoid new calls such as:

```text
_manager._house_manager._private_method()
```

Use typed getters and focused public methods.

Report any private coupling retained.

---

# Architecture constraints

Respect `AGENTS.md`.

In particular:

* Dedicated ownership.
* No broad manager growth.
* No blind abstractions.
* No speculative multi-building framework.
* No giant methods.
* No duplicate state.
* No hidden five-cell side effects.
* Explicit typed GDScript.
* No unnecessary `:=`.
* No Godot/test/build execution.

The correct split should remain approximately:

## `HouseManager`

Owns:

* House geometry.
* Six-cell occupancy.
* Five-cell wall footprint.
* Authored/runtime registry.
* Placement validation.
* Runtime creation.
* Normal removal.
* Hostile destruction teardown.
* Sprite positioning.
* House save records.

## `BuildPreviewController`

Owns:

* Six-cell preview rendering.
* Full preview sprite lifecycle.
* Valid/invalid preview tint.

It asks `HouseManager` for geometry and positioning.

## `BuildPlacementService`

Owns:

* Routing the selected house item.
* Inventory availability.
* Consuming one unit.
* Calling `HouseManager`.
* Rollback if commit unexpectedly fails.

## `BuildRemovalService`

Owns:

* Resolving unbuild requests.
* Delegating complete house removal.
* Calling the generic refund path.
* Deduplicating rectangle-removal records.

## `PlayerPlaceableDurabilityService`

Owns:

* One durability target per player-built house.
* Current/max health.
* Validation through the house owner.
* No-refund destruction dispatch.
* Durability serialization.

## `BuildingHealthOverlay`

Owns:

* Drawing the house health bar at the position supplied by durability.

## `Progression`

Owns:

* Writing and restoring the runtime-house save section.
* Save-version validation and compatibility.

## Rose Level Editor

Owns:

* Authoring starting quantities.
* Reward item selection.
* Merchant availability, price, day, and growth factor.

Update `scripts/map/ARCHITECTURE.md` with the final ownership.

---

# Explicitly forbidden implementations

Do not:

* Represent one house as five walls plus one fake entrance building.
* Consume or refund five wall items.
* Register five durability targets.
* Use one health pool per blocker cell.
* Place a hidden tile on the entrance.
* Make the entrance non-walkable.
* Allow another buildable to occupy the entrance.
* Use only a one-cell preview.
* Preview only the wall icon.
* Place the sprite at the entrance cell centre without bottom alignment.
* Duplicate house geometry offsets in multiple files.
* Route house removal through five independent `remove_tile()` calls with five invalidations.
* Recompute flow fields five times.
* Add house-specific merchant purchase logic.
* Add house-specific reward logic.
* Add a house-specific inventory.
* Make authored `house_seedmerchant` player-removable.
* Make authored houses tantrum targets.
* Keep the temporary `K` path after integration.
* Modify the C++ extension.
* Perform broad unrelated cleanup.
* Add rotation or additional footprint sizes.
* Create additional house art.

---

# Likely files

Inspect the current implementation before deciding the exact list.

Likely modified files:

```text
scripts/items/item_catalog.gd
scripts/map/house_manager.gd
scripts/map/build_placement_service.gd
scripts/map/build_preview_controller.gd
scripts/map/build_removal_service.gd
scripts/map/buildsystem.gd
scripts/map/building_manager.gd
scripts/map/player_placeable_durability_service.gd
scripts/map/building_health_overlay.gd
scripts/gameState/progression.gd
scripts/map/ARCHITECTURE.md
```

Possible Rose Level Editor files, depending on actual repository layout:

```text
Items tab/controller
Merchant tab/controller
Night reward editor
Level config serializer
Editor validation
```

Likely removed:

```text
scripts/debug/house_runtime_test_controller.gd
```

and any temporary pass-1 scene wiring.

Do not modify unrelated gameplay files simply because they can reach `BuildingManager`.

---

# Acceptance criteria

## Catalog and inventory

* `house` exists as one catalog item.
* Display name is `House`.
* Menu icon is the wall icon.
* World and preview use `house1.png`.
* It appears in the hammer build menu.
* It is inventory-backed.
* Placement consumes one.
* Normal unbuild restores one.
* Enemy destruction restores nothing.
* It is not bulk/drag buildable.
* Zero stock prevents placement.
* No direct placement currency is charged.

## Rose Level Editor

* House appears in the starting-item selector.
* A starting quantity is saved into `starting_items`.
* House appears in reward item selection.
* A house reward saves through `NightReward.item_id`.
* House appears as an optional seed-merchant inventory-backed item.
* Merchant price/day/growth configuration can be authored.
* House is not enabled in merchant defaults automatically.
* A missing positive merchant price cannot create a free purchase.
* Editor data uses existing generic runtime resource fields.

## Starting inventory

With a level configured for:

```text
house: 2
```

the fresh player starts with two houses.

The hammer menu displays quantity two.

Placing one reduces it to one.

## Reward

A night reward configured with:

```text
item_id = "house"
amount = 1
```

adds one house to inventory when claimed.

The reward remains claimable if inventory capacity prevents the grant.

## Merchant

When a level enables house at a positive money price:

* It appears at the seed merchant.
* Purchase spends the configured money.
* One unit enters inventory.
* Placement consumes the unit later.
* Placement does not charge money again.

## Preview

* Hovered cell is the entrance.
* All six cells are visibly covered.
* The entrance is included.
* The top sprite-only row is not marked as occupied.
* Full `house1.png` is visible.
* Sprite bottom aligns with entrance bottom.
* Preview matches final placement exactly.
* Any invalid footprint cell makes the whole preview invalid.
* Mouse and gamepad use the same result.
* Preview is cleaned up correctly.

## Placement

* One inventory item is consumed.
* One logical house is registered.
* All six presence cells are reserved.
* Exactly five wall cells are stamped.
* Entrance remains walkable.
* One sprite is created.
* One construction bar appears.
* One topology invalidation occurs.
* Navigation eventually routes around the five blockers.
* No partial house appears after invalid placement.
* No existing tiles are silently overwritten.

## Unbuild

* Hovering any of the six presence cells resolves the house.
* Entrance hover also resolves it.
* One unbuild operation removes the full object.
* Rectangle removal deduplicates one house.
* Sprite disappears.
* All six occupancy entries disappear.
* Five wall cells disappear.
* Entrance remains empty.
* Collision updates for all five blockers.
* One topology invalidation occurs.
* One house item returns to inventory.
* No wall items or money are returned.
* Authored `house_seedmerchant` cannot be unbuilt.

## Durability

* One player-built house creates one target.
* Maximum health is 100.
* First damage shows one health bar.
* Health bar appears above the house sprite.
* Tantrum clients approach the entrance.
* Damage affects one shared health pool.
* Destruction removes the full house.
* Five blockers are removed.
* No refund occurs.
* No invisible blockers remain.
* Authored houses are not registered as player-built targets.

## Save/load

* Unplaced house stock survives save/load through inventory.
* Player-built houses survive save/load.
* Their sprites return.
* Their six-cell registry ownership returns.
* Their five blockers remain.
* Their entrance remains walkable.
* Their current health returns.
* Damaged-house health bars use the correct position.
* Authored houses are not duplicated.
* Loaded houses do not show construction progress.
* Old saves without house data still load.
* Loading several houses does not trigger one runtime rebuild per house.

## Regression safety

Verify no regressions in:

* Wall placement.
* Wall drag placement.
* Wall inventory stock.
* Wall unbuild/refund.
* Existing construction bars.
* Fence placement/removal.
* Turret placement/removal.
* Kraken placement/removal.
* Pasteque inventory purchase and refund.
* Ordinary one-cell building durability.
* Tantrum target selection.
* Starting items.
* Night item rewards.
* Merchant inventory-backed purchases.
* Save/load of existing TileMap layers.
* `house_seedmerchant`.
* `seedmerchent_spot`.
* Startup flow-field precomputation.

---

# Manual test plan to report

Do not run these tests. Include them in the final implementation report.

1. Configure one starting house in the Rose Level Editor.
2. Start a fresh run and verify hammer stock.
3. Preview the house over valid terrain.
4. Verify all six cells are covered.
5. Verify the full sprite alignment.
6. Move one footprint cell over an obstacle and verify the whole preview turns invalid.
7. Place the house.
8. Verify stock decreases by one.
9. Verify only five cells block movement.
10. Walk through the entrance.
11. Walk above and below the house to verify z-index.
12. Wait for construction completion.
13. Unbuild by hovering a wall cell.
14. Rebuild and unbuild by hovering the entrance.
15. Verify one inventory item returns each time.
16. Configure a house night reward and claim it.
17. Configure a positive-price merchant house and purchase it.
18. Verify purchase charges money but placement does not.
19. Damage the house and verify one health bar.
20. Destroy it and verify no refund.
21. Save with a built undamaged house and reload.
22. Save with a damaged house and reload.
23. Load an older save without runtime-house data.
24. Verify authored `house_seedmerchant` remains present and non-removable.
25. Verify the `K` test no longer exists.

---

# Final report

At completion, report:

1. Every created, modified, and removed file.
2. The actual pass-1 APIs reused.
3. The final house item definition.
4. Why `inventory_backed` is true and `fixed_stock` is false.
5. How the Rose Level Editor exposes starting, reward, and merchant acquisition.
6. How the six-cell preview is rendered.
7. How full-sprite preview alignment shares the production positioning code.
8. How complete-footprint validation works.
9. How inventory consumption is rolled back after an unexpected commit failure.
10. How any footprint cell resolves to one house during unbuild.
11. How rectangle removal deduplicates houses.
12. How normal unbuild returns one inventory item.
13. How hostile destruction avoids refund.
14. How one durability target represents the complete house.
15. How attack and health-bar positions differ.
16. How runtime houses are saved and restored.
17. Save-version compatibility changes.
18. The temporary `K` code removed.
19. Any private coupling retained.
20. Any architectural concern discovered.
21. Manual test steps without claiming they were run.
