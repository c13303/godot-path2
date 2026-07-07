# AGENTS.md

For every task: do not guess. Ask if unsure.

Prefer simple, readable, production-oriented code.

The goal is not maximum abstraction. The goal is code that is easy to understand, easy to modify, hard to break, and not likely to grow into huge tangled files.

## Test / build policy

Do not run Godot, tests, compilation, export, or build commands.

The user runs tests manually.

Only run Godot if the user explicitly authorizes it in the current conversation.

Godot executable, only if authorized:

```txt
C:\GAMETOOLS\godot
```

## GDScript typing

Godot/GDScript strict typing is enabled.

When editing GDScript, avoid `:=` inference for:

* numeric expressions
* Dictionary / Array values
* signal or `call()` returns
* mixed `int` / `float` math
* nullable or dynamic values

Prefer explicit local types:

```gdscript
var count: int = 0
var pos: Vector2i = Vector2i.ZERO
var speed: float = 0.0
var data: Dictionary = {}
```

Cast deliberately when needed.

Do not rely on implicit Variant behavior when the value type matters.

## Production-quality objective

Every change should move the code toward production quality.

Production quality means:

* clear ownership of state
* small focused files
* explicit responsibilities
* predictable control flow
* limited coupling
* readable names
* no hidden side effects
* no dead compatibility layers unless needed
* no speculative architecture
* no giant files
* no god objects
* no “temporary” hacks without warning

If a requested feature or refactor starts making the code messy, stop and report it before continuing.

Report clearly when:

* a file is becoming too large
* a method is doing too many things
* a manager/controller is becoming a god object
* logic is being duplicated
* state ownership is unclear
* services are calling too deeply into each other
* the clean solution would require a larger refactor

## Simplicity rule

Do the simplest thing that keeps the code maintainable.

Do not over-engineer.

Avoid:

* generic frameworks
* speculative interfaces
* abstract base classes without immediate need
* service locators
* unnecessary event buses
* premature plugin-style architecture
* splitting tiny logic into many tiny files
* moving code just to move code

Prefer:

* one focused service/controller per real responsibility
* clear method names
* direct readable code
* small helper methods when they reduce repetition
* explicit data flow
* local refactors that make the current task safer

If there are two options, prefer the one a future coding agent can understand quickly.

## File size and responsibility limits

Avoid creating or growing huge files.

Guidelines:

```txt
0-300 lines: good
300-600 lines: acceptable if cohesive
600-900 lines: warning zone
900+ lines: justify before adding more
1000+ lines: do not grow; split by responsibility
```

If a file is already large, do not add new responsibility to it unless there is no safer option.

If a method grows beyond roughly 80-120 lines, check whether it should be split.

If a manager is mostly coordinating many unrelated systems, move new behavior into a focused controller/service instead of adding more logic to the manager.

## Anti-noodle architecture rules

Do not create code where everything knows about everything.

Avoid these patterns:

```gdscript
_manager._some_private_method()
_manager._some_private_dictionary
_manager._some_private_flag
```

from extracted services unless there is no safe alternative.

Prefer:

* explicit public wrappers with intention-revealing names
* direct calls to the owning service
* small query methods for read-only access
* keeping state mutations inside the owner of that state

Bad:

```gdscript
_manager._gardens[garden_id]
_manager._rebuild_everything()
_manager._some_random_private_flag = true
```

Better:

```gdscript
_manager.get_garden_cells(garden_id)
_manager.request_navigation_rebuild()
_manager.mark_navigation_topology_dirty()
```

If private coupling is kept, mention it in the final report.

## State ownership

Every important piece of state should have one clear owner.

Before adding or moving state, identify the owner.

Examples:

* navigation invalidation state should live in an invalidation controller
* garden topology state should live in a garden topology service
* spawning orchestration should live in a spawn service
* runtime frame orchestration should live in a runtime tick controller
* UI selection state should stay with UI/state controllers
* save/load compatibility can stay as façade wrappers if needed

