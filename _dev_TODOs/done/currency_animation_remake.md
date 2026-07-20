Read `AGENTS.md` first and follow it strictly.

# Task: replace all fly-to-HUD acquisition animations with one generic player pickup feedback system

## Objective

Replace the current currency/inventory acquisition animations with a conventional world-to-player pickup effect:

* Obtained items no longer fly to the currency HUD, inventory slots, quickbar, or any other UI destination.
* Every obtained item flies toward the player.
* When it reaches the player, it rises slightly above the player’s head and performs a small final bounce/pop.
* The bounce must clearly communicate: **“this item has been acquired.”**
* This must work generically for current and future currencies/items without creating one animation script or method per item.
* Fully migrate and delete the obsolete animation systems.
* Improve code ownership and reduce `game_ui.gd`; do not add another responsibility to that already oversized file.
* Keep the implementation clean, simple, optimized, and production-oriented.

Do not run Godot, tests, compilation, export, or build commands. The user will test manually.

---

# Required architecture

## 1. Create one focused visual controller

Create a focused controller, preferably named something explicit such as:

```text
scripts/ui/player_pickup_feedback_controller.gd
```

Add one corresponding node under `GameUI` in `mainRun.tscn`.

This controller owns only:

* resolving the visual icon for an acquired item;
* creating and cleaning temporary visual nodes;
* animating them from a source position to the player;
* the final above-player bounce/pop;
* stagger and visual-count limits.

It must **not**:

* update progression;
* add inventory;
* remove world drops;
* mark bamboo harvested;
* own reward state;
* know merchant/building/gameplay rules.

The controller is visual feedback only. Logical reward ownership remains with the existing progression, inventory, and gameplay owners.

`GameUI` may retain small intention-revealing façade methods for granting rewards and requesting feedback, but all animation implementation must leave `game_ui.gd`.

Do not create an event bus, abstract framework, service locator, or speculative plugin architecture.

---

## 2. Generic API

Provide a small typed API that supports the two actual source-coordinate cases.

Suggested shape:

```gdscript
func play_from_world(
	item_id: String,
	world_position: Vector2,
	quantity: int = 1
) -> bool

func play_from_screen(
	item_id: String,
	screen_position: Vector2,
	quantity: int = 1
) -> bool
```

The exact names may differ, but keep the API direct and strongly typed.

Use one shared internal implementation. Do not duplicate the animation for currencies and inventory items.

### Item identity

The feedback system should operate on a canonical `item_id`.

Examples:

```text
money
seed
gem
bamboo
imperial_rose
wall
house_builder
...
```

Icon resolution rules:

1. If the item corresponds to a currency, resolve its region through `CurrencyCatalog`.
2. Otherwise, resolve its frame through `ItemCatalog`.
3. Use the existing `items.png` catalog conventions.
4. A newly cataloged future item with a valid currency region or item frame should work automatically.
5. If an invalid item has no usable icon, skip the visual safely. Never block or reverse the logical reward.

There is already duplicated “item ID to currency ID” lookup logic. Add a small canonical query to `CurrencyCatalog`, such as:

```gdscript
static func get_currency_for_item_id(item_id: String) -> StringName
```

Use it where appropriate instead of duplicating scans in both the HUD and pickup controller.

Do not move unrelated catalog responsibilities.

---

# Required visual behavior

Use a screen-space visual layer owned by the focused controller. This keeps icons at a consistent readable pixel size and supports both world sources and UI sources.

The controller must visually sit:

* above normal world sprites and the player;
* below modal/dialog UI where practical;
* with mouse filtering disabled.

## Animation sequence

### A. Launch

* Start at the exact world or screen source.
* Apply a small initial lift/pop so the icon does not look glued to the source.
* Multiple icons from one reward should have a tiny deterministic positional separation so they do not perfectly overlap.
* Do not use a full 360-degree spin.

### B. Flight toward player

* Use a short smooth curved trajectory.
* The animation should feel direct and conventional, not like a long ceremonial HUD flight.
* Approximate flight duration should be around `0.35–0.55 s`, with tuning constants centralized in the controller.
* A simple interpolation plus a sine/arc offset is sufficient. Do not over-engineer a path system.

The player destination must remain dynamic during the flight:

* Resolve/cache the player through the existing `"player"` group.
* Validate the cached instance before reuse.
* Recalculate the player’s screen position while the animation is active.
* The icon must still reach the player if the player runs, changes direction, or the camera moves.
* There must be no permanent per-frame polling when no pickup animation exists.

### C. Acquired-item bounce

When the icon reaches the player:

* move it slightly above the player’s head;
* make it rise a little farther;
* apply a compact scale bounce/pop;
* briefly settle;
* fade and/or shrink away;
* continue tracking the player during this final phase.

The final result should read approximately as:

```text
source -> quick curved flight -> player contact -> icon pops above head -> disappears
```

