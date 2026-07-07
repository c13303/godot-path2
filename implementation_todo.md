Task: map-change consequence cleanup pass.

Targets:

* `scripts/map/build_placement_service.gd`
* `scripts/map/build_removal_service.gd`
* `scripts/map/building_scan_service.gd`
* `scripts/map/building_invalidation_controller.gd`
* `scripts/map/building_navigation_sync_service.gd`
* minimal related changes in `scripts/map/building_manager.gd`

Goal:
Make map-change consequences easier to trace, without changing gameplay behavior.

This is a cleanup pass, not a feature pass.

Do not optimize.
Do not create a broad event bus.
Do not move broad behavior.
Do not run Godot, tests, builds, compilation, or exports.

## Problem

Placement, removal, scan, and restore operations can affect several systems:

* garden topology
* navigation topology dirty state
* native/navigation sync
* spawner routes
* retargeting
* debug overlays
* object registries

Some of these consequences may still be triggered through scattered calls. This makes it harder for coding agents and humans to understand what a map change does.

## Main objective

Centralize or clarify **where map-change consequences are triggered**, especially dirty marking and invalidation.

Prefer small explicit methods on `BuildingInvalidationController` over scattered direct calls.

Do not change when consequences happen.

## Current known state

`BuildingInvalidationController` now owns:

* `_navigation_topology_dirty`
* `mark_navigation_topology_dirty()`
* `clear_navigation_topology_dirty()`

`BuildingScanService` should already use the invalidation controller instead of setting manager state directly.

Build on this direction.

## Step 1: audit map-change consequence calls

Search the target files for calls related to:

* dirty topology
* navigation topology dirty
* garden dirty marking
* invalidation
* route invalidation
* flow-field refresh
* native/navigation sync
* scan-triggered updates
* placement-triggered updates
* removal-triggered updates
* debug overlay refresh
* retarget triggering

Also search for:

* `_manager.call(`
* `_manager.get(`
* `_manager.set(`
* `_manager.has_method(`

Classify each consequence as coming from:

* placement
* removal
* scan
* startup restore
* night prep
* client prep
* counter-stock restore
* debug-only refresh
* unclear

## Step 2: clarify consequence ownership

`BuildingInvalidationController` should own orchestration of dirty/invalidation consequences already assigned to it.

It may expose small explicit methods if useful, for example methods with names like:

* `mark_navigation_topology_dirty()`
* `clear_navigation_topology_dirty()`
* `mark_after_building_scan_changed()`
* `mark_after_placement_changed()`
* `mark_after_removal_changed()`

Only add methods if they clarify existing behavior.

Do not add abstract generic methods like:

* `handle_everything_changed()`
* `process_event()`
* `dispatch_change()`

Avoid vague event-bus design.

## Allowed changes

Allowed:

* replace scattered dirty flag writes with explicit invalidation-controller calls
* replace hidden manager state writes with explicit accessors/controller methods
* group existing consequence calls behind small named methods if this improves traceability
* update internal call sites to use the clearer method
* keep compatibility wrappers in `BuildingManager` if external callers may need them

Not allowed:

* changing consequence timing/order
* adding new invalidation triggers
* removing existing invalidation triggers
* changing placement/removal rules
* changing scan behavior
* changing route selection
* changing retarget timing
* changing flow-field generation
* changing native-extension sync behavior
* changing debug log text
* changing `.tscn` files

## Ownership rules

`BuildPlacementService` should own:

* placement validation
* placement application
* placement-side direct tile/object mutation already assigned to it

It should not own:

* garden topology algorithms
* retarget policy
* route policy
* navigation dirty state internals

`BuildRemovalService` should own:

* removal validation
* removal application
* removal-side direct tile/object mutation already assigned to it

It should not own:

* garden topology algorithms
* retarget policy
* route policy
* navigation dirty state internals

`BuildingScanService` should own:

* scanning scene/map buildings
* discovering/registering scanned objects/spawners
* reporting scan consequences explicitly

It should not own:

* navigation dirty flag storage
* topology rebuild algorithms
* route policy
* retarget policy

`BuildingInvalidationController` should own:

* dirty/invalidation orchestration
* navigation topology dirty flag
* explicit invalidation methods used by scan/placement/removal/restore flows
* preserving current invalidation order

It should not own:

* placement/removal validation
* object creation/removal
* topology algorithms
* pathfinding algorithms
* actual spawning
* agent phase transitions

`BuildingNavigationSyncService` should own:

* applying map/object changes to navigation/native-extension state
* blocker/static-agent sync already assigned to it

It should not own:

* deciding high-level invalidation policy
* placement/removal validation
* garden topology policy

`BuildingManager` should only:

* coordinate lifecycle
* wire services
* call high-level consequence methods at existing lifecycle points
* keep compatibility wrappers where needed

## Important regression risks

Avoid:

* changing invalidation order
* clearing dirty flags too early
* leaving dirty flags set forever
* missing dirty marks after scan/placement/removal
* duplicating dirty state between manager and invalidation controller
* changing flow-field refresh timing
* changing native-extension blocker sync timing
* changing garden rebuild timing
* changing retarget timing
* changing route invalidation timing
* adding broad scans in hot paths
* adding extra per-agent work

## Expected result

After this pass:

* map-change consequences are easier to follow
* dirty/invalidation calls are more explicit
* `BuildingInvalidationController` is the clear owner of dirty/invalidation orchestration
* behavior remains unchanged
* no broad event system is introduced
* no scene files are changed

## If no safe cleanup is obvious

Do not force changes.

Report:

* current consequence flow
* what is already clean enough
* what remains messy but risky to change
* recommended next pass

## Final report

Report:

* files changed
* consequence calls audited
* invalidation methods added or reused
* scattered dirty writes removed, if any
* hidden manager calls removed, if any
* consequence timing intentionally preserved
* risky areas left unchanged
* manual test risks
* recommended next pass
