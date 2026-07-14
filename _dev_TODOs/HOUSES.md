Implement only the missing **dedicated house-build quickbar menu**.

Read and follow `AGENTS.md`.

Do not run Godot, tests, compilation, export, or build commands.

# Context

The complete house feature has already been implemented:

* House catalog item.
* Inventory ownership.
* Starting inventory.
* Rewards.
* Seed merchant purchase.
* Placement preview.
* Runtime construction.
* Unbuild and refund.
* Durability.
* Save/load.

Do not recreate, refactor, or modify those systems unless a minimal selection-routing adjustment is strictly required.

The current problem is only:

> Owned houses do not have a dedicated quickbar menu from which the player can select them for building.

# Required result

Add a new quickbar tool immediately after the hammer:

```text
hammer
buildhouse
<existing following tools>
```

Internal tool ID:

```text
buildhouse
```

Use the wall icon temporarily for this quickbar button.

Selecting `buildhouse` must open a vertical submenu, exactly like the existing quickbar tools that open item-selection submenus.

The submenu contains the player’s house buildable types.

For now, it contains only:

```text
house
```

Use the wall icon for the `house` submenu entry as well.

Selecting `house` must activate the already implemented house preview and placement flow.

# Scope

Implement only:

* The `buildhouse` quickbar entry.
* Its position immediately after hammer.
* Its vertical submenu.
* Catalog-driven discovery of house item types.
* Display of owned house quantities.
* Selection routing into the existing build flow.
* Normal mouse, keyboard, and gamepad menu behavior.
* Removal of `house` from the hammer submenu if it is still listed there.

Do not touch:

* House geometry.
* Placement validation.
* Preview rendering.
* Construction.
* Navigation invalidation.
* Inventory consumption.
* Unbuild.
* Refund.
* Durability.
* Save/load.
* Merchant logic.
* Rewards.
* Starting inventory.
* Rose Level Editor integration.

Those systems already exist.

# Catalog integration

Inspect the implemented house item definition and reuse its existing category or placement-kind field.

Do not introduce another separate way of identifying houses.

Add one authoritative catalog query following current naming conventions, for example:

```gdscript
static func get_house_build_item_ids() -> Array[StringName]:
```

It must return all catalog items classified as house buildables, in stable order.

For now, the result contains:

```text
house
```

Do not hardcode `house` inside the submenu controller.

Future house types must appear automatically when they are added to the catalog with the same house classification.

If `house` was previously added to:

```gdscript
ItemCatalog.get_hammer_shop_item_ids()
```

remove it from that list.

The house must appear only in the `buildhouse` submenu, not under hammer.

# Quickbar integration

Use the existing quickbar definition and ordering system.

Do not manually position a standalone button if the quickbar is generated from an ordered tool list.

Add:

```text
buildhouse
```

immediately after:

```text
hammer
```

Use the same atlas frame or icon resource used by wall.

Do not copy or recreate the wall icon asset.

Preserve:

* Existing tool ordering after the insertion.
* Mouse selection.
* Keyboard quickbar navigation.
* Gamepad quickbar navigation.
* Tool highlighting.
* Cancel behavior.
* Tooltip conventions.
* Existing shortcut/index behavior.

If quickbar tools are validated through an allowed-tool list or enum, add `buildhouse` to the same authoritative definitions.

Do not make `buildhouse` an inventory item.

# Vertical house submenu

Reuse the existing generic vertical item submenu used by hammer or the closest equivalent tool.

Do not create a parallel house-only menu system when the existing submenu can accept a different item source.

The submenu must:

* Open when `buildhouse` is selected.
* Be vertical.
* Build its entries from the house catalog query.
* Show the wall icon for `house`.
* Show the current owned quantity using the existing inventory quantity display.
* Support mouse selection.
* Support keyboard and gamepad navigation.
* Highlight the selected item consistently.
* Close or switch consistently with other quickbar submenus.
* Refresh when inventory quantity changes.

Follow the existing menu convention for zero-owned items:

* If other inventory-backed menu entries remain visible at zero, show `house` disabled at zero.
* If they are hidden at zero, hide it.
* Do not introduce a different house-only convention.

# Selection routing

Selecting the submenu entry must select the existing inventory item:

```text
house
```

and activate the existing house placement mode.

Use the same selected-placeable API used by the existing build menus.

Do not:

* Call `HouseManager` directly from the UI.
* Create a new selected-house state.
* Consume inventory during selection.
* Reimplement the preview.
* Reimplement placement.

Inventory must still be consumed only by the already implemented successful house placement path.

Expected ownership:

* Quickbar owns selected tool: `buildhouse`.
* Submenu owns item navigation.
* Existing build-mode state owns selected item: `house`.
* Existing preview and placement services handle the rest.

# Menu lifecycle

Match existing behavior exactly.

Verify the implementation handles:

* Opening `buildhouse` closes another submenu.
* Switching to hammer closes the house submenu.
* Switching to a weapon, unbuild tool, or another tool clears house selection and preview as appropriate.
* Cancel behaves like other vertical submenus.
* Selecting `buildhouse` again follows the current toggle convention.
* Placing the final owned house updates its displayed quantity.
* Refunding, buying, receiving, or loading houses updates the submenu quantity.
* A stale `house` selection is not left active after switching tools.

# Architecture constraints

Respect existing ownership.

Do not put house-menu state into:

* `HouseManager`
* `BuildingManager`
* `BuildPlacementService`

unless a tiny existing public selection wrapper is required.

Prefer configuring the existing generic submenu with a different catalog item source.

Do not perform a broad quickbar or menu refactor.

A small extraction is acceptable only if the current hammer submenu is needlessly hardcoded and the extraction clearly lets both hammer and buildhouse use the same existing behavior.

Use explicit GDScript types according to `AGENTS.md`.

# Acceptance criteria

* A new quickbar icon appears immediately after hammer.
* Its tool ID is `buildhouse`.
* It uses the wall icon.
* Selecting it opens a vertical submenu.
* The submenu currently displays the implemented `house` item.
* The house entry uses the wall icon.
* Its owned quantity is displayed and refreshed.
* Selecting it activates the existing complete house preview.
* The existing house placement works without new placement code.
* Inventory is not consumed when merely selecting it.
* `house` no longer appears in the hammer submenu.
* Mouse navigation works.
* Keyboard navigation works.
* Gamepad navigation works.
* Switching tools closes the submenu and clears selection correctly.
* Existing hammer and other quickbar tools still work.
* Future catalog-defined house types can appear in the same submenu without new quickbar buttons.

# Final report

Report only:

1. Files changed.
2. Where `buildhouse` was added to quickbar ordering.
3. Where house submenu membership is sourced.
4. How the existing generic submenu was reused.
5. How selection reaches the already implemented house build flow.
6. How inventory quantities refresh.
7. Confirmation that no house gameplay systems were reimplemented.
8. Manual UI tests to perform, without claiming they were run.
