# Refactor and clean the native terrain speed-modifier system

Read `AGENTS.md` and the relevant `ARCHITECTURE.md` files before editing.

Do not run Godot, builds, exports, or tests. I will test the project.

## Objective

Refactor the current “slowdown tile” implementation into a clean, generic **terrain speed multiplier system**.

It must support:

* slowdown tiles with multipliers below `1.0`;
* neutral tiles at `1.0`;
* future speed-up tiles with multipliers above `1.0`;
* immediate single-cell runtime updates;
* efficient batch updates;
* efficient full replacement during preload, load, or large resynchronization;
* agent categories/channels without hardcoded gameplay concepts such as `player`, `monster`, `rose`, or `water`;
* no flow-field rebuild when only terrain speed changes.

This system controls **physical movement speed only**.

It must not modify flow-field routing costs in this task.

---

# Verified current situation

The current implementation has two partially overlapping systems:

1. A shared absolute-cell terrain-speed map used by `SteeringSystem`.
2. A redundant `speed_multipliers` array stored inside every `FlowField`.

Actual movement reads the shared steering-side map.

The per-flow-field speed arrays are copied into synchronous and asynchronous flow fields, but Dijkstra does not use them. Flow-field cost still uses normal cardinal/diagonal movement costs only.

Therefore, the field-local slowdown data currently creates:

* unnecessary flow-field memory;
* unnecessary snapshot data;
* unnecessary async worker writes;
* unnecessary `FlowField::copy_from()` work;
* misleading comments claiming slowdown affects routing;
* two competing “sources of truth.”

The public API is also currently exposed through `FlowFieldNative`, even though terrain speed is a steering/movement concern.

Some GDScript systems update terrain speed one cell at a time, including during initial synchronization, and some slowdown sources bypass the main composition path.

There is also gameplay-specific C++ behavior resembling:

```cpp
all_multiplier
player_multiplier
```

or selection based on a player-specific profile property.

That must become generic.

---

# Required architecture

## 1. One authoritative native terrain-speed grid

Create one authoritative terrain-speed store in the native movement/steering domain.

Preferred ownership:

```text
SteeringSystem
└── TerrainSpeedGrid
```

A focused `TerrainSpeedGrid` class in dedicated `.h/.cpp` files is preferred if putting all logic directly into `SteeringSystem` would mix responsibilities or significantly expand an existing large file.

The terrain-speed grid must be independent from individual `FlowField` objects.

Use absolute navigation/world cell coordinates, consistent with the coordinates currently used by movement lookup.

The default value for any absent cell/channel must be:

```text
1.0
```

Store only non-neutral entries so the structure remains sparse.

Setting a cell back to `1.0` must erase the corresponding sparse entry rather than storing an explicit neutral value.

---

## 2. Generic terrain-speed channels

Remove hardcoded native concepts such as:

* `player_multiplier`;
* `all_multiplier`;
* checking whether an agent is “the player”;
* gameplay-specific terrain names or agent types.

Replace them with generic integer terrain-speed channels.

Required behavior:

```text
channel 0 = default terrain-speed channel
```

Each native agent movement profile must contain a terrain-speed channel ID.

Lookup behavior:

1. Look for a value for the agent’s selected channel on the current cell.
2. If no channel-specific value exists, fall back to channel `0`.
3. If channel `0` also has no value, use `1.0`.

Example:

```text
Cell default channel: 0.5
Cell channel 1:       1.0

Normal agent using channel 0 -> 0.5 movement speed
Agent using channel 1        -> 1.0 movement speed
```

GDScript decides which gameplay entity uses which channel.

The C++ side must not know what channel `1`, `2`, etc. represent.

Preserve the current player-versus-other-agent behavior by migrating it to channels rather than deleting it.

Do not introduce an unnecessarily large per-cell structure. Use an efficient sparse representation appropriate for the expected small number of channels.

---

# Public native API

Terrain-speed methods must no longer conceptually belong to `FlowFieldNative`.

Expose them through:

* the existing steering native façade, if the project already has one suitable for public bindings; or
* a small focused terrain-speed native façade if no appropriate steering façade exists.

Do not create a new general gameplay manager.

Suggested public API:

```gdscript
set_terrain_speed_cell(
    cell: Vector2i,
    multiplier: float,
    channel: int = 0
) -> void
```

