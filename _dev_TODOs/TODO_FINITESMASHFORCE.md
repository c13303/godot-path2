# Task: Add finite smash-force absorption to spray projectiles

Read and follow `AGENTS.md` before editing.

Implement only **Problem #1**: one spray projectile must no longer give every overlapping agent an independent copy of its complete smash force.

Do not address player knockback, big-monster contact push, control suppression, or Problem #2.

## Current defect

The relevant path is:

```txt
scripts/combat/fight_system.gd
    _register_spray_projectiles()

extensions/flowfield/godot/projectile_system_native.cpp
    ProjectileSystemNative::register_type()

extensions/flowfield/projectile/projectile_system.cpp
    ProjectileSystem::update()

extensions/flowfield/steering/steering_system.cpp
    SteeringSystem::apply_area_smash()
    SteeringSystem::apply_smash_impulse()
```

On an agent impact, `ProjectileSystem::update()` currently calls:

```txt
steering->apply_area_smash(...)
```

`apply_area_smash()` independently applies `force * attenuation` to every eligible agent inside the AoE.

For `scripts/combat/weapons/spray.tres`:

```txt
smash_force = 400
falloff = 0
spray_projectile_radius = 6
```

Because falloff is zero, every overlapping eligible agent receives the complete force of `400`, regardless of crowd density.

This creates smash force out of nothing: a projectile affecting 50 stacked agents effectively produces approximately 50 times as much total impulse as the same projectile hitting one agent.

## Required behavior

For the spray weapon, one projectile must have a **finite total smash-force budget**.

The projectile’s configured `smash_force` must serve both as:

* the maximum force that one agent can receive from that projectile;
* the total force budget available across all agents affected by that projectile impact.

Consequences:

* One isolated normal agent still receives the full configured smash force.
* In a dense crowd, the directly hit/front agent receives the force first.
* Any remaining force may propagate to subsequent agents.
* Once the budget is empty, deeper agents receive no smash impulse.
* One projectile must never distribute more total pre-resistance smash force than its configured `smash_force`.
* A sustained spray should progressively peel or push the front of a crowd instead of moving the complete stack simultaneously.

For the current spray settings, the directly hit agent will normally consume the complete budget because its attenuation is `1.0`. That is acceptable and intended.

## Ownership and architecture

This is **projectile-impact behavior** and belongs in:

```txt
extensions/flowfield/projectile/projectile_system.cpp
extensions/flowfield/projectile/projectile_system.h
```

Do not add the new algorithm to `steering_system.cpp`. That file is already very large, and generic `apply_area_smash()` has valid uses for explosions, melee attacks, and true AoE effects.

Reuse the existing public steering operations:

```txt
SteeringSystem::get_agent()
SteeringSystem::apply_smash_impulse()
SteeringSystem::get_max_fight_query_padding()
```

Do not create a new service, manager, framework, generic force-distribution system, or new source file.

A focused private helper inside `ProjectileSystem` is appropriate.

## Configuration

Add an explicit opt-in configuration flag.

### `scripts/combat/weapons/weapon_data.gd`

Under the existing `Spray Projectiles` group, add:

```gdscript
@export var spray_projectile_smash_budget_enabled: bool = false
```

The default must be `false` so existing `WeaponData` resources retain their current behavior.

Do not add a multiplier, penetration count, target limit, density scalar, or other tuning field. The total budget is exactly `smash_force`.

### `scripts/combat/weapons/spray.tres`

Enable the new behavior:

```txt
spray_projectile_smash_budget_enabled = true
```

Only enable it for `spray.tres`.

Do not enable it for `beam.tres` or any gun resource.

Player and turret spray attacks both reuse `spray.tres`; both should therefore receive the corrected behavior.

### `scripts/combat/fight_system.gd`

In `_register_spray_projectiles()`, pass the flag in the native projectile configuration dictionary:

```txt
"smash_budget_enabled": weapon.spray_projectile_smash_budget_enabled
```

Do not alter `_register_guns()`.

### Native configuration

In `ProjectileTypeConfig`, add:

```cpp
bool smash_budget_enabled = false;
```

In `ProjectileSystemNative::register_type()`, read the optional dictionary key:

```txt
smash_budget_enabled
```

