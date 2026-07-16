# Durable stompable plants and repeated crushing damage

Read `AGENTS.md` and `ARCHITECTURE.md` before editing.

Implement this as a clean, localized GDScript feature. Do not modify the C++ extension. Do not run Godot, tests, compilation, exports, or builds; the user will test manually.

## Objective

Crushing agents must no longer instantly destroy plants or plant-like placeables merely by walking onto their tile.

Instead:

1. entering a stompable tile applies damage immediately;
2. remaining on that same tile applies the same damage again every **1.0 second**;
3. when health reaches `0`, use the existing authoritative destruction result:

   * debris;
   * plant-parts burst where applicable;
   * irrigation cleanup;
   * runtime visual cleanup;
   * terrain-speed cleanup;
   * plant retargeting;
   * structural invalidation where already required;
   * existing destruction SFX.

Every surviving plant-like placeable must briefly flash red whenever it receives damage, regardless of whether the damage came from stomping or tantrum attacks.

## Exact health values

Set the following catalog maximum health:

| Item            | Maximum health |
| --------------- | -------------: |
| `rose`          |             80 |
| `imperial_seed` |             80 |
| `pasteque`      | 100, unchanged |
| `turret_epine`  |             50 |
| `kraken`        | 100, unchanged |

A normal 20-point stomp therefore removes exactly 25% of a rose or imperial plant’s health.

Do not alter unrelated placeable health values.

## Exact stomp damage

Damage per tick:

| Agent          | Damage |
| -------------- | -----: |
| normal monster |     20 |
| client         |     20 |
| merchant       |     20 |
| builder        |     20 |
| bigmonster     |     40 |

The canonical runtime categories are currently:

* `monsters`
* `clients`
* `merchants`
* `builders`
* `sheep`

Use the existing canonical `monster_type` metadata and `MonsterCatalog.BIG_MONSTER_ID` to identify bigmonsters.

Do not infer bigmonsters from:

* sprite or scene names;
* scale;
* health;
* animation;
* navigation group;
* visual properties.

The player and sheep must not apply stomp damage.

## Global damage interval

Use one centralized, easily adjustable value:

```gdscript
const STOMP_DAMAGE_INTERVAL_SECONDS: float = 1.0
```

Keep this value in the controller that owns crushing-contact rules, preferably `AgentTileInteractionController`.

Do not scatter `1.0` literals across scripts and do not create one Godot `Timer` node per agent.

The interval is shared by every crushing-agent type.

## Stompable placeables

The exact stompable set is:

* `rose`
* `imperial_seed`
* `pasteque`
* `turret_epine`
* `kraken`

Add one explicit catalog property, for example:

```gdscript
"stompable": true
```

Also normalize their contact behavior to one generic behavior, for example:

```gdscript
"agent_contact_enabled": true,
"agent_contact_behavior": &"stomp_damage",
"stompable": true,
```

Remove the need for separate contact behavior branches such as:

* `plant_trample`
* `pasteque_trample`
* `turret_eating`
* `kraken_walkover_damage`

Do not automatically make every destructible placeable stompable.

The following remain non-stompable unless separately requested:

* walls;
* fences;
* counters;
* reservoirs;
* houses;
* lamps;
* unrelated traps;
* unrelated buildings;
* `ronce`.

Keep the distinction explicit:

```gdscript
ItemCatalog.is_destructible_placeable(item_id)
ItemCatalog.is_stompable(item_id)
```

A placeable may be destructible without being stompable.

## Contact timing

Required sequence for one crushing agent:

```text
agent enters stompable tile
→ apply damage immediately
→ start a 1-second occupancy interval
→ after each full interval, apply damage again
→ continue while the agent remains on that exact target tile
→ stop when the contact is no longer valid
```

Example with a normal monster standing on an 80-HP rose:

```text
entry: 80 → 60
after 1 second: 60 → 40
after 2 seconds: 40 → 20
after 3 seconds: 20 → 0, destroy
```

Example with a bigmonster:

```text
entry: 80 → 40
after 1 second: 40 → 0, destroy
```

