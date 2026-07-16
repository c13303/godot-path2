# Task: Make player contact pushes consistent for villagers and all navigating agents

Read `AGENTS.md` before changing code.

Do not run Godot, tests, compilation, SCons, export, or the game. The user will test manually.

## Objective

Player contact pushing must work consistently regardless of the target agent’s current navigation state.

In particular:

* The fundamental builder currently feels correct and must remain correct.
* Normal builders, the merchant, the inventor, and future villagers must behave consistently with the fundamental builder.
* A villager must remain physically pushable while:

  * parked;
  * returning to its idle/home position;
  * following an A* path;
  * waiting near its house;
  * held for interaction.
* Clients and small monsters must also receive consistent player contact pushes while following flow fields or A* paths.
* Do not implement villager-specific force hacks.
* Do not detach paths or flow fields when contact pushing.
* After the temporary displacement, navigation must naturally regain control.

---

# Confirmed diagnosis

There are two related inconsistencies.

## 1. Generic contact pushes currently have no control suppression

In:

```text
extensions/flowfield/steering/steering_system.cpp
```

`SteeringSystem::apply_contact_pushes()` queues contact impulses approximately like this:

```cpp
queue_smash_impulse(
    target_id,
    impulse_dir,
    force,
    0.65,
    0.0,
    false,
    0.0,
    0.0,
    false,
    static_cast<int>(ImpulseQueuePriority::Contact)
);
```

The two zero values mean:

```text
control_suppression = 0.0
control_suppression_duration = 0.0
```

Later, both the A* path-following branch and flow-field branch contain logic that cancels propulsion when the impulse velocity opposes the autonomous target velocity and no control suppression is active.

Relevant areas are around:

```text
steering_system.cpp:2292
steering_system.cpp:2721
```

Therefore, a contact push can appear to work when aligned with navigation, but be cancelled when the player pushes sideways or away from the agent’s destination.

This affects any navigating agent, including:

* villagers returning to idle;
* clients;
* small monsters;
* other flow-field or A*-driven agents.

The apparent behavior can vary according to the agent’s current direction and movement branch.

## 2. The fundamental builder uses native pause; ordinary villagers do not

The fundamental builder calls the native:

```text
set_agent_paused()
```

through `BuilderController.set_fundamental_builder_paused()` when appropriate.

The native paused branch intentionally freezes autonomous navigation while still allowing contact propulsion:

```text
extensions/flowfield/steering/steering_system.cpp:2133-2157
```

This is why the fundamental builder feels substantially better when interacting with the player.

Ordinary villagers do not consistently reproduce this:

* `SeedMerchantController` tracks a logical `_paused` boolean but deliberately does not call native pause.
* The inventor has no movement role and therefore has no equivalent interaction hold.
* The comment claiming that native pause would prevent contact movement is incorrect: the native paused branch explicitly preserves contact propulsion.

---

# Required implementation

Implement both sections below. The interaction-pause parity is not a replacement for fixing generic contact suppression.

---

## Part 1 — Give generic contact pushes control suppression

Modify:

```text
extensions/flowfield/steering/steering_system.cpp
```

### Required behavior

When `apply_contact_pushes()` queues a contact impulse:

* use full autonomous control suppression:

  * `control_suppression = 1.0`;
* use the effective contact cooldown as the suppression duration:

  * `control_suppression_duration = cooldown`;
* keep:

  * `detach_flow = false`;
  * `ImpulseQueuePriority::Contact`;
  * the existing contact resistance calculation;
  * the existing pressure comparison;
  * the existing pair cooldown;
  * the existing smash resistance;
  * the existing impulse friction.

Conceptually:

```cpp
queue_smash_impulse(
    target_id,
    impulse_dir,
    force,
    0.65,
    0.0,
    false,
    1.0,
    cooldown,
    false,
    static_cast<int>(ImpulseQueuePriority::Contact)
);
```

Use the already calculated effective pair cooldown. Do not introduce an unrelated magic duration.

### Why

During the short contact window:

* autonomous flow/A* steering must yield;
* the contact impulse must not be immediately cancelled;
* the path or flow assignment must remain intact;
* when suppression expires, the existing navigation naturally resumes.

### Important constraints

Do not:

* special-case the player;
* special-case villagers;
* special-case clients;
* remove the opposing-velocity cancellation globally;
* detach flow fields;
* detach A* paths;
* modify contact push power values;
* modify contact resistance values;
* convert contact pushes into gameplay/weapon impulses;
* change `ImpulseQueuePriority`.

The contact system is symmetric. The same generic rule must also continue to support cases such as a big monster physically pushing the player.

Add a concise comment explaining that the contact cooldown is also the short autonomous-control suppression window, preventing path/flow steering from cancelling the physical contact impulse before the next contact may be generated.

---

## Part 2 — Reuse the fundamental builder’s native-pause behavior for ordinary villagers

The fundamental builder’s behavior should be reproduced through the shared visitor movement system, not copied independently into every villager role.

### 2.1 Add a focused pause API to `DayVisitorMovementController`

Modify:

```text
scripts/map/day_visitor_movement_controller.gd
```

This controller already owns:

