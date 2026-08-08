# CPathLib

CPathLib is a reusable Godot GDExtension for two-dimensional grid navigation and optional crowd
motion. Its portable C++ core does not depend on Godot; the `godot/` directory is a thin adapter.

Features include:

- weighted eight-direction A* with corner-cut prevention;
- synchronous and asynchronous shared flow fields;
- generational flow handles for multiple simultaneous destinations;
- independent blocker channels with per-request 64-bit masks;
- independent directional-traversal channels;
- wall clearance and static bottleneck analysis;
- optional explicit or seeded navigation areas with directional portals;
- typed routes across world, portal, and local-area segments;
- capacity, priority, timeout, direction, and fairness controls for bottlenecks;
- optional crowd agents, reusable profiles, cohorts, per-agent flows, separation, terrain speed,
  impulses, control suppression, and external velocities;
- generational static circular obstacles with avoidance and hard depenetration;
- per-agent sparse directional-motion fields with exact and radius-fallback sampling;
- filtered circle and navigation-cell agent queries plus neutral per-agent diagnostics;
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

For independent flows, use `create_flow_to_cell()` or `request_flow_handle_to_cell()`. A flow
handle remains valid until `release_flow()` and rejects stale generations after its slot is reused.
`get_flow_status()` returns pending, ready, unreachable, stale, or cancelled; grid/configuration
changes mark every existing flow stale. Sample a ready flow with `sample_flow()`.

Dynamic topology is uploaded through numbered blocker channels. Each blocker channel declares
whether it affects navigation, physics, or both. Pass a 64-bit channel mask to
`find_path_cells_with_options()`, `create_flow_to_cell_with_options()`, or
`request_flow_handle_to_cell_with_options()` to select the channels for that request. Directional
traversal rules are uploaded independently and selected by channel ID. Editing either kind of
channel invalidates existing flows so stale results cannot silently survive a topology change.
Use `get_flow_diagnostics()` and `get_flow_bottlenecks()` for data-only inspection; presentation
and debug drawing remain the consumer's responsibility.

Crowd profiles and cohorts are also instance-owned generational handles. Create a profile with
`create_profile()`, spawn agents through `add_agent_with_profile()`, and group them using
`create_cohort()` plus `assign_agent_to_cohort()`. Install a navigation flow once with
`install_navigation_flow()`, then attach it to one agent with `follow_flow_handle()` or to all
members with `assign_cohort_flow()`. Profiles are copied into agents only on creation or an
explicit `set_agent_profile()` call, so editing a profile has no hidden effect on active agents.

Crowd environment data is instance-owned as well. Terrain speed channels support individual,
batched, replacement, and clear operations. Static obstacles use generational handles and may be
moved or resized. Directional-motion fields also use generational handles and are assigned directly
to agents; they are distinct from navigation directional-traversal channels. The former supplies a
velocity target during motion, while the latter constrains which grid edges a path or flow may use.
Use `query_agents_in_circle()`, `get_agents_in_navigation_cell()`, and
`get_agent_diagnostics()` for neutral, data-only inspection.

Gardens are the friendly Godot API name for optional navigation areas. Create one explicitly with
`create_garden()` or flood-fill it from a seed with `create_garden_from_seed()`, add directional
multi-cell portals with `create_garden_portal()`, and request typed enter/exit routes. The neutral
`create_area()` names remain aliases over the same store, not a duplicate implementation. A crowd
can consume the current default flow through `use_navigation_flow()` or use flow handles,
per-agent paths, and manual directions.

## Verification and demo

Portable test sources are in `tests/`. The two Godot smoke scripts exercise navigation, routes,
asynchronous work, crowd motion, bottleneck reservations, and forces. `demo/navigation_demo.tscn`
shows the same features without requiring a TileMap, autoload, or prescribed scene hierarchy.

See [REUSE.md](REUSE.md) for the standalone-repository checklist and API stability rules.
