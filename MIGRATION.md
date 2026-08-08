# CPathLib migration status

## Outcome

The native conversion is complete in this repository.

- `extensions/CPathLib` is the only GDExtension source tree, descriptor, and DLL target.
- CPathLib contains only generic navigation, crowd-motion, force, effect-region, and projectile
  simulation concepts. It has no dependency on this game's scripts, scenes, metadata names,
  phases, combat rules, or presentation.
- The Godot project consumes the generic API through project-owned adapters under
  `scripts/native/`.
- The former `extensions/rabbit_game_native` implementation and its second build target were
  removed after the live scene and dynamic-call reference audit found no remaining callers.
- Creating a separate repository and choosing how this project pins it remain owner-controlled
  mechanical steps. See `extensions/CPathLib/REUSE.md`.

`NATIVE_MIGRATION_CONTRACT.md` remains the detailed historical inventory and parity contract.

## Final ownership boundary

### CPathLib

CPathLib owns reusable, instance-scoped simulation capabilities:

- weighted A* and shared or independent flow fields;
- asynchronous flow construction and stale-result protection;
- blocker and directional-traversal channels;
- gardens/navigation areas, portals, and typed routes;
- bottleneck discovery, occupancy gating, and reservation APIs;
- crowd profiles, agents, cohorts, manual/path/flow/directional motion;
- separation, terrain speeds, wall collision/sliding, and static obstacles;
- arrival, lost-flow, blocked-motion, pause, and force-isolation policies;
- delayed/prioritized impulses, resistance, control suppression, and external velocities;
- category-filtered circle, cone, AABB, and navigation-cell queries;
- query shapes used by generic spatial and projectile collision;
- effect volumes and pooled swept projectiles that publish neutral events.

The portable C++ modules do not depend on Godot. The `godot/` directory is a thin adapter over
those modules. CPathLib never calls into the consuming project.

### This Godot project

The project-owned adapters translate game data and decisions into generic CPathLib operations:

- `AgentHandleRegistry` owns weak scene-node mappings, selection-cohort bookkeeping, profile
  metadata translation, scene synchronization, and presentation events;
- `NavigationFlowCoordinator` owns project routing requests and flow/cohort handle lifetimes;
- `NavigationGridUploadService` translates authored map data into neutral grid/channel uploads;
- `NativeSimulationConfig` applies this project's numerical defaults to each world instance;
- `CrowdRuntime` interprets phases, damage, combat force allocation, and effect events;
- `ProjectileRuntime` translates weapon resources into generic projectile types and interprets
  neutral impact events.

Game meanings such as player, monster, drowning, damage, weapons, and selection never cross into
CPathLib. Generic fields such as category masks, query shapes, force enablement, impulse
resistance, and cohort handles carry only consumer-defined data.

## Behavior-preservation notes

The final parity pass preserves these conversion-sensitive contracts:

- manual movement uses the project-configured speed in every direction and wall collision retains
  the established slide behavior;
- flow-driven agents freeze while an asynchronous cohort flow is pending and resume when installed;
- small cohorts stop immediately near the flow goal, larger cohorts use the established radius and
  staggered delay, and `never_rest` maps to the generic continue-at-goal policy;
- agents with a missing flow direction wait, then recover toward the nearest navigable cell at the
  established reduced speed; external or impulse-owned motion is not swallowed by that wait;
- flow agents blocked by geometry enter the recovery brake without applying that policy to manual
  player movement;
- detected bottlenecks are integrated into flow steering and occupancy gating;
- crowd pressure and gameplay impulses respect the authored per-agent resistances;
- paused agents stop autonomous movement but may still receive contact/impulse displacement when
  the project enables that policy;
- force-isolated phases reject impulses, effect ticks, damage interpretation, and projectile hits
  while directional drift remains independently controllable;
- projectile sweeps and area attenuation use sprite-derived generic query AABBs;
- budgeted projectile force is allocated once, deterministically, direct-hit first and then
  front-to-back, while damage still applies to every eligible target;
- propelled/control-impaired presentation is driven from native impulse state, including the
  source profile's feedback-suppression policy;
- empty, non-current selection cohorts are released instead of accumulating indefinitely.

## Reuse procedure

When the owner creates the separate repository:

1. Copy `extensions/CPathLib` as the repository root without changing its internal layout.
2. Pin a `godot-cpp` revision compatible with the Godot version used by the consumer.
3. Build with the repository-local `SConstruct` and the supported MinGW workflow.
4. Keep CPathLib as the source of truth; consume it here through a pinned submodule or another
   explicitly pinned dependency.
5. Package the descriptor, `bin/cpathlib.dll`, and required MinGW runtime DLLs together.
6. Run the portable tests and Godot smoke scripts before advancing the pinned revision.
7. Keep all map interpretation, gameplay rules, save compatibility, and debug presentation in the
   consuming project.

Do not copy CPathLib into multiple repositories and edit the copies independently. Do not add
consumer-specific enums, metadata names, scene paths, singleton accessors, or callbacks to the
library.

## Verification gates

Before treating a revision as reusable:

- build `cpathlib.dll` with the current MinGW toolchain;
- run `test_a_star_solver` and `test_flow_field_algorithms`;
- run the navigation, crowd, and projectile CPathLib Godot smokes;
- run the project native-boundary and gameplay-adapter smokes;
- start the real project headlessly and check for parser, binding, and scene-load errors;
- manually verify player speed/wall sliding, flow arrival, monsters recovering after spray near a
  corner or bottleneck, drowning drift/isolation, combat hit shapes, and selection changes;
- confirm a source scan under `extensions/CPathLib` contains no consumer terminology or dependency;
- confirm the project contains no second GDExtension descriptor or legacy native class reference.

The user remains the authority for final gameplay acceptance. Automated checks establish structural
and deterministic regression confidence; they do not replace a normal day/night gameplay pass.
