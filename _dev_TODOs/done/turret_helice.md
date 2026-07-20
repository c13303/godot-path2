# TASK — Add `turret_helice` and perform the directly required turret cleanup

Read `AGENTS.md` and `ARCHITECTURE.md` first and follow them strictly.

Implement a new buildable turret named `turret_helice`.

This pass may include the small, directly related cleanup required to integrate the turret cleanly. Do not turn it into a broad turret-system, combat-system, animation-system, navigation, or native-extension refactor.

Do not run Godot, tests, compilation, GDExtension builds, exports, or project launch commands. I will test manually.

---

## 1. Required gameplay

`turret_helice` is a non-damaging wind turret.

It does not fire projectiles and must not create a fake gun, spray, projectile, weapon instance, or damage event.

### Direction and area

The turret is directional.

* Its facing direction is selected through the existing directional-building placement system.
* Wind affects a **90-degree cone in front of the turret**.
* Range: **5 tiles**, therefore `160 px` with the current 32 px tiles.
* Walls and other existing turret LOS blockers must block the wind.
* The range/coverage preview must show the real directional cone, not a complete circle.
* The force applied to an affected agent should point radially away from the turret’s center while still requiring the agent to be inside the forward cone.

The player is not affected.

Every other registered gameplay agent should be eligible, including:

* regular monsters;
* greenmonster;
* bigmonster;
* clients;
* builders;
* merchant;
* inventor;
* sheep;
* future tracked non-player agent categories where possible without creating unsafe assumptions.

Suspended, hidden, removed, drowning, externally captured, or otherwise invalid agents must not be affected.

### Activation cycle

The turret remains ready until at least one eligible agent is inside its cone and visible through the turret LOS rules.

When triggered:

1. Wind starts immediately.
2. Wind remains active for **1.0 second**.
3. The turret then enters cooldown for **3.0 seconds**.
4. After cooldown, it becomes ready again.
5. If an agent is still present, it may activate again on the next acquisition check.

The full cycle is therefore one second active followed by three seconds cooling down. Do not interpret the cooldown as a four-second frequency overlapping the active period.

During the active second:

* an agent entering the cone must receive the wind effect promptly;
* an agent already remaining inside may receive another impulse every **0.5 seconds**;
* leaving and entering again should allow an immediate new impulse;
* several agents can be pushed during the same activation;
* the activation continues for its full second even if the original triggering agent leaves.

### Wind impulse

Use the existing native propelled/smash impulse system. Do not implement custom manual movement or directly modify agent positions.

Initial values:

```txt
force:                       220.0
friction loss:               0.90
control suppression:         1.0
control suppression duration: 0.50 s
repulse frequency:           0.50 s
damage:                      0
detach flow:                 false
distance falloff:            none
```

This should produce a strong initial result of approximately:

* regular agent: around four tiles of displacement during a complete unobstructed activation;
* bigmonster: around half that distance.

Do not add a special `bigmonster` branch. Its existing `smash_resist_scale = 2.0` should naturally halve the received impulse. Preserve that generic resistance behavior.

The purpose of full control suppression is to prevent autonomous navigation from immediately cancelling the wind. Normal autonomous control must resume naturally after the suppression expires.

Agents must be able to be pushed onto water. Existing tile tracking and drowning behavior must handle the result naturally:

* drownable agents can drown;
* bigmonster remains non-drownable;
* do not add turret-specific drowning code.

---

## 2. Performance requirements

This game may contain hundreds of agents.

Do not:

* scan every agent;
* scan the whole map;
* perform an agent query every frame for every turret;
* add an `_process()` callback to each agent;
* recompute Flow Fields;
* trigger hard-topology navigation invalidation;
* repeatedly rebuild turret LOS;
* use physics overlap nodes for every turret if the indexed systems already provide the required query.

Use the existing `AgentCellTracker` spatial index or the native spatial index.

The current native continuous AoE system does not appear to support the turret’s cached LOS mask. Do not use it blindly if that would push agents through walls.

A safe approach is:

