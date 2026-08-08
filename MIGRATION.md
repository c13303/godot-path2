# Migration plan: reusable C++ pathfinding GDExtension library

## Review status and governing constraints

### Current transition state

The reusable foundation exists in `extensions/CPathLib`, but the conversion is not complete.
`extensions/rabbit_game_native` and its second DLL are temporary migration input, not an accepted
project-owned extension. The final architecture has one generic CPathLib source tree, descriptor,
entry point, and DLL. All native algorithms move into generic instance-owned CPathLib facilities;
only gameplay composition and presentation remain in Godot scripts.

Current completion summary:

| Boundary | Status |
|---|---|
| portable algorithms and initial generic Godot adapters | partial in `extensions/CPathLib` |
| standalone MinGW build and reuse instructions | available; final API still pending migration |
| generic source/game terminology isolation | required for every migrated native capability |
| host A* caller migration | complete; `PathfinderNative` removed |
| instance configuration, profiles, handles, cohorts, multi-flow foundation | complete in pass 2 |
| navigation channels, flow diagnostics, gardens/portals, bottleneck discovery | complete in pass 3 |
| crowd motion sources, terrain, static obstacles, directional motion, spatial queries | complete in pass 4 |
| impulses, source handles, contact/traffic forces, effects, generic projectiles | complete in pass 5 |
| host navigation/agent/combat conversion | pending across passes 6-7 |
| temporary native compatibility extension | must be deleted in pass 8 |
| separate Git repository and dependency pin | intentionally left to the owner |

The corrected one-extension conversion is governed by
[`NATIVE_MIGRATION_CONTRACT.md`](NATIVE_MIGRATION_CONTRACT.md). Its pass-1 inventory accounts for
all 224 legacy bound methods, the signal/property surface, scene wiring, singleton accessors,
parity-sensitive update order, final owners, and removal gates.

The legacy controller must be decomposed: generic simulation capabilities move into focused
CPathLib modules, while Rabbit Game decisions move into Godot. Trajectory and lifecycle parity
fixtures gate that work; the controller must not be copied wholesale or kept as a second native
implementation.

Completed reusable modules include A*, one synchronous/asynchronous flow builder, wall clearance,
static bottleneck detection, bottleneck traffic reservations, explicit and seeded areas, multi-cell
directional portals, typed enter/exit route segments, instance-owned agents, separation, terrain
speed, motion integration, impulses, control suppression, and persistent external velocities. The
portable build has no `godot-cpp`, Rabbit phase, damage, projectile, or global-singleton dependency.

The separate repository, dependency pin, and licensing decision remain owner-controlled and outside
this refactor. Instructions for that later mechanical split are checked in at
`extensions/CPathLib/REUSE.md`.

The original review found that the extension was not ready to be copied into another game because
portable algorithms and project gameplay shared one source/build boundary. The current physical
split provides safe migration staging, but it is not the solution: each legacy responsibility must
move to its generic CPathLib owner or its Godot gameplay owner, and the second extension must then
be deleted.

The migration has two equally important outcomes:

1. create a game-neutral pathfinding, flow-field, area, bottleneck, and optional crowd-motion
   library in its own repository;
2. keep Rabbit Game working without intentional gameplay, movement, timing, path-selection,
   scene-wiring, save/load, or debug-tool behavior changes.

The second outcome is a hard acceptance criterion, not a best-effort compatibility goal. During the
migration, existing Rabbit Game class names, methods, signals, properties, defaults, NodePaths, and
numerical update order must remain available until their call sites have been deliberately migrated.
Behavior-preserving wrappers are expected at the Rabbit Game boundary.

Do not start by deleting or renaming the current API. Start by capturing its contract and extracting
one algorithm behind that contract at a time.

## Goal

Turn the useful C++ code in `extensions/CPathLib` into a generic, tested, working Godot GDExtension library for 2D grid navigation and optional crowd motion.

The finished package must be suitable as the starting point for any Godot game that needs:

- weighted A*;
- shared flow fields;
- bottleneck detection and traffic control;
- rooms/areas with entrances and exits;
- transitions between world navigation and local navigation inside an area;
- crowd steering, separation, wall avoidance, and static-obstacle avoidance;
- terrain speed modifiers;
- impulses, control suppression, and persistent external velocities;
- asynchronous navigation builds;
- minimal Godot setup.

