# Task: Restore the Builder-specific hammering animation on WIP houses

Read `AGENTS.md` and `ARCHITECTURE.md` first.

Do not run Godot, tests, compilation, export, or build commands. The user tests manually.

## Scope

Restore the visible hammering effect used while a Builder actively works on a WIP house.

Keep the distinction clear:

* held-object display and attachment remain generic;
* hammering animation is Builder-specific;
* do not add a generic held-object strike-animation framework;
* do not change held roses or other agents.

## Confirmed current behavior

The work controller still periodically calls the Builder hammer animation:

```text
HouseBuilderWorkController
→ BuilderController.play_builder_hammer_swing()
→ character held-object animation
```

The current implementation uses a generic full `360°` held-object rotation with a small displacement.

That no longer reads as hammering because:

* it rotates around the hammer sprite center;
* the motion is brief and subtle;
* it looks like spinning rather than striking;
* the hammer then remains static until the next interval.

## Required result

While a Builder is actively progressing work on a WIP house, its hammer must visibly move back and forth:

```text
rest
→ raise hammer
→ strike toward the WIP house
→ return to rest
```

The hammer remains permanently visible before, during, and after the animation.

The effect is specific to Builders and must not alter generic held-object behavior.

---

## Implementation ownership

### Generic held-object visual

The existing held-object system should continue owning only:

* displaying a texture;
* attaching it to the agent;
* updating its base position;
* updating front/behind z-order;
* clearing or replacing it.

Do not add a reusable strike API or generic animation-profile system.

A minimal generic capability to expose the held-object visual node or apply a temporary transform is acceptable only if required, but it must remain a simple rendering primitive rather than a gameplay animation abstraction.

### Builder-specific hammer visual logic

Put the hammer swing implementation in the narrowest existing Builder-owned component.

Preferred ownership:

* `BuilderController`, if it already owns Builder-specific visual actions; or
* a small `BuilderHammerVisualController` only if `BuilderController` would otherwise gain substantial animation code.

Do not implement the Tween in:

* `building_manager.gd`;
* `HouseBuilderWorkController`;
* `AgentHeldObjectVisual` as a generic hammer/strike concept;
* the WIP-house scene.

### House work controller

`HouseBuilderWorkController` continues to own:

* when a strike is triggered;
* strike interval;
* immediate first strike;
* stopping triggers when work pauses or ends.

It must not manipulate Sprite2D transforms directly.

---

## 1. Implement a Builder-only hammer swing

Replace the current full rotation with a Builder-specific Tween.

The animation should use the Builder’s currently displayed hammer visual and animate it relative to its normal held-object transform.

Suggested motion:

```text
rest angle
→ wind-up angle
→ impact angle toward house
→ rest angle
```

Suggested values:

```gdscript
const HAMMER_SWING_DURATION_SECONDS: float = 0.32
const HAMMER_WINDUP_ANGLE: float = deg_to_rad(-25.0)
const HAMMER_IMPACT_ANGLE: float = deg_to_rad(50.0)
const HAMMER_STRIKE_DISTANCE: float = 8.0
```

Adjust signs/orientation after inspecting `marto.png`.

Requirements:

* no `360°` spin;
* clearly readable back-and-forth motion;
* small movement toward the house at impact;
* return exactly to the normal hammer position and rotation;
* no accumulated transform drift;
* a new strike safely replaces an unfinished previous strike;
* one Builder’s Tween must not affect another Builder.

## 2. Swing toward the assigned WIP house

Use the current assigned house center:

```gdscript
_house_manager.get_house_center_world(house_id)
```

The Builder-specific visual method should receive the target world position and derive the local strike direction.

The swing must behave coherently when the house is:

* left;
* right;
* above;
* below;
* diagonally offset.

Do not use one fixed screen-direction animation for every house.

A simple and stable approach is:

* compute normalized direction from Builder to house;
* use that direction for temporary positional displacement;
* mirror the swing-angle sign based on the target side when necessary.

