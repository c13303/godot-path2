# Reuse checklist

CPathLib is designed so this directory can become the root of a separate private repository.

1. Keep all portable modules, `godot/`, `register_types.*`, `cpathlib.gdextension`, tests, demo,
   and this documentation together.
2. Keep `godot-cpp` pinned to a revision compatible with the target Godot release.
3. Use the repository-local `SConstruct`; pass `godot_cpp_dir` only when `godot-cpp` is not a
   sibling checkout.
4. Package `cpathlib.gdextension`, `bin/cpathlib.dll`, and the required MinGW runtime DLLs under one
   addon directory while preserving descriptor-relative paths.
5. Do not commit object files, compiler runtime backups, temporary DLLs, `.godot`, or SCons state.
6. Run both portable test executables and both Godot smoke scripts before updating a consuming
   project's pinned revision.
7. Treat `NavigationWorld2D`, `NavigationRoute2D`, and `CrowdWorld2D` as the stable Godot boundary.
8. Keep host-specific TileMap interpretation, scene lookup, gameplay state, combat/effect rules,
   save formats, and debug presentation in the consuming project.
9. Preserve the dependency direction: host adapter to CPathLib Godot API to portable core.
10. Keep the repository private unless its owner deliberately chooses and adds a license.

Multiple navigation and crowd worlds can coexist. Consumers must not add process-wide navigation
singletons or callbacks from CPathLib into a host project.

Flow, profile, agent, cohort, area, and portal handles are owned by the instance that created them.
Do not pass handles between unrelated worlds. Explicitly release long-lived flow/profile/cohort
handles when the consumer no longer needs them; generation checks make stale handles fail safely.