Do not duplicate state across manager and service unless required for compatibility.

Do not move ownership of major state during a feature task unless the task is specifically a refactor.

## Manager / façade rule

Large manager files should be treated as façades/coordinators, not dumping grounds.

A manager may contain:

* Godot lifecycle callbacks
* scene wiring
* exported node references
* setup of services/controllers
* compatibility wrappers
* small orchestration entry points

A manager should not contain:

* large gameplay algorithms
* long frame loops
* spawning internals
* pathfinding internals
* save format transformations mixed with gameplay
* debug systems mixed with gameplay
* unrelated helper clusters
* new feature logic that belongs to a domain service

When adding a feature, first look for the correct existing service/controller.

If no owner exists, create a focused one.

Do not create a new service if the logic clearly belongs to an existing cohesive owner.

## Refactor policy

Refactors must be behavior-preserving unless the user explicitly asks for behavior changes.

Before refactoring:

1. Identify the current owner of the logic.
2. Identify who calls it.
3. Search for dynamic usage: `call()`, `Callable`, signals, scene references, string method names.
4. Preserve wrappers when unsure.
5. Move one coherent responsibility at a time.

Do not combine risky refactors with feature work unless necessary.

Do not perform broad cleanup while implementing a feature.

If cleanup is needed first, report the reason and propose a small focused cleanup.

## Feature implementation policy

When asked to add a feature:

1. Find the smallest correct owner for the feature.
2. Reuse existing systems where they fit.
3. Avoid adding logic to large managers.
4. Keep behavior localized.
5. Keep data flow explicit.
6. Add configuration only if the feature needs it now.
7. Avoid speculative extension points.
8. Warn if the feature requires touching too many systems.

A good feature change should usually have:

* one main owner
* a small number of call sites
* clear state ownership
* no hidden cross-service mutation
* no large unrelated rewrites

## Compatibility wrappers

Do not delete wrappers casually.

Keep wrappers when they may be used by:

* Godot signals
* scenes
* editor wiring
* `Callable`
* `call()`
* saved resources
* external nodes
* debug tools
* existing public-ish APIs

Delete a wrapper only if direct search proves it is unused and not dynamically referenced.

When unsure, keep it and report it.

## Debug and telemetry

Debug logic should not be mixed into core gameplay when avoidable.

Prefer focused debug/query/telemetry services for:

* debug overlays
* route inspection
* garden visualization
* flow-field labels
* lag reporting
* diagnostic summaries

Debug code must not change gameplay behavior.

Do not remove debug warnings unless they are obsolete or misleading.

## Performance policy

Performance matters.

The game may have hundreds of agents active.

Avoid per-frame work that scales badly with:

* all agents
* all map cells
* all buildings
* all gardens
* all spawners

Before adding per-frame loops, check whether the work can be:

* event-driven
* queued
* cached
* limited per frame
* scoped to dirty/affected objects only

Do not optimize by making the code unreadable.

If a clean implementation may be expensive, warn the user and explain the tradeoff.

## Reporting requirements

At the end of every coding task, report:

1. Changed files.
2. What moved or changed.
3. What behavior was intentionally preserved.
4. Any compatibility wrappers kept.
5. Any private coupling or messy area intentionally retained.
6. Any production-quality concern noticed.
7. Suggested manual test scenarios.

If the task risks creating noodles, explicitly say so and explain the safer alternative.

## Manual testing

The user runs tests manually.

Suggest relevant manual tests, but do not run them.

For gameplay/navigation changes, suggest tests such as:

* start a normal day
* start a normal night
* spawn monsters from multiple spawners
* let monsters target, eat, and exit
* place/remove buildings
* verify pathing/navigation invalidation
* verify client phase if affected
* verify save/load if affected
* verify debug overlays if affected
* check for new warnings/errors

## Final rule

Prefer code that is boring, explicit, and easy to follow.

Do not chase perfect architecture.

Do not create noodles.

If the clean solution is bigger than the task, warn the user before making the code worse.
