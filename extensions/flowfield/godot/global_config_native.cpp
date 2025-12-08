#include "global_config_native.h"
#include <algorithm>

using namespace godot;

namespace
{
    ffcore::GlobalConfig &cfg() { return ffcore::globalconfig(); }
}

void GlobalConfigNative::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("get_flow_weight"), &GlobalConfigNative::get_flow_weight);
    ClassDB::bind_method(D_METHOD("set_flow_weight", "value"), &GlobalConfigNative::set_flow_weight);

    ClassDB::bind_method(D_METHOD("get_center_pull"), &GlobalConfigNative::get_center_pull);
    ClassDB::bind_method(D_METHOD("set_center_pull", "value"), &GlobalConfigNative::set_center_pull);

    ClassDB::bind_method(D_METHOD("get_tile_size"), &GlobalConfigNative::get_tile_size);
    ClassDB::bind_method(D_METHOD("set_tile_size", "value"), &GlobalConfigNative::set_tile_size);

    ClassDB::bind_method(D_METHOD("get_wall_avoid_radius"), &GlobalConfigNative::get_wall_avoid_radius);
    ClassDB::bind_method(D_METHOD("set_wall_avoid_radius", "value"), &GlobalConfigNative::set_wall_avoid_radius);

    ClassDB::bind_method(D_METHOD("get_wall_repel_strength"), &GlobalConfigNative::get_wall_repel_strength);
    ClassDB::bind_method(D_METHOD("set_wall_repel_strength", "value"), &GlobalConfigNative::set_wall_repel_strength);

    ClassDB::bind_method(D_METHOD("get_direct_steer_radius"), &GlobalConfigNative::get_direct_steer_radius);
    ClassDB::bind_method(D_METHOD("set_direct_steer_radius", "value"), &GlobalConfigNative::set_direct_steer_radius);

    ClassDB::bind_method(D_METHOD("get_min_speed_fraction"), &GlobalConfigNative::get_min_speed_fraction);
    ClassDB::bind_method(D_METHOD("set_min_speed_fraction", "value"), &GlobalConfigNative::set_min_speed_fraction);

    ClassDB::bind_method(D_METHOD("get_cellgoal_cooldown_sec"), &GlobalConfigNative::get_cellgoal_cooldown_sec);
    ClassDB::bind_method(D_METHOD("set_cellgoal_cooldown_sec", "value"), &GlobalConfigNative::set_cellgoal_cooldown_sec);

    ClassDB::bind_method(D_METHOD("get_target_slow_radius_T1"), &GlobalConfigNative::get_target_slow_radius_T1);
    ClassDB::bind_method(D_METHOD("set_target_slow_radius_T1", "value"), &GlobalConfigNative::set_target_slow_radius_T1);

    ClassDB::bind_method(D_METHOD("get_target_approach_radius_T2"), &GlobalConfigNative::get_target_approach_radius_T2);
    ClassDB::bind_method(D_METHOD("set_target_approach_radius_T2", "value"), &GlobalConfigNative::set_target_approach_radius_T2);

    ClassDB::bind_method(D_METHOD("get_target_occupy_radius_T3"), &GlobalConfigNative::get_target_occupy_radius_T3);
    ClassDB::bind_method(D_METHOD("set_target_occupy_radius_T3", "value"), &GlobalConfigNative::set_target_occupy_radius_T3);

    ClassDB::bind_method(D_METHOD("get_arrival_speed_eps"), &GlobalConfigNative::get_arrival_speed_eps);
    ClassDB::bind_method(D_METHOD("set_arrival_speed_eps", "value"), &GlobalConfigNative::set_arrival_speed_eps);

    ClassDB::bind_method(D_METHOD("get_arrival_dwell_ms"), &GlobalConfigNative::get_arrival_dwell_ms);
    ClassDB::bind_method(D_METHOD("set_arrival_dwell_ms", "value"), &GlobalConfigNative::set_arrival_dwell_ms);

    ClassDB::bind_method(D_METHOD("get_separation_radius"), &GlobalConfigNative::get_separation_radius);
    ClassDB::bind_method(D_METHOD("set_separation_radius", "value"), &GlobalConfigNative::set_separation_radius);

    ClassDB::bind_method(D_METHOD("get_separation_strength"), &GlobalConfigNative::get_separation_strength);
    ClassDB::bind_method(D_METHOD("set_separation_strength", "value"), &GlobalConfigNative::set_separation_strength);

    ClassDB::bind_method(D_METHOD("get_max_neighbors"), &GlobalConfigNative::get_max_neighbors);
    ClassDB::bind_method(D_METHOD("set_max_neighbors", "value"), &GlobalConfigNative::set_max_neighbors);

    ClassDB::bind_method(D_METHOD("get_lerp_general"), &GlobalConfigNative::get_lerp_general);
    ClassDB::bind_method(D_METHOD("set_lerp_general", "value"), &GlobalConfigNative::set_lerp_general);

    ClassDB::bind_method(D_METHOD("get_friction_factor"), &GlobalConfigNative::get_friction_factor);
    ClassDB::bind_method(D_METHOD("set_friction_factor", "value"), &GlobalConfigNative::set_friction_factor);

    ClassDB::bind_method(D_METHOD("get_smash_threshold"), &GlobalConfigNative::get_smash_threshold);
    ClassDB::bind_method(D_METHOD("set_smash_threshold", "value"), &GlobalConfigNative::set_smash_threshold);

    ClassDB::bind_method(D_METHOD("get_smash_min_cutoff"), &GlobalConfigNative::get_smash_min_cutoff);
    ClassDB::bind_method(D_METHOD("set_smash_min_cutoff", "value"), &GlobalConfigNative::set_smash_min_cutoff);

    ClassDB::bind_method(D_METHOD("get_smash_cap"), &GlobalConfigNative::get_smash_cap);
    ClassDB::bind_method(D_METHOD("set_smash_cap", "value"), &GlobalConfigNative::set_smash_cap);
    ClassDB::bind_method(D_METHOD("get_shockwave_speed"), &GlobalConfigNative::get_shockwave_speed);
    ClassDB::bind_method(D_METHOD("set_shockwave_speed", "value"), &GlobalConfigNative::set_shockwave_speed);
    ClassDB::bind_method(D_METHOD("get_explosion_falloff"), &GlobalConfigNative::get_explosion_falloff);
    ClassDB::bind_method(D_METHOD("set_explosion_falloff", "value"), &GlobalConfigNative::set_explosion_falloff);
    ClassDB::bind_method(D_METHOD("get_shockwave_stop_ratio"), &GlobalConfigNative::get_shockwave_stop_ratio);
    ClassDB::bind_method(D_METHOD("set_shockwave_stop_ratio", "value"), &GlobalConfigNative::set_shockwave_stop_ratio);
    ClassDB::bind_method(D_METHOD("get_shockwave_stop_duration_ms"), &GlobalConfigNative::get_shockwave_stop_duration_ms);
    ClassDB::bind_method(D_METHOD("set_shockwave_stop_duration_ms", "value"), &GlobalConfigNative::set_shockwave_stop_duration_ms);

    ClassDB::bind_method(D_METHOD("reset_defaults"), &GlobalConfigNative::reset_defaults);

    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "flow_weight"), "set_flow_weight", "get_flow_weight");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "center_pull"), "set_center_pull", "get_center_pull");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "tile_size"), "set_tile_size", "get_tile_size");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "wall_avoid_radius"), "set_wall_avoid_radius", "get_wall_avoid_radius");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "wall_repel_strength"), "set_wall_repel_strength", "get_wall_repel_strength");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "direct_steer_radius"), "set_direct_steer_radius", "get_direct_steer_radius");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "min_speed_fraction"), "set_min_speed_fraction", "get_min_speed_fraction");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "cellgoal_cooldown_sec"), "set_cellgoal_cooldown_sec", "get_cellgoal_cooldown_sec");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "target_slow_radius_T1"), "set_target_slow_radius_T1", "get_target_slow_radius_T1");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "target_approach_radius_T2"), "set_target_approach_radius_T2", "get_target_approach_radius_T2");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "target_occupy_radius_T3"), "set_target_occupy_radius_T3", "get_target_occupy_radius_T3");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "arrival_speed_eps"), "set_arrival_speed_eps", "get_arrival_speed_eps");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "arrival_dwell_ms"), "set_arrival_dwell_ms", "get_arrival_dwell_ms");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "separation_radius"), "set_separation_radius", "get_separation_radius");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "separation_strength"), "set_separation_strength", "get_separation_strength");
    ADD_PROPERTY(PropertyInfo(Variant::INT, "max_neighbors"), "set_max_neighbors", "get_max_neighbors");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "lerp_general"), "set_lerp_general", "get_lerp_general");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "friction_factor"), "set_friction_factor", "get_friction_factor");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "smash_threshold"), "set_smash_threshold", "get_smash_threshold");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "smash_min_cutoff"), "set_smash_min_cutoff", "get_smash_min_cutoff");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "smash_cap"), "set_smash_cap", "get_smash_cap");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "shockwave_speed"), "set_shockwave_speed", "get_shockwave_speed");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "explosion_falloff"), "set_explosion_falloff", "get_explosion_falloff");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "shockwave_stop_ratio"), "set_shockwave_stop_ratio", "get_shockwave_stop_ratio");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "shockwave_stop_duration_ms"), "set_shockwave_stop_duration_ms", "get_shockwave_stop_duration_ms");
}

