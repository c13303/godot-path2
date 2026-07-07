Task: final targeted extraction pass after the `BuildingManager` responsibility review.

Target:

* `scripts/map/building_manager.gd`
* one existing service/controller file, only if it is the clear owner
* create a new service only if no existing owner fits cleanly

Goal:
Move one remaining clearly misplaced responsibility out of `BuildingManager`, without changing gameplay behavior.

This is a targeted extraction pass, not a broad cleanup pass.

Do not optimize.
Do not extract multiple unrelated blocks.
Do not run Godot, tests, builds, compilation, or exports.

## Main objective

Use the previous responsibility review to choose **one** remaining block of detailed logic that clearly does not belong in `BuildingManager`.

Only extract if all of these are true:

* the responsibility is cohesive
* related methods and state are easy to identify
* an existing service/controller clearly owns it, or a new service has an obvious narrow purpose
* extraction does not require broad call-site churn
* extraction does not create many new `_manager.call(...)`, `_manager.get(...)`, or `_manager.has_method(...)` usages
* behavior can be preserved exactly

If no block satisfies these conditions, do not extract. Report that no safe extraction is currently justified.

## Good extraction candidates

Good candidates look like:

* one clear algorithm block still embedded in `BuildingManager`
* one clear state group still living in `BuildingManager` but used mostly by one service
* one detailed subsystem behavior that already has a matching service
* one repeated wrapper/data-flow pattern that can be moved cleanly

Examples of acceptable target shapes:

* detailed debug overlay logic into an existing debug overlay controller
* remaining path helper logic into `BuildingPathService`
* remaining invalidation logic into `BuildingInvalidationController`
* remaining placement/removal detail into `BuildPlacementService` or `BuildRemovalService`
* remaining spawn config detail into `SpawnPlaylistConfigService`
* remaining client/merchant/counter detail into the appropriate controller

## Bad extraction candidates

Do not extract if the block:

* mixes several domains
* needs many callbacks into `BuildingManager`
* is mainly orchestration
* is scene-facing lifecycle code
* depends on unclear dynamic calls
* would force broad rewiring across many files
* would produce a helper service with no clear ownership
* would only reduce line count without improving ownership

## BuildingManager should keep

Keep these in `BuildingManager`:

* `_ready()` and Godot lifecycle entry points
* service/controller construction and setup
* high-level day/night orchestration
* high-level map/building event dispatch
* compatibility wrappers when external callers may need them
* scene-facing exported references
* methods likely called by scenes, signals, UI, animation, editor, or dynamic `call(...)`

## Extraction rules

When extracting:

1. Move the behavior and its related state together when practical.

2. Do not duplicate state between `BuildingManager` and the service.

3. If `BuildingManager` still needs the moved state, expose a small accessor on the service.

4. Keep thin compatibility wrappers in `BuildingManager` for moved methods if external callers may still need them.

5. Update internal call sites to use the clearer owner where safe.

6. Avoid adding hidden manager coupling to the extracted service.

7. Prefer explicit service dependencies or typed accessors over `_manager.call(...)`, `_manager.get(...)`, and `_manager.has_method(...)`.

8. Preserve method names where compatibility risk exists.

## New service rule

Only create a new service if the responsibility has a clear narrow name and no existing service owns it.

A new service must follow the existing pattern:

```gdscript
extends RefCounted
class_name ClearSpecificName

var _manager: Node

func setup(manager: Node) -> void:
	_manager = manager
```

Do not create generic names like:

* `BuildingHelper`
* `BuildingUtils`
* `ManagerHelpers`
* `CommonService`
* `MiscController`

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

Godot code may call methods dynamically through scenes, signals, `call(...)`, editor connections, animation tracks, or UI scripts.

If unsure whether a method is externally called, keep a compatibility wrapper in `BuildingManager`.

Do not remove methods merely because static search finds no `.gd` usage.

## Expected result

One of these outcomes is acceptable.

### A. Safe extraction performed

* one clearly-owned responsibility moves out of `BuildingManager`
* related state moves with it if practical
* `BuildingManager` keeps wrappers where needed
* behavior remains unchanged

### B. No extraction performed

* no block was safe enough to extract
* report why extraction was skipped
* recommend the next cleanup target

## Final report

Report:

* chosen responsibility block
* why this block was safe to extract
* files changed
* methods moved
* state moved
* wrappers kept in `BuildingManager`
* internal call sites updated
* hidden manager calls added or avoided
* behavior intentionally preserved
* manual test risks
* recommended next pass
