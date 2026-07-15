# Remove autosaves and eliminate rose-harvest frame hitches

Read `AGENTS.md` and `ARCHITECTURE.md` first.

Do not run Godot, tests, builds, exports, or compilation. I will test manually.

## Objective

Make rose harvesting allocation-light and free of synchronous global rebuilds.

Also hard-remove the entire autosave feature for now. Manual F5/F9 save/load must remain fully functional.

Do not merely hide the autosave option or add another guard. Remove the runtime autosave system and its dead compatibility wiring.

---

## Verified current situation

### Autosave

The in-game autosave option is disabled, so `progression.auto_save()` currently returns before serialization. Therefore, autosave is not the current harvest hitch.

However, obsolete autosave calls, UI, state flags and comments remain throughout the project and must be removed.

### Counter bouquet

`CounterStockManager.set_stock()` calls `rebuild_pile()` on every stock mutation.

`rebuild_pile()` currently:

1. queues every existing bouquet sprite for deletion;
2. creates every bouquet sprite again;
3. performs deferred scene-tree insertion.

Adding roses from stock 0 to 10 therefore creates 55 bouquet sprites instead of 10.

This scene-tree churn occurs during harvesting and must be eliminated.

### Counter topology

`BuildingManager.notify_counter_stock_changed()` performs a synchronous:

```gdscript
_rebuild_plant_zone_from_layer()
```

when counter stock changes from `0` to positive.

This means the first harvested rose placed into an empty counter can synchronously rebuild the complete garden topology, route caches and retargeting state.

Counters are also still partially represented as monster-edible garden content even though the monster counter-eating mechanic is supposed to be gone.

---

# Part 1 — Hard-remove autosaves

Preserve only the manual save slot:

```text
user://progression_save.json
```

Manual F5 save and F9 load must work exactly as before.

Remove all runtime support for:

```text
user://progression_autosave.json
```

## Required cleanup

### `scripts/gameState/progression.gd`

Remove:

* `AUTOSAVE_PATH`;
* `auto_save()`;
* `auto_save_after_rose_growth()`;
* startup autosave loading;
* autosave deletion during reset;
* autosave-specific comments and logs.

Manual pending-load application in `_ready()` must remain. F9 loading already uses this path and must not be broken.

`reset_game()` must simply reset transient run state and reload a fresh scene. It must not delete or overwrite the manual F5 save.

Update `_save_applied` comments so they refer only to manual save restoration.

Remove `load_on_start()` if it has no remaining responsibility after autosave removal.

### `scripts/map/dawn_harvest_controller.gd`

Remove:

```gdscript
_manager.auto_save_after_rose_harvest()
```

### `scripts/map/building_manager.gd`

Remove the `auto_save_after_rose_harvest()` façade wrapper.

### `scripts/map/plant_manager.gd`

After delayed dawn growth completes, directly continue the dawn sequence:

```gdscript
new_day_finished.emit()
day_seed_harvest_finished.emit()
```

Do not gate dawn progression on a save operation.

Remove autosave-specific logs and method checks.

Keep the existing stale-day and stale-night guards.

### `scripts/misc/cpp_debug_options.gd`

Remove:

* static `auto_save_enabled`;
* exported `enable_auto_save`;
* associated setup propagation;
* autosave-related comments.

### `scripts/gameState/gameState.gd`

Remove:

* `SKIP_STARTUP_AUTOSAVE_META`;
* `skip_startup_autosave_once()`;
* `consume_skip_startup_autosave()`.

The existing method also resets unrelated fresh-run state. Preserve those required behaviors explicitly at its former call sites using the existing:

```gdscript
GameState.reset_special_reward_claims()
GameState.reset_transient_run_state()
```

Do not retain an autosave-named method for unrelated state reset.

### UI and restart paths

Clean autosave references from:

* `scripts/ui/level_loader_menu.gd`;
* `scripts/ui/menus.gd`;
* `scripts/ui/game_over_modal.gd`;
* `scripts/ui/victory_modal.gd`;
* any other runtime script or scene found by search.

Specific behavior:

* remove “Reload autosave” from the level loader;
* retain manual-save loading;
* remove the `load_on_start()` call from `menus.gd`;
* replace misleading quit text such as “Progress will be saved” with wording that does not promise a save;
* replace reset text claiming it erases the save, because the manual save must remain untouched;
* restart, level selection, game over and victory must still reset the required transient/fresh-run state.

After this cleanup, searching runtime scripts and scenes for these terms should produce no functional autosave code:

```text
auto_save
autosave
AUTOSAVE
progression_autosave
skip_startup_autosave
```

