# Single-extension native migration contract

This document is the pass-1 contract for replacing the temporary two-extension state with one
generic CPathLib GDExtension. It is intentionally outside `extensions/CPathLib` because it names
the host project's legacy API.

## Non-negotiable end state

- One native source tree: `extensions/CPathLib`.
- One descriptor, one entry point, and one runtime DLL.
- Rabbit Game uses the same public CPathLib API as another Godot project.
- No duplicate A*, flow, crowd, steering, force, spatial-query, or projectile implementation.
- No gameplay phase, damage rule, actor category name, scene path, node lookup, or presentation
  rule in CPathLib.
- Host gameplay remains in GDScript and composes generic handles, masks, profiles, queries, events,
  navigation sources, and motion constraints.

The current `extensions/rabbit_game_native` directory is migration input only. It must be deleted
in pass 8.

## Implementation progress

- Pass 1 complete: all legacy bindings and native source files have final owners and removal gates.
- Pass 2 complete: CPathLib owns instance configuration, generational flow/profile/agent/cohort
  handles, simultaneous flow records, asynchronous flow status, and cohort-to-flow assignment.
  Existing single-flow adapter calls are backed by the same stores.
- Passes 3-8 remain required; the temporary legacy extension is still active.

## Source-file disposition

This table covers the implementation beneath the bound API, including helpers that Godot never
calls directly. Every function in a listed file must move to the stated owner, be replaced by an
already-existing implementation in that owner, or be deleted only after its callers and parity
fixture prove it obsolete. Copying a function while retaining the legacy implementation is not a
valid migration step.

| Legacy source | Final disposition |
|---|---|
| `agent_manager/agent_manager.*` | Agent storage, handle lifetime, cohort membership, and route references move into generic `CrowdWorld` modules. Node references and lifecycle signals move to the Godot `AgentHandleRegistry`. |
| `core/global_config.*` | Delete the process singleton. Navigation settings become `NavigationWorld` instance configuration; simulation settings become `CrowdWorld` configuration or agent profiles; projectile settings become explicit projectile profiles; gameplay and debug values become project resources. |
| `core/nav_config.h` | Replace fixed/process-wide values with typed, instance-owned generic configuration. Project defaults are supplied by Godot rather than compiled into CPathLib. |
| `core/nav_services.*` | Delete the service locator and globals. Owners receive explicit world references or stable handles; no replacement global registry is permitted. |
| `flow/flow_field_manager.*` | Flow allocation, reuse, job state, cancellation, and sampling move into the existing generic `NavigationWorld` flow store. Existing CPathLib flow algorithms remain the sole builders. |
| `steering/agent.*` | Neutral kinematic, navigation-source, traffic, terrain, impulse, and diagnostic state moves into focused generic crowd data types. Phase, damage, actor-class, and Node state move to Godot. |
| `steering/directional_cell_field.cpp` | Sparse directional-field storage becomes a generic instance-owned `CrowdWorld` facility addressed by handles, never by gameplay phase. |
| `steering/traffic_right_of_way_resolver.*` | Move into a focused generic crowd traffic resolver using handles, masks, priorities, and configuration values only. |
| `steering/steering_system.*` | Split the monolithic update into cohesive generic crowd modules while preserving the update order below. Navigation sampling, avoidance, contacts, obstacles, terrain, forces, integration, and queries must each have one implementation. Gameplay decisions remain in Godot. |
| `projectile/projectile_system.*` | Motion, pooling, swept collision, filtering, lifetime, and neutral impact production move into `ProjectileWorld`. Damage, smash presets, end effects, visuals, and actor rules move to Godot. |
| `godot/flow_field_native.*` | Replace with `NavigationWorld2D` APIs plus project grid-upload and debug scripts. Do not retain a forwarding legacy class after callers migrate. |
| `godot/spatial_grid_native.h` | Delete the node and wrapper; the crowd world owns its internal spatial index. |
| `godot/steering_system_native.*` | Replace with focused `CrowdWorld2D` bindings and Godot gameplay/debug services. Do not expose project phases or Node mappings through CPathLib. |
| `godot/agent_manager_native.*` | Replace native handle/cohort calls with `CrowdWorld2D`; replace Node mapping and gameplay signals with `AgentHandleRegistry`. |
| `godot/global_config_native.*` | Replace with explicit world/profile application from project resources, then delete the wrapper. |
| `godot/projectile_system_native.*` | Replace with `ProjectileWorld2D`; Godot consumes neutral impacts and applies combat effects. |
| `register_types.*`, `rabbit_game_native.gdextension` | Delete after the final scene caller is migrated. CPathLib's registration and descriptor become the only native entry point. |

