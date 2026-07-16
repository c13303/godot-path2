# Refactor save/load into a robust semantic checkpoint system

Read `AGENTS.md` and the relevant architecture documentation before editing anything. Follow all typing, ownership, file-size, compatibility, and reporting rules.

Do not run Godot, tests, compilation, export, SCons, or any build command. I will test manually.

## Objective

The current save/load system is fragile because it serializes live client and monster nodes together with partial navigation-phase data, then attempts to reconstruct their runtime paths, flow groups, native-agent registrations, and state-machine positions.

A concrete bug currently occurs when saving during the client walking phase: after loading, restored clients exist but remain immobile.

Do not patch only that symptom.

Replace the current live-agent restoration approach with a **semantic checkpoint system**:

* Save authoritative gameplay state.
* Do not save native navigation or steering internals.
* Do not restore transient agents from partial runtime state.
* Reconstruct transient simulation through the normal spawning/navigation pipelines.
* Make resource transactions atomic so save/load cannot duplicate or lose roses, money, monsters, or client demand.

This is the intended practical equivalent of a “full situation snapshot.” It is not a literal process-memory dump.

---

# Non-negotiable design decisions

## 1. Do not implement a memory dump

Do not attempt to serialize:

* The SceneTree.
* Live Godot nodes as `PackedScene`.
* Native-extension memory.
* Navigation IDs.
* Flow-field IDs or groups.
* A* paths.
* Steering state.
* Tween state.
* Pending callbacks.
* Runtime dictionaries keyed by navigation IDs.
* Exact client movement phases.

Keep the save file as inspectable JSON for now.

Changing JSON to binary is not part of this task and would not solve the ownership problem.

## 2. Save authoritative state, not instantiated simulation

Continue saving persistent state such as:

* Progression and currencies.
* Player position.
* Inventory and selected/equipped items.
* Canonical gameplay phase.
* Persistent phase flags.
* Tile layers.
* Plants and plant state.
* Bamboo state.
* Counter stock.
* Ground collectibles.
* Runtime placeables.
* Houses and construction state.
* Durability.
* Tutorial/onboarding progression.
* Spawn-playlist progress.
* Relevant one-shot reveal state.
* Sheep state if it is currently intended to survive save/load.

Do not save live clients, villagers, builders, merchants, or full live monster nodes.

Villagers and residents must continue to be reconstructed from their owning houses or authored gameplay state.

## 3. Client phase resumes from outstanding demand

`ClientSaleController` must become the sole owner of the remaining client workload.

A save during the client phase must capture:

* Whether the client sale is active.
* Existing not-yet-spawned client requests.
* Spawn timers.
* One outstanding request for every live client that has not yet completed a purchase.
* The source client spawner for every request.

After loading:

* No client node is recreated directly.
* Outstanding clients respawn through the normal client spawning method.
* Navigation is assigned through the normal production path.
* No loaded client may start in an idle native group waiting for ad-hoc retargeting.
* Existing spawner reveal restrictions and released-spawner state must remain respected.

Clients that have already completed their purchase must not be respawned merely because their exit animation or walk was unfinished.

## 4. Client purchases are synchronous gameplay transactions

The current implementation can remove a rose and complete the client while delaying the actual money credit until the HUD animation reaches the money icon. That creates an invalid save window.

Refactor client payment so the complete logical transaction happens synchronously:

1. Verify and consume exactly one rose from its authoritative source.
2. Credit exactly one money immediately through `Progression.update_money()`.
3. Mark the client purchase as completed.
4. Send the client toward the exit.
5. Start rose and money visual animations afterward.

The animations must become presentation only.

A save cannot occur in the middle of a synchronous GDScript call, so rose consumption, money credit, and purchase completion must all be committed before returning control to the frame.

For a counter purchase:

* Decrement counter stock immediately.
* Credit money immediately.
* Set `client_has_rose` immediately.
* Start the counter-to-client rose animation afterward.
* Start a visual-only money flight afterward.
* The pinned rose may still become visible when the rose flight reaches the client; that visual delay must not control gameplay ownership.

For a garden-plant purchase:

* Remove/consume the plant immediately.
* Credit money immediately.
* Set the client purchase as completed immediately.
* Start plant-parts and payment visuals afterward.

Add a clear visual-only money animation API. Preserve the existing money animation API if another call site genuinely depends on credit-on-arrival behavior, but client purchases must use the new visual-only path.

Update obsolete comments that currently state that client money is credited when the animation reaches the HUD.

## 5. Monster state uses semantic resume tokens

Night spawn-playlist and spawn-tick progress must remain authoritative for monsters that have not yet spawned.

For monsters already alive at save time, capture only a minimal semantic resume token where further hostile work remains.

Each token should contain only data such as:

```text
spawner_cell
monster_type
health
max_health
roses_eaten
```

Do not include:

```text
nav_id
position
path
flow group
garden id
garden entry
A* target
waiting-flow state
steering velocity
animation state
```

Classify live monsters as follows:

### Monster still seeking a target

Create one resume token.

### Monster currently eating

The plant was already consumed when eating began, so that consumption is committed.

* If the monster is already satiated, do not create a resume token.
* If it still needs more roses before satiety, create a resume token with its existing `roses_eaten`, health, type, and source spawner.
* On load, it restarts from its source spawner and seeks another target through the normal spawning/navigation pipeline.
* Do not restore the old eating timer or eating animation.

### Monster already escaping

Do not respawn it.

Its hostile work is complete and the remaining exit movement is transient presentation. Do not allow loading to make it eat another plant.

This intentional simplification is preferable to restoring fragile movement internals.

### Resume processing

* Resume-monster tokens must be stored independently from playlist track requests because the playlist already counts those monsters as spawned.
* Never increment playlist wave counts again for resumed monsters.
* Drain resume tokens through the existing spawn budget rather than spawning all of them in one frame.
* Process resume tokens before newly scheduled playlist monsters.
* A failed resumed spawn must remain queued for retry; it must not silently disappear.
* Night completion must wait until the resume queue is empty as well as the playlist being complete and no live monsters remaining.
* If no targetable plants remain, resumed hostile-work tokens may be discarded because they cannot perform additional gameplay work. Log this through existing debug/save logging and allow normal no-plants night completion.
* Apply canonical monster data first, then restore current health, max health, and `roses_eaten` before assigning normal navigation.

## 6. Saving remains blocked during client tantrum

Preserve the current rule that save is rejected while a client tantrum is active.

Do not serialize hostile-client assault state in this refactor.

Add defensive validation so a supposedly valid client-phase checkpoint containing hostile clients cannot silently produce a corrupted save.

## 7. Save capture must fail rather than guess

Every outstanding client and resumable monster must have a valid authored source spawner.

If a required spawner association is missing or invalid:

* Do not select an arbitrary spawner.
* Do not use the nearest spawner.
* Do not silently omit the agent.
* Return a clear capture error.
* Abort the save before writing or replacing the existing save file.
* Log enough context to locate the invalid agent.

A failed capture must leave the previous valid save untouched.

---

# Required ownership changes

## Replace `AgentSaveService`

The current `scripts/map/agent_save_service.gd` owns detailed serialization and reconstruction of live agents. That responsibility must be removed.

Replace it with a focused semantic runtime-save owner, for example:

```text
scripts/map/runtime_simulation_save_service.gd
class_name RuntimeSimulationSaveService
```

The exact name may differ only if an existing project convention provides a clearly better name.

This service should coordinate domain snapshots, not inspect navigation-owner private dictionaries.

It may coordinate:

* Client-sale checkpoint state.
* Spawn-playlist state.
* Spawn-tick state and resume-monster tokens.
* Sheep state.
* Spawner reveal state.
* Fundamental-builder onboarding state.
* Cleanup of transient actors created during scene startup before restoration.

It must not instantiate `character.tscn` or reconstruct saved paths.

Before deleting or renaming `AgentSaveService`, search for:

* Direct class references.
* Preloads.
* String method calls.
* `call()`.
* `Callable`.
* Signals.
* Scene/resource references.

Remove the old implementation if it is genuinely unused after migration. Do not retain a dead façade merely as reassurance.

## `ClientSaleController`

