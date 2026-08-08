# Rabbit Game native compatibility manifest

> Superseded for the final one-extension conversion by
> [`../../NATIVE_MIGRATION_CONTRACT.md`](../../NATIVE_MIGRATION_CONTRACT.md). This file remains a
> historical compatibility snapshot until `rabbit_game_native` is deleted.

This manifest protects Rabbit Game while the reusable navigation core is extracted. A public native
API remains supported until its direct calls, dynamic calls, scene wiring, and manual scenarios have
been migrated deliberately.

## Registered classes

| Class | Current ownership classification | Migration direction |
|---|---|---|
| `NavigationWorld2D` | reusable generic adapter | stable generic navigation boundary |
| `NavigationRoute2D` | reusable generic result | typed area-route segments |
| `CrowdWorld2D` | reusable generic adapter | stable generic crowd/motion boundary |
| `FlowFieldNative` | Rabbit compatibility | keep current TileMap/group/debug behavior |
| `SpatialGridNative` | Rabbit compatibility | keep existing scene/API wiring |
| `SteeringSystemNative` | Rabbit compatibility/gameplay | keep current numerical update and gameplay APIs |
| `AgentManagerNative` | Rabbit compatibility/gameplay | keep current IDs, groups, and orchestration |
| `GlobalConfigNative` | compatibility adapter | instance-owned generic configuration |
| `ProjectileSystemNative` | Rabbit-owned gameplay | keep outside reusable navigation API |

The project-owned extension entry point is `rabbit_game_native_library_init`. It registers every
established project class. CPathLib is loaded independently and registers only its three generic
classes.

## A* migration status

The former A* adapter has been removed. `mainRun.tscn` owns a generic `NavigationWorld2D` node and
`BuildingPathService` uploads each sparse walkable/blocker snapshot with
`configure_sparse_grid()`, then calls `find_path_cells()`. The portable solver, movement costs,
corner-cut rule, tie-breaking, endpoint inclusion, negative coordinates, and empty failure result
are unchanged. The generic navigation smoke test covers the sparse upload contract.

## Flow-field extraction: slice 1

The first portable flow-field slice now owns these algorithms for both synchronous and worker
builds:

- cell-to-cell traversal validation;
- diagonal corner-cut prevention;
- per-source directional traversal constraints;
- reverse-Dijkstra integration costs;
- the existing two-pass wall-distance transform.

`FlowFieldNative` remains registered with all existing methods, arguments, defaults, layer setters,
async request behavior, group assignment behavior, debug queries, and scene wiring unchanged. It
still owns Godot TileMap snapshot capture and converts the captured cells into portable core types.

Behavior locked by portable regression tests:

- cardinal cost `1.0` and diagonal cost `1.41421356237`;
- reverse traversal applies a directional constraint to the predecessor/source cell;
- diagonals require both adjacent cardinal cells to be walkable;
- missing goals leave every walkable integration cost unreachable;
- arbitrary and non-zero cell origins work in the distance field;
- walls have zero distance and the legacy distance transform uses `1.4142f` for diagonals.

The following behavior intentionally remains in `FlowFieldNative` for later focused extraction:

- TileMap/layer interpretation and coverage sampling;
- bottleneck detection and zone annotation;
- async queue ownership, request serials, group generations, and result installation;
- group pools, debug drawing, and Rabbit Game compatibility methods.

## Flow-field extraction: slice 2

Portable `FlowFieldAlgorithms` now also owns direction generation for synchronous and asynchronous
builds. The shared algorithm preserves:

- fixed eight-neighbor enumeration and steepest-downhill base selection;
- zero directions for blocked, unreachable, and goal cells;
- wall-distance gradient sampling with the current edge fallback;
- configurable wall-clearance blending;
- 16-division angular quantization before neighbor selection;
- cost-safe final selection, where clearance may break equal-cost ties but cannot select a more
  expensive route;
- cardinal/diagonal score normalization and the existing floating-point constants;
- directional traversal constraints during both base and final selection.

Both synchronous and worker builds now create a portable `FlowFieldBuildRequest` and call the same
`FlowFieldBuilder`. No public method or lifecycle behavior changed.

## Completed generic boundary

The reusable-only source selection contains no Godot dependency below its adapter and no Rabbit
gameplay state. It provides instance-owned worlds, immutable async request data, stale-result
rejection, areas and portals, route plans, static bottleneck analysis, runtime bottleneck traffic,
generic crowd movement, terrain speeds, impulses, and persistent external velocity.

Rabbit Game continues to use its original nodes in `mainRun.tscn`. Their registered names, NodePaths,
methods, signals, defaults, group/agent lifecycle, TileMap interpretation, numerical steering order,
debug queries, projectile behavior, damage events, and gameplay phases were intentionally retained.
They are compiled only into the project-owned `rabbit_game_native` GDExtension.

The old singletons and large steering controller are deliberately retained rather than rewritten in
place: Rabbit Game still calls them extensively, and replacing them with the new generic crowd API
would be a separate gameplay migration with movement-parity risk. They are not part of the reusable
build and cannot leak into a different game.

## Deliberately deferred host migration

Moving `mainRun.tscn` and its GDScript callers from the compatibility classes to the generic classes
is not required for reuse and would risk changing this game's behavior. The compatibility layer can
be removed class by class only after those callers and their manual gameplay scenarios are migrated.
The future repository split and dependency pin are also deferred by owner decision; [REUSE.md](REUSE.md)
documents that mechanical next step.