The final implementation should use focused modules rather than transplanting the roughly
3,000-line legacy steering file into another large file. Splitting files is an ownership cleanup,
not permission to change formulas, timing, ordering, or defaults during migration.

## Inventory result

The legacy module contains 31 C++ source/header files and 10,161 lines. It currently registers six
classes and 224 unique bound method names (227 binding occurrences). A textual scan finds 106
method names in project scripts/scenes and 118 with no project text reference. Textual absence does
not alone authorize deletion: editor properties, native-to-native calls, scene serialization, and
dynamic names are checked again when each owner migrates.

| Legacy class | Current responsibility | Final owner |
|---|---|---|
| `FlowFieldNative` | TileMap upload, blockers, multiple group flows, async lifecycle, sampling, debug drawing | `NavigationWorld2D` plus Godot grid-upload script and project debug script |
| `SpatialGridNative` | unbound native spatial-grid container | internal `CrowdWorld` spatial index; no Godot node |
| `SteeringSystemNative` | crowd simulation, paths, forces, obstacles, queries, phases, AoE/damage, node synchronization, debug drawing | `CrowdWorld2D` generic simulation/query APIs plus Godot gameplay/debug scripts |
| `AgentManagerNative` | numeric IDs, groups, Node mapping, events, route assignment | generational agent/cohort handles in `CrowdWorld2D` plus a Godot `AgentHandleRegistry` |
| `GlobalConfigNative` | process-wide navigation, steering, combat, and debug values | instance-owned CPathLib configs/profiles plus project configuration/debug resources |
| `ProjectileSystemNative` | pooled motion, static/agent collision, direct effects, end effects, impact events | generic `ProjectileWorld2D`; Godot applies gameplay effects from impact events |

## Final generic public surface

The exact names may be tightened while implementing, but responsibility boundaries may not move.

### `NavigationWorld2D`

- Instance-owned grid definition, walkability, physical blockers, traversal costs, and revisions.
- Named/numbered blocker and traversal-policy channels.
- Generational flow handles with request, cancellation, readiness, revision, sampling, route-cost,
  and release APIs.
- Default and per-flow build options: clearance, bottleneck detection, blocker-channel mask, and
  directional-constraint channel.
- A*, gardens/areas, portals, route segments, flow snapshots, and generic diagnostics.
- No TileMap node lookup. Godot scripts convert arbitrary level layers into packed cells and upload
  them explicitly.

### `CrowdWorld2D`

- Instance-owned agent and cohort handles.
- Per-agent profile, category mask, position, velocity, navigation source, flow handle, path,
  manual input, paused state, motion override, and diagnostics.
- The established fixed-step ordering for separation, contacts, right-of-way, wall/static obstacle
  response, terrain speed, bottleneck gating, impulses, control suppression, external velocity,
  integration, and depenetration.
- Generic static obstacles, sparse directional fields, terrain channels, circle/cone/AABB agent
  queries, and batched state exchange.
- Generic effect volumes may track overlap/tick/exit and optionally submit impulses. They never
  contain damage, weapon immunity, eating, drowning, or named actor classes.

### `ProjectileWorld2D`

- Instance-owned projectile types and pools.
- Position, direction, inherited velocity, radius, lifetime, owner handle, category/mask, and
  caller payload/token.
- Swept collision against generic static channel masks and crowd category masks.
- Impact/expiry events containing handles, cells, masks, position, direction, type handle, and
  caller token.
- No damage, smash, AoE, weapon, or actor-specific rule. Godot responds to impacts by calling
  generic crowd query/impulse APIs and applying gameplay damage itself.

### Godot-owned services

- `AgentHandleRegistry`: Node-to-handle and handle-to-Node mapping, lifecycle signals, stale-node
  cleanup, and registration diagnostics.
- Grid upload: TileMap layer interpretation, map bounds, fence policy selection, and conversion to
  packed cells/channels.
- Gameplay navigation state: garden missions, eating/waiting/drowning states, retargeting, and
  selection state.
- Combat: damage, weapon immunity, affected gameplay categories, effect visuals, and health.
- Debug presentation and lag thresholds.

## Legacy method disposition

