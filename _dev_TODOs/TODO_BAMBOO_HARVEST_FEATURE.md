# Bamboo harvest — authored permanent resource plants

Implement the bamboo harvest feature cleanly in the current Godot codebase.

Read `AGENTS.md` first and follow it strictly.

Do not run:

- Godot;
- tests;
- compilation;
- SCons;
- exports;
- build commands.

The user performs runtime testing manually.

This is a focused gameplay feature, not a broad plant-system refactor.

---

# Feature

Levels can author permanent bamboo plants through a root-level container named:

```text
bamboo
```

Each direct `Node2D` child of that container marks one bamboo plant.

For the current implementation, `level_demo.tscn` is the active level.

At level preload:

1. map every authored bamboo child position to its floor tile;
2. create one permanent bamboo plant on that cell;
3. start every bamboo mature unless a save restores another state.

Use the existing asset:

```text
bamboo.png
```

Search the actual repository for its path. Do not duplicate, move, or rename the asset.

The texture contains two horizontal `32x64` frames:

```text
frame 0: immature
frame 1: mature
```

Behavior:

- mature bamboo can be harvested by player proximity;
- use exactly the same pickup distance rule as ground gems/currency drops;
- harvesting turns the plant immature immediately;
- harvesting grants exactly `5` bamboo currency;
- show five bamboo icons flying from the plant tile to the bamboo currency HUD;
- every real dawn makes every bamboo mature again;
- bamboo can never be removed, damaged, trampled, eaten, or destroyed;
- bamboo always slows everyone on its tile to `50%` speed, whether mature or immature;
- bamboo cells are always unbuildable;
- maturity state is saved and restored.

Do not make bamboo a normal player-placed plant.

---

# Important current-codebase facts

Verify these before editing.

## Level loading

`LevelLoader` instantiates the selected level off-tree, captures selected authored data, reparents only specific runtime nodes/layers, and then frees the level root.

Therefore, merely leaving the authored `bamboo` container in `level_demo.tscn` is insufficient: its cell positions must be captured by `LevelLoader` before the level root is freed.

Do not reparent the authored marker nodes as gameplay visuals.

Treat them as editor markers only.

## Existing bamboo currency

Bamboo currency already exists through:

```text
CurrencyCatalog
Progression.update_bamboo()
Progression.update_currency()
PossessedItemsHud
GenericCurrencyIcon
```

Reuse it. Do not add a second bamboo inventory or duplicate currency state.

## Existing terrain slowdown

`FlowFieldNative.set_cell_speed_multiplier()` already updates the shared terrain-speed source used by native steering and future flow fields.

Reuse this mechanism.

Do not recompute flow fields when bamboo matures or is harvested.

The slowdown belongs to the permanent bamboo presence, not its maturity.

## Existing build validation

`BuildPlacementService.is_placeable_occupied()` intentionally allows most non-plant placeables to displace actors before checking actor groups.

Therefore, adding bamboo visuals to an occupied-node group is not sufficient to make bamboo cells permanently unbuildable.

Add one explicit static-world-feature reservation query before actor-displacement handling.

## Save safety

The current normal currency-harvest animation credits currency when each icon reaches the HUD.

Do not use that delayed-credit path directly for bamboo after immediately saving the bamboo as immature: saving during the icon flight could persist the harvested plant without persisting all five currency units.

For bamboo, make reward/state mutation atomic:

```text
credit all 5 bamboo immediately
then run five visual-only HUD flights
then mark/keep the plant immature
```

The player-visible animation remains the same, but a save during the flight cannot lose the reward.

Implement this through a small reusable GameUI currency API, not by reaching into HUD internals from the bamboo controller.

---

# Architecture

Create two focused files:

```text
scripts/map/bamboo_harvest_controller.gd
scripts/map/bamboo_plant_visual.gd
```

## `BambooHarvestController`

Owns:

```text
- the authored bamboo cell registry
- mature/immature state
- visual instances
- player pickup checks
- dawn regrowth
- bamboo save serialization/restoration
- registration of permanent terrain slowdown
```