The standalone library must not inherit Rabbit Game gameplay, naming, lifecycle, scripts, scenes,
or resources. However, Rabbit Game's currently used native API and behavior are migration
requirements for the host-project compatibility layer until all callers have safely moved to the new
API.

## Deliverables

The result should contain four clear parts:

1. **Portable C++ core**
   All pathfinding, flow-field, area, bottleneck, steering, and force algorithms. It must not depend on `godot-cpp`.

2. **Thin Godot adapter**
   A GDExtension that converts Godot data to core data, owns Nodes/Resources, submits asynchronous work, publishes results, and optionally draws diagnostics.

3. **Automated tests**
   Deterministic unit, regression, stress, and performance tests for the portable C++ core. Small Godot smoke-test scenes should verify the adapter.

4. **Minimal example project**
   A clean Godot project showing A*, a shared flow field, an area with entrances/exits, bottleneck traffic, multiple moving agents, and an external force.

These are package boundaries, not separate products. A game developer installs one GDExtension
addon. The separate portable core exists to keep the algorithms testable and the Godot layer small.

Rabbit Game may temporarily retain a fifth part outside the shared library: a game-owned legacy
adapter for existing class names and gameplay-only native features. That adapter is migration
scaffolding, not part of the reusable public API.

## Non-goals

- Exposing Rabbit Game-specific compatibility APIs as part of the new library's stable public API.
- Changing Rabbit Game behavior as a side effect of extraction.
- Migrating GDScript gameplay systems.
- Providing gameplay AI, jobs, combat, health, weapons, projectiles, animation, or VFX.
- Requiring a particular scene tree, TileMap layout, node name, group, metadata key, or autoload.
- Building a general gameplay framework.
- Supporting 3D navigation or navmeshes.
- Adding an ECS, networking layer, editor suite, or plugin architecture.
- Rewriting every algorithm simultaneously.

## Terminology and feature boundaries

Use neutral names in the shared library:

| Rabbit Game term | Shared-library term | Ownership |
|---|---|---|
| garden | navigation area | generic core |
| garden entrance/exit | area portal | generic core |
| monster/client/player | agent | crowd module or host game |
| plant/food target | target cell/region | host game chooses the target |
| eating/working/fighting | caller-defined gameplay state | Rabbit Game only |

An **area** is an optional advanced navigation feature. Games that only need A*, flow fields, or
steering must not need to configure areas or portals. Likewise, bottleneck analysis and traffic
control must be independently optional.

The shared repository should include navigation and generic motion only. Projectile simulation,
damage events, weapon rules, gameplay phases, and Rabbit Game debug presentation must either remain
in Rabbit Game or be moved to a separate game-owned native extension. They must not be silently
removed while Rabbit Game still calls them.

## Repository and integration strategy

The standalone repository should become the source of truth for the portable core, generic Godot
adapter, tests, packaged addon, and demo. Do not maintain copied implementations in both
repositories.

Recommended integration into Rabbit Game:

```text
standalone navigation repository
  -> versioned Git submodule or pinned dependency in Rabbit Game
  -> generic GDExtension API
  -> Rabbit Game compatibility adapter / gameplay services
  -> existing Rabbit Game call sites
```

Prefer a pinned Git submodule initially because the extension is still being migrated and Rabbit
Game must be able to lock a known-good revision. Packaged release artifacts can be added after the
API and platform matrix stabilize. Record both the library version and supported Godot/godot-cpp
version; never consume an unpinned moving branch in the game.

The current `extensions/CPathLib` directory can seed the new repository. Before the repository
split becomes authoritative:

1. complete the Stage 0 inventory and compatibility manifest;
2. decide where `ProjectileSystemNative`, damage/AoE helpers, gameplay phases, and Rabbit-specific
   debug APIs will live during migration;
3. define the initial repository build, license, version, and Godot/godot-cpp compatibility pins;
4. establish how Rabbit Game consumes a pinned revision and how it can roll back;
5. make the first split commit traceable to the exact source commit in this repository.

The Rabbit compatibility adapter may initially be compiled in the same binary as the shared core,
or it may be a separate Rabbit-owned GDExtension. Choose this during Stage 0 based on lifecycle and
call-overhead constraints. In either case, its source belongs to Rabbit Game and must depend on the
shared library, never the reverse.

## Current repository findings

This review found several concrete reasons to perform a staged extraction:

- `extensions/Sconstruct` now builds generic and project-owned source trees into separate Windows
  DLLs;
