Implement **new multi-agent daytime visitor: Builder**.

Read and follow `AGENTS.md` before editing.

Do not run Godot, tests, compilation, export, or build commands. The user performs runtime testing.

# Objective

Add a new passive daytime agent type:

```text
Builder
```

Builders:

1. Enter at the beginning of each daytime, at the same lifecycle moment as the seed merchant.
2. Spawn from the existing authored spawner:

```text
seedmerchent
```

3. Walk toward the authored anchor:

```text
builder_spot
```

4. Each Builder claims a different nearby free walkable tile.
5. Idle on their claimed tiles during the day.
6. Leave when night starts.
7. Reuse the route linked to:

```text
seedmerchent_exit
```

8. Are removed after reaching the exit.
9. All return the next daytime.
10. Use:

```text
builder.png
```

with the same sprite-sheet frame contract and animation setup as the existing seed merchant.

The system must support an arbitrary small roster of Builders, not one hardcoded agent.

The normal initial Builder roster is:

```text
1
```

When developer keys are enabled, pressing:

```text
K
```

adds one Builder permanently to the current run’s roster.

The first press therefore creates a second Builder.

This pass adds only Builder presence and lifecycle.

Do not implement:

* Builder interaction.
* Building or repair behavior.
* Builder shop.
* Dialogue.
* Builder rewards or acquisition UI.
* Builder costs.
* Player proximity prompts.
* New gameplay phases.
* Multiple Builder visual types.

---

# Core roster model

The system must distinguish:

```text
desired Builder count
```

from:

```text
currently active Builder agents
```

The desired Builder count is persistent.

The active Builder list is temporary runtime state.

Example:

```text
Day:
desired count = 3
active count = 3

Night, while they leave:
desired count = 3
active count decreases from 3 to 0

Next day:
desired count = 3
active count returns to 3
```

Do not infer the roster size from the number of currently live nodes.

Do not reduce the desired count when a Builder leaves at night.

Do not save every Builder as an ordinary live agent.

Default desired count:

```gdscript
const DEFAULT_BUILDER_COUNT: int = 1
```

Provide focused queries:

```gdscript
func builder_count() -> int
func active_builder_count() -> int
func is_any_builder_active() -> bool
```

The desired count must never be negative.

---

# Required ownership

Create:

```text
scripts/map/builder_controller.gd
```

with:

```gdscript
class_name BuilderController
```

`BuilderController` owns:

* Persistent desired Builder count.
* Collection of active Builder visitors.
* Builder target-cell claims.
* Builder spawn batching.
* Resolving `seedmerchent`.
* Resolving `builder_spot`.
* Adding Builders through the developer command.
* Day-start roster creation.
* Night departure orchestration.
* Builder-specific visual and identity configuration.
* Builder save/load state.
* Builder removal notification.
* Releasing and reallocating target-cell claims.

It does not own:

* Generic pathfinding algorithms.
* Native agent-manager internals.
* Flow-field generation.
* Merchant interaction.
* Debug keyboard input.
* General save-file writing.
* Generic agent cleanup.
* Future Builder gameplay.

Do not store Builder runtime arrays or roster state directly in `BuildingManager`.

---

# Shared daytime-visitor movement

The existing `SeedMerchantController` contains reusable movement behavior:

* Selecting a free spawn cell.
* Creating `character.tscn`.
* Registering a native agent.
* Assigning an A* path.
* Detecting arrival.
* Waiting at a target.
* Repathing after topology changes.
* Deferring departure until night navigation is ready.
* Assigning the existing escape flow.
* Cleanup after removal.

Do not copy this implementation into `BuilderController`.

Extract the genuinely shared single-agent movement state into a focused helper such as:

```text
scripts/map/day_visitor_movement_controller.gd
```

with:

```gdscript
class_name DayVisitorMovementController
```

A `DayVisitorMovementController` instance represents **one visitor agent**.

Consumers:

* `SeedMerchantController` owns one instance.
* `BuilderController` owns one instance per active Builder.

The helper may own, for one visitor:

* Active agent reference.
* Native navigation ID.
* Source spawner cell.
* Claimed target cell.
* Walking state.
* Waiting state.
* Leaving state.
* Pending-night-departure state.
* Spawn and path assignment.
* Arrival processing.
* Repathing.
* Escape-route assignment.
* Generic cleanup.

Expose focused queries such as:

```gdscript
func is_active() -> bool
func is_waiting() -> bool
func is_leaving() -> bool
func agent_node() -> Node2D
func target_cell() -> Vector2i
func get_agent_world_position() -> Vector2
func owns_agent(agent: Node2D) -> bool
```

Use explicit parameters for:

* Agent kind.
* Scene group.
* Desire/tracker category.
* Source spawner cell.
* Target cell.
* Visual setup callable or focused setup method.
* Diagnostic label.

Do not create:

* An inheritance hierarchy.
* A generic NPC framework.
* An event bus.
* A service locator.
* A visitor plugin system.
* A large configuration resource for two callers.

Keep the extraction local and readable.

---

# Seed merchant regression protection

After extraction, `SeedMerchantController` must still exclusively own:

* `GameState.set_seed_merchant_phase(...)`.
* Player proximity.
* Pausing at the merchant spot.
* Merchant purchase state.
* Merchant phase closure.
* Merchant prompt queries.
* Merchant interaction position.
* Merchant-specific save restoration.

The shared visitor helper must not know about:

```text
GameState.is_seed_merchant_phase
GameState.seed_merchant_purchase_made
merchant prompts
merchant purchases
```

The seed merchant must continue behaving exactly as before.

---

# Authored level contract

The Builder uses the exact authored nodes:

```text
seedmerchent
seedmerchent_exit
builder_spot
```

These nodes are direct children of the loaded level’s `spawners` container.

Do not create or move these nodes.

Do not guess their positions.

If a required node is absent, log a precise warning and safely skip spawning.

## Source spawner

Every Builder uses the authored spawner binding whose exact ID is:

```text
seedmerchent
```

Do not:

* Pick a random merchant spawner.
* Use the first dictionary entry.
* Create a Builder spawner kind.
* Create a second route.
* Hardcode a world or map position.

Expose or reuse a focused exact-binding query such as:

```gdscript
func level_spawner_binding(spawner_id: StringName) -> SpawnerBinding
```

The Builder’s metadata must include the source spawner cell:

```gdscript
agent.set_meta("spawner_cell", seedmerchent_binding.cell)
```

This allows the existing escape route to send every Builder through:

```text
seedmerchent_exit
```

## Builder spot

`builder_spot` is an anchor, not the destination for every Builder.

Capture authored named spots generically while the level is still available to `LevelLoader`.

Capture direct children of `spawners` whose names end with:

```text
_spot
```

Store:

```text
StringName -> Vector2i
```

Examples:

```text
seedmerchent_spot
builder_spot
```

Expose the data through focused read-only APIs.

Do not replace or break the existing `SpawnerBinding.spot_cell` behavior used by the seed merchant.

Do not hardcode a runtime node path to `builder_spot` inside `BuilderController`.

---

# Builder target-cell claims

Multiple Builders cannot all use `builder_spot`.

Treat `builder_spot` as the centre of a Builder gathering area.

Each active Builder must claim one unique destination cell near that anchor.

## Claim rules

Candidate order:

1. Exact `builder_spot` cell.
2. Nearest cells around it.
3. Continue outward in deterministic expanding rings or breadth-first order.

Use a bounded named search radius, for example:

```gdscript
const BUILDER_SPOT_CLAIM_RADIUS: int = 6
```

Keep the radius in one Builder-owned constant.

Do not scan the entire map.

A candidate is valid only when:

* It exists on valid floor.
* It is currently walkable.
* It is not already claimed by another Builder.
* It is not the seed merchant’s authored idle cell.
* It is not occupied by another stationary daytime visitor.
* It is not currently occupied according to the existing agent-cell/occupied-cell query.
* It is reachable from the selected Builder spawn cell.

Path reachability must be checked before the claim is committed.

Do not claim an unreachable tile merely because it is locally walkable.

## Determinism

Use deterministic candidate ordering.

Do not use random target-cell selection.

This makes Builder formation and debugging reproducible.

## Claim lifetime

A Builder claim begins before that Builder is spawned and path-assigned.

The claim remains reserved while the Builder:

* Walks toward it.
* Waits there.
* Is still part of the daytime roster.

Release the claim when that Builder:

* Starts leaving at night.
* Is removed.
* Fails to spawn.
* Is explicitly cleared.
* Is replaced with another target after topology invalidation.

Do not let two live Builder records own the same claimed cell.

Maintain a focused mapping such as:

