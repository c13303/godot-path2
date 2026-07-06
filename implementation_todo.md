Review `scripts/map/buildsystem.gd` after the recent extractions:

* `BuildPreviewController`
* `BuildPlacementService`

Goal: perform one focused extraction: move actual building removal / unbuild logic into a dedicated service.

Do not run Godot, tests, compilation, export, or build commands. I will test manually.

## Target

Create a focused removal service, for example:

```txt id="rfbhpe"
scripts/map/build_removal_service.gd
```

Use another clear name only if it better matches the existing project style.

## Why this extraction

`BuildSystem` should coordinate build mode and input, but it should not directly own every detail of removing an item from the world.

After preview and placement extraction, the next coherent responsibility is:

```txt id="bd2cgp"
Given a target cell:
detect what removable object exists there, remove it from the world, apply refunds if any, and trigger cleanup side effects.
```

This is separate from:

```txt id="7hdj2g"
preview rendering
cursor movement
placement commit
tool selection
UI menus
combat
save/load
```

This is architectural cleanup, not line-count cleanup.

## Candidate responsibility to move

Move only actual removal / unbuild commit behavior.

Candidate areas to inspect and possibly extract:

```txt id="1ebfuw"
remove current targeted building
unbuild wall
unbuild plant
unbuild furniture/building
unbuild lamp
unbuild turret/blocking building
clear TileMapLayer cell
remove BuildingObjectManager object
refund item/cost if existing behavior does that
clear terrain speed multiplier
clear player blocking cell
notify BuildingManager/building signals
mark navigation/topology dirty
cleanup irrigation/water side effects caused by removal
handle drag-remove commits, if present
```

Move only functions/state that are clearly removal-commit related.

If a function both handles input and commits removal, split only the removal commit part and leave input interpretation in `BuildSystem`.

## Desired boundary

`BuildSystem` may keep:

```gdscript id="lhzzge"
var _removal_service: BuildRemovalService = BuildRemovalService.new()
```

Initialize it with:

```gdscript id="00oh8s"
_removal_service.setup(self)
```

if that matches the current controller/service pattern and keeps the patch smaller.

Thin wrappers in `BuildSystem` are acceptable.

Example:

```gdscript id="4nfnvd"
func _try_remove_at_cell(cell: Vector2i) -> bool:
	return _removal_service.try_remove_at_cell(cell)
```

Do not rewrite the whole `BuildSystem` call graph just to avoid wrappers.

## Ownership rule

`BuildRemovalService` may own:

```txt id="vcb84k"
removal validation for commit
removal target detection
removal commit result
TileMapLayer/object-manager clearing path
refund behavior for removal if currently present
removal side effects
blocking/speed/topology updates caused by removal
irrigation/water cleanup caused by removal
```

`BuildSystem` should still own:

```txt id="l1e8xq"
build mode enable/disable
input handling
mouse/gamepad cursor interpretation
preview controller
placement service
tool/item selection
drag state, unless it is strictly removal commit state
UI-facing public API
save/load coordination
```

If ownership is unclear, keep the state in `BuildSystem` and expose a narrow wrapper.

## Do not extract

Do not move or refactor:

```txt id="b7xgzn"
preview/cursor rendering
actual placement
placement cost behavior
tool selection UI
shop/build menu UI
save/load behavior
combat/projectile behavior
player movement
broad BuildingManager behavior
counter stock internals
```

This pass is only about removal/unbuild commit.

## Behavior preservation

Preserve existing behavior exactly:

```txt id="dcxa00"
same removable/non-removable rules
same layer chosen for removal
same object-manager removal behavior
same wall removal behavior
same plant removal behavior
same furniture/lamp removal behavior
same turret/blocking building removal behavior
same refund behavior
same terrain speed reset/update behavior
same player blocking reset behavior
same navigation/topology dirty behavior
same building signals/callbacks
same irrigation/water cleanup behavior
same drag-removal result
same error/failure behavior
```

Do not change removal rules.

Do not change refunds.

Do not change item definitions.

Do not change blocking/collision semantics.

Do not change preview behavior.

Do not change placement behavior.

## Boundary with preview

`BuildPreviewController` answers:

```txt id="edd665"
What cell is targeted?
What does the remove/placement preview show?
Does the current target look valid/invalid?
```

`BuildRemovalService` answers:

```txt id="d5dkiu"
Can something be removed here?
If yes, remove it from the world and apply side effects.
```

Do not merge preview back into removal.

If removal currently relies on preview validity, preserve that behavior but avoid making preview the source of truth unless it already was.

## Boundary with placement

Do not move placement in this pass.

If placement and removal share tiny helpers, keep them in `BuildSystem` for now unless they are pure and clearly shared.

Do not create a generic build utility dumping ground.

## Coupling rule

If actual removal is deeply mixed with input, preview, placement, or UI code, do not extract the whole function blindly.

Instead:

```txt id="e3k0fr"
leave input/UI/preview/placement code in BuildSystem
extract only the removal commit core
add small wrapper methods if needed
report remaining coupling
```

If the extraction requires rewriting placement, UI, save/load, or item catalog behavior, stop and report the coupling instead of expanding the task.

## GDScript strict typing

Godot/GDScript strict typing is enabled.

Avoid `:=` inference for:

```txt id="n32a01"
numeric expressions
Dictionary / Array values
signal or call() returns
mixed int / float math
nullable or dynamic values
```

Prefer explicit local types.

Cast dynamic values before use.

## Patch discipline

Preserve behavior.

Keep the patch reviewable.

Do not rename unrelated symbols.

Do not reformat unrelated code.

Do not perform broad cleanup.

Do not create generic `utils` files.

Do not continue into placement, preview, UI, or inventory redesign because the code is nearby.

## Before coding, report

```txt id="8isgnn"
Owner:
Caller:
State owned:
Public API:
Files changed:
Estimated lines moved:
Removal state ownership decision:
BuildSystem state intentionally kept:
Thin wrappers to preserve:
Couplings found:
Risk:
```

Then implement only the removal/unbuild commit extraction.

## Final report

After implementation, report:

```txt id="t5m2p0"
What moved:
What stayed in BuildSystem:
Removal state ownership decision:
Thin wrappers kept:
Files changed:
Remaining risks:
Manual test checklist:
Recommended next step:
```