The first repeated tick occurs one complete interval after the immediate entry hit. Do not apply an additional tick during the entry frame.

## Multiple-agent stacking

Every crushing agent owns an independent contact interval.

If three normal clients remain on the same plant, each one applies 20 damage independently. Their damage therefore stacks.

Do not aggregate occupancy into one shared tile timer.

A target destroyed by one agent must invalidate the remaining contacts cleanly. Other agents must not:

* apply damage to a removed target;
* trigger destruction twice;
* spawn duplicate debris;
* run duplicate plant-retarget operations;
* produce stale errors.

## Contact-state ownership

`AgentCellTracker` already owns authoritative agent cell tracking and transition detection.

`AgentTileInteractionController` already owns which categories crush which placeables.

Keep those responsibilities:

### `AgentCellTracker`

Continue to own:

* registered agents;
* current cells;
* cell transitions;
* suspension and resume;
* world-cell invalidation;
* unregister and cleanup.

### `AgentTileInteractionController`

Own:

* which agents can crush;
* stomp damage amounts;
* the global stomp interval;
* active stomp-contact state;
* resolving the stompable target;
* applying immediate and repeated damage;
* clearing invalid contacts;
* the one-shot people-trampling tutorial alert.

Do not put this feature into `BuildingManager`.

`BuildingManager` may expose only thin, intention-revealing wrappers around the durability and object-manager owners.

## Active-contact implementation

Maintain only active stomp contacts, keyed by agent instance ID.

A contact record should contain only the data required to validate and tick it, approximately:

```gdscript
{
    "agent_ref": weakref(agent),
    "category": category,
    "cell": cell,
    "target_key": durability_key,
    "layer_name": layer_name,
    "item_id": item_id,
    "elapsed": 0.0,
}
```

Do not retain strong references that prevent deleted agents from being freed.

After the immediate entry hit, set `elapsed` to `0.0`.

Each frame, process only the active contact records:

```gdscript
elapsed += delta

while elapsed >= STOMP_DAMAGE_INTERVAL_SECONDS:
    elapsed -= STOMP_DAMAGE_INTERVAL_SECONDS
    apply_stomp_damage()
```

Use a safe positive interval. Guard against an accidental zero or negative configuration value.

Do not create a second full scan over every registered agent. Processing only active stomp contacts is acceptable.

`AgentCellTracker.process(delta)` may call one focused method such as:

```gdscript
_interactions.process_active_contacts(delta)
```

after cell transitions and queued interaction checks have been resolved.

## Starting a contact

Start a fresh stomp contact when:

* an eligible agent genuinely enters a cell containing a stompable target;
* a stompable target is newly placed underneath an eligible agent and that cell is explicitly invalidated;
* a suspended agent is resumed onto a stompable target and is considered active again.

Starting a fresh contact applies immediate damage once and resets its interval.

Do not reapply immediate damage because of an unrelated generic recheck while the agent is still in the same unchanged contact.

The current queue combines multiple reasons:

* cell transition;
* cell invalidation;
* state-exit recheck;
* suspension recovery.

Make those reasons explicit enough to avoid accidental extra immediate hits.

A clean solution is a small queue-reason enum or bitmask, for example:

```gdscript
const RECHECK_CELL_ENTERED: int = 1
const RECHECK_WORLD_CHANGED: int = 2
const RECHECK_STATE_CHANGED: int = 4
```

Required semantics:

* `CELL_ENTERED`: resolve a fresh contact and apply immediate damage;
* `WORLD_CHANGED`: invalidate the previous target contact, resolve the new tile content, and apply immediate damage if a new stompable target now exists;
* `STATE_CHANGED`: revalidate contact without applying an extra immediate hit to the same unchanged target.

Do not broadly rewrite the tracker. Make only the focused change needed to distinguish contact lifecycle events.

## Stopping a contact

Immediately clear an active stomp contact when:

* the agent leaves the target cell;
* the agent is unregistered;
* the agent is queued for deletion;
* its weak reference becomes invalid;
* the agent is suspended;
* the target no longer exists;
* the target item or target layer changed;
* the target is no longer stompable;
* the target is destroyed;
* the agent category no longer allows crushing;
* the game/level state is cleared.

