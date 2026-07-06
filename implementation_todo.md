Review `scripts/map/buildsystem.gd` after the recent extractions:

* `BuildPreviewController`
* `BuildPlacementService`
* `BuildRemovalService`

Goal: perform one focused extraction: move drag-build / drag-remove gesture state and processing into a dedicated controller.

Do not run Godot, tests, compilation, export, or build commands. I will test manually.

## Target

Create a focused drag controller, for example:

```txt id="e2p71j"
scripts/map/build_drag_controller.gd
```

Use another clear name only if it better matches the existing project style.

## Why this extraction

`BuildSystem` should coordinate build mode and tools, but drag gestures are their own responsibility:

```txt id="5lo5zk"
Track whether the player is dragging,
track which cells were already processed,
decide when a drag action should place/remove,
and call the placement/removal services for each new cell.
```

This is separate from:

```txt id="mqk8nc"
preview rendering
actual placement commit
actual removal commit
tool selection
UI menus
save/load
combat
```

This is architectural cleanup, not line-count cleanup.

## Candidate responsibility to move

Move only drag gesture logic.

Candidate areas to inspect and possibly extract:

```txt id="r5jrv2"
drag-build start
drag-build update
drag-build stop
drag-remove start
drag-remove update
drag-remove stop
drag processed-cell tracking
drag last-cell tracking
drag mouse-button state
drag gamepad placement repetition if it is drag-like
drag placement/removal throttling if present
calling placement service once per new dragged cell
calling removal service once per new dragged cell
```

Move only functions/state that are clearly drag-specific.

If a function mixes input interpretation, preview, and drag processing, extract only the drag-state part and leave high-level input routing in `BuildSystem`.

## Desired boundary

`BuildSystem` may keep:

```gdscript id="k85x5u"
var _drag_controller: BuildDragController = BuildDragController.new()
```

Initialize it with:

```gdscript id="jj2wv5"
_drag_controller.setup(self)
```

if this matches the current controller/service pattern and keeps the patch smaller.

Thin wrappers in `BuildSystem` are acceptable.

Examples:

```gdscript id="6oxb2a"
func _start_build_drag(cell: Vector2i) -> void:
	_drag_controller.start_build_drag(cell)

func _update_build_drag(cell: Vector2i) -> void:
	_drag_controller.update_build_drag(cell)

func _stop_build_drag() -> void:
	_drag_controller.stop_drag()
```

Do not rewrite the whole `BuildSystem` call graph just to avoid wrappers.

## Ownership rule

`BuildDragController` may own:

```txt id="mv4yhn"
is-dragging state
drag mode: place/remove
drag start cell
last drag cell
processed drag cells
drag throttling/timers if present
drag repeat state if it only exists for drag
```

`BuildSystem` should still own:

```txt id="la73bt"
build mode enable/disable
input event routing
mouse/gamepad cursor interpretation
preview controller
placement service
removal service
tool/item selection
UI-facing public API
save/load coordination
```

If ownership is unclear, keep the state in `BuildSystem` and expose a narrow wrapper.

## Boundary with placement/removal services

`BuildDragController` should not duplicate placement/removal rules.

It should call existing placement/removal commit methods, for example:

```gdscript id="fhpx0b"
manager.try_place_selected_item(cell)
manager.try_remove_at_cell(cell)
```

or directly call the services through `BuildSystem` wrappers.

The drag controller answers:

```txt id="26uwib"
Should this drag step attempt an action for this cell?
```

Placement/removal services answer:

```txt id="e1c3c1"
Can the action actually happen, and how is it committed?
```

Do not move placement/removal rules into the drag controller.

## Boundary with preview

Do not move preview rendering back into drag logic.

The drag controller may ask for the current targeted cell or preview validity through `BuildSystem` wrappers if needed.

But it should not own preview nodes, ghost tiles, highlight visuals, or preview tint.

## Do not extract

Do not move or refactor:

```txt id="k9ni6l"
preview/cursor rendering
actual placement commit rules
actual removal commit rules
tool selection UI
shop/build menu UI
save/load behavior
combat/projectile behavior
player movement
BuildingManager behavior
inventory/cost logic except calling existing placement/removal APIs
```

This pass is only about drag gesture state and drag processing.

## Behavior preservation

Preserve existing behavior exactly:

```txt id="hk63ml"
same drag-start condition
same drag-stop condition
same cells processed during drag
same duplicate-cell prevention
same drag placement behavior
same drag removal behavior
same drag with invalid cells
same drag with blocked cells
same mouse behavior
same gamepad behavior if applicable
same preview behavior during drag
same inventory/cost behavior through placement service
same refund/removal behavior through removal service
```

Do not change placement/removal rules.

Do not change preview behavior.

Do not change tool selection.

Do not change input bindings.

## Coupling rule

If drag behavior is deeply mixed with input event routing, do not extract the entire input function.

Instead:

```txt id="5cu1sd"
leave raw input routing in BuildSystem
extract only drag state and per-cell drag processing
use small wrapper calls into placement/removal
report remaining coupling
```

If the extraction requires rewriting placement, removal, preview, UI, or input architecture, stop and report the coupling instead of expanding the task.

## GDScript strict typing

Godot/GDScript strict typing is enabled.

Avoid `:=` inference for:

```txt id="y2yl0c"
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

Do not continue into input, preview, placement, removal, UI, or inventory redesign because the code is nearby.

## Before coding, report

```txt id="ia0drp"
Owner:
Caller:
State owned:
Public API:
Files changed:
Estimated lines moved:
Drag state ownership decision:
BuildSystem state intentionally kept:
Thin wrappers to preserve:
Couplings found:
Risk:
```

Then implement only the drag gesture extraction.

## Final report

After implementation, report:

```txt id="dovhw1"
What moved:
What stayed in BuildSystem:
Drag state ownership decision:
Thin wrappers kept:
Files changed:
Remaining risks:
Manual test checklist:
Recommended next step:
```