- the former `PathfinderNative` class and scene node have migrated to `NavigationWorld2D`; the
  project-owned extension still registers six established compatibility/gameplay classes;
- native class names or the `CPP/...` scene layout are referenced across the main scene and numerous
  GDScript systems, including dynamic `has_method()`/`call()` compatibility checks;
- `FlowFieldNative` still owns substantial production flow construction, TileMap interpretation,
  asynchronous work, and bottleneck analysis instead of only adapting Godot data;
- steering is split across a large Godot wrapper and an approximately 3,000-line core controller,
  with generic motion, bottlenecks, debug state, AoE/damage behavior, and Rabbit-specific phases
  mixed together;
- global configuration and the flow-field manager are process-wide mutable singletons;
- the present build assumes a sibling `godot-cpp`, Windows-specific libraries, and locally available
  compiler runtime DLLs;
- generated object files, binaries, temporary DLLs, and SCons state are present under the source
  tree and must not become source contents of the new repository;
- the original native code did not contain a generic area/portal subsystem. The new subsystem was
  therefore added independently of the garden terminology retained in Rabbit compatibility phases.

These findings do not mean the algorithms are unsuitable. They mean the reusable boundary does not
yet coincide with the current folder or binary boundary.

## Target package

One possible layout is:

```text
refined-navigation/
  README.md
  LICENSE
  VERSION
  CMakeLists.txt

  core/
    include/refined_nav/
      math/
      grid/
      path/
      flow/
      area/
      bottleneck/
      crowd/
      motion/
      jobs/
      diagnostics/
    src/

  godot/
    SConstruct
    src/
    refined_navigation.gdextension

  tests/
    unit/
    regression/
    performance/

  demo/
    project.godot
    main.tscn
    main.gd

  addon/
    refined_navigation.gdextension
    bin/
```

Exact names may change. The important rule is the dependency direction:

```text
Godot game
    |
    v
Thin GDExtension adapter
    |
    v
Portable C++ core
```

The core must never include `godot_cpp`, access Nodes, read TileMaps, emit Godot signals, or create Godot Variants. The adapter may depend on the core.

The core should build as a normal static library with CMake so tests can run without starting Godot. The GDExtension may keep SCons if that remains the simplest supported `godot-cpp` build path.

## What can be salvaged from the current C++ code

The reusable pieces are now arranged behind the stable source boundary listed in
`extensions/CPathLib/README.md`; the notes below explain the original extraction choices.

Good extraction candidates include:

- `core/types.h` for basic vector and ID concepts;
- `flow/flow_field.*` for dense field storage and sampling;
- `grid/spatial_grid.*` for moving-agent spatial queries;
- `steering/terrain_speed_grid.*`;
- `steering/external_velocity_accumulator.*`;
- `steering/traffic_right_of_way_resolver.*`;
- the numerical steering, wall, separation, and impulse code in `steering/steering_system.*`;
- the grid search now owned by `CPathLib/pathfinding/a_star_solver.*`;
- the production flow building, distance field, clearance, bottleneck, and worker code currently located in `godot/flow_field_native.*`.

The following current design problems should not be carried into the template:

- A* is implemented as a Godot Node instead of a portable solver.
- Production flow-building algorithms live in a large Godot wrapper.
- Steering, traffic, impulses, damage-like queries, debugging, and presentation state are mixed in one large system.
- configuration is global and mixes unrelated concerns;
- fixed values assume a 256 by 256 grid, a 32-unit cell, and fixed field/group capacities;
- global accessors prevent multiple independent navigation worlds;
- raw pointers and reused numeric IDs make stale asynchronous results risky;
- synchronous and asynchronous paths can use different code;
- debug presentation is mixed with simulation;
- some C++ types and flags describe game concepts rather than generic navigation or motion.

Code should be copied into its new owner and simplified there. Do not keep a compatibility layer for discarded APIs.

Within the standalone library, do not keep compatibility layers for APIs that no external consumer
uses. Within Rabbit Game, keep thin compatibility wrappers for every API that is still used by a
scene, script, signal, `Callable`, string-based `call()`, debug tool, or other dynamic integration.
Remove each wrapper only after direct and dynamic usage has been checked and its callers have been
migrated.

## Rabbit Game compatibility contract

Stage 0 must produce a checked-in compatibility manifest. At minimum, it must inventory:

