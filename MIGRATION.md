# CPathLib migration status

Last reviewed: 2026-08-08.

## Goal

One reusable navigation/crowd extension that can be dropped into another Godot project, while this
game keeps behaving exactly as it does today.

Nothing below changes gameplay. If a step would change behavior, it is out of scope.

## Where it stands

The native conversion is done. CPathLib is generic, self-contained, and fully bound. The remaining
work is packaging: as of today the extension cannot be copied into another project unmodified,
because its descriptor hardcodes this project's folder layout.

Verified directly against the tree, not just carried over from the pass notes:

- no file in the portable modules (`area/ bottleneck/ core/ crowd/ flow/ grid/ jobs/ pathfinding/
  projectile/ steering/`) includes `godot_cpp`;
- no gameplay terminology from this project appears anywhere in CPathLib;
- one descriptor, one entry point, four registered classes;
- 163 methods bound, covering every public method of the three node classes. The only unbound
  declarations (`copy_flow`, `copy_latest_flow`, `grid_definition`, `core_world`) are intentional
  C++-to-C++ accessors;
- no TODO/FIXME/stub markers;
- build artifacts gitignored, and the committed DLL matches the current sources;
- the only remaining legacy native class names are in `.godot/` editor caches and archived notes.

`NATIVE_MIGRATION_CONTRACT.md` is the historical inventory. `extensions/CPathLib/REUSE.md` is the
standalone-repository checklist.

## What blocks reuse

**1. The descriptor is not relocatable.** `cpathlib.gdextension` points at
`res://extensions/CPathLib/bin/...` for the library and the three MinGW runtime DLLs. Copy the
folder to `addons/cpathlib/` in another project and it cannot find its own binary. Godot resolves a
non-`res://` library path relative to the `.gdextension` file, so the fix is to write
`bin/cpathlib.dll` instead. This is the only thing standing between the current state and a
drop-in addon.

`demo/navigation_demo.tscn` has the same issue in its script `ext_resource`. Scene files cannot use
relative paths, so that one stays a known one-line edit when the folder moves.

**2. The build path used daily is the wrong one.** `run.sh` runs `scons -C extensions`, which uses
`extensions/Sconstruct`. That file duplicates `extensions/CPathLib/SConstruct`, which is the one a
standalone repository would ship — and which is therefore never exercised. Point `run.sh` at
`scons -C extensions/CPathLib target=template_debug use_mingw=yes godot_cpp_dir=../../../godot-cpp`
and delete `extensions/Sconstruct` and the unused `extensions/config.py`. After this the library's
own build file is the one proven working every day.

**3. The verification steps cannot be run.** `SConstruct` excludes `tests/`, and nothing builds
`tests/test_a_star_solver.cpp` or `tests/test_flow_field_algorithms.cpp` — the executables in `bin/`
were compiled by hand. The command to run the three Godot smoke scripts is documented nowhere
either. `REUSE.md` step 6 requires both before advancing a pinned revision.

**4. The docs disagree with reality.** `README.md` says the supported workflow is Godot 4.6.1, but
`run.sh` launches 4.5.1 and the descriptor declares `compatibility_minimum = "4.5"`. The README is
the wrong one. There is also no LICENSE and no record of which `godot-cpp` revision the committed
DLL was built against, though `REUSE.md` step 2 makes pinning it a rule.

## Plan

1. **Make the descriptor relative.** One edit to `cpathlib.gdextension`. Verify with `run.sh`: the
   game must launch and behave identically. If the extension fails to load, revert — that single
   result settles whether relative paths resolve on this Godot version.
2. **Consolidate the build.** Update `run.sh` to build via `extensions/CPathLib/SConstruct`, then
   delete `extensions/Sconstruct` and `extensions/config.py`. Verify with `run.sh`.
3. **Make the tests runnable.** Add a SCons alias that builds the two portable test executables, and
   write the exact commands for them and for the three headless smoke scripts into `README.md`.
4. **Fix the docs.** Correct the Godot version in `README.md`, state that the supported platform is
   Windows/MinGW only, and record the pinned `godot-cpp` revision.