Suspension must pause crushing by clearing the contact. Resume may establish a fresh contact through the normal recheck path.

Do not serialize active contact timers. They are transient runtime state.

## Target resolution

Resolve targets from existing authoritative registries.

For building-layer placeables, use `BuildingObjectManager.get_placeable_instance(cell)` or its direct typed equivalent.

For plant-layer placeables, resolve the live item from `PlantManager` or the existing authoritative plant lookup rather than assuming every occupied `plantz` cell is a rose.

The target descriptor must contain:

* cell;
* normalized layer name;
* item ID;
* durability key or enough information to resolve it directly.

Use O(1)-style cell lookups. Do not scan all buildings or plants.

## Damage application

All stomp damage must flow through `PlayerPlaceableDurabilityService`.

Do not directly erase tiles or call old instant-trample functions.

Expose or reuse a thin manager wrapper similar to:

```gdscript
func damage_player_placeable_at(
    cell: Vector2i,
    layer_name: String,
    item_id: String,
    amount: int
) -> bool:
    return _durability.apply_damage_at(cell, layer_name, item_id, amount)
```

The durability service remains the sole owner of:

* current health;
* maximum health;
* save/load durability state;
* lethal-hit detection;
* health-overlay refresh;
* destruction dispatch.

A successful non-lethal stomp must:

1. subtract the correct health;
2. refresh the health overlay;
3. trigger the damage flash;
4. retain the target;
5. avoid navigation invalidation;
6. avoid structural target-revision changes;
7. avoid waking unrelated tantrum agents.

A lethal stomp must destroy the target exactly once through its existing authoritative destruction pipeline.

## Separate health from destruction policy

The current implementation implicitly makes plant-category and `plantz` placeables `instant_destroy`.

Remove that coupling.

A placeable must not be instant-destroy merely because:

* its category is `plant`;
* it has `logical_plant`;
* it uses the `plantz` layer.

Rose and imperial plants must use normal durability records with 80 HP.

Do not continue storing them as:

```gdscript
"health": 1,
"max_health": 1,
"instant_destroy": true,
```

Durability and destruction behavior are separate concerns.

Introduce a clear catalog destruction policy or focused query, for example:

```gdscript
"destruction_policy": &"plant_consume"
```

with a query such as:

```gdscript
ItemCatalog.uses_plant_destruction_path(item_id)
```

Required death paths:

### Rose and imperial plant

On lethal damage:

* spawn the existing plant-parts burst;
* call the authoritative `PlantManager.consume_plant(cell)` path;
* leave the same debris as before;
* emit the existing plant-removal signals;
* trigger the existing monster retargeting behavior;
* clear the terrain slowdown;
* do not route them through generic structure removal.

### Pasteque

On lethal damage:

* preserve the current pasteque destruction result;
* remove its irrigation effect;
* restore/update affected floor state correctly;
* remove its building registry entry;
* leave the same debris and effects as currently;
* do not refund inventory.

### Thorn turret

On lethal damage:

* preserve its existing debris;
* preserve its plant-parts/burst result if currently part of turret destruction;
* remove its runtime visual;
* remove its registry and tile marker;
* clear its terrain slowdown;
* do not refund inventory.

### Kraken

On lethal damage:

* preserve its current Kraken debris;
* remove all Kraken runtime visuals and system registration;
* remove the underlying placeable;
* clear its terrain slowdown;
* do not refund inventory.

Do not add a generic path that bypasses existing per-type cleanup.

## Thorn-turret legacy eating path

`TurretEatingController` currently performs immediate thorn-turret removal and may suspend monsters for an eating animation.

It must no longer be the authoritative walkover path for `turret_epine`.

The new sequence is always:

```text
occupy turret tile
→ apply stomp damage
→ repeat damage every second
→ destroy only at zero health
```

Do not allow both the old turret-eating path and the new stomp-damage path to run for the same contact.

A non-lethal turret stomp must not:

* remove the turret;
* leave debris;
* suspend the monster;
* start the turret-eating timer;
* trigger an eating animation.

