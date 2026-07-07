We are continuing the BuildingManager cleanup.

Goal:
Batch 7 = review and harden the new runtime tick architecture after extracting `BuildingManager._process()`, without broad new extraction.

This is a refactor-only / audit-hardening pass.
Do not change gameplay behavior.
Do not optimize logic unless required to preserve behavior or prevent obvious architecture regression.
Do not run Godot, tests, export, build, or compilation commands.

Project rules:
- Godot/GDScript strict typing is enabled.
- Avoid `:=` inference for numeric expressions, Dictionary/Array values, signal/call returns, mixed int/float math, nullable values, and dynamic values.
- Prefer explicit local types.
- Keep files readable.
- Do not create or grow 1000+ line files.
- Do not create generic abstractions without immediate use.
- Do not perform a broad rewrite.
- Preserve behavior exactly.
- If unsure, keep the existing code and report it.

Current context:
Previous batch extracted the frame runtime orchestration from:

`scripts/map/building_manager.gd::_process(delta)`

into something like:

`scripts/map/building_runtime_tick_controller.gd`

Now we need to verify that the extraction did not simply move the noodle loop into a new god file.

Main objective:
Make sure `BuildingRuntimeTickController` is a readable runtime coordinator, not a new dumping ground.

Before editing:
1. Inspect `scripts/map/building_runtime_tick_controller.gd`.
2. Inspect `scripts/map/building_manager.gd::_process(delta)`.
3. Get line counts for both files.
4. List all methods in `BuildingRuntimeTickController`.
5. Identify all direct `_manager._xxx` calls in the runtime tick controller.
6. Identify whether the controller contains real domain logic or only orchestration.

Do not edit before completing this review.

Expected good state:
`BuildingRuntimeTickController` should mostly do this:

```txt
- check frame/runtime gates
- call existing services/controllers in the existing order
- preserve lag/debug timing
- preserve queue-drain order
- preserve phase-specific runtime updates

It should not own:

- garden topology algorithms
- spawn placement logic
- agent retargeting algorithms
- turret-eating internals
- drowning internals
- client-sale internals
- harvest internals
- save/load logic
- building scan internals
- large debug-overlay logic

Primary task:
If the runtime tick controller now contains small chunks of real domain logic that clearly belong to existing services, move those chunks to the existing owner.

Examples:

- turret eating logic -> TurretEatingController
- drowning logic -> DrowningController
- garden retarget queue internals -> GardenRetargetController
- spawn ticking internals -> SpawnTickController
- client sale ticking internals -> ClientSaleController
- seed merchant ticking internals -> SeedMerchantController
- debug telemetry logic -> BuildingDebugTelemetry / debug service
- building scan internals -> BuildingScanService

Important:
Do not create new services unless absolutely necessary.
Prefer moving logic into existing owners.
If the runtime tick controller only has orchestration and method calls, do not extract anything.

Secondary task:
Reduce only the most obvious unsafe _manager._private calls in BuildingRuntimeTickController.

Allowed improvements:

Replace direct manager-private calls with existing public wrappers if they already exist.
Add small public wrappers on BuildingManager only when the name makes ownership clearer.
Replace calls with direct calls to the owning service if the service is already exposed safely.

Do not attempt to eliminate all _manager._xxx calls.
Do not introduce a generic context object.
Do not create a service locator.
Do not move major state ownership in this pass.

Good replacement example:

Before:

_manager._garden_retarget.process_queue(delta)

After, if available:

_manager.process_garden_retarget_queue(delta)

or:

_manager.get_garden_retarget_controller().process_queue(delta)

Only do this when it improves clarity.

Bad replacement:

_manager.get_everything_context().garden_retarget.process_queue(delta)

Do not do that.

Runtime tick controller structure:
If useful, organize process(delta) into small private methods inside the controller, but only by frame-stage.

Good:

func process(delta: float) -> void:
	if _should_skip_runtime_tick():
		return

	_process_day_runtime(delta)
	_process_navigation_runtime(delta)
	_process_agent_runtime(delta)
	_process_phase_runtime(delta)
	_process_debug_runtime(delta)

Only do this if it improves readability and preserves order.

Bad:

func _process_everything_related_to_agents_and_gardens_and_clients(delta: float) -> void:
	...

Keep method names explicit and ordered.

Order preservation:
The exact update order from Batch 6 must be preserved.

If splitting process(delta) into stage methods, add short comments that make the order obvious.

Example:

# Keep this before spawn ticks: removed/retargeted agents must settle first.

Only add comments where order matters.

Anti-noodle guard:
Add a short comment at the top of building_runtime_tick_controller.gd explaining its boundary.

Example:

# Coordinates per-frame runtime updates for BuildingManager.
# This controller should preserve update order and delegate domain logic to focused services.
# Do not add new gameplay algorithms here; add them to the owning service/controller.

Do not over-comment obvious code.

BuildingManager:
BuildingManager._process(delta) should remain tiny.

Acceptable:

func _process(delta: float) -> void:
	_runtime_tick_controller.process(delta)

or with minimal guards if that was intentionally preserved.

Do not move runtime logic back into BuildingManager.

Expected result:

BuildingRuntimeTickController is clearly an orchestration coordinator.
It does not become a new god object.
Any obvious misplaced domain logic is moved to existing owners.
The most obvious unsafe private manager calls are reduced if easy.
BuildingManager._process(delta) remains tiny.
No new file over 1000 lines.
No gameplay behavior changes.

Safety checks by reading/searching only:

Verify runtime update order is unchanged from Batch 6.
Verify all moved helper methods are still called.
Verify no queue-drain order changed.
Verify no phase guard changed.
Verify no lag/debug timing label changed.
Verify no public/signal/Callable/call method was removed.
Verify strict typing in all changed code.
Verify no new circular dependency or preload path typo.
Verify no new service was created unless clearly justified.

Output required:

List changed files.
Give line counts for:
building_manager.gd
building_runtime_tick_controller.gd
Summarize whether the runtime tick controller is orchestration-only or still contains domain logic.
List any logic moved out of the runtime tick controller.
Show before/after _manager._ private-call count in the runtime tick controller.
Confirm runtime update order was preserved.
Mention any private coupling intentionally retained.
Mention remaining production-quality concerns.
Mention manual test scenarios.

Manual test scenarios to suggest:

Start the game and reach day phase.
Start a normal night.
Spawn monsters from multiple spawners.
Let monsters target plants, eat, and exit.
Place/remove buildings during day.
Verify building scan/invalidation still runs.
Verify turret eating, drowning, trampling, and retargeting still run.
Run client phase if applicable.
Enable debug overlays/telemetry if available.
Verify no new warnings/errors appear.