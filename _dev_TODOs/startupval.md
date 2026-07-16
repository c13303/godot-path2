# TASK: Fix startup playlist validation after removal of `traversable_buildings`

Read `AGENTS.md` first and follow it strictly.

Do not run Godot, tests, builds, compilation, or exports. I will test manually.

## Context

Only `res://scenes/levels/level_demo.tscn` is currently used.

`level_demo.tscn` is correctly authored. Its node-based spawners and `level_demo_spawn_playlist.tres` bindings are correct.

Do not modify:

* `level_demo.tscn`
* `level_demo_spawn_playlist.tres`
* the authored spawner positions or IDs
* any unused alternative level

Do not recreate a visual `traversable_buildings` TileMapLayer.

## Current launch errors

Playlist validation reports that these correct bindings do not correspond to scanned physical spawners:

```text
monster1 cell=(72, 10)
monster2 cell=(60, 10)
monster3 cell=(29, 73)
monster4 cell=(107, 82)
```

Playlist spawning is then disabled.

## Confirmed root cause

The problem is in:

```text
scripts/map/building_scan_service.gd
```

`scan_buildings()` currently starts approximately like this:

```gdscript
var traversable_buildings: TileMapLayer = _traversable_buildings()
if not traversable_buildings:
    return
```

The `traversable_buildings` TileMapLayer has intentionally been removed:

* `LevelLoader.LEVEL_LAYER_NAMES` no longer imports it.
* `mainRun.tscn` no longer wires it into `BuildingManager`.

However, the obsolete early return prevents the entire building scan from running, including:

```gdscript
scan_configured_spawner_nodes(seen_spawners)
```

As a result, the correct node-derived `SpawnerBinding` objects are never registered into `BuildingManager._spawners`.

`SpawnPlaylistController.configure()` therefore receives an empty or incomplete physical-spawner dictionary and rejects every playlist binding.

## Required fix

Make `BuildingScanService.scan_buildings()` independent from the optional legacy `traversable_buildings` TileMapLayer.

### Required behavior

1. Remove the global early return based on `traversable_buildings`.

2. Always execute the parts of the scan that do not depend on that layer:

   * topology signature calculation
   * configured node-based spawner scanning
   * spawner registration
   * missing-spawner cleanup
   * topology invalidation when actually required

3. Treat `traversable_buildings` as nullable and legacy-only inside this service.

4. Calling:

```gdscript
scan_special_layer(traversable_buildings, seen_spawners)
```

may remain because `scan_special_layer()` is already null-safe, but it must never prevent configured spawners from being scanned.

5. `migrate_special_tiles_from_wallz()` may remain a null-safe no-op when no legacy destination layer exists. Do not recreate the removed layer merely to preserve this obsolete migration path.

6. Update misleading comments that still describe `traversable_buildings` as a required source of spawners. The authoritative level spawners are now the child nodes captured by `LevelLoader` and exposed as `SpawnerBinding` objects.

## Keep the change narrow

Expected main owner:

```text
scripts/map/building_scan_service.gd
```

Only touch another file when directly required for this fix.

Do not:

* weaken or remove playlist validation
* make validation ignore missing physical spawners
* hardcode the four monster cells into code
* bypass `SpawnPlaylistController.configure()`
* manually populate `_spawners` from the playlist
* change the playlist resource
* add fallback offsets or approximate cell matching
* introduce a new service
* perform broad cleanup of every remaining logical `"traversable_buildings"` identifier

The playlist validation is correct and should remain strict. The physical scan must be fixed instead.

## Static verification

Trace this startup sequence after the change:

```text
BuildingManager._sync_runtime_state()
    -> BuildingScanService.scan_buildings()
        -> scan_configured_spawner_nodes()
            -> BuildingManager._register_spawner()
    -> SpawnPlaylistConfigService.validate_after_spawner_scan()
        -> SpawnPlaylistController.configure()
```

Confirm that the four monster bindings are registered before validation:

```text
monster1 -> Vector2i(72, 10)
monster2 -> Vector2i(60, 10)
monster3 -> Vector2i(29, 73)
monster4 -> Vector2i(107, 82)
```

Also confirm that configured client and merchant spawners continue to be registered through the same node-binding scan.

## Acceptance criteria

On launching `level_demo.tscn`:

* No `bound cell does not correspond to a scanned physical spawner` errors.
* No `invalid level spawn playlist` error.
* Playlist spawning remains enabled.
* All four monster spawners are available to the playlist controller.
* Client and merchant spawners are still registered.
* No `traversable_buildings` TileMapLayer is recreated.
* No scene or playlist coordinates are modified.
* Missing or genuinely invalid spawners would still be rejected by the existing strict validation.

## Final report

Report:

1. The exact root cause confirmed in code.
2. Every file changed.
3. The precise control-flow change.
4. Why playlist validation remains strict.
5. Any remaining legacy `traversable_buildings` dependency encountered that is unrelated to this startup bug and was deliberately left untouched.
6. Manual checks I should perform in Godot.