Audit all static and dynamic references to `TurretEatingController`.

If it becomes completely unused after this change, remove it and its manager processing/wiring cleanly.

If another valid feature still uses it, retain only that unrelated responsibility and remove thorn-turret walkover ownership from it.

Do not leave dead compatibility code without stating why it remains.

## Monster plant-eating behavior

Do not broadly rewrite the existing targeted garden-eating feature.

This task changes generic tile-contact crushing.

Ensure that an agent contact cannot simultaneously execute:

* the new stomp hit;
* an obsolete instant-trample handler for the same event.

If a monster deliberately targets and eats a plant through the garden-eating state machine, preserve that separate behavior unless it directly conflicts with the requested durability model.

Report any unavoidable overlap rather than silently changing the entire monster-eating design.

## Health bars

Reuse the existing `BuildingHealthOverlay`.

After removing the plant `instant_destroy` assumption, damaged roses and imperial plants must naturally appear in `damaged_records()`.

Expected examples:

* rose after one normal hit: `60 / 80`;
* imperial after one normal hit: `60 / 80`;
* pasteque after one normal hit: `80 / 100`;
* thorn turret after one normal hit: `30 / 50`;
* thorn turret after one bigmonster hit: `10 / 50`;
* Kraken after one normal hit: `80 / 100`.

Health bars:

* remain hidden at full health;
* appear immediately after the first surviving hit;
* update after every repeated damage tick;
* disappear when the target is destroyed;
* must not create one UI node per target.

Update stale comments in `BuildingHealthOverlay` and `PlayerPlaceableDurabilityService` that currently state that plants never show health bars.

## Generic red damage flash

Create one focused generic visual-feedback owner, for example:

```text
scripts/map/placeable_damage_feedback.gd
```

Do not put the implementation in `BuildingManager`.

The durability service must notify this owner after every successful hit, not only stomps. This ensures the same flash also occurs when tantrum agents attack the target.

A signal is appropriate, for example:

```gdscript
signal placeable_damaged(
    cell: Vector2i,
    layer_name: StringName,
    item_id: String,
    remaining_health: int,
    max_health: int
)
```

Emit it for every successful damage application before refreshing the overlay.

The feedback owner may subscribe through scene setup or an explicit setup method.

### Flash behavior

Required visual behavior:

* immediate strong red tint;
* duration around `0.12` seconds;
* restore the exact original modulation afterward;
* repeated hits restart the current flash cleanly;
* no stacked conflicting tweens;
* no permanent red tint after removal or scene unload;
* no material duplication per damage tick;
* no gameplay work in `_process`;
* no structural or navigation side effects.

Use one shared duration constant, for example:

```gdscript
const DAMAGE_FLASH_DURATION_SECONDS: float = 0.12
```

A lethal hit must not delay destruction merely to make the flash visible. The authoritative death path remains immediate.

### Runtime-node visuals

For placeables represented by runtime nodes:

* `turret_epine`;
* `kraken`;

resolve the runtime root with:

```gdscript
BuildingObjectManager.get_runtime_node(cell)
```

Provide one narrow public method on the visual root, for example:

```gdscript
func play_damage_flash(duration: float) -> void:
```

For `TurretSpriteVisual`, flash both base and head together.

For `KrakenVisual`, flash every segment together.

Preserve their original modulation and animation state.

Do not add separate timers to every Kraken segment.

### Imperial plants

`ImperialPlantVisuals` already owns the visible sprite per imperial plant.

Add a narrow method such as:

```gdscript
func play_damage_flash_at(cell: Vector2i, duration: float) -> bool:
```

Flash the actual visible imperial sprite.

Do not create a second duplicate imperial sprite.

### Roses and tile-backed visuals

`GrownupRoseDance` already contains tile-copy logic for rose/contact animation.

Reuse and extend that existing representation instead of implementing another unrelated atlas-copy system.

Add a narrow method such as:

```gdscript
func play_damage_flash_at(
    layer_name: StringName,
    cell: Vector2i,
    item_id: String,
    duration: float
) -> bool:
```