```text
claimed cell -> visitor instance/runtime ID
```

Do not use scene-tree scans to determine claim ownership.

## No available cell

When no reachable free cell exists within the bounded search radius:

* Do not spawn that Builder partially.
* Do not place multiple Builders on one tile.
* Do not reduce the desired roster count.
* Log one concise warning containing:

  * Desired Builder count.
  * Active Builder count.
  * Spot anchor.
  * Search radius.

The missing Builder can be attempted again the next day.

Do not retry every frame.

---

# Day-start spawning

Builders enter at the same lifecycle seam as the seed merchant:

```gdscript
BuildingManager._on_new_day_finished()
```

The conceptual orchestration is:

```gdscript
_begin_seed_merchant_phase()
_begin_builder_day()
_begin_dawn_harvest()
```

The exact ordering between merchant and Builders may follow the existing code, but the seed merchant should spawn first so its spawn cell and idle cell are already considered unavailable.

At Builder day start:

1. Clear stale active Builder runtime state safely.
2. Preserve the desired roster count.
3. Resolve exact `seedmerchent` source binding.
4. Resolve `builder_spot`.
5. Spawn Builders sequentially until:

   * Active count reaches desired count, or
   * No further valid target/spawn pair can be found.
6. Reserve each chosen spawn cell during the current batch so two Builders cannot spawn on the same cell.
7. Reserve each target claim before spawning the next Builder.

Each Builder must have:

* Its own visitor movement instance.
* Its own native nav ID.
* Its own target cell.
* Its own A* arrival path.
* The same source spawner metadata.
* The same eventual escape route.

Do not create one shared path assignment for all Builders.

Do not spawn them all on the exact `seedmerchent` cell.

Use the existing free-cell-near-spawner behavior.

---

# Development key: K

Integrate the debug command into the existing developer-key owner:

```text
scripts/misc/cpp_debug_options.gd
```

Do not add `_unhandled_input()` to `BuilderController` or `BuildingManager`.

The key is active only when:

```gdscript
dev_keys == true
```

Add handling for:

```gdscript
KEY_K
```

Use the existing `_is_key(...)` helper so physical and logical keyboard layouts behave consistently.

Ignore:

* Released events.
* Echo events.
* Input when developer keys are disabled.

Mark the input handled when accepted.

The debug owner should call one focused manager façade method, such as:

```gdscript
manager.call("add_builder_for_dev", 1)
```

The façade delegates immediately to `BuilderController`.

Do not implement Builder creation directly in `CppDebugOptions`.

## K behavior

Each accepted `K` press:

```text
desired Builder count += 1
```

Examples:

```text
Initial: 1
K:       2
K:       3
K:       4
```

During daytime:

* Increment the desired count.
* Attempt to spawn exactly the missing Builder immediately.
* Give it a unique target claim near `builder_spot`.
* Do not restart or respawn existing Builders.

During night:

* Increment the desired count.
* Do not spawn a daytime Builder during night.
* Log that the new Builder will appear next morning.

If daytime immediate spawning fails because no free reachable target exists:

* Keep the increased desired count.
* Do not duplicate an existing Builder.
* Log that the roster increased but the missing Builder will be retried next morning.

Use a concise debug log such as:

```text
dev_keys: Builder roster 1 -> 2; active Builders: 2
```

or, on deferred spawn:

```text
dev_keys: Builder roster 2 -> 3; spawn deferred until next day
```

If another active feature still uses `K`, do not silently override it. Remove obsolete temporary house-test wiring if it remains; otherwise report the conflict.

---

# Builder identity

Use semantic constants:

```gdscript
const AGENT_KIND_BUILDER: StringName = &"builder"
const BUILDER_GROUP: StringName = &"builders"
```

Each Builder must:

```gdscript
agent.add_to_group(&"builders")
agent.set_meta("agent_kind", &"builder")
agent.set_meta("spawner_cell", source_spawner_cell)
```

Do not add Builders to:

```text
monsters
clients
merchants
```

The seed merchant cleanup currently relies on `merchants`; Builders must remain distinct.

Register each Builder through:

* Native agent manager.
* Central cell tracker.
* Existing desire/crowd registration path, using a dedicated or appropriate friendly visitor category.
* Existing authoritative agent-removal path.

Do not create a separate movement body.

Use:

```text
res://scenes/entities/character.tscn
```

---

# Builder sprite and animation

Extend:

