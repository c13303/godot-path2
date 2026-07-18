# TASK — Make Inventor unlocks generically populate the correct quickslot menu

Read `AGENTS.md` and `ARCHITECTURE.md` first and follow them strictly.

Do not run Godot, tests, compilation, GDExtension builds, exports, or project launch commands. I will test manually.

## Objective

An item purchased as a blueprint from the Inventor must become immediately available in the appropriate quickslot submenu.

This must work generically by catalog item semantics, not through item-specific UI code.

Expected future workflow:

### New placeable

When a new placeable is:

1. registered in `ItemCatalog`;
2. assigned a normal placeable category;
3. registered as an Inventor blueprint;

then purchasing its blueprint must automatically make it appear in the appropriate build menu:

* gardening;
* hammer;
* house.

### New weapon

When a new weapon is:

1. registered in `ItemCatalog` as `weapon` or `gun`;
2. registered as an Inventor blueprint;

then purchasing its blueprint must immediately make it appear in the weapon quickslot menu and make it equipable and usable.

No additional weapon-specific quickbar edit should be required.

This generic behavior must cover `turret_helice` and future Inventor content.

---

## 1. Preserve the correct ownership model

The Inventor blueprint service owns permanent item unlock state.

`ItemCatalog` owns item identity and classification.

`GameUI` owns quickslot availability and equipped weapon state.

`Toolbuild` only renders the items exposed by those authoritative systems.

Do not duplicate unlock state in:

* `GameUI`;
* `Toolbuild`;
* inventory;
* individual item definitions;
* merchant state.

Do not make the Inventor controller directly mutate quickslot UI.

The intended data flow is:

```txt
Inventor purchase
    -> BlueprintUnlockService permanently unlocks catalog item
    -> Progression emits an item-unlock change
    -> GameUI refreshes its derived item access
    -> Correct quickslot submenu displays the item
```

---

## 2. Generalize blueprint definitions from buildables to catalog items

The current blueprint definitions use:

```txt
build_item_id
```

This is unnecessarily limited to buildings.

Replace the authoritative definition field with:

```txt
item_id
```

Example:

```gdscript
&"turret_helice": {
    "item_id": &"turret_helice",
    "currency": &"money",
    "price": 10,
    "prerequisites": [],
    "automatic": false,
    "initially_published": false,
}
```

Blueprint IDs and catalog item IDs must not be assumed to be identical.

Add a proper query:

```gdscript
func get_blueprint_item_id(blueprint_id: StringName) -> StringName
```

The Inventor dialog must use this query when:

* choosing the displayed item;
* looking up its icon;
* looking up its translated name;
* determining which item is unlocked.

Do not continue doing:

```gdscript
var item_id: String = String(blueprint_id)
```

### Compatibility

Keep the current save format based on blueprint IDs.

No save-version bump should be needed because saved unlock records already store blueprint IDs, not `build_item_id`.

Keep compatibility wrappers where current callers may still dynamically use them:

```gdscript
is_blueprint_buildable(item_id)
is_blueprint_unlocked(item_id)
```

However, introduce correctly named generic APIs and migrate known direct callers:

```gdscript
has_item_unlock_definition(item_id: String) -> bool
is_item_unlocked(item_id: String) -> bool
```

The old wrappers may delegate to these generic methods.

Do not rename the entire service or save keys during this focused task.

---

## 3. One generic item-access rule

Add one authoritative query in the appropriate progression/GameUI boundary:

```gdscript
func is_item_progression_unlocked(item_id: String) -> bool
```

Required semantics:

* If the item has no Inventor blueprint definition, it passes this gate.
* If the item has an Inventor blueprint definition, it passes only when that blueprint is permanently unlocked.
* Unknown catalog items fail safely.
* This is only the progression gate; normal availability rules still apply afterward.

For placeables, the complete availability remains:

```txt
catalog classification
+ Inventor unlock gate
+ level availability
+ house uniqueness/ownership rules
+ phase restrictions
+ stock/affordability rules
```

Do not make blueprint unlocking bypass any existing placement, phase, level, stock, or uniqueness restriction.

---

## 4. Build-menu integration

The existing catalog classification should remain responsible for routing placeables:

* plant / terrain / turret / irrigation / trap → gardening menu;
* shop counter / wall / fence / furniture / floor replacement → hammer menu;
* house placement kind → house menu.

Do not add lists of unlocked item IDs to `Toolbuild`.

Do not add conditions such as:

```gdscript
if item_id == "turret_helice"
```

The build menu should continue enumerating catalog candidates and filter each candidate through the generic item-unlock gate.

After a blueprint purchase:

* the newly unlocked placeable must become visible the next time its relevant menu is displayed;
* if that menu is already open behind or immediately after the dialog, it must refresh correctly;
* no scene reload or day transition is required;
* no manual UI registration beyond catalog classification is required.