`ClientSaleController` owns:

* Active client-sale status.
* Outstanding client requests.
* Spawn timers.
* Capture of live, unserved client demand.
* Restoration of that demand.
* Sale completion based on pending demand and live clients.

Its save method must build a new checkpoint without mutating the live phase.

When capturing:

1. Copy existing pending client requests.
2. Inspect current live clients.
3. Ignore clients whose purchase is already committed (`client_has_rose == true`).
4. Add exactly one request per remaining live, unserved client.
5. Ensure every such client has a valid `spawner_cell`.
6. Put previously live clients ahead of never-spawned requests so already-started demand resumes first.
7. Make their source spawner eligible to retry promptly while still respecting normal per-frame spawning and reveal restrictions.

Do not duplicate a request already represented as pending. Under the current model, a client is removed from the pending list when successfully spawned, so pending and live demand should be disjoint. Preserve that invariant explicitly.

## `AgentNavigationPhaseController`

This controller already owns the semantic navigation phases.

Add narrow read-only capture methods for classifying live monsters without exposing its internal dictionaries to the save service.

For example, it may expose an operation conceptually equivalent to:

```gdscript
capture_monster_resume_tokens() -> Dictionary
```

The result should communicate:

```text
ok
error
tokens
```

It may inspect its own:

* Eating registry.
* Escaping registry.
* Other movement-phase registries.
* Live monster nodes.

Do not move navigation ownership into the save service.

Do not expose all private dictionaries as new generic getters merely for save/load.

## `SpawnTickController`

Extend its existing cohesive spawning responsibility to own a load-resume queue for semantic monster tokens.

It must:

* Serialize any already queued resume tokens.
* Restore them.
* Drain them under the existing per-frame count/time budget.
* Retry transient failures.
* Process resumed monsters before new playlist requests.
* Include the resume queue in night-completion conditions and telemetry.
* Keep resume requests separate from playlist track-index deduplication.

Do not fake playlist track indexes for resume tokens.

## `AgentSpawnService`

Reuse the normal spawning path.

Add a narrow resumed-monster entry point or a small optional resume-state argument to the existing monster spawn operation.

Do not copy and paste the complete spawn algorithm.

The resumed path must still perform:

* Normal scene instantiation.
* Runtime group registration.
* Canonical monster-data application.
* Native registration.
* Garden/route selection.
* Normal navigation assignment.
* Existing spawn failure handling and telemetry.

Then apply the semantic resume data at the correct point:

* `monster_type`
* `health`
* `max_health`
* `roses_eaten`

Do not allow resumed monsters to bypass normal route validity checks.

## `BuildingManager`

`BuildingManager` remains a façade/coordinator.

Replace facade methods such as:

```text
serialize_runtime_agents_for_save
restore_runtime_agents_from_save
```

with intention-revealing semantic checkpoint methods, for example:

```text
capture_runtime_simulation_for_save
restore_runtime_simulation_from_save
```

The capture API must be able to report failure explicitly rather than returning an ambiguous empty dictionary.

A suitable result shape is:

```gdscript
{
    "ok": true,
    "error": "",
    "state": {}
}
```

Do not add the new save algorithms directly to `building_manager.gd`. It is already far beyond the size threshold and must remain orchestration/facade code.

Eliminate save-service access to manager internals such as:

```text
_manager._eating_agents
_manager._escaping_agents
_manager._client_counter_agents
_manager._astar_in_agents
_manager._entry_path_agents
```

Use the actual owning controllers.

---

# Save-system structural cleanup

## Extract save/load orchestration from `progression.gd`

`scripts/gameState/progression.gd` is already over the `AGENTS.md` file-size limit and currently mixes:

* Currency/progression ownership.
* Progression UI updates.
* Input shortcuts.
* Save-file I/O.
* Snapshot capture.
* Snapshot validation.
* Scene reload.
* World restoration.
* Runtime simulation restoration.
* Save summaries.

This task is specifically a save-system refactor, so extract the save/load responsibility instead of adding more code to `progression.gd`.

Create a focused save-game owner, for example:

```text
scripts/gameState/save_game_service.gd
class_name SaveGameService
```

