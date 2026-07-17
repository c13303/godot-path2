# Task: Secondary per-frame performance cleanup

Read `AGENTS.md` and `ARCHITECTURE.md` first.

Do not run Godot, tests, builds, exports, or benchmarks. The user will perform runtime validation.

Follow all project rules:

* strict GDScript typing;
* explicit ownership;
* no speculative framework;
* no large unrelated refactor;
* preserve gameplay and visuals;
* avoid temporary allocations in hot paths;
* do not replace one polling loop with another polling loop;
* do not introduce pooling unless profiling or lifecycle behavior actually justifies it.

## Context

A previous performance pass addressed the highest-priority recurring work:

* permanent building scans;
* duplicate per-agent plant-contact checks;
* turret full-group targeting;
* Planificator UI reconstruction.

This second pass addresses the next confirmed per-frame scaling costs:

1. repeated immutable agent metadata queries;
2. ground-drop list duplication and broad pickup polling;
3. grown-rose animation dictionary allocations and repeated logical-state queries;
4. expensive debug agent counting every frame.

Do not include Toolbuild or tutorial refactors in this pass.

---

# Part 1 — Cache immutable character classification and frame-layout state

## Current issue

Relevant file:

* `scripts/entities/character.gd`

Character update code repeatedly evaluates metadata-driven predicates during frame processing, including combinations of:

* `has_meta("agent_kind")`;
* `get_meta("agent_kind")`;
* `String(...)` conversion;
* monster/client type classification;
* small/big monster classification;
* directional frame-layout metadata;
* sprite-layout mode checks.

Some of these values are immutable for the lifetime of an agent, or only change when the agent definition is explicitly reapplied.

With hundreds of agents, repeated dynamic metadata access and string conversion are unnecessary baseline cost.

## Required design

Introduce explicitly typed cached state for immutable or rarely changing agent properties.

Examples of appropriate cached values:

* agent category/kind;
* is client;
* is monster;
* is big monster;
* directional monster layout enabled;
* directional client layout enabled;
* sprite frame-layout mode;
* any other classification repeatedly derived from immutable metadata.

Use enums or stable typed identifiers where the project already has them.

Do not create a second competing source of truth.

The cache must be refreshed only when the authoritative agent definition/configuration is applied or changed.

## Mutable state

Do not blindly cache metadata that changes during gameplay.

Examples that may remain mutable or should receive explicit setters:

* currently holding an object;
* temporary combat state;
* temporary sprite override;
* temporary interaction state.

Where mutable metadata is currently modified externally, prefer a clear setter that updates both the authoritative value and any derived cached state.

Do not leave external `set_meta()` calls capable of silently making the cache stale.

## Required investigation

Before changing code:

1. Find every write to the relevant metadata keys.
2. Separate immutable initialization metadata from runtime mutable metadata.
3. Identify the authoritative agent setup/configuration method.
4. Find every repeated classification helper called from `_process`, `_physics_process`, animation update, or movement update.
5. Check whether pooled/reused agents can change kind during their lifetime.

If an agent object can be reused as another kind, the cache must be reset during reuse.

## Acceptance criteria

During ordinary per-frame character processing:

* no repeated string conversion is used to rediscover immutable agent kind;
* no repeated `has_meta()` / `get_meta()` sequence is used for immutable frame layout;
* cached values remain correct after save reload and agent reuse;
* sprite animation behavior remains unchanged.

---

# Part 2 — Remove ground-drop active-list duplication and broad pickup polling

## Current issue

Relevant file:

* `scripts/map/ground_drop_manager.gd`

The manager duplicates its active drop collection during frame processing:

```gdscript
var records: Array = _active.duplicate()
```

This allocates and copies the complete active array every frame while any drop exists.

The system also appears to treat all drops similarly even though they have different lifecycle needs:

* newly spawned/flying drops require animation updates;
* settled drops may only need collection eligibility;
* distant stationary drops do not need continuous animation work;
* pickup checks may scan more active records than necessary.

## Required design

Separate the lifecycle conceptually:

```text
animated/flying drops
settled collectible drops
released/inactive drops
```

