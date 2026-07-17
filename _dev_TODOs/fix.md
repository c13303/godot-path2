# Task: Remove confirmed per-frame and periodic query aberrations

Read `AGENTS.md` and `ARCHITECTURE.md` first.

Do not run Godot, tests, builds, exports, or benchmarks. The user will perform runtime validation.

Follow the project rules:

* strict GDScript typing;
* explicit ownership and responsibilities;
* no speculative large framework;
* no oversized manager expansion;
* preserve existing gameplay behavior;
* native C++ code must remain generic;
* game-specific behavior belongs in GDScript;
* do not hide problems by merely increasing timers;
* do not replace one global scan with many smaller per-agent scans.

## Context

A static performance audit found four confirmed recurring-work aberrations:

1. Full building and tilemap scans every `0.25s`.
2. Duplicate plant-contact queries for every agent every frame.
3. Turrets scanning the entire monster group every frame while ready.
4. Planificator UI being destroyed and rebuilt every `0.15s`.

These are structural inefficiencies, not speculative micro-optimizations.

This task should fix these four systems cleanly in one focused pass.

Do not broadly refactor unrelated gameplay systems.

---

# Part 1 — Remove permanent full building scans

## Current issue

`BuildingRuntimeTickController` periodically invokes a complete building scan, approximately every `0.25s`.

Relevant areas include:

* `scripts/map/building_runtime_tick_controller.gd`
* `scripts/map/building_scan_service.gd`

The scan repeatedly traverses some or all of:

* wall tile cells;
* water cells;
* blocking buildings;
* hard-topology buildings;
* special tile layers;
* physical spawners;
* topology signatures.

It also creates temporary arrays through calls such as `get_used_cells()`.

This occurs even though normal building placement/removal already uses authoritative mutation and invalidation paths.

This periodic full-world scan must not remain active during ordinary gameplay.

## Required behavior

### Startup and reload

A complete scan is still allowed when required during:

* initial level startup;
* scene reload;
* save restoration;
* explicit map/bootstrap initialization.

The startup scan must establish the authoritative initial state.

### Runtime

After initialization, navigation/building changes must be driven by authoritative events:

* building added;
* building removed;
* building updated;
* tile traversal cost changed;
* special tile changed;
* spawner registered/unregistered;
* save restoration batch completed.

Do not perform full scans every few frames as a normal runtime mechanism.

### Debug consistency check

A manual or debug-only consistency scan may remain, but it must:

* be disabled by default;
* not run continuously in production;
* clearly identify itself as a verification scan;
* report mismatches without silently becoming the normal update path.

A very slow fallback timer is acceptable only if an unavoidable legacy mutation path genuinely exists and cannot emit events. Do not add such a fallback without proving the need.

## Telemetry allocation

Do not enumerate entire tile layers or build temporary arrays merely to compose debug strings when the corresponding debug output is disabled.

Expensive telemetry values must be computed only inside the enabled-debug branch.

## Acceptance criteria

During normal gameplay after initialization:

```text
full building scans per second = 0
```

Building placement, destruction, restore, and topology invalidation must still work correctly through event-driven updates.

---

# Part 2 — Eliminate duplicate per-agent plant-contact probes

## Current issue

`AgentCellTracker` already determines each agent’s current floor cell.

Relevant areas include:

* `scripts/map/agent_cell_tracker.gd`
* `scripts/map/agent_tile_interaction_controller.gd`
* `scripts/map/plant_contact_dance_router.gd`
* `scripts/map/building_runtime_tick_controller.gd`

However, stationary agents currently trigger a second path that:

* converts their position to a tile again;
* queries plant/building state again;
* refreshes contact visuals repeatedly.

With hundreds of agents, this creates duplicate per-frame work.

The player also has a separate repeated query path that searches for the player and converts its position again.

## Required design

The cell tracker must remain the authoritative owner of agent cell transitions.

The plant-contact system should consume:

* agent reference or stable ID;
* already-computed current cell;
* previous cell;
* contact start/end events;
* cell-content invalidation events.

Do not recompute an agent’s floor cell in the contact router when the tracker already knows it.

## Contact lifecycle

Implement a clear lifecycle:

```text
contact entered
contact remains active
contact exited
contact invalidated because plant/building state changed
```

The visual animation owner should continue its own animation while contact is active.

It must not require a new “still touching” request every rendered frame merely to keep an animation alive.

