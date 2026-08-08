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

Blocker and directional channel numbers are local to one `NavigationWorld2D`. The consumer owns
their meaning and should define them in its own configuration rather than adding named gameplay
channels to CPathLib. Blocker masks use bits 0 through 63; a request mask chooses which uploaded
blocker channels participate in that path or flow. Directional channels are selected separately by
integer ID. Channel edits invalidate installed flows, so consumers must rebuild flows after edits.

The `garden` and `area` method families are aliases backed by one navigation-area store. New Godot
consumers may use the garden terminology without creating another area abstraction. Portals,
routes, revisions, and handle lifetime are identical through both method families.

Directional traversal and directional motion are deliberately separate. Traversal channels belong
to `NavigationWorld2D` and constrain path construction. Directional-motion fields belong to
`CrowdWorld2D`, produce velocity targets, and are explicitly assigned to agents. Static obstacles,
motion fields, terrain channels, and category-mask meanings are owned by the consuming world; keep
their semantic names in consumer code rather than adding them to CPathLib.