Every bound method is accounted for below. A method may expand into more than one generic call; the
legacy name is not preserved after its last caller migrates.

### `FlowFieldNative`

| Legacy methods | Replacement |
|---|---|
| `set_floor_layer`, `set_wall_layer`, `set_navigation_blocking_layer`, `set_water_layer`, `set_blocking_layer`, `get_floor_layer`, `get_wall_layer`, `get_navigation_blocking_layer`, `get_water_layer`, `get_blocking_layer`, `set_map_bounds` | Godot grid-upload service selects layers and calls `NavigationWorld2D.configure_grid`; no Node pointers retained natively |
| `set_extra_blocking_cells`, `clear_extra_blocking_cells`, `set_fence_blocking_cells`, `clear_fence_blocking_cells`, `set_cell_blocked` | generic blocker channels and localized topology edits |
| `set_directional_traversal_field`, `clear_directional_traversal_field`, `clear_directional_traversal_fields` | generic directional-constraint channels |
| `rebuild_async`, `request_flow_to_group`, `assign_flow_to_group`, `mark_group_flow_queued`, `is_group_flow_request_ready`, `cancel_group_flow_request`, `are_async_flows_idle` | flow-handle requests/status/cancellation plus cohort-to-flow assignment; queued/computing is derived request state |
| `compute_flow_dir`, `compute_group_flow_dir`, `group_route_cost_at_world` | sample direction/cost by flow handle |
| `compute_distance_field_global` | part of configured grid/flow build, using the single generic builder |
| `get_flow_pool_debug_snapshot` | generic read-only flow diagnostics |
| `set_debug_draw`, `get_debug_draw`, `set_debug_draw_group` | project debug script reads diagnostics and draws; simulation does no presentation work |

### `AgentManagerNative`

| Legacy methods/signal | Replacement |
|---|---|
| `spawn_agent`, `unregister_agent` | `CrowdWorld2D.add_agent`/`remove_agent` returning generational handles |
| `create_group`, `dissolve_group`, `cleanup_groups`, `assign_agent`, `mark_group_has_order`, `count_group_members`, `count_group_route_references`, `get_group_flow_wait`, `set_current_selected_group` | generic cohort handles/membership/route state; current selection remains Godot UI state |
| `assign_agent_path`, `detach_agent_path`, `agent_path_arrived`, `detach_agent_flow`, `set_agent_waiting_flow_group` | generic navigation-source, path, flow-handle, and route-progress APIs |
| `set_agent_paused`, `set_agent_never_rest` | generic paused and destination/idle policy fields |
| `set_agent_traffic_state` | generic traffic group token and priority |
| `set_agent_phase` | no phase enum in CPathLib; Godot selects path/flow/manual/override/paused state and an optional directional-field handle explicitly |
| `update_godot_agent`, `find_node_by_agent`, `get_registration_debug_snapshot`, `send_agent_event`, `agent_event` | Godot `AgentHandleRegistry`; generic CPathLib emits only typed/neutral handle state changes |

The existing `agent_event` payloads observed in use are `spawned` and
`propelled_state_update`. The registry owns `spawned`; generic agent diagnostics/state transitions
allow Godot to produce propelled/control-feedback events.

### `SteeringSystemNative`: agent and navigation

| Legacy methods | Replacement |
|---|---|
| `set_flowfield`, `set_grid` | explicit `CrowdWorld2D` connection to a `NavigationWorld2D`; spatial index is internally owned |
| `register_node_mapping`, `get_agent_id` | Godot `AgentHandleRegistry` |
| `set_agent_control_mode`, `set_agent_input`, `set_agent_manual_motion` | generic manual navigation source and per-agent acceleration/deceleration profile |
| `set_agent_profile` | typed generic agent profile; gameplay chooses values and category masks |
| `set_agent_position`, `get_agent_position`, `get_agent_velocity` | generic handle state access and batched variants |
| `set_paused` | instance/world pause, not global configuration |
| `get_agents_in_map_cell` | generic spatial query returning agent handles |

### `SteeringSystemNative`: terrain, obstacles, and directional fields

