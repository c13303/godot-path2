Implement a data-driven, per-level monster spawn playlist system for the current Godot 4 project.

Do not create a custom editor plugin yet. First implement the runtime architecture and typed resources cleanly, then create a working playlist resource for `level_demo.tscn`.

Do not replace or simplify the existing garden, flow-field, night-preparation, spawn-budget, or monster-routing systems.

## Current architecture to preserve

The current spawning logic is mainly located in:

```text
res://scripts/map/building_manager.gd
```

Relevant current behaviour:

* `BuildingManager` scans special spawner tiles from `traversable_buildings`.
* Physical spawners are currently stored in `_spawners`, keyed by `Vector2i`.
* `_spawn_timers` stores cooldowns per spawner cell.
* `_process_spawners(delta)` currently:

  * runs only during night;
  * waits for `_night_preparation_ready`;
  * checks plants;
  * applies the old global spawn quota;
  * updates every spawner cooldown;
  * queues ready spawners;
  * drains the queue under:

    * `spawner_budget_per_frame`;
    * `spawner_budget_ms`.
* `_spawn_monster_from(spawner_cell)` performs the actual expensive spawn:

  * selects a reachable garden;
  * resolves the cached route;
  * finds a free spawn cell;
  * instantiates `AGENT_SCENE`;
  * registers the monster with `agent_manager`;
  * assigns it to the garden-entry flow.

The existing physical spawning and routing work inside `_spawn_monster_from()` must remain the canonical execution path.

The playlist system must decide **which spawner may spawn, when, and which monster type**, but it must not duplicate physical monster creation or routing.

Current night lifecycle:

```text
GameState.mode_changed
BuildingManager._on_game_mode_changed()
BuildingManager._run_night_preparation()
BuildingManager._process_spawners()
GameState.start_day()
Progression._on_game_mode_changed(false)
```

`Progression` currently increments `nDays` whenever a night ends and the game returns to day.

The old spawn amount is currently calculated through:

```gdscript
nDays * monster_per_day + roses * monster_per_rose
```

That quota-based spawning must be replaced when a valid playlist is assigned.

## Goal

Each level has one spawn playlist resource.

The playlist contains an ordered list of nights.

Each night contains one ordered track per participating physical spawner.

Each spawner track contains an ordered list of waves.

Example semantics:

```text
Night 1
    Spawner "north"
        Wave 1: 10 basic monsters, one every 3 seconds
        Wave 2: 5 basic monsters, one every 3 seconds
        Wave 3: 5 basic monsters, one every 3 seconds, emit event "A"

    Spawner "south"
        Wave 1: wait for event "A", then spawn 10 basic monsters every 3 seconds
        Wave 2: 5 basic monsters every 3 seconds
```

Within one spawner track:

* Waves are always sequential.
* Wave 2 cannot start before wave 1 has completely spawned.
* “Wave complete” means every monster scheduled by the wave has been successfully spawned.
* Monsters do not need to be killed before the next wave starts.
* A wave with `wait_for_event` cannot start until that named event has been emitted during the current night.
* A wave with `emit_event` emits the event immediately after its final monster has been successfully spawned.
* Emitted events remain active for the rest of that night.
* All spawner tracks run concurrently, subject to their own wave sequence and event dependencies.

A night has completed its spawn schedule when every spawner track has completed every wave.

The night itself ends only when:

1. the entire current night playlist has finished spawning; and
2. no live monsters remain.

Then call `GameState.start_day()` through the existing lifecycle.

When the final configured night has been survived, emit a clear level-completion signal. Do not invent a full victory screen if none currently exists.

## Typed Resource model

Create typed resources in an appropriate folder, for example:

```text
res://scripts/spawning/resources/spawn_wave.gd
res://scripts/spawning/resources/spawner_wave_track.gd
res://scripts/spawning/resources/night_spawn_playlist.gd
res://scripts/spawning/resources/level_spawn_playlist.gd
```

Use `Resource` classes with `class_name`.

### `SpawnWave`

Required exported fields:

```gdscript
monster_type: StringName
monster_count: int
spawn_interval_seconds: float
wait_for_event: StringName
emit_event: StringName
```

Constraints:

