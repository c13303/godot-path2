Task: final polish pass for the map/building cleanup.

Targets:

* `scripts/map/building_manager.gd`
* all `scripts/map/*service.gd`
* all `scripts/map/*controller.gd`
* `AGENTS.md`, only if it exists and needs minor tuning
* optional: `scripts/map/ARCHITECTURE.md`, only if useful

Goal:
Verify the map/building codebase is in a clean enough state for future coding-agent and human maintenance.

This is the final cleanup pass, not a broad refactor pass.

Do not optimize.
Do not move broad behavior.
Do not create new systems.
Do not run Godot, tests, builds, compilation, or exports.

## Main objective

Confirm that the previous cleanup passes achieved the intended architecture:

* `BuildingManager` is mostly coordinator/facade
* extracted services/controllers have clear ownership
* state mostly lives with the behavior that owns it
* hidden manager coupling is rare and justified
* compatibility wrappers are intentional
* file sizes are reasonable for their responsibilities
* future agents can understand where to edit without reading the whole codebase

## Step 1: final hidden-coupling audit

Search `scripts/map/` for:

* `_manager.call(`
* `_manager.get(`
* `_manager.set(`
* `_manager.has_method(`

For each remaining usage, classify it as:

* dynamic compatibility call
* external/signal/scene safety
* unavoidable manager-owned lifecycle/state access
* safe to replace
* risky / leave unchanged

Allowed changes:

* replace clearly safe hidden calls with direct calls or existing accessors
* replace clearly safe manager state reads/writes with explicit service/controller accessors
* leave dynamic or risky calls unchanged and report why

Do not try to force the count to zero.

Success condition:

Remaining hidden manager access should be rare, localized, and explainable.

## Step 2: final BuildingManager role check

Review `building_manager.gd`.

Classify remaining content into:

* lifecycle / `_ready()` / setup
* service wiring
* day/night orchestration
* high-level build/map event dispatch
* compatibility wrappers
* scene-facing references
* save/progression integration
* still-detailed subsystem logic
* unclear/mixed ownership

Allowed changes:

* bypass internal-only wrappers if clearly safe
* add short comments for compatibility wrappers that must stay
* report remaining detailed logic blocks
* perform tiny local cleanup only if risk is low

Do not perform new large extraction in this pass.

Success condition:

`BuildingManager` should be understandable as the map/building coordinator, even if it still has compatibility wrappers.

## Step 3: final state ownership check

Look for obvious split or duplicate state.

Examples:

* a flag stored in `BuildingManager` but owned by a service
* a dictionary stored in two places
* a service reading/writing manager state through `_manager.get/_manager.set`
* a service owning behavior while another class owns the related state

Allowed changes:

* move only tiny, obvious state if it has one clear owner and low risk
* otherwise report the issue for a future task

Do not move lifecycle, save/progression, exported, or broadly shared state unless it is obviously wrong and safe.

Success condition:

No obvious duplicate state remains in the core map/building systems.

## Step 4: file size and cohesion check

Review large files in `scripts/map/`.

Use these guidelines:

* 0–400 lines: usually fine
* 400–800 lines: acceptable if cohesive
* 800–1200 lines: review ownership
* 1200+ lines: suspicious unless it is a coordinator/facade
* `BuildingManager` may remain around 1500–2500 lines if mostly orchestration and compatibility

Allowed changes:

* no line-count-only splitting
* report large but cohesive files as acceptable
* report large mixed files as future cleanup candidates

Success condition:

Files are organized by responsibility, not arbitrary line count.

## Step 5: optional architecture note

Only if useful, create or update:

* `scripts/map/ARCHITECTURE.md`

Keep it short.

Use this format:

```txt
# Map / Building Architecture

## BuildingManager
Owns:
- ...

Does not own:
- ...

Notes:
- ...

## ServiceName
Owns:
- ...

Does not own:
- ...

Notes:
- ...
```

Do not add pseudo-code.
Do not write a long essay.
Do not document aspirational ownership as if it already exists.
If ownership is still shared or messy, say so.

If the code is clear enough without this file, skip it and report why.

## Step 6: optional AGENTS.md tune-up

Only if `AGENTS.md` exists and is clearly outdated or too broad, make minimal edits.

Keep it short and generic.

It should contain durable rules only:

* do not guess; ask if unsure
* do not run Godot/tests/builds unless explicitly authorized
* strict GDScript typing
* do not split files only for line count
* preserve behavior unless requested
* avoid hidden manager coupling when practical
* report changed files and manual test risks

Do not put task-specific extraction instructions in `AGENTS.md`.
Do not add pseudo-code for current tasks.

## Do not change

Do not change:

* gameplay behavior
* public method behavior
* signal-connected behavior
* scene-facing method names
* service setup order
* day/night lifecycle order
* spawning behavior
* placement/removal behavior
* garden behavior
* retarget behavior
* navigation behavior
* client/merchant behavior
* save/progression behavior
* debug log text
* `.tscn` files

## Important Godot caution

Godot may call methods dynamically through:

* scenes
* signals
* `call(...)`
* editor connections
* animation tracks
* UI scripts

If unsure whether a method or wrapper is externally called, keep it and report it.

## Expected result

After this pass:

* remaining hidden coupling is classified and reduced where safely possible
* `BuildingManager` role is clear
* obvious duplicate/split state is gone or reported
* large files are justified or flagged
* optional architecture documentation exists only if it is useful
* optional `AGENTS.md` stays short and generic
* behavior remains unchanged

## Final report

Report:

* files changed
* remaining `_manager.call/get/set/has_method` counts by file
* hidden coupling removed, if any
* remaining hidden coupling intentionally kept and why
* `BuildingManager` role assessment
* state ownership issues fixed or left for later
* large file/cohesion review
* architecture doc created/updated/skipped
* `AGENTS.md` updated/skipped
* behavior intentionally preserved
* manual test risks
* whether the codebase is now clean enough to stop refactoring for cleanliness
