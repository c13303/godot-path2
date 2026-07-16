# Refactor: remove the `traversable_buildings` TileMapLayer and replace it with generic runtime placeables

Read `AGENTS.md` and `scripts/map/ARCHITECTURE.md` before editing.

Do not run Godot, tests, compilation, export, or build commands. I will test manually.

## Objective

`traversable_buildings` is no longer a valid visual/storage TileMapLayer.

Remove the actual `Map/MonTilemap/traversable_buildings` TileMapLayer entirely.

The name `traversable_buildings` may remain as a **logical placeable-layer identifier** for:

* item catalog classification
* durability keys
* save compatibility
* contact/stomp target identity
* removal/destruction dispatch

However, it must no longer refer to a scene node or `TileMapLayer`.

Every placeable currently assigned to this logical category must instead exist as an authoritative one-cell record in `BuildingObjectManager` with a z-indexed runtime visual.

The migration set is:

* `pasteque`
* `ronce`
* `lamp`
* `reservoir`
* `kraken`

Do not move these onto `blocking_buildings`. They remain traversable and must not become movement blockers.

---

# Required result

After this refactor:

1. There is no `traversable_buildings` TileMapLayer in `mainRun.tscn` or any level scene.
2. Placing one of the five placeables never calls `set_cell()` on a persistent building layer.
3. Their logical cell occupancy is owned by `BuildingObjectManager`.
4. Their visuals are runtime `Node2D`/`Sprite2D` objects using world-depth sorting.
5. Their speed modifiers continue working through the existing live terrain-speed system.
6. Their damage flash uses the existing generic durability damage signal.
7. Their health bars use `BuildingHealthOverlay`.
8. Their normal removal, hostile destruction, irrigation cleanup, save/load, contact interactions, and inventory refunds continue to work.
9. Kraken remains fully functional and `KrakenSystem` can still retrieve its `KrakenVisual`.
10. No invisible replacement TileMapLayer or hidden marker tile is introduced.

---

# Architecture

## 1. `BuildingObjectManager` becomes authoritative

For logical `traversable_buildings` placeables, `BuildingObjectManager` must own:

* cell
* item ID
* catalog definition
* logical target-layer name
* direction when applicable
* runtime visual node
* runtime-specific serializable state
* occupancy query
* removal
* optional light component
* optional slowdown properties through catalog lookup

Use the existing `_buildings_by_cell` registry rather than creating a second parallel registry.

Expose or retain clear public queries such as:

```gdscript
func has_building(cell: Vector2i) -> bool
func get_building(cell: Vector2i) -> Dictionary
func get_placeable_item_id(cell: Vector2i) -> String
func get_building_cells() -> Array[Vector2i]
func get_building_cells_by_item_id(item_id: String) -> Array[Vector2i]
func get_runtime_node(cell: Vector2i) -> Node2D
```

Add a focused query for the exact use case if needed, for example:

```gdscript
func has_runtime_traversable_placeable(cell: Vector2i) -> bool
```

Do not let external services inspect private dictionaries.

The logical layer identifier can remain:

```gdscript
const TRAVERSABLE_BUILDINGS_LAYER: String = "traversable_buildings"
```

Centralize this identifier instead of scattering new raw string comparisons.

Clearly comment that it is a logical category and not a TileMap node.

## 2. Do not create an abstract framework

Create one small concrete generic visual implementation for simple placeables, for example:

```txt
scripts/map/simple_placeable_visual.gd
```

or another equally clear name.

It should be used by:

* Pasteque
* Ronce
* Lamp

Complex visuals remain specialized:

* Reservoir keeps a dedicated runtime visual/controller.
* Kraken keeps `KrakenVisual`.

Do not introduce speculative abstract base classes, service locators, or plugin-style architecture.

Use a small common public contract through normal Godot method checks:

```gdscript
play_damage_flash(duration: float)
request_contact_dance(duration: float)
get_health_bar_anchor_world_position() -> Vector2
serialize_placeable_state() -> Dictionary
restore_placeable_state(state: Dictionary)
```