* `monster_count >= 0`
* `spawn_interval_seconds >= 0`
* Empty `wait_for_event` means no dependency.
* Empty `emit_event` means no event is emitted.
* Do not call these fields Godot signals. They are playlist events.

Use clear inspector groups and tooltips/comments.

### `SpawnerWaveTrack`

Required fields:

```gdscript
spawner_id: StringName
waves: Array[SpawnWave]
```

`spawner_id` must be stable and must not depend on the order of spawners in an array.

### `NightSpawnPlaylist`

Required field:

```gdscript
spawner_tracks: Array[SpawnerWaveTrack]
```

### `LevelSpawnPlaylist`

Required field:

```gdscript
nights: Array[NightSpawnPlaylist]
```

Add validation helpers where appropriate, but do not put mutable runtime state inside these resources. They are immutable configuration during a run.

## Playlist attachment to levels

Each level scene must reference one external `.tres` playlist resource.

Do not embed the production playlist as a large subresource inside the `.tscn`.

Add a clean exported property at the level integration point, or on a dedicated runtime controller owned by the main run scene:

```gdscript
@export var spawn_playlist: LevelSpawnPlaylist
```

Use the project’s existing level-loading architecture. Inspect:

```text
res://scripts/map/level_loader.gd
res://scenes/levels/level_demo.tscn
res://scenes/levels/level_river.tscn
res://scenes/main/mainRun.tscn
res://scripts/map/building_manager.gd
```

Do not hardcode `level_demo`.

The playlist associated with the loaded level must be made available to the runtime spawn controller or `BuildingManager` without relying on fragile absolute scene paths.

Create:

```text
res://scenes/levels/playlists/level_demo_spawn_playlist.tres
```

Populate it with a small but real example containing at least:

* two nights;
* at least two spawner tracks when the level contains at least two physical spawners;
* multiple sequential waves;
* one emitted event;
* another wave waiting for that event.

Do not overwrite the actual level design with arbitrary huge monster counts. Use small development values.

## Stable spawner IDs

The current physical spawners are represented by cells in `traversable_buildings`.

The playlist must not identify them as “Spawner 1”, array index, or iteration order.

Add a stable ID mapping per level:

```text
StringName spawner_id -> Vector2i physical spawner cell
```

Choose the cleanest integration based on the current level architecture.

A suitable solution may be a small typed level resource or exported array of spawner bindings, where each binding contains:

```gdscript
spawner_id: StringName
cell: Vector2i
```

Requirements:

* IDs must remain stable if dictionary iteration order changes.
* The playlist references IDs, never raw array positions.
* Runtime spawning ultimately resolves the ID to the current physical spawner cell.
* Duplicate IDs must be detected.
* Duplicate cell bindings must be detected.
* Playlist references to unknown IDs must be reported clearly.
* A bound cell that does not correspond to a scanned physical spawner must be reported clearly.

Do not redesign the entire current tile-based spawner placement system.

For this first implementation, an explicit ID-to-cell binding stored with the level is acceptable.

## Runtime controller

Prefer a dedicated runtime class such as:

```text
res://scripts/spawning/spawn_playlist_controller.gd
```

It may be a child node integrated into the current main scene, or a tightly scoped helper owned by `BuildingManager`.

Do not create another global autoload.

The controller owns runtime schedule state:

```text
current_night_index
runtime state for each spawner track
current wave index
number successfully spawned in current wave
time until next spawn
events emitted this night
whether all tracks are complete
```

Do not mutate the `.tres` resources to store these values.

Expose clear methods such as:

```gdscript
configure(...)
begin_night(night_index)
advance(delta)
mark_spawn_result(...)
is_current_night_schedule_complete()
get_total_night_count()
```

The exact API may differ if another API fits the current code better, but responsibilities must remain clear.

## Integration with current `BuildingManager`

Refactor the current spawner processing carefully.

### Preserve

Preserve:

* `_night_preparation_ready` gating;
* plant availability checks;
* the ready-spawner queue or equivalent budgeted execution;
* `spawner_budget_per_frame`;
* `spawner_budget_ms`;
* route caches;
* `_spawn_monster_from()`;
* failed-spawn retry behaviour;
* lag instrumentation;
* garden selection;
* free-cell search;
* agent registration;
* entry-flow assignment.

