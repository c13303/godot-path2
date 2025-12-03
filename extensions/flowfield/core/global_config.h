#pragma once

namespace ffcore
{
    struct GlobalConfig
    {
        double flow_weight = 1.0;
        double center_pull = 1.0;
        double tile_size = 16.0;

        double wall_avoid_radius = tile_size * 1.2;
        double wall_repel_strength = 8.4;

        double direct_steer_radius = tile_size * 2.5;
        double min_speed_fraction = 0.25;
        double cellgoal_cooldown_sec = 1.0;

        double target_slow_radius = tile_size * 3.0;
        double target_approach_radius = tile_size * 1.0;
        double target_occupy_radius = tile_size * 0.4;

        double separation_radius = 18.0;
        double separation_strength = 400.0;
        int max_neighbors = 16;

        double lerp_general = 0.02;

        double friction_factor = 0.91;
        double smash_threshold = 5.0;
        double smash_min_cutoff = 0.20;
        double smash_cap = 500.0;
        double propelled_duration = 8.0;
        double shockwave_speed = 600.0; // vitesse de propagation de l'onde (units/s)

        void recompute_from_tile();
    };

    GlobalConfig &globalconfig();
    void reset_globalconfig();

} // namespace ffcore
