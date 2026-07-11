I resolved “no debris” as **no debris for destroyed structures**. Plants reuse the existing immediate creature-destruction path and its current plant visual semantics.

# Task — Per-agent client tantrum and generic player-built structure destruction

Implement this feature in the current Godot codebase.

## Working rules

* Do not guess. Inspect the relevant implementation before editing. Ask only if the code contradicts this specification.
* Do not run Godot, tests, compilation, exports, or build commands. The user tests manually.
* GDScript strict typing is enabled. Use explicit local types; avoid unsafe `:=` inference.
* Prefer simple, readable, production-oriented code.
* Do not put another large responsibility into `building_manager.gd`.
* Add dedicated ownership where appropriate.
* Do not perform unrelated cleanup.
* Do not add building-specific logic to the C++ extension.
* Existing native APIs are sufficient:

  * `AgentManagerNative.set_agent_paused()`
  * `assign_agent_path()`
  * `detach_agent_path()`
  * `detach_agent_flow()`
* The C++ addon must remain generic.

---

# Required gameplay behavior

## Exact tantrum trigger

A client may enter tantrum **only at the exact moment it finishes walking to a rose-shop counter and discovers that counter is empty**.

At that moment, check the authoritative current rose availability:

```text
total counter stock > 0
OR
grown-up normal roses currently present on the plant layer > 0
```

If either source still contains a rose:

* the client must not enter tantrum;
* retarget it through the existing client targeting logic.

If:

```text
total counter stock == 0
AND
grown-up normal rose count == 0
```

then that specific client has zero chance of obtaining a rose and enters tantrum.

Do not use cached garden availability as the final authority for this condition. Use the existing authoritative counter-stock and `PlantManager.grownup_rose_count()` sources.

Tantrum must never begin from:

* `ClientSaleController` noticing that global targets are empty;
* a client spawn check;
* a plant disappearing;
* a generic retarget failure;
* another client entering tantrum;
* any global conversion function.

There must be one clear call site for the actual transition: empty-counter arrival handling.

## Independent clients

Tantrum is per agent.

When one client enters tantrum:

* do not clear pending client spawns as a side effect of the tantrum transition;
* do not clear all counter-bound agents;
* do not convert every rose-less client;
* do not stop the normal client-sale controller;
* do not change the state of other clients.

Other clients continue their own behavior normally.

Several clients may independently enter tantrum at different times.

They do not attack or otherwise react to one another.

The client phase must remain active until:

* all normal clients have finished or despawned; and
* all tantrum clients have been killed.

---

# Existing behavior that must be removed

The current `ClientTantrumController.begin()` behavior is obsolete.

It currently:

* starts tantrum globally;
* clears all sale spawns;
* clears all counter agents;
* converts every rose-less client;
* creates one shared flow-field group;
* routes all hostiles toward a reservoir.

Remove this global behavior.

Also remove or retire:

* the shared tantrum flow-field group;
* reservoir-only targeting;
* global reservoir flow rebuilding;
* hostile restoration from saves;
* `restore_live_hostiles()`;
* `_restore_hostile()`;
* any BuildingManager wrappers that exist only for the old reservoir-only tantrum controller.

Do not retain dead compatibility code without a real caller.

---

# Per-client tantrum transition

Replace the global entry point with an explicit API such as:

```gdscript
func start_for_client(client: Node2D) -> bool:
```

A successful transition must:

1. Validate the client and its `nav_id`.
2. Ensure it does not already own a rose.
3. Detach its current native path and flow.
4. Clear only that agent’s navigation records.
5. Keep it in the `clients` group.
6. Add it to `monsters` if required by the existing combat system.
7. Set:

   * `agent_kind = client`
   * `hostile_client = true`
   * current and maximum agent health to the existing tantrum-client value of `100`
8. Call the existing angry-state behavior so the client becomes damageable.
9. Start the three-second tantrum wind-up described below.
10. Add only this client to `_hostile_clients`.
11. Show or refresh the existing tantrum alert using the current hostile count.

`ClientTantrumController.is_active()` should mean that at least one tantrum client is active. It must not imply that all normal client processing should stop.

---

# Three-second tantrum wind-up

When a client enters tantrum:

* it stops for exactly `3.0` seconds;
* its native steering must be hard-paused using:

```gdscript
AgentManagerNative.set_agent_paused(nav_id, true)
```

Calling only `FlowAgent.set_paused()` is not sufficient because native steering owns movement.