Requirements:

* if the rose already has a runtime dancer sprite, flash that sprite;
* if it is a TileMap-only rose stage, temporarily use the existing contact/tile-copy machinery;
* do not tint the entire `plantz` layer;
* do not permanently erase or duplicate the logical tile;
* preserve source ID, atlas coordinates and alternative tile;
* preserve z-index/depth sorting;
* restore the source visual correctly after the flash.

### Pasteque

Pasteque is currently TileMap-backed.

Use the same generic temporary tile-copy technique:

* copy the exact atlas region;
* preserve source and alternative tile;
* place it at the exact world cell;
* tint only that temporary sprite red;
* remove it after the flash;
* do not tint the entire buildings layer.

Prefer sharing the tile-copy helper already used by `GrownupRoseDance`, but do not perform a broad visual-system refactor merely to share a few lines.

## Contact dance

Preserve the existing plant/contact dance effect.

Damage flash and contact dance are separate:

* contact dance represents an agent touching/standing on the placeable;
* red flash represents an actual damage tick.

Do not restart the full contact dance every second unless that already happens naturally. The red flash must occur on every successful damage tick.

## Tutorial alert

The existing one-shot alert:

```text
tutorial.people_crush_plants
```

currently depends on a villager destroying something.

Update it to trigger after the first successful villager stomp damage, even when the target survives.

It must still be shown only once through the existing tutorial-alert mechanism.

Monsters must not trigger this people-specific alert.

## Save and load

Continue serializing durability through `PlayerPlaceableDurabilityService`.

Required:

* damaged roses retain their health;
* damaged imperial plants retain their health;
* damaged pasteques retain their health;
* damaged thorn turrets retain their health;
* damaged Krakens retain their health;
* loading runtime visuals must not heal the target;
* active stomp timers are not saved;
* destroyed targets are not restored.

### Legacy save migration

The old implementation may contain `1 / 1` durability records for instant-destroy plants and thorn turrets.

Migrate these full-health legacy records safely:

* old `rose` `1 / 1` → `80 / 80`;
* old `imperial_seed` `1 / 1` → `80 / 80`;
* old `turret_epine` `1 / 1` → `50 / 50`.

Do not load an old full-health thorn turret as `1 / 50`.

Old saves without a durability entry for a currently live target must initialize it at the current catalog maximum health.

For normal modern records, preserve the saved current health and maximum health where valid.

Do not change the overall save schema unless necessary.

## Placement and invalidation

Placing a stompable target under an already registered crushing agent must be handled through the existing targeted cell invalidation system.

Do not scan all agents after placement.

The flow should remain approximately:

```text
place target
→ register durability
→ invalidate that cell
→ only agents indexed in that cell are rechecked
→ establish a fresh stomp contact
→ apply immediate damage
```

Removing or destroying a target must invalidate/clear only relevant contacts.

## Performance constraints

The game supports hundreds of agents.

Required:

* no new full-agent scan;
* no new full-building scan;
* no new full-plant scan per damage tick;
* no per-agent Timer nodes;
* no per-target health-bar nodes;
* no per-frame TileMap atlas reconstruction;
* no navigation rebuild for non-lethal damage;
* no flow-field invalidation for non-lethal damage;
* O(1)-style target lookup by cell/key;
* process only agents that currently have an active stomp contact;
* deduplicate damage-flash tweens by target;
* clean stale weak references lazily and safely.

Multiple agents can occupy the same target, but the system must remain proportional to the number of active crushing contacts, not to every placeable in the world.

## Likely files

Inspect actual ownership and references before editing. Expected scope:

* `scripts/items/item_catalog.gd`
* `scripts/map/agent_cell_tracker.gd`
* `scripts/map/agent_tile_interaction_controller.gd`
* `scripts/map/player_placeable_durability_service.gd`
* `scripts/map/building_health_overlay.gd`
* `scripts/map/building_manager.gd` — thin wrappers/wiring only
* `scripts/map/building_object_manager.gd`
* `scripts/map/plant_manager.gd`
* `scripts/map/turret_eating_controller.gd`
* `scripts/animations/grownup_rose_dance.gd`
* `scripts/map/imperial_plant_visuals.gd`
* `scripts/combat/turrets/turret_sprite_visual.gd`
* `scripts/combat/kraken/kraken_visual.gd`
* new focused `scripts/map/placeable_damage_feedback.gd`
* `mainRun.tscn` only if explicit node wiring is required

