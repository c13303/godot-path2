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
  arrival/recovery policies, impulses, resistance, control suppression, and external velocities;
- generational static circular obstacles with avoidance and hard depenetration;
- per-agent sparse directional-motion fields with exact and radius-fallback sampling;
- filtered circle, cone, AABB, and navigation-cell queries, optional per-agent query AABBs, and
  neutral per-agent diagnostics;
- delayed and prioritized impulses, generational external-velocity sources, contact pressure,
  and traffic right-of-way;
- generational circle/cone effect volumes with enter, tick, and exit events;
- pooled projectiles with swept static/agent collision and neutral impact events;
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
- `ProjectileWorld2D`: optional pooled projectile simulation and neutral impact reporting.

## Local Windows build

Windows with MinGW-w64 is the only supported platform. There is no Linux or macOS build, and no
MSVC build is exercised. The workflow is Godot 4.5.1 with a matching `godot-cpp` checkout; the
descriptor declares `compatibility_minimum = "4.5"`.

In this project, run from `extensions/CPathLib/` in an MSYS2 MinGW64 shell:

```sh
scons target=template_debug use_mingw=yes godot_cpp_dir=../../../godot-cpp
```

In a standalone checkout with `godot-cpp` beside CPathLib, omit `godot_cpp_dir`. The build writes
`bin/cpathlib.dll` for either target, so a release build overwrites a debug one. The descriptor
resolves its library and the three MinGW runtime DLLs relative to itself, so the folder can be
dropped anywhere in a project.

### Pinned `godot-cpp`

| | |
| --- | --- |
| revision | `b262298503e4a768caed4b8277beb6b972334f28` |
| branch | `4.5` |
| dated | 2026-04-28 |

Rebuild against this revision when reproducing a released binary. Update this table in the same
commit that changes the checkout, so the recorded revision and the committed DLL never disagree.

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

For interaction logic, configure per-agent contact pressure and optional traffic group tokens on
`CrowdWorld2D`. Circle, cone, and AABB queries return category-filtered generational handles, and
`apply_impulse_batch()` submits explicit velocities through the same delayed, prioritized impulse
pipeline. External velocities use world-owned generational source handles so stale sources cannot
be refreshed after removal.

Effect volumes are optional circle or cone regions. They can follow an agent, filter categories,
emit neutral enter/tick/exit records, and optionally submit fixed or radial impulses. Caller tokens
let the consumer associate events with its own rules without putting those rules in CPathLib.

`ProjectileWorld2D` owns reusable projectile-type handles and fixed-size pools. Connect it to a
`CrowdWorld2D`, upload a static collider-mask grid, then spawn projectiles with optional inherited
velocity, owner handle, and caller token. Swept collision produces agent, static-collider, or
lifetime-expiry records. Agent sweeps use the profile's optional query AABB, falling back to its
world radius. Force-isolated agents are omitted from projectile targeting. The consuming project
decides what each impact means.

Navigation areas are optional sub-regions with their own local routing. Create one explicitly with
`create_area()` or flood-fill it from a seed with `create_area_from_seed()`, edit it with
`set_area_cells()` / `set_area_target_cells()`, add directional multi-cell portals with
`create_portal()`, inspect it with `get_area_info()` / `get_area_handles()`, and request typed
enter/exit routes with `plan_enter_area()` / `plan_exit_area()` — or the `*_with_options()` forms to
select blocker channels for that request. A crowd can consume the current default flow through
`use_navigation_flow()` or use flow handles, per-agent paths, and manual directions.

`garden_*` is a complete alias set over the same API, named for the first consuming project. Every
alias is a one-line forwarder with no behavior of its own, kept so that project keeps working.
**Prefer the area names in new code**; the aliases may be dropped in a future major version.

## Verification and demo

Build the library and the portable unit tests:

```sh
scons target=template_debug use_mingw=yes godot_cpp_dir=../../../godot-cpp tests
```

`tests` is an alias, not the default target, so a bare `scons` still builds only the library. The
unit tests link the simulation modules directly and need no engine:

```sh
bin/test_a_star_solver.exe
bin/test_flow_field_algorithms.exe
```

The Godot smoke scripts are `SceneTree` programs. Each exits 0 on success, 1 on the first failure,
and must be run one per process:

```sh
godot --headless --path <project> --script res://<addon-path>/tests/navigation_world_2d_smoke.gd
godot --headless --path <project> --script res://<addon-path>/tests/crowd_world_2d_smoke.gd
godot --headless --path <project> --script res://<addon-path>/tests/projectile_world_2d_smoke.gd
```

They exercise navigation, routes, asynchronous work, crowd motion, bottleneck reservations, forces,
effect volumes, and projectiles. `demo/navigation_demo.tscn` shows the same features without
requiring a TileMap, autoload, or prescribed scene hierarchy.

In this project, `../../check.sh` builds everything and runs all of the above plus the project's own
boundary smokes in one command.

**These checks verify the library against itself.** They cannot see a consuming project mapping one
of its values onto the wrong field — that failure mode belongs to the consumer, and a consumer
should keep its own boundary tests. See `scripts/native/migration_parity_smoke.gd` in this project
for a worked example.

See [REUSE.md](REUSE.md) for the standalone-repository checklist and API stability rules.