Does not own:

```text
- general plant state
- normal plant growth
- flow-field rebuilding
- build placement algorithms
- global currency storage
- generic save-file orchestration
```

## `BambooPlantVisual`

Owns only:

```text
- one bamboo sprite
- frame selection
- base-anchored idle dance
- z-index positioning
```

It must not own:

```text
- maturity rules
- harvesting
- currency
- save state
- dawn events
- slowdown
- build reservations
```

Do not add bamboo behavior to `PlantManager`.

Do not add the full feature to `BuildingManager`.

`BuildingManager` remains a setup/façade owner with thin wrappers only.

---

# Part A — Capture authored bamboo cells in `LevelLoader`

Modify:

```text
scripts/map/level_loader.gd
```

Add:

```gdscript
var _loaded_bamboo_cells: Array[Vector2i] = []
```

Add a read-only getter returning a copy:

```gdscript
func get_loaded_bamboo_cells() -> Array[Vector2i]
```

During `_load_level()`, before `level_root.free()` and while the level’s own `floor` layer still exists, capture the markers.

Use a focused method such as:

```gdscript
func _capture_level_bamboo_cells(level_root: Node) -> void
```

Rules:

1. Clear `_loaded_bamboo_cells` on each level load.
2. Find the exact root-level node:

   ```text
   bamboo
   ```

3. If there is no container, keep an empty list without a hard error.
4. Every direct child that is a `Node2D` is one marker.
5. Convert each marker’s `global_position` to a floor cell using the same world-to-cell convention used by spawner marker capture:

   ```gdscript
   var local_position: Vector2 = floor_layer.to_local(marker.global_position)
   var cell: Vector2i = floor_layer.local_to_map(local_position)
   ```

6. Ignore non-`Node2D` children with a warning.
7. Reject markers whose derived cell has no floor tile, with a warning including marker name and cell.
8. Deduplicate cells. Warn when two markers resolve to the same cell.
9. Sort the final cells deterministically by Y, then X.
10. Do not mutate or reparent the marker nodes.

The reviewed archive does not currently contain the authored `bamboo` container, and its pack omits assets. The actual working tree is expected to contain them.

If the working tree still has no bamboo markers:

- implement zero-marker-safe support;
- do not invent positions;
- report the mismatch in the final report.

---

# Part B — Bamboo state owner

Create:

```text
scripts/map/bamboo_harvest_controller.gd
```

Suggested base:

```gdscript
extends Node2D
class_name BambooHarvestController
```

Use a small typed nested record rather than parallel loose dictionaries:

```gdscript
class BambooRecord:
    var cell: Vector2i
    var mature: bool
    var visual: BambooPlantVisual
```

Equivalent explicit typed state is acceptable.

Suggested constants:

```gdscript
const BAMBOO_CURRENCY: StringName = &"bamboo"
const HARVEST_AMOUNT: int = 5
const TERRAIN_SPEED_MULTIPLIER: float = 0.5
```

Setup should receive explicit dependencies equivalent to:

```gdscript
func setup(
    floor_layer: TileMapLayer,
    level_loader: LevelLoader,
    navigation_sync: BuildingNavigationSyncService,
    game_ui: CanvasLayer
) -> void
```

It may resolve the player lazily through the existing:

```text
player
```

group.

Do not give it the complete `BuildingManager` as a universal private backchannel.

## Setup behavior

During setup:

1. read `level_loader.get_loaded_bamboo_cells()`;
2. create one record per cell;
3. set every record mature by default;
4. create its visual;
5. register the permanent `0.5` terrain multiplier for the cell;
6. connect once to `GameState.dawn_phase_changed`;
7. compute the shared pickup radius;
8. enable processing only when at least one bamboo exists.

The controller must be set up synchronously during `BuildingManager._ready()` before `Progression._ready()` can restore save data.

The current scene orders `BuildingManager` before `progression`; preserve that usable initialization seam.

---

# Part C — Bamboo visual

Create:

```text
scripts/map/bamboo_plant_visual.gd
```

Suggested base:

```gdscript
extends Node2D
class_name BambooPlantVisual
```

