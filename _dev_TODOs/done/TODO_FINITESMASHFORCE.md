# Task: Back up the current spray and convert the active spray to direct-hit-only projectiles

Read and follow `AGENTS.md` before editing.

Implement only this task.

## Objective

1. Preserve the **current spray weapon** as an unused backup resource named:

```text
res://scripts/combat/weapons/old_spray.tres
```

2. Convert the active `spray` weapon so that:

> Each spray projectile collides with exactly one front-most agent and applies its complete damage and smash effect only to that agent.

The active weapon must remain identified as `"spray"` and continue being the weapon used by `level_demo.tscn`, the player, shops, difficulty presets, and spray turrets.

`old_spray` must not be used or registered anywhere in `level_demo.tscn`.

---

# 1. Preserve the current spray as `old_spray`

Before changing `spray.tres`, copy its **current working-tree contents** to:

```text
scripts/combat/weapons/old_spray.tres
```

This backup must preserve the current spray configuration, including the previously implemented smash-budget configuration if that field currently exists.

Change only what is necessary to make it a separate dormant resource:

```text
id = "old_spray"
```

Do not duplicate the embedded resource UID from `spray.tres`.

Either:

* assign a genuinely unique resource UID using the project’s established method; or
* omit the `uid` field from the new `.tres` header and allow Godot to assign one later.

Never leave `spray.tres` and `old_spray.tres` with the same UID.

## `old_spray` must remain completely unused

Do not add `old_spray` to:

* `FightSystem.weapons`;
* `ItemCatalog`;
* starting weapons;
* merchant inventories;
* legacy shops;
* turret defaults;
* difficulty presets;
* `level_demo.tscn`;
* another scene or resource;
* any preload or runtime registration.

A repository search for these must return no references outside the backup resource itself:

```text
old_spray
old_spray.tres
```

The backup exists only for future manual restoration.

Do not replace any `"spray"` item ID in `level_demo.tscn` with `"old_spray"`.

---

# 2. Preserve the active spray’s identity and presentation

The active resource remains:

```text
scripts/combat/weapons/spray.tres
```

Its ID remains:

```text
id = "spray"
```

Preserve its existing configuration unless specifically required by this task:

* projectile rate;
* projectile speed;
* lifetime;
* collision radius;
* visual radius;
* shader;
* projectile growth;
* spread;
* reserve cost;
* reserve timing;
* watering behavior;
* static collision mask;
* pool size;
* smash force;
* damage;
* friction;
* control suppression;
* control-suppression duration;
* affected smash classes.

Do not convert it into a `GunData`.

It remains a spray-projectile `WeaponData`.

Do not change its item-catalog entry, shop availability, price, icon/frame, inventory ID, or input handling.

---

# 3. Add an explicit direct-hit projectile mode

The generic native projectile system is also used by guns and other weapon behavior. Do not globally convert all projectiles to direct-hit-only behavior.

Add an explicit opt-in field under the existing `Spray Projectiles` section of:

```text
scripts/combat/weapons/weapon_data.gd
```

Use a clear name such as:

```gdscript
@export var spray_projectile_direct_hit_only: bool = false
```

The default must be `false`.

Set it to `true` in:

```text
scripts/combat/weapons/spray.tres
```

The copied `old_spray.tres` must retain the old behavior. Therefore, its direct-hit-only field must remain `false` or omitted.

If the previous force-budget patch added a field such as:

```text
spray_projectile_smash_budget_enabled
```

then for the active `spray.tres`:

* enable direct-hit-only behavior;
* disable the budgeted AoE smash behavior.

Do not execute both modes for one impact.

The previous mode may remain available for the dormant `old_spray` backup.

---

# 4. Pass the mode explicitly to the native projectile system

In:

```text
scripts/combat/fight_system.gd
```

update `_register_spray_projectiles()` so the native projectile configuration receives the direct-hit setting, for example:

```text
"direct_hit_only": weapon.spray_projectile_direct_hit_only
```

Do not change `_register_guns()` unless the native configuration requires the same optional key to be passed explicitly. Missing keys must still default to legacy behavior.

Add the corresponding configuration field to:

```text
extensions/flowfield/projectile/projectile_system.h
```

For example:

```cpp
bool direct_hit_only = false;
```

