Review `scripts/map/buildsystem.gd` after the recent extractions:

* `BuildPreviewController`
* `BuildPlacementService`
* `BuildRemovalService`
* `BuildDragController`
* `BuildInputController`

Goal: perform one focused extraction: move build-mode state and tool/item selection state into a dedicated controller.

Do not run Godot, tests, compilation, export, or build commands. I will test manually.

## Target

Create a focused state controller, for example:

```txt id="i9yczg"
scripts/map/build_mode_state_controller.gd
```

Use another clear name only if it better matches the existing project style.

## Why this extraction

`BuildSystem` should coordinate build subsystems, but it should not directly own all build-mode state.

The next coherent responsibility is:

```txt id="d9u2q6"
Track whether build mode is active, which build/remove/tool mode is selected, which item is selected, and how state resets when mode/tool/item changes.
```

This is separate from:

```txt id="ykpb7k"
input routing
preview rendering
placement commit
removal commit
drag processing
UI menu rendering
inventory mutation
TileMap mutation
```

This is architectural cleanup, not line-count cleanup.

## Candidate responsibility to move

Move only build-mode and selection state.

Candidate areas to inspect and possibly extract:

```txt id="c5janl"
build mode active/inactive state
current selected tool
current selected build item
current selected item definition/cache
current target layer/type derived from selection
remove/unbuild mode state
rotation/flip state if it is selection/mode state
mode reset on cancel
mode reset on item switch
mode reset on tool switch
public getters for current selection
public setters called by UI/tool menu
state validation when selected item becomes unavailable
```

Move only functions/state that are clearly mode/selection state.

If a function mixes UI, input, and mode state, extract only the state mutation/query part and leave UI/input routing in their existing controllers.

## Desired boundary

`BuildSystem` may keep:

```gdscript id="1r1qrl"
var _build_mode_state: BuildModeStateController = BuildModeStateController.new()
```

Initialize it with:

```gdscript id="8uwryq"
_build_mode_state.setup(self)
```

if this matches the current controller/service pattern and keeps the patch smaller.

Existing public methods on `BuildSystem` may remain as thin wrappers.

Examples:

```gdscript id="4lhha9"
func is_build_mode_active() -> bool:
	return _build_mode_state.is_build_mode_active()

func set_build_mode_active(active: bool) -> void:
	_build_mode_state.set_build_mode_active(active)

func get_selected_build_item_id() -> String:
	return _build_mode_state.get_selected_item_id()

func set_selected_build_item_id(item_id: String) -> void:
	_build_mode_state.set_selected_item_id(item_id)
```

Thin wrappers are acceptable and recommended if UI/tutorial/input code already calls `BuildSystem`.

Do not rewrite the whole call graph just to remove wrappers.

## Ownership rule

`BuildModeStateController` may own:

```txt id="2r549y"
build mode active flag
current tool/mode enum or string
selected build item id
selected item definition cache, if currently present
remove/unbuild mode flag
rotation/flip selection state, if currently present
state reset rules
state query helpers
selection validity checks
```

`BuildSystem` should still own:

```txt id="hzoky4"
subsystem orchestration
preview controller
placement service
removal service
drag controller
input controller
TileMap references
BuildingObjectManager references
inventory/cost mutation through services
UI-facing compatibility wrappers
save/load coordination
```

If ownership is unclear, keep the state in `BuildSystem` and expose a narrow wrapper.

## Boundary with BuildInputController

`BuildInputController` may query mode/selection state:

```txt id="pe7wct"
is build mode active?
is removal mode active?
what tool is selected?
what item is selected?
```

It may request state changes through wrappers:

```txt id="wp3h90"
cancel build mode
switch tool
toggle remove mode
```

But input controller should not own mode/selection state.

## Boundary with BuildPreviewController

`BuildPreviewController` may query:

```txt id="4x2zb0"
selected item id
selected target layer
selected rotation/flip
is remove mode active
```

But preview controller should not own selected item/mode state.

## Boundary with placement/removal services

Placement/removal services may query selection state:

```txt id="s0pgp8"
selected item id
current item definition
selected target layer
rotation/flip state
```

But they should not own selection state.

## Do not extract

Do not move or refactor:

```txt id="bvm2pt"
input event routing
preview/cursor rendering internals
actual placement commit rules
actual removal commit rules
drag processed-cell state
shop/build menu UI
save/load behavior
combat/projectile behavior
player movement
BuildingManager behavior
inventory/cost mutation except through existing APIs
TileMap mutation except through existing services
```

This pass is only about build-mode and selection state.

## Behavior preservation

Preserve existing behavior exactly:

```txt id="ix10jr"
same build mode enter behavior
same build mode exit/cancel behavior
same selected tool behavior
same selected item behavior
same remove/unbuild mode behavior
same state reset when switching tools/items
same preview refresh after state changes
same input behavior after state changes
same UI-facing public methods
same tutorial/save-load compatibility if any
same placement/removal results
```

Do not change input bindings.

Do not change placement/removal rules.

Do not change preview visuals.

Do not change UI menu behavior.

Do not change inventory/cost behavior.

## Compatibility rule

If other scripts call `BuildSystem` methods for build mode or selected item state, keep those methods as wrappers.

Do not break `has_method(...)` / `call(...)` compatibility if it exists.

Before coding, search for external callers of build-system public methods related to:

```txt id="v21mow"
build mode
selected item
selected tool
remove mode
unbuild mode
rotation
cancel build
```

Update only if necessary. Prefer preserving wrapper methods on `BuildSystem`.

## Coupling rule

If state is deeply mixed with UI or input code, do not extract the whole function blindly.

Instead:

```txt id="n275gq"
leave UI/input behavior in existing files/controllers
extract only the state mutation/query part
use small wrappers
report remaining coupling
```

If the extraction requires rewriting UI, input, placement, removal, preview, inventory, or save/load behavior, stop and report the coupling instead of expanding the task.

## GDScript strict typing

Godot/GDScript strict typing is enabled.

Avoid `:=` inference for:

```txt id="pd8i9g"
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

Do not continue into UI, input, preview, placement, removal, drag, inventory, or save/load redesign because the code is nearby.

## Before coding, report

```txt id="kngdnp"
Owner:
Caller:
State owned:
Public API:
Files changed:
Estimated lines moved:
Mode/selection state ownership decision:
BuildSystem state intentionally kept:
Thin wrappers to preserve:
External callers found:
Couplings found:
Risk:
```

Then implement only the build-mode / selection-state extraction.

## Final report

After implementation, report:

```txt id="pa7hbu"
What moved:
What stayed in BuildSystem:
Mode/selection state ownership decision:
Thin wrappers kept:
Files changed:
Remaining risks:
Manual test checklist:
Recommended next step:
```