During these three seconds:

* force the existing tantrum **SOUTH** frame;
* do not allow directional facing updates to replace it;
* play the existing fear-style shaking effect;
* the shake must be visual only;
* do not shake or tween the agent’s world position;
* the client remains damageable;
* damage and knockback do not interrupt or shorten the wind-up;
* native hard pause must prevent knockback from moving it.

The supplied scripts do not expose an obvious reusable fear-shake helper. Search the full repository once. If no reusable implementation exists, add a small visual-only implementation.

For a fallback implementation:

* shake `MonsterSprite2D.offset.x` or another visual-only property;
* preserve and restore the exact original value;
* do not fight `CharacterAnimation` by continuously overwriting its managed `position`;
* do not modify `client.global_position`.

After exactly three seconds:

* stop and cleanly restore the shake;
* clear the forced-SOUTH override;
* select a target;
* calculate its path;
* unpause native steering only when a valid path has been assigned.

Use an explicit per-hostile stage, for example:

```text
windup
waiting_for_target
moving
attacking
```

Do not infer the state from unrelated fields.

---

# Generic player-built destructible system

All player-built placeables must be destructible targets.

This includes current and future player-built:

* walls;
* fences;
* rose-shop counters;
* turrets;
* lamps;
* reservoirs;
* pasteques;
* ronces;
* normal roses;
* imperial plants;
* other catalog placeables.

Only objects actually built by the player are targetable.

Level-authored objects must not automatically become tantrum targets merely because they use the same atlas tile or item definition.

## Dedicated ownership

Create a dedicated service instead of adding the full system to `BuildingManager`.

A suitable name is:

```text
scripts/map/player_placeable_durability_service.gd
```

The exact name may differ if the repository already has a better matching owner, but ownership must remain dedicated.

This service should own:

* player-built provenance;
* live target registration;
* current health;
* maximum health;
* damaged-state queries;
* target validity;
* cheap nearest-target selection;
* damage application;
* instant plant destruction;
* save serialization and restoration.

`ClientTantrumController` owns hostile-client behavior.

`BuildRemovalService` remains the owner of actual tile/placeable removal and associated cleanup.

`BuildingManager` should only expose thin, typed accessors or orchestration methods where needed.

## Player-built provenance

Do not infer player-built status by scanning all existing layers at startup.

Register provenance when placement succeeds through `BuildPlacementService.after_placeable_placed()` or a closely related central placement hook.

Unregister it through the central removal path.

Persist provenance in saves so player-built structures remain identifiable after loading.

Level-authored structures discovered by:

```gdscript
BuildingObjectManager.initialize_from_layer()
```

must remain unregistered unless the save explicitly identifies them as player-built.

For older saves that contain no provenance section:

* continue loading the save;
* do not guess that ambiguous level tiles are player-built;
* log a concise compatibility warning if useful.

## Stable target representation

Do not require every target to have a runtime `Node2D`.

Walls, fences and other TileMap objects must work without creating one Node per tile.

Use a stable target key based on data such as:

```text
layer role + cell
```

A target record should contain only the data actually required, for example:

```gdscript
{
    "key": String,
    "cell": Vector2i,
    "item_id": String,
    "layer_name": String,
    "health": int,
    "max_health": int,
    "instant_destroy": bool,
}
```

Avoid loosely typed target dictionaries scattered across several files. Keep creation and validation centralized in the durability service.

---

# Health configuration

Add a data-driven `max_health` field to current player-buildable item definitions in:

```text
scripts/items/item_catalog.gd
```

Use `100` for all current non-plant placeables in this pass. This preserves the existing reservoir health baseline and leaves individual balancing for later.

Plants are instant-destroy targets, so their health value is not used for repeated attacks.

Future player-built placeables must become destructible automatically when they are normal `type == "placeable"` catalog entries. Do not require editing `ClientTantrumController` for every new building type.

Do not add a hardcoded switch listing every current item ID.

---

# Health bars

Every damaged non-plant player-built structure must display a health bar.

The health bar:

* is hidden at full health;
* appears after the first damage;
* remains visible while health is below maximum;
* disappears when the structure is removed;
* must work for TileMap-only targets such as walls and fences.

Do not create a runtime node for every wall merely to display health.

Create a single lightweight overlay, for example:

```text
scripts/map/building_health_overlay.gd
```

It should draw bars only for currently damaged registered structures and redraw only when health or registrations change.