## Required triggers

Refresh plant-contact state when:

* an agent enters another cell;
* an agent is registered;
* an agent is removed;
* a plant appears in the occupied cell;
* a plant disappears from the occupied cell;
* a relevant traversable building appears/disappears;
* plant maturity or contact eligibility changes;
* an agent category/state changes in a way that affects contact behavior.

Use existing building/plant invalidation signals when available.

Do not introduce one signal connection per plant-agent pair.

## Player handling

Do not call `get_first_node_in_group("player")` every frame.

Cache the player reference through authoritative registration or startup resolution.

Use the same player cell-transition path as other agents where possible.

If the player is intentionally not part of the ordinary tracker, create one focused player-cell observer. It must emit only on actual cell changes or relevant cell-content invalidations.

## Acceptance criteria

For stationary agents on unchanged cells:

```text
position-to-cell conversions caused by plant contact = 0 per frame
plant-contact eligibility queries = 0 per frame
```

Plant dance/contact visuals must still:

* start correctly;
* remain active;
* stop correctly;
* react when the underlying plant/building changes without requiring agent movement.

---

# Part 3 — Replace turret full-group target scans

## Current issue

Relevant file:

* `scripts/combat/turret_system.gd`

Ready turrets can repeatedly call:

```gdscript
get_tree().get_nodes_in_group(&"monsters")
```

When a ready turret finds no target, it may repeat the complete scan on the next frame.

This creates scaling near:

```text
turret count × monster count × frame rate
```

Directional turrets may additionally perform tile conversions and line-of-sight checks for every monster candidate.

This must be removed.

## Required design

Use the existing spatial agent-cell tracking/query infrastructure.

There is already radius-query behavior used by systems such as Kraken targeting. Reuse the generic spatial query mechanism rather than creating another monster registry.

Target acquisition should work conceptually as:

1. query agents inside the turret’s relevant world radius or cell bounds;
2. filter by valid monster category/state;
3. apply turret-specific directional/cone/line rules;
4. perform line-of-sight checks only for nearby filtered candidates;
5. choose the correct target according to existing gameplay rules.

Do not change target-selection semantics accidentally.

## Target acquisition cadence

A ready turret with no target must not rescan every rendered frame.

Add an explicit target-acquisition interval separate from the firing cooldown.

Requirements:

* configurable;
* small enough to preserve responsive gameplay;
* staggered between turret instances;
* no synchronized scan burst for all turrets;
* no full scan immediately repeated every frame.

Use a deterministic initial offset derived from turret identity or registration order.

Do not introduce random nondeterminism if the game expects deterministic behavior.

## Existing target validation

When a turret already has a target:

* validate that target cheaply;
* retain it while valid according to existing behavior;
* do not reacquire the complete candidate set unless necessary.

Do not preserve dead, removed, exited, or invalid targets.

## Iteration allocations

Inspect per-frame use of:

```gdscript
_turrets.keys()
```

Avoid allocating a key array every frame when a safe direct or stable-list iteration model is available.

Do not mutate dictionaries during unsafe direct iteration.

A dedicated stable active-turret array is acceptable if ownership and removal are handled correctly.

## Acceptance criteria

No turret targeting path may call:

```gdscript
get_nodes_in_group("monsters")
```

during ordinary repeated acquisition.

With no nearby monsters, each turret performs target acquisition only at the configured staggered interval.

Line-of-sight work must only happen for nearby spatial candidates.

---

# Part 4 — Stop rebuilding the Planificator UI every 0.15 seconds

## Current issue

Relevant file:

* `scripts/ui/planificator.gd`

The Planificator currently refreshes approximately every `0.15s`.

Each refresh can:

* recompute the complete display model;
* queue-free current row controls;
* create new containers, icons, and labels;
* reapply theme/layout values;
* recursively traverse the UI tree;
* rebuild identical content even when nothing changed.

This is allocation and scene-tree churn.

## Required design

Create the required row/view controls once.

Update existing controls in place:

* label text;
* icon texture;
* count;
* visibility;
* section title;
* row size if genuinely required;
* current/tonight/tomorrow state.

Do not destroy and recreate the complete interface for ordinary count changes.

## Model change detection

Build a compact immutable display model or signature containing only values that affect the UI.

For example:

* current phase/display section;
* represented agent types;
* counts;
* icon/frame identity;
* title/label keys;
* victory state;
* visibility state.