- registered native class and extension entry-point names;
- bound methods, argument order, default values, return shapes, signals, properties, and enums;
- scene node types, names, NodePaths, exported references, and lifecycle order;
- all direct and dynamic GDScript calls (`call()`, `has_method()`, signals, and string method names);
- global configuration defaults and runtime mutations;
- coordinate conversion, TileMap layer semantics, blocker precedence, and map-bound behavior;
- synchronous/asynchronous request semantics, cancellation, installation order, and teardown;
- agent ID/group ID lifecycle and stale-reference behavior;
- fixed-step order, steering constants, arrival thresholds, bottleneck behavior, and impulse decay;
- debug/query output shapes used by Rabbit Game;
- game-only APIs that need a new Rabbit-owned home rather than a generic replacement.

For every extracted subsystem, record whether compatibility is provided by:

1. the new generic API directly;
2. a thin Rabbit Game wrapper translating old calls to the new API; or
3. a Rabbit-owned gameplay module retained outside the navigation library.

No-behavior-change means more than compiling. Representative before/after fixtures should compare
paths, flow directions/costs, bottleneck annotations, portal choices, agent trajectories, arrival
events, and force decay using identical inputs and fixed deltas. Where exact floating-point equality
is inappropriate, document tolerances before changing the implementation.

## Core data model

### Navigation world

`NavigationWorld` should be an ordinary instance, not a singleton. More than one world must be allowed in one process.

It should own:

- grid definition and coordinate conversion;
- topology and cost revisions;
- immutable snapshots used by solvers and workers;
- path and flow-field caches;
- areas and portals;
- asynchronous requests and completed results;
- configurable memory limits.

### Grid definition

Use one canonical definition:

```cpp
struct GridDefinition {
    int width;
    int height;
    float cell_size;
    Vec2 world_origin;
};
```

All cell/world conversion must go through this definition. Non-zero origins, non-square map sizes, and cell sizes other than 32 must work.

Use a small dense `Grid2D<T>` for solver data. Bounds should be checked at public API edges; verified inner loops may use efficient unchecked access.

Suggested generic cell information:

```text
walkable
physics_passable
dynamic_blocked
base_traversal_cost
area_id
caller-defined flags
```

Sparse overlays are suitable for dynamic blockers, terrain modifiers, and directional traversal edges. Solvers should receive an immutable flattened `GridSnapshot`.

### Traversal policy

Do not add booleans named after a specific terrain type or agent role. A request should carry a generic policy:

```cpp
struct TraversalPolicy {
    bool allow_diagonals = true;
    bool allow_corner_cutting = false;
    uint32_t required_flags = 0;
    uint32_t forbidden_flags = 0;
    int cost_channel = 0;
    float agent_clearance = 0.0f;
    DirectionalEdgeSetHandle directional_edges;
};
```

Games can create several policies over the same topology without changing the algorithms.

### Handles and revisions

Use opaque generational handles instead of public raw pointers:

```cpp
struct AgentHandle     { uint32_t index; uint32_t generation; };
struct FlowFieldHandle { uint32_t index; uint32_t generation; };
struct AreaHandle      { uint32_t index; uint32_t generation; };
struct PortalHandle    { uint32_t index; uint32_t generation; };
```

Every path, field, area, and asynchronous result should record the topology/cost revision used to create it. Stale handles or results must fail safely.

Public operations should return explicit statuses such as `Found`, `Pending`, `Unreachable`, `InvalidInput`, `Cancelled`, and `Stale`. Do not use zero IDs, extreme coordinates, empty arrays, and infinity as interchangeable error states.

## A* subsystem

Create a Godot-independent `AStarSolver`:

```cpp
struct PathQuery {
    Cell start;
    Cell goal;
    TraversalPolicy policy;
    uint32_t max_expansions = 0;
};

struct PathResult {
    PathStatus status;
    std::vector<Cell> cells;
    float total_cost = 0.0f;
    uint32_t expanded_nodes = 0;
};
```

Initial behavior should include:

- four- or eight-direction movement;
- octile heuristic for eight-direction movement;
- no diagonal corner cutting by default;
- weighted traversal costs;
- directional traversal restrictions;
- explicit invalid/unreachable results;
- optional query limits and cancellation;
- deterministic tie-breaking.

Use reusable solver workspace with dense score/parent arrays and generation stamps. This avoids repeated hash-table allocations when many paths are requested.

Path smoothing should be optional and disabled by default. It is a separate step, not part of correctness.

## Flow-field subsystem

Split flow fields into focused owners:

- `FlowFieldData`: directions, integration cost, distance-to-wall, navigability, passability, target, bounds, and revision;
- `FlowFieldBuilder`: one pure synchronous algorithm over an immutable snapshot;
- `FlowFieldStore`: handles, cache keys, memory accounting, use counts, and eviction;
- `FlowFieldJobQueue`: worker execution and cancellation.

Synchronous and asynchronous requests must call the same builder.

```cpp
struct FlowFieldRequest {
    TargetRegion target;
    TraversalPolicy policy;
    float wall_clearance_weight = 0.0f;
    BottleneckOptions bottlenecks;
    uint64_t topology_revision = 0;
    uint64_t cost_revision = 0;
    uint64_t request_generation = 0;
};
```

Targets should support:

- one cell;
- several equivalent cells;
- a radius or explicit region.

Cache keys must contain every input that changes a field: target, topology revision, cost revision, traversal policy, clearance settings, directional edges, and bottleneck options.

Fields should be limited by a configurable byte budget rather than a fixed field count. Diagnostics should expose memory use, build time, cache hits, expanded cells, and cancellation reason.

## Bottleneck subsystem

Separate static analysis from runtime traffic.

`BottleneckAnalyzer` should produce:

- stable ID for the current topology revision;
- core cells;
- approach/influence cells on both sides;
- principal axis/direction;
- width or capacity estimate;
- route-cost interval;
- adjacent connected regions when available.

`BottleneckTrafficController` should own:

- occupancy;
- reservations;
- direction and priority;
- capacity;
- timeout;
- fairness/starvation prevention;
- the movement constraint returned to steering.

Steering may consume a bottleneck constraint, but it should not own bottleneck discovery or reservation maps.

## Areas, rooms, entrances, and exits

Use **area** as the neutral core term. A room is an area with one or more portals.

Support two explicit construction strategies:

1. `ExplicitArea`: the caller supplies interior cells and optional portals.
2. `SeededArea`: the caller supplies seed cells and a bounded expansion rule.

Do not force all games to use one automatic room-detection algorithm.

```cpp
struct NavigationArea {
    AreaHandle id;
    std::vector<Cell> interior;
    std::vector<Cell> target_cells;
    std::vector<PortalHandle> portals;
    uint64_t revision;
};

struct AreaPortal {
    PortalHandle id;
    AreaHandle area;
    std::vector<Cell> boundary_cells;
    std::vector<Cell> outside_cells;
    PortalDirection direction; // Both, EnterOnly, ExitOnly
    uint32_t capacity;
};
```

A portal may span multiple cells. A wide doorway should not become several unrelated one-cell entrances.

`AreaBuilder` should provide reusable connected-component, bounded expansion, boundary, and portal-generation helpers.

`PortalSelector` should rank valid portals using:

1. actual route cost;
2. reachability and traversal-policy compatibility;
3. portal capacity or congestion when requested;
4. local continuation quality;
5. deterministic ID/cell tie-breaking.

### Route segments

Represent transitions explicitly:

```text
world start
  -> flow field or A* to a portal
  -> portal crossing
  -> local A* inside the area
  -> destination
```

Leaving an area is another route:

```text
local position
  -> local A* to a selected portal
  -> portal crossing
  -> flow field or A* in the world
```

A route plan should contain typed segments, progress, status, and the revisions it depends on. If topology changes, it becomes `Stale`. The caller decides whether and when to replan.

The library reports navigation arrival. It does not decide what gameplay action happens there.

## Steering and motion physics

Preserve useful formulas by extracting them into focused systems instead of retaining one large controller:

- `AgentWorld`: agent handles, profiles, positions, velocities, and route-follow state;
- `SpatialIndex`: neighbor queries;
- `SteeringSolver`: desired velocity from flow, path, or manual input plus separation and avoidance;
- `BottleneckTrafficController`: traffic constraints;
- `ImpulseSystem`: impulses, delay, decay, control suppression, priority, and persistent velocity sources;
- `MotionIntegrator`: combines velocities, integrates position, and resolves invalid overlap;
- optional `OverlapQuery`: generic circle, cone, and box queries;
- `AgentDiagnostics`: read-only simulation diagnostics.

Use generic navigation and motion states:

```text
NavigationSource: None, FlowField, Path, Manual
RouteProgress: Idle, WaitingForData, Following, Arrived, Stale, Failed
MotionConstraint: Paused, ControlSuppressed, ExternalOverride
```

No gameplay phase belongs in the core.