Follow the existing `BuildingConstructionOverlay` pattern where useful.

There must be one authoritative health source. Do not allow `ReservoirRuntime` and the new durability service to independently damage the same player-built reservoir.

The tantrum controller must use the generic durability service, not `ReservoirRuntime.take_damage()`.

---

# Cheap target selection

The priority is low computation.

Use this strategy:

1. Scan live player-built targets using squared Euclidean world distance.
2. Select the closest target.
3. Compute only one route for that chosen target.
4. Keep that target until it is destroyed, removed, or proven unreachable.
5. Do not continuously switch targets.
6. Do not calculate a path or route cost to every candidate.
7. Do not create one flow-field group per building.
8. Do not rebuild a shared tantrum flow whenever a target changes.

Use deterministic tie-breaking for equal distances, such as layer/key or cell coordinates.

The reservoir has no special priority. It competes like every other structure.

## Attack access cell

Do not path directly into an occupied wall or blocking-building cell.

For structures:

* find the cheapest valid adjacent attack cell using a small local neighbor check;
* use the existing authoritative walkability methods;
* choose by squared distance from the client;
* a valid diagonal adjacent cell is acceptable because attack range is `1.5` tiles.

For plant-layer targets:

* the plant cell itself may be the endpoint because plants are walkable and are destroyed on contact/range.

Use the existing:

```gdscript
BuildingPathService.find_path_on_walkable_map()
BuildingPathService.path_cells_to_world()
AgentManagerNative.assign_agent_path()
```

Do not add building-specific pathfinding to C++.

## Avoid path spikes

Several wind-ups may finish close together.

Do not perform an unbounded number of full A* requests in one frame.

Add a small retarget/path-assignment queue in `ClientTantrumController`, processing at most one expensive path attempt per frame unless the current architecture already provides a suitable budget.

A cheap target scan may happen when needed, but expensive path requests must be budgeted.

If the closest target has no valid attack cell or no path:

* mark that target rejected for this selection attempt;
* try the next closest target on a later budgeted tick;
* do not run several expensive A* attempts in one frame.

If all current targets are unreachable:

* keep the hostile client safely paused;
* avoid retrying every frame;
* retry when the target/topology revision changes.

If no target exists and game over has not already been triggered, log a warning because this contradicts the expected level invariant.

---

# Moving and attacking

Once a valid path has been assigned:

* unpause native steering;
* set the hostile stage to `moving`;
* wait until the path arrives or the agent enters attack range.

Attack range remains:

```text
1.5 tiles
```

When the target is reached:

* hard-pause native steering;
* enter `attacking`;
* keep the selected target until it disappears;
* use the existing attack interval and damage:

  * `1` damage;
  * one attack every `3.0` seconds;
* preserve the short lunge/return visual timing:

  * `0.09` second lunge;
  * `0.12` second return.

The lunge must be visual only. Do not tween `client.global_position`, because native steering owns the authoritative body position. Offset the sprite or another visual child and restore its exact original transform after the animation.

Use the existing damage-number display.

When a structure reaches zero health:

* remove it through the normal low-level removal/cleanup path;
* do not refund inventory or currency;
* do not create structure debris;
* stop/remove turret runtime behavior through existing `BuildingObjectManager` cleanup;
* clear counter stock through the existing counter-removal callback;
* update collisions, speed data, fence autotiling and navigation exactly as a normal removal requires;
* do not duplicate these cleanup rules in the tantrum controller.

Refactor `BuildRemovalService` so it supports both:

```text
normal player unbuild -> remove + refund
hostile destruction   -> same removal cleanup, no refund
```

Do not call the refunding commit method and then attempt to undo the refund.

## Plants

Player-built plants are valid deliberate targets.

When a hostile client reaches a plant target:

* destroy it immediately;
* do not run the three-second repeated structure attack;
* reuse the existing authoritative plant consume/trample removal behavior rather than manually erasing only the tile;
* preserve the existing plant visual/removal semantics;
* then select another target.

Do not hardcode only normal roses. The generic plant-layer rule must also support imperial plants and future player-built plant-layer placeables.

---

# Retargeting

Retarget only when:

* the current target has been destroyed;
* the current target was removed through another system;
* target validation fails;
* no path exists to the selected target.

Do not rescan targets every frame.

If several hostile clients selected the same target:

* they may all attack it;
* when one destroys it, the others must detect invalidation and independently retarget;
* no hostile may retain a stale tile/runtime reference.