Compare the new model with the previous model.

If unchanged, return before touching UI nodes.

Do not use an expensive deeply nested dynamic structure if a small typed model or normalized signature is sufficient.

## Event-driven refresh

Connect to authoritative signals where available:

* day/night phase transition;
* playlist/current wave update;
* client count update;
* monster count update;
* progression/night index update;
* victory state;
* language/locale change where relevant.

A slow fallback poll may remain only for legacy data with no signal, but:

* it must only recompute the lightweight model;
* it must not rebuild UI when unchanged;
* it should not run at `0.15s` unless there is a demonstrated requirement.

## Mouse filtering

Set `mouse_filter` correctly when controls are created.

Do not recursively traverse the entire Planificator control hierarchy every refresh.

## Acceptance criteria

When the displayed model remains unchanged:

```text
new Control nodes created = 0
nodes queue_freed = 0
UI property writes = 0
```

The Planificator must continue showing exactly the correct two-section behavior already specified by the project.

Do not alter its gameplay sequencing rules.

---

# Shared instrumentation

Add lightweight debug counters for this pass.

Use an existing debug/performance flag where possible.

Track:

* full building scans;
* agent plant-contact evaluations;
* duplicate position-to-cell conversions avoided;
* turret acquisition scans;
* turret spatial candidates examined;
* turret LOS checks;
* Planificator model evaluations;
* Planificator actual UI updates;
* Planificator node creations after initialization.

The counters must not spam normal logs.

A summarized debug report once every few seconds is acceptable when explicitly enabled.

Do not leave per-agent or per-turret print statements active.

---

# Required investigation before implementation

Before editing, identify and report internally:

1. All callers of the building scan service.
2. Which runtime mutations currently bypass authoritative building events.
3. Existing agent cell-entered/cell-exited signals.
4. Existing plant/building mutation signals.
5. How player cell tracking currently differs from ordinary agent tracking.
6. Existing spatial radius-query APIs in `AgentCellTracker`.
7. Existing turret target-selection rules that must be preserved.
8. All signals/data sources used by the Planificator.
9. Whether the Planificator has a reusable row scene/component already.
10. Any save/load ordering dependency affected by removing fallback scans.

Do not code around an unknown mutation path. Trace it.

---

# Non-goals

Do not include these secondary optimizations unless they are required by the four fixes:

* general character metadata caching;
* ground-drop pooling or spatialization;
* grown-rose animation rewrites;
* Toolbuild event refactor;
* tutorial state-machine refactor;
* FPS debug label refactor;
* unrelated navigation architecture changes;
* unrelated villager interaction changes already handled in another task.

Small directly related cleanup is allowed.

---

# Validation checklist

## Building state

Validate:

* fresh level start;
* save reload;
* place wall;
* remove wall;
* place/remove reservoir where supported;
* place/remove counters;
* place/remove slow traversal buildings;
* special tile initialization;
* spawner registration;
* topology invalidation;
* speed-cell update.

Confirm no runtime full scan is needed for these operations.

## Plant contact

Validate:

* stationary agent on a plant;
* agent enters plant cell;
* agent exits plant cell;
* plant becomes mature under stationary agent;
* plant is harvested/removed under stationary agent;
* traversable contact building added/removed;
* player contact;
* several hundred stationary agents.

Confirm visual behavior remains correct with no per-frame eligibility refresh.

## Turrets

Validate:

* one turret, no monsters;
* many turrets, no monsters;
* one monster enters range;
* monster exits range;
* monster dies while targeted;
* several monsters in range;
* directional turret;
* LOS blocked/unblocked;
* save reload with existing turrets;
* turret removed during acquisition.

Confirm target response remains visually acceptable despite acquisition throttling.

## Planificator

Validate every documented phase:

* start of game;
* night 1;
* day client phase;
* after client phase;
* later nights;
* victory;
* save reload;
* counts changing while visible;
* language change if supported.

Confirm no stale rows or incorrect sequencing.

---

# Final report required

Provide a concise implementation report containing:

* confirmed root causes;
* architecture changes;
* files changed;
* any legacy mutation paths discovered;
* counters before/after where statically or manually measurable;
* remaining fallback polling;
* any behavior intentionally preserved;
* anything requiring user runtime validation.

Do not claim runtime FPS improvement without runtime profiling.

The implementation is complete only when the four recurring-work paths are structurally removed, not merely slowed down with longer timers.
