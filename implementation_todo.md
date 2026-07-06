Review the current `scripts/map/building_manager.gd` after the recent controller/helper/service extractions.

Goal: perform one focused extraction: move garden topology ownership out of `BuildingManager`.

Do not run Godot, tests, compilation, export, or build commands. I will test manually.

## Target

Create a focused topology service:

```txt
scripts/map/garden_topology_service.gd
```

Use another clear name only if it better matches the existing project style.

## Why this extraction

`BuildingManager` should coordinate gameplay phases, but it should not own all garden topology state and rebuild logic.

Garden topology is a coherent responsibility:

```txt
Given plant cells, counter access cells, walkability, and spawner reachability:
build gardens, compute garden geometry, validate targetability, maintain plant-zone caches, and expose garden lookup data.
```

This is architectural cleanup, not line-count cleanup.

## Current responsibility to extract

Move garden topology state and logic only.

Candidate state:

```gdscript
_gardens
_garden_by_plant_cell
_dirty_gardens
_next_garden_id
_gardens_epoch
_gardens_iter_depth
_garden_debug_logs
_pending_empty_gardens
_spawner_reachable_cells
_walkable_map_tiles
_plant_zone_tiles
_plant_zone_margin_tiles
_plant_zone_built
_counter_access_cells
```

Move state only if the topology service clearly owns it.

If moving a variable creates too much coupling, keep it temporarily in `BuildingManager` and expose it through a thin wrapper.

## Candidate functions to move

Move only garden topology / geometry / reachability / plant-zone cache logic.

Candidate functions:

```gdscript
_rebuild_walkable_map_cache_budgeted
_build_gardens_from_plants_budgeted
_validate_gardens_budgeted
_recompute_garden_geometry_budgeted
_recompute_spawner_reachable_cells_budgeted
_rebuild_plant_zone_compatibility_cache_budgeted

_rebuild_walkable_map_cache
_build_plant_zone
_rebuild_plant_zone_from_layer
_build_gardens_from_plants
_validate_dirty_gardens
_recompute_garden_geometry
_recompute_spawner_reachable_cells
_apply_spawner_reachability
_rebuild_plant_zone_compatibility_cache

_create_garden
_erase_garden
_mark_garden_dirty
_add_plant_to_gardens
_remove_plant_from_garden_content_only
_garden_has_target_for_kind
_garden_has_counter_target
_collect_counter_access_cells
```

Also inspect nearby small helpers, but do not broaden the extraction.

## Desired boundary

`BuildingManager` may keep:

```gdscript
var _garden_topology: GardenTopologyService = GardenTopologyService.new()
```

Initialize it with:

```gdscript
_garden_topology.setup(self)
```

if this matches the current controller/service pattern and keeps the patch smaller.

`BuildingManager` may keep thin wrappers for compatibility if many internal call sites still expect old method names.

Examples:

```gdscript
func _build_gardens_from_plants_budgeted(token: int) -> bool:
	return bool(await _garden_topology.build_gardens_from_plants_budgeted(token))

func _validate_gardens_budgeted(token: int) -> bool:
	return bool(await _garden_topology.validate_gardens_budgeted(token))

func _garden_has_target_for_kind(garden_id: int, agent_kind: StringName) -> bool:
	return _garden_topology.garden_has_target_for_kind(garden_id, agent_kind)
```

Thin wrappers are acceptable. Do not rewrite the whole manager call graph just to remove wrappers.

## Ownership rule

`GardenTopologyService` should own:

```txt
garden dictionaries
plant-to-garden mapping
dirty garden set
garden id allocation
garden epoch
garden geometry
garden reachability
plant-zone caches
walkable map cache, if practical
counter access cells, if practical
```

`BuildingManager` should still own:

```txt
phase orchestration
night/client preparation state
spawner registries
spawner route service
garden access scorer
garden retarget queue
agent eating
agent escaping
astar-in logic
spawn tick logic
client systems
save/load facade
debug/telemetry
plant manager signal wiring
zone overlay node wiring
```

If ownership is unclear, keep the state in `BuildingManager` for this pass and expose a wrapper.

## Important boundary with SpawnerRouteService

