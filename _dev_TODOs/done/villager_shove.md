Read `AGENTS.md` first and follow all project architecture, typing, performance, ownership, and reporting rules.

## Task: autonomous agents gently shove an idle player

### Problem

Villagers and other autonomous agents can become permanently blocked when their navigation path passes through the player while the player is standing still.

The existing contact-pressure system appears to remain player-dominant even when the player has no movement input. As a result, the autonomous agent cannot make the idle player yield and may remain stuck indefinitely.

Implement a clean, generic fix.

## Required gameplay behavior

When an autonomous agent is actively trying to move through the player:

* If the player has no movement input, the agent may gently shove the player out of the way.
* If the player is actively walking, preserve the current player-dominant pushing behavior.
* The shove must feel controlled and gentle, not like the previous excessive sliding/penguin-on-ice behavior.
* The agent must be able to continue navigating after the player has been displaced.
* Repeated contact may continue applying the existing contact impulse at its normal cooldown until enough space is available.

This should work generically for:

* villagers;
* builders;
* merchant;
* inventor;
* future autonomous villagers;
* small monsters;
* other autonomous agents using the same movement/contact infrastructure.

Big monsters may retain their existing stronger physical profile if their current contact configuration already makes them stronger.

## Preferred implementation owner

Investigate and implement the fix in the existing native contact-resolution path, likely around:

```cpp
SteeringSystem::apply_contact_pushes()
```

Do not create a separate player-side detector or villager-specific workaround.

The current system already appears to have the required generic data:

* `AgentData.control_mode`;
* `AgentData.manual_input_dir`;
* autonomous desired/navigation direction;
* current movement/path intent;
* pairwise contact cooldowns;
* contact pressure values;
* `queue_smash_impulse()`;
* `ImpulseQueuePriority::Contact`;
* existing friction, resistance, control suppression, wall sliding, and overlap correction.

Reuse those systems rather than duplicating them.

## Generic rule

During pairwise contact resolution, identify the special case where:

1. Exactly one agent is manually controlled.
2. The manually controlled agent currently has no meaningful movement input.
3. The other agent is autonomously controlled.
4. The autonomous agent has genuine locomotion intent.
5. The autonomous agent is trying to move approximately toward or through the idle manual agent.
6. The contact pair is actually overlapping or inside the existing contact threshold.

For this specific case, allow the autonomous agent to win the contact interaction and apply the existing contact impulse to the idle manual agent.

Do not key this logic on names, groups, scene paths, or explicit types such as:

```text
player
villager
merchant
monster
```

The distinction must be based on control mode and movement intent.

## Determining whether the player is idle

Use manual movement input, not velocity.

A pushed player will temporarily have velocity even though the user is not pressing a movement control. Using velocity as the idle test would cause the first shove to disable subsequent contact pushes prematurely.

Use the existing input direction with an appropriate small deadzone, for example conceptually:

```cpp
manual_input_dir.length_squared() <= epsilon
```

Do not require exact floating-point equality unless the existing input normalization guarantees it safely.

## Determining autonomous movement intent

Do not shove the player merely because an autonomous agent happens to touch them.

Require meaningful movement intent from the autonomous agent. Reuse the most authoritative existing movement direction available in the contact system, such as:

* desired steering direction;
* navigation direction;
* active path/flow-field direction;
* intended velocity.

Also require directional relevance:

* the autonomous movement direction should point generally toward the idle player/contact obstacle;
* an agent moving away from the player must not push the player;
* an idle autonomous agent must not push the player;
* an agent merely standing beside the player must not cause jitter.

Use a reasonable dot-product threshold rather than requiring exact alignment.

Do not add raycasts, shape queries, full agent scans, or additional GDScript polling.

## Impulse behavior

Reuse the current contact impulse pipeline.

Do not introduce a new independent displacement system.

The idle-player exception should:

* enqueue a contact-priority impulse through the existing queue;
* preserve stronger gameplay knockback priorities;
* preserve smash resistance and other existing modifiers;
* preserve wall collision and sliding behavior;
* preserve static-overlap correction;
* preserve the existing pair cooldown;
* avoid stacking uncontrolled impulses every physics frame.

For impulse strength, reuse the existing pair/contact pressure configuration where possible.

Do not globally assign villagers a new permanent `contact_push_power` merely to fix this case, because that could alter moving-player-versus-moving-villager interactions everywhere.

Prefer a localized override of which participant loses the contact interaction when the manual participant is idle.

The resulting player displacement should be similar in magnitude to the existing gentle contact shove used when the player pushes a small agent, unless the existing profiles provide a cleaner canonical value.

Do not add unexplained magic constants. Any new threshold must be named, centralized appropriately, and documented briefly.

## States that must remain protected