double GlobalConfigNative::get_flow_weight() const { return cfg().flow_weight; }
void GlobalConfigNative::set_flow_weight(double v) { cfg().flow_weight = v; }

double GlobalConfigNative::get_center_pull() const { return cfg().center_pull; }
void GlobalConfigNative::set_center_pull(double v) { cfg().center_pull = v; }

double GlobalConfigNative::get_tile_size() const { return cfg().tile_size; }
void GlobalConfigNative::set_tile_size(double v)
{
    if (v > 0.0)
    {
        cfg().tile_size = v;
        cfg().recompute_from_tile();
    }
}

double GlobalConfigNative::get_wall_avoid_radius() const { return cfg().wall_avoid_radius; }
void GlobalConfigNative::set_wall_avoid_radius(double v) { cfg().wall_avoid_radius = std::max(0.0, v); }

double GlobalConfigNative::get_wall_repel_strength() const { return cfg().wall_repel_strength; }
void GlobalConfigNative::set_wall_repel_strength(double v) { cfg().wall_repel_strength = std::max(0.0, v); }

double GlobalConfigNative::get_direct_steer_radius() const { return cfg().direct_steer_radius; }
void GlobalConfigNative::set_direct_steer_radius(double v) { cfg().direct_steer_radius = std::max(0.0, v); }