* the native navigation ID;
* access to `agent_manager`;
* visitor movement/path assignment.

Add a small public API such as:

```gdscript
func set_autonomous_paused(value: bool) -> void
func is_autonomous_paused() -> bool
```

Naming may vary slightly, but it must clearly mean native autonomous-navigation pause, not pausing the scene tree or gameplay globally.

Requirements:

* Cache the current pause state so repeated calls are idempotent.
* Call native `agent_manager.set_agent_paused(_nav_id, value)` when the native agent is valid.
* Do not detach its path.
* Do not change `_waiting`, `_leaving`, or its target.
* Ensure an old visitor is unpaused before its movement state is cleared/reset when a valid native agent still exists.
* Initialize the pause state correctly for newly spawned visitors.
* Keep strict GDScript typing.

This becomes the single shared GDScript entry point for pausing a `DayVisitorMovementController`.

---

### 2.2 Route the fundamental builder through the shared API

Modify:

```text
scripts/map/builder_controller.gd
```

Update `set_fundamental_builder_paused()` so it obtains the fundamental builder’s `DayVisitorMovementController` and calls the new shared pause API.

Do not change when the fundamental builder becomes paused or unpaused.

Preserve its exact current gameplay behavior. This change is ownership cleanup only:

```text
BuilderController decides when.
DayVisitorMovementController performs the native movement pause.
```

Do not add ordinary-villager logic to `BuilderController`.

---

### 2.3 Make interaction hold generic for ordinary house residents

Modify:

```text
scripts/map/house_resident_config.gd
scripts/map/house_resident_controller.gd
scripts/map/building_manager.gd
```

Add an explicit optional configuration value to `HouseResidentConfig`, for example:

```gdscript
var interaction_hold_radius_tiles: int = 0
```

Semantics:

* `0` means the resident has no automatic proximity interaction hold.
* A positive value means the ordinary resident pauses autonomous movement when the player is within that tile radius.

Set this value to `2` for:

* the merchant;
* the inventor.

Do this where their `HouseResidentConfig` objects are constructed in `BuildingManager._setup_ally_housing()`.

Future ordinary villagers with dialogs should be able to opt into the same behavior by setting this one configuration value.

### HouseResidentController ownership

`HouseResidentController` must own the ordinary resident’s interaction-hold state.

Add focused state/query methods, for example:

```gdscript
var _interaction_held: bool = false

func is_interaction_held() -> bool
func _set_interaction_hold(value: bool) -> void
func _process_interaction_hold() -> void
```

`_set_interaction_hold()` must delegate to:

```gdscript
_visitor.set_autonomous_paused(value)
```

### Required interaction-hold behavior

An ordinary resident may enter interaction hold only when:

* it is active;
* it is daytime;
* it is not leaving;
* it is not evacuating;
* it is not returning home for the night;
* it has initially reached/parked at its idle spot;
* the player is within its configured interaction radius.

Once the hold has started, it must remain active while the player remains near, even if:

* the player pushes the resident away;
* idle-home correction assigns a return A* path;
* `_visitor.is_waiting()` becomes false because that return path was assigned.

This detail is essential.

The intended sequence is:

1. Resident is parked.
2. Player approaches.
3. Native autonomous movement is paused.
4. Player pushes the resident.
5. Idle-home correction may assign a path back home.
6. The path remains assigned, but native pause prevents the resident from fighting the player.
7. Contact pushes continue moving it through the native paused branch.
8. Player leaves the interaction radius.
9. Native pause is released.
10. The already-assigned path naturally returns the resident home.

Do not continuously require `has_reached_idle_spot()` after the hold has already begun.

A suitable condition is conceptually:

```gdscript
if not _interaction_held and not has_reached_idle_spot():
    return
```

Then update the held state from player proximity.

### Mandatory release cases

Release the native interaction hold immediately before or during:

* night transition;
* evacuation;
* house destruction/removal;
* resident clearing;
* agent-removal cleanup;
* departure;
* any lifecycle transition where autonomous movement must resume.

In particular, release it before assigning the night return path.

Never leave a native agent paused after its resident controller has been reset.

### Processing order

Process interaction hold after arrival state has been updated but before idle-home correction, so a newly parked resident can enter the hold and a displaced held resident can safely receive an idle-return path.

Keep the existing resident tick consolidated. Do not add a new global per-frame scan.

---

### 2.4 Remove merchant-specific duplicate pause ownership

Modify:

```text
scripts/map/seed_merchant_controller.gd
```

The merchant role must no longer own a separate `_paused` state or implement its own proximity movement hold.

Its role should continue owning only merchant-specific concerns such as:

* seed merchant phase;
* purchase/phase behavior;
* shop-specific lifecycle side effects.

The generic `HouseResidentController` now owns interaction hold and native pause.

There is an existing compatibility/query method:

```gdscript
func is_paused_agent(agent: Node2D) -> bool
```

It is referenced indirectly by existing navigation code. Do not casually delete it.

Keep it as a thin compatibility wrapper if still required, but make it delegate to the resident controller’s canonical state:

```gdscript
return (
    _resident != null
    and _resident.owns_agent(agent)
    and _resident.is_interaction_held()
)
```

