# Rabbit Game native compatibility manifest

This manifest protects Rabbit Game while the reusable navigation core is extracted. A public native
API remains supported until its direct calls, dynamic calls, scene wiring, and manual scenarios have
been migrated deliberately.

## Registered classes

| Class | Current ownership classification | Migration direction |
|---|---|---|
| `PathfinderNative` | compatibility adapter | wrap portable `ffcore::AStarSolver` |
| `FlowFieldNative` | mixed | generic core plus Rabbit adapter |
| `SpatialGridNative` | generic adapter | generic spatial index adapter |
| `SteeringSystemNative` | mixed | generic crowd/motion core plus Rabbit adapter |
| `AgentManagerNative` | mixed | generic agent storage plus Rabbit orchestration |
| `GlobalConfigNative` | compatibility adapter | instance-owned generic configuration |
| `ProjectileSystemNative` | Rabbit-owned gameplay | keep outside reusable navigation API |

The extension entry point remains `flowfield_library_init` during the in-project migration.

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
- flow-direction selection, clearance blending, and direction quantization;
- bottleneck detection and zone annotation;
- async queue ownership, request serials, group generations, and result installation;
- group pools, debug drawing, and Rabbit Game compatibility methods.

## Remaining inventory

Before extracting each later subsystem, extend this manifest with its complete bound methods,
properties, signals, defaults, dynamic calls, lifecycle, threading, update order, and representative
before/after behavior fixtures. Flow fields and steering are the highest-risk areas because they
currently combine algorithms, asynchronous state, Godot lifecycle, global configuration, and Rabbit
Game behavior.
