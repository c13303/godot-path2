# Task: Fix villager idle FPS hitches, interaction proximity polling, and redundant reload navigation work

Read `AGENTS.md` and `ARCHITECTURE.md` first. Follow all project rules, especially:

* strict typing;
* no oversized controllers;
* one responsibility per class;
* reuse existing generic systems where appropriate;
* do not introduce speculative abstractions;
* native C++ systems must remain generic;
* game-specific villager logic belongs in GDScript;
* preserve current gameplay behavior unless this task explicitly changes it.

## Context

A small recurring FPS hitch appears when more than one villager is idle near their house.

Static investigation found several likely causes.

### Confirmed issue 1: per-villager, per-frame player proximity polling

Ordinary villagers currently check player proximity every frame through the housing/resident interaction path.

The test performs work such as:

* finding the player through the scene tree/group;
* retrieving the floor layer;
* converting player position to a tile;
* converting villager position to a tile;
* computing tile distance.

The interaction prompt system independently repeats similar `can_interact()` / proximity checks every frame.

The fundamental builder has a separate version of comparable logic.

This means proximity work scales with the number of villagers and is duplicated between villager controllers and prompt controllers.

### Confirmed issue 2: multiple independently processing interaction prompts

Several villager-specific dialog controllers own their own continuously processing `InteractionPrompt`.

Each prompt repeatedly asks whether its corresponding villager can currently interact.

This should not remain one permanent polling loop per villager.

### Suspected main hitch: synchronized idle-home correction and A* repathing

Ordinary residents periodically check whether they are too far from their idle/home position, approximately every `0.5s`.

When considered displaced, they can call the return-home/repath logic and request an A* path.

There appears to be a tolerance mismatch:

* resident home correction considers an agent displaced at roughly `tile_size * 0.45`;
* native steering considers a destination reached at roughly `tile_size * 0.50`.

This creates a range where native steering may consider the target reached while the resident controller shortly afterward considers the villager displaced.

Idle agents can also still be moved slightly by local avoidance/separation. With several nearby villagers, this may produce a loop:

1. destination considered reached;
2. idle separation shifts villagers slightly;
3. synchronized home checks run;
4. several villagers request A* return paths;
5. they stop again;
6. the cycle repeats.

This is a strong static diagnosis, but it must be confirmed with lightweight instrumentation before blindly changing behavior.

### Reload logs also show redundant work

Observed after starting and then reloading a save:

```text
[NAV_INVALIDATION] impact=HARD_TOPOLOGY source=building_removed:reservoir
[NAV_INVALIDATION] impact=HARD_TOPOLOGY source=building_added:reservoir
...
plant layout rebuild completed in 645ms
...
plant layout rebuild completed in 620ms
```

The invalidation messages themselves are diagnostic, not errors.

However:

* the reservoir is redundantly removed and immediately re-added during registration/load;
* restored buildings emit many individual navigation changes;
* the same plant layout appears to rebuild twice after one load.

These should be cleaned up where the fix is local and safe.

---

# Main objectives

## 1. Replace villager-owned proximity polling with a single player-centric interaction coordinator

Create a clean, focused interaction-proximity owner.

Do not let each villager search for the player or convert both positions every frame.

The player side, or a dedicated coordinator owned near the player, must determine the currently interactable villager.

A suitable structure could be something like:

```text
VillagerInteractionCoordinator
```

The exact name and ownership may differ after inspecting the architecture.

Responsibilities:

* maintain a registry of currently valid villager interactables;
* track the current selected interaction target;
* recompute the candidate only when relevant state changes;
* expose the selected candidate to the interaction prompt and input system;
* notify villagers when they become or cease to be the selected proximity target.

Do not make every villager subscribe to `_process()` just to measure player distance.

### Required recompute events

Player tile change is the primary trigger, but not the only trigger.

Recompute when any of the following happens:

* player enters a different tile;
* a registered villager enters a different tile;
* a villager is spawned;
* a villager is removed;
* a villager is hidden or shown;
* a villager starts or ends an errand;
* a villager enters or leaves a dialog/interactable state;
* a villager arrives at or leaves its home idle position;
* a villager is pushed into or out of interaction range while the player remains stationary;
* a villager becomes otherwise eligible or ineligible for interaction.

Use existing tile/cell transition events if the project already exposes them.