Garden topology may tell route service when routes must be released or invalidated.

But do not move route ownership back into garden topology.

Acceptable:

```gdscript
manager.release_garden_routes(garden_id)
manager.rebuild_spawner_garden_route_cache()
manager.clear_garden_entry_resolve_cache(reason)
```

or equivalent wrapper calls.

Not acceptable:

```txt
GardenTopologyService owns _spawner_garden_routes
GardenTopologyService creates flow-field groups
GardenTopologyService decides route cache hit/miss behavior
```

Route caches belong to `SpawnerRouteService`.

## Important boundary with GardenAccessScorer

Garden topology may expose garden entry cells.

But it should not own the scoring algorithm for choosing the best access cell if `GardenAccessScorer` already owns that.

Acceptable:

```txt
GardenTopologyService computes entry cell candidates
GardenAccessScorer selects/scorers the best entry for a spawner/source
```

Do not merge `GardenAccessScorer` back into topology.

## Important boundary with retargeting

Do not extract retargeting in this pass.

Garden topology may notify/enable retargeting when topology changes.

But the retarget queue and reassignment logic should stay in `BuildingManager` for now.

Do not move:

```gdscript
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
```

Those belong to a later `GardenRetargetController` extraction.

## Do not extract

Do not move or refactor:

```txt
spawner route ownership
flow-field route cache
garden access scoring
garden retargeting
spawn tick behavior
spawn playlist behavior
night/client preparation state machines
agent eating
agent escaping
astar-in arrival logic
monster death/drop logic
agent suspend/resume
client systems
save/load behavior
tutorial behavior
debug/telemetry
building scan
```

This pass is only about garden topology.

## Behavior preservation

Preserve existing behavior exactly:

```txt
same garden clustering behavior
same GARDEN_LINK_DISTANCE behavior
same wall-aware clustering
same diagonal corner-cut prevention
same plant-zone margin behavior
same garden entry candidate generation
same targetable/reachable behavior
same counter access cells behavior
same spawner reachability behavior
same garden epoch behavior
same dirty garden behavior
same plant-zone debug overlay data
same route invalidation calls
same cache invalidation calls
same night preparation behavior
same client preparation behavior
```

Do not tune garden sizes.

Do not change plant grouping.

Do not change target selection.

Do not change route selection.

Do not change retarget behavior.

## Budgeted async behavior

Preserve the existing budgeted/yielding behavior.

Methods that currently yield per frame must still yield in equivalent places.

Preserve:

```txt
night_preparation_budget_ms behavior
_night_preparation_is_current(token) checks
process_frame yields
false return on stale token
true return on successful completion
```

Do not convert budgeted methods into blocking methods.

## Zone overlay compatibility

The plant-zone overlay may still read data from `BuildingManager`.

If needed, keep wrapper methods on `BuildingManager` so overlay behavior does not change.

Do not refactor the overlay in this pass.

## Public / internal API compatibility

If existing code expects garden-related methods or fields through `BuildingManager`, keep thin wrappers.

Acceptable wrappers:

```gdscript
func _get_garden(garden_id: int) -> Dictionary:
	return _garden_topology.get_garden(garden_id)

func _get_gardens() -> Dictionary:
	return _garden_topology.gardens()

func _plant_zone_contains(cell: Vector2i) -> bool:
	return _garden_topology.plant_zone_contains(cell)
```

Do not expose broad mutable dictionaries unless that is already how the current code works and changing it would make the patch risky.

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

Do not continue into garden retargeting because the code is nearby.

If this extraction requires deep changes to retargeting, spawner routes, flow-field ownership, spawn tick logic, or night/client preparation state machines, stop and report the coupling instead of continuing.

## Before coding, report

```txt
Owner:
Caller:
State owned:
Public API:
Files changed:
Estimated lines moved:
Garden state ownership decision:
Manager state intentionally kept:
Thin wrappers to preserve:
Couplings found:
Risk:
```

Then implement only the garden topology extraction.

## Final report

After implementation, report:

```txt
What moved:
What stayed in BuildingManager:
Garden state ownership decision:
Thin wrappers kept:
Files changed:
Remaining risks:
Manual test checklist:
Recommended next step:
```
