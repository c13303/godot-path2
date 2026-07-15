Implement the fundamental Builder introduction cutscene, dialog, and first Builder House tutorial.

Read and follow `AGENTS.md`. Do not run Godot, tests, compilation, export, or build commands.

## Relevant existing systems

Inspect and reuse:

* `scripts/map/builder_controller.gd`
* `scripts/map/ally_housing_controller.gd`
* `scripts/map/spawner_reveal_cutscene_controller.gd`
* `scripts/map/spawner_reveal_phase_controller.gd`
* `scripts/map/agent_save_service.gd`
* `scripts/map/house_manager.gd`
* `scripts/map/building_manager.gd`
* `scripts/ui/dialog.gd`
* `scripts/ui/merchant_dialog_controller.gd`
* `scripts/ui/merchant_prompt.gd`
* `scripts/controls/player_controller.gd`
* `scripts/misc/tutorial.gd`
* `scripts/shop/toolbuild.gd`
* `scripts/ui/game_ui.gd`
* `scripts/map/agent_definition_service.gd`
* `mainRun.tscn`
* the project’s FR/EN translation files

Do not put the feature logic directly into `BuildingManager`. Keep it as wiring and narrow façade methods.

Use one focused onboarding owner for the fundamental Builder’s one-shot progression. Do not create a general interaction framework or perform an unrelated merchant refactor.

## Persistent onboarding state

Persist exactly the progression needed for this feature:

```gdscript
intro_cutscene_played: bool
builder_house_tutorial_state: int
```

Tutorial states:

```gdscript
NOT_STARTED
ACTIVE
COMPLETED
```

Fresh-game defaults:

```gdscript
intro_cutscene_played = false
builder_house_tutorial_state = NOT_STARTED
```

Transitions:

* The introduction cutscene successfully starts:

  * `intro_cutscene_played = true`
* The fundamental Builder dialog closes while the tutorial is `NOT_STARTED`:

  * tutorial becomes `ACTIVE`
* The player successfully places their first WIP `house_builder`:

  * tutorial becomes `COMPLETED`

Save/load requirements:

* Include both values in the normal run save data, near the existing `spawner_reveal` one-shot state in `AgentSaveService`.
* Loading restores the exact state.
* A played cutscene must not replay after save/load.
* A completed Builder House tutorial must not reactivate after save/load.
* If saved while the tutorial is `ACTIVE`, it must still be active after loading.
* Do not force an autosave.
* Do not add speculative migration logic or a save-version change unless the current save validator actually requires it.

Consume the cutscene only after the shared cutscene controller accepts and starts it. If starting fails, leave it pending.

## Fundamental Builder camera introduction

The trigger applies only to the fundamental Builder, not house-owned Builders.

During the existing Builder runtime processing, detect when:

* the Builder is `_fundamental_builder_id`;
* its state is `STATE_ENTERING`;
* `intro_cutscene_played` is false;
* the live Builder is within 3 grid tiles of the authored `fundamental_builder_spot`.

Reuse the project’s existing grid-distance convention for “within 3 tiles.” Do not add path-length computation or a separate watcher. If the codebase has no established convention, report that ambiguity instead of silently inventing another system.

Emit or forward a one-shot request containing the live fundamental Builder node. Keep the check inside the existing active Builder processing; do not scan scene groups every frame.

## Reuse the existing camera cutscene

Reuse `SpawnerRevealCutsceneController`. Do not implement another camera lock, skip prompt, progress circle, or return-to-player system.

Generalize it narrowly:

* Add a public `is_active() -> bool`.
* Allow a cutscene item to target either:

  * the existing fixed `world_position`; or
  * an optional live `target_node: Node2D`.
* For `target_node`, resolve its valid current world position while scrolling so the moving Builder remains in view.
* Preserve all existing spawner-reveal behavior.

Use a distinct context:

```gdscript
&"fundamental_builder_intro"
```

This context has no spawning or reveal gameplay action. It only focuses the Builder.

If another reveal cutscene is currently active, do not call `begin()` because the current implementation treats that as a skip request. Keep the Builder introduction pending and start it once the shared controller is idle.

The introduction:

1. Locks gameplay input through the existing cutscene system.
2. Scrolls to the live fundamental Builder.
3. Uses the existing focus pause and skip prompt.
4. Returns to the player.
5. Restores normal camera following and input.
6. Does not pause, teleport, repath, or otherwise modify the Builder.

## Faster generic skip return

Improve skipped returns for all cutscenes using this shared controller.

Keep the normal return duration unchanged:

```gdscript
NORMAL_RETURN_SECONDS = 1.0
```

Use:

```gdscript
SKIPPED_RETURN_SECONDS = 0.3
```

When the skip progress circle completes:

* interrupt the current camera scroll or focus pause immediately;
* preserve the existing reveal/spawn release behavior for monster and client cutscenes;
* begin returning from the camera’s current position immediately;
* complete that return in `0.3s`;
* do not add another delay or focus pause;
* keep gameplay input locked until the return finishes.