The whole sequence should remain compact, normally below one second.

Do not leave temporary nodes or Tweens alive after completion.

---

# Quantity handling and optimization

Do not spawn unlimited visual nodes for large rewards or refunds.

Provide:

* a reasonable per-event visual cap;
* a reasonable global active-visual cap;
* compressed stagger timing so an event does not take several seconds;
* safe skipping of excess visuals while still granting the complete logical quantity.

Five bamboo must show five icons.

Very large rewards/refunds may show only a representative capped number of icons. The full amount must still be granted atomically.

A value near the existing reward cap of `15` may be appropriate, but inspect normal quantities and choose a sensible value.

Do not add object pooling unless existing profiling demonstrates it is needed. Short-lived capped nodes are simpler and safer.

No always-running `_process()` should be introduced. Use Tweens or enable processing only while active visuals exist.

---

# Granting and persistence semantics

The animation must never own or delay the actual reward.

## Canonical rule

For all acquisitions:

1. Validate whether the reward can be granted.
2. Grant the full reward atomically.
3. Commit/remove/update the source state.
4. Start visual feedback.
5. A missing controller, player, texture, or animation failure must not lose the reward.

This is especially important for save/load safety.

### Currencies

Currency must be credited in one operation before feedback begins.

Remove the old pattern where one currency unit is credited when each icon reaches the HUD.

### Inventory items

Continue checking inventory capacity before consuming the world source.

If the inventory cannot accept the full reward:

* do not consume the source;
* do not partially add the reward;
* do not play pickup feedback.

### Ground drops

Currently a loose currency drop is hidden and retained until its HUD-flight callback completes.

Remove that visual/gameplay coupling.

After the currency grant succeeds:

* remove/release the ground-drop record immediately;
* start player pickup feedback independently;
* do not keep a hidden drop alive waiting for a Tween callback.

### Persistent sources

Bamboo and similar persistent sources must still update saved source state only after the reward grant succeeds.

The reward must already exist logically before the first icon moves.

---

# Migrate every current acquisition path

Search for direct calls, `call()`, `Callable`, string method names, scene script references, and comments before deleting anything.

At minimum, inspect and migrate these known paths:

## `scripts/map/ground_drop_manager.gd`

* Loose gem/seed/money/other currency pickups.
* Remove the finished-animation callback dependency.
* Grant, release the drop, then show feedback.
* Remove its unnecessary dependency on `GameUI/currenciesUI` for collectible textures. Resolve ground-drop currency visuals directly from `CurrencyCatalog` instead of reading HUD icon textures.

## `scripts/map/bamboo_harvest_controller.gd`

* Keep the atomic five-bamboo grant.
* Route all five visuals through the generic player feedback controller.
* Preserve save safety and mature/immature state behavior.

## `scripts/map/dawn_harvest_controller.gd`

* Imperial rose inventory pickup.
* Preserve the capacity check and harvest ordering.
* The imperial rose must fly to the player, not an inventory/HUD slot.

## `scripts/ui/merchant_dialog_controller.gd`

* Purchased seed/items currently launch from a dialog row toward HUD/inventory.
* Keep launching from the row’s screen position, but target the player and use the generic feedback API.
* Logical purchase must remain completed independently of the visual.

## `scripts/ui/fundamental_builder_dialog_controller.gd`

* Intro gem reward.
* Credit the complete gem reward immediately.
* Show generic pickup feedback from the builder/dialog source to the player.

## `scripts/map/sheep_garden_role.gd`

* Debris reward gems.
* Stop calling `gemIcon` directly.
* Use a canonical `GameUI` reward/grant façade.
* Grant atomically, then show feedback.

## `scripts/map/building_manager.gd`

* Client payment money visual.
* The client sale already credits money immediately.
* Replace the direct `moneyIcon` visual call with generic visual-only feedback from the client’s world position to the player.

## `scripts/ui/game_ui.gd`

Migrate:

* world currency collection;
* immediate currency rewards;
* inventory item world collection;
* active-night currency rewards;
* active-night item rewards;
* build currency refunds;
* inventory-backed build refunds;
* merchant purchase feedback façades;
* any other item/currency flight helper.

Keep small granting/coordination methods only where `GameUI` is already the correct façade or inventory owner.

Delete the entire embedded inventory-flight implementation from `game_ui.gd`.

## `scripts/ui/possessed_items_hud.gd`

The possessed-items HUD should display counts only.

Remove:

* animation-script preloads;
* dynamically applying seed/gem/money/generic currency scripts;
* flight-target position APIs used only by the old system;
* any animation-specific behavior.

Static and dynamically created HUD rows should remain plain UI nodes.

## `mainRun.tscn`

Remove obsolete animation scripts and exported animation settings from:

* `seedIcon`;
* `gemIcon`;
* `moneyIcon`.

These icons remain plain HUD icons used for quantity display.

