#pragma once

namespace ffcore
{
    struct GlobalConfig
    {
        // =========================================================
        // DEBUG TOGGLES (grouped at top for visibility)
        // =========================================================
        bool debug_disable_all_debug = true;
        bool debug_disable_bottlenecks = false;
        bool debug_draw_world_hitbox = false;
        bool debug_draw_bottleneck_zones = true;
        bool debug_draw_fight_hitbox = false;
        bool debug_show_agent_state_labels = true;
        bool debug_show_zones = true;
        bool draw_flow_field = false;                  // debug: draw flow field arrows
        bool debug_static_obstacles = false;           // log static-obstacle queries/contacts (throttled)
        double debug_redraw_interval = 0.2;
        double debug_redraw_accum = 0.0;
        double debug_label_time = 0.0;

        bool effective_debug_disable_bottlenecks() const { return !debug_disable_all_debug && debug_disable_bottlenecks; }
        bool effective_debug_draw_world_hitbox() const { return !debug_disable_all_debug && debug_draw_world_hitbox; }
        bool effective_debug_draw_bottleneck_zones() const { return !debug_disable_all_debug && debug_draw_bottleneck_zones; }
        bool effective_debug_draw_fight_hitbox() const { return !debug_disable_all_debug && debug_draw_fight_hitbox; }
        bool effective_debug_show_agent_state_labels() const { return !debug_disable_all_debug && debug_show_agent_state_labels; }
        bool effective_debug_show_zones() const { return !debug_disable_all_debug && debug_show_zones; }
        bool effective_draw_flow_field() const { return !debug_disable_all_debug && draw_flow_field; }
        bool effective_steering_debug_draw_enabled() const
        {
            return effective_debug_draw_world_hitbox() ||
                   effective_debug_draw_bottleneck_zones() ||
                   effective_debug_draw_fight_hitbox() ||
                   effective_debug_show_agent_state_labels();
        }

        // Lag detector sensitivities (used by BuildingManager via GlobalConfigNative bindings)
        double debug_nav_frame_lag_ms = 35.0;          // warn if one navigation/gameplay routing frame exceeds this
        double debug_flowfield_rebuild_lag_ms = 35.0;  // warn if one flowfield rebuild exceeds this

        // Runtime control (not strictly debug)
        bool paused = false;

        // =========================================================
        // GAMEPLAY / STEERING CONFIG
        // =========================================================
        double agent_max_speed = 150.0;
        double flow_weight = 0.8;
        double center_pull = 1.0;
        double tile_size = 32.0;

        // Startup/default value. If tile_size is changed through GlobalConfigNative,
        // recompute_from_tile() overwrites this unless wall_avoid_radius is set after it.
        double wall_avoid_radius = tile_size * 1.3;
        double wall_repel_strength = 12;

        double direct_steer_radius = tile_size * 2.5;
        double min_speed_fraction = 0.25;
        double cellgoal_cooldown_sec = 1.0;

        //
        // T2 = target of flowfield
        double target_T2_param_margin = tile_size * 2.0; // margin around target, triggers slowdown (green circle)

        double target_T2_param_speed_ratio = 0.6;          // fraction de la vitesse max visée dans T2
        double target_T2_param_speed_lerp = 0.05;          // bigger = less inertia

        double agent_world_diameter_ratio = 0.9;
        int bottleneck_zone_radius_tiles = 2;
        double bottleneck_reservation_seconds = 1.0;
        double bottleneck_wait_speed_ratio = 0.05;
        double bottleneck_backoff_strength = 0.35;
        double bottleneck_backward_push_ratio = 0.15;
        double bottleneck_lateral_push_ratio = 1.25;
        double priority_separation_bias = 0.30;
        double separation_radius = tile_size;
        double separation_strength = 600.0;
        int max_neighbors = 16;

        // Generic static circular obstacle repulsion (reusable: not tied to any game concept).
        // Moving agents query nearby static obstacles during steering and get pushed out,
        // sliding around them because the obstacles are circular.
        double static_obstacle_repulsion_strength = 400.0;
        double static_obstacle_query_padding = tile_size; // extra query radius around the agent

        double lerp_general = 0.02;

        /* target radius = flow field stop system */
        double target_radius_time_before_stop = 1.0;
        double target_radius_time_group_size_ratio = 0.005; // group_size x ratio

        double movement_threshold = 25;
        double agent_offset_y = 0.0;

        double flow_field_wall_clearance = 0.5; // weight for pushing flow away from walls (distance field blend)
        double lost_retry_seconds = 0.6;

        // Wall-stuck detector: agent wants to move (desired_dir set) but
        // velocity along that direction stays near zero AND wall_repel
        // dominates separation (geometry, not neighbors, is the blocker).
        // Triggers a lost_timer recovery (brake + flow re-query).
        double wall_stuck_detect_seconds = 0.6;      // sustained window before flagging
        double wall_stuck_velocity_ratio = 0.1;      // |v.desired_dir| / max_speed below this counts as "not progressing"
        double wall_stuck_wall_vs_sep_ratio = 1.5;   // |wall_repel| must exceed this * |separation| to attribute to walls

        double friction_factor = 0.91;
        double smash_threshold = 5.0;
        double smash_min_cutoff = 0.20;
        double smash_cap = 500.0;
        double propelled_duration = 8.0;
        double shockwave_speed = 150.0;           // vitesse de propagation de l'onde (units/s)
        double explosion_falloff = 0.1;           // puissance de l'atténuation (1.0 linéaire, >1 plus raide)
        double shockwave_stop_ratio = 2.0;        // rayon de blocage relatif à l'explosion
        double shockwave_stop_duration_ms = 3000; // durée de blocage en millisecondes

        double micro_osc_win_time = 1;                // seconds window before micro-osc counter resets
        int micro_osc_limit_before_cancel = 50000000; // threshold to cancel agent when oscillating
        int micro_osc_label_min = 2;                  // min reversals before the "flow osc" debug label shows
        double debug_label_refresh_interval = 0.2;    // seconds between debug state-label refreshes

        void recompute_from_tile();
    };

    GlobalConfig &globalconfig();
    void reset_globalconfig();

} // namespace ffcore