Only implement methods that are relevant to each visual.

---

# Runtime-node ownership

`_runtime_nodes_by_cell` must contain exactly one authoritative runtime root per placeable cell.

Fix the current component-registration problem where registering a light can overwrite the runtime-node entry created for another visual.

For Lamp:

* the runtime root contains its Sprite2D
* its `PointLight2D` is attached to the same runtime root
* `_runtime_nodes_by_cell[cell]` continues to point to that one root
* removing the building frees both sprite and light

For Kraken:

* `get_runtime_node(cell)` must continue returning the actual `KrakenVisual`
* do not wrap it in a generic node that breaks casts in `KrakenSystem`
* attach only compatible child components if necessary

For Reservoir:

* use one dedicated runtime root
* do not create a separate orphan visual and a separate registry node

---

# Generic simple visual

The simple runtime visual must support catalog-driven configuration for the immediate requirements only:

* texture
* optional atlas/frame region
* local sprite offset
* optional contact-dance support
* z-index/world-depth placement
* red damage flash
* health-bar anchor

A reasonable catalog structure would be something like:

```gdscript
"building_sprite_visual": {
    "texture": SOME_TEXTURE,
    "frame_size": Vector2i(32, 32),
    "frame": 0,
    "offset": Vector2.ZERO,
    "contact_dance": true,
    "health_bar_offset": Vector2(0.0, -16.0),
}
```

The exact field names can differ, but keep the configuration narrow and readable.

Do not hardcode separate `if item_id == ...` visual construction branches for Pasteque, Ronce, and Lamp inside `BuildingObjectManager`.

## Damage flash

The generic simple visual must implement:

```gdscript
func play_damage_flash(duration: float) -> void
```

Behavior:

* immediately tint the visible sprite red
* tween back to its exact original modulation
* repeated hits restart the flash cleanly
* no permanent color corruption
* freeing the visual during a tween must be safe

Use the existing `PlaceableDamageFeedback` signal path. Do not introduce another damage event system.

## World depth

Every runtime placeable visual must use the existing `WorldDepthSort` system.

Do not use a fixed high z-index.

In particular, remove the Reservoir-specific fixed `RESERVOIR_Z_INDEX = 510` behavior.

The visual should sort naturally against:

* player
* monsters
* clients
* villagers
* plants
* other buildings

The sprite’s visual bottom should be the depth anchor. Apply a local offset where a sprite is taller than one tile.

---

# Item-specific requirements

## Pasteque

* Replace the persistent tile visual with `pasteque.png`.
* It must be a normal z-indexed runtime Sprite2D.
* It must flash red when damaged.
* It uses the existing generic health/durability system.
* It remains traversable.
* It remains stompable.
* Preserve:

  * `max_health = 100`
  * irrigation radius
  * inventory-backed placement
  * creature stomp damage
  * debris on destruction
  * agent recheck on placement
  * current removal/refund behavior
* The floor beneath the Pasteque must be wet grass, not a building tile.
* On successful placement, ensure the center floor is converted to wet grass without a visible dry-frame delay.
* Preserve the existing expanding irrigation patch.
* On unbuild or destruction, preserve the existing shrinking irrigation cleanup and dry-floor restoration semantics.
* Never stamp the former Pasteque atlas tile into another persistent TileMap layer.

## Ronce

* Replace its persistent tile visual with a z-indexed runtime Sprite2D.
* Use the dedicated Ronce texture if one exists in the repository.
* If no standalone texture exists, create a Sprite2D-compatible atlas subtexture from the existing visual source. Do not retain the TileMap visual merely because a standalone PNG is absent.
* Preserve:

  * traversability
  * `speed_multiplier = 0.3`
  * grass-floor requirement
  * contact visual behavior
  * agent recheck on placement
  * `max_health = 100`
* The new generic simple visual must respond to the existing `request_contact_dance()` route.
* It must flash red when damaged.

## Lamp

