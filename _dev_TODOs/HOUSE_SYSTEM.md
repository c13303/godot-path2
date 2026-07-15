Implement the builder tutorial arrow fix and change the fundamental builder’s house lifecycle.

Read and follow `AGENTS.md` and `ARCHITECTURE.md` before editing. Preserve the current architecture and reuse the existing builder housing, tutorial-arrow, save/load, destruction, and day/night systems. Do not add parallel systems or broad manager-level hacks.

Do not run Godot, tests, builds, exports, or compilation. The user will test manually.

## 1. Fix the missing builder tutorial arrows

Current bug:

After closing the fundamental builder’s introductory dialog, the tutorial text may activate, but the expected arrows do not appear:

1. Vertical arrow pointing to the House quickslot.
2. Horizontal arrow pointing to the `house_builder` item inside the house selector.

The tutorial currently appears to be filtered by phase logic, while this onboarding sequence occurs around dawn.

Fix the gating so this specific one-shot tutorial can display immediately after the dialog closes, regardless of the normal afternoon-only tutorial filtering.

Required behavior:

* Closing the fundamental builder dialog activates the existing “Build a builder house” tutorial.
* First arrow points to the House quickslot.
* Once the House selector is open, the arrow points to `house_builder`.
* Reuse the existing generic tutorial-arrow implementation used by comparable build tutorials, such as the turret tutorial.
* Keep arrows hidden while:

  * a dialog is open;
  * a cutscene is active;
  * it is night;
  * the target UI element is not currently available or visible.
* When the blocking state ends, the active tutorial must resume correctly.
* Do not create a separate builder-specific arrow renderer.
* Preserve the existing permanent consumption rule: the tutorial is completed forever once the player places their first builder house.
* Preserve save/load behavior for the tutorial completion state.
* Do not reactivate the tutorial in saves where it was already completed.

## 2. Fundamental builder now occupies the first builder house

Current behavior to replace:

* The first completed builder house spawns a normal builder.
* The fundamental builder leaves the map permanently.

New behavior:

* The first completed `house_builder` becomes the fundamental builder’s home.
* Completing this first house must not spawn a normal builder.
* The existing fundamental builder remains the same agent and becomes associated with that house.
* Normal builders begin spawning only from the second completed builder house onward.

Examples:

* 0 completed builder houses:

  * Fundamental builder uses the original authored spot.
  * 0 normal builders.

* 1 completed builder house:

  * Fundamental builder lives in that house.
  * 0 normal builders.

* 2 completed builder houses:

  * Fundamental builder lives in the first house.
  * 1 normal builder lives in the second house.

* 3 completed builder houses:

  * Fundamental builder lives in the first house.
  * 2 normal builders live in the later houses.

Do not merely calculate `normal_builder_count = builder_house_count - 1` without tracking ownership. The system must know which specific house belongs to the fundamental builder.

## 3. Durable house ownership

Store the fundamental-builder assignment as part of the house’s saved state, not as independently saved agent state.

Use a small explicit house-level role or equivalent existing metadata, for example:

```text
resident_role = fundamental_builder
```

The exact field name should fit the existing house data model.

Requirements:

* Only houses continue to be persisted.
* Runtime builder agents are still reconstructed from the loaded house situation.
* Exactly one builder house may have the fundamental-builder role.
* A normal builder house must not also spawn the fundamental builder.
* A fundamental-builder house must not spawn a normal builder.
* Avoid relying exclusively on array order or the current count of houses.

Backward compatibility:

* Existing saves will not contain this new field.
* When loading an older save:

  * if there is at least one completed builder house;
  * and none is marked as the fundamental builder’s house;
  * assign the oldest completed builder house using the existing stable construction-order data.
* Persist that resolved ownership on the next save.
* Do not change unrelated save data or serialize runtime builder positions.

## 4. First-house completion transition

When the first builder house completes:

* Do not retire, despawn, replace, or duplicate the fundamental builder.
* Bind the existing fundamental builder to the completed house.
* Update its home/resident reference to that house.
* The house must not request a normal builder spawn.
* Release the builder cleanly from the completed construction task through the existing work-controller lifecycle.
* Once idle, the fundamental builder should return to the same home position/entrance convention used by other builders.