Add and wire the focused pickup feedback controller cleanly.

---

# Remove the obsolete systems completely

After every caller has migrated, delete these files if searches confirm they have no legitimate remaining use:

```text
scripts/ui/currency_harvest_animation.gd
scripts/ui/currency_harvest_animation.gd.uid

scripts/ui/seed_icon.gd
scripts/ui/seed_icon.gd.uid

scripts/ui/gem_icon.gd
scripts/ui/gem_icon.gd.uid

scripts/ui/money_icon.gd
scripts/ui/money_icon.gd.uid

scripts/ui/generic_currency_icon.gd
scripts/ui/generic_currency_icon.gd.uid
```

Also remove obsolete code including, where no longer used:

```text
CurrencyHarvestAnimation
animate_seed_harvest
animate_gem_harvest
animate_money_harvest
animate_money_harvest_visual_only
animate_currency_harvest
animate_currency_flight_only
_currency_animate_method
_currency_icon_node
_reward_icon_node
animate_inventory_item_to_slot
_inventory_backed_refund_target_position
get_item_flight_target_global_position
PURCHASE_FLIGHT_SIZE
PURCHASE_FLIGHT_DURATION
_update_purchase_flight
_finish_purchase_flight
```

Do not retain dead compatibility wrappers merely to avoid migrating internal callers.

Only preserve a wrapper if a real dynamic/scene use is found that cannot safely be migrated. Report any such wrapper explicitly.

Do not remove `CurrencyCatalog` HUD node-name/label-name data that is still used by progression or possessed-item HUD rendering.

---

# SFX behavior

Inspect existing acquisition sounds while migrating.

Required result:

* do not play one bag sound for every visual icon in a large reward;
* play at most one appropriate acquisition sound per logical transaction/event;
* do not tie reward credit to the sound or animation landing;
* preserve source-specific sounds only where they still make semantic sense;
* avoid duplicate sounds caused by both `add_inventory()` and the feedback controller.

Choose one clear owner for the acquisition sound and report it.

---

# Regression constraints

Do not change:

* currency quantities;
* item quantities;
* prices;
* inventory capacity or stacking;
* reward claim rules;
* bamboo growth/state rules;
* ground-drop pickup radius;
* merchant availability;
* build refund amounts;
* night reward claim persistence;
* client payment logic;
* HUD count layout;
* save format.

The intended behavior change is:

```text
old: obtained object -> HUD/inventory slot -> sometimes credit on arrival
new: atomic grant -> object flies to player -> above-head acquired bounce
```

Do not refactor unrelated parts of `game_ui.gd`, `building_manager.gd`, or the catalogs during this task.

---

# Static verification

Do not run Godot.

Use static searches to verify that:

* no code still calls the deleted animation methods;
* no scene still references the deleted scripts;
* no comments still describe fly-to-HUD or fly-to-inventory acquisition;
* `game_ui.gd` no longer contains visual-flight algorithms;
* no acquisition path directly searches for `seedIcon`, `gemIcon`, or `moneyIcon`;
* the HUD no longer installs animation scripts;
* all current item/currency sources route through the new generic feedback path;
* no permanent polling loop was introduced.

Update outdated comments and relevant architecture documentation, including the bamboo description that currently names `grant_currency_from_world_immediate` and HUD flight behavior.

---

# Manual test checklist for the final report

Tell the user to test all of the following:

1. Pick up one loose gem while standing still.
2. Pick up a loose gem while running away from it.
3. Change direction during the flight.
4. Pick up several drops almost simultaneously.
5. Harvest one bamboo and verify five bamboo icons.
6. Save immediately after bamboo collection and reload.
7. Harvest an imperial rose.
8. Attempt imperial rose collection with full inventory.
9. Claim builder intro gems.
10. Receive sheep debris reward gems.
11. Complete a client purchase and observe money from client to player.
12. Claim currency and item night rewards.
13. Buy a seed from the merchant.
14. Buy an inventory-backed item from the merchant.
15. Remove a currency-funded building and verify the refund.
16. Remove an inventory-backed building and verify the returned item.
17. Trigger a large refund/reward and verify the visual cap.
18. Collect near a screen edge.
19. Collect while the camera is moving.
20. Open a modal/dialog during active feedback and verify correct layering.
21. Verify HUD quantities update immediately rather than on animation landing.
22. Verify no item is lost or duplicated when saving during feedback.

---

# Final report

Provide:

* files added;
* files modified;
* files deleted;
* the final canonical feedback API;
* where logical grants now occur;
* all migrated acquisition paths;
* the chosen per-event and global visual caps;
* SFX ownership;
* confirmation that old animation method/script searches return no remaining references;
* any compatibility wrapper that had to remain and the exact reason;
* any production-quality concern discovered;
* the manual tests the user must perform;
* explicit confirmation that Godot/tests/builds were not run.