Find and preload the existing `bamboo.png`.

Do not assume another texture path if repository search shows a different one.

## Frame layout

Configure one `Sprite2D`:

```gdscript
hframes = 2
vframes = 1
centered = true
```

Frames:

```text
0 = immature
1 = mature
```

Expose a narrow state method:

```gdscript
func set_mature(value: bool) -> void
```

## Exact tile anchoring

Each frame is `32x64`.

The lower `32x32` half of the frame must occupy the bamboo’s floor tile.

For a `32x32` tile:

- the plant root/sort point is the floor cell center;
- a visual pivot sits at the bottom edge of that tile;
- the centered `32x64` sprite is placed `32` pixels above that pivot.

Equivalent transform math is acceptable, but verify the resulting geometry:

```text
sprite lower half:
    exactly covers the authored floor tile

sprite upper half:
    extends one tile above it
```

Do not place the entire sprite centered on the tile.

Use the real floor tile size rather than hardcoding tile dimensions for the offset math, while still validating that the bamboo frame itself is `32x64`.

## Z ordering

Use world-Y ordering consistent with agents and existing tall world visuals:

```gdscript
z_as_relative = false
z_index = int(cell_center_world.y)
```

The result must be:

- agents above the bamboo draw behind it;
- agents below it draw in front;
- the sprite does not use a fixed decorative layer that ignores agent Y.

## Idle dance

Both immature and mature bamboo should continuously feel alive.

Use a base-anchored animation similar to `GrownupRoseDance`, slightly stronger:

Suggested defaults:

```gdscript
sway_degrees = 7.0
sway_speed = 1.0
breathe_amount = 0.06
breathe_speed = 1.3
bob_pixels = 1.5
```

Requirements:

- pivot around the planted base, not sprite center;
- randomize/desynchronize phase per plant;
- preserve the bottom anchor;
- no tween allocation every frame;
- no global synchronization where every bamboo moves identically;
- no harvest pop, particles, or additional effects unless already effectively free.

Keep the animation readable, not violent.

---

# Part D — Exact pickup range reuse

Modify:

```text
scripts/map/ground_drop_manager.gd
```

Do not duplicate the gem pickup constants in bamboo code.

Extract the current radius calculation into a small reusable static/public helper, for example:

```gdscript
static func pickup_radius_for_floor(floor_layer: TileMapLayer) -> float
```

It must preserve the exact existing rule:

```text
fallback:
    36 px

tile-based value:
    max(tile width, tile height) * 1.15

result:
    max(fallback, tile-based value)
```

`GroundDropManager._refresh_pickup_radius()` must use that same helper, so existing gem pickup behavior remains unchanged.

`BambooHarvestController` must use the helper and compare squared distance.

Preserve the current lightweight pickup scan cadence:

```text
0.06 seconds
```

Reuse the existing constant if practical rather than duplicating its numeric value.

Do not add an `Area2D`, collision shape, or per-bamboo physics body merely for pickup detection.

---

# Part E — Harvesting and atomic currency reward

## Pickup processing

Only process pickup checks when:

- there is at least one bamboo record;
- at least one record is mature;
- a valid player exists;
- gameplay is not paused by tree pause semantics.

For every mature bamboo within the shared currency-pickup radius:

1. ask GameUI to grant and animate exactly five bamboo currency;
2. only if the grant succeeds, set the bamboo immature immediately;
3. update its visual to frame `0`.

Do not require exact player-cell equality. Use the same radial distance rule as gems.

If several mature bamboos are simultaneously inside the gem pickup radius, collecting each is acceptable and matches the existing nearby-ground-drop behavior.

A record that is already immature must never grant again before the next dawn.

## Save-safe GameUI API

Modify:

```text
scripts/ui/generic_currency_icon.gd
scripts/ui/game_ui.gd
```

Add a visual-only animation entry point to `GenericCurrencyIcon`, using the existing `CurrencyHarvestAnimation` with:

```text
credit_on_finish = false
```

Use a clear method name such as:

```gdscript
func animate_currency_flight_only(...)
```