### Motion update contract

Define and test one explicit update order:

1. update timed impulses, cooldowns, and external sources;
2. resolve contact and right-of-way requests;
3. select flow, path, or manual desired velocity;
4. apply arrival slowdown;
5. apply terrain speed;
6. calculate separation, wall, obstacle, and bottleneck contributions;
7. combine autonomous and external motion according to constraints;
8. integrate position;
9. resolve wall/static-obstacle penetration;
10. publish arrival and diagnostic state.

The exact formulas and order should be recorded when extracting the existing numerical code. Once accepted as the template behavior, regression tests should lock it down.

### Forces

The generic force API should support:

- immediate and delayed impulses;
- force magnitude and cap;
- friction/decay and duration;
- optional autonomous-control suppression;
- navigation-preserving impulses;
- priorities when impulses compete;
- persistent external velocity sources with response and expiry;
- caller-defined 32-bit collision/category masks.

Damage, immunity, weapon rules, and visual feedback remain outside the library. The optional overlap-query module may return affected agent handles so the caller can apply its own effects.

## Godot-facing API

Prefer a few cohesive classes:

- `NavigationWorld2D`: grid input, topology edits, A*/flow requests, areas, portals, and completion signals;
- `CrowdWorld2D`: agent registration, profiles, movement updates, route attachment, impulses, and batched state access;
- optional `NavigationArea2D`: authored area/portal data;
- optional `NavigationDebugDraw2D`: debug rendering only.

The minimal setup should be:

1. install/copy the addon;
2. add `NavigationWorld2D`;
3. upload a grid directly or connect an optional TileMap helper;
4. request a path or flow field;
5. add `CrowdWorld2D` only if agent movement is needed.

The core API must accept raw grid data so TileMap is optional.

Use typed Resources and packed arrays at the Godot boundary. Avoid Dictionaries in hot APIs. Provide batched agent registration, input, and output to avoid one GDExtension call per agent per frame.

The adapter must copy all Godot data on the main thread. Worker threads may touch only immutable core snapshots and thread-safe queues. Completed results must be installed on the main thread after validating world lifetime, handle generation, request generation, and topology/cost revisions.

Debug drawing must be optional and separate from simulation. Disabling it must remove its per-frame cost.

## Testing requirements

The portable core must have automated deterministic tests. Under this repository's policy, Godot execution remains manual unless explicitly authorized; Godot smoke tests can be supplied for the user or CI to run.

### Unit and regression tests

- cardinal and diagonal A*;
- no corner cutting;
- weighted costs and directional edges;
- invalid and unreachable endpoints;
- deterministic path tie-breaking;
- single- and multi-target flow fields;
- non-zero world origin and arbitrary cell size;
- navigability versus physics passability;
- wall distance and clearance adjustment;
- dynamic blockers and revision invalidation;
- async completion, cancellation, and stale-result rejection;
- narrow and wide bottlenecks;
- reservation capacity, priority, timeout, and fairness;
- explicit and seeded areas;
- one-cell and multi-cell portals;
- enter-only and exit-only portals;
- deterministic portal selection;
- area split, merge, edit, and removal while routes exist;
- world -> portal -> local path transitions;
- local path -> portal -> world transitions;
- separation, wall avoidance, and static obstacles;
- terrain speed modifiers;
- immediate, delayed, and navigation-preserving impulses;
- impulse decay, control suppression, and persistent external velocity;
- deterministic fixed-step agent trajectories.

### Performance tests

- several grid sizes, including non-square maps;
- many local A* requests with reusable workspace;
- simultaneous flow-field requests;
- many agents with bounded neighbor work;
- frequent localized topology changes;
- cache eviction under a byte budget;
- batched state exchange overhead;
- debug disabled versus enabled.

Performance tests should report time, allocations, memory, expanded cells, cache hit rate, and worst neighbor-query size. Thresholds should be documented per supported build type and machine class rather than hidden in code.

### Minimal Godot smoke tests

- extension loads without errors;
- classes and properties register correctly;
- a raw grid can be uploaded without TileMap;
- the optional TileMap helper creates the same grid snapshot;
- A* and flow requests return valid typed results;
- async completion is delivered on the main thread;
- an area with two portals can be entered and exited;
- multiple agents move and avoid each other;
- a bottleneck regulates opposing traffic;
- an impulse alters motion and decays;
- teardown with pending work does not crash or install stale results;
- a release binary runs in a clean exported project.

