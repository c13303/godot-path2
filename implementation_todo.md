We are continuing the BuildingManager cleanup.

Goal:
Batch 8 = reduce unsafe private-manager coupling in `scripts/map/building_runtime_tick_controller.gd` only, while preserving behavior and runtime update order exactly.

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
`BuildingManager._process(delta)` has been extracted into:

`scripts/map/building_runtime_tick_controller.gd`

The new controller is small and organized, but it still directly accesses many `BuildingManager` private fields/methods through `_manager._xxx`.

Main objective:
Reduce the most unsafe private coupling in `BuildingRuntimeTickController` without changing runtime order or moving major state ownership.

Before editing:
1. Inspect `building_runtime_tick_controller.gd`.
2. Count `_manager._` references.
3. Categorize each private access as:
   - runtime guard state
   - timing/scan state
   - service/controller access
   - queue/count debug access
   - domain processing method
   - debug/telemetry-only access
4. Only replace accesses where the clean replacement is obvious.

Do not try to eliminate every `_manager._xxx` call.

Priority 1 — service/controller access:
Where `BuildingRuntimeTickController` directly accesses a manager-owned service/controller, prefer an explicit public getter on `BuildingManager`.

Examples:

Before:

```gdscript
_manager._turret_eating_controller.process_turret_eating_agents(delta)
_manager._drowning_controller.process_drowning_agents(delta)
_manager._client_sale.process(delta)
_manager._seed_merchant.process_phase()

After:

_manager.get_turret_eating_controller().process_turret_eating_agents(delta)
_manager.get_drowning_controller().process_drowning_agents(delta)
_manager.get_client_sale_controller().process(delta)
_manager.get_seed_merchant_controller().process_phase()

Only add getters that are actually used.

Getter names should be explicit and typed.

Example:

func get_drowning_controller() -> DrowningController:
	return _drowning_controller

Priority 2 — runtime guard state:
Replace direct reads like:

_manager._flow_ready
_manager._startup_ready
_manager._paused
_manager._night_preparing
_manager._client_preparing

with intention-revealing public methods if simple.

Possible wrappers:

func is_runtime_ready_for_building_tick() -> bool:
	return _flow_ready and _startup_ready

func should_skip_building_runtime_tick() -> bool:
	return _paused or _night_preparing or _client_preparing

Use names that match the current behavior.
Do not change the guard semantics.

Priority 3 — scan timer:
_scan_timer is mutable tick state.

Do not expose it as a raw public variable.

Either:

keep it as private manager access for now, or
move the scan timer responsibility into BuildingRuntimeTickController only if this is clearly safe and does not change behavior.

Conservative recommendation:
For this pass, keep _scan_timer access unless the move is trivial and low-risk.

Priority 4 — debug count access:
For debug-only counters like:

_manager._eating_agents.size()
_manager._astar_in_agents.size()
_manager._escaping_agents.size()
_manager._entry_path_agents.size()

prefer small read-only count wrappers if they already exist or are easy to add.

Possible wrappers:

func eating_agent_count() -> int:
	return _eating_agents.size()

func astar_in_agent_count() -> int:
	return _astar_in_agents.size()

func escaping_agent_count() -> int:
	return _escaping_agents.size()

func entry_path_agent_count() -> int:
	return _entry_path_agents.size()

Only add these if they meaningfully reduce repeated private access.

Priority 5 — domain processing methods:
Methods like:

_manager._process_eating_agents(delta)
_manager._process_creature_rose_trampling()
_manager._process_pasteque_trampling()
_manager._process_astar_in_arrivals()
_manager._process_plant_arrivals()
_manager._process_escape_arrivals()

may remain private for now unless a clear public wrapper already exists.

Do not move these methods in this pass.
Do not extract new services in this pass.
Do not change update order.

Compatibility:
Do not remove existing private methods.
Do not rename existing methods unless all call sites are safely updated.
Do not delete wrappers.
This pass is about safer access boundaries, not deletion.

Expected result:

BuildingRuntimeTickController has fewer _manager._xxx accesses.
Service/controller accesses use typed getters.
Runtime guard state is accessed through explicit methods if safe.
Debug count access is reduced through read-only wrappers if useful.
Runtime update order is unchanged.
No gameplay behavior changes.
No new service unless absolutely necessary.
No file grows over 1000 lines.

Safety checks by reading/searching only:

Count _manager._ references before and after.
Verify runtime update order is unchanged.
Verify all new getters/wrappers are typed.
Verify no public/signal/Callable/call method was removed.
Verify no lifecycle callback was changed.
Verify no queue-drain order changed.
Verify no lag/debug timing label changed.
Verify strict typing in all changed code.

Output required:

List changed files.
Give before/after _manager._ count in building_runtime_tick_controller.gd.
List new public getters/wrappers added to BuildingManager.
Explain which private accesses were intentionally retained and why.
Confirm runtime update order was preserved.
Confirm no behavior changes were intended.
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