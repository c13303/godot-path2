# Reusable 2D navigation GDExtension

This folder now contains a game-neutral navigation library and a Rabbit Game compatibility layer.
The generic code can be moved to its own repository without taking Rabbit gameplay with it; the
default build still includes all existing Rabbit native classes so this project keeps its current
scene wiring and behavior.

The reusable API supports:

- deterministic eight-direction A* with corner-cut prevention;
- synchronous and asynchronous shared flow fields;
- wall clearance, physics passability, and static bottleneck analysis;
- explicit or seeded navigation areas and multi-cell directional portals;
- typed world/portal/local route segments with revision-based stale detection;
- capacity, direction, priority, timeout, and fairness for bottleneck traffic;
- instance-owned crowd agents, shared-flow/path/manual steering, separation, terrain speed,
  collision-safe integration, impulses, control suppression, and persistent external velocity;
- non-zero world origins, arbitrary cell origins, rectangular grids, and arbitrary cell sizes.

Areas are the reusable equivalent of Rabbit Game gardens. The generic library knows nothing about
plants, eating, monsters, clients, weapons, damage, projectiles, or gameplay phases.

## Source ownership

The reusable source set is:

```text
area/             area construction, portals, selection, route plans
bottleneck/       static analysis and runtime traffic reservations
core/types.h      portable math and IDs
core/navigation_world.*
crowd/            generic agents, steering, integration, impulses
flow/flow_field.*
flow/flow_field_algorithms.*
flow/flow_field_builder.*
grid/spatial_grid.*
jobs/flow_field_job_queue.*
pathfinding/a_star_solver.*
steering/external_velocity_accumulator.*
steering/terrain_speed_grid.*
godot/navigation_world_2d.*
godot/navigation_route_2d.*
godot/crowd_world_2d.*
```

The following source is Rabbit-owned compatibility code and is excluded by
`rabbit_compat=no`: the old agent manager, global configuration and service singletons,
`FlowFieldNative`, `SteeringSystemNative`, `AgentManagerNative`, `GlobalConfigNative`,
`SpatialGridNative`, `PathfinderNative`, projectile simulation, AoE/damage helpers, Rabbit agent
phases, and the old flow-field manager. See [COMPATIBILITY.md](COMPATIBILITY.md) for why those
wrappers remain in this project.

## Build modes

The supported local configuration is the existing Windows x86-64 MinGW toolchain, Godot 4.6.1,
and the matching sibling `godot-cpp` checkout. No additional build system is required.

From an MSYS2 MinGW64 shell in `extensions/`:

```sh
scons -f Sconstruct target=template_debug use_mingw=yes rabbit_compat=yes
```

`rabbit_compat=yes` is the default and produces this project's current `flowfield.dll`, including
legacy classes. For a clean reusable build in the future standalone repository:

```sh
scons -f Sconstruct target=template_debug use_mingw=yes rabbit_compat=no
```

That mode compiles only the portable core and the three generic Godot classes. Because both modes
currently use the same output filename, rebuild with `rabbit_compat=yes` before running Rabbit Game
after testing the clean mode.

Do not publish `.o`, `.sconsign`, local compiler DLL copies, or temporary binaries. They are build
artifacts. Keep the standalone repository private unless you deliberately choose a license later.

## Install in another Godot game

1. Keep `godot-cpp` at the version matching the target Godot version.
2. Copy or check out this source as a pinned dependency.
3. Build with `rabbit_compat=no`.
4. Copy `flowfield.gdextension`, `bin/flowfield.dll`, and the required MinGW runtime DLLs under the
   destination project's addon directory, preserving the descriptor's relative paths.
5. Add a `NavigationWorld2D`. Add `CrowdWorld2D` only when crowd movement is needed.
6. Upload raw cells with `configure_grid`; a TileMap and specific scene hierarchy are not required.

The extension entry point remains `flowfield_library_init`. Pin both the navigation source commit
and the matching `godot-cpp` commit when the standalone repository is created.

## Minimal Godot API

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

var path: PackedVector2Array = navigation.find_path_cells(Vector2i(1, 1), Vector2i(18, 10))
navigation.build_flow_to_cell(Vector2i(18, 10))
```

For asynchronous flow building, connect `flow_ready(request_id, status, topology_revision)` and
call `request_flow_to_cell`. A result is installed only if its topology and cost revisions are still
current.

Create optional areas with `create_area`, add portals with `create_portal`, and request a typed
`NavigationRoute2D` with `plan_enter_area` or `plan_exit_area`. Each route exposes its segment types
and cells. `is_route_current` detects topology or area edits.

`CrowdWorld2D` uses generational integer handles. Upload the latest shared flow with
`use_navigation_flow`, add agents, select flow/path/manual navigation, and read positions and
velocities in packed batches. Bottleneck access is an explicit reservation: callers pause or
constrain agents that have not been granted access.

## Demo and verification

The standalone demonstration is [demo/navigation_demo.tscn](demo/navigation_demo.tscn). It builds a
raw grid, area, portal, typed route, shared flow, opposing bottleneck traffic, multiple agents, and
an impulse without any Rabbit Game dependency.

Portable tests are in `tests/test_a_star_solver.cpp` and `tests/test_flow_field_algorithms.cpp`.
Godot boundary smoke tests are:

```text
tests/pathfinder_native_smoke.gd       Rabbit compatibility
tests/navigation_world_2d_smoke.gd    generic navigation, route, and async work
tests/crowd_world_2d_smoke.gd          generic crowd and forces
```

The full migration rationale and acceptance constraints remain documented in
[MIGRATION.md](../../MIGRATION.md).