## Migration stages

The current Rabbit Game API must remain operational throughout migration. Each stage needs both its
new core tests and the relevant Rabbit Game compatibility checks to pass before dependent code is
moved. The user runs Godot verification manually under this repository's policy.

### Stage 0 - inventory and behavior capture

- Catalogue algorithms, configuration, global state, Godot dependencies, and game-only code in the current C++ files.
- Record the existing numerical update order for steering and forces.
- Create small data-only fixtures for open grids, corners, islands, corridors, rooms, portals, and dynamic blockers.
- Capture useful current algorithm outputs only where they are intentionally retained.
- Mark game-only code for deletion rather than extraction.
- Create the Rabbit Game compatibility manifest described above.
- Map every registered class to `generic`, `temporary compatibility`, or `Rabbit-owned gameplay`.
- Record the exact source revision and toolchain used to seed the standalone repository.
- Define representative manual Rabbit Game scenarios and deterministic data fixtures before moving
  behavior.

Exit criterion: every useful algorithm has a destination owner, every discarded responsibility is
identified, every currently used API has a compatibility route, and the standalone repository split
can be traced and rolled back.

### Stage 1 - package skeleton and core types

- Create the standalone core build and test executable.
- Add math, cell, bounds, dense-grid, handle, revision, status, and result types.
- Add instance-owned `NavigationWorld`.
- Add conversion helpers only in the Godot adapter.

Exit criterion: a non-Godot test can construct, edit, snapshot, and query a grid.

### Stage 2 - A*

- Extract the grid search into `AStarSolver`.
- Remove Godot types from the algorithm.
- Add traversal policies, weighted costs, explicit results, cancellation, diagnostics, and reusable workspace.
- Write correctness and performance tests.
- Create the new Godot A* API directly and migrate the host's sparse-grid callers to
  `NavigationWorld2D`.

Exit criterion: A* passes the full solver matrix through both C++ and the minimal Godot adapter.

### Stage 3 - flow fields

- Extract integration costs, directions, distance-to-wall, clearance adjustment, and passability masks.
- Make synchronous and asynchronous requests use one `FlowFieldBuilder`.
- Add store handles, cache keys, revisions, cancellation, and byte-budget eviction.
- Keep TileMap reading and debug drawing outside the core.

Exit criterion: flow-field fixtures are deterministic and async results cannot be installed after becoming stale.

### Stage 4 - bottlenecks

- Extract detection into `BottleneckAnalyzer`.
- Extract reservations and occupancy into `BottleneckTrafficController`.
- Define capacity, direction, priority, timeout, and fairness behavior.
- Add fixed-step opposing-traffic tests.

Exit criterion: detection and runtime traffic pass independently and together.

### Stage 5 - areas and portals

- Implement explicit/seeded areas, boundary calculation, multi-cell portals, and revisions.
- Implement route-cost-based portal selection.
- Add local paths and explicit world/local route segments.
- Add stale-route behavior after topology edits.

Exit criterion: generic fixtures can enter and leave one- and multi-portal areas with no gameplay code.

### Stage 6 - steering and forces

- Extract agent storage and spatial indexing.
- Extract steering contributions one at a time.
- Extract impulses/external velocity and the motion integrator.
- Delete game-specific states, category names, damage, immunity, presentation, and debug labels.
- Add deterministic fixed-step trajectory tests after each extraction.

Exit criterion: paths and fields can drive large groups while avoidance and forces remain stable and bounded.

### Stage 7 - Godot adapter

- Finalize the small typed Node/Resource API.
- Add direct-grid upload and optional TileMap conversion.
- Add batched agent APIs, async signals, safe teardown, and separate debug drawing.
- Keep Node methods as marshalling/orchestration only; algorithms stay in the core.
- Verify the Rabbit Game compatibility adapter against the manifest. Do not add Rabbit-specific
  methods to the generic classes merely to avoid a host-side wrapper.

Exit criterion: adapter smoke tests cover every public feature with no game dependencies.

### Stage 8 - library packaging

- Add build/install/versioning and upgrade/rollback documentation.
- Add supported Godot, `godot-cpp`, compiler, platform, and architecture matrix.
- Add debug and release builds.
- Add the minimal demo and copy/install instructions.
- Add automated core CI and documented Godot smoke-test commands.
- Verify the addon in a new empty project using only packaged files and README instructions.
- Pin a released or commit-addressed revision in Rabbit Game and document the update procedure.