Do not let this low-priority contact rule override states or impulses that should take precedence.

Inspect the existing rules and preserve them, including where applicable:

* stronger pending impulses;
* knockback;
* weapon effects;
* scripted control suppression;
* pause/freeze states;
* drowning;
* invalid or inactive agents;
* despawning agents;
* agents currently excluded from contact handling;
* tantrum-specific collision rules;
* big-monster special behavior.

Do not reset player velocity directly.

Do not teleport the player.

Do not directly mutate position outside the established movement/impulse pipeline unless the existing contact system already does so canonically.

## Critical regression constraints

The following behavior must remain unchanged unless strictly required by this task:

* A walking player can still push villagers and small monsters as before.
* Villagers must not become stronger than an actively moving player.
* An idle player must not be constantly pushed by nearby stationary agents.
* An agent walking past or away from the player must not pull or shove the player.
* Two autonomous agents must retain their current interaction.
* Two manual agents, if ever supported, must retain their current interaction.
* Existing combat knockback must retain priority.
* Existing player movement responsiveness must remain intact.
* The player must regain direct movement control naturally as soon as input resumes.
* No prolonged slippery movement or excessive control cancellation may be introduced.
* No new per-agent `_process()` or `_physics_process()` work.
* No new global full-agent scan.
* No new player-specific collision query.
* No navigation or flow-field recomputation for this feature.
* No allocation-heavy work inside the contact loop.

## Performance requirements

This code runs in a potentially large pairwise contact loop with hundreds of agents.

Keep the hot-path work minimal:

* cheap control-mode checks;
* squared vector lengths where possible;
* at most a small number of dot products;
* no temporary collections;
* no strings;
* no scene-tree lookups;
* no dynamic casts if avoidable;
* no repeated normalization when a squared/dot comparison is sufficient;
* no logging in the normal hot path.

Order checks from cheapest and most selective to more expensive.

## Investigation before editing

Before changing code:

1. Trace the exact current player/villager contact-resolution path.
2. Confirm why a stationary player still wins pressure resolution.
3. Identify the authoritative fields for:

   * manual input;
   * autonomous movement intent;
   * control mode;
   * impulse priority;
   * contact cooldown.
4. Confirm whether the existing traffic/right-of-way system is relevant.

Do not expand the traffic-priority system merely for this feature unless inspection proves it is already the canonical owner. This request appears to be a local physical-contact rule, not a routed-traffic-group rule.

## Suggested acceptance tests

Test or reason through all of these cases:

### Idle player

* Player stands directly in a villager’s route.
* Villager reaches the player.
* Villager gently pushes the player enough to proceed.
* No permanent deadlock remains.
* The player does not slide an excessive distance.

### Active player

* Player walks into a villager.
* Existing player-to-villager shove remains unchanged.
* The villager does not reverse-push an actively moving player.

### Input resumes during shove

* Villager begins pushing an idle player.
* User presses a movement direction.
* The idle-player exception immediately stops applying.
* Player control remains responsive.
* Existing queued contact impulse decays according to the normal system.

### Direction filtering

* Villager touches the side of the player while moving parallel.

* No unnecessary shove or visible jitter occurs.

* Villager is touching the player but moving away.

* Player is not shoved.

* Villager is idle beside the player.

* Player is not shoved.

### Multiple agents

* Several villagers encounter an idle player.
* They may displace the player using the normal contact cadence.
* The player is not launched by unbounded impulse stacking.
* No oscillation or unstable winner switching occurs.

### Other agents

* Small monster walking into idle player can make the player yield.
* Big monster retains its intended stronger profile.
* Autonomous-agent-versus-autonomous-agent behavior remains unchanged.

### Environment

* Player is pushed near walls and corners.
* Existing wall sliding/collision prevents clipping.
* The player is not pushed through blocking geometry.
* An autonomous agent eventually reroutes or proceeds where physically possible.

## Scope discipline

Make the smallest coherent production-quality change.

Do not opportunistically refactor unrelated steering or movement systems.

A small helper inside the native steering/contact owner is acceptable if it improves clarity and avoids duplicating conditions, but do not create a new subsystem for this rule.

## Required report

After implementation, report:

1. The confirmed root cause.
2. Files and functions changed.
3. The exact generic condition that allows an autonomous agent to shove an idle manual agent.
4. How autonomous movement intent and directional relevance are determined.
5. How impulse magnitude is selected.
6. How active player input preserves the previous behavior.
7. Why the change does not add meaningful hot-loop cost.
8. Tests or static validation performed.
9. Any remaining edge case or uncertainty.
10. Any nearby non-generic, unsafe, or performance-problematic code discovered during the task, without expanding scope to fix it automatically.

Do not claim runtime validation if the project was not compiled and run.
