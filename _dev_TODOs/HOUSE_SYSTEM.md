Implement the complete **house-bound ally system** described below.

Read `AGENTS.md` first and respect it fully. Inspect the existing implementation before editing. Do not run Godot, tests, builds, exports, or compilation.

## Core invariant

Normal ally presence must be derived exclusively from **completed, intact houses**.

Do not maintain a second independent source of truth such as saved builder counts, unconditional merchant spawning, or manually configured desired agent counts.

* One completed `house_builder` = one normal builder.
* One completed `house_merchant` = one seed merchant.
* WIP houses grant no resident.
* Destroyed houses grant no resident.

Use the existing `HouseManager`, builder controller, merchant controller, house placement system, and agent systems. Extend them cleanly; do not rebuild the feature inside `building_manager.gd`.

## New house types

### `house_builder`

* Sprite: `house_builder.png`
* `items.png` icon frame: `28`
* Cost: `20` gems
* Resident type: builder
* Multiple allowed

### `house_merchant`

* Sprite: `house_merchant.png`
* `items.png` icon frame: `29`
* Cost: `20` gems
* Resident type: seed merchant
* Unique

Merchant uniqueness must count both:

* WIP merchant houses
* completed merchant houses

Reject duplicate placement again at commit time; UI disabling alone is insufficient.

The existing generic house quickslot icon remains unchanged.

The current legacy house should be converted into `house_merchant` where practical rather than keeping two systems.

Add backward-compatible migration:

```text
house -> house_merchant
```

Apply it to saved house records and any saved inventory/build-item references that can still contain the old ID.

Both new houses are direct gem purchases, not inventory-backed items.

## House construction and resident spawning

A resident is granted only when its house becomes completed.

When a house completes during daytime:

* spawn its resident immediately;
* associate that resident permanently with the house runtime ID.

When a house completes during nighttime:

* do not show the resident at night;
* spawn it at the next dawn.

At every dawn, reconcile the full state:

* every completed intact house must have exactly one corresponding resident;
* no resident may exist without a valid completed house, except the fundamental builder;
* repair missing residents;
* remove duplicates.

Do not save active ally positions. On load, restore houses first, then reconstruct ally presence from completed houses.

## Resident-to-house ownership

Create a focused owner such as `AllyHousingController` or an equivalent small dedicated service.

It owns only:

* house ID ↔ resident association;
* resident housing state;
* dawn reconciliation;
* house completion/removal reactions;
* fundamental builder fallback state;
* return-home and evacuation requests.

It must not absorb:

* builder construction work logic;
* merchant shop logic;
* generic house geometry;
* generic building placement;
* generic phase control.

Keep responsibilities:

* `HouseManager`: house records, status, geometry, save/load.
* Builder controller: builder work, movement, task assignment.
* Merchant controller: merchant idle/shop behavior.
* Housing controller: resident lifecycle attached to houses.
* `BuildingManager`: wiring only.

Do not add the complete implementation directly to an existing large manager.

## Normal daytime behavior

Normal residents keep their existing behavior:

* builders construct WIP houses;
* seed merchant shop behavior remains unchanged.

Each normal resident must know:

```text
resident_house_id
home entrance
```

Normal builders may use a nearby valid idle position derived from their house entrance instead of the old single global builder spot.

The seed merchant must no longer spawn unconditionally from the old merchant marker.

Remove or neutralize any old authoritative `builder_count`, desired-count, or unconditional merchant-presence logic.

Development shortcuts must not violate the new invariant.

## Night return behavior

At night, every active normal resident must return to its own house:

1. stop accepting new work/interactions;
2. walk to the house entrance;
3. when the entrance is reached, remove or deactivate the runtime agent completely;
4. store only a logical “inside house” state.

Do not leave an invisible active native agent processing movement.

For per-house return routes, use a cheap one-shot path suitable for the very small ally count. Do not create one permanent flow field per house.

If the house entrance cannot be reached, evacuate the resident through the shared ally exit instead of leaving it stuck forever. The house may recreate its resident at the next dawn.

## House destruction

Handle destruction before the house record and entrance data are discarded.

`HouseManager` should expose a typed pre-removal event/snapshot containing at least:

```text
house runtime ID
house item ID/type
completion state
entrance world position/cell
```

### Resident currently outside

When its house is destroyed:

* cancel/release builder work cleanly if applicable;
* close the merchant shop immediately if open;
* detach the resident from the house;
* send it to `fundamental_builder_out`;
* remove it after it reaches the exit.

### Resident currently inside

When its house is destroyed:

* respawn it at the former entrance from the pre-removal snapshot;
* send it to `fundamental_builder_out`;
* remove it at the exit.

All homeless normal allies use the same evacuation route.

## Shared evacuation flow field

Add one reusable general ally escape flow field targeting:

```text
fundamental_builder_out
```

It must be available for:

* residents whose house is destroyed;
* residents unable to reach their house at night;
* the fundamental builder when retiring.

Integrate this field into the existing navigation lazy-load/topology rebuild system:

* initialize it with the level;
* rebuild it only on real hard navigation topology changes, following the same policy as other permanent fields;
* do not rebuild it for turrets, slowing tiles, house state changes, or unrelated placement changes;
* keep the native extension generic.

Do not create separate evacuation fields per ally or house.

## Fundamental builder

Use these level markers:

```text
fundamental_builder_in
fundamental_builder_spot
fundamental_builder_out
```

Register them explicitly as ally markers.

They must not be detected as client or monster spawners based on texture or generic marker discovery.

The fundamental builder is the bootstrap and recovery fallback.

Eligibility:

```text
day >= 2
AND completed house_builder count == 0
```

Rules:

* Day 1: absent.
* Dawn day 2: if no completed builder house exists, enter from `fundamental_builder_in`.
* Idle at `fundamental_builder_spot`.
* Build WIP houses using the normal builder work system.
* A WIP builder house does not make him leave.
* When the first builder house completes:

  * finish that completion cleanly;
  * stop taking new work;
  * exit through `fundamental_builder_out`;
  * then allow the normal house-bound builder to take over.
* If all completed builder houses are later destroyed:

  * during daytime, bring the fundamental builder back immediately;
  * during nighttime, bring him back at the next dawn.
* Never allow two fundamental builders.
* Never associate him with a house.
* Do not save his position; reconstruct his presence from the eligibility rule.

Avoid a transition where the fundamental builder and the first normal builder both claim the same WIP task.

## House quickslot rules

The generic house quickslot icon stays unchanged.

### Day 1, before the fundamental builder exists

If there are no completed builder houses and the fundamental builder has not arrived yet:

* hide the house quickslot;
* block its keyboard/gamepad shortcut as well.

### Fundamental builder active, no completed builder house

Show the house quickslot, but offer only:

```text
house_builder
```

Do not show `house_merchant` yet.

### At least one completed builder house

Offer both house types:

* `house_builder`: enabled
* `house_merchant`: enabled only when no WIP or completed merchant house exists

If the last builder house is destroyed and the fundamental builder returns, revert to builder-only house selection until a builder house is completed again.

Centralize this availability logic. Do not duplicate conditions across UI and placement code.

## HouseManager API

Extend the existing house manager with focused typed queries/signals rather than exposing its internal dictionaries.

Equivalent API is acceptable, but it should provide functionality such as:

```gdscript
count_completed_houses(item_id: StringName) -> int
count_existing_houses(item_id: StringName) -> int
get_completed_house_ids(item_id: StringName) -> Array[int]
get_house_snapshot(house_id: int)
```

Lifecycle notifications equivalent to:

```gdscript
house_completed(snapshot)
house_removing(snapshot)
houses_restored()
```

Use explicit GDScript types. Follow the strict typing rules in `AGENTS.md`.

## Existing markers and legacy logic

Search for and remove or replace old assumptions involving:

```text
builder_spot
seedmerchent
legacy house item ID
saved builder_count
desired builder count
unconditional merchant spawn
```

Do not leave compatibility fallbacks that can create duplicate residents.

Preserve unrelated agent, construction, shop, phase, navigation, save, and building behavior.

## Required edge cases

The implementation must correctly handle:

1. Day 1: house quickslot hidden and shortcut blocked.
2. Dawn day 2: fundamental builder enters.
3. WIP builder house exists: fundamental builder remains.
4. First builder house completes: fundamental retires and one normal builder replaces him.
5. Several builder houses: exactly one builder per completed house.
6. Last completed builder house destroyed: normal builder evacuates and fundamental builder returns.
7. Merchant house duplicate placement attempted before completion: rejected.
8. Merchant house destroyed while shop is open: shop closes immediately and merchant evacuates.
9. House destroyed while resident is inside: resident reappears at the former entrance and evacuates.
10. Night begins while resident is working or shop is open: current activity stops cleanly and resident returns home.
11. House entrance unreachable: resident evacuates instead of freezing.
12. Save/load with WIP and completed houses: residents are reconstructed exactly once.
13. Legacy saves containing `house`: migrated to `house_merchant`.
14. Fundamental markers never enter normal client/monster spawner registries.
15. No unnecessary flow-field rebuilds are introduced.

## Implementation discipline

Before editing, identify:

* current house ownership;
* current builder spawning/count ownership;
* current merchant spawning ownership;
* current dawn/night hooks;
* current save/load restoration order;
* current permanent flow-field registration;
* current quickslot availability owner.

Then implement the smallest coherent architecture matching the rules above.

Do not:

* create parallel old/new ally systems;
* put all logic in `BuildingManager`;
* add one flow field per house;
* hardcode native-extension behavior for builder or merchant types;
* save transient ally positions;
* silently preserve obsolete builder-count authority;
* run Godot or tests.

At the end, report:

* files changed;
* ownership/API changes;
* removed legacy logic;
* save migration added;
* manual scenarios the user should test;
* any remaining uncertainty grounded in the actual code.
