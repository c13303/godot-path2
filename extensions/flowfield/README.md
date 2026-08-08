# Flow-field extension: reuse and migration instructions

## Current status

This directory is the C++ source for Rabbit Game's current Godot GDExtension. It contains reusable
navigation algorithms, but the directory as a whole is **not yet a portable, drop-in library**.

Do not copy the current folder into another game and assume it is independent. The single extension
binary currently combines:

- A* pathfinding and flow-field construction;
- crowd steering, spatial queries, terrain speed, impulses, and bottleneck traffic;
- Godot TileMap/lifecycle/configuration adapters;
- Rabbit Game agent phases and debug/query behavior;
- gameplay-only AoE, damage-event, and projectile features.

The authoritative extraction and compatibility plan is [`../../MIGRATION.md`](../../MIGRATION.md).

## Intended reusable product

The future standalone repository is a versioned 2D grid-navigation library with:

- a Godot-independent C++ core;
- a thin Godot GDExtension adapter;
- optional A*, flow-field, area/portal, bottleneck, crowd-steering, and force modules;
- deterministic native tests;
- a minimal Godot demo that does not depend on Rabbit Game.

The generic term is **navigation area**. Rabbit Game's gardens map to navigation areas, and garden
entrances/exits map to area portals. The shared library must not know about plants, eating, monsters,
clients, jobs, combat, or other Rabbit Game rules.

## Rules for extracting into the standalone repository

1. Preserve provenance: record the Rabbit Game source commit used for the initial split.
2. Do not move algorithms and redesign their behavior in the same step.
3. Keep all `godot_cpp` types and Node access in the adapter; the core must compile without Godot.
4. Make navigation worlds instance-owned. Do not carry global manager/config singletons into the
   public library design.
5. Keep advanced modules optional. A consumer using only A* must not initialize crowd, areas,
   bottlenecks, projectiles, or Rabbit Game compatibility code.
6. Do not put projectile, damage, weapon, phase, or presentation code in the shared navigation API.
7. Use one implementation for synchronous and asynchronous flow construction.
8. Version the API and pin compatible Godot, `godot-cpp`, compiler, platform, and architecture
   combinations.
9. Package only source and intentional runtime artifacts. Do not publish `.o`, `.sconsign`, temporary
   DLL files, or locally saved compiler runtime copies as source.
10. Do not remove a Rabbit Game API until its direct and dynamic call sites have been migrated and
    its manual parity scenario has passed.

## Consuming the future repository from Rabbit Game

Use a pinned Git submodule or another commit-addressed dependency. Do not copy source back and forth
between repositories and do not track an unpinned branch.

Keep the dependency direction explicit:

```text
Rabbit Game gameplay
    -> Rabbit Game compatibility/services layer
    -> generic Godot adapter
    -> portable navigation core
```

During migration, existing scene class names and methods may remain as thin wrappers in Rabbit Game.
Gameplay-only native features should remain in, or move to, a Rabbit-owned module. The generic
library must not call back into Rabbit Game services.

When updating the pinned library revision:

1. read the library changelog and supported-version matrix;
2. update the pin on a dedicated branch;
3. rebuild using the documented toolchain;
4. let the user run the Rabbit Game manual compatibility scenarios;
5. commit the dependency pin and any intentional adapter changes together;
6. roll back to the previous pin if behavior parity fails.

## Minimum standalone demo

The demo should be a clean Godot project containing only the nodes and scripts needed to show:

- raw-grid upload without a TileMap dependency;
- one A* query;
- one shared flow field used by multiple simple agents;
- one navigation area with at least two portals;
- opposing agents regulated at a bottleneck;
- one external impulse or velocity source;
- optional debug drawing that can be disabled with no simulation dependency.

The demo must not import Rabbit Game scenes, scripts, resources, autoloads, groups, metadata, or node
names.

## Before declaring the split ready

Complete Stage 0 of `MIGRATION.md`. In particular, inventory the existing registered classes and all
GDScript/scene call sites, decide the destination of projectile/combat features, capture behavior
fixtures, choose the license and version policy, and prove that Rabbit Game can pin and roll back the
standalone dependency.

Until those items are complete, creating a separate repository is useful as a controlled extraction
workspace, but it is not yet evidence that the extension is reusable or safe to replace in this
project.