Read the optional dictionary key in:

```text
extensions/flowfield/godot/projectile_system_native.cpp
```

Existing projectile configurations without the key must behave exactly as before.

---

# 5. Select one real front-most collision target

The existing projectile collision path must not use the first ID returned by:

```text
SpatialGrid::query_neighbors()
```

Spatial-grid neighbor ordering is not a valid collision order.

For direct-hit-only projectiles, identify the actual first eligible agent touched during the projectile’s movement from:

```text
prev_pos
```

to:

```text
p.pos
```

Implement this as focused private logic owned by:

```text
ProjectileSystem
```

Do not add it to `SteeringSystem`.

## Candidate query

Use only the existing spatial grid.

Query around the projectile movement segment, not all agents.

A suitable local query region is centered on the movement segment and large enough to contain:

* the complete segment;
* the projectile collision radius;
* the maximum agent fight-query padding.

Do not introduce a global-agent iteration.

## Agent eligibility

A direct-hit candidate must satisfy the same filtering currently used for projectile impacts:

* not the projectile owner;
* agent still exists;
* not drowning;
* not `weapon_immune`;
* matches `affected_smash_classes`;
* its fight geometry is intersected by the projectile.

Use the agent’s fight AABB:

```text
fight_center
fight_half_w
fight_half_h
fight_offset_y
```

Do not use only the agent origin or visual sprite bounds.

## Collision ordering

Treat the projectile as a moving circle.

For collision testing, expand the agent fight AABB by the projectile radius, then test the movement segment against that expanded AABB.

For every intersected eligible candidate, calculate the earliest contact parameter along the segment.

Select:

1. the smallest contact parameter;
2. agent ID as the deterministic tie-breaker.

This ensures that the agent physically closest to the front of the projectile path absorbs the projectile.

Do not use random selection.

Do not use distance to the projectile’s final position as the sole ordering criterion.

Do not rely on spatial-grid iteration order.

## Impact position

When a segment contact is found, use the calculated first-contact point as the projectile impact position where practical.

This avoids placing the impact behind the front agent when the projectile travelled several pixels during the frame.

Do not change static-collider ordering: wall/static collision handling must continue occurring before agent-impact handling as it currently does.

---

# 6. Apply the complete effect only to the selected agent

When `direct_hit_only == true` and a valid agent is hit:

## Smash

Call the existing direct operation:

```text
SteeringSystem::apply_smash_impulse()
```

for the selected agent ID only.

Pass the full configured values unchanged:

* `smash_force`;
* projectile direction;
* friction loss;
* detach-flow value;
* control suppression;
* control-suppression duration.

Do not apply falloff.

Do not divide the force by crowd size.

Do not spend a force budget across several agents.

Do not call `apply_area_smash()` for this impact.

`smash_resist` must continue being handled by `apply_smash_impulse()` exactly as before.

Do not pre-apply or duplicate resistance.

## Damage

Apply the full configured projectile damage to the same selected agent only:

```text
cfg.damage
```

Do not call `apply_area_damage()` for this impact.

The complete direct projectile effect is therefore:

```text
one projectile
→ one selected front agent
→ one full smash impulse
→ one full damage event
→ projectile despawns
```

No other nearby agent receives damage or smash from that projectile.

---

# 7. Add a focused direct-damage operation

The native projectile system currently has:

```text
apply_smash_impulse(agent_id, ...)
```

but damage is currently exposed through:

```text
apply_area_damage(...)
```

Add a small direct operation to the core `SteeringSystem`, for example:

```text
apply_damage_to_agent(...)
```

in:

```text
extensions/flowfield/steering/steering_system.h
extensions/flowfield/steering/steering_system.cpp
```

This method should:

* accept an agent ID;
* accept damage;
* optionally accept `affected_smash_classes` if needed to preserve filtering;
* reject missing agents;
* reject non-positive damage;
* reject drowning agents;
* reject `weapon_immune` agents;
* reject agents outside the requested smash-class mask;
* push one existing `DamageEvent`;
* use the agent fight center as the damage-event position.

Do not introduce a second damage-event system.

Do not expose this method to GDScript unless an actual current caller requires it.

It is acceptable for it to be a public C++ core operation used directly by `ProjectileSystem`.