Do not change existing `animate_currency_harvest()` behavior or positional signature.

Add one generic GameUI operation such as:

```gdscript
func grant_currency_from_world_immediate(
    currency: StringName,
    world_position: Vector2,
    count: int
) -> bool
```

Required behavior:

1. validate the currency through `CurrencyCatalog`;
2. validate `count > 0`;
3. credit the complete amount once through:

   ```gdscript
   progression.update_currency(currency, count)
   ```

4. launch one visual-only icon flight per unit when the matching HUD icon supports it;
5. use the same compressed stagger rule already used by currency rewards;
6. if the currency is valid and progression credit succeeds but the HUD icon is unavailable, keep the credited reward and return success;
7. do not credit again when flights finish.

This method is reusable for persistent world sources whose saved source state changes immediately.

Do not replace existing delayed-credit collection used by loose ground drops.

The bamboo controller must call:

```gdscript
grant_currency_from_world_immediate(
    &"bamboo",
    bamboo_world_position,
    5
)
```

Do not call `Progression` directly from the bamboo controller.

---

# Part F — Dawn regrowth

Connect `BambooHarvestController` to:

```gdscript
GameState.dawn_phase_changed
```

When the signal changes to `true` during a real phase transition:

- set every bamboo mature;
- update every visual to frame `1`;
- do not grant currency;
- do not touch terrain speed;
- do not rebuild navigation;
- do not recreate visual nodes.

Ignore restored-phase signal replay:

```gdscript
if GameState.is_emitting_restored_phase_signals():
    return
```

This matters because loading a save made during dawn after harvesting bamboo must preserve the saved immature state rather than treating load as a second dawn.

Fresh runs still begin with every authored bamboo mature.

Use an idempotent method such as:

```gdscript
func mature_all_for_dawn() -> void
```

---

# Part G — Permanent 50% slowdown

Modify:

```text
scripts/map/building_navigation_sync_service.gd
```

Add a small generic static-world-feature terrain-speed registry.

Suggested state:

```gdscript
var _static_terrain_speed_by_cell: Dictionary = {}
```

Suggested public API:

```gdscript
func set_static_terrain_speed_multiplier(
    cell: Vector2i,
    multiplier: float
) -> void
```

Semantics:

- clamp multiplier to `[0.01, 1.0]`;
- values at or above `1.0` remove the static entry;
- otherwise store it;
- refresh only that cell’s effective terrain speed.

Update:

```gdscript
effective_cell_speed_multiplier(cell)
```

so the static value participates in the existing minimum calculation with logical plants and all placeable layers.

The bamboo controller registers:

```gdscript
0.5
```

once per authored bamboo cell.

The multiplier applies whether the bamboo is mature or immature.

Do not:

- request a flow rebuild;
- dirty garden topology;
- invalidate routes;
- add an agent-kind branch;
- add separate slowdown logic for player, monsters, clients, merchants, builders, or sheep.

The current shared native terrain multiplier is intended to affect every native-steered agent, including the player.

Verify this current behavior before adding any separate player code.

Because bamboo is permanent, no runtime unregister path is required. Still keep the navigation-sync API generic and able to clear an entry with `1.0`.

---

# Part H — Permanently unbuildable cells

Do not stamp an invisible tile into:

```text
wallz
plantz
traversable_buildings
blocking_buildings
fences
```

A hidden tile would couple permanent bamboo to layer save/removal logic and could make it destructible.

Use an explicit reservation query.

## Bamboo controller query

Add:

```gdscript
func has_bamboo_at(cell: Vector2i) -> bool
```

This is true in both maturity states.

## Thin façades

Add a thin `BuildingManager` query with a generic intent-revealing name, for example:

```gdscript
func is_permanent_world_feature_cell(cell: Vector2i) -> bool:
    return _bamboo_harvest_controller.has_bamboo_at(cell)
```

Add a thin `BuildSystem` wrapper that reaches the manager through its existing resolver:

```gdscript
func is_permanent_world_feature_cell(cell: Vector2i) -> bool
```

## Placement enforcement