* Replace its persistent tile visual with a z-indexed runtime Sprite2D.
* Use a dedicated Lamp texture if one exists; otherwise use an atlas subtexture through Sprite2D.
* Preserve:

  * traversability
  * current light radius/configuration
  * night-only light enabling
  * `max_health = 100`
* The light and sprite must be children/components of the same authoritative runtime node.
* The visible lamp must flash red when damaged.
* Removing or destroying the lamp must remove the light immediately.

## Reservoir

The Reservoir is already partially runtime-rendered, but its implementation is special-cased and duplicated.

Refactor it into the same authoritative runtime-placeable lifecycle:

* registered in `BuildingObjectManager`
* no traversable marker tile
* z-indexed through `WorldDepthSort`
* one runtime root
* existing `reservoir.png`
* existing water-fill visual
* existing irrigation source
* existing `reservoirs` group behavior where still needed

Remove duplicated durability ownership from `reservoir_runtime.gd` where it conflicts with `PlayerPlaceableDurabilityService`.

There must be one source of truth for:

* health
* damage
* health-bar visibility
* destruction

That source should be `PlayerPlaceableDurabilityService`, like the other player placeables.

Remove the Reservoir’s private health-bar drawing if `BuildingHealthOverlay` now handles it.

Implement `play_damage_flash()` on the Reservoir visual using the same red-flash contract.

On destruction:

* remove the runtime visual
* clear the building registry entry
* preserve irrigation/destruction cleanup
* preserve `GameState.set_reservoir_destroyed(true)`
* preserve the intended game-over behavior
* do not leave an orphan `reservoirs` group node

Audit level-authored reservoirs. They must also be represented through the runtime placeable registry instead of a separate visual-only special case.

## Kraken

Kraken already has the correct general visual direction.

Migrate it away from the invisible traversable TileMap marker while preserving:

* `KrakenVisual`
* all attack/eating/retraction behavior
* damage flash
* slowdown
* stompability
* health
* debris
* placement conditions
* save/load state
* `KrakenSystem` lookup and type casts

Replace `_kraken_layer()` and any TileMap-based coordinate dependency with a neutral map reference such as the floor/reference grid.

Do not alter Kraken gameplay tuning during this refactor.

---

# Placement system

## Runtime-only placement path

`BuildPlacementService` currently expects every non-plant placeable to resolve to a real `TileMapLayer` and stamps a tile with `set_cell()`.

Add a clean runtime-only branch for logical `traversable_buildings` definitions.

Do not fake this by returning `floorz`, `wallz`, or `previewbuild` as their storage layer.

For these placeables:

1. Validate the cell using the normal floor and placement rules.
2. Check all occupancy sources.
3. Purchase/consume the item.
4. Register the placeable through `BuildingObjectManager.add_building()`.
5. Refresh the live terrain speed for the cell.
6. Register durability provenance.
7. Trigger irrigation or specialized setup.
8. Displace actors if current behavior requires it.
9. Play build FX.
10. Never stamp a persistent building tile.

A TileMap may still be used as a coordinate reference for:

* `map_to_local`
* `local_to_map`
* build FX positioning
* temporary preview rendering

It must not be used as authoritative storage.

## Occupancy

A runtime traversable placeable still occupies its cell for construction.

Update `is_placeable_occupied()` so it checks `BuildingObjectManager` instead of `traversable_buildings.get_cell_source_id()`.

It must prevent overlap with:

* another runtime traversable placeable
* blocking buildings
* fences
* walls
* plants
* houses, including entrances
* bamboo/permanent world features
* water or invalid floor according to the existing rules

Do not make runtime traversable placeables block movement merely because they occupy a construction cell.

## Drag placement

Audit drag placement, but do not broaden the feature unnecessarily.

If any runtime traversable placeable is drag-buildable, support it without tile stamping.

If none currently require drag placement, preserve the existing item rules and avoid speculative new drag architecture.

## Preview

`previewbuild` may remain a temporary TileMapLayer.