```gdscript
set_terrain_speed_cells(
    cells: PackedVector2Array,
    multipliers: PackedFloat32Array,
    channel: int = 0
) -> void
```

```gdscript
clear_terrain_speed_cell(
    cell: Vector2i,
    channel: int = 0
) -> void
```

```gdscript
clear_terrain_speed_cells(
    cells: PackedVector2Array,
    channel: int = 0
) -> void
```

```gdscript
replace_terrain_speed_channel(
    cells: PackedVector2Array,
    multipliers: PackedFloat32Array,
    channel: int = 0
) -> void
```

```gdscript
clear_terrain_speed_channel(
    channel: int = 0
) -> void
```

Exact naming may follow existing project conventions, but all of these capabilities are required.

## API semantics

### Single-cell update

Use for isolated runtime changes.

It must update movement behavior immediately.

### Batch update

Use when several cells change together.

It must cross the Godot-to-C++ boundary once for the batch, not once per tile.

### Replace channel

Use during:

* level preload;
* map initialization;
* savegame restoration;
* full terrain-speed resynchronization.

It must efficiently replace the complete sparse state of one channel without requiring:

```text
clear everything
+ one native call per cell
```

Validate batch array lengths before applying them.

Do not use Dictionaries, nested Variants, or one Variant allocation per cell in the native hot path when packed arrays or another compact representation is available.

---

# Multiplier rules

The implementation must support both slowdown and speed-up values.

Required interpretation:

```text
multiplier < 1.0  -> slowdown
multiplier = 1.0  -> neutral
multiplier > 1.0  -> speed-up
```

Do not clamp valid values to a maximum of `1.0`.

Reject or safely handle:

* zero;
* negative values;
* NaN;
* infinity;
* invalid channel IDs;
* mismatched batch lengths.

Define centralized native constants for safe minimum and maximum terrain-speed multipliers.

A reasonable initial safe range is:

```text
0.05 to 4.0
```

Do not scatter these limits through multiple files.

Values outside the supported range may be clamped or rejected consistently, but the behavior must be explicit and documented.

A multiplier of `1.0` must remove the sparse entry.

---

# Movement integration

Continue applying the terrain multiplier during the existing movement integration path.

Requirements:

* preserve the current steering, avoidance, separation, and collision behavior;
* do not apply the multiplier twice;
* ensure values above `1.0` are not accidentally limited back to `1.0`;
* ensure channel lookup is not performed through gameplay-specific branches;
* keep the lookup cheap enough for hundreds of agents per frame;
* avoid per-frame allocations;
* avoid repeated world-to-cell conversions if the current cell is already known.

Do not redesign steering behavior in this task.

Do not compensate for speed-up values by changing acceleration, avoidance, or collision tuning unless a concrete implementation bug requires it.

---

# Remove terrain speed from flow fields

Completely remove the obsolete field-local speed system.

Audit and remove all related state and methods, including equivalents of:

```cpp
FlowField::speed_multipliers
FlowField::set_cell_speed_multiplier(...)
FlowField::cell_speed_multiplier(...)
FlowField::apply_cell_speed_modifiers(...)
```

Also remove terrain-speed data from:

* synchronous field construction;
* async field snapshots;
* async worker results;
* field registration;
* `FlowField::copy_from()`;
* field replacement;
* global lazy rebuild preparation;
* flow-field serialization or temporary buffers, if present.

The async flow-field worker must not receive terrain-speed data.

A general lazy flow-field rebuild must not copy, snapshot, clear, reseed, or replace terrain-speed state.

Terrain speed and flow-field lifetime must be fully independent.

After migration, there must be exactly one native source of truth for terrain movement multipliers.

---

# Remove obsolete `FlowFieldNative` ownership

Find every caller of the current methods resembling:

```gdscript
FlowFieldNative.set_cell_speed_multiplier(...)
FlowFieldNative.clear_cell_speed_multipliers(...)
```

Migrate them to the new steering/terrain-speed API.

Once all call sites are migrated:

* remove the old public methods from `FlowFieldNative`;
* remove obsolete native backing maps;
* remove forwarding calls into `SteeringSystem`;
* remove obsolete bindings;
* remove misleading comments.

Do not keep two public APIs indefinitely.

A temporary internal compatibility wrapper is acceptable only if required to perform the migration safely within the same patch, but it must be removed before completing the task.

---

# GDScript ownership and composition

