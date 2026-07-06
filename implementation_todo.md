Review the current build-system code after the recent `BuildModeStateController` extraction.

Recent state:

```txt id="ssob76"
BuildModeStateController now owns _build_direction and selected_placeable_def()
BuildSystem still keeps DIRECTION_* constants for fence autotiling and _alternative_from_direction
BuildPlacementService still has its own _is_directional_placeable / _alternative_from_direction logic
get_preview_direction() remains a BuildSystem wrapper for turret_system.gd
```

Goal: perform one focused extraction: centralize build direction / orientation rules into a small shared helper/service.

Do not run Godot, tests, compilation, export, or build commands. I will test manually.

## Target

Create a focused helper/service, for example:

```txt id="f7erhf"
scripts/map/build_direction_rules.gd
```

or:

```txt id="m2ho16"
scripts/map/build_orientation_service.gd
```

Use the clearest name for the existing project style.

## Why this extraction

Direction/orientation rules are now duplicated across build state and placement code.

The next coherent responsibility is:

```txt id="7cphru"
Given an item definition and a build direction:
determine whether the item is directional,
cycle direction forward/backward,
convert direction to tile alternative/rotation data,
and expose shared direction constants.
```

This is separate from:

```txt id="4mce86"
build mode state
input routing
preview rendering
placement commit
removal commit
drag processing
UI selection
TileMap mutation
```

This is a cleanup extraction, not a behavior change.

## Candidate responsibility to move

Move only direction/orientation rules.

Candidate duplicated or related code to inspect:

```gdscript id="rh09n4"
DIRECTION_*
_is_directional_placeable
_next_build_direction
_prev_build_direction
_alternative_from_direction
selected-placeable direction composition, only if pure
direction-to-alternative mapping used by placement
direction queries used by preview/turret range preview
```

Move only pure direction/orientation logic.

Do not move selected item ownership, build mode state, input handling, preview nodes, or placement commit rules.

## Desired boundary

Possible design:

```gdscript id="arh67h"
class_name BuildDirectionRules
extends RefCounted
```

With pure/static or instance methods such as:

```gdscript id="ctlsce"
func is_directional_placeable(item_def: Dictionary) -> bool
func next_direction(direction: int) -> int
func previous_direction(direction: int) -> int
func alternative_from_direction(direction: int) -> int
func normalize_direction(direction: int) -> int
```

Static methods are acceptable if that fits the project style.

A `RefCounted` instance is also acceptable if it better matches existing controllers.

## Ownership rule

`BuildDirectionRules` may own:

```txt id="wja443"
DIRECTION_* constants
direction cycling rules
direction normalization
directional-placeable detection
direction -> TileMap alternative mapping
```

`BuildModeStateController` should still own:

```txt id="gqqmbu"
current _build_direction value
rotate_selected_build_direction()
selected_placeable_def() composition
state reset behavior
```

`BuildPlacementService` should still own:

```txt id="smax0z"
actual placement commit
TileMap writes
item placement validation
inventory/cost mutation
placement side effects
```

`BuildSystem` should still own:

```txt id="qhk8eh"
compatibility wrappers
subsystem orchestration
public API used by turret_system.gd / input / UI
fence autotiling call sites, unless only the direction mapping is moved
```

If ownership is unclear, keep the state/function where it is and only centralize the pure helper logic.

## Required compatibility

Keep these existing public/wrapper methods working:

```gdscript id="xjn0p1"
rotate_selected_build_direction()
get_preview_direction()
_selected_placeable_def()
```

Do not break external callers such as:

```txt id="v8h05z"
turret_system.gd
BuildInputController
BuildDragController
BuildPreviewController
BuildPlacementService
```

Prefer wrappers over broad caller rewrites.

## Behavior preservation

Preserve existing behavior exactly:

```txt id="j8zlhf"
same direction order
same forward rotation
same backward rotation
same behavior for non-directional items
same selected_placeable_def result
same preview direction
same turret range preview direction
same TileMap alternative chosen during placement
same fence autotiling behavior
same mouse wheel / R / gamepad rotate behavior
```

Do not change rotation semantics.

Do not change tile alternatives.

Do not change item definitions.

Do not change preview.

Do not change placement.

Do not change input bindings.

## Boundary with BuildModeStateController

`BuildModeStateController` should call the new direction rules helper for:

```txt id="ny8byf"
is this selected item directional?
next direction
previous direction
```

But it should continue to own the mutable current direction.

Do not move `_build_direction` into the rules helper.

## Boundary with BuildPlacementService

`BuildPlacementService` should call the new direction rules helper for:

```txt id="7q7vce"
directional-placeable detection
direction -> alternative mapping
```

Do not duplicate `_is_directional_placeable` or `_alternative_from_direction` in the placement service after this pass, unless there is a concrete incompatibility that you must report.

## Boundary with BuildSystem

`BuildSystem` may keep `DIRECTION_*` compatibility constants if external code or inspector usage depends on them.

However, avoid having two independent sources of truth.

Acceptable options:

Option A:

```txt id="s469zd"
Move constants to BuildDirectionRules and have BuildSystem constants alias them if GDScript allows cleanly.
```

Option B:

```txt id="3svcnt"
Keep constants in BuildSystem for compatibility but make all logic call BuildDirectionRules, and report the remaining constant duplication.
```

Prefer Option A if safe. Use Option B if cyclic load/order/strict typing makes aliasing risky.

## Do not extract

Do not move or refactor:

```txt id="xrtnnb"
input routing
preview/cursor rendering
placement commit rules
removal commit rules
drag processed-cell state
build mode active state
selected item/tool state
shop/build menu UI
save/load behavior
combat/projectile behavior
player movement
inventory/cost mutation
TileMap mutation except replacing direction helper calls
```

This pass is only about pure build direction/orientation rules.

## Coupling rule

If direction logic is mixed into placement or preview functions, do not extract the whole function.

Instead:

```txt id="syxm9w"
leave placement/preview logic where it is
extract only the pure direction calculation
replace duplicated helper bodies with calls to BuildDirectionRules
report any duplication intentionally left
```

If this extraction requires rewriting input, preview, placement, removal, UI, or item catalog behavior, stop and report the coupling instead of expanding the task.

## GDScript strict typing

Godot/GDScript strict typing is enabled.

Avoid `:=` inference for:

```txt id="6wss95"
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

Do not create a generic utility dumping ground.

Do not continue into placement, preview, input, drag, UI, inventory, or save/load because the code is nearby.

## Before coding, report

```txt id="nywjdn"
Owner:
Caller:
State owned:
Public API:
Files changed:
Estimated lines moved:
Direction constants ownership decision:
Duplicated helpers found:
BuildSystem compatibility wrappers/constants kept:
Couplings found:
Risk:
```

Then implement only the direction/orientation rules extraction.

## Final report

After implementation, report:

```txt id="ac5eal"
What moved:
What stayed in BuildSystem:
What stayed in BuildModeStateController:
What stayed in BuildPlacementService:
Direction constants ownership decision:
Duplicated helper bodies removed:
Compatibility wrappers kept:
Files changed:
Remaining risks:
Manual test checklist:
Recommended next step:
```
