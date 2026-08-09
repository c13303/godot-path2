# CPathLib migration status

Last reviewed: 2026-08-09.

## Goal

One reusable navigation/crowd extension that can be dropped into another Godot project, while this
game keeps behaving exactly as it did before the migration.

## Where it stands

The native conversion is structurally done: CPathLib is generic, self-contained and fully bound, no
portable module includes `godot_cpp`, no gameplay terminology appears anywhere in it, and there is
one descriptor, one entry point and one build file.

**The parity claim this document used to make was wrong.** An earlier revision asserted that nothing
in the conversion changed gameplay. Six behavior regressions were later found by reading the
pre-migration C++ (`56ae851`) against the new code, and several of them sat inside this document's
own "behavior that must not change" list. All are fixed; they are recorded below because the way
they were introduced is the main risk in the remaining work.

| Regression | Cause | Fixed in |
| --- | --- | --- |
| Sprayed enemy never recovered | `ImpulseSystem` kept only exponential decay — no lifetime, no residual-speed floor, no launch cap — and added impulse velocity on top of navigation instead of sharing one budget with it | `ImpulseResponseConfig`, `blend_impulse_with_navigation` |
| Sprayed enemy stayed stuck ~8s | `preserve_navigation` was derived from `smash_detach_flow`; it is the successor of the old `smash_preserves_control`, and `detach_flow` was inert before the migration too | `crowd_runtime.gd` weapon paths pass `false` |
| Agent debug state unusable | Debug visuals were drawn in C++ by the old native nodes; CPathLib's nodes are plain `Node` and every `set_debug_*` wrote into a dictionary nothing read | `AgentDebugLabelController` + real setters |
| Crowd overrode obstacles and flow | Separation became a raw sum over uncapped neighbours instead of a unit direction scaled to `separation_weight`; the priority yield and 16-neighbour cap were dropped | `SteeringSolver::separation` restored |
| Agents ejected from chokepoints | The bottleneck forward/lateral clamp on avoidance was not ported, and the navigation weight (authored 5.0) was implicitly 1.0 | `CrowdWorld::steer_direction` |
| Debug speed multiplier player-only | Agents copy max speed into their profile at registration; nothing re-pushed it | `AgentHandleRegistry.refresh_agent_speeds()` |

Every one of these was a **project↔library boundary** fault, not a library fault. The decisive
example: `crowd_world_2d_smoke.gd` already asserts that an impulse opposing navigation cancels once
control returns, and it passed the entire time spray was broken — the library was correct and the
project handed it the wrong field.

`NATIVE_MIGRATION_CONTRACT.md` is the historical inventory. `extensions/CPathLib/REUSE.md` is the
standalone-repository checklist.

## Done

1. **Relocatable descriptor.** `cpathlib.gdextension` resolves `bin/cpathlib.dll` and the three
   MinGW runtime DLLs relative to itself, so the folder can be dropped anywhere.
2. **One build file.** `run.sh` builds through `extensions/CPathLib/SConstruct` — the file a
   standalone copy ships — so the daily build and the packaged build are the same. The duplicate
   `extensions/Sconstruct` and the unused `extensions/config.py` are gone.
3. **Runnable checks.** `scons ... tests` builds the two portable unit tests via an alias, and
   `check.sh` builds everything and runs the unit tests, the three CPathLib smokes and the four
   project smokes, reporting pass/fail per check. Commands are documented in the README.
4. **Boundary regression tests.** `scripts/native/migration_parity_smoke.gd` asserts one contract
   per regression above: authored configuration actually reaches the world, a weapon impulse
   releases the agent once control returns, an impulse always ends within its lifetime, separation
   magnitude does not scale with crowd size, and the debug toggles reach something.
5. **Honest docs.** README states Godot 4.5.1 and Windows/MinGW-only, documents the verification
   commands, and notes that library self-tests cannot catch consumer mapping faults.

## Remaining

1. **Add a LICENSE.**
2. **Extract.** Copy `extensions/CPathLib` to its own private repository and consume it back here as
   a pinned submodule at the same path. `demo/navigation_demo.tscn` hardcodes its script path in an
   `ext_resource`; scene files cannot use relative paths, so that stays a known one-line edit when
   the folder moves. Confirm with `check.sh` plus a normal day/night pass.

Done since the last review: the `godot-cpp` revision is recorded in the README; the navigation-area
API no longer requires a consumer to say "garden" (the `garden_*` names remain a complete alias set,
checked by the parity smoke); and **`check.sh` passes end to end**, verified over three consecutive
runs. That run also turned up four defects, listed below, all fixed.

### Found by the first real run of the checks

| Defect | Cause |
| --- | --- |
| Test objects would not compile | `g++` will not create its output directory and SCons does not do it for an explicitly named `Object()` target |
| Build worked only from an MSYS2 shell | `SConstruct` hardcoded `/mingw64/bin/g++`, a path that exists only inside that shell |
| Compiler started and died silently | SCons runs commands with a minimal environment, so `g++.exe` could not find its own runtime DLLs |
| Every headless smoke touching `CrowdRuntime` failed to compile | `AgentDebugLabelController` read `FlowAgent.PHASE_*`, pulling `character.gd` → `agent_definition_service.gd` → `building_manager.gd` → the `GameState` autoload, and autoloads do not exist under `--script` |
| The game would not start at all, though every check passed | `agent_phase.gd` used `class_name`, which only exists once the editor has imported the file. Consumed via `preload()` instead, so a fresh clone cannot hit it |
| Agent debug labels errored every frame | `z_index = 4097` exceeds `RenderingServer::CANVAS_ITEM_Z_MAX` (4096) |

