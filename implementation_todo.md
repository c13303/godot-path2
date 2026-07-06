Review the current `scripts/map/building_manager.gd` after the recent controller/helper extractions.

Goal: perform one focused extraction: move building/spawner scanning and tile-special detection out of `BuildingManager`.

Do not run Godot, tests, compilation, export, or build commands. I will test manually.

## Target

Create a focused scanner/service, for example:

```txt
scripts/map/building_scan_service.gd
```

Use another clear name only if it better matches the existing project style.

## Why this extraction

`BuildingManager` should coordinate gameplay systems, but it should not directly own all low-level map scanning.

Building/spawner scanning is a coherent responsibility:

```txt
Read TileMapLayer / configured spawner nodes, detect special cells, update spawner registries, and report topology changes.
```

This is architectural cleanup, not line-count cleanup.

## Candidate logic to extract

Move only building scan / special tile / spawner registration logic.

Candidate functions:

```gdscript
_load_tile_definitions
_scan_buildings
_scan_configured_spawner_nodes
_scan_special_layer
_migrate_special_tiles_from_wallz
_register_spawner
_log_scan_summary
_atlas_key
_tile_layer_signature
```

Also inspect nearby small helpers, but do not broaden the extraction.

Move related constants/state only if they are exclusively part of scanning:

```gdscript
BUILD_TILES_INDEX_PATH
SPAWNER_KIND_MONSTER
SPAWNER_KIND_CLIENT
SPAWNER_KIND_MERCHANT
EXIT_WALL_ATLAS
_tile_defs_by_atlas
_last_wall_signature
_last_water_signature
_last_blocking_signature
_last_fence_signature
_last_scan_summary
```

Only move a variable if all its reads/writes belong to scan responsibility.

If a variable is used by gameplay systems outside scanning, keep it in `BuildingManager`.

## State ownership rule

The scanner may update these registries, but be careful with ownership:

```gdscript
_spawners
_spawner_kind_by_cell
_spawner_exit_cell_by_cell
_spawner_spot_cell_by_cell
_client_spawners
_client_frequency_by_cell
_merchant_spawners
_spawner_bindings_by_id
```

Preferred safe first-pass boundary:

```txt
BuildingManager keeps ownership of core gameplay registries.
BuildingScanService performs scanning and calls narrow manager methods to register/erase/update entries.
```

Do not move route caches or route ownership into this service.

Do not move:

```gdscript
_spawner_routes
_spawner_garden_routes
_dirty_spawner_escapes
_exit_wall_escapes
_route_cache_hits
_route_cache_misses
```

Those belong to route / flow-field logic, not scanning.

## Desired boundary

`BuildingManager` may keep:

```gdscript
var _building_scan: BuildingScanService = BuildingScanService.new()
```

Initialize it with:

```gdscript
_building_scan.setup(self)
```

if that matches the current helper/controller pattern and keeps the patch smaller.

After extraction, `BuildingManager` should call something like:

```gdscript
_building_scan.load_tile_definitions()
_building_scan.scan_buildings()
```

or keep thin wrappers if many call sites currently use private manager methods:

```gdscript
func _scan_buildings() -> void:
    _building_scan.scan_buildings()
```

Thin wrappers are acceptable if they reduce patch risk.

## Do not extract

Do not move or refactor:

```txt
garden topology
garden access scoring
garden retargeting
spawner route creation
flow-field ownership
night preparation
client preparation
spawn tick logic
agent eating
agent escaping
astar-in logic
monster death/drop logic
agent suspend/resume
client systems
save/load behavior
tutorial behavior
debug/telemetry except scan summary if already part of scanner
```

This pass is only about scanning / special tile detection / spawner registration.

## Behavior preservation

Preserve existing behavior exactly:

```txt
same spawner detection
same spawner kind assignment
same client spawner detection
same merchant spawner detection
same authored node spawner behavior
same legacy tile marker behavior
same migration behavior from wallz to traversable/special layers
same wall/water/blocking/fence signature behavior
same dirty topology detection
same scan summary logging
same playlist validation timing
same route invalidation side effects
```

Do not change how spawners work.

Do not change route initialization.

Do not change night/client preparation.

Do not change spawn playlist behavior.

## Important coupling rule

If scanning currently marks route/topology state dirty, preserve that side effect.

But do not extract the route rebuild itself.

Example acceptable boundary:

```gdscript
manager.mark_navigation_topology_dirty()
manager.mark_spawner_escape_dirty(spawner_cell)
manager.register_scanned_spawner(...)
```

Do not let the scan service directly own flow-field groups or garden routes.

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

Keep the patch small and reviewable.

Do not rename unrelated symbols.

Do not reformat unrelated code.

Do not perform broad cleanup.

Do not create generic `utils` files.

Do not continue into spawner routes just because the code is nearby.

If this extraction requires major changes to route caches, flow-field ownership, garden logic, or spawn playlist behavior, stop and report the coupling instead of continuing.

## Before coding, report

```txt
Owner:
Caller:
State owned:
Public API:
Files changed:
Estimated lines moved:
Registry ownership decision:
Why this split is architectural and bounded:
Couplings found:
Risk:
```

Then implement only this extraction.

## Final report

After implementation, report:

```txt
What moved:
What stayed in BuildingManager:
Registry ownership decision:
Files changed:
Remaining risks:
Manual test checklist:
Recommended next step:
```