Do not remove or redesign the normal save serialization format.

---

# Part 2 — Make counter bouquet updates allocation-free

Ownership remains in:

```text
scripts/map/counter_stock_manager.gd
```

Do not move bouquet rendering into `BuildingManager`.

## Required design

Each physical rose counter must own a fixed set of 10 reusable bouquet slot sprites.

Use the existing ten offsets in:

```gdscript
COUNTER_BOUQUET_SLOT_OFFSETS
```

### Counter registration

Add a clear counter lifecycle API, for example:

```gdscript
register_counter(counter_cell: Vector2i) -> void
unregister_counter(counter_cell: Vector2i) -> void
```

Use the existing counter placement/removal/scan pathways to register and unregister counters.

On registration:

* create exactly `MAX_STOCK_PER_COUNTER` sprites once;
* configure their texture, frame, scale, position and z-index once;
* add them to the scene tree;
* start them hidden.

Existing counters discovered during level loading or save restoration must also be registered before gameplay harvesting.

On counter destruction/removal:

* free its ten persistent sprites once;
* remove its stock state;
* clean all references.

Do not create the ten nodes during the actual harvest operation when a clean counter-created or preload hook is available.

### Stock mutation

Replace `rebuild_pile()` with an incremental visibility synchronization.

Changing stock from `previous` to `value` must only:

* update `_stock_by_cell`;
* show newly occupied slots;
* hide newly emptied slots.

For example:

* `4 -> 5`: show slot 4 only;
* `5 -> 4`: hide slot 4 only;
* `0 -> 10` during restore: show the ten existing slots;
* `10 -> 0`: hide the ten existing slots.

Ordinary `set_stock()` and `add_stock()` must not call:

* `Sprite2D.new()`;
* `queue_free()`;
* deferred `add_child`;
* a complete bouquet reconstruction.

Preserve the exact bouquet offsets, scale, texture frame and visual layering.

### Restore and clear

Save/load behavior must remain unchanged logically.

Restoring counter stock must synchronize visibility on already registered slots without recreating the bouquet.

`clear()` and level teardown must correctly free registered slot nodes.

### Nightfall dissolve

Preserve the existing three-second reverse bouquet dissolve and rose-seed refund behavior.

Adapt it to persistent slots:

* immediately clear logical stock as before;
* progressively hide the visible slots in reverse order;
* refund from the corresponding slot’s world position;
* do not detach or destroy persistent bouquet sprites;
* leave all slots hidden and ready for reuse afterward.

Counter destruction during or after dissolve must remain safe.

### Transient flight sprites

Do not create an elaborate generic object-pooling framework for the single flying rose animation unless telemetry proves it significant.

One temporary flight sprite and Tween per harvested or sold rose is acceptable for now.

The persistent counter bouquet is the important allocation fix.

---

# Part 3 — Remove stock changes from garden-topology rebuilding

Counter stock must be runtime content state, not navigation topology.

Changing a counter between empty and stocked must never rebuild the complete plant zone.

## Stable client-only counter access cells

Keep counter access cells available as stable client target points based on the existence of the physical counter, not on whether its stock is currently positive.

Currently, counter access collection is based on `stocked_counter_cells()`.

Change this so access cells are generated from all physical rose counters:

```gdscript
rose_shop_counter_cells()
```

This allows counter access geometry to be established when the counter is built or when topology is initially prepared.

Stock availability must remain a dynamic check:

```gdscript
stock(counter_cell) > 0
```

Therefore:

* building/removing a counter may legitimately invalidate topology;
* adding or removing a rose from an existing counter must not.

## `BuildingManager.notify_counter_stock_changed()`

Remove the synchronous `0 -> positive` call to:

```gdscript
_rebuild_plant_zone_from_layer()
```

A stock mutation should normally only:

* emit `counter_stock_changed`;
* update the counter visual;
* update lightweight client-sale state if required.

It must not rebuild gardens, flow fields, route caches or all-agent targeting.

Remove `mark_counter_stock_restored_for_navigation()` if restoration no longer requires topology invalidation.

## Counters are not monster food

Audit and remove the obsolete monster-counter consumption path.

Relevant current code includes:

* counter handling in `AgentNavigationPhaseController.process_plant_arrivals()`;
* `BuildingManager._consume_counter_rose()`;
* `BuildingManager.start_agent_eating_counter_rose()`;
* `CounterStockManager.consume_counter_rose()`;
* `GardenTopologyService.is_eatable_for_monster()` counter handling;
* comments and conditions treating a stocked counter as an edible monster garden.