Do not introduce a new global per-frame world-position scan when an event-based hook already exists.

A very small throttled fallback is acceptable only if there is genuinely no event for sub-tile displacement, but it must be centralized, not one timer per villager.

### Candidate selection

Do not select the first arbitrary node returned by a group or dictionary.

On each recompute:

1. filter unavailable candidates;
2. filter candidates outside interaction range;
3. choose the nearest candidate;
4. use a deterministic tie-breaker for equal distance.

Possible stable tie-breakers:

* persistent resident ID;
* stable registration order;
* instance ID as a last resort.

An early exit is valid only for a perfect-distance candidate or another guaranteed best possible result.

With the current small villager count, scanning all registered interactables on an event is acceptable. Do not add a spatial tree unless profiling proves it necessary.

## 2. Use one shared interaction prompt for the selected target

Replace permanent villager-specific range polling by a single prompt representing the coordinator’s selected target.

The prompt may continue processing while visible if needed to follow the target’s screen position, but it must not:

* search all villagers;
* recompute interaction range;
* independently call every villager’s `can_interact()` each frame.

The coordinator should push target changes into the prompt.

Expected behavior:

* no selected target: prompt hidden and processing disabled;
* selected target: prompt follows that villager;
* selected target changes: prompt updates cleanly;
* dialog begins: prompt hides appropriately;
* target becomes invalid: prompt clears immediately.

Dialog controllers may remain villager-specific, but proximity selection and prompt visibility must no longer be duplicated across them.

## 3. Centralize interaction input and hold behavior

Currently each villager may independently process proximity/hold behavior.

Change this so only the selected interaction candidate can receive the player’s interaction hold/input.

There must not be several villagers simultaneously entering an interaction hold merely because they are all near the player.

When the player presses interact:

* use the coordinator’s cached selected target;
* perform one final lightweight validity check;
* open the correct dialog or interaction;
* avoid a new scene-wide search.

Preserve current input semantics, including hold duration and cancellation behavior, unless the existing behavior is clearly inconsistent between villager types.

The fundamental builder and normal house villagers must use the same selection/proximity mechanism.

Do not retain a separate fundamental-builder player search path.

## 4. Instrument and fix repeated idle-home repathing

Before modifying the home-return behavior, add debug-only instrumentation sufficient to prove what is happening.

Track per resident:

* number of idle-home probes;
* number of return-home requests;
* number of actual A* repaths caused by home correction;
* distance from home when the repath was requested;
* whether the resident already had an active path;
* whether the resident was being pushed or displaced;
* timestamps or frame numbers sufficient to identify repeated cycles.

The instrumentation must be:

* behind an existing debug flag, development build guard, or explicit local constant;
* silent in normal production play;
* easy to remove or retain safely.

Then fix the actual issue.

### Required home-return invariants

A villager must not request a new return-home path when:

* it is already returning to the same home target;
* it has an active valid path to that target;
* it is within an arrival tolerance consistent with native steering;
* only minor avoidance displacement has occurred;
* the last correction was requested too recently and no meaningful displacement occurred.

Use the same positional reference for both arrival and correction logic.

For example, do not compare:

* sprite/global origin in one system;
* navigation foot position in another.

Inspect how agent tile/foot positions are represented and use the canonical navigation position.

### Fix tolerance mismatch

Align home correction with native arrival semantics.

Do not simply change `0.45` to a guessed larger number without understanding path endpoint dispersal and the native destination-reached threshold.

Define explicit named values or derive the correction threshold from the native/public navigation arrival radius.

A valid solution should include hysteresis:

* one threshold for considering home reached;
* a meaningfully larger threshold for considering a settled resident displaced enough to require a repath.

For example conceptually:

```text
arrival radius < displacement/repath radius
```

This prevents oscillation around one boundary.

The exact values must be selected based on current tile size, path endpoint dispersion, and existing steering behavior.

### Avoid synchronized periodic spikes

If periodic home validation still remains necessary:

* do not let all residents run it on the same frame;
* prefer event-driven displacement detection;
* otherwise stagger checks deterministically per resident.

However, staggering is not a substitute for eliminating redundant A* requests.

### Preserve pushing behavior

Player push/control suppression must continue working.

A pushed villager should:

* temporarily accept displacement;
* not fight the push every frame;
* eventually return home when genuinely displaced and no longer under push/control suppression.

Do not make residents immutable or immediately snap them home.

## 5. Clean redundant navigation invalidations during save reload

Inspect:

* building registration;
* building replacement;
* save restore;
* level-loader reservoir registration;
* navigation invalidation aggregation.

The following sequence should not be emitted when an identical reservoir registration is restored:

```text
building_removed:reservoir
building_added:reservoir
```

Make building registration idempotent where appropriate.

If an existing building has the same:

* type;
* occupied cells;
* relevant topology flags;
* traversal-speed data;
* runtime identity or authoritative restore identity;

then registration should not remove and re-add it merely to refresh the same data.

If data actually changed, emit only the minimum correct invalidation.

### Restore transaction

Where feasible, restore buildings inside a scoped batch/transaction:

1. begin restore batch;
2. register or update buildings without immediately rebuilding navigation;
3. collect changed topology cells;
4. collect changed speed cells;
5. complete restore;
6. emit one consolidated hard-topology invalidation if required;
7. emit one batched speed update if required.

Do not suppress legitimate changes.

The following remain correct conceptually:

```text
[NAV_SPEED] ... turret_epine ... new=0.50
[NAV_INVALIDATION] ... rose_shop_counter
[NAV_INVALIDATION] ... reservoir
```

The task is to avoid redundant duplicate emissions and rebuilds, not to hide logs.

## 6. Find and eliminate the duplicate plant-layout rebuild after reload

One reload currently appears to produce two full plant-layout rebuilds:

```text
plant layout rebuild completed in 645ms
plant layout rebuild completed in 620ms
```

Investigate all scheduling paths.

Add debug context to layout rebuild scheduling:

* dirty reason;
* requested generation;
* currently running generation;
* whether the request was merged;
* whether another generation was queued;
* changed garden IDs;
* whether the request came from save restoration, building scan, navigation invalidation, or delayed startup.

The scheduler should coalesce equivalent requests.

Expected behavior:

* several dirty events during one restore/startup transaction should produce one final rebuild;
* a request received while a rebuild is running should only queue another generation if the underlying relevant data changed after the active generation snapshot;
* identical requests must not cause a second full rebuild.

Do not merely suppress the second log line. Ensure the second computation is genuinely eliminated.

## 7. Preserve valid invalidation logging

Do not remove the `[NAV_INVALIDATION]` and `[NAV_SPEED]` diagnostics entirely.

They are useful.

Improve them if necessary so logs distinguish:

* queued invalidation;
* merged invalidation;
* executed rebuild;
* ignored no-op registration;
* batched restore invalidation.

Avoid production spam if the project has an existing navigation debug flag.

---

# Architecture requirements

Prefer a small set of explicit components rather than growing existing large controllers.

Likely responsibilities:

### Interaction coordinator

Owns:

* interactable registry;
* selected target;
* event-driven candidate refresh;
* interaction input routing;
* selected-target signal.

### Interactable villager adapter/interface

Each villager exposes only what the coordinator needs, such as:

* stable ID;
* navigation position or current cell;
* interaction radius;
* eligibility;
* display anchor;
* interaction callback.

Use the project’s existing conventions rather than forcing a formal interface if GDScript architecture already uses components or signals.

### Shared prompt presenter

Owns:

* current visual target;
* visibility;
* screen position;
* prompt animation.

Does not own range selection.

### Resident home-settling logic

Owns:

* settled/home state;
* displacement hysteresis;
* return request deduplication;
* push/control-suppression awareness.

Do not mix save restoration batching into the interaction coordinator.

---

# Performance constraints

After the fix:

* ordinary idle villagers must not run player-proximity calculations every frame;
* fundamental builder must not run a separate player lookup every frame;
* hidden villager prompts must not process;
* candidate selection must not perform scene-tree group searches repeatedly;
* no per-villager timer should poll the player position;
* no repeated home A* request should occur while the villager is already returning;
* save reload should not perform two identical plant-layout rebuilds;
* identical building re-registration should not emit remove/add topology invalidations.

Avoid allocations in recurring hot paths:

* do not create temporary arrays every frame;
* reuse registry structures where sensible;
* avoid repeated `Callable`, dictionary, or string construction in movement/process paths;
* signals/events must not produce unbounded connection duplication after reload.

