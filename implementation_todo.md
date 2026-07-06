Review the current `scripts/map/building_manager.gd` after the recent extractions:

* `GardenTopologyService`
* `GardenRetargetController`
* `SpawnerRouteService`
* `GardenAccessScorer`
* `BuildingScanService`
* `AgentSuspendService`
* `MonsterDeathController`
* client/merchant/harvest/tantrum controllers
* debug telemetry

Goal: perform one focused extraction: move runtime agent navigation phase bookkeeping out of `BuildingManager`.

Do not run Godot, tests, compilation, export, or build commands. I will test manually.

## Target

Create a focused controller:

```txt
scripts/map/agent_navigation_phase_controller.gd
```

Use another clear name only if it better matches the existing project style.

## Why this extraction

`BuildingManager` should coordinate high-level systems, but it should not directly own all runtime agent phase dictionaries and per-frame phase processing.

This controller owns the runtime movement/phase layer:

```txt
entry flow -> A*-in path -> plant/counter arrival -> eating/payment -> escape flow -> despawn
```

This is separate from:

```txt
garden topology
garden retargeting
spawner routes
spawn tick logic
client sale phase
monster death/drop handling
agent suspend/resume
```

This is architectural cleanup, not line-count cleanup.

## Candidate state to move

Move only runtime navigation/phase state if practical:

```gdscript
_eating_agents
_escaping_agents
_entry_path_agents
_astar_in_agents
_client_counter_agents
```

Move these only if the controller becomes the clear owner.

If moving `_client_counter_agents` creates too much client/payment coupling, keep it in `BuildingManager` for this pass and use wrappers.

Do not move retarget queue/index state if it is now owned by `GardenRetargetController`.

Do not move route caches if they are owned by `SpawnerRouteService`.

## Candidate functions to move

Move only agent navigation phase processing and bookkeeping.

Candidate functions:

```gdscript
_process_eating_agents
_process_astar_in_arrivals
_process_plant_arrivals
_process_escape_arrivals
_process_client_counter_arrivals

_assign_agent_to_garden_entry_flow
_assign_agent_to_astar_in
_assign_agent_to_escape
_clear_agent_navigation_records

_start_agent_eating
_erase_eating_agent
_consume_plant

_start_client_payment
_start_client_counter_payment
_finish_client_purchase
_try_client_early_counter_fetch
```

Also inspect nearby small helpers, but do not broaden the extraction.

If a function is too coupled to client payment, counter stock, or UI animation, keep it in `BuildingManager` and expose a narrow wrapper.

## Desired boundary

`BuildingManager` may keep:

```gdscript
var _agent_navigation_phases: AgentNavigationPhaseController = AgentNavigationPhaseController.new()
```

Initialize it with:

```gdscript
_agent_navigation_phases.setup(self)
```

if this matches the current controller/service pattern and keeps the patch smaller.

Thin wrappers in `BuildingManager` are acceptable and recommended.

Examples:

```gdscript
func _process_eating_agents(delta: float) -> void:
	_agent_navigation_phases.process_eating_agents(delta)

func _process_plant_arrivals() -> void:
	_agent_navigation_phases.process_plant_arrivals()

func _assign_agent_to_escape(agent: Node2D) -> bool:
	return _agent_navigation_phases.assign_agent_to_escape(agent)

func clear_agent_navigation_records(nav_id: int) -> void:
	_agent_navigation_phases.clear_agent_navigation_records(nav_id)
```

Do not rewrite the whole manager call graph just to remove wrappers.

## Ownership rule

`AgentNavigationPhaseController` may own:

```txt
entry path agent records
A*-in agent records
eating agent records
escaping agent records
client counter walking records, if practical
per-frame phase arrival checks
transition from entry flow to A*-in
transition from A*-in to plant/counter/eating
transition from eating/payment to escape
transition from escape arrival to cleanup/despawn
navigation record cleanup
```

`BuildingManager` should still own:

```txt
phase orchestration
night/client preparation
garden topology service
garden retarget controller
spawner route service
garden access scorer
spawn tick controller
plant manager signal wiring
counter stock manager, unless a narrow wrapper is enough
client sale controller
client tantrum controller
seed merchant controller
monster death controller
agent suspend service
debug telemetry
save/load facade
tutorial-facing public API
```

