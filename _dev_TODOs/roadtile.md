# Task: Generic terrain movement multipliers + Road buildable

Read `AGENTS.md` completely before making changes.

Implement a clean, generic **terrain movement multiplier system covering both slow tiles and fast tiles**, then add the new **Road** buildable through that system.

This is a regression-sensitive task.

## Critical behavior constraint

Apart from the new Road tile becoming available, **current game behavior must remain unchanged**.

In particular:

* existing slowdown tiles must produce exactly the same movement behavior as before;
* bamboo slowdown must remain unchanged;
* player and non-player agent behavior must remain unchanged;
* no navigation, flow-field, steering, collision, or build-placement behavior should change unintentionally;
* do not reinterpret or rebalance existing multiplier values;
* do not modify existing save data semantics unless required for Road;
* do not introduce new per-frame work.

Treat the generic terrain-speed refactor as an internal implementation cleanup, not as a gameplay redesign.

---

# Part 1 — Generic terrain movement multiplier system

## Objective

There must be one authoritative system for terrain-based movement multipliers.

It must support:

* slowdown values below `1.0`;
* neutral value `1.0`;
* speed-up values above `1.0`;
* static level-authored modifiers;
* dynamically added and removed modifiers;
* single-cell updates;
* efficient batch updates;
* different applicability channels if the current project already supports them, such as player versus other agents.

Road must not create a separate fast-tile system.

Existing slowdown terrain and Road must use the same generic API and runtime index.

---

## No runtime TileMap scanning

Do not scan the entire `floor`, `floorz`, or any other TileMapLayer when a Road is built or removed.

The runtime system must maintain an indexed representation of non-neutral terrain modifiers.

Conceptually:

```gdscript
cell -> modifier sources -> effective multiplier
```

Neutral cells should normally have no runtime entry:

```text
missing entry = multiplier 1.0
```

Examples of modifier sources:

```text
road
bamboo
level_slow_terrain
future_temporary_effect
```

The precise data structures and names should follow the existing architecture.

Do not create a new TileMapLayer merely to store speed values. A TileMapLayer is not needed for this runtime index.

---

## Source-aware modifiers

Prefer storing modifiers by source rather than storing only the final multiplier.

Conceptually:

```text
cell (20, 15):
    bamboo = 0.5
    road = 1.5
```

This matters because removing one source must reveal any remaining modifier rather than blindly restoring `1.0`.

Required generic operations should be equivalent to:

```gdscript
set_cell_modifier(source_id, cell, multiplier, applicability)
set_cells_modifier(source_id, cells, multiplier, applicability)

remove_cell_modifier(source_id, cell, applicability)
remove_cells_modifier(source_id, cells, applicability)
```

Names and signatures may follow the project’s conventions.

Provide typed single-cell and batch APIs.

Do not expose mutable internal dictionaries to callers.

---

## Multiplier composition rule

Fix any current code that assumes all terrain modifiers are slowdowns.

The generic composition semantics must be:

1. If one or more slowdown modifiers below `1.0` apply, use the strongest slowdown.
2. Otherwise, if one or more speed-up modifiers above `1.0` apply, use the strongest speed-up.
3. Otherwise, use `1.0`.

Examples:

```text
1.0 + 1.5 -> 1.5
1.2 + 1.5 -> 1.5
1.5 + 0.8 -> 0.8
0.8 + 0.6 -> 0.6
1.0 + 1.0 -> 1.0
```

A slowdown takes priority over a speed-up when both affect the same cell.

Centralize this rule in one authoritative helper. Do not duplicate it in multiple services.

Inspect all existing terrain-speed composition paths. Replace any logic equivalent to:

```gdscript
minf(1.0, multiplier)
```

when that logic would discard values above `1.0`.

Be especially careful around any separate player and default-agent terrain channels.

---

## Preserve current slowdown behavior

Migrate existing slow-terrain registration to the generic API only where necessary.

Do not alter:

* the cells currently considered slow;
* their multiplier values;
* which agent groups they affect;
* when their state is initialized;
* existing bamboo behavior;
* any agent-specific applicability already implemented.

Static level terrain may be indexed once during controlled level initialization.

Dynamic gameplay changes must be incremental.

Do not repeatedly rediscover static slow tiles during gameplay.

---

## Native/runtime synchronization

Only upload cells whose effective multiplier actually changed.

For a batch operation:

1. update the indexed modifier sources;
2. resolve effective multipliers for affected cells;
3. discard cells whose effective result did not change;
4. send the remaining changed cells through one batch native update when supported.

Do not upload once per Road tile during drag placement.

Do not iterate over agents when terrain changes. Agents should continue sampling the shared terrain-speed data through the current movement path.

---

## No flow-field rebuild

Terrain movement multiplier changes must not trigger:

