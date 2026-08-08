# Standalone repository checklist

Use this checklist when `extensions/flowfield` becomes its own private repository.

1. Copy the reusable source set listed in [README.md](README.md), `extensions/Sconstruct`,
   `register_types.*`, the generic tests, the demo, and the GDExtension descriptor.
2. Either omit the Rabbit-owned files entirely or keep them in a clearly separate host integration
   directory. Never make the generic core depend on them.
3. Record the Rabbit Game source commit and matching `godot-cpp` commit in the first repository
   commit.
4. Preserve the `rabbit_compat=no` build as the standalone default. Rabbit Game may continue using
   `rabbit_compat=yes` until its old scenes and scripts are deliberately migrated.
5. Keep the dependency pinned when Rabbit Game consumes the new repository. Do not copy changes in
   both directions or follow an unpinned branch.
6. Rebuild and run both portable tests and both generic Godot smoke tests before updating the pin.
7. Rebuild Rabbit compatibility and run its gameplay scenarios before accepting the new pin.
8. Do not publish build objects, local runtime backups, `.godot`, SCons state, or temporary DLLs.
9. This is private software with no license grant until the owner explicitly adds a license.

The clean repository dependency direction is:

```text
Rabbit Game compatibility/gameplay
    -> generic Godot adapter
    -> portable C++ navigation core
```

Never introduce an include or callback in the reverse direction.