Modify:

```text
scripts/map/build_placement_service.gd
```

At the beginning of `is_placeable_occupied()`—before `_placeable_displaces_actors()` can bypass actor-group occupancy—reject any permanent world-feature cell.

This one check must cover:

- normal one-cell buildings;
- logical plants;
- fences;
- turrets;
- counters;
- houses and every house presence cell;
- drag placement;
- mouse preview;
- gamepad preview.

Do not add bamboo to `occupied_groups` as the sole protection.

Do not make the bamboo cell non-walkable.

Player and agents must still walk through the cell with the slowdown.

---

# Part I — Never destroyed

Bamboo must not participate in any of these systems:

```text
PlantManager removal/trampling
BuildingObjectManager
PlayerPlaceableDurabilityService
BuildRemovalService
monster walkover damage
tantrum targets
projectile damage
turret targets
garden topology
garden plant targets
house footprint registry
ground collectibles
```

Do not give bamboo:

- health;
- collision;
- damage callbacks;
- removal callbacks;
- debris;
- refund behavior;
- player-built provenance.

Harvest changes only maturity and reward state.

---

# Part J — Save/load

Modify:

```text
scripts/gameState/progression.gd
scripts/map/building_manager.gd
```

Add a dedicated optional save section:

```json
"bamboo_states": [
  {
    "x": 10,
    "y": 20,
    "mature": false
  }
]
```

Do not merge bamboo into `PlantManager.serialize_plant_states()`.

## Save version

Increment:

```gdscript
SAVE_VERSION
```

from `5` to `6`.

Update the version comment:

```text
Version 6 adds authored bamboo maturity state.
Versions 1-5 remain accepted and default all authored bamboo to mature.
```

## Bamboo controller API

Add:

```gdscript
func serialize_state() -> Array[Dictionary]
func restore_state(saved_states: Array) -> void
```

Serialization rules:

- emit one entry for every current authored bamboo cell;
- include only stable state: `x`, `y`, `mature`;
- sort deterministically by Y then X;
- do not serialize visual transforms, animation phase, pickup timers, or slowdown.

Restoration rules:

1. begin from all current authored bamboo records mature;
2. apply saved entries only when their cell exists in the current level’s authored registry;
3. ignore unknown/stale cells with a warning;
4. ignore duplicate saved entries after the first valid one, with a warning;
5. update visuals immediately;
6. never create bamboo at a cell that is not authored by the current level;
7. old saves with no section leave all current authored bamboo mature.

## Manager façades

Add thin wrappers:

```gdscript
func serialize_bamboo_states_for_save() -> Array[Dictionary]
func restore_bamboo_states_from_save(saved_states: Array) -> void
```

No bamboo save transformation belongs in `BuildingManager`.

## Progression integration

Add focused helpers equivalent to:

```gdscript
func _get_bamboo_states(scene: Node) -> Array[Dictionary]
func _restore_bamboo_states(scene: Node, raw_states: Variant) -> void
```

During save:

```gdscript
"bamboo_states": bamboo_states
```

During load:

- restore authored layers and normal plants first;
- then restore bamboo state;
- do so before restored gameplay-phase signals are emitted.

Validate optional version-6 data:

- section must be an `Array`;
- every entry must be a `Dictionary`;
- required fields: `x`, `y`, `mature`;
- `mature` must be a bool;
- coordinates must be numeric.

Older save versions may omit the section.

Optionally add the bamboo-state count to existing save/debug summaries if it remains a small local change.

## Atomicity invariant

Because all five currency units are credited immediately before the bamboo becomes immature, saving during the visual flights must produce:

```text
bamboo currency:
    already includes all 5

bamboo state:
    immature
```

No pending bamboo reward needs to be serialized.

---

# Part K — BuildingManager wiring

Modify:

```text
scripts/map/building_manager.gd
```

Add a preload and typed controller member:

```gdscript
const BAMBOO_HARVEST_CONTROLLER_SCRIPT: Script = preload(...)
var _bamboo_harvest_controller: BambooHarvestController = BAMBOO_HARVEST_CONTROLLER_SCRIPT.new()
```