Create or identify one focused GDScript owner responsible for producing the final native terrain-speed values.

Suggested responsibility:

```text
TerrainSpeedModifierService
```

Use the project’s existing naming and service architecture when an appropriate owner already exists.

This owner must:

* collect terrain-speed contributions;
* convert world positions to absolute navigation cells;
* compute the effective final multiplier;
* send single or batch changes to C++;
* rebuild native terrain-speed state during preload/load;
* remove native values when sources disappear;
* prevent unrelated gameplay controllers from directly writing native terrain speed.

Controllers such as sheep, buildings, plants, water, bamboo, fences, or map initialization must register/update their terrain effects through this service rather than directly calling the native API.

Do not make `BuildingManager` or another large manager own this new domain.

If implementation would add more than approximately 150 lines to one existing file, split the responsibility into a dedicated file according to `AGENTS.md`.

---

# GDScript contribution policy

Preserve the current gameplay behavior for existing slowdown sources.

For multiple active contributions on one cell, use the following deterministic GDScript-side policy unless the current code already has a documented equivalent:

1. Ignore neutral contributions equal to `1.0`.
2. If one or more slowdown contributions below `1.0` exist, use the lowest slowdown multiplier.
3. Otherwise, if one or more speed-up contributions above `1.0` exist, use the highest speed-up multiplier.
4. Otherwise, use `1.0`.

Examples:

```text
No contribution              -> 1.0
0.5                          -> 0.5
0.8 + 0.5                    -> 0.5
1.25                         -> 1.25
1.25 + 1.5                   -> 1.5
0.5 + 1.5                    -> 0.5
```

This preserves “strongest slowdown wins” behavior and allows future speed-up tiles without neutral `1.0` suppressing them.

Keep this gameplay composition rule in GDScript.

The native C++ system must only receive and apply the final multiplier. It must not know how gameplay contributions were combined.

Each contribution must have a stable source identity so removing one object does not accidentally clear another object’s modifier on the same cell.

Avoid rebuilding every cell when one contribution changes. Recompute and upload only affected cells, except during explicit full replacement.

---

# Static and dynamic synchronization

## Initial/preload synchronization

Collect all relevant terrain-speed cells in GDScript first.

Upload them through batch or replace-channel methods.

Do not perform one native call per cell.

## Runtime updates

For one changed tile, use the single-cell API.

For several changed tiles from one action, use the batch API.

Examples:

* a placed or removed multi-cell object;
* a batch of plants becoming active/inactive;
* loading a region;
* clearing several map modifiers.

## Save/load

The native terrain-speed map is runtime-derived state.

Do not add duplicate savegame serialization for the native sparse map unless the project already treats this data as independently persistent.

On load, reconstruct the terrain-speed state from the actual saved gameplay/map objects and perform a full channel replacement.

Ensure stale terrain-speed cells cannot survive loading another map or save.

---

# Async and thread-safety rules

Terrain-speed mutations are expected to occur from the Godot/main thread.

They must remain valid while an asynchronous flow-field worker is running because the worker no longer owns or reads terrain-speed state.

Do not add locks to the flow-field worker for terrain speed.

Do not advertise the setter as safe for arbitrary concurrent thread mutation unless actual synchronization is implemented.

Document the intended model clearly:

```text
Main-thread terrain updates may occur while flow-field jobs run.
Flow-field worker threads do not read terrain-speed state.
Steering reads the current terrain-speed state during movement.
```

---

# Routing-cost separation

Do not add slowdown or speed-up multipliers to Dijkstra cost in this task.

Movement speed and route cost are separate concepts:

```text
Terrain speed multiplier:
Changes how quickly an agent physically crosses a cell.

Traversal cost:
Changes which route the flow field selects.
```

Changing terrain movement speed must not:

* invalidate flow fields;
* queue a group rebuild;
* trigger a global lazy rebuild;
* modify garden topology;
* modify wall topology;
* modify flow directions;
* change Dijkstra cardinal/diagonal cost.

Remove or correct comments that claim the current terrain-speed multiplier feeds routing cost.

If a future weighted-routing feature is needed, it must use a separate traversal-cost system and explicit flow-field invalidation.

Do not prepare that feature beyond keeping terminology clean.

---

# Call-site audit

Audit all terrain speed writers, including at minimum:

* water or terrain initialization;
* plant slowdown;
* bamboo slowdown;
* fence slowdown;
* buildings or placeables;
* player-specific exemptions;
* preload/map setup;
* savegame load or level reset;
* debug or development tools.

For every caller, determine:

* the source identity;
* affected cell or cells;
* multiplier;
* terrain-speed channel;
* add/update/remove lifecycle;
* whether it should use single, batch, or replace API.

No direct native terrain-speed writer should remain outside the authoritative GDScript service unless there is a documented architectural reason.

---

# Cleanup requirements

Remove:

* duplicate maps;
* obsolete arrays;
* dead helper methods;
* dead bindings;
* stale comments;
* temporary compatibility code;
* test logs or verbose debug output;
* slowdown-specific names in generic native code;
* unnecessary reseeding during flow rebuilds.

Rename generic concepts consistently:

Preferred terminology:

```text
terrain speed
terrain speed multiplier
terrain speed channel
terrain speed grid
```

Avoid using `slowdown` in the generic native API because values above `1.0` are valid.

Gameplay classes may still use terms such as “slowdown plant” when appropriate.

---

# Performance requirements

The final system must:

* perform one cheap terrain lookup per moving agent as currently intended;
* avoid per-agent allocation;
* avoid per-cell Godot/native calls during bulk initialization;
* avoid terrain-speed copies during flow rebuild;
* avoid one full-map multiplier array per flow field;
* keep neutral cells absent from sparse storage;
* update only affected cells during normal runtime mutation;
* allow efficient clearing or replacement when changing maps or saves.

Do not add pooling, jobs, watchers, signals, or caching layers without a concrete need.

Prefer simple, readable, production-oriented code.

---

# Required validation

Do not run Godot yourself, but ensure the implementation supports the following manual checks.

## Existing behavior

1. Existing slowdown tiles still slow normal agents by the same amount.
2. Any player-specific exemption or alternative speed remains behaviorally identical through a generic channel.
3. Removing a slowdown source restores the correct remaining overlapping modifier.
4. Removing the final source restores the cell to `1.0`.
5. Water, plants, bamboo, fences, and other existing terrain modifiers still work.

## Speed-up readiness

6. A debug/manual call setting a cell to `1.5` makes an applicable agent cross it at approximately 150% normal movement speed.
7. A multiplier above `1.0` is not silently clamped to `1.0`.
8. Clearing the speed-up cell restores normal speed.
9. Channel-specific speed-up values use default-channel fallback correctly.

Do not add a permanent debug key unless one already exists and is the standard project testing method.

## Flow-field independence

10. Changing one terrain-speed cell does not queue or rebuild any flow field.
11. Batch changes do not queue or rebuild flow fields.
12. A terrain-speed change applies immediately while an async flow rebuild is pending.
13. A completed async flow result does not overwrite newer terrain-speed values.
14. Global lazy flow rebuilds no longer snapshot or copy terrain-speed data.

## Batch behavior

15. Initial map synchronization uses batch/replace calls rather than one native call per tile.
16. Batch cells and multiplier arrays are validated.
17. Replacing a channel removes stale cells that are absent from the replacement batch.
18. Loading a different save or map cannot retain modifiers from the previous one.

---

# Implementation process

Before editing, provide a concise ownership plan containing:

* current native owner;
* new native owner;
* GDScript owner;
* persistent state;
* public API;
* exact files expected to change;
* call sites to migrate.

Then implement the refactor.

Do not guess about call sites. Search the full codebase for all related methods, fields, bindings, comments, and multiplier names.

Keep strict GDScript typing.

Avoid `:=` where forbidden by `AGENTS.md`, especially for dynamic returns, Dictionaries, Arrays, nullable values, and mixed numeric expressions.

Do not expand an unrelated manager with a new responsibility.

---

# Final response required from the coding agent

Report:

1. The final native source of truth.
2. The public API added.
3. How terrain-speed channels work.
4. Which obsolete flow-field data was removed.
5. Which GDScript callers were migrated.
6. How batch preload/load synchronization now works.
7. How values above `1.0` are supported.
8. Any behavior intentionally left unchanged.
9. Exact files changed.
10. A concise manual test checklist.

Explicitly confirm:

* terrain speed no longer lives inside flow fields;
* terrain-speed changes never trigger flow-field rebuilds;
* C++ contains no player-specific terrain-speed behavior;
* multipliers above `1.0` are supported;
* no Godot build or test was run.