Avoid duplicating the full damage-event logic in `ProjectileSystem`.

---

# 8. Preserve the old projectile paths

For projectile types where:

```text
direct_hit_only == false
```

preserve their current behavior.

This includes:

* existing gun projectile AoEs;
* water gun behavior;
* thorn gun behavior;
* end-of-life AoEs;
* explosions;
* beam behavior;
* melee behavior;
* the dormant `old_spray` behavior;
* the previously implemented force-budget mode, if it currently exists.

The native impact branch should conceptually remain:

```text
if direct_hit_only:
    apply full smash and damage to selected agent only
elif existing smash-budget mode is enabled:
    use the existing budgeted behavior
else:
    use the existing legacy AoE behavior
```

Use clean direct control flow. Do not stack multiple effect modes.

Do not remove the previous budget implementation during this task unless inspection proves it is incomplete dead code and removing it would not prevent `old_spray` from reproducing the backed-up behavior.

---

# 9. Projectile lifetime and impact events

After a direct agent hit:

* record one `ProjectileImpact`;
* mark it as `ImpactKind::Agent`;
* deactivate the projectile;
* return its slot to the free list;
* do not let it continue into another agent.

Because no gameplay AoE was applied, the impact event radius should represent that accurately.

Prefer:

```text
radius = 0
```

for a direct-hit-only agent impact, unless an existing consumer specifically requires the physical projectile radius.

Do not report the old `aoe_radius` as though an AoE was applied.

The active spray currently has no agent-impact AoE ring rendering, so this should not change its visible spray presentation.

Preserve:

* water metaball rendering;
* active projectile rendering;
* damage-number rendering;
* splash effects triggered by damage events;
* static plant watering;
* static wall/turret collisions;
* expiry behavior.

---

# 10. `level_demo.tscn` requirements

`level_demo.tscn` currently uses the item ID:

```text
spray
```

in merchant/shop configuration.

Keep those entries as `"spray"`.

The scene should therefore automatically use the newly converted active spray through the existing item and `FightSystem` wiring.

Do not add:

```text
old_spray
```

to:

* `starting_weapons`;
* `merchant_available_items`;
* `merchant_prices`;
* `shop_available_items`;
* `shop_prices`;
* any scene node;
* any exported weapon array.

No `level_demo.tscn` edit should be necessary merely to activate the new behavior, because the active resource path and item ID remain unchanged.

If no scene edit is needed, leave the scene untouched.

---

# 11. Difficulty and turret behavior

Keep:

```text
scripts/gameState/difficulty.gd
```

preloading and modifying:

```text
spray.tres
```

It must not reference `old_spray.tres`.

If the difficulty preset explicitly resets every spray field, add the new direct-hit-only field to the hardcore reset so pressing F3 cannot accidentally disable the new behavior:

```text
_spray.spray_projectile_direct_hit_only = true
```

If the old budget field is currently reset there, ensure the active spray’s settings remain unambiguous:

```text
direct hit only = true
budgeted AoE smash = false
```

Turrets currently reuse the `"spray"` weapon through `FightSystem`.

They should automatically receive direct-hit-only behavior too.

Do not create a separate turret implementation.

---

# 12. Scope restrictions

Do not:

* change Problem #2 or big-monster player knockback;
* modify player movement or input suppression outside existing spray values;
* change contact push;
* convert spray into `GunData`;
* remove spray metaball visuals;
* reduce projectile count as a substitute for correct collision behavior;
* add a hard maximum number of agents;
* divide force by target count;
* keep AoE damage while making only smash direct;
* let one projectile damage one agent and smash another;
* add `old_spray` to the item catalog;
* register `old_spray`;
* modify unrelated level configuration;
* run Godot;
* run tests;
* compile the extension;
* export or build the project;
* perform unrelated cleanup.

---

# 13. Expected files

The change should normally be limited to:

```text
scripts/combat/weapons/old_spray.tres          new dormant backup
scripts/combat/weapons/spray.tres
scripts/combat/weapons/weapon_data.gd
scripts/combat/fight_system.gd
scripts/gameState/difficulty.gd                only if preset reset requires it
extensions/flowfield/projectile/projectile_system.h
extensions/flowfield/projectile/projectile_system.cpp
extensions/flowfield/godot/projectile_system_native.cpp
extensions/flowfield/steering/steering_system.h
extensions/flowfield/steering/steering_system.cpp
```