During `_ready()`:

1. set up `BuildingNavigationSyncService` first;
2. resolve level layers;
3. resolve `LevelLoader`;
4. resolve `GameUI`;
5. add the bamboo controller as a child under `Map`/`BuildingManager`;
6. call its explicit setup synchronously;
7. ensure this happens before `Progression._ready()` may call the restore façade.

Do not add bamboo pickup logic to `BuildingRuntimeTickController`.

The bamboo controller owns its own lightweight `0.06s` process cadence.

Add only the thin query/save methods required by build placement and progression.

---

# Expected files

New:

```text
scripts/map/bamboo_harvest_controller.gd
scripts/map/bamboo_plant_visual.gd
```

Expected modifications:

```text
scripts/map/level_loader.gd
scripts/map/building_manager.gd
scripts/map/building_navigation_sync_service.gd
scripts/map/buildsystem.gd
scripts/map/build_placement_service.gd
scripts/map/ground_drop_manager.gd
scripts/ui/generic_currency_icon.gd
scripts/ui/game_ui.gd
scripts/gameState/progression.gd
scripts/map/ARCHITECTURE.md
```

Inspect but do not alter authored positions without a specific need:

```text
scenes/levels/level_demo.tscn
```

Do not modify unrelated files.

Do not add a `.tscn` for bamboo visuals unless inspection shows the project’s current runtime visual convention clearly requires one. A focused scripted `Node2D` + child `Sprite2D` is sufficient.

---

# Required invariants

1. Every authored bamboo marker maps to at most one floor cell.
2. Bamboo defaults to mature on a fresh run.
3. Mature frame is `1`; immature frame is `0`.
4. The lower `32x32` half of each `32x64` frame occupies its tile.
5. Bamboo Y-sorts against agents.
6. Bamboo idle animation stays anchored at its planted base.
7. Harvest range exactly matches ground currency pickup range.
8. One harvest grants exactly `5` bamboo.
9. One maturity cycle can be harvested only once.
10. Currency grant and saved maturity transition are atomic.
11. A real dawn matures every bamboo.
12. Restored dawn signals do not mature bamboo a second time.
13. Bamboo slowdown is always `0.5`.
14. Maturity changes never touch slowdown.
15. Bamboo slows all native-steered agents without species branches.
16. Bamboo remains walkable.
17. Bamboo cells reject every buildable type and house footprint.
18. Bamboo is never registered as a removable/damageable object.
19. Bamboo never triggers a navigation, route, garden, or flow-field rebuild.
20. Old saves without bamboo state load with all authored bamboo mature.
21. Saved cells not authored in the current level never create new bamboo.
22. No duplicate bamboo inventory is introduced; existing bamboo currency is used.
23. No full feature logic is added to `BuildingManager`.
24. No Godot, test, compilation, SCons, export, or build command is run.

---

# Manual tests

Do not run these tests. Include them in the final report.

## 1. Authored loading

Open `level_demo`.

Expected:

- one bamboo per direct child of the level’s `bamboo` container;
- each appears on the marker’s derived floor cell;
- duplicate/invalid markers produce clear warnings rather than duplicate plants.

## 2. Fresh visual state

Start a fresh run.

Expected:

- all bamboo uses frame `1`;
- lower half aligns to the tile;
- upper half extends one tile upward;
- plants sway independently;
- no whole-garden synchronized movement.

## 3. Z ordering

Walk above and below a bamboo.

Expected:

- player above draws behind it;
- player below draws in front;
- no fixed-layer sorting error.

## 4. Harvest range

Approach bamboo at the same distance used to collect a gem.

Expected:

- collection triggers at the same radius;
- exact player-cell equality is not required;
- moving outside the radius does not harvest.

## 5. Harvest reward

Harvest one mature bamboo.

Expected:

- frame changes to `0` immediately;
- five bamboo icons fly to the bamboo HUD;
- bamboo currency increases by exactly `5`;
- staying on the tile grants nothing further.

## 6. Save during icon flight