When retargeting:

* detach the obsolete native path;
* ensure the agent is safely paused during target/path selection;
* clear attack visual state;
* clear rejected-target state when a topology/target revision makes it stale.

---

# Reservoir and game over

A player-built reservoir is an ordinary target for target selection.

It is not prioritized.

When a player-built reservoir reaches zero health:

1. call the existing authoritative reservoir-destroyed game-state path;
2. ensure `GameState.is_reservoir_destroyed` becomes true;
3. remove the built reservoir through the generic no-refund destruction path;
4. allow the existing game-over UI/controller to react.

Do not create a second independent game-over system.

The expected level invariant is that if no player-built target remains, the reservoir has already been destroyed and game over is active.

---

# Client sale controller changes

Update `scripts/map/client_sale_controller.gd`.

The current behavior that globally calls tantrum when no targets remain must be removed.

Specifically, this type of logic must not remain:

```gdscript
if not has_client_targets_remaining():
    if has_clients_without_rose():
        client_tantrum.begin()
```

When no rose targets remain:

* pending future client spawns may be cancelled using the existing sale logic;
* existing clients are not globally converted;
* normal clients already holding roses continue escaping;
* normal clients without roses continue according to their current navigation;
* only an individual empty-counter arrival can trigger its tantrum.

Do not return early from the entire client-sale process merely because one or more hostiles exist.

Sale completion must continue to require:

```text
no pending client spawns
no normal clients
no counter-bound clients
no hostile clients
tantrum controller inactive
```

---

# Counter arrival changes

Update:

```text
scripts/map/agent_navigation_phase_controller.gd
```

In `process_client_counter_arrivals()`:

1. Detect the arrived agent as currently done.
2. Stop its counter A* state.
3. If the selected counter still has stock, complete payment normally.
4. If that counter is empty:

   * check authoritative global rose availability;
   * if any counter stock or grown-up normal rose remains, use existing retarget logic;
   * otherwise call `ClientTantrumController.start_for_client(agent)`.

Do not call a parameterless/global tantrum method.

Keep empty-counter handling centralized so the condition cannot diverge between controllers.

---

# Saving

## No save during tantrum

Saving must be rejected while:

```text
ClientTantrumController.is_active()
OR
ClientTantrumController.has_hostiles()
```

Add the guard at the very beginning of:

```gdscript
progression.gd::save_progression()
```

It must run before:

* layer serialization;
* runtime-agent serialization;
* file opening;
* overwriting either save slot.

When rejected:

* return `false`;
* do not alter the existing save file;
* show this exact user-facing message:

```text
NO SAVE DURING TANTRUM
```

Use the existing notification mechanism.

This guard applies to manual and automatic calls to `save_progression()`.

Do not serialize:

* hostile target;
* hostile attack stage;
* wind-up timer;
* attack cooldown;
* hostile paths;
* tantrum client metadata for restoration.

Remove obsolete hostile restoration code.

## Save building provenance and health

Partial building damage remains after tantrum ends and must survive later saves.

Increment the save format to version `3`.

Add a dedicated save section, for example:

```json
"player_placeable_durability": [
  {
    "x": 10,
    "y": 12,
    "layer": "wallz",
    "item_id": "wall",
    "health": 72,
    "max_health": 100
  }
]
```

This section is authoritative for:

* which surviving placeables are player-built;
* their current health;
* their saved maximum health.

On load:

1. restore TileMap layers;
2. reindex `PlantManager` and `BuildingObjectManager`;
3. restore player-built durability/provenance;
4. validate every saved record against the actual live item at that layer/cell;
5. ignore invalid or stale records with a concise warning;
6. clamp health safely;
7. redraw health bars.

Keep loading version `1` and version `2` saves.

Do not infer ambiguous player-built provenance for old saves.

Update save validation and save summaries accordingly.

---

# Existing reservoir runtime

Review:

```text
scripts/map/reservoir_runtime.gd
scripts/map/building_object_manager.gd
scripts/map/reservoir_system.gd
```

The generic durability service must be authoritative for player-built reservoir damage.

Avoid:

* two health bars;
* two current-health values;
* calling both generic damage and `ReservoirRuntime.take_damage()`;
* removing only reservoir sprites while leaving its registered tile/building alive.

Level-authored reservoir behavior may remain compatible, but it must not cause level-authored reservoirs to appear in the player-built target registry.

---

# Cleanup and lifecycle safety

