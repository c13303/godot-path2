We are continuing the BuildingManager cleanup.

Goal:
Batch 9 = reduce unsafe manager coupling between garden retargeting and agent navigation phases, without changing gameplay behavior.

This is a refactor-only pass.
Do not change gameplay behavior.
Do not optimize logic unless required by the boundary cleanup.
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
- If unsure, keep the existing private access and report it.

Current context:
Previous batches reduced `BuildingManager` bloat and extracted runtime ticking.
The next largest coupling hotspot is likely around:

```txt
scripts/map/garden_retarget_controller.gd
scripts/map/agent_navigation_phase_controller.gd
scripts/map/building_manager.gd

These controllers are important and performance-sensitive.
They should not become noodles, but this pass must stay conservative.

Main objective:
Make ownership and communication between garden retargeting and agent navigation phases clearer.

Do not rewrite the garden system.
Do not rewrite pathfinding.
Do not change retarget behavior.
Do not change agent status names.
Do not change queue order.
Do not change per-frame limits.
Do not change fallback behavior.

Before editing:

Inspect garden_retarget_controller.gd.
Inspect agent_navigation_phase_controller.gd.
Inspect related wrappers/accessors in building_manager.gd.
Count _manager._ references in both controllers.
Categorize private accesses as:
- read-only agent collection query
- read-only garden/topology query
- navigation phase mutation
- retarget queue mutation
- route/path lookup
- debug/telemetry only
- compatibility wrapper call
- unclear / keep

Do not edit before this classification.

Primary target:
Reduce direct private access where one extracted controller calls through BuildingManager to reach another extracted controller or its state.

Bad pattern:

_manager._agent_navigation_phases._some_internal_state
_manager._garden_retarget._some_internal_method()
_manager._some_private_agent_collection

Better patterns:

_manager.get_agent_navigation_phase_controller().some_public_method(...)
_manager.get_garden_retarget_controller().some_public_method(...)
_manager.get_agents_waiting_for_navigation_retarget()
_manager.agent_navigation_phase_for(agent)

Only add wrappers/getters that are actually used.

Priority 1 — controller-to-controller access:
If GardenRetargetController needs to update navigation phase state, prefer a typed getter from BuildingManager:

func get_agent_navigation_phase_controller() -> AgentNavigationPhaseController:
	return _agent_navigation_phases

Then call an explicit public method on AgentNavigationPhaseController.

Example method names:

func assign_agent_to_astar_in_phase(agent: Node, path: PackedVector2Array) -> void:
	...

func assign_agent_to_flow_exit_phase(agent: Node, exit_cell: Vector2i) -> void:
	...

func clear_agent_navigation_phase(agent: Node) -> void:
	...

Only create methods that correspond to existing behavior.
Do not invent new phase semantics.

Priority 2 — agent collection access:
If controllers directly read manager-owned dictionaries/arrays of agents, prefer narrow read-only methods or count/query wrappers.

Examples:

func has_eating_agent(agent: Node) -> bool:
	return _eating_agents.has(agent)

func get_agents_targeting_removed_plant(plant_cell: Vector2i) -> Array[Node]:
	...

Do not expose raw dictionaries unless there is no clean alternative.

Avoid:

func get_eating_agents() -> Dictionary:
	return _eating_agents

unless absolutely necessary for compatibility.

Priority 3 — garden/topology queries:
If controllers ask the manager for garden data that actually belongs to GardenTopologyService, prefer calling the topology service through a typed getter or existing public wrapper.

Example:

func get_garden_topology_service() -> GardenTopologyService:
	return _garden_topology

Then use explicit topology query methods.

Good:

_manager.get_garden_topology_service().garden_for_plant_cell(cell)

Bad:

_manager._garden_topology._garden_by_plant_cell[cell]

Do not move garden state ownership in this pass.

Priority 4 — debug-only access:
Debug/telemetry private access can remain if replacing it would add clutter.

Only clean debug access if it is repeated or obviously unsafe.

Do not prioritize debug cleanup over gameplay boundary clarity.

Priority 5 — unclear coupling:
If the clean boundary is not obvious, keep the current private access and report it.

Expected result:

Fewer _manager._xxx references in garden_retarget_controller.gd.
Fewer _manager._xxx references in agent_navigation_phase_controller.gd.
The most dangerous raw mutable state access is replaced by explicit methods.
Controller-to-controller communication is more explicit.
No gameplay behavior changes.
No large new abstraction.
No new service unless absolutely necessary.
No file grows over 1000 lines.

Do not try to reach zero _manager._xxx calls.
A good target is to reduce the most unsafe calls by 25-50%, not eliminate everything.

Strict behavior preservation:
Preserve exactly:

- agent statuses
- queue ordering
- queue limits
- retarget timing
- fallback paths
- garden target selection
- route assignment
- astar-in behavior
- flow-in / flow-out behavior
- escape behavior
- wait/new-status behavior
- debug/lag reporting

Do not change performance characteristics unless the existing code already does the same work through a safer method.

Compatibility:
Do not remove existing private methods.
Do not remove wrappers.
Do not rename public-ish methods.
Do not change scene/signal/callable APIs.
Do not delete dead code in this pass.

This is not a pruning pass.

Suggested workflow:

Count _manager._ references in both target files.
Classify each access.
Pick the highest-value unsafe accesses.
Add narrow typed getters/wrappers where useful.
Replace only safe call sites.
Keep unclear/private/debug-only access unchanged.
Re-count _manager._ references.
Report what remains.

Safety checks by reading/searching only:

Verify all changed method signatures.
Verify no agent status string changed.
Verify no queue order changed.
Verify no per-frame limit changed.
Verify no route/path fallback changed.
Verify no save/load structure changed.
Verify no signal/Callable/call method was removed.
Verify no scene/editor reference was broken.
Verify strict typing in all changed code.

Output required:

List changed files.
Give before/after _manager._ count for:
garden_retarget_controller.gd
agent_navigation_phase_controller.gd
List new getters/wrappers added to BuildingManager.
List new public methods added to controllers.
Explain which private accesses were replaced and why.
Explain which private accesses were intentionally retained and why.
Confirm no behavior changes were intended.
Mention remaining production-quality concerns.
Mention manual test scenarios.

Manual test scenarios to suggest:

Start a normal night.
Spawn monsters from multiple spawners.
Let monsters target plants, eat, and exit.
Remove a plant while monsters are targeting it.
Remove/place buildings that affect navigation.
Verify agents enter waiting/retarget states correctly if applicable.
Verify astar-in arrivals still work.
Verify flow-in / flow-out behavior still works.
Verify garden targeting/retargeting still works.
Verify no new warnings/errors appear.