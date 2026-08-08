# Rabbit Game native compatibility manifest

This manifest protects Rabbit Game while the reusable navigation core is extracted. A public native
API remains supported until its direct calls, dynamic calls, scene wiring, and manual scenarios have
been migrated deliberately.

## Registered classes

| Class | Current ownership classification | Migration direction |
|---|---|---|
| `PathfinderNative` | compatibility adapter | wrap portable `ffcore::AStarSolver` |
| `NavigationWorld2D` | reusable generic adapter | stable generic navigation boundary |
| `NavigationRoute2D` | reusable generic result | typed area-route segments |
| `CrowdWorld2D` | reusable generic adapter | stable generic crowd/motion boundary |
| `FlowFieldNative` | Rabbit compatibility | keep current TileMap/group/debug behavior |
| `SpatialGridNative` | Rabbit compatibility | keep existing scene/API wiring |
| `SteeringSystemNative` | Rabbit compatibility/gameplay | keep current numerical update and gameplay APIs |
| `AgentManagerNative` | Rabbit compatibility/gameplay | keep current IDs, groups, and orchestration |
| `GlobalConfigNative` | compatibility adapter | instance-owned generic configuration |
| `ProjectileSystemNative` | Rabbit-owned gameplay | keep outside reusable navigation API |

The extension entry point remains `flowfield_library_init`. The default build defines
`REFINED_NAV_RABBIT_COMPAT` and registers every old class. A reusable-only build omits these seven
compatibility/gameplay registrations while retaining the three generic classes.

## A* compatibility contract

`PathfinderNative` remains a Godot `Node` registered under the same name. Its bound API is:

| Method | Contract |
|---|---|
| `set_walkable_tiles(cells)` | replaces the complete walkable set; converts packed `Vector2` coordinates to integers; duplicates collapse |
| `set_blockers(cells)` | replaces the complete blocker set; duplicates collapse |
| `find_path(from_tile, to_tile)` | returns `PackedVector2Array`, including both endpoints, or empty when invalid/unreachable |
| `walkable_count()` | returns the number of unique walkable cells |
| `blocker_count()` | returns the number of unique blocker cells, including blockers outside the walkable set |

Behavior preserved by the extracted solver:

- eight-direction movement with cardinal cost `1` and diagonal cost `sqrt(2)`;
- octile heuristic;
- diagonal corner cutting is forbidden when either adjacent cardinal cell is not open;
- blockers override walkability;
- identical open endpoints return a one-cell path;
- invalid or unreachable endpoints return an empty array;
- each setter replaces, rather than patches, its previous set;
- negative and sparse cell coordinates are supported;
- direction enumeration, score comparison, and path reconstruction order are unchanged.

Known callers and wiring:

- `mainRun.tscn` contains the `CPP/PathfinderNative` node and exports its NodePath to
  `BuildingManager`;
- `BuildingPathService` dynamically checks/calls `find_path`, `set_walkable_tiles`, and
  `set_blockers`;
- garden-local paths, whole-map paths, sheep paths, builder placement, client tantrums, and daytime
  visitor movement consume paths through `BuildingPathService` or its manager wrapper;
- `walkable_count()` and `blocker_count()` are public but no current GDScript call site was found.

## A* verification scenarios

Automated portable checks cover open diagonal routing, corner-cut prevention, blockers, setter
replacement, invalid endpoints, identical endpoints, duplicate cells, and negative coordinates.

Headless Godot compatibility should verify that the extension loads, `PathfinderNative` is
registered, all five methods exist, packed-array conversion is unchanged, and the main project
starts without native registration errors.

Manual gameplay checks after A* extraction:

- an agent enters a garden and reaches a plant;
- an agent leaves a garden using its local path;
- sheep errands still route around blockers;
- daytime visitors enter and leave normally;
- builder placement and client attack-path selection still find reachable cells;
- blocked or deleted garden paths fail safely without new warnings/errors.

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
They are compiled only when `rabbit_compat=yes`, which remains the default.

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
