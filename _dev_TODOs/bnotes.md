Read `AGENTS.md` first and follow it strictly.

## Task

Implement a generic **agent bubble notification** system (“b-note”) using the existing `bnote.png`, then use it for:

1. **Seed merchant**

   * Show the bubble while the merchant has at least one unclaimed special reward.
   * Clear it only when all active rewards have been successfully collected.
   * A failed item-reward claim, such as inventory full, must leave the bubble visible.

2. **Fundamental Builder**

   * Show the bubble while the fundamental Builder has no completed home assigned to him.
   * A WIP Builder House does not count as a home.
   * Clear the bubble once his completed Builder House is assigned.
   * If that house is destroyed and he becomes homeless again, restore the bubble whenever his agent is visible.

3. **Inventor**

   * Show the bubble while the Inventor has newly published blueprints that the player has not acknowledged.
   * Opening the dialog alone must not clear it.
   * Clear it when the Inventor dialog is subsequently closed in any way: OK, Escape/B, close cross, or dialog replacement.
   * The blueprints do not need to be purchased. Closing the dialog means the player has seen the currently published offers.
   * A later dawn that publishes another blueprint must show the bubble again.

Also change blueprint progression:

* Purchasing a blueprint still unlocks that purchased buildable immediately.
* However, purchasing prerequisites must **not immediately reveal downstream blueprints**.
* Newly prerequisite-eligible blueprint offers are published only at the next real dawn.
* Preserve current initial behavior: Ronce and Fence are the Inventor’s initial available offers.
* Example:

  1. Ronce and Fence are available initially.
  2. The player purchases both.
  3. Kraken must not appear immediately or during the same dialog.
  4. Kraken becomes available at the next real dawn.
  5. The Inventor then receives a new-blueprint bubble.

## First inspect

Before editing, inspect at least:

* `scripts/entities/character.gd`
* `scripts/entities/agent_held_object_visual.gd`
* `scripts/gameState/blueprint_unlock_service.gd`
* `scripts/gameState/progression.gd`
* `scripts/gameState/gameState.gd`
* `scripts/ui/dialog.gd`
* `scripts/ui/merchant_dialog_controller.gd`
* `scripts/ui/inventor_dialog_controller.gd`
* `scripts/map/house_resident_controller.gd`
* `scripts/map/ally_housing_controller.gd`
* `scripts/map/builder_controller.gd`
* `scripts/map/builder_resident_handler.gd`
* `scripts/map/house_manager.gd`
* the relevant `BuildingManager` façade methods
* `mainRun.tscn`

Locate the existing `bnote.png` instead of guessing its path. Do not create, replace, rename, or move the asset. If it genuinely does not exist in the repository, stop and report that precise blocker.

## Required architecture

### 1. Generic agent visual component

Create one small focused visual component under `scripts/entities/`, for example:

```text
agent_bubble_notification_visual.gd
```

It must:

* own the `bnote.png` sprite;
* attach to and follow an agent using local coordinates;
* display above the agent’s head;
* not participate in world-Y depth sorting;
* use only a fixed draw-order mechanism needed to stay over world sprites;
* never recompute a z-index from world position;
* require no `_process`, `_physics_process`, timers, proximity scans, or polling;
* start hidden;
* create only one sprite/component per agent;
* disappear naturally with the owning agent;
* support multiple independent `StringName` reasons so one system cannot accidentally hide a bubble requested by another system.

Provide a narrow API such as:

```gdscript
set_bubble_notification(reason: StringName, active: bool) -> void
```

The bubble is visible when at least one reason is active.

All target villagers currently use the shared `FlowAgent`/character scene. Verify that before relying on it. Since `character.gd` is already in the warning-size range, put the actual implementation in the new component and add only minimal setup/public forwarding methods to `FlowAgent`.

Do not invent bobbing, tweening, text, interaction, sound, or animation. This task only requests the image above the agent.

### 2. Event-driven synchronization

Do not add a global per-frame notification manager.

Update bubbles only at discrete authoritative events:

* resident agent spawned/replaced/removed;
* reward availability changed or a reward was successfully claimed;
* fundamental Builder home assignment changed;
* blueprint publication state changed;
* Inventor dialog closed;
* save state finished loading;
* a real new day began.

If the UI controllers currently lack a clean way to know that an ordinary resident instance changed, add the smallest generic lifecycle signal and façade access needed.

A suitable shape would be:

* `HouseResidentController` emits an agent-changed signal after spawn and when its agent is cleared;
* `BuildingManager` forwards a generic signal keyed by `resident_type`;
* `BuildingManager` exposes a narrow read-only method returning the current ordinary resident agent.

Do not expose or read private dictionaries from UI controllers. Do not make UI controllers depend on `BuildingManager` private state.

### 3. Merchant ownership

`MerchantDialogController` already owns interpretation of the merchant’s active reward rows. Keep the reward notification decision there.

Add a focused synchronization helper that:

* obtains the current merchant agent through the public resident API;
* checks whether `_active_reward_list()` is non-empty;
* sets the generic reason, for example `&"merchant_reward"`.

Synchronize it:

* deferred once after scene startup/load;
* when the merchant resident agent changes;
* after a successful reward claim;
* after a real day advance, once the day number has already advanced.

Prefer the existing `Progression.day_started` signal for the dawn reward refresh because reward selection depends on the incremented day number. Do not refresh from `GameState.dawn_phase_changed` before `Progression.advance_day()` has updated the day.

Do not clear the bubble after only one reward when other reward rows remain.

### 4. Fundamental Builder ownership

Keep the homeless condition in the Builder domain.

Add one small helper in `BuilderController`, or the smallest existing Builder owner, that updates the fundamental Builder agent’s reason, for example:

```gdscript
&"fundamental_builder_no_home"
```

Use the existing authoritative home assignment:

* no assigned completed fundamental Builder House → active;
* completed home assigned → inactive.

Call the helper at every actual state transition:

* fundamental Builder spawn;
* assignment to a completed house;
* house assignment cleared;
* house destruction/evacuation path;
* agent removal or roster reset where relevant.

Do not scan all houses or all agents. Use the existing fundamental Builder ID and house assignment state.

### 5. Blueprint publication model

Keep permanent ownership in `BlueprintUnlockService`.

Separate these concepts explicitly:

* **unlocked**: purchased; the buildable is usable;
* **published**: the Inventor is currently allowed to offer it;
* **seen/acknowledged**: the player has closed the Inventor dialog after it was published.

Do not reinterpret “published” as “affordable.” Lack of money must not affect the new-blueprint notification.

Use explicit definition data for initial offers rather than relying on an accidental prerequisite rule. Ronce and Fence should be initially published. Kraken should not be initially published.

Required behavior:

```text
get_purchasable_blueprint_ids()
```

must return only definitions that are:

* published;
* not already unlocked.

`can_purchase_blueprint()` must also reject unpublished definitions.

After a successful purchase:

* unlock the purchased blueprint immediately;
* do not automatically publish newly eligible descendants;
* do not make Kraken appear in the currently open dialog.

Add a method with a clear name such as:

```gdscript
publish_newly_eligible_blueprints_for_dawn() -> bool
```

It should publish every currently unpublished, unpurchased paid blueprint whose prerequisites are now satisfied. Any newly published IDs become unseen.

Call this exactly once as part of a genuine day transition, preferably inside `Progression.advance_day()` after the day value is incremented and before `day_started` is emitted.

Do not publish from restored phase signals. Loading a save during dawn must not simulate another dawn publication.

Expose narrow progression wrappers such as:

```gdscript
has_unseen_published_blueprints() -> bool
mark_published_blueprints_seen() -> bool
```

Emit a focused progression signal when publication/seen state actually changes so the Inventor controller can update without polling.

### 6. Inventor dialog behavior

`InventorDialogController` remains the owner of the “player has seen the offers” interaction.