Avoid excessive orientation logic. The effect only needs to read correctly.

## 3. Preserve the normal held-object attachment

The generic character/held-object update may reposition the hammer every frame.

The Builder hammer animation must therefore avoid fighting that base attachment update.

Use one of these focused solutions:

### Preferred

Keep a Builder-specific animation offset and rotation separate from the generic base held position.

The generic attachment computes the normal hammer transform, then the Builder-specific transient transform is applied on top.

### Acceptable minimal alternative

Animate a dedicated Builder hammer pivot node that exists only for Builder hammer presentation.

Do not restructure all held objects around a generic animated pivot merely for this feature.

Whatever approach is used:

* the hammer must remain attached while the Builder changes facing;
* directional z-order must still work;
* the animation must not be overwritten every frame;
* roses must remain unaffected.

## 4. Strike cadence

Keep hammering coupled to actual work progression.

Required behavior:

* trigger one strike immediately when the Builder begins actively working;
* repeat while work progress is advancing;
* approximately one strike per second;
* do not strike while travelling to the house;
* do not strike during idle pauses that are not counted as work, unless the existing work animation intentionally includes those pauses;
* stop when the task is cancelled;
* stop on house completion;
* stop at Night;
* stop if the Builder or target house becomes invalid.

Do not modify:

* construction duration;
* work progress rate;
* task ordering;
* Builder movement around the house;
* Night interruption behavior.

## 5. Reset cleanly

Add a Builder-specific reset method for hammer animation.

It must:

* kill the active hammer Tween;
* clear temporary animation offset;
* clear temporary animation rotation;
* restore the hammer’s normal held pose;
* keep the hammer visible.

Call it when:

* work stops;
* assignment changes;
* target house disappears;
* construction completes;
* Night interrupts work;
* Builder is removed or reset.

## 6. Remove obsolete use of the generic full rotation

Inspect all usages of:

```gdscript
animate_held_object_full_rotation()
rotate_full_turn()
```

If Builder hammering is the only real caller:

* remove the obsolete methods and related constants.

If another feature genuinely uses them:

* retain them for that feature;
* stop using them for Builder hammering.

Do not leave dead Builder wrappers pointing to the old full-spin effect.

---

## Likely files to inspect

At minimum:

* `scripts/map/house_builder_work_controller.gd`
* `scripts/map/builder_controller.gd`
* `scripts/entities/character.gd`
* `scripts/entities/agent_held_object_visual.gd`
* `scripts/map/agent_definition_service.gd`

Only add a new Builder-specific visual controller if it materially improves ownership and keeps `BuilderController` focused.

Do not broaden the change into a held-object refactor.

---

## Performance constraints

* Use Tween, not `_process`.
* Do not recreate the hammer sprite for every strike.
* Do not add polling.
* Do not add a global animation manager.
* Multiple Builders must animate independently.
* Allocation should be limited to the short Tween created for each strike.

---

## Manual verification

The user must verify:

1. A Builder reaches a WIP house and immediately performs a visible hammer strike.
2. The hammer raises, strikes, and returns instead of spinning.
3. The strike visibly points toward the WIP house.
4. The hammer remains attached while the Builder changes position or facing.
5. The hammer returns to the exact normal pose after every strike.
6. No positional or rotational drift appears after prolonged work.
7. Work completion stops the animation but leaves the hammer visible.
8. Night interruption resets the hammer pose.
9. Destroying or cancelling the target house stops the animation safely.
10. Multiple Builders can hammer independently.
11. Client-held and monster-held roses remain visually unchanged.

## Final report

Report:

1. the confirmed root cause;
2. files changed;
3. where the Builder-specific hammer Tween now lives;
4. how it layers over the generic held-object attachment;
5. how interruption/reset is handled;
6. whether the old full-rotation API was removed;
7. exact manual checks required.

Do not claim runtime success because Godot was not run.