Harvest and save immediately while icons are still flying.

Expected after load:

- all five bamboo currency are present;
- the harvested bamboo remains immature;
- no duplicate or lost reward.

## 7. Dawn regrowth

Harvest several plants, finish the night, enter dawn.

Expected:

- all authored bamboo returns to frame `1`;
- no currency is granted by regrowth;
- slowdown remains unchanged.

## 8. Save/load before dawn

Harvest bamboo during afternoon/night and save.

Expected after load:

- harvested plants remain immature;
- unharvested plants remain mature.

## 9. Save/load during dawn after harvesting

At dawn, harvest a bamboo, then save and reload while still in dawn.

Expected:

- restored phase signals do not remature it;
- it remains immature until the next real dawn.

## 10. Old save compatibility

Load a version `1-5` save with no `bamboo_states`.

Expected:

- load succeeds;
- every currently authored bamboo starts mature.

## 11. Slowdown

Walk the player and several agent kinds across bamboo cells.

Expected:

- movement on the cell is approximately `50%`;
- speed returns normally after leaving;
- mature and immature bamboo slow identically.

## 12. No navigation rebuild

Harvest and regrow bamboo while debug timing/logging is enabled.

Expected:

- no flow rebuild;
- no lazy-flow request;
- no A* recomputation;
- no garden topology rebuild;
- no route invalidation.

## 13. Build rejection

Try every relevant placement type on a bamboo cell:

- rose/plant;
- wall;
- fence;
- turret;
- counter;
- Kraken if surface permits;
- house with bamboo in any presence cell;
- drag placement;
- mouse and gamepad preview.

Expected:

- preview is invalid;
- no currency is spent;
- bamboo remains present.

## 14. Permanent world feature

Try removal, hostile attacks, trampling, explosions, tantrum attacks, and night monsters.

Expected:

- bamboo is unaffected;
- no health bar;
- no debris;
- no removal/refund;
- maturity changes only by harvest and dawn.

## 15. Zero-marker level

Load a level with no `bamboo` container.

Expected:

- no error;
- no bamboo processing cost beyond an inactive controller;
- all other gameplay remains unchanged.

## 16. Largest authored bamboo set

Use the largest practical marker count.

Expected:

- pickup checks remain lightweight at the existing `0.06s` cadence;
- no physics body per bamboo;
- no continuous save/nav work;
- no console spam.

---

# Architecture documentation

Update:

```text
scripts/map/ARCHITECTURE.md
```

Add a concise section:

## BambooHarvestController

Owns authored permanent bamboo cells, maturity, pickup, dawn regrowth, visuals, save state, and static terrain-speed registration.

## BambooPlantVisual

Owns only one bamboo’s frame, anchoring, dance, and Y sorting.

## LevelLoader

Captures root-level `bamboo` marker children into stable floor cells before freeing the authored level shell.

## BuildingNavigationSyncService

Owns generic static-world-feature terrain speed multipliers in addition to tile/placeable-derived speed.

## Build placement

Rejects permanent world-feature cells before actor-displacement logic.

Do not write a large design document.

---

# Final report

Report:

1. every changed and new file;
2. the actual discovered path and dimensions of `bamboo.png`;
3. how authored marker positions are converted to cells;
4. duplicate/invalid marker handling;
5. exact sprite anchoring math;
6. exact dance values;
7. exact pickup radius reuse;
8. exact harvest amount and atomic currency flow;
9. where maturity is assigned on fresh load, harvest, dawn, and save restore;
10. save version and backward compatibility;
11. how restored dawn signals are ignored;
12. how static `0.5` slowdown is registered and combined with existing multipliers;
13. how every build type is rejected on bamboo cells;
14. confirmation that bamboo is absent from damage/removal/trampling systems;
15. confirmation that no flow/A*/garden rebuild occurs on harvest or regrowth;
16. any current-codebase mismatch, especially missing authored markers or asset;
17. complete manual-test checklist;
18. confirmation that no Godot, tests, compilation, SCons, export, or build command was run.

Do not claim runtime correctness because runtime testing is performed manually by the user.