| Legacy methods | Replacement |
|---|---|
| `set_terrain_speed_cell`, `set_terrain_speed_cells`, `clear_terrain_speed_cell`, `clear_terrain_speed_cells`, `replace_terrain_speed_channel`, `clear_terrain_speed_channel` | generic terrain-speed channels |
| `register_static_obstacle`, `unregister_static_obstacle`, `clear_static_obstacles`, `get_static_obstacle_count` | generic generational static-obstacle handles |
| `set_directional_cell_field`, `clear_directional_cell_field`, `clear_directional_cell_fields` | generic directional-field handles |
| `bind_phase_directional_cell_field`, `clear_phase_directional_cell_field` | removed as a phase concept; Godot assigns/clears a directional-field handle on each affected agent |

### `SteeringSystemNative`: impulses, areas, and events

| Legacy methods | Replacement |
|---|---|
| `apply_smash_impulse`, `apply_navigation_preserving_impulse` | one generic impulse request with priority, delay, decay, navigation-preservation, control-suppression, and feedback-neutral state |
| `create_external_velocity_source`, `set_agent_external_velocity`, `release_agent_external_velocity` | generic external-velocity source handles |
| `apply_area_smash`, `apply_cone_smash`, `apply_explosion`, `apply_explosion_filtered` | generic circle/cone query plus batched impulse submission using category masks and ignored handles |
| `spawn_aoe_zone`, `start_continuous_aoe`, `update_continuous_aoe`, `stop_continuous_aoe` | generic effect-volume handles with overlap/tick/exit events and optional impulse cadence |
| `take_damage_events` | deleted as damage API; Godot receives neutral effect/impact overlap events and applies damage rules |

The currently textually unused one-shot impulse/area methods are still covered because projectile
and effect-volume internals use the same behavior. Their generic implementation must be the only
implementation, even if their old Godot bindings are not recreated.

### `SteeringSystemNative`: diagnostics and drawing

| Legacy methods | Replacement |
|---|---|
| `get_agent_debug_snapshot` | generic typed/neutral agent diagnostics; project adds phase labels |
| `set_debug_disable_all_debug`, `get_debug_disable_all_debug`, `set_debug_draw_world_hitbox`, `get_debug_draw_world_hitbox`, `set_debug_draw_bottleneck_zones`, `get_debug_draw_bottleneck_zones`, `set_debug_disable_bottlenecks`, `get_debug_disable_bottlenecks`, `set_debug_draw_fight_hitbox`, `get_debug_draw_fight_hitbox`, `set_debug_show_agent_state_labels`, `get_debug_show_agent_state_labels`, `set_debug_redraw_interval`, `get_debug_redraw_interval`, `set_debug_static_obstacles`, `get_debug_static_obstacles` | project debug configuration and drawing; generic diagnostics remain read-only and debug toggles cannot change simulation behavior |

### `ProjectileSystemNative`

| Legacy methods | Replacement |
|---|---|
| `register_type` | register generic projectile profile; smash/damage/end-AoE fields become a caller token resolved by Godot |
| `fire`, `fire_with_velocity` | spawn projectile with type handle, transform, inherited velocity, owner handle, target category mask, and caller token |
| `get_active_positions`, `get_active_projectile_states`, `get_active_count`, `get_type_count` | generic batched projectile state/count queries |
| `get_impacts` | generic drain/take impact events; events contain no gameplay damage/effect decision |
| `set_static_collision_cells`, `clear_static_collisions` | generic static collision channel upload |
| `set_static_collision_layers`, `set_wall_layer`, `clear_walls` | Godot converts TileMap layers to cells/channels before upload |
| `set_steering`, `set_grid` | explicit `ProjectileWorld2D` to `CrowdWorld2D` connection; no separate spatial-grid node |
| `set_paused` | instance pause |

### `GlobalConfigNative`

Every getter/setter pair is migrated according to ownership; the global node and
`globalconfig()` accessor are deleted.