Do not modify `level_demo.tscn` unless inspection finds an explicit embedded weapon-resource override that must be corrected.

Do not add a new controller, service, manager, or C++ source file.

---

# 14. Acceptance criteria

The task is complete only when all of the following are true:

1. `old_spray.tres` contains a backup of the spray configuration that existed before this task.
2. `old_spray.tres` has its own ID and does not duplicate the active resource UID.
3. Nothing references or registers `old_spray`.
4. The active resource remains `spray.tres` with `id = "spray"`.
5. `level_demo.tscn` continues using `"spray"`.
6. One active spray projectile selects one deterministic front-most agent.
7. That selected agent receives the projectile’s full smash force.
8. That same selected agent receives the projectile’s full damage.
9. No other agent receives damage or smash from that projectile.
10. The projectile despawns immediately after that direct hit.
11. Generic projectile AoEs and end-of-life AoEs remain unchanged.
12. The active spray’s visuals, firing, resource cost, watering and turret reuse remain unchanged.
13. The new behavior does not depend on spatial-grid neighbor ordering.

---

# 15. Important gameplay expectation

Do not misreport the result.

This change guarantees:

```text
one projectile cannot affect several agents
```

It does not guarantee:

```text
one spray burst can affect only one agent
```

The spray fires many projectiles with spread. Different projectiles may legitimately hit different agents, especially when agents stand side by side.

The intended crowd protection is strongest when agents are aligned front-to-back:

* the front agent absorbs incoming projectiles;
* agents directly behind it remain untouched until exposed;
* side-by-side agents may each be hit by different droplets.

---

# 16. Manual tests

Do not run these tests. Include them in the final report for the user.

## Backup/resource checks

1. Search the repository for `old_spray`.
2. Confirm the only result is the resource itself.
3. Confirm `old_spray.tres` and `spray.tres` do not share a UID.
4. Confirm no duplicate weapon ID is registered.

## Single-agent test

1. Fire one or several spray droplets at one isolated normal monster.
2. Confirm its damage and knockback remain comparable to the active spray before this task.

## Front-to-back crowd test

1. Place five agents tightly behind one another in the firing direction.
2. Fire briefly.
3. Confirm front agents absorb projectiles.
4. Confirm one projectile never damages or knocks back several agents.
5. Confirm rear agents remain protected until their collision geometry becomes exposed.

## Side-by-side test

1. Place five agents side by side.
2. Fire the spray across them.
3. Different projectiles may hit different agents.
4. Confirm this is not mistaken for one projectile applying an AoE.

## Damage-event test

1. Observe damage numbers during a single projectile hit.
2. Confirm one projectile produces at most one damage event.

## Deterministic collision test

1. Stack or overlap several agents.
2. Fire repeatedly from the same direction.
3. Confirm the front-most collision target is consistently selected rather than changing according to grid ordering.

## Turret test

1. Use a turret configured with `"spray"`.
2. Confirm its individual projectiles also affect one agent each.

## Static collision and watering test

1. Fire at walls, reactive roses and turrets.
2. Confirm collision, watering and splash behavior remain unchanged.

## Regression tests

Confirm unchanged behavior for:

* beam;
* water gun;
* thorn gun;
* bomb;
* sword;
* projectile expiry;
* wall-impact/end-of-life AoEs.

---

# 17. Final report

Report:

1. Changed files.
2. How `old_spray.tres` was made UID-safe.
3. Confirmation that `old_spray` has zero external references.
4. The new configuration field and its default.
5. How the front-most agent is selected.
6. Whether segment-versus-expanded-AABB collision was used.
7. How direct damage is queued.
8. Confirmation that full smash and full damage target the same single agent.
9. Confirmation that no AoE damage or AoE smash occurs for active spray agent impacts.
10. Confirmation that existing generic projectile behavior was preserved.
11. Confirmation that `level_demo.tscn` still uses `"spray"` and never uses `"old_spray"`.
12. Confirmation that Problem #2 was untouched.
13. Any private coupling or production-quality concern discovered.
14. Manual test scenarios.

Do not claim compilation or runtime validation because those actions are not authorized.
