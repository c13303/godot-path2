Review `scripts/map/buildsystem.gd`.

Goal: start cleaning `buildsystem.gd` with one focused extraction: move build preview / placement cursor responsibility into a dedicated helper/controller.

Do not run Godot, tests, compilation, export, or build commands. I will test manually.

## Target

Create a focused controller, for example:

```txt
scripts/map/build_preview_controller.gd
```

Use another clear name only if it better matches the existing project style.

## Why this extraction

`BuildSystem` should coordinate building actions, but it should not directly own all preview/cursor rendering and placement-highlight state.

The first extraction should separate:

```txt
Where would the item be placed?
How should the preview look?
Is the preview visible?
What tile/cell is currently targeted?
What feedback should be shown before committing placement/removal?
```

from:

```txt
Actually place/remove the building
Mutate TileMapLayers
Update flow/player blocking
Update inventory/cost
Update irrigation/plants/counters
```

This is architectural cleanup, not line-count cleanup.

## Candidate responsibility to move

Move only build preview / cursor / ghost / highlight behavior.

Candidate areas to inspect and possibly extract:

```txt
preview node creation
preview node update
preview visibility
preview position
preview rotation / flip display
valid/invalid preview feedback
hovered build cell
current target cell
mouse-to-cell / cursor-to-cell preview calculation
gamepad build cursor display
remove/unbuild preview highlight
placement footprint preview
multi-cell placement preview, if present
```

Move only functions/state that are clearly preview-only.

If a function both previews and commits placement/removal, split only the preview part and leave the commit logic in `BuildSystem`.

## Desired boundary

`BuildSystem` may keep:

```gdscript
var _build_preview: BuildPreviewController = BuildPreviewController.new()
```

Initialize it with:

```gdscript
_build_preview.setup(self)
```

if that matches the project’s current controller/service pattern and keeps the patch smaller.

Thin wrappers in `BuildSystem` are acceptable.

Example acceptable wrapper style:

```gdscript
func _update_build_preview() -> void:
	_build_preview.update_preview()
```

Do not rewrite the whole `BuildSystem` call graph just to avoid wrappers.

## Ownership rule

`BuildPreviewController` may own:

```txt
preview nodes
preview visibility state
current preview cell
current preview validity
preview tint/modulate state
gamepad cursor visual state, if it is only preview-related
remove/unbuild preview state, if it is only visual
```

`BuildSystem` should still own:

```txt
actual placement
actual removal
inventory/cost mutation
TileMapLayer writes
BuildingObjectManager writes
flow/player-blocking updates
terrain speed updates
irrigation cleanup
counter/turret/lamp gameplay side effects
input action interpretation
build mode enable/disable
public API used by UI/tutorial/save-load
```

If ownership is unclear, keep the state in `BuildSystem` and expose a narrow wrapper.

## Do not extract

Do not move or refactor:

```txt
actual building placement
actual building removal
inventory spending/refunding
item definitions/catalog logic
TileMapLayer mutation
BuildingObjectManager mutation
flow-field blocking updates
player blocking updates
building signal handling
irrigation/water cleanup
counter stock behavior
turret/lamp gameplay behavior
save/load behavior
UI menu behavior
tool selection behavior
combat/projectile behavior
```

This pass is only about preview/cursor/visual placement feedback.

## Behavior preservation

Preserve existing behavior exactly:

```txt
same preview position
same preview visibility rules
same valid/invalid feedback
same mouse placement preview
same gamepad placement preview
same remove/unbuild preview
same rotation/flip preview if present
same footprint preview if present
same blocked-cell feedback
same out-of-range feedback
same UI/tool interactions
same actual placement/removal behavior
```

Do not change placement rules.

Do not change build costs.

Do not change item validity.

Do not change collision/blocking behavior.

Do not change how buildings are committed to the map.

## Coupling rule

If preview logic is tightly mixed with placement commit logic, do not extract the whole function blindly.

Instead:

```txt
leave commit logic in BuildSystem
extract pure preview calculation/rendering where safe
add small wrapper methods if needed
report remaining coupling
```

If the extraction requires rewriting actual placement/removal, stop and report the coupling instead of expanding the task.

## GDScript strict typing

Godot/GDScript strict typing is enabled.

Avoid `:=` inference for:

```txt
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

Do not continue into placement/removal/inventory/UI logic because the code is nearby.

## Before coding, report

```txt
Owner:
Caller:
State owned:
Public API:
Files changed:
Estimated lines moved:
Preview state ownership decision:
BuildSystem state intentionally kept:
Thin wrappers to preserve:
Couplings found:
Risk:
```

Then implement only the build preview / placement cursor extraction.

## Final report

After implementation, report:

```txt
What moved:
What stayed in BuildSystem:
Preview state ownership decision:
Thin wrappers kept:
Files changed:
Remaining risks:
Manual test checklist:
Recommended next step:
```