`progression.gd` should keep small compatibility/facade entry points needed by current UI or input code:

```text
save_progression(...)
load_progression()
reset_game()
```

Those wrappers should delegate to the new save-game owner.

The new owner should handle:

* Reading and writing save files.
* Schema versioning.
* Validation.
* Legacy migration.
* Snapshot capture orchestration.
* Scene reload request.
* Ordered restoration into the fresh scene.
* Save/load logging and summaries.
* Atomic replacement of the save file.

Do not create a generic serialization framework.

If moving validation and migration into the same file would push it into the warning/giant-file range, split only the real separate responsibility, such as a focused save-schema validator/migrator. Do not create many tiny codec classes.

## Atomic file replacement

Do not overwrite the valid save slot directly.

Use this sequence:

1. Capture and validate the complete snapshot.
2. Serialize to JSON.
3. Write to a temporary file beside the target save.
4. Close/flush it successfully.
5. Replace the target save only after the temporary file is complete.
6. Clean up the temporary file on failure where possible.

A capture, serialization, or write failure must not destroy the previous valid save.

Preserve current manual F5/F9 behavior.

Do not add or restore autosaves.

---

# New save schema

Bump the save version from `8` to `9`.

Replace the misleading top-level `runtime_agents` section with a semantic section such as:

```text
runtime_simulation
```

A reasonable shape is:

```text
runtime_simulation:
    client_sale:
        active
        outstanding_spawners
        spawn_timers

    night:
        spawn_playlist
        spawn_tick:
            ready_queue
            resume_monsters
            empty_night_elapsed

    sheep
    spawner_reveal
    fundamental_builder_onboarding
```

Use the existing project’s serialization conventions for `Vector2i`.

Do not save an `agents` array in a version-9 save.

Remove unused fields rather than carrying them forward. For example, verify whether `night_preparation_ready` is actually restored or meaningful before retaining it.

Update validation and save summaries for the new schema. Useful summary data includes:

* Current phase.
* Pending client count.
* Resumed live-client demand count.
* Remaining playlist monsters.
* Resume-monster token count.
* Live client/monster count at capture.
* Persistent world counts already reported today.

---

# Legacy save compatibility

Preserve loading of existing valid save versions `1` through `8`.

Do not preserve the old live-node restoration path.

Instead, migrate old data into the new semantic version-9 shape before common restoration.

For legacy `runtime_agents.agents`:

## Legacy clients

* If `client_has_rose == true`, consider the purchase committed and do not create outstanding demand.
* Otherwise, convert the client into one outstanding client request using its saved source spawner.
* Preserve the existing legacy `client_sale.pending_spawners` requests as well.
* Reject the legacy load with a clear validation error if an unserved client has no valid source spawner.

## Legacy monsters

Use the saved phase only to convert into a semantic token:

* `escape`: completed; do not create a resume token.
* `eating` and already satiated: completed; do not create a token.
* `eating` and still hungry: create a normal seek resume token.
* `entry`, `astar`, `retarget`, waiting, or another inbound state: create a seek resume token.
* Preserve type, health, max health, `roses_eaten`, and source spawner.
* Do not retain position, garden, target, path, or timer.
* Reject migration if a required source spawner is missing rather than guessing.

After migration, restoration must use the same version-9 semantic path. There must not be a separate long-term “legacy agent re-instantiation” implementation.

Older saves that contain no runtime-agent section should continue through the existing phase fallback behavior.

Keep legacy compatibility code localized to the save schema/migration responsibility and report it explicitly.

---

# Restoration order

Preserve a deterministic restoration sequence.

The target order is:

1. Validate and migrate save data.
2. Reload the scene.
3. Restore progression and special persistent rewards.
4. Restore authored/persistent tile layers.
5. Restore player state and inventory.
6. Reindex loaded world layers and runtime placeables.
7. Restore plant and bamboo state.
8. Restore counter stock.
9. Restore ground collectibles.
10. Restore runtime houses.
11. Restore durability.
12. Restore canonical `GameState` phase flags without emitting normal phase signals yet.
13. Restore the BuildingManager phase scaffold.
14. Prepare navigation for the restored night/client phase through the existing preparation controller.
15. Clear transient startup-created agents and transient runtime registries through one explicit cleanup operation.
16. Restore semantic runtime simulation:

    * Spawn-playlist state.
    * Spawn-tick state.
    * Resume-monster queue.
    * Client outstanding-demand state.
    * Reveal state.
    * Sheep state.
    * Onboarding state.
