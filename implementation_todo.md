Review `scripts/map/buildsystem.gd` after the recent `BuildPreviewController` extraction.

Goal: perform one focused extraction: move actual building placement / commit logic into a dedicated service.

Do not run Godot, tests, compilation, export, or build commands. I will test manually.

## Target

Create a focused placement service, for example:

```txt id="r46fkp"
scripts/map/build_placement_service.gd
```

Use another clear name only if it better matches the existing project style.

## Why this extraction

`BuildSystem` should coordinate build mode and input, but it should not directly own every detail of committing an item to the world.

After preview extraction, the next coherent responsibility is:

```txt id="ep4pgz"
Given a selected item and target cell:
validate placement, spend/refund resources if applicable, write the building/plant/tile/object, and trigger side effects.
```

This is separate from:

```txt id="gd094b"
preview rendering
cursor movement
tool selection
UI menus
removal/unbuild
combat
save/load
```

This is architectural cleanup, not line-count cleanup.

## Candidate responsibility to move

Move only actual placement / commit behavior.

Candidate areas to inspect and possibly extract:

```txt id="emsp1g"
place current selected item
place wall
place plant
place furniture/building
place lamp
place turret/blocking building
write to TileMapLayer
write to BuildingObjectManager
consume inventory item or cost
apply terrain speed multiplier
set player blocking cell
notify BuildingManager/building signals
mark navigation/topology dirty
handle multi-cell or drag placement commits, if present
```

Move only functions/state that are clearly placement-commit related.

If a function both handles input and commits placement, split only the commit part and leave input interpretation in `BuildSystem`.

## Desired boundary

`BuildSystem` may keep:

```gdscript id="d2r30n"
var _placement_service: BuildPlacementService = BuildPlacementService.new()
```

Initialize it with:

```gdscript id="682ydu"
_placement_service.setup(self)
```

if that matches the current controller/service pattern and keeps the patch smaller.

Thin wrappers in `BuildSystem` are acceptable.

Example:

```gdscript id="m66sji"
func _try_place_selected_item(cell: Vector2i) -> bool:
	return _placement_service.try_place_selected_item(cell)
```

Do not rewrite the whole `BuildSystem` call graph just to avoid wrappers.

## Ownership rule

`BuildPlacementService` may own:

```txt id="del9px"
placement validation for commit
placement commit result
selected item placement dispatch
TileMapLayer/object-manager write path
inventory/cost consumption for placement
placement side effects
blocking/speed/topology updates caused by placement
```

`BuildSystem` should still own:

```txt id="cwp4nc"
build mode enable/disable
input handling
mouse/gamepad cursor interpretation
preview controller
tool/item selection
drag state, unless it is strictly placement commit state
removal/unbuild logic
UI-facing public API
save/load coordination
```

If ownership is unclear, keep the state in `BuildSystem` and expose a narrow wrapper.

## Do not extract

Do not move or refactor:

```txt id="5smn4p"
preview/cursor rendering
actual removal/unbuild
refund logic for removal
tool selection UI
shop/build menu UI
save/load behavior
combat/projectile behavior
player movement
irrigation cleanup caused by removal
broad BuildingManager behavior
counter stock internals
```

This pass is only about placement commit.

## Behavior preservation

Preserve existing behavior exactly:

```txt id="ogfssy"
same placement validity rules
same allowed/blocked cells
same layer chosen for each item
same inventory/cost behavior
same wall placement behavior
same plant placement behavior
same furniture/lamp placement behavior
same turret/blocking building placement behavior
same terrain speed update behavior
same player blocking update behavior
same navigation/topology dirty behavior
same building signals/callbacks
same drag-placement result
same error/failure behavior
```

Do not change placement rules.

Do not change costs.

Do not change item definitions.

Do not change blocking/collision semantics.

Do not change preview behavior.

Do not change removal behavior.

## Boundary with preview

`BuildPreviewController` answers:

```txt id="yx9t0w"
What cell is targeted?
What does the ghost/preview show?
Does the placement look valid/invalid?
```

`BuildPlacementService` answers:

```txt id="5v2je9"
Can this item actually be placed here?
If yes, commit it to the world and apply side effects.
```

Do not merge preview back into placement.

If placement currently relies on preview validity, keep that behavior but avoid making preview the source of truth unless it already was.

## Boundary with removal

Do not move removal/unbuild in this pass.

If placement and removal share tiny helpers, keep them in `BuildSystem` for now or extract only if they are pure and clearly placement-safe.

Do not create a generic build utility dumping ground.

## Boundary with inventory/cost

If inventory/cost mutation is tightly coupled, move only the placement-side calls.

Do not redesign inventory.

Do not redesign build costs.

Do not change how UI quantities update.

If needed, keep inventory updates as manager/buildsystem wrapper calls.

## Coupling rule

If actual placement is deeply mixed with input, preview, removal, or UI code, do not extract the whole function blindly.

Instead:

```txt id="i6mnff"
leave input/UI/removal code in BuildSystem
extract only the placement commit core
add small wrapper methods if needed
report remaining coupling
```

If the extraction requires rewriting removal, UI, save/load, or item catalog behavior, stop and report the coupling instead of expanding the task.

## GDScript strict typing

Godot/GDScript strict typing is enabled.

Avoid `:=` inference for:

```txt id="eg8x08"
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

Do not continue into removal, preview, UI, or inventory redesign because the code is nearby.

## Before coding, report

```txt id="qhadum"
Owner:
Caller:
State owned:
Public API:
Files changed:
Estimated lines moved:
Placement state ownership decision:
BuildSystem state intentionally kept:
Thin wrappers to preserve:
Couplings found:
Risk:
```

Then implement only the placement commit extraction.

## Final report

After implementation, report:

```txt id="srupw8"
What moved:
What stayed in BuildSystem:
Placement state ownership decision:
Thin wrappers kept:
Files changed:
Remaining risks:
Manual test checklist:
Recommended next step:
```
