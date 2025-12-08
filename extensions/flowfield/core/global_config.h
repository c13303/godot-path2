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

        // Arrivée dynamique
        double target_T1_param_tile_ratio = 0.1;  // rayon T1 en nombre de tiles
        double target_T2_param_margin = tile_size * 3.0; // marge ajoutée autour de T1

        double target_T2_param_speed_ratio = 0.5; // fraction de la vitesse max visée dans T2
        double target_T2_param_speed_lerp = 0.05; // interpolation vers la vitesse cible en T2

        double separation_radius = 16.0;
        double separation_strength = 400.0;
        int max_neighbors = 16;

        double lerp_general = 0.02;
        bool enable_claim_force = true;
        double velocity_min_trig_walk_animation = 0.5;
        double agent_offset_y = 0.0;

        double friction_factor = 0.91;
        double smash_threshold = 5.0;
        double smash_min_cutoff = 0.20;
        double smash_cap = 500.0;
        double propelled_duration = 8.0;
        double shockwave_speed = 150.0;           // vitesse de propagation de l'onde (units/s)
        double explosion_falloff = 0.1;           // puissance de l'atténuation (1.0 linéaire, >1 plus raide)
        double shockwave_stop_ratio = 2.0;        // rayon de blocage relatif à l'explosion
        double shockwave_stop_duration_ms = 3000; // durée de blocage en millisecondes

        void recompute_from_tile();
    };

    GlobalConfig &globalconfig();
    void reset_globalconfig();

} // namespace ffcore
