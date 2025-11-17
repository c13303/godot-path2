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

        double get_target_slow_radius() const;
        void set_target_slow_radius(double v);

        double get_target_approach_radius() const;
        void set_target_approach_radius(double v);

        double get_target_occupy_radius() const;
        void set_target_occupy_radius(double v);

        double get_separation_radius() const;
        void set_separation_radius(double v);

        double get_separation_strength() const;
        void set_separation_strength(double v);

        int get_max_neighbors() const;
        void set_max_neighbors(int v);

        double get_lerp_general() const;
        void set_lerp_general(double v);

        void reset_defaults();
    };

} // namespace godot

#endif // GLOBAL_CONFIG_NATIVE_H

