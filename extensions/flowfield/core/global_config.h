#pragma once

namespace ffcore
{
    struct GlobalConfig
    {
        double agent_max_speed = 150.0;
        double flow_weight = 0.8;
        double center_pull = 1.0;
        double tile_size = 16.0;

        double wall_avoid_radius = tile_size * 1.2;
        double wall_repel_strength = 12;

        double direct_steer_radius = tile_size * 2.5;
        double min_speed_fraction = 0.25;
        double cellgoal_cooldown_sec = 1.0;

        //
        // T2 = target of flowfield
        double target_T2_param_margin = tile_size * 1.0; // margin around target, triggers slowdown (green circle)

        double target_T2_param_speed_ratio = 0.6;          // fraction de la vitesse max visée dans T2
        double target_T2_param_speed_lerp = 0.05;          // bigger = less inertia
        double target_T2_slow_threshold = tile_size * 3.0; // slowdown starts this many tiles from claim

        double separation_radius = tile_size;
        double separation_strength = 400.0;
        int max_neighbors = 16;

        double lerp_general = 0.02;
        bool enable_claim_force = true;
        bool enable_claiming_tiles = false;

        /* target radius = flow field only stop ssystem (enable_claiming_tiles = false )*/
        double target_radius_time_before_stop = 1.0;
        double target_radius_time_group_size_ratio = 0.005; // group_size x ratio

        double movement_threshold = 25;
        double agent_offset_y = 0.0;

        double flow_field_wall_clearance = 0.5; // weight for pushing flow away from walls (distance field blend)

        double friction_factor = 0.91;
        double smash_threshold = 5.0;
        double smash_min_cutoff = 0.20;
        double smash_cap = 500.0;
        double propelled_duration = 8.0;
        double shockwave_speed = 150.0;           // vitesse de propagation de l'onde (units/s)
        double explosion_falloff = 0.1;           // puissance de l'atténuation (1.0 linéaire, >1 plus raide)
        double shockwave_stop_ratio = 2.0;        // rayon de blocage relatif à l'explosion
        double shockwave_stop_duration_ms = 3000; // durée de blocage en millisecondes

        /* drawing options */
        bool draw_claimed_path = false; // debug: draw agent→claim links
        bool draw_flow_field = false;   // debug: draw flow field arrows

        double micro_osc_win_time = 1;                // seconds window before micro-osc counter resets
        int micro_osc_limit_before_cancel = 50000000; // threshold to cancel agent when oscillating

        void recompute_from_tile();
    };

    GlobalConfig &globalconfig();
    void reset_globalconfig();

} // namespace ffcore
