# CPathLib

CPathLib is a reusable Godot GDExtension for two-dimensional grid navigation and optional crowd
motion. Its portable C++ core does not depend on Godot; the `godot/` directory is a thin adapter.

Features include:

- weighted eight-direction A* with corner-cut prevention;
- synchronous and asynchronous shared flow fields;
- wall clearance and static bottleneck analysis;
- optional explicit or seeded navigation areas with directional portals;
- typed routes across world, portal, and local-area segments;
- capacity, priority, timeout, direction, and fairness controls for bottlenecks;
- optional crowd agents, separation, terrain speed, impulses, control suppression, and external
  velocities;
- arbitrary rectangular grids, cell sizes, cell origins, and world origins.

## Ownership and dependencies

`area/`, `bottleneck/`, `core/`, `crowd/`, `flow/`, `grid/`, `jobs/`, `pathfinding/`, and
`steering/` form the portable library. They must not include `godot_cpp` or depend on a host game.
`godot/` may depend on the portable library. Nothing in CPathLib may depend on code outside this
directory except `godot-cpp` and the C++ standard library.

The public Godot classes are:

- `NavigationWorld2D`: grid topology, paths, flow fields, areas, portals, and asynchronous work;
- `NavigationRoute2D`: an immutable typed route result;
- `CrowdWorld2D`: optional instance-owned crowd simulation and bottleneck reservations.

## Local Windows build

The current supported workflow uses Godot 4.6.1, its matching `godot-cpp` checkout, and MinGW-w64.
In this project, run from `extensions/CPathLib/` in an MSYS2 MinGW64 shell:

```sh
scons target=template_debug use_mingw=yes godot_cpp_dir=../../../godot-cpp
```

In a standalone checkout with `godot-cpp` beside CPathLib, omit `godot_cpp_dir`. The build writes
`bin/cpathlib.dll`. The descriptor expects the MinGW runtime DLLs beside it.

## Minimal use

```gdscript
var navigation: NavigationWorld2D = NavigationWorld2D.new()
add_child(navigation)
navigation.configure_grid(
    Rect2i(0, 0, 20, 12),
    32.0,
    Vector2.ZERO,
    walkable_cells,
    physical_wall_cells
)

var path: PackedVector2Array = navigation.find_path_cells(
    Vector2i(1, 1),
    Vector2i(18, 10)
)
navigation.build_flow_to_cell(Vector2i(18, 10))
```

Connect `flow_ready(request_id, status, topology_revision)` before using
`request_flow_to_cell()` for asynchronous work. Results are installed only when their topology and
cost revisions still match the world.

Areas and bottlenecks are optional. Create areas with `create_area()` or the seeded-area API, add
directional portals with `create_portal()`, and request typed enter/exit routes. A crowd can consume
the current shared flow through `use_navigation_flow()` or use per-agent paths/manual directions.

## Verification and demo

Portable test sources are in `tests/`. The two Godot smoke scripts exercise navigation, routes,
asynchronous work, crowd motion, bottleneck reservations, and forces. `demo/navigation_demo.tscn`
shows the same features without requiring a TileMap, autoload, or prescribed scene hierarchy.

See [REUSE.md](REUSE.md) for the standalone-repository checklist and API stability rules.