double GlobalConfigNative::get_min_speed_fraction() const { return cfg().min_speed_fraction; }
void GlobalConfigNative::set_min_speed_fraction(double v) { cfg().min_speed_fraction = std::clamp(v, 0.0, 1.0); }

double GlobalConfigNative::get_cellgoal_cooldown_sec() const { return cfg().cellgoal_cooldown_sec; }
void GlobalConfigNative::set_cellgoal_cooldown_sec(double v) { cfg().cellgoal_cooldown_sec = std::max(0.0, v); }

double GlobalConfigNative::get_target_slow_radius_T1() const { return cfg().target_slow_radius_T1; }
void GlobalConfigNative::set_target_slow_radius_T1(double v) { cfg().target_slow_radius_T1 = std::max(0.0, v); }

double GlobalConfigNative::get_target_approach_radius_T2() const { return cfg().target_approach_radius_T2; }
void GlobalConfigNative::set_target_approach_radius_T2(double v) { cfg().target_approach_radius_T2 = std::max(0.0, v); }

double GlobalConfigNative::get_target_occupy_radius_T3() const { return cfg().target_occupy_radius_T3; }
void GlobalConfigNative::set_target_occupy_radius_T3(double v) { cfg().target_occupy_radius_T3 = std::max(0.0, v); }

double GlobalConfigNative::get_arrival_speed_eps() const { return cfg().arrival_speed_eps; }
void GlobalConfigNative::set_arrival_speed_eps(double v) { cfg().arrival_speed_eps = std::max(0.0, v); }

double GlobalConfigNative::get_arrival_dwell_ms() const { return cfg().arrival_dwell_ms; }
void GlobalConfigNative::set_arrival_dwell_ms(double v) { cfg().arrival_dwell_ms = std::max(0.0, v); }

double GlobalConfigNative::get_separation_radius() const { return cfg().separation_radius; }
void GlobalConfigNative::set_separation_radius(double v) { cfg().separation_radius = std::max(0.0, v); }

double GlobalConfigNative::get_separation_strength() const { return cfg().separation_strength; }
void GlobalConfigNative::set_separation_strength(double v) { cfg().separation_strength = std::max(0.0, v); }

int GlobalConfigNative::get_max_neighbors() const { return cfg().max_neighbors; }
void GlobalConfigNative::set_max_neighbors(int v) { cfg().max_neighbors = std::max(0, v); }

double GlobalConfigNative::get_lerp_general() const { return cfg().lerp_general; }
void GlobalConfigNative::set_lerp_general(double v) { cfg().lerp_general = std::clamp(v, 0.0, 1.0); }

double GlobalConfigNative::get_friction_factor() const { return cfg().friction_factor; }
void GlobalConfigNative::set_friction_factor(double v) { cfg().friction_factor = std::clamp(v, 0.0, 1.0); }

double GlobalConfigNative::get_smash_threshold() const { return cfg().smash_threshold; }
void GlobalConfigNative::set_smash_threshold(double v) { cfg().smash_threshold = std::max(0.0, v); }

double GlobalConfigNative::get_smash_min_cutoff() const { return cfg().smash_min_cutoff; }
void GlobalConfigNative::set_smash_min_cutoff(double v) { cfg().smash_min_cutoff = std::max(0.0, v); }

double GlobalConfigNative::get_smash_cap() const { return cfg().smash_cap; }
void GlobalConfigNative::set_smash_cap(double v) { cfg().smash_cap = std::max(0.0, v); }

double GlobalConfigNative::get_shockwave_speed() const { return cfg().shockwave_speed; }
void GlobalConfigNative::set_shockwave_speed(double v) { cfg().shockwave_speed = std::max(0.0, v); }

double GlobalConfigNative::get_explosion_falloff() const { return cfg().explosion_falloff; }
void GlobalConfigNative::set_explosion_falloff(double v) { cfg().explosion_falloff = std::max(0.0, v); }

double GlobalConfigNative::get_shockwave_stop_ratio() const { return cfg().shockwave_stop_ratio; }
void GlobalConfigNative::set_shockwave_stop_ratio(double v) { cfg().shockwave_stop_ratio = std::max(0.0, v); }

double GlobalConfigNative::get_shockwave_stop_duration_ms() const { return cfg().shockwave_stop_duration_ms; }
void GlobalConfigNative::set_shockwave_stop_duration_ms(double v) { cfg().shockwave_stop_duration_ms = std::max(0.0, v); }

void GlobalConfigNative::reset_defaults()
{
    ffcore::reset_globalconfig();
}
