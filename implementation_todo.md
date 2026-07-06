Review `scripts/map/buildsystem.gd` after the recent extractions:

* `BuildPreviewController`
* `BuildPlacementService`
* `BuildRemovalService`
* `BuildDragController`

Goal: perform one focused extraction: move build-mode input routing into a dedicated controller.

Do not run Godot, tests, compilation, export, or build commands. I will test manually.

## Target

Create a focused input controller, for example:

```txt id="ykol5t"
scripts/map/build_input_controller.gd
```

Use another clear name only if it better matches the existing project style.

## Why this extraction

`BuildSystem` should remain the public coordinator for building, but it should not directly own all raw input handling.

The next coherent responsibility is:

```txt id="6533kq"
Read mouse/gamepad/build actions, interpret them in the current build mode, and dispatch to preview, drag, placement, removal, or cancellation.
```

This is separate from:

```txt id="y9o787"
preview rendering
placement commit
removal commit
drag state
item/tool selection
inventory/cost mutation
TileMap mutation
UI menus
save/load
```

This is architectural cleanup, not line-count cleanup.

## Candidate responsibility to move

Move only build-system input routing.

Candidate areas to inspect and possibly extract:

```txt id="z65yzm"
_unhandled_input / _input handling related to building
mouse click placement routing
mouse click removal routing
mouse release handling
mouse motion build preview routing
gamepad build cursor movement input routing
gamepad confirm/cancel routing
build mode cancel input
tool action dispatch
routing to drag controller
routing to preview controller
routing to placement service
routing to removal service
```

Move only functions/state that are clearly input-specific.

If a function mixes input with placement/removal commit logic, leave commit logic in the placement/removal services and make the input controller call existing wrappers.

## Desired boundary

`BuildSystem` may keep:

```gdscript id="14j0ef"
var _input_controller: BuildInputController = BuildInputController.new()
```

Initialize it with:

```gdscript id="n58w3j"
_input_controller.setup(self)
```

if this matches the current controller/service pattern and keeps the patch smaller.

Existing Godot callbacks may remain in `BuildSystem` as thin wrappers:

```gdscript id="ioq7zk"
func _unhandled_input(event: InputEvent) -> void:
	_input_controller.unhandled_input(event)

func _process(delta: float) -> void:
	_input_controller.process(delta)
```

Thin wrappers are acceptable and recommended.

Do not rewrite the whole `BuildSystem` call graph just to avoid wrappers.

## Ownership rule

`BuildInputController` may own:

```txt id="qnrgwo"
raw build-mode input routing
mouse press/release routing
mouse motion routing
gamepad confirm/cancel routing
gamepad cursor repeat timing, if currently input-only
input suppression/consumption logic
dispatch to preview/drag/place/remove wrappers
```

`BuildSystem` should still own:

```txt id="y91355"
build mode state, unless tiny read/write wrappers are enough
selected tool/item state, unless already owned elsewhere
preview controller
placement service
removal service
drag controller
UI-facing public API
save/load coordination
inventory/cost mutation through placement/removal services
TileMap mutation through placement/removal services
```

If ownership is unclear, keep the state in `BuildSystem` and expose a narrow wrapper.

## Boundary with BuildDragController

`BuildInputController` decides:

```txt id="91v2ep"
The user pressed/moved/released input in a way that starts, updates, or stops a drag.
```

`BuildDragController` decides:

```txt id="inl5si"
Which cells are processed during that drag and whether a drag step should attempt placement/removal.
```

Do not move drag processed-cell state into the input controller.

## Boundary with BuildPreviewController

`BuildInputController` may tell preview to update, show, hide, or refresh based on input/mode.

But it should not own:

```txt id="eb7utk"
preview nodes
preview tint
preview validity visuals
footprint ghost visuals
remove highlight visuals
```

Do not move preview rendering back into input.

## Boundary with placement/removal

`BuildInputController` may call placement/removal wrappers:

```gdscript id="05yb8v"
manager.try_place_selected_item(cell)
manager.try_remove_at_cell(cell)
```

But it must not own placement/removal rules.

Do not duplicate validation or commit logic in input.

## Do not extract

Do not move or refactor:

```txt id="mc5qls"
preview/cursor rendering internals
actual placement commit rules
actual removal commit rules
drag processed-cell state
tool selection UI
shop/build menu UI
save/load behavior
combat/projectile behavior
player movement
BuildingManager behavior
inventory/cost logic except calling existing placement/removal APIs
```

This pass is only about input routing.

## Behavior preservation

Preserve existing behavior exactly:

```txt id="sl6ted"
same mouse click behavior
same mouse release behavior
same mouse drag behavior
same mouse movement preview behavior
same gamepad cursor behavior
same gamepad confirm/cancel behavior
same build-mode cancel behavior
same input consumed/ignored behavior
same interactions with UI/menu focus
same click-place behavior
same click-remove behavior
same drag-place behavior
same drag-remove behavior
same preview update timing
same selected tool/item behavior
```

Do not change input bindings.

Do not change placement/removal rules.

Do not change drag behavior.

Do not change preview behavior.

Do not change UI behavior.

## Coupling rule

If input routing is deeply mixed with mode state or UI selection, do not extract the entire function blindly.

Instead:

```txt id="jz2u30"
leave mode/tool selection state in BuildSystem
extract only the input routing and dispatch
use small wrapper methods on BuildSystem
report remaining coupling
```

If the extraction requires rewriting UI, placement, removal, preview, drag, or save/load behavior, stop and report the coupling instead of expanding the task.

## GDScript strict typing

Godot/GDScript strict typing is enabled.

Avoid `:=` inference for:

```txt id="sxxsdy"
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

Do not continue into UI, preview, placement, removal, drag, inventory, or save/load redesign because the code is nearby.

## Before coding, report

```txt id="ks18g4"
Owner:
Caller:
State owned:
Public API:
Files changed:
Estimated lines moved:
Input state ownership decision:
BuildSystem state intentionally kept:
Thin wrappers to preserve:
Couplings found:
Risk:
```

Then implement only the build input routing extraction.

## Final report

After implementation, report:

```txt id="l1vtul"
What moved:
What stayed in BuildSystem:
Input state ownership decision:
Thin wrappers kept:
Files changed:
Remaining risks:
Manual test checklist:
Recommended next step:
```