Missing keys must preserve the legacy default of `false`.

## Direct-hit selection

The current impact detection stores only a `bool hit` and stops at the first overlapping neighbor returned by the spatial grid.

That ordering is not guaranteed to represent the front agent in a dense crowd.

Replace the boolean-only result with an identified direct-hit agent:

```txt
hit_agent_id
```

Among eligible agents whose fight AABB overlaps the projectile collision circle, select the front-most contact along the projectile travel direction.

Use the projected leading edge of the fight AABB rather than relying only on its center.

For normalized projectile direction `dir`, the projected leading-edge score can be based on:

```txt
dot(fight_center - projectile_position, dir)
- abs(dir.x) * fight_half_w
- abs(dir.y) * fight_half_h
```

The smallest score is the agent encountered first along the projectile path.

Use the agent ID as a deterministic final tie-breaker.

Do not implement a broader swept-agent collision rewrite or change the existing static-collider raycast. Only make direct-hit selection deterministic enough for the smash-budget ordering.

## Budgeted smash algorithm

When an agent impact occurs:

* If `smash_budget_enabled == false`, preserve the existing `apply_area_smash()` call exactly.
* If `smash_budget_enabled == true`, use the new budgeted projectile-smash helper.
* Damage must still be applied through the existing `apply_area_damage()` call independently of smash budgeting.

The helper must perform the following work.

### 1. Query only local candidates

Use the spatial grid with:

```txt
aoe_radius + steering->get_max_fight_query_padding()
```

Do not iterate over all agents.

### 2. Apply the same eligibility rules as the existing area smash

Exclude:

* the projectile owner;
* missing/stale agent IDs;
* drowning agents;
* `weapon_immune` agents;
* agents whose `smash_class` does not match `affected_smash_classes`;
* agents whose fight AABB is outside `aoe_radius`.

Use the existing fight geometry:

```txt
fight_center = agent.position + (0, fight_offset_y)
point_aabb_distance(...)
```

Do not use only the agent origin or world radius.

### 3. Build a deterministic front-to-back candidate order

The identified direct-hit agent must be first if it remains eligible.

Order the remaining candidates from front to back along the projectile direction using their projected AABB leading edge.

Use deterministic tie-breaking, preferably:

1. projected leading edge;
2. lateral distance from the projectile axis;
3. agent ID.

Do not depend on `SpatialGrid::query_neighbors()` ordering.

### 4. Preserve existing attenuation semantics

For each candidate, calculate distance and falloff exactly as `apply_area_smash()` currently does:

```txt
base = max(0, 1 - distance / radius)
attenuation = pow(base, max(0, falloff))
desired_force = smash_force * attenuation
```

Preserve the existing zero-falloff behavior.

### 5. Spend the finite force budget

Initialize:

```txt
remaining_budget = max(0, smash_force)
```

For each ordered candidate:

```txt
allocated_force = min(desired_force, remaining_budget)
```

If `allocated_force` is meaningfully greater than zero:

* call `steering->apply_smash_impulse()` with `allocated_force`;
* pass through the existing friction, detach-flow, control-suppression, and suppression-duration values unchanged;
* subtract `allocated_force` from `remaining_budget`.

Stop once the remaining budget is effectively zero.

The sum of all force values passed to `apply_smash_impulse()` for one projectile impact must never exceed the initial budget.

### 6. Do not double-apply resistance

`SteeringSystem::apply_smash_impulse()` already divides incoming force by:

```txt
agent.profile.smash_resist
```

Do not reproduce or pre-apply that calculation in `ProjectileSystem`.

The finite budget represents physical incoming impulse. `smash_resist` remains the receiving agent’s inertia and continues reducing its resulting movement exactly as before.

Do not modify `smash_resist` semantics.

## Damage behavior

Keep this call unchanged:

```txt
steering->apply_area_damage(...)
```

All agents currently eligible for projectile AoE damage must continue receiving damage exactly as before.

This task changes smash-force distribution only.

Do not combine the damage budget with the smash budget.

## Impact events and visuals

Preserve the existing `ProjectileImpact` event:

* same impact position;
* same direction;
* same radius;
* same type ID;
* same `ImpactKind::Agent`.

Impact visuals must remain unchanged.

The projectile must still despawn after the first detected agent impact.