The first three were only reachable from outside the author's own shell — exactly what "the build a
standalone consumer runs" means. The fourth is the same class of fault as the migration regressions:
a boundary the library never sees.

The `class_name` one is worth remembering: **the checks all passed while the game was completely
unable to start.** A global class name resolves during a `--script` run but does not exist until the
editor imports the file, so the suite is not a substitute for launching the game. `check.sh` covers
contracts; only `run.sh` covers "it boots".

`game_player_collision_smoke.gd` also had two latent bugs of its own, both pre-existing and both
invisible until there was a runner: it read `_baseline_goal_cell` on the line after `set_cell_blocked`
though that recovery is asynchronous, and it drove the player into a freshly uploaded runtime blocker
without waiting for the collision flow to be rebuilt. Both now wait on the real signal rather than a
frame count.

## Known divergences, accepted

Found during the audit, judged not worth reverting. Listed so nobody rediscovers them as bugs.

- **Soft wall avoidance is gone.** The old steering fed a `wall_repel` force (strength 12, radius
  `tile * 1.3`) into the desired direction. CPathLib has only hard collision resolution with
  sliding. The flow field's `wall_clearance_weight` biases the field away from walls, which covers
  flow agents; path-following and manual agents scrape where they used to steer off.
- **Flow-agent acceleration is a redesign.** The old code used a frame-rate-dependent
  `velocity.lerp(target, 0.02)`; the new one uses 900/1200 px/s². Agents accelerate and turn
  noticeably faster.
- **Hitbox, bottleneck-zone and flow-field debug overlays have no owner.** They were drawn in C++.
  `CppDebugOptions` still exports the flags and `_call_if_available` skips them. Agent state labels
  are the only restored visual.
- **Write-only config remains:** `NativeSimulationConfig.impulse_decay`, `radial_falloff_exponent`,
  `SimulationConfigService.draw_flow_field`. `detach_flow` is still an authored weapon field that
  does nothing — as it did before the migration.

## Ownership boundary

CPathLib owns generic, instance-scoped simulation: A* and flow fields, async flow construction and
stale-result protection, blocker and directional-traversal channels, gardens/areas/portals/routes,
bottleneck discovery and gating, crowd profiles/agents/cohorts, separation, terrain speeds, wall and
static-obstacle response, arrival and recovery policies, impulses and external velocities, filtered
spatial queries, effect volumes, and pooled swept projectiles. It never calls into the game.

This project owns the meaning: `AgentHandleRegistry` (node mapping, selection cohorts, presentation
events), `NavigationFlowCoordinator` (routing requests, flow/cohort lifetimes),
`NavigationGridUploadService` (authored map data to neutral cells/channels), `NativeSimulationConfig`
(numeric defaults), `CrowdRuntime` (phases, damage, combat forces, effect events), `ProjectileRuntime`
(weapon resources, impact interpretation), and `AgentDebugLabelController` (debug presentation).

Day/night phases, monsters, clients, villagers, gardens-as-gameplay, tantrums, buildings, weapons,
drowning, damage, and selection never cross into CPathLib. Category masks, query shapes, caller
tokens, and traffic group tokens are opaque values the game assigns meaning to.

## Behavior that must not change

These are the conversion-sensitive contracts. The starred ones now have an automated check; the rest
are still manual-only, which is why the audit above was needed.

- manual movement speed in every direction, and the established wall-slide behavior;
- flow-driven agents freeze while an async cohort flow is pending, and resume when it installs;
- small cohorts stop immediately near the goal, larger cohorts use the established radius and
  staggered delay, and `never_rest` maps to continue-at-goal;
- agents with no flow direction wait, then recover toward the nearest navigable cell at the reduced
  speed, without swallowing impulse- or external-owned motion;
- flow agents blocked by geometry brake, but manual player movement never does;
- bottlenecks feed both flow steering and occupancy gating, and crowd pressure cannot eject a
  queueing agent backwards out of a chokepoint;
- crowd pressure and gameplay impulses respect authored per-agent resistances, and separation
  strength does not scale with crowd depth *;
- gameplay impulses end — by opposition cancel, lifetime, or speed floor — and share one speed
  budget with navigation rather than stacking on it *;
- paused agents stop moving but may still be displaced when the project allows it;
- force-isolated agents reject impulses, effect ticks, damage, and projectile hits, while directional
  drift stays independently controllable;
- projectile sweeps and area attenuation use the sprite-derived query AABBs;
- budgeted projectile force is allocated once, direct-hit first then front-to-back, while damage
  still applies to every eligible target;
- propelled/control-impaired visuals are driven from native impulse state;
- authored configuration reaches the native world rather than being silently skipped *;
- empty non-current selection cohorts are released rather than accumulating.

## Checks before calling it done

- `check.sh` passes end to end;
- the descriptor loads from a path other than `extensions/CPathLib` and all four classes register;
- a normal day and night: multiple spawners, garden enter/target/exit, building edits, combat,
  a client tantrum against two adjacent buildings, save/load, debug overlays;
- a source scan under `extensions/CPathLib` still finds no gameplay terminology;
- the project contains one descriptor and one build file.

Final gameplay acceptance is yours. The automated checks establish that the contracts marked above
still hold; everything else in the list is still only as good as the manual pass.