The prohibition concerns persistent world representation and logic, not the transient build preview.

Where an existing runtime visual preview path already exists, reuse it. Do not rewrite the entire preview system solely for this task.

---

# Removal and hostile destruction

`BuildRemovalService` currently requires a real `TileMapLayer` in removal records.

Extend the removal record so a runtime traversable placeable can be represented logically, for example:

```gdscript
{
    "item_id": item_id,
    "cell": cell,
    "layer_name": "traversable_buildings",
    "runtime_placeable": true,
}
```

Do not insert a fake TileMapLayer.

`removable_at_cell()` must query `BuildingObjectManager` for runtime placeables.

Normal unbuild must:

* validate that the same item still exists at the cell
* clear Pasteque irrigation before removal when relevant
* unregister durability
* remove the BuildingObjectManager record
* free the runtime visual
* refresh terrain speed
* refund exactly once
* run item-specific cleanup
* not trigger hard navigation invalidation for speed-only/traversable objects

`BuildSystem.destroy_placeable_no_refund()` must support the logical `traversable_buildings` layer without requiring `get_cell_source_id()`.

Hostile destruction and normal unbuild must continue to share the same low-level cleanup path, differing only in refund behavior.

---

# Slowdown and navigation

Remove every terrain-speed dependency on a physical `traversable_buildings` layer.

The effective multiplier for a cell must include:

* logical plants from `PlantManager`
* relevant physical TileMap layers
* the runtime placeable registered in `BuildingObjectManager`
* static/permanent terrain-speed contributors

Update both initialization paths:

* `BuildSystem._sync_terrain_speed_cells()`
* `BuildingNavigationSyncService.sync_all_terrain_speed_cells()`

Runtime placeable cells must be included by enumerating `BuildingObjectManager.get_building_cells()`.

When calculating one cell’s multiplier, resolve the runtime item ID from `BuildingObjectManager` and apply:

```gdscript
PlaceableNavImpact.def_speed_multiplier(item_def)
PlaceableNavImpact.def_player_speed_multiplier(item_def)
```

Preserve the minimum-of-all-contributors rule.

Adding or removing Ronce/Kraken/etc. must update only the affected speed cell.

It must not:

* rebuild global flow fields
* mark garden topology dirty
* create static steering obstacles
* block the player
* block projectiles unless the catalog explicitly says so

---

# Durability, damage feedback, and health bars

Update `PlayerPlaceableDurabilityService` so logical runtime placeables validate against `BuildingObjectManager`.

For a durability record whose logical layer is `traversable_buildings`:

```gdscript
building_objects.has_building(cell)
building_objects.get_placeable_item_id(cell) == item_id
```

Do not query a TileMapLayer.

`register_live_destructible_targets()` must enumerate runtime placeables from `BuildingObjectManager` instead of scanning a removed layer.

Avoid registering the same target twice.

Keep durability keys compatible:

```txt
traversable_buildings:x,y
```

This preserves existing stomp/contact and save references.

## Health-bar anchors

For runtime visuals, allow the visual to provide an anchor:

```gdscript
func get_health_bar_anchor_world_position() -> Vector2
```

Add a `BuildingObjectManager` query that delegates to the runtime node and falls back to the normal cell center.

`PlayerPlaceableDurabilityService.health_bar_world_position()` should use that query for logical runtime buildings.

This prevents bars from appearing inside taller sprites such as the Reservoir.

Do not create a separate health-bar node per placeable. Keep the existing lightweight `BuildingHealthOverlay`.

## Damage feedback

Continue using:

```txt
PlayerPlaceableDurabilityService.placeable_damaged
    -> PlaceableDamageFeedback
    -> runtime_node.play_damage_flash()
```

Do not duplicate damage-flash routing in each combat/contact system.

---

# Save/load compatibility

Increment the save version.

New saves must no longer serialize a `layers.traversable_buildings` TileMap layer.

Physical layer serialization should include only actual TileMap layers.

Runtime traversable placeables must be serialized through:

```gdscript
BuildingObjectManager.serialize_runtime_placeables()
```

Preserve:

* item ID
* cell
* logical target layer
* direction where applicable
* runtime-specific state where applicable

The logical saved target layer may remain:

```txt
traversable_buildings
```

It is a compatibility identifier, not a scene-node name.

## Old saves

Continue accepting older supported saves.

For saves that contain explicit `runtime_placeables`, those records are authoritative.

For older saves without explicit runtime-placeable identity:

* inspect the legacy serialized `layers.traversable_buildings` cell records
* infer the placeable through the existing atlas/source/alternative compatibility logic
* create runtime registry entries directly
* do not recreate a TileMapLayer
* if a marker is ambiguous, warn and skip it rather than guessing
* explicit runtime records must win over inferred legacy records

Old durability records using layer `"traversable_buildings"` must validate after the runtime registry has been restored.

Required restore order:

1. Restore physical TileMap layers.
2. Restore or migrate runtime placeables into `BuildingObjectManager`.
3. Restore runtime visual state.
4. Restore irrigation/placeable-dependent systems.
5. Restore durability records.
6. Refresh terrain-speed cells.

New save validation must not require `layers.traversable_buildings`.

Legacy validation must still accept that field when loading old versions.

---

# Scene and legacy cleanup

Remove from `mainRun.tscn`:

* `Map/MonTilemap/traversable_buildings`
* exported NodePaths pointing to it
* `traversable_buildings` entries in `node_paths`

Remove the corresponding `@export var traversable_buildings: TileMapLayer` fields from:

* `BuildSystem`
* `BuildingManager`
* `BuildingObjectManager`
* any other service that only used it as a physical layer

Do not leave nullable dead exports for compatibility unless a dynamic scene reference genuinely requires them. Search first.

Audit all repository references to `traversable_buildings`.

Every remaining occurrence must be one of:

* logical layer constant
* save compatibility
* legacy migration
* catalog classification
* durability/contact identity

There must be no remaining code that calls these methods on it:

```gdscript
get_used_cells()
get_cell_source_id()
get_cell_atlas_coords()
set_cell()
erase_cell()
update_internals()
map_to_local()
local_to_map()
```

## Building scan cleanup

Spawners are node-authored.

Remove the obsolete dependency where `BuildingScanService.scan_buildings()` returns early when the traversable layer is absent.

Remove traversable-layer special scanning.

Clean `build_tiles_index.tres`:

* remove the obsolete `spawner -> traversable_buildings` marker definition
* preserve `plantsToTarget` behavior if it is still used
* legacy spawner tiles in `wallz` may still be removed/warned about during migration, but must not be moved to another traversable layer

Do not remove the node-authored spawner system.

## Other known references to update

Audit and correctly update at least:

* `scripts/map/building_object_manager.gd`
* `scripts/map/build_placement_service.gd`
* `scripts/map/build_removal_service.gd`
* `scripts/map/buildsystem.gd`
* `scripts/map/building_manager.gd`
* `scripts/map/building_navigation_sync_service.gd`
* `scripts/map/player_placeable_durability_service.gd`
* `scripts/map/building_scan_service.gd`
* `scripts/map/build_actor_displacement_service.gd`
* `scripts/map/agent_tile_interaction_controller.gd`
* `scripts/combat/kraken/kraken_system.gd`
* `scripts/gameState/progression.gd`
* `scripts/ui/game_ui.gd`
* `scripts/map/counter_stock_manager.gd`
* `scripts/items/item_catalog.gd`
* `scripts/map/build_tiles_index.tres`
* `mainRun.tscn`

This is an audit list, not an instruction to edit every file unnecessarily. Remove obsolete references where required and keep unrelated systems unchanged.

---

# Authored world content

Search all level scenes for cells or nodes that currently represent:

* Lamp
* Ronce
* Reservoir
* Pasteque
* Kraken

through the old traversable layer.

Migrate any authored instances so they are registered in `BuildingObjectManager` at startup without requiring the removed TileMapLayer.