Unknown items can continue to appear after explicitly ordered known items. Do not require every future item to be added to an ordering array merely for it to exist in the menu.

Ordering arrays may still be used only to provide preferred ordering for known content.

---

## 5. Weapon-menu integration

The current weapon menu is based only on weapons physically present in inventory.

That is insufficient for permanent Inventor weapon unlocks.

Introduce the concept of an **accessible weapon**.

A weapon is accessible when either:

1. the player owns it through the existing inventory/starting-weapon/merchant path; or
2. it has an Inventor blueprint and that blueprint is permanently unlocked.

Add clear APIs, for example:

```gdscript
func has_weapon_access(item_id: String) -> bool
func get_accessible_weapon_ids() -> Array[String]
```

Use these APIs for:

* weapon quickslot menu contents;
* equipping a weapon;
* validating the equipped weapon;
* selecting the first fallback weapon;
* deciding whether the weapon quickslot is disabled;
* restoring the equipped weapon after save/load;
* self-healing an invalid equipped weapon.

Do not use `_has_inventory_weapon()` for these access decisions anymore.

Keep `_has_inventory_weapon()` for operations that specifically concern physical backpack ownership.

### Weapon ordering

Return accessible weapons deterministically:

1. inventory-owned weapons in their existing inventory order;
2. Inventor-unlocked weapons not already present, in blueprint/catalog authored order.

Do not show duplicates when a weapon is accessible from both sources.

### Permanent Inventor weapons are not backpack stacks

An Inventor weapon unlock is permanent progression access.

Do not require a free inventory slot.

Do not add a fake inventory copy when purchasing it.

Do not make the purchase fail because the backpack is full.

Do not display a permanent Inventor weapon as a stackable backpack item unless the game later introduces an explicit design requiring that.

Existing starting weapons and merchant-purchased weapons must remain inventory-backed exactly as they are now.

### Duplicate acquisition

A permanently unlocked Inventor weapon should count as already accessible for unique-weapon purchase checks.

The merchant must not sell the player a redundant second copy of a weapon already permanently unlocked through the Inventor.

Do not globally modify non-weapon inventory uniqueness.

---

## 6. Immediate event-driven refresh

Successful purchases currently change unlock state without a dedicated item-unlock notification.

Add a focused progression signal, for example:

```gdscript
signal inventor_item_unlocked(item_id: StringName)
```

Emit it only after a real new unlock succeeds.

The emitted value must be the catalog `item_id`, not necessarily the blueprint ID.

If purchasing one blueprint also triggers existing automatic unlocks, emit once for each newly unlocked catalog item.

Do not emit duplicate notifications for an item that was already unlocked.

`GameUI` must connect to this signal and refresh:

* the fixed weapon quickslot icon;
* weapon quickslot enabled/disabled state;
* equipped-weapon fallback;
* build-menu-derived availability;
* any currently visible quickslot submenu.

Do not poll progression state every frame from `GameUI`.

`Toolbuild` may retain its existing lightweight visible-menu rendering loop, but unlock state changes must not depend exclusively on waiting for arbitrary polling.

Do not misuse `inventory_changed` as the authoritative progression signal.

A UI refresh may emit its normal derived UI notification afterward if existing consumers require it, but progression unlock state and inventory mutation must remain distinct concepts.

---

## 7. Save/load correctness

Inventor unlocks already persist through blueprint save data. Preserve that.

Required behavior:

* Placeable unlocks remain visible after reload.
* Inventor-unlocked weapons remain in the weapon menu after reload even though no inventory copy exists.
* An Inventor-unlocked weapon may be saved as the equipped weapon.
* On reload, it remains equipped if still accessible.
* If the saved equipped weapon is neither inventory-owned nor progression-unlocked, fall back to the first accessible weapon.
* Old saves remain valid.
* Existing inventory-owned weapons remain valid.
* Do not duplicate unlocked weapons into inventory during load.

Blueprint state is currently restored before player selection validation. Preserve that ordering.

After restoring blueprint and player state, perform one explicit derived UI refresh rather than relying on later incidental calls.

No save-version bump unless an actual serialized field changes.

---

## 8. Blueprint validation

Add small development-time validation to `BlueprintUnlockService`.

Each definition should verify:

* blueprint ID is non-empty;
* `item_id` exists in `ItemCatalog`;
* no two blueprint definitions accidentally unlock the same item unless explicitly supported;
* prerequisites refer to existing blueprints;
* paid blueprint order contains valid paid definitions;
* price and currency are valid for paid blueprints;
* the target item can be routed to a supported gameplay surface.

Currently supported Inventor unlock targets:

```txt
placeable
weapon
gun
```

If an unsupported item type is registered, report a clear warning/error rather than silently purchasing an item that can never appear anywhere.

