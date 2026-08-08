# Project-owned native integration

This directory is not part of CPathLib. It preserves native behavior that belongs to this project:

- TileMap-to-navigation interpretation and per-group flow lifecycle;
- scene-node registration and agent/group orchestration;
- the established steering update order and project phase state;
- combat overlap, damage-event, AoE, and projectile behavior;
- project debug drawing and runtime configuration.

It may include CPathLib portable headers and algorithms. CPathLib must never include this directory.
The two modules have separate registration entry points and GDExtension descriptors.

## Migration status

The former A* compatibility node has been removed. The main scene now uses CPathLib's
`NavigationWorld2D` directly, and `BuildingPathService` uses `configure_sparse_grid()` plus
`find_path_cells()`.

The remaining native classes are compatibility or gameplay owners, not public CPathLib API. Keep
their class names, methods, signals, defaults, NodePaths, and numerical update order until a
replacement has parity coverage for every current caller. In particular, do not replace the large
steering controller wholesale with `CrowdWorld2D`: the generic crowd intentionally has no project
phase, node-mapping, damage, AoE, or presentation behavior.

Safe future extraction order:

1. move debug rendering out of `SteeringSystemNative` without changing simulation state;
2. move combat overlap/damage event ownership into a focused project combat service;
3. replace global service lookup with explicit ownership rooted at the scene adapter;
4. add deterministic trajectory fixtures for the established controller;
5. migrate one motion contribution at a time only when old/new trajectories match;
6. remove a compatibility method only after direct, dynamic, signal, and scene usage is absent.

See [COMPATIBILITY.md](COMPATIBILITY.md) for the current contract and `../../MIGRATION.md` for the
library-wide rationale.