Use the smallest project-appropriate authoring representation.

Do not invent a large new editor framework.

Do not silently delete authored placeables.

Report exactly which authored instances were migrated.

---

# Preserve unrelated behavior

Do not change:

* prices
* inventory semantics
* placement restrictions
* building menu order
* build controls
* night placement rules
* stomp damage values or cadence
* Kraken combat timing
* Reservoir irrigation radius
* Ronce slowdown
* Lamp light tuning
* agent navigation architecture
* blocking-building behavior
* fence behavior
* plant TileMap behavior
* house behavior

This task is a runtime-placeable storage/visual unification, not a gameplay rebalance.

---

# Manual acceptance scenarios

Do not run them, but structure the implementation so I can test:

## Fresh game

1. Start a fresh game.
2. Confirm no `traversable_buildings` node exists.
3. Confirm authored Reservoir/Lamp/etc. still appear if the level contains them.
4. Confirm there are no missing-node errors.

## Pasteque

1. Place Pasteque.
2. Confirm no persistent building tile appears.
3. Confirm `pasteque.png` is visible and depth-sorted.
4. Walk in front of and behind it.
5. Confirm the floor directly beneath it is wet grass.
6. Confirm irrigation expands normally.
7. Stomp/damage it and confirm:

   * red flash
   * health bar
   * repeated damage
   * debris at zero health
8. Unbuild another Pasteque and confirm:

   * one refund
   * runtime visual removed
   * irrigation shrinks/restores correctly
   * no orphan registry record

## Ronce

1. Place Ronce.
2. Confirm runtime sprite and world-depth sorting.
3. Confirm contact dance.
4. Confirm 0.3 slowdown remains.
5. Damage it and confirm red flash and health bar.
6. Remove it and confirm speed returns immediately.

## Lamp

1. Place Lamp.
2. Confirm runtime sprite exists.
3. Confirm light is off during day and on during night.
4. Damage the Lamp and confirm the sprite flashes.
5. Destroy/remove it and confirm the light is also gone.

## Reservoir

1. Confirm Reservoir visual and water fill.
2. Confirm natural world-depth sorting instead of fixed z-index.
3. Damage it and confirm one generic health bar and red flash.
4. Confirm there is no duplicated private health bar.
5. Destroy it and confirm game-state destruction behavior and cleanup.

## Kraken

1. Place Kraken.
2. Confirm no invisible TileMap marker is created.
3. Confirm slowdown and stomp damage.
4. Confirm targeting, extension, eating, retraction, and reset.
5. Confirm save/load during an idle valid state.
6. Confirm no failed `KrakenVisual` casts.

## Placement conflicts

Confirm runtime traversable placeables cannot overlap:

* each other
* plants
* walls
* blocking buildings
* fences
* houses
* bamboo
* invalid floor/water according to catalog rules

## Save/load

1. Save with all five placeables present.
2. Reload.
3. Confirm identity, cell, visual, health, slowdown, light, irrigation, and Kraken state.
4. Load an older save containing `layers.traversable_buildings`.
5. Confirm it migrates into runtime objects without recreating the TileMapLayer.
6. Confirm ambiguous legacy cells warn instead of becoming the wrong item.

## Performance

Place and remove multiple runtime traversable objects.

Confirm:

* no global flow-field rebuild
* no garden topology rebuild for speed-only objects
* only affected terrain-speed cells are refreshed
* no per-frame scan over every runtime building was added

---

# Completion report

At the end, report:

1. Changed files.
2. New state owner and runtime-visual structure.
3. How each of the five placeables was migrated.
4. How old saves are migrated.
5. Any authored level objects converted.
6. Compatibility wrappers retained and why.
7. Any asset fallback used for Lamp or Ronce.
8. Any remaining occurrence of the string `traversable_buildings` and why it remains.
9. Production-quality concerns noticed.
10. Manual tests I should run.

Do not claim testing was performed because Godot must not be run.