Required behavior:

* monsters never select a counter access cell as food;
* monsters never eat or reduce counter stock;
* stocked counters do not keep a monster night alive;
* an empty or stocked counter is irrelevant to monster edible-target counts;
* client agents can still find stocked counters and buy roses normally;
* clients must not target empty counters as valid sale targets.

Counter access cells may remain represented in garden route geometry for clients, but they must be explicitly client-only targets.

Do not implement a second parallel general navigation framework. Use the smallest clean change that preserves existing client garden and counter routing.

---

# Part 4 — Add focused harvest telemetry

Telemetry ownership belongs in:

```text
scripts/map/building_debug_telemetry.gd
```

Do not scatter unconditional `print()` calls through gameplay code.

Add a dedicated debug option in `CppDebugOptions`, default disabled, such as:

```gdscript
@export var debug_rose_harvest_telemetry: bool = false
```

Optionally add a warning threshold, default around `1.0 ms` or `2.0 ms`.

Use `Time.get_ticks_usec()`.

## Measure these synchronous spans

For one regular rose harvest, record:

* target-counter lookup;
* plant removal;
* counter stock mutation;
* bouquet visibility synchronization;
* counter-stock notification;
* flight animation setup;
* `check_finished()`;
* complete harvest call.

Also record diagnostic facts:

* frame number;
* rose cell;
* counter cell;
* stock transition, such as `0 -> 1`;
* bouquet sprites created during this harvest;
* bouquet sprites freed during this harvest;
* whether any topology rebuild or navigation invalidation was requested;
* total duration.

The optimized harvest must report:

```text
bouquet_created=0
bouquet_freed=0
topology_rebuild=false
```

during normal harvesting.

Use one compact log line, for example:

```text
[HARVEST_PERF] frame=1234 total=0.42ms lookup=0.03 plant=0.08 stock=0.05 pile=0.01 notify=0.01 flight=0.12 finish=0.12 stock_change=4->5 created=0 freed=0 topology_rebuild=false
```

When telemetry is disabled, its runtime overhead should be negligible.

Do not generate multiple log lines for one harvest. Logging itself must not become the hitch.

Existing broad garden-lag telemetry may be reused where appropriate, but the harvest breakdown must remain identifiable and compact.

---

# Plant-removal invalidation

The existing plant-layout invalidation appears to be deferred and coalesced when runtime agents are inactive.

Do not replace it with a synchronous rebuild.

Instrument it through the harvest telemetry, but only change it if inspection proves that one harvested plant still performs substantial synchronous topology work.

Repeated rose harvesting must result in at most one coalesced deferred plant-layout rebuild after the existing quiet period, not one rebuild per rose.

Do not broaden this task into a full garden-navigation refactor.

---

# Acceptance criteria

## Autosave

* No autosave file is written.
* No autosave file is loaded.
* No autosave UI choice exists.
* No harvest or dawn-growth code calls a save operation.
* Manual F5 save still uses `progression_save.json`.
* Manual F9 load still restores the manual save.
* Restarting a run does not delete the manual save.
* Dawn growth continues normally without waiting for a save result.

## Harvest performance

During ordinary harvesting:

* no existing bouquet sprites are destroyed;
* no bouquet sprites are created;
* no deferred bouquet node insertion occurs;
* no full garden rebuild occurs on counter `0 -> 1`;
* no flow-field or global route rebuild is caused solely by counter stock;
* the bouquet still has the same compact ten-rose layout;
* the rose flight animation still works;
* counter save/load visuals remain correct;
* nightfall dissolve and refunds remain correct.

## Agent behavior

* clients still buy stocked counter roses;
* clients do not buy from empty counters;
* monsters never target or consume counter roses;
* counter stock does not affect monster night completion;
* constructing or destroying a counter still updates navigation correctly.

## Code quality

* strict GDScript typing;
* no new gameplay responsibility added to `BuildingManager`;
* no broad speculative framework;
* no dead autosave compatibility wrappers;
* no hidden per-harvest allocations;
* no unconditional performance logging.

---

# Final report

Report:

1. the exact autosave files, methods and UI wiring removed;
2. the final owner and lifecycle of persistent bouquet slots;
3. how counter access remains available to clients without stock-triggered topology rebuilds;
4. all obsolete monster-counter code removed;
5. the exact harvest telemetry line and debug option;
6. files changed;
7. manual test checklist;
8. anything that could not be completed safely.

Do not claim performance improvement solely from inspection. Explain the structural allocations and rebuilds removed, and leave the telemetry available for manual confirmation.