### Replace for playlist-controlled levels

When a valid playlist is configured:

* Do not use `_compute_spawn_limit()`.
* Do not use `_spawn_limit_this_night` to determine the number of monsters.
* Do not advance all physical spawners from their tile-defined cooldowns.
* Do not automatically enqueue every scanned spawner.
* Only enqueue a spawn request when the active wave for that spawner track is eligible and its playlist interval has elapsed.
* The requested monster is consumed from the wave only after `_spawn_monster_from()` returns success.
* On failure:

  * do not increment the wave’s spawned count;
  * do not finish the wave;
  * do not emit its event;
  * retry later;
  * use a small retry delay such as the existing `0.25` seconds rather than retrying every frame.

The budgeted queue must support playlist spawn requests.

A request must carry at least:

```text
spawner_id
resolved spawner cell
monster_type
track/runtime identity needed to report success
```

Do not allow duplicate pending requests for the same track.

Multiple playlist tracks may become ready in the same frame, but the current spawn budget must still spread expensive spawn work across frames.

### Fallback

If no playlist is assigned, decide on one explicit policy:

* either retain the current quota-based legacy spawning as a temporary fallback;
* or disable spawning with a clear configuration error.

Prefer retaining the current behaviour as a compatibility fallback unless doing so would make the implementation unsafe or excessively complex.

Keep the playlist path clearly separated from the legacy path.

## Monster type support

The playlist contains `monster_type`.

Currently `BuildingManager` always instantiates:

```gdscript
const AGENT_SCENE = preload("res://scenes/entities/character.tscn")
```

Do not pretend multiple monster scenes already exist if they do not.

Implement a small explicit monster-type resolver or catalog that currently maps:

```text
"basic" -> character.tscn
```

Modify the physical spawn entry point so it can receive the requested monster type:

```gdscript
_spawn_monster_from(spawner_cell, monster_type)
```

or an equivalent typed request.

Requirements:

* `"basic"` preserves the exact current monster behaviour.
* Unknown monster types fail clearly and do not consume the playlist entry.
* Do not use arbitrary dynamic paths directly from the playlist.
* Keep the catalog ready for future monster types without overengineering it.
* Preserve all current initialization, grouping, navigation registration, and routing regardless of monster type.

## Night numbering

Playlist night index 0 corresponds to playable Night 1.

The current `Progression.nDays` starts at 1 and increments when returning to day.

Do not blindly use `nDays - 1` without checking save/load and scene-start behaviour.

Establish one clear source of truth for the current level night.

For the first integration, it is acceptable to derive the playlist night from `nDays`, provided:

* the mapping is explicit;
* starting day 1 selects playlist Night 1;
* returning to day after surviving Night 1 advances progression to day 2;
* starting the next night selects playlist Night 2;
* save/load retains the correct night;
* invalid indices are handled safely.

Do not add a second independently saved night counter unless necessary.

## Final-night completion

When the final night schedule has completed and all live monsters have been removed:

* do not start another ordinary day as though another playlist night existed;
* emit a dedicated signal such as:

```gdscript
signal level_completed
```

* ensure it fires only once;
* stop further playlist spawning;
* leave victory presentation to existing or future UI code;
* log a clear message in debug mode.

Place the signal on the most appropriate non-global controller.

If compatibility with current progression requires returning to day first, document and implement the ordering explicitly. Avoid incrementing `nDays` into a nonexistent extra night before level completion unless the existing game lifecycle requires it.

## Plant exhaustion and blocked spawners

The current code can end or stall a night when no plants remain or a spawner cannot spawn.

Retain safe behaviour:

* If no plants remain, do not consume playlist monsters.
* Existing monsters may finish their current behaviour.
* The game must not crash due to an unfinished schedule.
* A permanently blocked physical spawner must not create an infinite tight retry loop.
* Keep or adapt the current stall protection.
* Emit clear diagnostics indicating:

  * night number;
  * spawner ID;
  * wave index;
  * number spawned versus scheduled;
  * failure reason when known.

Do not silently mark blocked waves complete.

## Validation