* use a bounded, local `AgentCellTracker` radius query;
* query only the five-tile neighborhood;
* use one local indexed traversal for all eligible non-player categories;
* perform ready-state acquisition at approximately the existing turret acquisition cadence;
* stagger initial acquisition checks by turret cell;
* while active, evaluate cone membership at a bounded interval such as `0.10 s`;
* keep a small per-turret/per-agent repulsion cooldown so entry is immediate and continuous overlap is limited to one impulse every `0.50 s`;
* call native `apply_smash_impulse()` only for eligible local agents.

Adding a small generic `AgentCellTracker` query such as “agents in radius except category” is acceptable if it prevents repeating the cell traversal for every individual category.

Do not duplicate the complete radius-query implementation in the new turret controller.

Per-frame timer updates over the small list of helix turrets are acceptable. Per-frame spatial or all-agent queries are not.

---

## 3. Ownership and code structure

`scripts/combat/turret_system.gd` is already approximately 639 lines and is in the warning zone.

Do not place the full helix state machine inside it.

Create a focused owner, for example:

```txt
scripts/combat/turrets/turret_helice_controller.gd
```

The exact name may follow existing project naming conventions, but it must have one clear responsibility:

> Own runtime state and wind application for all `turret_helice` instances.

Suggested owned state per turret:

```txt
cell
direction
state: READY / ACTIVE / COOLDOWN
active_time_left
cooldown_time_left
acquisition_wait
active_query_wait
per-agent repulse cooldowns or next-allowed times
```

`TurretSystem` should remain the coordinator:

* identify the behavior from `TurretData`;
* register weapon turrets with the existing weapon loop;
* register wind turrets with the focused helix controller;
* unregister them cleanly;
* provide small public coverage/LOS query methods if the controller needs access to state owned by `TurretSystem`;
* process the controller once from the existing central turret tick.

Do not make the new controller access private dictionaries or private methods of unrelated managers.

If it needs the native steering node, provide it explicitly during setup or add a small intention-revealing public query to the current owner. Do not reach into `FightSystem._steering`.

When gameplay is paused:

* active and cooldown timers must freeze;
* no wind queries or impulses may occur;
* resuming continues the cycle safely.

Removing the turret while active must immediately delete its controller state. There must be no lingering effect, stale reference, or orphaned timer.

---

## 4. Turret data

Extend `TurretData` only as much as is needed now.

A simple typed behavior discriminator is appropriate, for example:

```gdscript
enum Behavior {
    WEAPON,
    WIND,
}
```

Existing `turret_epine.tres` must retain weapon behavior by default without requiring risky migration.

Add only the immediately required wind configuration, with explicit types. Possible fields:

```txt
behavior
activation_angle_degrees
wind_active_duration
wind_cooldown_duration
wind_force
wind_friction_loss
wind_control_suppression
wind_control_suppression_duration
wind_repulse_frequency
wind_query_interval
```

Do not create a speculative generic effect framework or abstract turret inheritance hierarchy.

Create:

```txt
res://scripts/combat/turrets/turret_helice.tres
```

Required data:

```txt
id:                           turret_helice
behavior:                     WIND
shooting range:               160.0
activation angle:             90.0 degrees
directional:                  true
straight-line detection:      false
active duration:              1.0
cooldown duration:            3.0
force:                        220.0
friction loss:                0.90
control suppression:          1.0
control suppression duration: 0.50
repulse frequency:            0.50
active query interval:        0.10
build_in_range:               same as turret_epine
build_range:                  same as turret_epine
eatable_by_monsters:          same as turret_epine
```

Do not reuse `shoot_frequency`, `shoot_duration`, or weapon fields in misleading ways merely to avoid adding explicit wind timing.

---

## 5. Building registration

Add `turret_helice` to `ItemCatalog`.

Expected asset:

```txt
turret_helice.png
```

Locate and use the actual asset path in the repository. Do not invent a path if the file is elsewhere.

Copy the relevant building semantics from `turret_epine`, not its weapon behavior:

```txt
id:                         turret_helice
name fallback:              Fan Turret
currency:                   gem
type:                       placeable
category:                   turret
price:                      10
target_layer:               blocking_buildings
atlas:                      invisible building marker
occupies_cell:              true
isWall:                     false
blocks_movement:            false
blocks_player_movement:     false
blocks_projectiles:         false
speed_multiplier:           0.5
requires_walkable_floor:    true
requires_grass_green_floor: true
pad_skip_preview:           true
directional:                true
runtime_id:                 turret_helice
max_health:                 50
leaves_debris_on_destroy:   true
agent_contact_enabled:      true
agent_contact_behavior:     stomp_damage
stompable:                  true
recheck_agents_on_place:    true
max_stack:                  999
```

Therefore, it must automatically inherit the existing generic behavior for:

* placement validation;
* directional placement;
* build preview;
* ten-gem cost;
* unbuilding and refund;
* slowdown on its occupied tile;
* health and health overlay;
* damage flashing;
* monster attacks;
* tantrum-client attacks;
* stomp damage;
* destruction;
* debris;
* save/load;
* build removal.

Do not add duplicate helix-specific implementations for those systems.

No dedicated `items.png` icon frame was specified. For this pass, use the existing turret icon frame `6` as a temporary shared icon. Mention this clearly in the report. Do not redesign the entire item icon system for this missing content asset.

Add the item to all required authored/default tool-shop lists, ordering functions, level defaults, and price maps so it can appear once unlocked.

The blueprint lock remains the authoritative visibility gate.

Add translations:

```txt
item.turret_helice
EN: Fan Turret
FR: Tourelle à hélice
```

Use the actual translation JSON structure already present in the project.

---

## 6. Inventor blueprint

Add a paid blueprint:

```txt
blueprint id:  turret_helice
build item id: turret_helice
currency:      money
price:         10
prerequisites: []
automatic:     false
```

It has no prerequisite, but follow the existing blueprint-publication-at-dawn behavior:

* do not publish it immediately in the middle of a day;
* it becomes eligible and is published at the next dawn;
* the inventor receives the existing unseen-blueprint bubble;
* opening and closing the inventor dialog clears the unseen state through the existing generic behavior;
* purchasing it permanently unlocks the build item.

Add it to the explicit paid-blueprint order.

Save behavior:

* unlocked state persists;
* publication/unseen state persists;
* old saves where the blueprint did not exist must not receive it already unlocked;
* an old save may publish it naturally at the next dawn;
* avoid a save-version bump unless the existing schema genuinely requires one.

---

## 7. Sprite composition and animation

`turret_helice.png` contains these frames:

```txt
0: base
1: normal head
2: cooldown head
3, 4, 5, 6: propeller animation
```

The visual requires three composed sprites:

1. Base
2. Rotating/oriented head
3. Propeller attachment

Extend `TurretSpriteVisual` with one optional generic animated head attachment. Do not create a broad animation framework.

Expected structure:

```txt
TurretSpriteVisual
├── Base              z = 0
└── Head              z = 1
    └── Attachment    z = 2
```

The attachment must be a child of the head so it follows head orientation automatically.

Default east-facing attachment center:

```txt
Vector2(16.0, 0.0)
```

Use this as configurable visual data rather than burying it in behavior code.

Suggested visual definition:

```txt
base_frame:                0
head_frame:                1
refractory_frame:          2
head_offset:               same structural offset as turret_epine
attachment_frames:         [3, 4, 5, 6]
attachment_frame_duration: 0.08 s
attachment_offset:         Vector2(16.0, 0.0)
attachment_z_index:        2
```

Inspect the actual texture dimensions, padding, transparent bounds, and frame stride before finalizing the visual definition. If they differ from `turret_epine`, configure the actual values instead of forcing the old layout.

Visual states:

### Ready

* Head frame `1`.
* Propeller stopped on its current frame.
* On initial creation, it may begin stopped on frame `3`.

### Active

* Head frame `1`.
* Propeller loops frames `3, 4, 5, 6`.
* Continue looping for the full active second.

### Cooldown

* Head frame `2`.
* Propeller stops immediately and remains frozen on whichever animation frame it currently displays.

### Return to ready

* Head returns to frame `1`.
* Propeller remains frozen until the next activation.

Add a small generic visual API such as:

```txt
set_activity_active(active)
set_refractory_active(active)
```

`BuildingObjectManager` may expose matching public wrappers. Keep visual mutation inside the visual owner.

Damage flash must affect:

* base;
* head;
* propeller attachment.

Build preview must render the complete composed turret, including a frozen propeller.

Existing `turret_epine` visuals, shot animation, cooldown frame, damage flash, direction, preview, and idle/contact dance must remain unchanged.

---

## 8. Coverage and LOS

The current turret coverage code supports straight lines and radial ranges. Add the smallest generic support for a directional angle.

Requirements:

* `turret_epine` straight-line coverage remains unchanged;
* a non-straight-line turret with `activation_angle_degrees < 360` uses a directional cone;
* hovered coverage shows only cone cells;
* placement preview shows only cone cells;
* async visible-cell precomputation filters by both range and cone angle;
* LOS blockers still exclude hidden cells;
* build-exclusion range remains independent and must not accidentally become cone-shaped.

Use a small geometry helper for the angle test instead of duplicating dot-product logic in the preview, LOS builder, target acquisition, and helix controller.

Verify whether the existing turret LOS cache is correctly refreshed when walls or other LOS blockers are added or removed.

If it is currently stale:

* add the smallest event-driven invalidation shared by all turrets;
* recompute lazily/budgeted through the existing async coverage path;
* do not recompute every frame;
* do not perform an immediate unbudgeted rebuild for every turret inside the wall placement method;
* coalesce repeated blocker changes where practical.

Do not silently ship the helix using permanently stale LOS data.

---

## 9. Focused cleanup allowed in this pass

Perform only cleanup directly required by this feature.

### Required

1. Remove the assumption that every non-gun turret must be a spray.

A wind turret must never call:

```txt
create_turret_spray
update_turret_spray
stop_turret_spray
```

Dispatch turret runtime behavior explicitly from `TurretData.behavior`.

2. Replace new or existing `turret_epine`-specific checks with capability/data checks where the logic truly applies to every turret or every speed-only placeable.

For example, the speed-only navigation debug guard should derive its expectation from item semantics rather than requiring an ever-growing list of turret IDs.

3. Keep `TurretSystem` as a coordinator and put the wind state machine in its focused controller.

4. Add the optional visual attachment generically inside `TurretSpriteVisual`.

### Contained correctness fix

The supplied checkout appears to contain an unconditional second `continue` inside `TurretSystem._nearest_enemy_in_range()` after its distance check.

Confirm this against the current source.

If present, remove the erroneous unconditional `continue` as a small contained correctness fix and report it separately. Do not use this as an excuse to rewrite target acquisition.

### Do not generalize unnecessarily

Do not change code that is legitimately specific to `turret_epine`, such as its dedicated tutorial.

Do not broaden legacy-save compatibility lists for a newly introduced item that could never exist in those old saves.

Do not move major state ownership.

Do not introduce:

* abstract turret base classes;
* service locators;
* a generic effect scripting framework;
* signals for every internal state transition;
* a new global event bus;
* unnecessary C++ API changes;
* one Node per affected agent;
* one Area2D per turret unless there is a demonstrated need.

If clean integration unexpectedly requires a much larger refactor, stop and report the exact issue rather than creating noodles.

---

## 10. Strict typing and safety

Follow strict GDScript typing from `AGENTS.md`.

Avoid `:=` for:

* numeric expressions;
* dictionaries and arrays;
* dynamic `get()`;
* `call()` returns;
* nullable references;
* mixed integer/float calculations.

Use explicit types and deliberate casts.

Before changing public-looking methods, search for:

* direct calls;
* `call()`;
* `Callable`;
* signal connections;
* scene references;
* saved resources;
* string-based method names.

Keep compatibility wrappers where dynamic usage cannot be disproved.

Do not let controller state contain strong references to agents. Use nav IDs, instance IDs, or validated weak references as appropriate.

Remove stale per-agent cooldown entries when agents leave the cone, disappear, or become invalid.

---

## 11. Acceptance criteria

The task is complete when all of the following are true in code:

### Progression and building