* hard-topology invalidation;
* global flow-field recomputation;
* garden route recomputation;
* asynchronous wall-style rebuilds;
* agent retargeting;
* navigation progress UI.

Road does not change traversability or topology.

Do not show the wall lazy-recompute progress bar for Road.

The operation is incremental and proportional to the number of changed cells.

---

# Part 2 — Road buildable

## Road definition

Add the following buildable:

```text
ID: road
English name: Road
Icon: items.png frame 30, zero-based
Cost: 10 gems per tile
Floor atlas coordinate: Vector2i(8, 12)
Movement multiplier: 1.5
```

It must appear in the hammer/build slot.

Add it to all currently active item availability/configuration paths required by the project.

Do not accidentally modify blueprint unlock behavior or make unrelated items available.

---

## Placement behavior

Road is a floor replacement.

It directly changes the existing floor TileMapLayer tile.

It is not:

* a building entity;
* a wall;
* a traversable building;
* a destructible object;
* a collision object;
* a sprite overlay;
* a navigation obstacle.

It can be placed only on:

* dry grass;
* wet grass.

It cannot be placed on:

* another Road;
* a non-grass floor;
* an occupied building/plant/wall/fence/counter/house cell;
* any cell rejected by existing generic build validation.

Other buildables should not subsequently be placeable on top of Road unless the existing project has an explicit generic rule allowing floor replacements under buildings. Default to requiring Road removal first.

Keep this rule centralized in build validation. Do not scatter Road-specific checks across every buildable.

---

## Drag building

Road must use the same draggable placement workflow as roses:

* drag to select/place multiple cells;
* keep Road selected after successful placement;
* continue building until cancellation;
* stop when the player cannot afford another Road tile;
* charge 10 gems per successfully committed cell;
* never charge for a rejected or failed cell.

Reuse the existing generic draggable-preview system rather than implementing a Road-specific drag controller.

For a drag operation:

* validate candidate cells;
* commit valid affordable cells;
* update the TileMap in a batch where possible;
* update autotiling in a batch;
* register terrain multipliers in a batch;
* perform one native terrain-speed batch upload.

Avoid per-cell redraws and per-cell native calls.

---

## Terrain-speed integration

When Road placement succeeds:

```text
Road source multiplier = 1.5
Applicability = all agents
```

This includes:

* player;
* monsters;
* big monsters;
* clients;
* villagers;
* builders;
* future agents using the standard terrain movement channel.

Do not add Road checks inside player, monster, client, villager, steering, or movement scripts.

The movement effect must come exclusively from the generic terrain movement multiplier system.

Road placement complexity should be proportional to the number of placed Road cells:

```text
O(changed cells)
```

No full map scan.

---

# Part 3 — Road underlay and removal

## Hidden grass underlay

Because Road replaces the visible floor tile, retain enough semantic data to restore the correct terrain when Road is removed.

For every Road cell, track whether the hidden floor underneath is:

* dry grass;
* wet grass.

Do not infer the underlay by scanning the map during removal because the visible tile is now Road.

A focused floor-replacement registry/service should own:

* active Road cells;
* the Road item ID at each cell;
* hidden dry/wet underlay state;
* placement registration;
* removal registration;
* save/load serialization;
* queries needed by build validation and irrigation.

Do not place this loose state directly into a large manager if a focused service is cleaner.

---

## Unbuild behavior

Road must be removable with the normal unbuild tool.

On removal:

1. identify the indexed Road entry;
2. remove the Road modifier source from the terrain-speed system;
3. restore the correct dry or wet grass;
4. update nearby grass autotiling where required;
5. refund according to the project’s normal unbuild/refund rules;
6. batch terrain-speed/native changes when several cells are removed together.

Do not blindly set the terrain multiplier to `1.0`.

Remove only the `road` modifier source and let the generic system resolve any remaining terrain modifier.

---

## Wet-grass restoration

Do not save and restore a stale wet-grass edge atlas coordinate.

Store the semantic state as wet versus dry.

When restoring wet grass:

* restore the project’s canonical wet-grass base tile;
* invoke the existing grass autotile/beautification system;
* refresh affected neighboring cells in one batch.

When restoring dry grass:

* use the authoritative dry-grass tile definition already used by the project.

Do not duplicate grass atlas lists in the Road implementation.

---

## Irrigation changes under Road

A Road may cover a cell whose hidden grass changes between dry and wet due to reservoirs.

The visible tile must remain Road, but the hidden underlay state must stay correct.

Integrate this through a narrow public API.

Required behavior:

* if irrigation reaches a Road cell, mark its hidden underlay as wet;
* if irrigation leaves a Road cell, mark its hidden underlay as dry;
* do not visually replace the Road;
* do not apply wet-grass visuals until Road is removed;
* ordinary uncovered grass irrigation must behave exactly as before.

The reservoir system must not directly mutate the Road registry’s internal dictionary.