Avoid any temporary state where:

* a normal builder is spawned for the first house;
* the fundamental builder is simultaneously leaving;
* two builders represent the same house.

## 5. Destruction of the fundamental builder’s house

If the specific house occupied by the fundamental builder is destroyed:

* Clear that house association.
* The fundamental builder becomes homeless again.
* Restore its original authored spot as its home anchor.
* Restore its previous lifecycle:

  * during the day, it remains available as the fundamental builder;
  * at night, it leaves through the existing night departure behavior;
  * at dawn, it returns to its original authored spot.
* Do not permanently delete or retire it.
* Do not spawn a replacement normal builder for the destroyed house.

Important:

Do not automatically transfer the fundamental builder into another surviving builder house.

Example:

* First house belongs to the fundamental builder.
* Second and third houses belong to normal builders.
* First house is destroyed.
* The two normal builders keep their own houses.
* The fundamental builder returns to its authored spot.
* No surviving normal-builder house changes ownership.

If the fundamental builder is currently working on another WIP house when its home is destroyed:

* immediately clear/replace its home reference;
* do not unnecessarily cancel valid work already in progress;
* once its current task releases it, it returns to the authored spot.

Use the existing destruction notification and builder reconciliation pathways. Do not introduce polling or per-frame house-validity watchers.

## 6. Day/night reconciliation

Update the existing builder reconciliation logic so it derives the population from explicit house roles:

* one fundamental builder exists independently of normal builder houses;
* it is either:

  * assigned to its marked completed house; or
  * assigned to its original authored spot;
* each completed normal builder house produces exactly one normal builder;
* WIP houses produce no resident;
* destroyed houses produce no resident.

At load and dawn reconciliation:

* recreate the fundamental builder in the correct state;
* recreate normal builders only for completed houses without the fundamental role;
* prevent duplicates if reconciliation runs more than once;
* keep the existing lazy/event-driven architecture.

The fundamental builder should use the same practical “living in a house” semantics already used by normal builders. Do not expand this task into a new visual system where builders visibly enter and emerge from interiors unless that already exists.

## 7. Architecture constraints

Before coding, identify:

* the current owner of tutorial activation and arrow-target selection;
* the current owner of builder-house resident reconciliation;
* the current owner of house persistence;
* the current house destruction notification path;
* the current fundamental builder spawn/retirement path.

Modify those owners rather than adding cross-domain state to an unrelated manager.

Prefer:

* one explicit resident role on house state;
* one central reconciliation path;
* event-driven updates on completion, destruction, dawn, and load;
* small typed helper methods where they reduce duplicated branching.

Avoid:

* per-frame polling;
* global singleton flags duplicating house state;
* identifying the fundamental house only by current list index;
* spawning then immediately deleting a normal builder;
* silently promoting another house after destruction;
* saving runtime agents;
* broad refactors unrelated to this task.

Keep strict GDScript typing. Avoid unsafe `:=` inference for dynamic values, dictionaries, arrays, nullable values, signal returns, and mixed numeric expressions.

## Acceptance criteria

1. Closing the fundamental builder dialog immediately shows the House quickslot tutorial arrow when the UI is available.
2. Opening the House selector moves the arrow to `house_builder`.
3. The tutorial remains one-shot and save-persistent.
4. Completing the first builder house keeps the existing fundamental builder and spawns no normal builder.
5. Completing the second builder house produces exactly one normal builder.
6. Additional builder houses each produce one additional normal builder.
7. Save/load restores the correct fundamental-house ownership and normal builder count.
8. Older saves assign the oldest completed builder house to the fundamental builder.
9. Destroying the fundamental house returns the fundamental builder to its original spot lifecycle.
10. Other surviving builder houses keep their normal builders and are not promoted.
11. Destroying a normal builder house removes only that house’s normal builder.
12. Repeated dawn/load reconciliation does not duplicate builders.
13. No polling, no parallel housing system, and no unrelated architectural expansion.

At the end, report:

* files changed;
* the root cause of the missing arrows;
* where fundamental-house ownership is stored;
* the old-save migration rule;
* how completion, destruction, dawn, and load trigger reconciliation;
* any assumptions that could not be confirmed statically.