* `turret_helice` is initially locked.
* It is published through the existing dawn blueprint system.
* It appears in the inventor dialog for 10 money.
* Buying it permanently unlocks it.
* It appears in the correct build menu only after unlock.
* Building costs 10 gems.
* Placement/unbuilding rules match `turret_epine`.
* It is non-blocking and applies the same `0.5` terrain-speed multiplier.
* Placement/removal performs only the appropriate speed-cell update, not a hard Flow Field rebuild.
* Health, damage, tantrum targeting, monster attacks, stomp damage, destruction, debris, refund, and save/load use existing generic systems.

### Wind behavior

* The turret activates only when an eligible non-player agent is within the forward cone and visible.
* Wind lasts exactly one second.
* Cooldown lasts exactly three seconds after wind ends.
* Agents entering during the active second receive an effect promptly.
* Continuous overlap is limited to one impulse every 0.5 seconds.
* Several agents can be pushed simultaneously.
* No damage is dealt.
* The player is unaffected.
* Regular monsters, clients, and villagers are strongly displaced.
* Bigmonster is displaced significantly less through its existing resistance.
* Normal navigation resumes after suppression.
* Walls block wind.
* Agents can be pushed into water.
* Drowning remains owned by the existing drowning system.
* Removing an active turret leaves no active effect or stale state.

### Visuals

* Base uses frame `0`.
* Normal head uses frame `1`.
* Cooldown head uses frame `2`.
* Propeller uses frames `3–6`.
* Propeller rotates with the head.
* Propeller is above the head.
* Propeller animates only while active.
* It freezes on its current frame while idle or cooling down.
* Damage flash affects all three sprite layers.
* Preview and orientation work in all four directions.

### Regression safety

* `turret_epine` still fires normally.
* Its projectile release timing is unchanged.
* Its shot animation and cooldown frame remain correct.
* Its preview and LOS remain correct.
* Existing weapons and sprays are unchanged.
* Existing blueprint unlocks and publications are unchanged.
* No new per-frame all-agent or all-map scan exists.
* No unnecessary native rebuild or navigation recomputation was introduced.

---

## 12. Manual test list for the final report

Do not run these tests. Include them in your report for me to perform:

1. Start from a fresh game and confirm the blueprint is absent before its eligible dawn.
2. Reach dawn and confirm the inventor notification appears.
3. Open inventor dialog and verify the Fan Turret blueprint, icon, and 10-money price.
4. Buy it, close the dialog, and verify the build option appears.
5. Save and reload; confirm the unlock persists.
6. Build it in all four orientations.
7. Verify the coverage preview is a 90-degree five-tile cone.
8. Verify placement costs 10 gems and unbuilding/refund matches `turret_epine`.
9. Put a monster in the cone and verify the one-second active/three-second cooldown cycle.
10. Let several monsters enter at different times during one active second.
11. Test a client, builder, merchant, inventor, and sheep.
12. Stand the player inside the cone and verify no effect.
13. Compare regular monster and bigmonster displacement.
14. Put a wall between the turret and an agent and verify the wind is blocked.
15. Add/remove a wall after turret placement and verify coverage updates without stale LOS.
16. Push a drownable agent onto water.
17. Push bigmonster onto water and verify it does not drown.
18. Damage the turret and verify all sprite layers flash.
19. Let monsters and tantrum clients attack and destroy it.
20. Remove the turret while active and check for lingering effects or errors.
21. Pause during active wind and during cooldown; verify timers freeze.
22. Place several helix turrets and many agents; inspect for frame spikes.
23. Re-test `turret_epine` firing, visuals, preview, cooldown, damage, and removal.
24. Check startup and runtime logs for warnings, errors, invalid navigation invalidations, or stale native calls.

---

## 13. Final report

Report:

1. Every changed and created file.
2. The final ownership split.
3. How wind agents are queried without global scans.
4. How entry and 0.5-second repeat impulses are tracked.
5. How walls and cone coverage are enforced.
6. How bigmonster resistance is reused.
7. What focused cleanup was performed.
8. Whether the `_nearest_enemy_in_range()` issue was present and changed.
9. What behavior was intentionally preserved.
10. Compatibility wrappers retained.
11. Any private coupling or messy area deliberately left unchanged.
12. Any production-quality concern discovered.
13. The temporary reuse of `items.png` frame `6`.
14. The complete manual test list.
15. Confirmation that no Godot, test, compilation, build, or export command was run.