17. Reconcile house-owned residents from houses.
18. Emit restored-phase signals exactly once.
19. Allow normal frame processing to respawn clients and resumed monsters.

Do not use arbitrary timer delays.

A single deferred call or process-frame wait may remain if scene startup genuinely requires it, but document why it is required and use existing preparation/readiness gates rather than adding timing guesses.

Rename the current `has_runtime_agents` concept. A nonempty semantic state does not imply live agents exist. Use a precise concept such as:

```text
has_phase_resume_state
```

or derive it specifically from the current phase’s semantic checkpoint.

---

# Transient-agent cleanup during load

The fresh scene may create visitors or residents during startup before the saved phase is fully applied.

Keep one explicit cleanup path that:

* Clears agent cell tracking.
* Clears navigation-phase records.
* Unregisters relevant native agents.
* Unregisters runtime agent registries.
* Removes transient clients and monsters.
* Removes/reconciles villagers that are reconstructed from houses.
* Does not leave stale waiting-flow, traffic-priority, drowning, retarget, counter, eating, or escape records.

Do not mix this cleanup with serialization.

Place the cleanup in the narrowest existing owner or a focused runtime-reset method. Do not duplicate cleanup logic between the save service and `BuildingManager`.

---

# Phase behavior requirements

## Dawn

Preserve the existing durable distinctions:

* Sunrise.
* Harvest.
* Pre-client stage.
* Client-sale-start request.

Do not start a second client sale after restoring an existing client-sale checkpoint.

## Morning/client phase

Restore outstanding demand and let `ClientSaleController` spawn it naturally.

If the restored sale is active but has:

* No pending requests.
* No live clients.
* No hostile clients.

Then normal phase processing should complete the sale and continue to afternoon. This covers a save made after the last client committed its purchase but before its transient exit completed.

## Afternoon

No transient clients or monsters should be restored.

## Night

Restore playlist progress, ready requests, and resume-monster tokens before normal night processing resumes.

Do not replay monsters already represented as completed/escaping.

Do not count resume tokens as new playlist spawns.

## Tantrum

Save remains rejected.

---

# Invariants to enforce

After the refactor:

* Version-9 save data contains no live-agent array.
* Save code never instantiates `character.tscn`.
* Save code never restores an agent to native group `0` and then guesses how to retarget it.
* Save code does not read navigation-owner private dictionaries.
* No nav ID is written to disk.
* No flow-field ID/group is written to disk.
* No A* path is written to disk.
* No tween or animation timer is written to disk.
* Client outstanding demand has one owner.
* Spawn-playlist progress has one owner.
* Resume-monster work has one owner.
* A committed rose sale always has both the rose removed and money credited.
* A noncommitted client is always represented as outstanding demand.
* A monster already counted as spawned is never counted by the playlist a second time.
* Restored phase signals are emitted once, after state is ready.
* A failed save cannot corrupt the previous slot.
* Loading cannot leave an agent permanently idle because no live navigation state is restored.

Add targeted error messages or assertions for violated invariants, but do not add noisy per-frame logging.

---

# Performance requirements

The game can contain hundreds of agents.

Save capture may inspect live clients and monsters once when the user saves. That is acceptable.

Do not introduce:

* New per-frame scans of all agents solely for save/load.
* New per-frame serialization.
* Immediate spawning of every restored request in one frame.
* Full-map recomputation beyond the existing phase preparation path.
* Duplicate navigation rebuilds during restoration.
* New polling watchers for save state.

Resume spawning must use the existing frame budgets.

---

# Expected files to inspect

At minimum inspect:

```text
AGENTS.md
ARCHITECTURE.md
scripts/map/ARCHITECTURE.md
scripts/gameState/progression.gd
scripts/gameState/gameState.gd
scripts/map/agent_save_service.gd
scripts/map/client_sale_controller.gd
scripts/map/agent_navigation_phase_controller.gd
scripts/map/agent_spawn_service.gd
scripts/map/building_manager.gd
scripts/map/building_preparation_controller.gd
scripts/map/ally_housing_controller.gd
scripts/map/house_resident_controller.gd
scripts/spawning/spawn_tick_controller.gd
scripts/spawning/spawn_playlist_controller.gd
scripts/ui/money_icon.gd
scripts/ui/currency_harvest_animation.gd
```

Also inspect every direct/dynamic caller before renaming or deleting an API.

Do not modify the C++ extension for this task unless inspection proves a required cleanup API is genuinely unavailable. This architecture should be implementable on the GDScript side by rebuilding native registrations normally.

---

# Manual acceptance scenarios

Do not run these yourself. Include them in the final report for manual testing.

## Client sale

1. Save while several clients are walking inward.
2. Load and verify the same number of unserved clients respawn and move normally.
3. Save while a client is walking to a counter.
4. Save immediately after a counter rose is committed while its rose flight is still visible.
5. Save while the money flight is still visible.
6. Load and verify:

   * The rose is not duplicated.
   * The rose is not lost without payment.
   * Money is not duplicated.
   * Money is not lost.
   * The completed client is not respawned.
7. Save with a mixture of:

   * Pending clients.
   * Live unserved clients.
   * Purchased clients walking out.
8. Verify only pending plus unserved clients resume.
9. Save after the final client has purchased but before it exits.
10. Load and verify the client phase completes normally instead of hanging.
11. Verify client reveal cutscene restrictions still work when saving during partial reveal.
12. Repeat save/load several times during the same client phase and verify demand does not grow.

## Night

1. Save with pending playlist monsters but no live monsters.
2. Save with live inbound monsters.
3. Save with damaged inbound monsters.
4. Save with multiple monster types, including `bigmonster`.
5. Save while a monster is eating but still needs another rose.
6. Verify the consumed rose remains consumed and the resumed monster keeps its `roses_eaten`.
7. Save while a satiated monster is eating.
8. Save while monsters are escaping.
9. Verify satiated/escaping monsters do not respawn and do not consume extra roses.
10. Verify resume monsters spawn before new playlist requests and respect the spawn budget.
11. Verify playlist wave counts are not incremented twice.
12. Verify the night ends correctly when playlist, resume queue, and live monsters are all empty.
13. Verify no-plants night completion does not become stuck on resume tokens.
14. Repeat save/load several times during one night and verify monster counts do not multiply.

## Other phases and persistent state

1. Save/load during dawn sunrise.
2. Save/load during dawn harvest.
3. Save/load during pre-client dawn.
4. Save/load during afternoon.
5. Verify houses, WIP progress, durability, plants, bamboo, counter stock, ground collectibles, inventory, player position, and currencies.
6. Verify villagers/builders/merchant/inventor reconstruct from houses and phase state rather than saved live nodes.
7. Verify saving remains rejected during tantrum.
8. Verify F5/F9 still work.
9. Verify no autosave has been reintroduced.
10. Verify a deliberately invalid runtime capture does not replace the previous valid save.
11. Load at least one existing version-8 save containing active clients or monsters and verify semantic migration.
12. Check for new errors, warnings, duplicate phase signals, or immobile agents.

---

# Final report requirements

Follow `AGENTS.md`.

Report:

1. Every changed, created, renamed, and deleted file.
2. The final ownership of:

   * Save-file orchestration.
   * Persistent world snapshot.
   * Client outstanding demand.
   * Monster resume tokens.
   * Spawn resume queue.
   * Currency transaction commit.
3. The version-9 schema.
4. Legacy migration behavior.
5. APIs removed and compatibility wrappers retained.
6. Any remaining private coupling.
7. Any file that entered the warning size range.
8. Any behavior intentionally simplified, especially outbound clients and escaping/satiated monsters not being recreated.
9. Every manual test scenario.
10. Confirmation that no Godot, test, compilation, export, or build command was run.

Implement the complete refactor. Do not stop after fixing the immobile-client symptom.