Do not broaden or refactor reservoir behavior beyond what is necessary for this compatibility.

---

# Part 4 — Save/load

Road state must survive save and reload.

Save at least:

```text
cell
item ID / replacement kind
hidden underlay state: dry or wet
```

On load:

1. restore the visible Road tile;
2. restore the Road registry/index;
3. restore its `1.5` terrain modifier through the generic API;
4. batch native terrain-speed synchronization;
5. avoid triggering flow-field recomputation.

Maintain compatibility with existing saves that contain no Road data.

Do not require migration for old saves beyond treating missing Road data as an empty Road list.

Do not serialize the entire terrain-speed runtime index if it can be rebuilt from existing semantic sources such as Road and bamboo state.

---

# Part 5 — Regression protection

This task must not change current gameplay except for adding Road.

Before editing, identify all existing terrain-speed producers and consumers.

At minimum, verify:

* existing static slowdown terrain;
* bamboo slowdown;
* player terrain speed;
* monster/client/villager terrain speed;
* level-load initialization;
* savegame restoration;
* any default-agent versus player multiplier channels;
* build placement occupancy;
* grass irrigation;
* unbuild refunds.

Do not perform broad cleanup unrelated to this feature.

Avoid changing public APIs unnecessarily. When an existing API must change, update all call sites in the same patch.

Do not leave parallel old and new terrain-speed systems active at the same time.

Do not add compatibility fallbacks that silently scan TileMaps during gameplay.

---

# Required manual regression checks

Report the exact code paths changed and provide a manual test checklist covering:

## Existing behavior

1. Start a fresh game without building Road.
2. Confirm existing slowdown terrain behaves exactly as before.
3. Confirm bamboo still slows the same agents by the same amount.
4. Confirm normal grass still gives neutral speed.
5. Confirm player, clients, villagers, normal monsters, and big monsters retain their current movement behavior.
6. Confirm no new navigation rebuild or progress bar appears from existing terrain-speed changes.
7. Confirm old savegames without Road still load normally.

## Road placement

1. Road appears in the hammer menu with `items.png` frame 30.
2. It costs exactly 10 gems per tile.
3. It can be placed on dry grass.
4. It can be placed on wet grass.
5. It cannot be placed on invalid floors.
6. It cannot overwrite occupied buildable cells.
7. Drag placement works like roses.
8. Road stays selected after placement.
9. Only successfully placed cells are charged.
10. Large drag placement performs one batched terrain-speed update rather than one upload per tile.

## Movement

1. Player speed increases by 50% while on Road.
2. Client speed increases by 50%.
3. Villager/builder speed increases by 50%.
4. Monster speed increases by 50%.
5. Big monster speed increases by 50%.
6. Speed returns immediately to the normal value after leaving Road.
7. No agent-specific Road branch exists in movement code.
8. No flow-field rebuild occurs when placing or removing Road.

## Removal and terrain restoration

1. Removing Road restores dry grass when its hidden underlay is dry.
2. Removing Road restores wet grass when its hidden underlay is wet.
3. Wet-grass borders/corners are correctly regenerated.
4. Refund behavior matches normal unbuild rules.
5. Removing Road removes only the Road terrain modifier.
6. Removing several Road cells batches speed updates.

## Irrigation

1. Build Road over dry grass.
2. Extend irrigation beneath it.
3. Remove Road and confirm wet grass appears.
4. Build Road over wet grass.
5. Remove irrigation beneath it.
6. Remove Road and confirm dry grass appears.
7. Confirm Road remains visually unchanged while irrigation changes beneath it.

## Save/load

1. Save with Roads on dry and wet underlays.
2. Reload.
3. Confirm Road visuals remain.
4. Confirm `1.5` movement speed remains.
5. Remove each Road and confirm the correct underlay is restored.
6. Confirm no flow-field recompute is incorrectly triggered during load.

---

# Performance requirements

The final implementation must have:

* no new `_process()` or `_physics_process()` terrain scans;
* no runtime whole-floor scans for Road placement/removal;
* no per-agent update when a Road changes;
* no flow-field invalidation from Road;
* no per-cell native upload during drag operations;
* no redundant upload when a cell’s effective multiplier remains unchanged;
* no duplicate Road-specific movement implementation;
* no new TileMapLayer unless inspection reveals a concrete architectural requirement and this is reported before using it.

---

# Final report

After implementation, report:

1. files changed;
2. the authoritative owner of terrain movement modifiers;
3. the runtime index structure;
4. how multiplier conflicts are resolved;
5. how existing slowdown behavior was preserved;
6. how Road placement/removal performs incremental updates;
7. how Road underlays and irrigation are handled;
8. how save/load works;
9. any regression risk found;
10. the manual tests still required.

Also report any existing non-generic, duplicated, or performance-risky terrain-speed code encountered during the task, but do not expand the scope to unrelated refactors without explicit approval.