Validate the complete playlist when the level starts, before the first night.

Detect at least:

* missing playlist;
* empty playlist;
* null night entries;
* duplicate spawner tracks within one night;
* empty spawner IDs;
* unknown spawner IDs;
* duplicate spawner bindings;
* invalid monster types;
* negative counts;
* negative intervals;
* null wave entries;
* events that are waited for but never emitted in that night;
* obviously impossible self-dependencies, such as a wave waiting for an event that can only be emitted by itself after completion.

Do not reject legitimate cross-spawner dependencies.

For invalid production data:

* report precise `push_error()` messages;
* include resource path, night index, spawner ID and wave index;
* prevent unsafe spawning;
* do not crash.

Validation should not run every frame.

## Save/load considerations

Inspect the current progression save/load flow.

The current game appears to save during days rather than mid-night. Do not build a large mid-wave serialization system unless the current save system actually supports saving during night.

At minimum:

* loading on day N must select playlist Night N;
* restarting/reloading the level must reset runtime wave and event state cleanly;
* no stale event or pending request may survive a scene reload.

If saves can currently occur during night, preserve existing behaviour safely and document whether the current night restarts from its beginning.

## Performance constraints

This game may have 500+ active agents.

Requirements:

* no per-frame scans of resource trees beyond the small active playlist state;
* no `get_nodes_in_group()` calls added beyond the existing monster-count path;
* no repeated full playlist validation;
* no repeated string-based node searches;
* use `StringName` for IDs and event names;
* keep active track state indexed for direct access;
* maintain the current spawn budgets;
* avoid allocating large dictionaries or arrays every frame;
* avoid changing the expensive garden/pathfinding code;
* do not add timers as one Node per wave or one Node per monster.

Use one central lightweight scheduler.

## Debugging API

Add useful debug logging behind the existing `debug_logs` behaviour or an equivalent existing debug option.

Useful messages:

```text
Playlist Night 1 started
Spawner north Wave 2 started
Spawner north Wave 2 spawned 3/5 basic
Playlist event A emitted
Spawner south Wave 1 unblocked by A
Playlist Night 1 schedule complete
Playlist Night 1 cleared
Final playlist night cleared; level completed
```

Do not print every frame or repeatedly print a blocked dependency.

## Files and scene changes

Keep new files organized under a dedicated spawning folder.

Likely additions:

```text
scripts/spawning/spawn_playlist_controller.gd
scripts/spawning/monster_spawn_catalog.gd
scripts/spawning/resources/spawn_wave.gd
scripts/spawning/resources/spawner_wave_track.gd
scripts/spawning/resources/night_spawn_playlist.gd
scripts/spawning/resources/level_spawn_playlist.gd
scripts/spawning/resources/spawner_binding.gd
scenes/levels/playlists/level_demo_spawn_playlist.tres
```

The exact structure may vary if the existing codebase suggests a cleaner equivalent.

Modify only the necessary existing files, likely including:

```text
scripts/map/building_manager.gd
scripts/map/level_loader.gd or the actual level integration point
scenes/main/mainRun.tscn
scenes/levels/level_demo.tscn
```

Do not put separate behaviour scripts on every level.

Each level should only need:

* one playlist `.tres`;
* its spawner ID bindings;
* one reference to the playlist through the established level configuration.

## Implementation quality

Before editing:

1. Inspect all relevant scene loading and spawner scanning code.
2. Identify exactly where the loaded level can expose configuration.
3. Identify how spawner tiles are discovered and represented.
4. Identify the current save/load assumptions.
5. Preserve existing node ownership and injected references.

Then implement the smallest clean architecture satisfying the requirements.

Do not perform unrelated refactors.

Do not remove old garden or pathfinding functionality.

Do not alter monster movement after spawning.

Do not bypass `_spawn_monster_from()`.

Do not create the custom playlist editor yet.

At the end, provide:

1. A concise list of files added and modified.
2. A description of the runtime flow.
3. The exact place where a new level assigns its playlist.
4. The exact process for assigning stable IDs to physical spawners.
5. Any legacy spawn-quota code retained as fallback.
6. Any unresolved limitation, especially save-during-night behaviour.
7. Confirmation that no per-level script is required.