5. **Extract.** Copy `extensions/CPathLib` to its own private repository, add a LICENSE, and consume
   it back here as a pinned submodule at the same path. Confirm with `run.sh` plus a normal
   day/night gameplay pass.

Steps 1 and 2 are the ones that matter; each is verified by launching the game and seeing no change.
Step 5 becomes a copy rather than a rewrite once 1 through 4 are done.

## Explicitly out of scope

- **Splitting `CrowdWorld`.** It is large (`crowd_world.cpp` 982 lines, plus a 308-line second
  partial), but the work is already delegated to focused subsystems and the ownership is correct.
  Splitting it further is not needed for reuse, cannot be verified by the existing tests, and risks
  changing the parity-sensitive update order. Leave it alone.
- **Separating the debug and release DLL names.** `SConstruct` writes `bin/cpathlib.dll` for either
  target, so a release build overwrites a debug one. Real, but it does not block reuse and it forces
  a rebuild to fix. Revisit only if you start shipping release exports of the addon.
- **Linux and macOS support.** Not needed; just say so in the README rather than implying otherwise.

## Ownership boundary

CPathLib owns generic, instance-scoped simulation: A* and flow fields, async flow construction and
stale-result protection, blocker and directional-traversal channels, gardens/areas/portals/routes,
bottleneck discovery and gating, crowd profiles/agents/cohorts, separation, terrain speeds, wall and
static-obstacle response, arrival and recovery policies, impulses and external velocities, filtered
spatial queries, effect volumes, and pooled swept projectiles. It never calls into the game.

This project owns the meaning: `AgentHandleRegistry` (node mapping, selection cohorts, presentation
events), `NavigationFlowCoordinator` (routing requests, flow/cohort lifetimes),
`NavigationGridUploadService` (authored map data to neutral cells/channels), `NativeSimulationConfig`
(numeric defaults), `CrowdRuntime` (phases, damage, combat forces, effect events), and
`ProjectileRuntime` (weapon resources, impact interpretation).

Player, monster, drowning, damage, weapon, and selection never cross into CPathLib. Category masks,
query shapes, caller tokens, and traffic group tokens are opaque values the game assigns meaning to.

## Behavior that must not change

These are the conversion-sensitive contracts. Any packaging step that alters one of them is wrong:

- manual movement speed in every direction, and the established wall-slide behavior;
- flow-driven agents freeze while an async cohort flow is pending, and resume when it installs;
- small cohorts stop immediately near the goal, larger cohorts use the established radius and
  staggered delay, and `never_rest` maps to continue-at-goal;
- agents with no flow direction wait, then recover toward the nearest navigable cell at the reduced
  speed, without swallowing impulse- or external-owned motion;
- flow agents blocked by geometry brake, but manual player movement never does;
- bottlenecks feed both flow steering and occupancy gating;
- crowd pressure and gameplay impulses respect authored per-agent resistances;
- paused agents stop moving but may still be displaced when the project allows it;
- force-isolated agents reject impulses, effect ticks, damage, and projectile hits, while directional
  drift stays independently controllable;
- projectile sweeps and area attenuation use the sprite-derived query AABBs;
- budgeted projectile force is allocated once, direct-hit first then front-to-back, while damage
  still applies to every eligible target;
- propelled/control-impaired visuals are driven from native impulse state;
- empty non-current selection cohorts are released rather than accumulating.

## Checks before calling it done

- `run.sh` builds and launches with no parser, binding, or scene-load errors;
- the descriptor loads from a path other than `extensions/CPathLib` and all four classes register;
- `test_a_star_solver` and `test_flow_field_algorithms` pass;
- the three CPathLib smoke scripts and the project's native-boundary smokes pass;
- a normal day and night: multiple spawners, garden enter/target/exit, building edits, combat,
  save/load, debug overlays;
- a source scan under `extensions/CPathLib` still finds no gameplay terminology;
- the project contains one descriptor and one build file.

Final gameplay acceptance is yours. The automated checks only establish that nothing structural
regressed.