If ownership is unclear, keep the state/function in `BuildingManager` and expose a narrow wrapper.

## Boundary with GardenRetargetController

`GardenRetargetController` may request:

```txt
clear stale path
assign agent to garden entry flow
assign agent to escape
query whether nav_id is eating/escaping/astar-in
erase astar-in records
```

But do not merge retargeting into the phase controller.

Retargeting answers:

```txt
Where should this agent go next?
```

Navigation phase controller answers:

```txt
What phase is this agent currently in, and how do we transition it?
```

Keep those separate.

## Boundary with SpawnerRouteService

The phase controller may use route service through manager wrappers to:

```txt
get entry flow group
get escape flow group
check route readiness
query nearest reachable exit
```

It must not own route caches, route groups, or flow-field rebuilds.

## Boundary with GardenTopologyService

The phase controller may query topology through manager wrappers:

```txt
plant cell validity
garden id lookup
garden target data
counter access cells
```

It must not build, validate, mutate, or erase gardens.

## Boundary with client/counter logic

Client payment/counter logic is coupled to navigation.

Acceptable first-pass options:

Option A, broader:
Move client counter walking and payment transitions into the phase controller.

Option B, safer:
Keep payment/counter-stock/UI animation functions in `BuildingManager`, and only let the phase controller call wrappers such as:

```gdscript
manager.start_client_payment(agent, plant_cell)
manager.start_client_counter_payment(agent, counter_cell)
manager.finish_client_purchase(agent)
manager.try_client_early_counter_fetch(agent)
```

Prefer Option B if the payment/UI coupling makes the extraction too large.

Do not move `CounterStockManager` in this pass.

## Do not extract

Do not move or refactor:

```txt
garden topology
garden retargeting
spawner route ownership
spawn tick behavior
spawn playlist behavior
night/client preparation state machines
client sale phase
seed merchant phase
morning harvest phase
monster death/drop logic
agent suspend/resume
building scan
save/load behavior
tutorial behavior
debug/telemetry
counter stock manager internals
UI money animation internals
```

This pass is only about runtime agent navigation phases and their records.

## Behavior preservation

Preserve existing behavior exactly:

```txt
same entry-flow assignment
same A*-in assignment
same A*-in arrival detection
same plant arrival behavior
same client early counter fetch behavior
same eating timer behavior
same consume-plant behavior
same client plant payment behavior
same client counter payment behavior
same escape assignment
same escape arrival/despawn cleanup
same clear navigation records behavior
same interaction with retarget queue
same interaction with drowning/turret suspend
same invalid/dead agent cleanup behavior
same lag warning context values
```

Do not tune movement.

Do not change target selection.

Do not change route selection.

Do not change plant consumption.

Do not change client payment.

Do not change escape behavior.

## Critical compatibility rule

If other systems currently call these methods on `BuildingManager`, keep thin wrappers:

```gdscript
_assign_agent_to_escape
_assign_agent_to_garden_entry_flow
_assign_agent_to_astar_in
_clear_agent_navigation_records
_erase_astar_in_agent
_erase_eating_agent
_process_eating_agents
_process_plant_arrivals
_process_escape_arrivals
```

Do not break `call(...)` / `has_method(...)` compatibility if it exists.

## Per-frame processing rule

Preserve the existing `_process()` order unless there is a concrete bug.

The controller should be called from the same points where the old methods ran.

Do not reorder:

```txt
eating / trampling
turret eating
drowning
astar-in arrivals
plant arrivals
client counter arrivals
escape arrivals
garden retarget queue
spawn tick / client sale / seed merchant
```

If preserving order requires thin wrappers, keep wrappers.

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

Do not create generic utility files.

Do not continue into retargeting, topology, routes, combat, or UI because the code is nearby.

If this extraction requires deep changes to those systems, stop and report the coupling instead of expanding the task.

## Before coding, report

```txt
Owner:
Caller:
State owned:
Public API:
Files changed:
Estimated lines moved:
Navigation phase state ownership decision:
Manager state intentionally kept:
Thin wrappers to preserve:
Couplings found:
Risk:
```

Then implement only the agent navigation phase extraction.

## Final report

After implementation, report:

```txt
What moved:
What stayed in BuildingManager:
Navigation phase state ownership decision:
Thin wrappers kept:
Files changed:
Remaining risks:
Manual test checklist:
Recommended next step:
```