```text
scripts/map/agent_definition_service.gd
```

with a focused method such as:

```gdscript
func apply_builder_data(agent: Node) -> void
```

Locate the actual `builder.png` asset in the current repository.

Do not duplicate or rename it.

If it is absent, report the exact expected asset path and leave no fake placeholder.

Configure it using the actual current seed merchant sprite contract.

Expected current contract:

```gdscript
sprite.hframes = 4
sprite.frame = 0
sprite.flip_h = false
```

Use the same:

* Frame count.
* Frame interpretation.
* Facing behavior.
* `CharacterAnimation` bounce.
* Idle breathing.
* Sprite scale and offset conventions.
* Y-based z-index behavior.

Do not invent a new animation state machine.

---

# Arrival and idle

For each Builder:

1. Select a unique free spawn cell near `seedmerchent`.
2. Select and reserve a unique reachable target near `builder_spot`.
3. Compute an A* path.
4. Instantiate `character.tscn`.
5. Configure Builder visual and metadata.
6. Register the native agent.
7. Assign the path.
8. Walk toward the claimed target.
9. Detect path arrival through the native path-arrival API.
10. Detach the arrival path.
11. Stop A* arrival state.
12. Remain idle at the claimed tile.

Builders must not:

* Wander after arrival.
* Follow the player.
* Recluster every frame.
* Swap targets unnecessarily.
* Pause when the player approaches.
* Open any prompt.

Builders may stand adjacent to each other.

They may use normal crowd steering while moving.

---

# Walkability changes

While a Builder is walking toward its target, reuse the same bounded repath behavior as the seed merchant.

On hard walkability changes:

* Process every active Builder visitor.
* Skip Builders already leaving.
* Validate the Builder’s current claimed target.
* If the target remains valid and reachable, repath to the same target.
* If the target became blocked or unreachable:

  1. Release its old claim.
  2. Find a new unique claim near `builder_spot`.
  3. Assign a new path.
  4. Preserve all other Builders’ claims.

For a Builder already idle:

* If its claimed cell remains walkable, do nothing.
* If its claimed cell becomes blocked, assign it a new nearby free target and make it walk there.

Do not leave an idle Builder embedded in a new wall.

Do not recompute every Builder path every frame.

Use the existing hard-topology invalidation seam.

Extend `BuildingInvalidationController` so it calls focused visitor methods rather than containing Builder algorithms.

If no replacement target is available:

* Leave the Builder safely at its current valid position when possible.
* Clear its invalid claim.
* Warn once for that invalidation event.
* Do not overlap it onto another Builder’s claimed tile.

---

# Night departure

At night start:

1. Preserve the desired Builder count.
2. Mark every active Builder for departure.
3. Release their daytime target claims.
4. Do not immediately assign escape flow before night navigation preparation is ready.
5. Use the same post-preparation seam as the seed merchant:

```gdscript
BuildingManager.on_night_reveal_finished()
```

6. Start all pending Builder departures.
7. Assign every Builder through the existing escape route associated with its `seedmerchent` source metadata.
8. Allow all Builders and the seed merchant to leave concurrently.
9. Remove each Builder after it reaches `seedmerchent_exit`.

Do not:

* Wait for one Builder to leave before starting the next.
* Create one exit flow per Builder.
* Compute direct A* paths to `seedmerchent_exit`.
* Set desired Builder count to zero.
* Spawn replacements during night.

An escape assignment failure for one Builder must not prevent the others from leaving.

Use the existing safe no-drop removal fallback for a visitor whose escape assignment fails.

---

# Runtime processing

Extend:

```text
scripts/map/building_runtime_tick_controller.gd
```

through focused Builder calls.

It may call:

```gdscript
builder_controller.process_arrivals()
builder_controller.process_active_visitors()
```

Do not add Builder movement algorithms to the runtime tick controller.

Do not scan the `builders` group every frame.

`BuilderController` already owns direct references to all active Builder visitor instances.

The number of Builders is expected to be small, so a direct iteration over the owned active list is appropriate.

Clean invalid visitor entries without mutating an array unsafely during iteration.

---

# Passive friendly behavior

Builders are friendly passive visitors.

They must not:

* Be counted as monsters.
* Be counted as clients.
* Be treated as seed merchants.
* Target gardens.
* Eat plants.
* Trample roses.
* Trample pasteques.
* Eat or destroy turrets.
* Enter tantrum.
* Attack buildings.
* Drop monster currency.
* Show health bars.
* Receive normal combat damage.