Do not add substantial logic to the already large `BuildingManager`.

## Required static audit

Before finishing, search for all remaining references to:

```text
plant_trample
pasteque_trample
turret_eating
kraken_walkover_damage
trample_plant_at_agent
trample_pasteque_at_agent
is_instant_destroy_placeable
instant_destroy
walkover_damage_by_monsters
TurretEatingController
```

Remove or update obsolete contact paths and comments.

Do not leave two authoritative ways to damage or destroy the same target on walkover.

Preserve compatibility wrappers only when a dynamic caller or scene reference requires them, and state this in the final report.

## Manual acceptance scenarios

Report the expected result for each scenario.

### 1. Normal client on rose

* entry: `80 → 60`;
* immediate red flash;
* health bar appears;
* after one second: `60 → 40`;
* red flash again;
* after three total seconds of occupancy: rose is destroyed;
* existing burst, debris and plant-retarget behavior occur once.

### 2. Client leaves before interval

* entry: rose `80 → 60`;
* client leaves after 0.5 seconds;
* no second damage tick;
* returning later applies a new immediate 20 damage.

### 3. Bigmonster on rose

* entry: `80 → 40`;
* after one second: `40 → 0`;
* destruction occurs once.

### 4. Thorn turret and normal monster

* entry: `50 → 30`;
* no instant removal;
* no monster suspension/eating state;
* after one second: `30 → 10`;
* after two seconds: destroyed;
* existing debris/removal behavior occurs once.

### 5. Thorn turret and bigmonster

* entry: `50 → 10`;
* after one second: destroyed.

### 6. Kraken and normal client

* entry: `100 → 80`;
* all Kraken segments flash red;
* health bar appears;
* repeated 20 damage every second;
* destruction at zero uses the existing Kraken cleanup/debris path.

### 7. Pasteque

* normal entry: `100 → 80`;
* pasteque flashes red;
* health bar appears;
* repeated ticks work;
* lethal damage removes irrigation correctly and preserves current debris behavior.

### 8. Imperial plant

* every growth stage uses the same durability record;
* changing visual stage does not reset health;
* damage flashes the currently visible imperial sprite;
* lethal damage uses `PlantManager` removal semantics.

### 9. Multiple agents

Two normal clients enter the same 80-HP rose at approximately the same time:

* first client entry: `80 → 60`;
* second client entry: `60 → 40`;
* after one second, each active contact applies 20;
* rose reaches zero once;
* only one destruction/debris/retarget sequence occurs.

### 10. Same-cell idle rechecks

While a client remains on a rose:

* an unrelated state recheck must not apply another immediate hit;
* damage continues only according to the original one-second interval.

### 11. Suspension

* suspend an agent standing on a target;
* crushing stops immediately;
* resume on the target establishes a fresh contact according to the defined resume behavior;
* no hidden timer continues during suspension.

### 12. Save/load

* damage each of the five stompable types;
* save and reload;
* health values remain unchanged;
* health bars reflect the loaded state;
* no active stomp timer is restored;
* contact restarts naturally when agents subsequently occupy the target.

### 13. Tantrum damage

* tantrum attacks still use the same durability records;
* every surviving tantrum hit triggers the same red flash;
* health bars continue to work;
* stomp and tantrum damage cannot destroy the target twice.

## Final report

Provide:

1. files changed;
2. concise ownership summary;
3. exact catalog health and stomp values;
4. how repeated contact timing is stored and cleaned;
5. how multiple agents stack;
6. how red flash dispatch works for each visual representation;
7. legacy save migration behavior;
8. obsolete instant-destroy/contact paths removed;
9. any compatibility wrapper intentionally retained;
10. manual tests the user should run.

Do not claim runtime verification because Godot and tests must not be run.
