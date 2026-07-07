Task: batched debug / telemetry / overlay cleanup pass to make the map/building codebase easier for coding agents and humans to maintain.

Targets:

* `scripts/map/building_debug_telemetry.gd`
* `scripts/map/building_debug_overlay_controller.gd`, if it exists
* `scripts/map/garden_debug_overlay_controller.gd`, if it exists
* `scripts/map/building_debug_options.gd`, if it exists
* minimal related changes in `scripts/map/building_manager.gd`

Goal:
Reduce hidden coupling with `BuildingManager` in debug, telemetry, and overlay code, without changing gameplay behavior.

This is a cleanup pass, not a feature pass.

Do not optimize.
Do not move broad gameplay behavior.
Do not run Godot, tests, builds, compilation, or exports.

Problem:
Debug and telemetry code should observe and report system state. It should not secretly own gameplay decisions or trigger gameplay side effects through hidden manager calls.

Main objective:
Make debug/telemetry dependencies clearer where safe, while preserving behavior exactly.

Before editing, search inside each target file for:

* `_manager.call(`
* `_manager.get(`
* `_manager.has_method(`
* `_manager.set(`

Also search debug/telemetry/overlay references in `building_manager.gd`.

Classify each usage as:

* manager state read
* debug data lookup
* gameplay method call
* dependency lookup
* compatibility/safety check
* unclear / risky

Clean only the safe ones.

Preferred cleanup order:

1. Replace calls to `BuildingManager` wrappers that simply forward to already-existing services.

2. Cache stable debug dependencies during `setup(...)` when safe.

Possible dependencies, only if already used by the current code:

* `GardenTopologyService`
* `GardenRetargetController`
* `SpawnerRouteService`
* `AgentNavigationPhaseController`
* `BuildingNavigationSyncService`
* `BuildingObjectManager`
* `CounterStockManager`
* `agent_manager`
* `plant_manager`
* `floorz`
* `plantz`

3. Replace known manager method calls with direct typed calls only when the method clearly exists and keeping it on `BuildingManager` is intentional.

4. Add small typed accessors on `BuildingManager` only when this avoids broad churn and makes ownership clearer.

5. Keep `_manager.call(...)`, `_manager.get(...)`, `_manager.has_method(...)`, or `_manager.set(...)` when replacing it would be risky or would require broad behavior movement.

Do not try to remove every manager reference.
The goal is meaningful coupling reduction, not a perfect rewrite.

Ownership rules:

`BuildingDebugTelemetry` should own:

* debug timing counters
* lag detection counters
* telemetry snapshots
* debug logging helpers already assigned to it
* read-only reporting of subsystem state

It should not own:

* gameplay state mutation
* garden topology computation
* retarget processing
* navigation phase transitions
* placement/removal
* spawning
* client/merchant behavior

Debug overlay controllers should own:

* visual debug overlays
* overlay refresh/clear behavior
* converting existing state into debug visuals

They should not own:

* gameplay rules
* topology computation
* retargeting decisions
* placement/removal
* spawn logic
* navigation decisions

Debug options should own:

* exported debug thresholds/options
* debug toggles
* debug display configuration

They should not own:

* gameplay behavior
* telemetry processing
* overlay drawing logic beyond configuration

`BuildingManager` should only:

* wire debug services/controllers
* call debug lifecycle/update hooks
* keep compatibility wrappers when external callers may need them
* expose small accessors when needed

Do not change:

* gameplay behavior
* debug toggle behavior
* lag threshold behavior
* telemetry values
* debug overlay visuals
* debug overlay refresh timing
* debug log text
* performance safeguards
* public method names used by other files
* `.tscn` files

Important regression risks:

* do not make debug code mutate gameplay state
* do not change lag detection thresholds
* do not change when debug logs are emitted
* do not add broad scans in hot paths
* do not add extra per-agent work
* do not change overlay visibility behavior
* do not change exported debug option names

Keep compatibility wrappers in `BuildingManager` if external callers may still need them.

If a hidden manager access cannot be safely replaced, leave it unchanged and explain why in the final report.

Expected result:

* debug / telemetry / overlay files have fewer hidden manager calls where safe
* debug ownership is clearer
* behavior is unchanged
* `BuildingManager` may gain small typed accessors if needed
* no scene files are changed

Final report:

* files changed
* `_manager.call/get/has_method/set` usages removed per file
* dependencies cached or added per file
* usages intentionally left unchanged and why
* any new accessors/wrappers added to `BuildingManager`
* debug ownership clarified per file
* behavior intentionally preserved
* manual test risks