Update semantic friendly-agent checks so:

```text
builder
```

is damage-immune.

In `character.gd`, extend the existing damage-immune visitor logic to include:

```gdscript
agent_kind == &"builder"
```

Do not use membership in the `merchants` group to obtain immunity.

## Tile interactions

Add a dedicated Builder category where required.

Builder cell transitions must not fall through to monster behavior.

In particular, ensure `TurretEatingController` explicitly ignores Builders.

Do not solve this by classifying Builders as merchants, because that would currently allow them to crush or consume some placeables.

A Builder should perform no destructive tile interactions in this pass.

Normal water/collision handling may remain consistent with passive agents unless the current code requires an explicit safe category.

---

# Desire and crowd registration

Builders should participate in normal movement occupancy and crowd avoidance.

They must be registered in the central tracker and native movement system.

Add a Builder category to `Desire` only if the existing registration system requires one.

Do not make Builders invisible to crowd steering.

Do not stamp them as monsters.

For a small number of Builders, use the same high-fidelity visitor priority behavior as clients/merchants when that is the closest existing semantic fit, but keep the group and `agent_kind` distinct.

Document the chosen category.

---

# Removal and cleanup

Every authoritative removal path must notify `BuilderController`.

Handle:

* Normal escape arrival.
* Explicit phase clearing.
* Save/load cleanup.
* Scene reload.
* Unexpected node removal.
* Native registration failure.
* Escape assignment failure.

When a Builder is removed:

1. Find the owning visitor instance.
2. Release its target claim.
3. Remove it from the active visitor collection.
4. Clear native/path state through the existing owner.
5. Remove it from `builders`.
6. Do not decrement desired Builder count.
7. Do not notify `SeedMerchantController`.

Update generic escaped-agent cleanup so it distinguishes:

```gdscript
is_merchant
is_builder
```

before groups are removed.

Then notify the correct owner.

Do not use one `is_merchant` boolean for both.

`MonsterDeathController` and other generic removal owners must:

* Remove `builders` group membership.
* Avoid monster drops.
* Notify `BuilderController`.
* Avoid seed merchant phase changes.

---

# Save/load

The authoritative saved value is:

```text
builder_count
```

Do not save:

```text
builder_active
```

because active count becomes zero every night while the persistent roster remains unchanged.

Do not serialize individual Builder agents in the generic agent list.

## Gameplay phase save state

Add:

```gdscript
"builder_count": _builder.builder_count()
```

to:

```gdscript
BuildingManager.serialize_gameplay_phase_state_for_save()
```

Validate it as an integer.

Clamp invalid negative values safely.

For new games and old saves without the field, use:

```text
1
```

Do not default legacy saves to zero.

This ensures the normal Builder exists when loading an older daytime save.

## Restore behavior

On restore:

1. Clear all stale live Builder agents.
2. Restore desired Builder count.
3. Do not restore individual positions, target claims, paths, or departure states.
4. If the loaded game is daytime:

   * Defer restoration using the same scene/navigation safety pattern as the seed merchant.
   * Spawn the desired number of Builders from `seedmerchent`.
   * Recalculate unique target claims near `builder_spot`.
5. If the loaded game is night:

   * Spawn no Builders.
   * Preserve the desired count.
   * Spawn the full roster at the next day start.

Prevent duplicate restore calls.

## Dawn autosave

The dawn autosave must include the actual persistent Builder count.

Do not hardcode:

```text
builder_count = 1
```

after the player has used the dev key.

Query the owning Builder controller or progression state.

## Generic AgentSaveService

Builders must be excluded from `_serialize_live_agents()`.

Update `_clear_existing_agents()` to include:

```text
builders
```

Otherwise loading a daytime save could leave old Builders alive and spawn a second roster.

When discarding unexpected generic Builder agent records from future or malformed saves, log and skip them safely rather than restoring them as monsters.

## Save compatibility

Bump the save version only if required by the current project convention.

Old saves without `builder_count` remain valid.

The field must persist when saving during:

* Day arrival.
* Day idle.
* Night.
* Night departure.

---

# BuildingManager integration

Instantiate:

```gdscript
var _builder: BuilderController = BuilderController.new()
```

Setup:

```gdscript
_builder.setup(self)
```

Keep `BuildingManager` as a façade.

Allowed thin seams include:

```gdscript
func get_builder_controller() -> BuilderController
func add_builder_for_dev(amount: int = 1) -> bool
func _begin_builder_day() -> void
func _start_pending_builder_departures() -> void
```

The manager may also:

* Forward day start.
* Forward night start.
* Forward post-night-preparation readiness.
* Include Builder count in save state.
* Dispatch load restoration.
* Notify Builder removal.

Do not add to `BuildingManager`:

* Builder arrays.
* Claim dictionaries.
* Claim-search loops.
* Per-Builder path state.
* Sprite setup.
* K-key logic.
* Save record parsing beyond thin coordination.

---

# Level loading and configuration flow

Use the existing chain:

```text
LevelLoader
LevelSpawnConfigLoader
SpawnPlaylistConfigService
BuildingManager
```

to carry:

* Exact spawner bindings by ID.
* Named authored spot cells.

Do not overload the monster playlist binding dictionary if it intentionally excludes merchant bindings.

Keep distinct concepts explicit:

```text
all authored spawner bindings
validated playlist spawner bindings
named authored spots
```

Do not change monster playlist validation behavior.

---

# Architecture documentation

Update:

```text
scripts/map/ARCHITECTURE.md
```

Document:

* `BuilderController` owns persistent roster, runtime Builder collection, and spot claims.
* `DayVisitorMovementController` owns one visitor’s arrival/wait/departure navigation.
* `SeedMerchantController` retains merchant interaction behavior.
* `AgentDefinitionService` owns Builder sprite setup.
* `LevelLoader` captures named authored spots.
* `CppDebugOptions` owns the K developer shortcut.
* Builders reuse `seedmerchent`’s escape route.
* Builder count persists independently from active Builder nodes.

---

# Explicitly forbidden implementations

Do not:

* Implement only one `_agent` field in `BuilderController`.
* Store only a boolean `builder_active`.
* Infer the persistent roster from live scene nodes.
* Put Builders in the `merchants` group.
* Copy the entire seed merchant controller.
* Add multiple Builders to the same target tile.
* Make all Builders target `builder_spot` exactly.
* Use random target selection.
* Search the whole map for target cells.
* Recalculate target cells every frame.
* Spawn Builders during night.
* Decrement Builder count when they leave.
* Serialize individual Builder navigation state.
* Add K input outside the existing developer-key controller.
* Let K work when `dev_keys` is false.
* Recreate existing Builders whenever K is pressed.
* Add a new Builder spawner.
* Add a new Builder exit route.
* Hardcode authored cells or world positions.
* Let Builders trample plants or eat turrets.
* Let Builders drop currencies.
* Modify the C++ extension.
* Run Godot or tests.

---

# Likely files

New:

```text
scripts/map/builder_controller.gd
scripts/map/day_visitor_movement_controller.gd
```

Modified as required:

```text
scripts/map/seed_merchant_controller.gd
scripts/map/agent_definition_service.gd
scripts/map/building_manager.gd
scripts/map/building_runtime_tick_controller.gd
scripts/map/building_invalidation_controller.gd
scripts/map/level_loader.gd
scripts/spawning/level_spawn_config_loader.gd
scripts/map/spawn_playlist_config_service.gd
scripts/map/agent_save_service.gd
scripts/map/agent_tile_interaction_controller.gd
scripts/map/turret_eating_controller.gd
scripts/map/monster_death_controller.gd
scripts/entities/character.gd
scripts/gameState/progression.gd
scripts/misc/cpp_debug_options.gd
scripts/map/ARCHITECTURE.md
```

This list is indicative.

Inspect the actual current code and modify only files genuinely required.

Do not modify `level_demo.tscn` merely to create or reposition `builder_spot` if the user has already authored it locally.

---

# Acceptance criteria

## Default roster

* A fresh game has desired Builder count `1`.
* One Builder enters each daytime.
* It spawns from `seedmerchent`.
* It claims `builder_spot` when that tile is free.
* It idles there.
* It leaves through `seedmerchent_exit`.
* It returns the next day.

## Multiple Builders

After pressing `K` once with developer keys enabled:

* Desired Builder count changes from one to two.
* A second Builder appears immediately during daytime.
* The first Builder is not recreated.
* Both use `builder.png`.
* Both originate near `seedmerchent`.
* They use different spawn cells.
* They claim different target cells.
* One may use `builder_spot`.
* The other uses the nearest valid reachable walkable tile.
* Both remain active during the day.
* Both leave at night.
* Both return the next day.