Exit criterion: a user can install the package, run the demo, upload a grid, create an area, request A*/flow navigation, move agents, and apply an impulse without access to this repository.

### Stage 9 - remove discarded source

- Compare the package against the inventory from Stage 0.
- Delete old wrappers only after their Rabbit Game callers have migrated. Move still-required
  game-only native code to its declared Rabbit-owned module. Remove duplicate algorithms, old
  globals, object files, and obsolete binaries from the library package.
- Confirm that only one implementation exists for each algorithm.
- Run the full core, performance, and adapter test suites through the authorized test process.

Exit criterion: no discarded system is required to build, test, install, or use the library; Rabbit
Game uses a pinned library revision; all remaining compatibility wrappers have documented callers;
and the agreed manual behavior-parity scenarios pass without intentional behavior changes.

## Production constraints

- Never access Godot objects from worker threads.
- Do not use global mutable navigation state.
- Do not expose core object pointers through the public API.
- Do not duplicate synchronous and asynchronous algorithms.
- Do not rebuild every field after a localized edit unless dependencies require it.
- Do not scan all agents for local steering or force queries; use the spatial index.
- Keep neighbor work bounded and expose saturation diagnostics.
- Share fields by target and traversal policy; do not create a field per agent.
- Batch data across the GDExtension boundary.
- Use explicit fixed-step or capped-step simulation for reproducible steering.
- Budget cached fields by bytes.
- Keep debug work opt-in and read-only.
- Keep public headers small and versioned.
- Prefer explicit, readable data flow over global managers or generic frameworks.

## Main risks

### Movement behavior changes during extraction

Steering and forces are order-dependent. Moving formulas between owners can change acceleration, avoidance, collision correction, or knockback decay. Record the chosen update order and add golden fixed-step trajectories before cleanup.

### Coordinate mistakes

Cell, field-relative, local, and world coordinates must not be mixed. `GridDefinition` and adapter conversion functions should be the only coordinate authority.

### Stale asynchronous results

Validate world lifetime, generational handles, request generation, topology revision, and cost revision before installing any result.

### Cache growth

Targets, policies, topology, cost channels, clearance, directional edges, and bottleneck options all affect cache identity. Use complete cache keys, metrics, and byte-budget eviction.

### Over-generalized area detection

Areas can be authored, flood-filled, or expanded from seeds. Keep construction strategies separate and share only the resulting area/portal representation.

### Godot adapter growth

The adapter can easily become another large manager. It should only marshal data, own Godot lifecycle, submit/poll jobs, emit results, and draw optional diagnostics.

## Definition of done

The migration is complete when:

- the portable core builds and passes automated tests without Godot;
- no core public header includes `godot_cpp`;
- the GDExtension builds in debug and release for every documented supported target;
- an empty Godot project can install and use only the packaged addon;
- no scene-tree convention or TileMap is mandatory;
- multiple independent worlds can exist in one process;
- grid size, origin, cell size, capacities, and policies are runtime configuration;
- A*, flow fields, bottlenecks, areas/portals, route segments, steering, and forces have typed APIs;
- async work is snapshot-based, cancellable, and stale-safe;
- debug drawing is optional and separated from simulation;
- game-specific phases, combat, damage, projectiles, and presentation are absent;
- there is exactly one implementation path for each algorithm;
- the minimal demo and README are sufficient to get started;
- the test and performance baselines are documented and reproducible.
- Rabbit Game consumes a pinned library revision and retains all agreed behavior;
- every remaining Rabbit compatibility wrapper and game-owned native feature has a documented owner.

## Recommended first implementation slice

Start with compatibility capture, then the smallest end-to-end vertical slice:

1. create the Stage 0 API/call-site manifest and A* behavior fixtures;
2. decide the temporary ownership of gameplay-only native features;
3. create the package skeleton and portable test target;
4. add `GridDefinition`, `Grid2D`, `GridSnapshot`, handles, and result types;
5. extract `AStarSolver` with no Godot dependency;
6. add deterministic A* unit tests;
7. expose the new solver through a minimal `NavigationWorld2D` adapter;
8. migrate the host A* scene node and callers to `NavigationWorld2D`;
9. demonstrate the generic API in the empty example project;
10. have the user verify the existing Rabbit Game A* scenarios before continuing to flow fields.

This establishes the permanent dependency direction, testing pattern, packaging pattern, and minimal Godot experience before the larger flow-field and steering code is moved.