When a hostile client dies or is otherwise removed:

* clear it from `_hostile_clients`;
* cancel/kill any visual attack tween owned by its state;
* restore any modified sprite offset if the node still exists;
* unpause its native agent before native unregister if required;
* remove pending target/path requests for its `nav_id`;
* refresh the tantrum alert;
* call `end()` only when no hostile clients remain.

When tantrum fully ends:

* hide the existing alert;
* do not alter normal client state;
* do not dissolve any obsolete flow group because the new implementation must not create one.

Phase reset, level reload and manager cleanup must not leave an agent paused or a health overlay holding stale records.

---

# Performance requirements

The completed system must not:

* scan all targets for every hostile every frame;
* compute route cost to every building;
* allocate one flow field per target;
* rebuild a flow field whenever an agent changes target;
* create one runtime Node per wall;
* create one health-bar node per structure;
* perform unlimited A* queries in one frame;
* repeatedly rebuild navigation for non-topology health changes.

Taking damage does not affect navigation.

Only actual destruction should run the existing removal/navigation consequences.

Wall destruction is a real topology change and may trigger the existing wall-removal rebuild path.

Turret, lamp and other non-topology destruction must preserve the existing optimized invalidation classification.

---

# Expected files

Inspect first, but the implementation will likely involve:

```text
scripts/map/client_tantrum_controller.gd
scripts/map/agent_navigation_phase_controller.gd
scripts/map/client_sale_controller.gd
scripts/map/building_manager.gd
scripts/map/buildsystem.gd
scripts/map/build_placement_service.gd
scripts/map/build_removal_service.gd
scripts/map/building_object_manager.gd
scripts/items/item_catalog.gd
scripts/gameState/progression.gd
scripts/entities/character.gd
scripts/map/reservoir_runtime.gd
```

Likely new dedicated files:

```text
scripts/map/player_placeable_durability_service.gd
scripts/map/building_health_overlay.gd
```

Do not force all logic into these exact names if an existing owner clearly fits better, but explain any deviation.

---

# Manual acceptance scenarios

The implementation must support all of these cases.

## Trigger correctness

1. The arrived counter is empty, but another counter has stock:

   * no tantrum;
   * client retargets.

2. Every counter is empty, but one grown-up normal rose exists on the floor:

   * no tantrum;
   * client retargets.

3. Every counter is empty and no grown-up normal rose exists:

   * only the client that just arrived enters tantrum.

4. Another client elsewhere does not enter tantrum merely because the first one did.

## Wind-up

5. The new hostile stops for three seconds.

6. It displays the SOUTH tantrum frame and visual shake.

7. It remains damageable.

8. Knockback does not move it or interrupt the three-second timer.

## Targeting and combat

9. After the wind-up, it chooses the nearest player-built target by squared distance.

10. A closer wall is selected instead of a farther reservoir.

11. A level-authored object using the same item tile is ignored.

12. The hostile does not continuously switch targets.

13. A plant is destroyed immediately when reached.

14. A structure loses one health per attack.

15. Its health bar appears after the first damage.

16. Two hostiles may attack the same structure.

17. When the target is destroyed, surviving hostiles retarget.

18. Destroying a wall uses the existing topology-removal path.

19. Destroying a turret does not cause an unnecessary full flow-field rebuild.

20. Destroying a counter clears its stored roses.

21. No structure refund is granted.

22. No structure debris is spawned.

23. Destroying a reservoir triggers the existing game-over state.

## Phase behavior

24. Normal clients continue processing while hostile clients exist.

25. The client phase cannot finish while any hostile remains alive.

26. Once all hostile and normal clients are gone, phase completion works normally.

## Save behavior

27. Pressing save during tantrum shows:

```text
NO SAVE DURING TANTRUM
```

28. The save file is not overwritten.

29. After tantrum ends, saving is allowed.

30. Partially damaged structures retain their health after loading.

31. Player-built provenance remains correct after loading.

32. No hostile attack state is restored because tantrum saves are impossible.

---

# Final report

After implementation, provide:

1. Files added and changed.
2. The final ownership split.
3. The exact global tantrum behavior that was removed.
4. How player-built provenance is tracked.
5. How target selection avoids excessive computation.
6. How structure destruction reuses normal removal without refunds.
7. How health and provenance are saved.
8. Any remaining compatibility concern.
9. Confirmation that Godot/tests/builds were not run.

This is ready to paste into the coding agent.
