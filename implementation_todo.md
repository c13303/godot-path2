Review the current `scripts/map/building_manager.gd` after the recent controller extractions.

Goal: perform one focused extraction: move agent suspend/resume logic out of `BuildingManager`.

Do not run Godot, tests, compilation, export, or build commands. I will test manually.

## Target

Create a focused helper/service for temporary agent suspension, for example:

```txt id="f3s8a4"
scripts/map/agent_suspend_service.gd
```

Use another clear name only if it better matches the existing project style.

## Why this extraction

Some systems temporarily take control of an agent, then need to restore its previous movement/path/eating/flow state.

This is currently a shared responsibility used by systems such as:

* drowning
* turret eating
* possibly future grabs/stuns/traps

`BuildingManager` should coordinate these systems, but should not own all suspend/resume internals.

## Candidate logic to extract

Move only temporary agent suspend/resume logic.

Candidate functions:

```gdscript id="vb9dy3"
_suspend_agent_for_drowning
_resume_agent_after_drowning
_suspend_agent_for_turret_eating
_resume_agent_after_turret_eating
_capture_agent_resume_state
_resume_agent_entry_flow
_resume_agent_path
```

Also inspect for small directly-related helpers, but do not broaden the extraction.

Only move a helper if it is clearly part of the suspend/resume responsibility.

## Desired boundary

`BuildingManager` may keep:

```gdscript id="x7vhhf"
var _agent_suspend: AgentSuspendService = AgentSuspendService.new()
```

Initialize it with:

```gdscript id="s5ayww"
_agent_suspend.setup(self)
```

if that matches the current controller pattern.

Existing controllers should call the manager facade or the service through the manager. Keep the patch small.

Acceptable pattern:

```gdscript id="l0ux5e"
func suspend_agent_for_drowning(nav_id: int, agent: Node2D) -> Dictionary:
    return _agent_suspend.suspend_agent_for_drowning(nav_id, agent)
```

or direct internal use:

```gdscript id="n6x94m"
_agent_suspend.suspend_agent_for_drowning(...)
```

Prefer preserving existing public/private method names on `BuildingManager` as thin wrappers if current controllers call them via `call(...)`.

Do not break `has_method(...)` / `call(...)` compatibility.

## Responsibility

The new service owns:

```txt id="j9uw4g"
capturing an agent's resumable state
temporarily stopping/removing movement assignment
restoring previous entry flow
restoring previous path
restoring previous eating/target state only if already part of the old suspend/resume behavior
drowning-specific suspend/resume wrapper logic
turret-eating-specific suspend/resume wrapper logic
```

`BuildingManager` still owns:

```txt id="wnx2wn"
agent registries
garden logic
retarget logic
flow-field routes
night preparation
spawner routes
client systems
drowning controller
turret eating controller
process orchestration
```

The service may call narrow manager methods for existing state operations.

Do not move unrelated state dictionaries into the service unless they are exclusively owned by suspend/resume behavior.

## Do not extract

Do not move or refactor:

```txt id="qg02po"
garden topology
garden retargeting
spawner routes
flow-field ownership
night preparation
client preparation
client sale
spawn tick logic
monster death/drop logic
agent eating state machine
agent escaping state machine
astar-in arrival logic
tutorial behavior
save/load behavior
building scan behavior
debug/telemetry
```

This pass is only about temporary suspend/resume.

## Behavior preservation

Preserve existing behavior exactly:

```txt id="i7c71v"
same suspend timing
same resume timing
same path restoration
same flow-field restoration
same eating-state restoration
same astar-in restoration
same drowning behavior
same turret-eating behavior
same cleanup order
same failure behavior if the agent is invalid
```

Do not add new gameplay behavior.

Do not “improve” the movement logic in this pass.

## GDScript strict typing

Godot/GDScript strict typing is enabled.

Avoid `:=` inference for:

```txt id="c29s07"
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

Keep the patch small and reviewable.

Do not rename unrelated symbols.

Do not reformat unrelated code.

Do not perform broad cleanup.

Do not create generic `utils` files.

Do not continue the refactor just because `BuildingManager` is still long.

If the extraction requires touching garden retargeting, pathfinding internals, or flow-field route ownership deeply, stop and report the coupling instead of continuing.

## Before coding, report

```txt id="xb5jw7"
Owner:
Caller:
State owned:
Public API:
Files changed:
Estimated lines moved:
Why this split is architectural and low-risk:
Couplings found:
Risk:
```

Then implement only this extraction.

## Final report

After implementation, report:

```txt id="e0pi6r"
What moved:
What stayed in BuildingManager:
Files changed:
Remaining risks:
Manual test checklist:
Recommended next step:
```
