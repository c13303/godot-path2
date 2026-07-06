Task: reduce `scripts/map/building_manager.gd` by extracting build/place/remove command orchestration into a dedicated RefCounted controller.

Context:
`BuildingManager` is still too large. Previous extraction passes have been tested, including path service, agent definition service, spawn controller, garden access resolver, and invalidation controller.

The next extraction should move build/place/remove command orchestration out of `BuildingManager`, while preserving behavior exactly.

Create a new file:

`scripts/map/build_command_controller.gd`

with:

```gdscript
extends RefCounted
class_name BuildCommandController
```

Goal:
Move the high-level “apply a build/remove command” orchestration out of `BuildingManager`.

This controller should not invent new build rules.

It should preserve current placement/removal behavior and delegate to existing systems exactly as before.

Extract logic related to:

* placing a selected placeable
* removing/unbuilding a placeable
* successful placement side effects
* successful removal side effects
* cost/inventory application
* refund behavior, if currently handled directly in `BuildingManager`
* object manager placement/removal calls
* tilemap/building-layer mutation calls
* calling invalidation after successful mutation
* debug logging around placement/removal

Likely methods/code blocks to search for:

* `_place_selected`
* `_place_building`
* `_try_place`
* `_try_place_at`
* `_remove_building`
* `_try_remove`
* `_unbuild`
* `_unbuild_at`
* `_can_place`
* `_can_remove`
* `_commit_place`
* `_commit_remove`
* `_apply_build_cost`
* `_refund_build_cost`
* calls into `BuildingObjectManager`
* calls into inventory/cost services
* placement/removal success paths
* calls into the new invalidation controller

Exact method names may differ. Search the codebase and extract the coherent command orchestration, not unrelated preview/input/drag logic.

Architecture:
Follow the existing RefCounted controller pattern.

The controller should keep a manager reference:

```gdscript
var _manager: Node

func setup(manager: Node) -> void:
	_manager = manager
```

Suggested public API:

```gdscript
func setup(manager: Node) -> void

func try_place_at(cell: Vector2i, placeable_def: Dictionary, source: StringName = &"") -> bool
func try_remove_at(cell: Vector2i, source: StringName = &"") -> bool
func can_place_at(cell: Vector2i, placeable_def: Dictionary) -> bool
func can_remove_at(cell: Vector2i) -> bool
```

Adjust names/signatures to match the current codebase if necessary.

Preserve compatibility:
Keep thin wrappers in `BuildingManager` for old methods that other controllers, signals, or dynamic `call()` usage may still depend on.

Example:

```gdscript
func _try_place_at(cell: Vector2i, placeable_def: Dictionary) -> bool:
	return _build_command_controller.try_place_at(cell, placeable_def)

func _try_remove_at(cell: Vector2i) -> bool:
	return _build_command_controller.try_remove_at(cell)
```

Add to `BuildingManager`:

```gdscript
var _build_command_controller: BuildCommandController = BuildCommandController.new()
```

In `_ready()`:

```gdscript
_build_command_controller.setup(self)
```

Important ownership boundary:
`BuildCommandController` owns command orchestration.

It should not own:

* preview logic
* cursor hover logic
* drag input
* UI selection state
* placeable definitions
* direction rotation state
* raw object storage
* garden topology implementation
* pathfinding implementation
* flow-field implementation
* spawning
* agent retargeting

Those should remain in their existing owners.

The command controller may call existing services/controllers through `_manager`, for example:

```gdscript
_manager.call("_can_place_at", cell, placeable_def)
_manager.call("_clear_hover")
_manager.call("_cell_center", cell)
_manager.call("_is_walkable", cell)
_manager.call("_apply_build_cost", placeable_def)
_manager.call("_refund_build_cost", removed_def)
_manager.call("_set_building_cell", cell, placeable_def)
_manager.call("_remove_building_cell", cell)
```

Use the actual existing method names from the codebase.

For extracted controllers, direct property access is acceptable if consistent with existing code:

```gdscript
var invalidation: Object = _manager.get("_building_invalidation_controller")
```

Do not invent a new dependency-injection architecture.

Behavior preservation requirements:

1. Do not change placement rules.
2. Do not change removal rules.
3. Do not change inventory/cost behavior.
4. Do not change refund behavior.
5. Do not change object-manager behavior.
6. Do not change tilemap mutation behavior.
7. Do not change blocked/walkable behavior.
8. Do not change light-source behavior.
9. Do not change turret/furniture/wall/plant/trap behavior.
10. Do not change build direction behavior.
11. Do not change UI selection behavior.
12. Do not change preview behavior.
13. Do not change drag behavior.
14. Do not change debug logs.
15. Do not change telemetry names.
16. Do not change return values.
17. Do not change side-effect order.

Side-effect order is critical.

Preserve the exact current order of:

* validation
* cost check
* inventory mutation
* object/tile mutation
* light registration
* turret/blocker registration
* plant/garden dirty marks
* route/cache invalidation
* preview/hover refresh
* debug logging
* signal emission

If the current code has rollback behavior on failed placement/removal, preserve it exactly.

If the current code consumes cost before mutation, keep that order.

If the current code mutates before invalidation, keep that order.

If the current code clears hover/preview after mutation, keep that order.

Search all references before editing:

* place
* placement
* remove
* unbuild
* refund
* cost
* inventory
* building_object_manager
* light
* turret
* trap
* furniture
* wall
* plant
* `_building_invalidation_controller`
* `_clear_hover`
* `_refresh_preview`
* `_placement_disabled`

Expected result:

* `building_manager.gd` loses a large coherent block of build/remove command orchestration.
* `BuildCommandController` owns command execution.
* `BuildingManager` keeps selection/input/preview coordination and compatibility wrappers only.
* Existing callers continue to work.
* No `.tscn` changes required.
* No gameplay behavior changes.

Regression risks to avoid:

1. Do not move input handling into this controller.
2. Do not move preview handling into this controller except existing post-command refresh calls if they already occur in the command path.
3. Do not change build validation rules while extracting.
4. Do not accidentally charge inventory on failed placement.
5. Do not accidentally refund twice on removal.
6. Do not skip invalidation after successful mutation.
7. Do not invalidate before mutation if the old code invalidated after mutation.
8. Do not change how directional placeables are resolved.
9. Do not change light/turret/blocker registration order.
10. Do not duplicate placement state between `BuildingManager` and the new controller.
11. Do not rewrite `BuildingObjectManager`.
12. Do not modify garden/path/spawn/agent services unless strictly required for call-site wiring.
13. Do not rename concepts.
14. Do not compile or run tests; I will do it.

Non-goals:
Do not refactor preview rendering.
Do not refactor input handling.
Do not refactor drag placement.
Do not refactor placeable definitions.
Do not refactor direction rules.
Do not refactor garden topology.
Do not refactor pathfinding.
Do not refactor spawning.
Do not change build costs.
Do not optimize placement.
Do not perform unrelated cleanup.