## End-of-life AoE

Do not apply this budget system to:

```txt
trigger_end_aoe()
end_of_life_aoe_enabled
end_aoe_force
```

Wall-impact and expiry AoEs must retain their current generic `apply_area_smash()` behavior.

## Expected changed files

The implementation should normally be limited to:

```txt
scripts/combat/weapons/weapon_data.gd
scripts/combat/weapons/spray.tres
scripts/combat/fight_system.gd
extensions/flowfield/godot/projectile_system_native.cpp
extensions/flowfield/projectile/projectile_system.h
extensions/flowfield/projectile/projectile_system.cpp
```

Do not modify:

```txt
extensions/flowfield/steering/steering_system.cpp
extensions/flowfield/steering/steering_system.h
scripts/combat/weapons/gun_data.gd
```

unless an unexpected compile-level dependency makes it strictly necessary. Report such a dependency before broadening the design.

## Scope restrictions

Do not:

* address big-monster/player knockback;
* modify player controls or control suppression;
* alter contact push;
* modify generic melee, explosion, bomb, sword, beam, or gun behavior;
* divide smash force equally by the number of targets;
* choose a random target;
* add a hardcoded maximum target count;
* add global configuration;
* add new debugging UI;
* perform unrelated cleanup;
* refactor the complete projectile system;
* change damage behavior;
* change projectile visuals;
* change projectile lifetime, speed, radius, or fire rate.

## Performance requirements

The game may contain hundreds of agents.

The new work must:

* use the existing spatial-grid query;
* run only when a budget-enabled projectile actually impacts an agent;
* allocate and sort only the local AoE candidates;
* avoid per-frame global-agent scans;
* avoid persistent per-projectile candidate state;
* avoid GDScript-side agent enumeration.

A small local candidate vector and an `O(k log k)` sort for the locally affected agents are acceptable.

## Compatibility requirements

The new native configuration must default to legacy behavior.

Existing projectile dictionaries without `smash_budget_enabled` must continue working.

Existing guns, beam projectiles, end-of-life AoEs, melee attacks, explosions, and other direct `apply_area_smash()` callers must remain behaviorally unchanged.

Do not remove or rename existing native methods or dictionary keys.

## Manual test scenarios

Do not run Godot, tests, compilation, export, or build commands. The user performs testing manually.

Include these manual tests in the final report:

1. **Single normal monster**

   * Hit one isolated monster with one spray projectile.
   * It should receive approximately the same knockback as before.

2. **Dense stacked crowd**

   * Stack many normal monsters inside one projectile AoE.
   * One projectile must not kick the complete stack.
   * The directly hit/front agent should receive the force first.

3. **Sustained spray**

   * Hold the spray against a dense crowd.
   * The crowd should be pushed progressively from the front rather than all agents moving simultaneously from each projectile.

4. **Heavy monster**

   * Hit an isolated monster with increased `smash_resist`.
   * Its knockback reduction must remain consistent with the previous behavior.

5. **Damage preservation**

   * Confirm agents inside the damage AoE still receive the same damage as before, even when they receive no remaining smash force.

6. **Turret spray**

   * Confirm a turret using the same spray weapon gets the same budgeted crowd behavior.

7. **Beam regression**

   * Confirm `beam.tres` retains its previous smash behavior because its new resource flag remains false.

8. **Gun regression**

   * Test water and thorn gun projectiles.
   * Their direct and end-of-life AoEs must remain unchanged.

9. **Melee/explosion regression**

   * Confirm sword, bomb, and other generic area-smash behavior is unchanged.

10. **Impact visuals**

    * Confirm projectile impact rings/events still appear once at the correct impact position.

## Final report

Report:

1. Changed files.
2. The exact configuration field added.
3. Where direct-hit selection now occurs.
4. Where the finite budget is owned and distributed.
5. Confirmation that total applied smash force is capped at one projectile’s `smash_force`.
6. Confirmation that damage remains unbudgeted and unchanged.
7. Confirmation that generic `apply_area_smash()` was not modified.
8. Confirmation that Problem #2 was not touched.
9. Any compatibility behavior retained.
10. Any production-quality concern discovered.
11. The manual tests the user should run.

Do not claim runtime or compile validation because you are not authorized to run them.