| Settings | Final owner |
|---|---|
| `flow_weight`, `center_pull`, `wall_avoid_radius`, `wall_repel_strength`, `movement_threshold`, `direct_steer_radius`, `min_speed_fraction`, `cellgoal_cooldown_sec`, `target_T2_param_margin`, `target_T2_param_speed_ratio`, `target_T2_param_speed_lerp`, `separation_radius`, `separation_strength`, `max_neighbors`, `lerp_general`, `lost_retry_seconds`, `agent_world_diameter_ratio` | instance `CrowdWorld` configuration or per-agent profile, using neutral names such as arrival radius/slowdown |
| `tile_size`, `flow_field_wall_clearance`, `bottleneck_zone_radius_tiles` | `NavigationWorld` grid/build configuration |
| `agent_max_speed` | per-world default profile copied into each new agent; existing agents change only through explicit profile updates |
| `bottleneck_reservation_seconds`, `bottleneck_wait_speed_ratio`, `bottleneck_backoff_strength`, `bottleneck_backward_push_ratio`, `bottleneck_lateral_push_ratio`, `priority_separation_bias`, `traffic_right_of_way_enabled`, `traffic_push_force`, `traffic_push_cooldown`, `traffic_control_lock_seconds` | instance `CrowdWorld` traffic configuration |
| `friction_factor`, `smash_threshold`, `smash_min_cutoff`, `smash_cap`, `shockwave_speed`, `explosion_falloff`, `shockwave_stop_ratio`, `shockwave_stop_duration_ms` | neutral impulse/effect defaults in project resources; values are supplied explicitly to generic requests |
| `draw_flow_field`, `debug_show_zones`, `debug_nav_frame_lag_ms`, `debug_flowfield_rebuild_lag_ms` | project debug/telemetry configuration |
| `debug_show_plant_zones`, `debug_plantff_frame_lag_ms`, `debug_plantff_ff_lag_ms` | obsolete aliases removed after callers migrate to project debug names |
| `get_agent_world_radius` | derived by Godot or generic profile query from configured agent radius |
| `reset_defaults` | reset the project resource and explicitly reapply affected instance configs/profiles |

This accounts for all bound `get_*` and `set_*` methods corresponding to the settings above.

Exact bound-method inventory for the settings table:

```text
get_flow_weight / set_flow_weight
get_agent_max_speed / set_agent_max_speed
get_center_pull / set_center_pull
get_tile_size / set_tile_size
get_wall_avoid_radius / set_wall_avoid_radius
get_wall_repel_strength / set_wall_repel_strength
get_movement_threshold / set_movement_threshold
get_flow_field_wall_clearance / set_flow_field_wall_clearance
get_lost_retry_seconds / set_lost_retry_seconds
get_direct_steer_radius / set_direct_steer_radius
get_min_speed_fraction / set_min_speed_fraction
get_cellgoal_cooldown_sec / set_cellgoal_cooldown_sec
get_target_T2_param_margin / set_target_T2_param_margin
get_target_T2_param_speed_ratio / set_target_T2_param_speed_ratio
get_target_T2_param_speed_lerp / set_target_T2_param_speed_lerp
get_separation_radius / set_separation_radius
get_agent_world_diameter_ratio / set_agent_world_diameter_ratio
get_agent_world_radius
get_bottleneck_zone_radius_tiles / set_bottleneck_zone_radius_tiles
get_bottleneck_reservation_seconds / set_bottleneck_reservation_seconds
get_bottleneck_wait_speed_ratio / set_bottleneck_wait_speed_ratio
get_bottleneck_backoff_strength / set_bottleneck_backoff_strength
get_bottleneck_backward_push_ratio / set_bottleneck_backward_push_ratio
get_bottleneck_lateral_push_ratio / set_bottleneck_lateral_push_ratio
get_priority_separation_bias / set_priority_separation_bias
get_traffic_right_of_way_enabled / set_traffic_right_of_way_enabled
get_traffic_push_force / set_traffic_push_force
get_traffic_push_cooldown / set_traffic_push_cooldown
get_traffic_control_lock_seconds / set_traffic_control_lock_seconds
get_separation_strength / set_separation_strength
get_max_neighbors / set_max_neighbors
get_lerp_general / set_lerp_general
get_friction_factor / set_friction_factor
get_smash_threshold / set_smash_threshold
get_smash_min_cutoff / set_smash_min_cutoff
get_smash_cap / set_smash_cap
get_shockwave_speed / set_shockwave_speed
get_explosion_falloff / set_explosion_falloff
get_shockwave_stop_ratio / set_shockwave_stop_ratio
get_shockwave_stop_duration_ms / set_shockwave_stop_duration_ms
get_draw_flow_field / set_draw_flow_field
get_debug_show_zones / set_debug_show_zones
get_debug_nav_frame_lag_ms / set_debug_nav_frame_lag_ms
get_debug_flowfield_rebuild_lag_ms / set_debug_flowfield_rebuild_lag_ms
get_debug_show_plant_zones / set_debug_show_plant_zones
get_debug_plantff_frame_lag_ms / set_debug_plantff_frame_lag_ms
get_debug_plantff_ff_lag_ms / set_debug_plantff_ff_lag_ms
reset_defaults
```

