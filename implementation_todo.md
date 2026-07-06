Review the current `scripts/map/building_manager.gd` after the recent `GardenTopologyService` extraction.

Goal: perform one focused extraction: move garden retarget / waiting-agent reassignment logic out of `BuildingManager`.

Do not run Godot, tests, compilation, export, or build commands. I will test manually.

## Target

Create a focused retarget controller:

```txt id="3tzfdy"
scripts/map/garden_retarget_controller.gd
```

Use another clear name only if it better matches the existing project style.

## Why this extraction

`GardenTopologyService` now owns garden structure.

The next separate responsibility is:

```txt id="hc3esp"
When garden topology or plant content changes, decide which agents have stale targets, park them safely, queue them, and retarget/escape them within a frame budget.
```

This is not garden topology. It is runtime agent reassignment.

This is architectural cleanup, not line-count cleanup.

## Candidate state to move

Move only retarget/waiting-agent state.

Candidate state:

```gdscript id="6yx67q"
_garden_retarget_queue
_garden_retarget_queued

_astar_in_agents_by_target_plant
_astar_in_target_by_nav_id
_debug_check_retarget_index

_last_plant_retarget_astar_in
_last_plant_retarget_bucket
_last_plant_retarget_affected
_last_plant_retarget_queued
_last_plant_retarget_stale
_last_plant_retarget_already_queued

_last_retarget_profile
_last_local_retarget_profile
_last_find_local_retarget_profile
_find_path_in_zone_accum
```

Move state only if it is exclusively part of retargeting.

If moving the profiling dictionaries creates too much coupling, keep them temporarily in `BuildingManager` with wrapper methods.

## Candidate functions to move

Move only garden retarget / stale-target / waiting-agent logic.

Candidate functions:

```gdscript id="csz7ub"
_retarget_agents_for_garden_topology_change
_garden_target_is_stale
_clear_stale_garden_path
_retarget_agents_targeting_removed_plant_only
_find_local_retarget_plant
_try_local_retarget_agent
_retarget_agent_or_escape
_retarget_agent_or_escape_impl
_queue_agent_for_garden_retarget
_queue_agents_after_garden_rebuild
_handle_garden_became_empty
_queue_affected_empty_garden_agent
_process_garden_retarget_queue
_retarget_single_waiting_agent
_requeue_waiting_agent

_register_astar_in_target
_unregister_astar_in_target
_set_astar_in_agent
_erase_astar_in_agent

_reset_retarget_profile
_reset_find_path_in_zone_accum
_accumulate_find_path_in_zone
_emit_retarget_breakdown
```

Also inspect nearby small helpers, but do not broaden the extraction.

If `_set_astar_in_agent` / `_erase_astar_in_agent` are too deeply tied to astar-in processing, it is acceptable to keep them in `BuildingManager` and have them call the retarget controller only for target-index registration.

## Desired boundary

`BuildingManager` may keep:

```gdscript id="5n67kp"
var _garden_retarget: GardenRetargetController = GardenRetargetController.new()
```

Initialize it with:

```gdscript id="mb563z"
_garden_retarget.setup(self)
```

if this matches the current controller/service pattern and keeps the patch smaller.

Thin wrappers in `BuildingManager` are acceptable and recommended for this pass.

Examples:

```gdscript id="lm3zub"
func _process_garden_retarget_queue() -> int:
	return _garden_retarget.process_queue()

func _retarget_agents_for_garden_topology_change(cell: Vector2i) -> void:
	_garden_retarget.retarget_agents_for_garden_topology_change(cell)

func _retarget_agent_or_escape(agent: Node2D, spawner_cell: Vector2i) -> void:
	_garden_retarget.retarget_agent_or_escape(agent, spawner_cell)
```

Do not rewrite the whole manager call graph just to remove wrappers.

## Ownership rule

`GardenRetargetController` may own:

```txt id="x5vepj"
retarget queue
queued nav-id set
plant-target reverse index
stale target detection
waiting_new_status parking
local retarget search
agent retarget-or-escape decision
budgeted queue processing
retarget profiling counters
```

`BuildingManager` should still own:

```txt id="bnk90e"
phase orchestration
garden topology service
spawner route service
garden access scorer
agent eating dictionary, unless only referenced through wrappers
agent escaping dictionary, unless only referenced through wrappers
entry-path and astar-in movement processing
plant arrival processing
escape arrival processing
night/client preparation
spawn tick logic
client systems
save/load facade
debug/telemetry
```

If ownership is unclear, keep state in `BuildingManager` and expose a narrow method.

## Boundary with GardenTopologyService

Retarget controller may query garden topology:

```txt id="30ue2m"
garden lookup
plant-to-garden lookup
garden has target
garden targetable/reachable flags
plant zone membership
```

It must not build, validate, erase, or mutate garden topology except through existing manager/topology APIs.

Do not move garden topology back into the retarget controller.

## Boundary with SpawnerRouteService

Retarget controller may request route data:

```txt id="qgpj42"
get/create spawner-garden route
check route readiness
nearest reachable exit escape
```

It must not own route caches or flow-field groups.

Do not move route ownership into retargeting.

## Boundary with agent state machines

Do not extract full eating/escaping/astar-in state machines in this pass.

The retarget controller may coordinate with them through manager wrappers, but do not move:

```gdscript id="vzpdh2"
_process_eating_agents
_process_plant_arrivals
_process_astar_in_arrivals
_process_escape_arrivals
_resume_agent_path
_resume_agent_entry_flow
```

Unless a tiny wrapper is strictly needed.

This pass is not an agent movement rewrite.

## Behavior preservation

Preserve existing behavior exactly:

```txt id="vwrntm"
same retarget queue budget behavior
same garden_retarget_budget_per_frame behavior
same garden_retarget_budget_ms behavior
same waiting_new_status behavior
same local retarget radius behavior
same plant-removal reverse-index behavior
same stale target cleanup
same retarget-or-escape fallback
same handling of empty gardens
same handling of unreachable gardens
same profiling/logging behavior
same lag-warning context values
same no-double-enqueue behavior
same invalid/dead agent cleanup behavior
```

Do not tune retarget priorities.

Do not change target selection.

Do not change pathing behavior.

Do not change flow-field assignment behavior.

## Critical compatibility rule

If other functions still expect to call:

```gdscript id="mi472u"
_set_astar_in_agent
_erase_astar_in_agent
_retarget_agent_or_escape
_process_garden_retarget_queue
```

on `BuildingManager`, keep those methods as thin wrappers.

Do not break internal or external `call(...)` / `has_method(...)` compatibility if it exists.

## Budgeted processing rule

Preserve the existing budgeted queue behavior:

```txt id="n5brn5"
process at least one queued item if possible
stop after count budget if applicable
stop after time budget if applicable
do not process the whole queue in one frame
return processed count for debug logging
```

Do not “simplify” this.

## GDScript strict typing

Godot/GDScript strict typing is enabled.

Avoid `:=` inference for:

```txt id="e7xbs2"
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

Do not create generic utility files.

Do not continue into garden topology, spawner routes, eating, escaping, or astar-in processing because the code is nearby.

If this extraction requires deep changes to those systems, stop and report the coupling instead of expanding the task.

## Before coding, report

```txt id="a80k0t"
Owner:
Caller:
State owned:
Public API:
Files changed:
Estimated lines moved:
Retarget state ownership decision:
Manager state intentionally kept:
Thin wrappers to preserve:
Couplings found:
Risk:
```

Then implement only the garden retarget extraction.

## Final report

After implementation, report:

```txt id="xo15ef"
What moved:
What stayed in BuildingManager:
Retarget state ownership decision:
Thin wrappers kept:
Files changed:
Remaining risks:
Manual test checklist:
Recommended next step:
```