The exact containers may differ, but the implementation must avoid copying the complete active list every frame.

## Safe iteration

Use a mutation-safe iteration strategy such as:

* reverse indexed iteration;
* deferred removal list;
* swap-remove where ordering does not matter;
* explicit pending-release queue.

Do not mutate a dictionary or array unsafely during direct iteration.

Do not allocate a full duplicate merely to permit removals.

## Processing activation

The manager should disable `_process()` when there are no drops requiring per-frame animation.

Settled collectible drops should not force full-frame animation processing indefinitely.

If settled drops still require periodic visual effects, use the cheapest suitable owner and cadence.

## Pickup detection

Inspect how player collection is currently detected.

Prefer one of these existing mechanisms:

* player cell-change events;
* player movement distance event;
* spatial cell buckets;
* an existing nearby-item radius query;
* physics overlap signals, if already used consistently by the project.

Do not scan every settled collectible every rendered frame.

A small centralized pickup check at a limited cadence may remain if necessary, but it must query only spatially nearby drops.

Do not introduce one timer per drop.

## Spatial indexing

If the project already has a cell-based registry suitable for items, reuse it.

Otherwise, a small manager-owned dictionary keyed by floor cell is acceptable:

```text
cell -> settled drops in/near that cell
```

Only inspect the player’s current cell and nearby collection-radius cells.

Keep flying drops out of settled spatial buckets until landing.

Update buckets when:

* a drop lands;
* a drop is collected;
* a drop is removed;
* a drop is moved by an explicit mechanic.

## Preserve behavior

Do not change:

* drop trajectory;
* collection radius;
* collection timing;
* item/currency reward;
* propulsion animation;
* visual stacking;
* save behavior, where applicable.

## Acceptance criteria

When only stationary distant drops exist:

* no active-list duplication occurs;
* no full active-drop scan occurs every frame;
* per-frame manager processing is disabled unless a visual actually requires it;
* nearby collection still reacts correctly.

---

# Part 3 — Remove grown-rose animation hot-path allocations

## Current issue

Relevant file:

* `scripts/animations/grownup_rose_dance.gd`

The animation path repeatedly calls `.keys()` on dancer dictionaries and may re-query logical plant state while updating visual dancers.

Dictionary `.keys()` creates temporary arrays.

With a large garden and many animated roses, this produces recurring allocations and avoidable logical queries.

## Required design

Make visual dancer membership authoritative through explicit lifecycle events.

Expected lifecycle:

```text
rose becomes eligible for dance
rose dancer registered
rose remains animated
rose becomes ineligible/removed
rose dancer unregistered
```

The animation frame should update only already-registered visual dancers.

It should not repeatedly ask the plant system whether each dancer is still logically mature unless a defensive debug check is enabled.

## Iteration

Avoid `.keys()` in per-frame paths.

Use:

* direct dictionary iteration where no mutation occurs;
* stable arrays for update order;
* deferred removal queues;
* reverse indexed arrays;
* a compact dancer record collection.

Choose the simplest safe structure.

Do not create a complex pooling framework.

## Invalid instances

Handle freed or invalid nodes safely.

Invalid dancer cleanup should not require copying the whole dictionary every frame.

Possible approach:

* detect invalid instance during direct/stable iteration;
* append its identifier/index to a reusable removal buffer;
* remove after iteration.

Avoid creating a fresh removal array every frame if no removals occur.

## Logical state changes

Connect to or consume authoritative events for:

* plant maturity;
* plant harvest;
* plant removal;
* plant destruction;
* save restoration;
* garden rebuild;
* scene reload.

Ensure dancers cannot survive after their plant becomes invalid.

## Processing activation

Disable the animation processor when there are no active dancers.

If different dancer categories use different update cadences, do not overcomplicate this pass unless the existing structure already supports it.

## Preserve visuals

Do not alter:

* dance amplitude;
* dance timing;
* sprite positioning;
* z-indexing;
* random phase behavior;
* maturity appearance.

## Acceptance criteria

In the normal animation frame:

* no dictionary `.keys()` allocation occurs;
* no full logical plant-state validation occurs for every dancer;
* processing is disabled when dancer count is zero;
* plant removal and harvesting remove dancers immediately and safely.

