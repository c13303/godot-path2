#ifndef GLOBAL_CONFIG_NATIVE_H
#define GLOBAL_CONFIG_NATIVE_H

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/core/class_db.hpp>
#include "../core/global_config.h"

namespace godot
{

    class GlobalConfigNative : public Node
    {
        GDCLASS(GlobalConfigNative, Node);

    protected:
        static void _bind_methods();

    public:
        GlobalConfigNative() = default;
        ~GlobalConfigNative() override = default;

        double get_flow_weight() const;
        void set_flow_weight(double v);

        double get_center_pull() const;
        void set_center_pull(double v);

        double get_tile_size() const;
        void set_tile_size(double v);

        double get_wall_avoid_radius() const;
        void set_wall_avoid_radius(double v);

        double get_wall_repel_strength() const;
        void set_wall_repel_strength(double v);

        double get_direct_steer_radius() const;
        void set_direct_steer_radius(double v);

        double get_min_speed_fraction() const;
        void set_min_speed_fraction(double v);

        double get_cellgoal_cooldown_sec() const;
        void set_cellgoal_cooldown_sec(double v);

        double get_target_T2_param_margin() const;
        void set_target_T2_param_margin(double v);

        double get_target_T2_param_speed_ratio() const;
        void set_target_T2_param_speed_ratio(double v);

        double get_target_T2_param_speed_lerp() const;
        void set_target_T2_param_speed_lerp(double v);
        double get_target_T2_slow_threshold() const;
        void set_target_T2_slow_threshold(double v);

        double get_separation_radius() const;
        void set_separation_radius(double v);

        double get_separation_strength() const;
        void set_separation_strength(double v);

        int get_max_neighbors() const;
        void set_max_neighbors(int v);

        double get_lerp_general() const;
        void set_lerp_general(double v);

        double get_friction_factor() const;
        void set_friction_factor(double v);

        double get_smash_threshold() const;
        void set_smash_threshold(double v);

        double get_smash_min_cutoff() const;
        void set_smash_min_cutoff(double v);

        double get_smash_cap() const;
        void set_smash_cap(double v);

        double get_shockwave_speed() const;
        void set_shockwave_speed(double v);

        double get_explosion_falloff() const;
        void set_explosion_falloff(double v);

        double get_shockwave_stop_ratio() const;
        void set_shockwave_stop_ratio(double v);

        double get_shockwave_stop_duration_ms() const;
        void set_shockwave_stop_duration_ms(double v);

        bool get_draw_claimed_path() const;
        void set_draw_claimed_path(bool v);

        void reset_defaults();
    };

} // namespace godot

#endif // GLOBAL_CONFIG_NATIVE_H