### `SpatialGridNative`

It binds no methods, signals, or properties. No script uses it directly. The node is deleted when
the generic crowd owns the only spatial index. Projectile and query systems access that index
through explicit `CrowdWorld` APIs, never through a process-global pointer.

## Process-wide state to eliminate

| Current accessor/state | Uses | Replacement |
|---|---|---|
| `globalconfig()` / `reset_globalconfig()` | flow, steering, projectiles, Godot config | configs owned by each navigation/crowd/projectile instance |
| `flowfields()` static manager | group flow pool and reuse | flow store owned by `NavigationWorld` |
| `get_global_agent_manager()` / `g_agent_manager` | flow assignment, steering, node adapter | agent/cohort store owned by `CrowdWorld`; Node registry in Godot |
| `get_global_steering_system()` / `g_steering` | flow reactivation, agent manager, projectiles | explicit object references/handles between instance owners |

Multiple independent worlds must work in one process before any global accessor is deleted from the
migration source.

## Current lifecycle and update-order contract

The current main scene instantiates siblings in this order:

1. global configuration;
2. agent manager;
3. spatial grid;
4. flow-field node and its Godot layer-upload child;
5. steering node;
6. projectile node;
7. generic `NavigationWorld2D` used by building A*.

Construction-time globals currently make the agent/steering pointers available before `_ready`.
At runtime, completed async group flows are installed by the flow node before steering updates, and
projectiles update after steering. The one-world replacement must make this explicit:

1. poll/install navigation jobs;
2. update effect volumes and contact/right-of-way requests;
3. update delayed impulses, suppression timers, and decay;
4. rebuild bottleneck occupancy;
5. update external velocity, navigation, avoidance, terrain, integration, and depenetration per
   agent;
6. publish batched states/diagnostics;
7. update projectiles and publish impacts;
8. Godot consumes neutral state/impact/effect events and applies gameplay.

Within the established steering update, the parity-sensitive order is:

1. expire bottleneck reservations;
2. update one-shot/continuous effect-volume membership and cooldowns;
3. update contact and right-of-way cooldowns, then submit pushes;
4. activate delayed impulses;
5. update control-suppression timers and impulse decay;
6. count current bottleneck occupancy;
7. update external velocities;
8. handle paused/waiting/override modes;
9. calculate wall, agent separation, and static-obstacle contributions;
10. choose manual, path, flow, directional-field, or recovery navigation;
11. apply arrival slowdown and bottleneck gating;
12. combine autonomous, impulse, and external velocities;
13. apply terrain-scaled integration, wall correction, and static-obstacle depenetration;
14. update spatial membership and diagnostics.

Changing this order requires an explicit fixture showing that the relevant trajectory is unchanged
or an owner-approved behavior change.

## Parity fixtures required before deletion

| Domain | Required comparison |
|---|---|
| grid/flow | walkable/physics masks, origin/size, direction, route cost, clearance, bottlenecks, fence policy, directional constraints |
| async flows | queued/computing/ready/cancel/stale behavior, group/cohort lifetime reuse, installation order |
| agent lifecycle | handle reuse, group membership, Node mapping, unregister, stale handles, batched state order |
| steering | fixed-delta positions/velocities for manual, path, flow, arrival, lost recovery, walls, crowd, static obstacles, bottlenecks, pause, and directional override |
| forces | delay, priority, decay, control suppression, navigation preservation, category filters, external velocity response/expiry |
| effect volumes | circle/cone membership, re-entry, tick cadence, follow offset, ignored owner, category filters |
| projectiles | pool exhaustion/reuse, swept static/agent collision, inherited velocity, mask filtering, lifetime, impact position/order |
| Godot integration | day/night startup, multiple spawners, garden enter/target/exit, visitors/sheep, building edits, combat, debug, save/load |

## Removal gates

A legacy class is removed only when all of the following are true:

1. every live direct and dynamic caller uses the new owner;
2. its scene node and NodePaths are gone;
3. its native-to-native responsibilities have generic equivalents;
4. parity fixtures for its responsibility pass;
5. no registration, include, descriptor, documentation, or string-method reference remains;
6. deleting its source does not make another implementation appear elsewhere.

Final mechanical checks must find no `rabbit_game_native`, legacy native class name, process-global
accessor, project phase/category term, or second descriptor/DLL in the extension build.