---

# Part 4 — Make debug agent counting non-invasive

## Current issue

Relevant file:

* `scripts/misc/label.gd`

The FPS/debug label appears to call `get_nodes_in_group()` for several agent groups every frame and deduplicate them through a dictionary.

With hundreds of agents, the debug overlay can distort the performance being measured.

## Required design

Prefer an authoritative registered-agent count from the existing agent registry/cell tracker.

If the existing registry already knows:

* total agents;
* count by category;
* active/inactive count;

expose read-only counters rather than scanning the scene tree.

Do not create another agent registry solely for the debug label.

## Refresh cadence

Update diagnostic text at a limited cadence, approximately 2–4 times per second.

FPS display does not need to rebuild its full text every rendered frame.

The label may sample FPS every frame internally if required, but group/category counts and text reconstruction should be throttled.

Use one centralized timer/accumulator in the label, not multiple timers.

## Visibility

When the label is hidden or its debug option is disabled:

* disable processing;
* do not query counts;
* do not build strings.

## Fallback

If authoritative category counts are unavailable, a throttled scene-group scan is acceptable as a temporary fallback.

It must not occur every frame.

Document the fallback in the final report.

## Acceptance criteria

With the debug label enabled:

* no multi-group scene-tree scan occurs every rendered frame;
* displayed counts remain correct enough for diagnostics;
* label processing is disabled when hidden.

---

# Shared allocation audit

While editing these four systems, inspect directly adjacent hot paths for obvious allocations such as:

* `.keys()`;
* `.values()`;
* `.duplicate()`;
* temporary arrays;
* temporary dictionaries;
* repeated `String(...)`;
* repeated `Callable(...)`;
* repeated group scans;
* repeated metadata lookup.

Fix only directly related occurrences.

Do not broaden the task into a whole-project rewrite.

---

# Lightweight debug counters

Where an existing performance/debug system exists, add optional counters for:

* character immutable metadata lookups avoided;
* active ground drops;
* flying drops processed per frame;
* settled drops examined per pickup query;
* ground-drop array copies;
* active rose dancers;
* rose dancer temporary-array allocations;
* debug agent-count refreshes;
* scene-group count scans.

Counters must be disabled or near-zero cost in normal gameplay.

Do not emit per-frame log spam.

---

# Validation checklist

## Characters

Test:

* clients;
* small monsters;
* big monsters;
* villagers;
* player where applicable;
* directional animation;
* held-object animation;
* save reload;
* pooled or reused agents if supported.

Confirm classification and sprite layouts remain correct.

## Ground drops

Test:

* one drop;
* many simultaneous propelled drops;
* drops settling;
* player collecting while moving;
* player standing near a newly landed drop;
* distant settled drops;
* drop release/removal during iteration;
* save reload if drops persist.

Confirm rewards and visuals remain identical.

## Grown roses

Test:

* no grown roses;
* one grown rose;
* large garden;
* rose matures;
* rose harvested;
* rose destroyed;
* plant layout rebuild;
* save reload;
* scene reload.

Confirm dancers are added and removed correctly.

## Debug label

Test:

* label hidden;
* label shown;
* several agent categories;
* hundreds of agents;
* agents spawning and despawning;
* save reload.

Confirm counts update without scene scans every frame.

---

# Non-goals

Do not include:

* Toolbuild event-driven UI conversion;
* tutorial state-machine refactor;
* interaction prompt changes;
* turret targeting changes already handled in the previous pass;
* Planificator changes already handled in the previous pass;
* building scan changes already handled in the previous pass;
* broad object pooling;
* native steering changes;
* unrelated save-system changes.

---

# Final report required

Provide a concise report containing:

* files changed;
* exact recurring allocations or queries removed;
* cache ownership and invalidation rules;
* any remaining polling and why it remains;
* any fallback scene-group scans;
* behavior intentionally preserved;
* runtime validation steps for the user.

Do not claim measured FPS improvements without profiling.

The patch is complete only when these recurring costs are structurally removed rather than merely executed less often.