Ensure coordinators unregister cleanly on scene reload.

---

# Required investigation steps

Before coding:

1. Trace all ordinary villager interaction paths.
2. Trace the fundamental builder interaction path.
3. Find every `InteractionPrompt` instance and every `can_interact()` call.
4. Find every per-frame or periodic player proximity calculation.
5. Trace agent tile-change events already available.
6. Trace villager push/control-suppression state.
7. Trace `_request_idle_home_return()` and all A* calls it can cause.
8. Compare GDScript home-arrival thresholds with native steering arrival thresholds.
9. Trace building restoration and reservoir registration.
10. Trace every plant-layout rebuild scheduling source.

Document the findings briefly in the final report.

Do not assume the initial diagnosis is complete. If profiling reveals another major hotspot associated with idle residents, fix it when it is directly related and can be addressed without broad unrelated refactoring.

---

# Validation

## Interaction

Test with:

* one ordinary villager;
* several ordinary villagers;
* fundamental builder plus ordinary villagers;
* multiple villagers standing inside interaction radius;
* equal-distance villagers;
* player stationary while a villager walks into range;
* player stationary while a villager is pushed out of range;
* villager starts an errand while selected;
* selected villager enters its house;
* selected villager is removed;
* save reload with player already near a villager.

Confirm:

* nearest eligible villager is selected deterministically;
* only one prompt is visible;
* only one villager reacts to interaction hold;
* prompt updates without needing the player to move again;
* no stale target survives removal/reload;
* all dialogs still open correctly.

## Idle-home behavior

Test:

* one idle villager;
* two villagers at nearby homes;
* several villagers clustered near adjacent houses;
* player repeatedly pushes a villager;
* villager returns after push suppression ends;
* avoidance shifts villagers slightly;
* villager is genuinely displaced by more than one tile;
* house destroyed while villager is idle;
* daytime/nighttime transitions;
* save during displaced/returning state, where supported.

Confirm:

* no repeated A* repath loop;
* no oscillation around the home point;
* minor avoidance movement does not cause constant repathing;
* genuinely displaced villagers still return;
* villagers remain pushable;
* no new stuck state is introduced.

## Reload/navigation

Start a game, save, and reload.

Confirm:

* no duplicate coordinator or signal connections;
* identical reservoir registration does not emit remove then add;
* topology rebuild remains correct;
* thorn traversal speed is restored correctly;
* counters and reservoir remain navigationally correct;
* only one plant-layout rebuild occurs for the restore/startup batch;
* flow-field recomputation count remains correct;
* no stale gardens or entry points remain.

## Profiling

Use the project’s normal profiler or lightweight counters.

Compare before/after:

* per-frame script time with 1, 2, 5, and 10 idle villagers;
* number of proximity evaluations per second;
* number of `get_first_node_in_group("player")` calls from villager interaction code;
* number of idle-home A* requests per minute;
* number of plant-layout generations during reload;
* number of hard invalidations during restore.

Expected:

```text
idle per-villager proximity evaluations per second = 0
```

Candidate scans should occur only on relevant events.

While nobody moves or changes interaction state, interaction candidate recomputations should remain at zero.

---

# Acceptance criteria

The task is complete only when all of the following are true:

1. Villagers no longer poll player proximity independently each frame.
2. Fundamental builder uses the same centralized proximity selection.
3. There is only one active interaction prompt for the selected villager.
4. Candidate selection is event-driven and deterministic.
5. A stationary player correctly detects a villager that moves into range.
6. Only the selected villager receives interaction hold/input.
7. Idle villagers do not repeatedly request A* paths near their settled position.
8. Home correction uses consistent position semantics and hysteresis.
9. Player pushing still works.
10. Identical reservoir restore does not generate redundant remove/add invalidations.
11. Save restoration batches navigation mutations where safe.
12. One reload does not execute two equivalent plant-layout rebuilds.
13. Navigation diagnostics remain available and meaningful.
14. No duplicate signal connections or leaked node references occur after repeated reloads.
15. A concise final report states:

    * root causes found;
    * files changed;
    * architecture introduced;
    * measured before/after counters;
    * remaining uncertainty or intentionally deferred work.

Do not stop after merely reducing the polling frequency. The ownership must be corrected so interaction proximity is centralized and event-driven.