Normal, non-skipped completion still returns over `1.0s`.

## Fundamental Builder interaction and dialog

Give the fundamental Builder an interaction equivalent to the seed merchant:

* keyboard: `E`
* gamepad: the same interaction button used by the merchant
* show the existing `E-Y.png` interaction glyph above the Builder
* use the same tile interaction radius as `SeedMerchantController.INTERACT_RADIUS_TILES`
* show the prompt only after the fundamental Builder has reached its idle spot
* do not show or allow it at night
* do not show it while another dialog is open or during a camera cutscene

Add narrow Builder queries through `BuilderController` and thin `BuildingManager` wrappers as needed:

* fundamental Builder is active
* fundamental Builder is idle at its spot
* player is within interaction range
* live fundamental Builder world position
* live fundamental Builder node, when needed by the cutscene

Do not expose the BuilderController’s private dictionaries.

Create a small fundamental Builder dialog adapter modeled on `MerchantDialogController`, using the existing `DialogUI`.

Use the first frame of:

```text
res://assets/sprites/legval/fundamental_builder.png
```

as the portrait, following the merchant portrait approach.

For the displayed speaker name, reuse an existing fundamental Builder/Builder translation if one exists. Do not invent a new character name. If no display name exists, report that single missing content decision.

Dialog translations:

French:

```text
Salut ! Je peux construire des maisons avec toi, mais tu dois d'abord m'aider à construire la mienne.
```

English:

```text
Hi! I can help you build houses, but first you need to help me build mine.
```

Single button:

```text
OK
```

The OK button closes the dialog. Standard generic dialog closing controls must continue to work.

Whenever this dialog closes, if the Builder House tutorial state is still `NOT_STARTED`, change it to `ACTIVE`.

The dialog itself remains interactable while the fundamental Builder is present. Do not add a separate persisted “dialog acknowledged” one-shot.

## Special Builder House tutorial

Add a translation key such as:

```text
tutorial.build_builder_house
```

French:

```text
Construisez une maison de bâtisseur
```

English:

```text
Build a Builder House
```

When the tutorial state is `ACTIVE`:

* display this as the active tutorial instruction;
* keep it active until the first WIP `house_builder` is successfully placed;
* do not infer it from the day number or general economy conditions;
* preserve existing cutscene suppression and alert behavior.

Arrow behavior must match the existing multi-stage build tutorials:

1. While the house menu is closed, point at the `buildhouse` quickslot.
2. Once the `buildhouse` menu is open, point at the visible `house_builder` item icon.
3. If the relevant target is temporarily unavailable or hidden, hide the arrow cleanly rather than pointing at an invalid rectangle.

Reuse:

* `GameUI.get_quick_slot_global_rect_for_kind("buildhouse")`
* `Toolbuild.get_visible_build_item_global_rect("house_builder")`
* the existing `TutorialArrow` behavior

Do not duplicate arrow animation code.

## Tutorial completion event

The tutorial is completed only after a successful player placement of a WIP Builder House:

```text
item_id == "house_builder"
status == WIP
```

Do not consume it when:

* the item is selected;
* the build preview appears;
* payment is attempted;
* placement validation fails;
* a different house type is placed;
* the house finishes construction;
* a house is restored from save.

Add a narrow success signal at the authoritative placement owner, preferably `HouseManager.build_player_house()` after `create_house()` succeeds. For example, emit a player-house-placement event containing the normalized item ID and status.

The onboarding owner listens for that event and changes `ACTIVE` to `COMPLETED` for `house_builder`.

Do not poll the world every frame to detect the house.

## Acceptance checks

Manually verify through code inspection:

1. Fresh game: fundamental Builder approaches its spot.
2. At 3 tiles, camera introduction plays exactly once.
3. Holding skip completes the circle and immediately starts a `0.3s` return.
4. Other monster/client reveal cutscenes retain their normal behavior.
5. The Builder cutscene never interrupts an already active reveal cutscene.
6. After reaching its spot, the Builder displays the E/gamepad tooltip.
7. Interaction opens the generic dialog with the correct portrait and localized text.
8. Closing it activates “Construisez une maison de bâtisseur”.
9. Arrow points first to `buildhouse`, then to `house_builder`.
10. Failed placement does not complete the tutorial.
11. Successful WIP `house_builder` placement completes it permanently.
12. Save/load after the introduction does not replay the cutscene.
13. Save/load while the tutorial is active restores it as active.
14. Save/load after placement does not reactivate the tutorial.
15. No per-frame scene scan, duplicate skip system, or new feature logic is added to `BuildingManager`.

At the end, report:

* files changed;
* owner of the onboarding state;
* exact save fields added;
* exact event used to complete the tutorial;
* any remaining ambiguity, without guessing.

builder name = (FR/ENGLISH) 
"Bâtisseur Nomade" (make the EN trans)