* Pass a real close callback to `DialogUI.open_dialog()` instead of the current empty `Callable()`.
* In that close callback, acknowledge all currently published blueprint offers.
* Do this for every close reason supplied by `DialogUI`.
* Then synchronize the Inventor bubble.

Do not acknowledge on dialog open.

Synchronize the Inventor reason, for example `&"inventor_new_blueprints"`:

* deferred after startup/load;
* when the Inventor resident agent changes;
* when blueprint publication/seen state changes;
* after the dialog closes.

Purchasing a row while the dialog is open must not clear the bubble early. It clears when the dialog closes.

## Save compatibility

This state must survive save/load:

* unlocked blueprint IDs;
* published blueprint IDs;
* acknowledged/seen blueprint IDs.

Keep the existing `unlocked_blueprints` section compatible if practical and add a separate compact blueprint-offer state section rather than silently changing the old field’s type.

Increment `SAVE_VERSION`.

Migration from existing saves must preserve behavior:

* Existing unlocked blueprints remain unlocked.
* Blueprints that the old version would already have displayed should be treated as published.
* Treat those migrated published offers as already seen, so loading an old save does not create a misleading “new blueprint” notification.
* Future prerequisite completion after migration must still use the new next-dawn rule.

Fresh games should start with Ronce and Fence published and unseen, allowing the Inventor bubble to appear once the Inventor exists.

Validate the new save section defensively, ignore unknown IDs with a warning, and never grant an invalid blueprint from malformed save data.

Do not let restored dawn signals publish offers a second time.

## Safety and performance constraints

* Do not run Godot, tests, compilation, export, or build commands.
* Do not make broad unrelated refactors.
* Do not add logic to per-frame agent loops.
* Do not scan scene groups every frame.
* Do not add new notification state to `GameState`; blueprint publication belongs to `BlueprintUnlockService`.
* Do not put reward-query logic into the generic bubble component.
* Do not duplicate blueprint state in the Inventor controller.
* Do not add large feature logic to `BuildingManager`; it may only gain small façade/signal wiring.
* Keep strict GDScript typing. Avoid unsafe `:=` inference as specified by `AGENTS.md`.
* Preserve all existing merchant purchases, reward claims, resident movement, dialogs, house behavior, save behavior, and build availability outside the requested changes.
* Preserve the existing merchant dialog’s signature refresh behavior.
* Avoid stale references when a villager goes home, evacuates, is destroyed, or is reconstructed after load.

## Manual acceptance checklist

Report that the implementation is ready for these manual tests:

1. Fresh game: Ronce and Fence are available; Kraken is not.
2. Inventor appears with unseen initial offers: bubble visible.
3. Open Inventor dialog: bubble remains visible.
4. Close using OK: bubble clears.
5. Repeat using Escape/B, close cross, and replacement: each close acknowledges offers.
6. Buy only Ronce: Kraken remains absent.
7. Buy Fence after Ronce: Kraken remains absent in the same dialog and for the rest of the day.
8. Next real dawn: Kraken appears and Inventor bubble returns.
9. Save after buying prerequisites but before dawn; reload: Kraken remains unpublished.
10. Save after Kraken publication; reload: publication and seen/unseen state are preserved.
11. Loading a save made during dawn does not perform a second publication.
12. Merchant with multiple rewards: bubble remains until every reward succeeds.
13. Failed item reward due to full inventory: bubble remains.
14. Fundamental Builder before completed home: bubble visible.
15. While his house is WIP: bubble remains.
16. When the house completes and is assigned: bubble clears.
17. Destroy that home: bubble returns when the homeless Builder is visible.
18. Villagers leaving/respawning/loading do not leave orphan bubbles or stale references.
19. Two simultaneous bubble reasons on a test agent do not interfere: clearing one keeps the other visible.

## Final report

Return:

* concise summary of the implementation;
* files created and modified;
* exact save-version/migration changes;
* event sources used for each notification;
* confirmation that no polling/per-frame notification logic was introduced;
* any architecture concern found during the task;
* manual tests the user should run.

Do not claim that Godot or tests were run.
