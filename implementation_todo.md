We are continuing the BuildingManager cleanup.

Goal:
Batch 6 = extract the frame runtime orchestration from `scripts/map/building_manager.gd::_process()` into a focused controller, while preserving behavior exactly.

This is a refactor-only pass.
Do not change gameplay behavior.
Do not optimize logic unless required by the extraction.
Do not run Godot, tests, export, build, or compilation commands.

Project rules:
- Godot/GDScript strict typing is enabled.
- Avoid `:=` inference for numeric expressions, Dictionary/Array values, signal/call returns, mixed int/float math, nullable values, and dynamic values.
- Prefer explicit local types.
- Keep files readable.
- Do not create or grow 1000+ line files.
- Do not create generic abstractions without immediate use.
- Preserve behavior exactly.
- If unsure, keep the existing logic and report it.

Current context:
`BuildingManager` has been progressively converted into a façade/coordinator.
Major areas already extracted include:
- preparation orchestration
- agent spawning
- rose counter/shop logic
- debug/query helpers
- some private-coupling cleanup

Remaining issue:
`BuildingManager._process(delta)` still acts as a central noodle loop.
It coordinates many runtime systems in one frame update.

This pass must extract that loop into a dedicated controller without changing update order, guards, timing, or side effects.

Create a new file:

`scripts/map/building_runtime_tick_controller.gd`

Suggested shape:

```gdscript
extends RefCounted
class_name BuildingRuntimeTickController

var _manager: Node = null

func setup(manager: Node) -> void:
	_manager = manager

func process(delta: float) -> void:
	# moved runtime update sequence here

Main responsibility:
Own the frame-by-frame runtime update sequence currently inside BuildingManager._process(delta).

The controller may coordinate existing services/controllers, but it should not own unrelated domain state.

Expected BuildingManager._process(delta) after extraction:
Keep it very small. Ideally:

func _process(delta: float) -> void:
	if not _runtime_tick_controller:
		return
	_runtime_tick_controller.process(delta)

However, if the existing _process() has important startup/flow/phase guards, either:

keep the guards in BuildingManager._process() and delegate only the active runtime body; or
move the full guard/body sequence into the controller.

Choose whichever preserves behavior most clearly.

Important:
Do not reorder runtime steps.

Before editing:

Inspect the current BuildingManager._process(delta) completely.
Write down the current execution order.
Identify every guard/early-return.
Identify every timing/lag/debug measurement.
Identify every state mutation.
Identify every service call.
Only then move the body.

The extracted controller must preserve the existing order, including anything like:

- startup/flow readiness gates
- night/client/preparation gates
- morning harvest processing
- building scan processing
- route queue drains
- eating agent processing
- plant/rose/pasteque trampling processing
- turret eating processing
- drowning processing
- astar-in arrival processing
- plant arrival/eating processing
- client counter arrival processing
- tantrum processing
- merchant proximity processing
- escape arrival processing
- garden retarget queue processing
- spawn tick processing
- client sale processing
- seed merchant processing
- debug visibility/overlay updates
- frame lag detection/reporting

The exact list must come from the current code, not from this prompt.

Behavior preservation:

Do not change frame update order.
Do not change which systems run during day/night/client phases.
Do not change early-return behavior.
Do not change pause/preparation behavior.
Do not change async assumptions.
Do not change debug/lag threshold behavior.
Do not change process timing labels.
Do not change any queue-drain limits.
Do not change agent status transitions.
Do not change spawn timing.
Do not change eating/trampling/drowning/turret behavior.
Do not change client sale or seed merchant behavior.
Do not change the exact methods called unless replacing with equivalent wrappers.

Compatibility:
Keep _process(delta) in BuildingManager.
Do not rename _process.
Do not delete any methods used by the moved loop.
Do not remove wrappers unless they are obviously dead and unrelated. Wrapper deletion is not a goal of this pass.

Manager-private coupling:
For this pass, it is acceptable for BuildingRuntimeTickController to call existing manager-private methods/fields if that is required to preserve behavior and avoid a broad rewrite.

But:

Do not introduce unnecessary new private coupling.
Prefer existing public wrappers if they already exist.
Do not attempt a large private-coupling cleanup in this pass.
Report retained _manager._private coupling.

Setup:
Add the new controller as a member in BuildingManager, following the existing service/controller style.

Example:

const BuildingRuntimeTickControllerScript := preload("res://scripts/map/building_runtime_tick_controller.gd")

var _runtime_tick_controller: BuildingRuntimeTickController = BuildingRuntimeTickController.new()

or match the existing preload/instantiation style used in the file.

In _ready():

_runtime_tick_controller.setup(self)

Place setup near other runtime controllers.

Expected result:

BuildingManager._process(delta) becomes a small delegate/gate.
The runtime update sequence lives in BuildingRuntimeTickController.
BuildingManager loses a large central noodle block.
Update order and behavior are unchanged.
No new file over 1000 lines.
No unrelated cleanup.

Optional cleanup:
If there are tiny helper methods used only by _process() and clearly part of runtime ticking, they may be moved with the loop.

Only move helpers if:

they are not used elsewhere;
direct search proves this;
moving them reduces coupling;
behavior remains identical.

Do not move helpers if they are shared by other systems or likely used dynamically.

Safety checks by reading/searching only:

Search for _process( to ensure only the Godot callback remains where expected.
Search every helper moved from BuildingManager.
Search .gd, .tscn, and .tres for moved method names if deleting wrappers.
Verify _runtime_tick_controller.setup(self) is called before _process() can use it.
Verify all called methods still exist.
Verify strict typing in the new controller.
Verify no lifecycle callback was renamed or removed.
Verify no signal/Callable/call target was removed.
Verify no save/load or public compatibility API changed.

Output required:

List changed files.
Give building_manager.gd line count before and after.
Summarize the exact runtime sequence moved.
Confirm _process(delta) remains as the Godot callback.
Confirm update order was preserved.
Mention any helpers moved with the loop.
Mention any retained _manager._private coupling.
Mention manual test scenarios.

Manual test scenarios to suggest:

Start the game and reach day phase.
Start a normal night.
Spawn monsters from multiple spawners.
Let monsters target plants, eat, and exit.
Place/remove buildings during day if supported.
Verify building scan/invalidation still runs.
Verify turret eating, drowning, trampling, and retargeting still run.
Run client phase if applicable.
Enable debug overlays/telemetry if available.
Verify no new warnings/errors appear.