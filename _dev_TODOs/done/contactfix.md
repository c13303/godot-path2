TASK — Fix excessive player-contact shove for villagers and small monsters

Read `AGENTS.md` and follow the project’s architecture, typing, optimization, and file-size rules.

## Problem

When the player walks into a villager, the villager is pushed much too far and continues sliding like it is on ice.

The same gentle contact behavior is required for:

* All villagers
* `monster`
* `greenmonster`

Do not apply the new tuning to `bigmonster`, which intentionally has a heavier and stronger contact response.

## Existing behavior to inspect

The relevant systems appear to include:

* `scripts/controls/player_controller.gd`
* `scripts/map/agent_definition_service.gd`
* `scripts/entities/monster_catalog.gd`
* `extensions/rabbit_game_native/steering/steering_system.cpp`

Current approximate values found during inspection:

```text
player contact_push_power = 216
villager/small-monster contact_push_resist = 1.0
contact_push_cooldown = 0.20 s
contact friction loss = 0.65
control suppression = coupled to the contact cooldown
generic propelled lifetime = 8 s
generic stop threshold = 0.20 px/s
```

The important issue is that native friction currently behaves approximately like:

```cpp
velocity *= pow(1.0 - friction_loss, delta);
```

Therefore `friction_loss = 0.65` does not remove 65% of velocity immediately. It only produces slow exponential decay over time, causing agents to coast for several tiles.

Also inspect whether the contact cooldown is incorrectly reused as the duration during which autonomous agent control is fully suppressed.

## Required implementation

### 1. Separate contact cooldown from control suppression

Contact cooldown and control cancellation are two different responsibilities:

* Contact cooldown prevents a new contact impulse from being applied too frequently.
* Control suppression temporarily prevents autonomous steering from immediately cancelling the shove.

Do not use the same value for both.

Add a clean receiver-side way for an agent profile to define its contact response, for example:

```cpp
double contact_push_friction_loss = 0.65;
double contact_control_suppression_seconds = 0.20;
```

Use the project’s existing profile/config architecture rather than introducing scattered agent-type checks in the steering system.

The native contact impulse path should pass:

* The receiver’s contact friction
* The receiver’s control-suppression duration
* The existing independent contact cooldown

Conceptually:

```cpp
queue_smash_impulse(
    target_id,
    impulse_dir,
    force,
    target.profile.contact_push_friction_loss,
    0.0,
    false,
    1.0,
    target.profile.contact_control_suppression_seconds,
    false,
    ImpulseQueuePriority::Contact
);
```

Adapt this to the actual API and ownership boundaries in the codebase. Do not duplicate impulse logic.

### 2. Apply gentle contact tuning

For all villagers and for `monster` / `greenmonster`, use this initial target configuration:

```text
contact_push_resist = 2.0
contact_push_cooldown = 0.20 seconds
contact_push_friction_loss = 0.995
contact_control_suppression_seconds = 0.10 seconds
```

Keep the player contact push power unchanged unless code inspection proves that the force is shared with unrelated mechanics and cannot safely be tuned receiver-side.

Expected effective initial velocity with the current player force:

```text
216 / 2.0 = 108 px/s
```

This should produce approximately:

* 8–12 px of movement before autonomous control returns
* No more than roughly 20–24 px total movement from one isolated contact
* Continued player pressure can progressively move the agent aside
* No long residual sliding
* Small monsters resume navigation almost immediately
* Villagers remain pushable but do not fly away

`greenmonster` should inherit or reuse the same generic small-monster contact profile as `monster`. Do not duplicate its configuration unnecessarily.

### 3. Preserve bigmonster behavior

Do not give `bigmonster` the gentle profile.

Its current heavier response, including its high resistance and stronger contact behavior, must remain unchanged unless a shared refactor requires explicitly restating its existing values.

### 4. Do not alter unrelated knockback systems

Do not globally change these merely to fix contact pushing:

* Weapon knockback
* Explosion knockback
* Spray behavior
* Generic smash impulses
* Generic propelled lifetime
* Generic propelled stop threshold
* Villager idle-home displacement grace
* Return-home timers

The fix must be scoped to physical contact pushing.

Reducing the villager’s return-home grace is not a valid fix: that would make the villager try to walk back through the player rather than correcting the sliding physics.

## Architecture requirements

* Keep the native C++ steering/impulse implementation generic.
* Agent-specific values belong in agent definitions/profiles/catalog data.
* Avoid hardcoded checks such as `if monster`, `if villager`, or `if greenmonster` inside the generic impulse solver.
* Reuse the existing contact and impulse systems.
* Do not add per-frame GDScript polling.
* Do not introduce extra neighborhood queries or collision scans.
* Preserve current performance characteristics for hundreds of agents.
* Maintain strict typing.
* Keep changes focused and production-ready.
* Do not leave compatibility wrappers, dead fields, duplicated constants, or temporary debug code.

If a new profile field crosses the GDScript/C++ boundary, ensure:

* It has a safe default preserving existing behavior for unaffected agent types.
* It is correctly copied/registered in all profile construction paths.
* Missing values cannot silently become zero and disable expected behavior.
* Savegames are unaffected because this should be static agent-definition data, not saved runtime state.

## Validation

Test at minimum:

### Villagers

* Player walks into a stationary villager.
* Villager moves gently out of the way.
* Villager does not coast for multiple tiles.
* Villager remains pushable under sustained player pressure.
* Villager can resume idle/home-return behavior after contact.
* Fundamental builder and all other villagers behave consistently.

### Small monsters

Test both:

* `monster`
* `greenmonster`

Verify:

* Same gentle displacement profile
* Navigation resumes quickly
* No prolonged sliding
* No frozen-control period that visibly interrupts pursuit
* Repeated overlap does not create explosive acceleration

### Bigmonster

Verify:

* Existing heavy contact behavior remains intact
* It does not accidentally inherit the small-agent values

### Regression checks

Verify that the change does not affect:

* Weapon smash
* Spray impacts
* Explosions
* Tantrum attacks
* Building damage
* Agent-agent separation
* Ordinary flow-field steering
* Save/load
* Agent spawning and profile registration

## Tuning fallback

Start with the exact requested values:

```text
resistance = 2.0
friction loss = 0.995
control suppression = 0.10 s
cooldown = 0.20 s
```

Only adjust after an actual in-game test.

Allowed narrow tuning range:

```text
contact_push_resist: 1.8–2.3
contact_push_friction_loss: 0.995–0.997
contact_control_suppression_seconds: 0.08–0.12
contact_push_cooldown: 0.20–0.24
```

Prefer adjusting resistance first for shove distance, friction second for residual glide, and control suppression only for how quickly navigation resumes.

Do not perform broad arbitrary tuning.

## Final report

Report:

1. Root cause confirmed in the actual code
2. Exact files changed
3. Exact final values used
4. How cooldown and control suppression were separated
5. How villager and small-monster profiles share the behavior
6. Confirmation that `bigmonster` remains unchanged
7. Validation performed
8. Any architectural or non-generic issue discovered during the task

If the inspected implementation contradicts any assumption in this prompt, do not blindly follow the assumption. Use the actual code path, preserve the requested gameplay result, and explain the discrepancy in the final report.
