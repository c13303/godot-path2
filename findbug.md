Task: Find a rare freeze bug in the native flow-field/steering system, then harden it
Mission
A Godot 4.5 tower-garden game has a rare, sudden near-freeze and you need to (1) find the root cause and (2) strengthen the native agent system against this whole class of fault. Investigate and propose/implement fixes, but do not run the build or the game — the human owns compilation and testing (see AGENTS.md). Do not spawn sub-agents.

The bug (ground truth from the developer)
Happens during the day phase with lots of agents (day-phase agents are shop clients).
Most of the time it runs flawless. Very rarely, it suddenly lags to almost-freeze/near-crash.
Sudden onset, not a gradual slowdown. No error logs when it happens.
Developer suspects an oscillation / feedback loop or a rare state that snowballs.
Huge crowds have been stress-tested and are fine — so raw crowd size is NOT the cause; the crowd steering is already tuned (max_neighbors=16 caps the separation force).
Architecture (where to look)
Native GDExtension (C++17, MinGW) under extensions/flowfield/, driving GDScript gameplay.

extensions/flowfield/steering/steering_system.cpp — the per-frame agent simulation. update_all() (~line 1532) runs every frame on the main thread and integrates every agent (flow-follow, path-follow, wall repulsion, crowd separation, smash/propel, bottleneck traffic, drowning). This is the prime suspect: it's the only per-frame hot path with (until recently) no timing/logging, which is why the freeze produces no logs.
extensions/flowfield/grid/spatial_grid.cpp — uniform spatial hash for neighbor queries. query_neighbors() (line 49) returns every id in a cell box; update(id, old_pos, new_pos) (line 29). Note the fragility: update() locates the agent's current cell from the caller-supplied old_pos, not from the authoritative id_cells[id] map.
extensions/flowfield/steering/steering_system.cpp — force_voisine() (line 596) = crowd separation; ultimate_wall_correction() (line 506, mutates position at 533); resolve_static_obstacle_overlap() (~840–883, mutates position at 883); unregister_agent() (176, swap-and-pop + grid->remove); register_agent_with_id() (240); set_agent_profile() (1048).
extensions/flowfield/godot/steering_system_native.cpp — _process() (718) calls system.update_all(delta) (729), then builds debug labels.
extensions/flowfield/godot/agent_manager_native.cpp — spawn_agent() (178) and unregister_agent() (145) are the GDScript↔native lifecycle seam.
extensions/flowfield/godot/flow_field_native.cpp — async flow-field rebuild worker (worker_loop, ~1018) on a background thread; main thread drains results.
scripts/map/building_manager.gd (~300KB) — day/night gameplay. _process() (1284) is heavily instrumented with _warn_garden_task_lag_us; its whole-frame timer emits debug_nav_total_frame_lag (line 1405). These GDScript detectors are NOT the freeze (they'd have logged) and do not include native update_all.
scripts/misc/cpp_debug_options.gd — pushes debug flags + lag thresholds into native (set_debug_disable_all_debug, set_debug_nav_frame_lag_ms ← lag_detect_fps_threshold_ms).
Already ruled out (don't re-derive)
Crowd O(n²) sort in force_voisine: candidate count is bounded by physical packing (~dozens) and force is capped at max_neighbors=16. At realistic client counts this is ~1ms worst case — nowhere near a freeze. Dead theory.
GDScript gameplay tasks: fully timed; would log. The freeze is silent ⇒ native.
All while loops in native are bounded; the flow worker is on its own thread.
Leading hypotheses (ranked) — a freeze needs a single frame 10–100× normal
Spatial-grid ID leak / snowball (most likely). SpatialGrid::update() trusts old_pos instead of id_cells[id]. On any frame where to_cell(old_pos+offset) disagrees with where the grid actually filed the agent, remove_from_cell silently removes nothing, then push_back adds a duplicate, and id_cells[id] is overwritten — orphaning the old entry permanently. Duplicates accumulate in a hot cell over a session ⇒ query_neighbors returns ever-larger lists ⇒ sudden, silent, worsens-over-time. Fits "oscillation" (an agent jittering on a cell boundary is the likely trigger). Verify: is there ANY path that changes a.position between frames without a paired grid->update? Audit every .position = and every early-continue in update_all, plus external setters (profile change, phase/eating transitions, teleport/respawn, smash/propel).
Orphaned live agents. Any despawn/queue_free path that doesn't reach AgentManagerNative::unregister_agent → SteeringSystem::unregister_agent leaves a live agent in agents (processed forever) and in the grid. Audit all monster/client removal paths in building_manager.gd and elsewhere for a guaranteed unregister. Also check agent_manager_native.cpp:145 — when steering exists it does NOT also call core_mgr->remove_agent; confirm that's intentional and doesn't leak the AgentManager registry.
Global query-radius inflation. force_voisine's query radius is world_radius + max_world_radius; max_world_radius/max_fight_query_padding are maxima over ALL agents (recompute_hitbox_query_extents, line 138). A single agent with a large/garbage profile inflates every agent's cell-box scan simultaneously. Check whether any client/monster/boss profile (or the player agent) can set a large world_radius or fight extents.
Leaked continuous AoE / NaN position. A continuous AoE zone never stop-ped keeps doing per-frame query_neighbors; a NaN/inf integrated position would poison to_cell. Lower probability; confirm isfinite guards exist on integrated positions before grid->update.
Instrumentation already in place (Phase 1 probe — do not duplicate)
update_all() is timed; on a frame exceeding cfg.debug_nav_frame_lag_ms it prints:


debug_steering_update_all_lag: elapsed_ms=… agents=… grid_ids=… grid_leak=… grid_max_cell=… grid_cells=… max_neighbor_query=… active_aoes=…
SpatialGrid has total_id_count(), max_cell_occupancy(), cell_count(). The probe now fires on the threshold regardless of the debug-draw toggle. Interpretation: grid_leak>0 ⇒ hypothesis 1; huge grid_max_cell with small agents ⇒ hot cell; rising agents across a session ⇒ hypothesis 2.

Your deliverables
Root-cause analysis: trace the exact code path that can desync the grid or leak agents. Name the precise line(s). If you cannot prove one statically, say so and specify the minimal extra assertion/log that would confirm it at runtime.
Hardening (behavior-preserving) — propose/implement:
Make SpatialGrid::update() authoritative: remove from id_cells[id]'s stored cell, not from to_cell(old_pos). De-dupe on insert.
Optional debug assertion / self-heal that detects grid_ids != agents.size() and logs the offending id.
Reuse a scratch buffer in query_neighbors instead of returning a fresh std::vector per agent per frame.
Guarantee unregister_agent on every despawn path; add an isfinite guard on integrated positions.
Any oscillation dampening you can justify without changing tuned feel. Each change must keep gameplay identical in the common case; explain why.
Constraints
Do not build or run — the human compiles via MSYS2 MINGW64 ./run.sh (scons -C extensions target=template_debug use_mingw=yes) and tests. You may -fsyntax-only reason about code but assume you cannot execute it.
Keep changes minimal and match surrounding C++ style (French comments exist; mirror the file's conventions).
Don't touch tuning constants in global_config.h unless you show it's the cause.
Present findings as: root cause → evidence (file:line) → proposed fix → risk. Ask before large refactors.