Do not create a speculative universal reward framework for resources, currencies, or consumable inventory items in this pass.

---

## 9. API cleanup and compatibility

The current terms `possessed weapon` and `inventory weapon` are mixed.

Clean only the directly relevant ambiguity:

* `inventory weapon` means physically present in backpack inventory;
* `accessible weapon` means usable through inventory ownership or permanent progression unlock.

Add new intention-revealing APIs.

Keep compatibility wrappers such as `get_possessed_weapon_ids()` if dynamic usage cannot be disproved, but migrate known menu/equipment callers to `get_accessible_weapon_ids()`.

Before changing or deleting any method, search for:

* direct calls;
* `call()`;
* `Callable`;
* signals;
* scene references;
* string method names.

Do not broadly rewrite the inventory system.

Do not broadly rewrite `GameUI`.

If a large file is already in the warning zone, add only small coordination/query methods and move any substantial new progression-resolution logic to the existing blueprint service.

---

## 10. `turret_helice` integration requirement

After this cleanup, the `turret_helice` implementation should require only:

1. an `ItemCatalog` placeable definition with category `turret`;
2. a blueprint definition whose `item_id` is `turret_helice`;
3. optional preferred display ordering.

After purchasing the blueprint, it must automatically appear in the gardening quickslot menu.

Do not add a `turret_helice` visibility branch to:

* `GameUI`;
* `Toolbuild`;
* Inventor dialog;
* quickslot code.

---

## 11. Future weapon acceptance example

The generic system must support this future scenario without another quickbar integration patch:

```txt
ItemCatalog:
    id: glue_gun
    type: gun

Inventor blueprint:
    blueprint id: glue_gun_blueprint
    item_id: glue_gun
    price: 10 money
```

Expected result:

* Inventor dialog displays the Glue Gun using `item_id`, despite blueprint ID being different.
* Purchasing the blueprint permanently unlocks `glue_gun`.
* It appears immediately in the weapon quickslot menu.
* It is equipable and usable.
* It does not require an inventory slot.
* It remains available after save/reload.
* Existing inventory weapons still appear.
* It is never duplicated in the menu.

Do not actually add `glue_gun` in this task. This is an architectural acceptance case.

---

## 12. Regression requirements

Preserve all existing behavior:

* Ronce unlocks and appears in the gardening menu.
* Fence unlocks and appears in the hammer menu.
* Kraken unlocks and appears in the gardening menu.
* Blueprint prerequisites, publication-at-dawn, unseen notification, acknowledgement, currency spending, and save/load remain unchanged.
* Existing starting weapons appear in the weapon menu.
* Existing merchant-bought weapons appear in the weapon menu.
* Inventory weapons still occupy inventory slots.
* Build item affordability and placement consumption remain unchanged.
* Inventory-backed placeables still depend on owned quantity.
* House menu ownership and uniqueness rules remain unchanged.
* Night restrictions remain unchanged.
* No item becomes unlocked merely because it exists in `ItemCatalog`.

---

## 13. Manual tests to report

Do not run these tests. Include them in the final report for me:

1. Fresh game: verify locked Ronce/Kraken do not appear before unlock.
2. Buy Ronce and immediately open gardening; verify it appears.
3. Buy/unlock Fence and immediately open hammer; verify it appears.
4. Buy Kraken and immediately open gardening; verify it appears.
5. Add/use a temporary development weapon blueprint whose blueprint ID differs from its item ID.
6. Purchase it and verify it immediately appears in the weapon menu.
7. Verify the weapon is usable with a full backpack.
8. Verify it does not occupy or replace an inventory slot.
9. Verify an inventory-owned weapon and an Inventor-unlocked weapon coexist in the menu.
10. Verify no weapon appears twice if both ownership sources exist.
11. Equip the Inventor weapon, save, reload, and verify it remains equipped.
12. Remove/corrupt its unlock in a development save and verify equipped weapon falls back safely.
13. Verify the merchant cannot sell a redundant unique copy of an already unlocked weapon.
14. Verify old saves load with their existing weapons and blueprints.
15. Verify `turret_helice` appears in gardening after its blueprint is purchased.
16. Check logs for invalid blueprint definitions, unsupported item types, duplicate mappings, or stale UI calls.

---

## 14. Final report

Report:

1. Every changed file.
2. The final owner of permanent unlock state.
3. The new generic blueprint-to-item mapping.
4. Compatibility wrappers retained.
5. How placeables are routed into build menus.
6. How accessible weapons are derived.
7. Why Inventor weapons do not consume inventory slots.
8. How immediate UI refresh works.
9. How save/load handles an equipped Inventor weapon.
10. Any dynamic callers discovered.
11. Any unrelated messy code deliberately left unchanged.
12. The manual test list.
13. Confirmation that no Godot, tests, compilation, build, export, or project launch command was run.