After pressing `K` additional times:

* Builder count continues increasing by one.
* Every successfully spawned Builder gets a unique target claim.
* No Builder is duplicated internally.
* No target cell is shared.

## Dev-key gating

* K does nothing when `dev_keys` is disabled.
* K ignores echo events.
* K uses the existing dev-key input owner.
* K increments the persistent roster.
* K during night defers live spawning until next morning.
* Save/load preserves the added count.

## Target claims

* Claims are deterministic.
* Exact `builder_spot` is preferred.
* Nearby cells are chosen in nearest-first order.
* Every claimed cell is walkable and reachable.
* The seed merchant’s idle tile is excluded.
* Claims are released when Builders leave or are removed.
* No full-map scan occurs.
* No per-frame reclustering occurs.

Claimed tiles must be checked and lazy-recomputed in the lazy-reload of the pathfinder that exists already. It means when a building is having a progress bar because waiting for the lazy load of Flow fields, those claim check/computing must be included.

## Topology changes

* A walking Builder repaths after a hard blocker change.
* Builders retain unique targets.
* If an idle Builder’s tile becomes blocked, it relocates.
* Other Builders keep their valid claims.
* Failure to find a replacement does not overlap agents or crash.

## Night departure

* Every active Builder receives a pending leave request.
* They wait for navigation preparation.
* All can leave concurrently.
* All use the existing `seedmerchent` escape route.
* All exit through `seedmerchent_exit`.
* Active count reaches zero.
* Desired count remains unchanged.

## Save/load

* `builder_count` is saved during day and night.
* Builders are not in the generic live-agent save list.
* Loading daytime recreates the complete roster.
* Loading night recreates none immediately.
* The full roster returns next day.
* Old saves default to one Builder.
* Stale Builder nodes are removed before restoration.
* No duplicate roster appears after load.

## Seed merchant regression

The seed merchant must still:

* Spawn once.
* Use its own exact authored spot.
* Pause near the player after arrival.
* Open the merchant interface.
* Process purchases.
* Leave at night.
* Restore after loading.
* Remain completely independent from the Builder roster.

## Passive behavior

Builders:

* Are damage-immune.
* Have no health bars.
* Have no prompt.
* Do not pause near the player.
* Do not trample plants.
* Do not eat turrets.
* Do not attack.
* Do not drop currency.
* Are not counted as monsters, clients, or merchants.

---

# Manual test plan

Do not run these tests. Include them in the final report.

1. Start a fresh level and verify one Builder.
2. Verify the Builder reaches `builder_spot`.
3. Press K once and verify a second Builder appears.
4. Verify the first Builder is not respawned.
5. Verify both claim different cells.
6. Press K several times and verify unique nearby claims.
7. Disable developer keys and verify K does nothing.
8. Press K during night and verify the added Builder waits until next day.
9. Add a wall over a walking Builder’s target and verify reassignment.
10. Add a wall over an idle Builder’s claimed cell and verify relocation.
11. Fill the area around `builder_spot` and verify safe bounded failure.
12. Start night and verify every Builder leaves.
13. Verify active count becomes zero but desired count is preserved.
14. Start the next day and verify the entire roster returns.
15. Save during daytime with several Builders and reload.
16. Save during night with several Builders and reload.
17. Load an older save without `builder_count`.
18. Verify the seed merchant still behaves exactly as before.
19. Verify Builders do not interact destructively with plants or turrets.
20. Verify no Builder creates monster drops.

---

# Final report

Report:

1. Every created and modified file.
2. Final ownership of desired count, active visitors, and target claims.
3. How the single-agent visitor helper is shared with the seed merchant.
4. How exact `seedmerchent` and `builder_spot` data are resolved.
5. The deterministic target-claim algorithm and radius.
6. How target uniqueness is enforced.
7. How K increments the persistent roster.
8. K behavior during day and night.
9. How multiple Builders spawn without cell duplication.
10. How topology changes reassign invalid claims.
11. How all Builders leave concurrently through the existing route.
12. How `builder_count` is saved and restored.
13. How old saves default to one Builder.
14. How Builders are excluded from generic agent serialization.
15. How seed merchant behavior was preserved.
16. Any private manager coupling retained.
17. Any architecture concern discovered.
18. Manual tests without claiming they were run.