Update stale comments that currently state native pause would prevent contact movement.

Do not add merchant-specific native movement calls.

---

### 2.5 Inventor must use the generic behavior

Do not create an `InventorMovementController` or inventor-specific pause role.

The inventor must receive the behavior solely from:

```text
HouseResidentConfig.interaction_hold_radius_tiles = 2
HouseResidentController
DayVisitorMovementController
```

Its existing dialog controller should remain focused on dialog concerns.

Do not duplicate proximity pause logic inside:

```text
scripts/ui/inventor_dialog_controller.gd
```

unless a minor compatibility adjustment proves strictly necessary.

---

# Preserve existing behavior

Do not change:

* villager contact push power;
* villager contact resistance;
* player push power;
* monster data;
* big-monster resistance/pushing behavior;
* villager health;
* health-bar rules;
* house ownership;
* resident spawn/reconstruction;
* night departure rules;
* idle-home delay or displacement thresholds;
* dialog text;
* interaction radius;
* builder work behavior;
* flow-field target assignment;
* A* path generation;
* save format.

Do not add contact-push configuration to every villager definition. The fix belongs to the generic contact impulse system and generic resident interaction lifecycle.

---

# Performance requirements

The game may contain hundreds of agents.

* Do not add a GDScript per-frame loop over all native agents.
* Native contact processing already scans relevant spatial neighbors; keep using it.
* Ordinary-resident proximity processing must remain inside the existing small registered resident tick.
* Do not trigger flow-field rebuilds or navigation invalidation when an agent is contact-pushed.
* Do not recalculate paths on every contact frame.
* Keep the existing lazy idle-home correction interval.

---

# Required code review checks

Before finishing, inspect all call sites of:

```text
set_agent_paused
queue_smash_impulse
is_paused_agent
HouseResidentConfig
DayVisitorMovementController.clear
DayVisitorMovementController.forget_agent
```

Check for:

* dynamic `call()` usage;
* compatibility wrappers;
* stale comments;
* duplicate pause state;
* lifecycle paths that might leave an agent paused.

Do not perform unrelated cleanup.

---

# Acceptance criteria

## Fundamental builder

* Fundamental builder behavior is unchanged.
* Approaching it in the existing interaction situation still pauses autonomous navigation.
* The player can push it while it is natively paused.
* Moving away releases it correctly.

## Merchant

* The merchant reaches its house spot normally.
* When the player enters the configured radius, autonomous navigation is natively paused.
* The player can push it from every direction.
* If idle correction assigns a path while the player remains near, it does not become immovable.
* It resumes its path when the player moves away.
* Its shop, prompt, phase, and night behavior remain unchanged.

## Inventor

* The inventor receives the same physical behavior as the merchant without an inventor-specific movement controller.
* It remains pushable while the player is nearby.
* Its dialog still opens and closes normally.
* It resumes returning home after the player leaves.

## Normal builders

* Normal builders remain pushable while idle and while walking back to their claimed idle cells.
* No builder-specific contact-force workaround is introduced.

## Clients

Test contact pushing during:

* flow-field entry;
* A* movement, where applicable;
* flow-field exit.

Push from:

* behind;
* in front;
* either side.

A contact push must visibly displace the client before navigation regains control.

## Monsters

* Small monsters remain pushable from every direction while following a flow field.
* Big monsters retain their existing high resistance and contact pressure.
* Big-monster/player contact remains symmetric according to existing pressure and resistance values.

## General native behavior

* Contact pushes do not detach paths or flow fields.
* Contact pushes are not immediately cancelled by opposing navigation.
* Autonomous movement resumes after the short suppression window.
* Weapon/gameplay impulses retain their existing suppression values and priorities.
* Traffic impulses retain their existing priority.
* Contact cooldown is not consumed by an impulse that produces no visible displacement due to immediate steering cancellation.

---

# Manual test scenarios to report

Do not run these tests. Include them in the final report for the user:

1. Push the fundamental builder from all four directions.
2. Push the merchant while parked.
3. Keep standing near the merchant until idle-return correction assigns a path; continue pushing it.
4. Move away and verify the merchant returns home.
5. Repeat with the inventor.
6. Push a normal builder away from its idle claim and during its return.
7. Push a client while entering and leaving.
8. Push a small monster forward, backward, and sideways relative to its flow direction.
9. Contact a big monster and verify its existing weight/resistance remains apparent.
10. Start night while standing near a held resident and verify it unpauses and leaves correctly.
11. Destroy a held resident’s house and verify evacuation is not frozen.
12. Check for new warnings or errors.

---

# Final report requirements

Report:

1. Every changed file.
2. The exact native contact-suppression behavior added.
3. How `DayVisitorMovementController` now owns native visitor pause calls.
4. How fundamental-builder behavior was preserved.
5. How merchant/inventor interaction hold is now shared.
6. Any compatibility wrapper retained.
7. Any stale or duplicated logic removed.
8. Production-quality concerns noticed but intentionally left outside this task.
9. The manual tests the user should perform.

Do not claim tests passed because no runtime/build/test commands are authorized.
